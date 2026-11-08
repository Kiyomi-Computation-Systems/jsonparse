;;; tests/test-easy-sequence.sps: the stream procedures of (jsonparse easy),
;;; held to ADR-0020 decision 10 (and ADR-0019 for the shape of an error).
;;;
;;; Every expectation is written by hand. Non-ASCII characters are written
;;; as \x...; escapes, RS as \x1e; or the byte 30. Anything that can raise is
;;; run through `outcome`, which tags what happened, so a raise never equals
;;; an expected #f and a no-raise never equals an expected raise.
;;;
;;; 1. Reading: formats, options, short forms, argument dispatch, the empty
;;;    stream, the fold's order.
;;; 2. Errors, through each reader: every site an error starts from, the
;;;    reader's own codes, non-continuable raises, ports that start mid-way.
;;; 3. REPORT: the condition it gets, skipping, stopping, when it is
;;;    refused.
;;; 4. Ports: values arrive as records do, one byte per read, long streams,
;;;    re-entrancy, what the caller's code raises.
;;; 5. Writing: exact bytes, indent, refused values, partial output, ports
;;;    that raise, bad VALUES.
;;; 6. Round trips.
;;; 7. The one-document readers refuse stream values.
;;; 8. Arguments.
;;; 9. Re-exports.
(import (rnrs)
        (rnrs mutable-pairs)
        (only (chezscheme) real-time make-list void)
        (srfi :64)
        (jsonparse-testing)
        (jsonparse easy)
        (jsonparse writer)
        (prefix (jsonparse error) l:)
        (prefix (jsonparse options) l:))

(define runner (test-runner-simple))
(test-runner-current runner)

;; The simple runner names a failing test but not its values. Print both.
(let ((simple-end (test-runner-on-test-end runner)))
  (test-runner-on-test-end! runner
    (lambda (r)
      (simple-end r)
      (when (memq (test-result-kind r) '(fail xpass))
        (display "  expected: ")
        (write (test-result-ref r 'expected-value))
        (newline)
        (display "  actual:   ")
        (write (test-result-ref r 'actual-value))
        (newline)
        (flush-output-port (current-output-port))))))

(define started (real-time))

(define-syntax chk
  (syntax-rules ()
    ((_ name expected expr) (test-equal name expected expr))))

;; --- helpers -----------------------------------------------------------------

(define (u s) (string->utf8 s))
(define (noop n) #f)
(define (o . args) (apply l:make-json-options args))

;; norm : Any -> Any
;; A value with hashtables as (table (key . value) ...) sorted by key, and
;; json-numbers as (num text), so that equal? compares it.
(define (norm v)
  (cond ((vector? v) (vector-map norm v))
        ((hashtable? v)
         (let-values (((ks vs) (hashtable-entries v)))
           (cons 'table
                 (list-sort (lambda (a b) (string<? (car a) (car b)))
                            (map (lambda (k x) (cons k (norm x)))
                                 (vector->list ks) (vector->list vs))))))
        ((pair? v) (map (lambda (m) (cons (car m) (norm (cdr m)))) v))
        ((json-number? v) (list 'num (json-number-text v)))
        (else v)))

;; norm-list : Any -> Any   a list of values, each normalised
(define (norm-list vs)
  (if (list? vs) (map norm vs) (norm vs)))

;; cond-list : condition -> list
;; Every field of a &json-error that a stream procedure promises, read raw:
;; a missing who, message or irritants condition shows as #f.
;;   (REASON OFFSET RECORD WHO MESSAGE IRRITANTS json-error? record-error? error? violation?)
(define (cond-list e)
  (list (l:json-error-reason e) (l:json-error-offset e)
        (and (l:json-record-error? e) (l:json-error-record e))
        (and (who-condition? e) (condition-who e))
        (and (message-condition? e) (condition-message e))
        (and (irritants-condition? e) (condition-irritants e))
        (json-error? e) (l:json-record-error? e) (error? e) (violation? e)))

;; outcome : (-> Any) -> list
;; What the thunk did, caught by type:
;;   (returned NORMALISED-VALUE)
;;   (raised-rec . cond-list)       a &json-record-error
;;   (raised REASON OFFSET WHO MESSAGE IRRITANTS ERROR? VIOLATION?)  another &json-error
;;   (violation WHO IRRITANTS)      an assertion violation
;;   (other-condition)
(define (outcome thunk)
  (guard (e ((l:json-record-error? e) (cons 'raised-rec (cond-list e)))
            ((json-error? e)
             (list 'raised (l:json-error-reason e) (l:json-error-offset e)
                   (and (who-condition? e) (condition-who e))
                   (and (message-condition? e) (condition-message e))
                   (and (irritants-condition? e) (condition-irritants e))
                   (error? e) (violation? e)))
            ((assertion-violation? e)
             (list 'violation (and (who-condition? e) (condition-who e))
                   (if (irritants-condition? e) (condition-irritants e) 'no-irritants)))
            ((condition? e) (list 'other-condition)))
    (list 'returned (norm-list (thunk)))))

;; (violation-of WHO thunk): the outcome, with the irritants dropped when it
;; is a violation, so the who alone is compared. Used where the irritants
;; are not the point; the raw shape is asserted in section 8.
(define (who-only o)
  (if (eq? (car o) 'violation) (list 'violation (cadr o)) o))

(define (rrec reason offset record who message)
  (list 'raised-rec reason offset record who message '() #t #t #t #f))
;; What a REPORT receives: cond-list of the same condition.
(define (skipped reason offset record who message)
  (list reason offset record who message '() #t #t #t #f))
(define (raised reason offset who message . irritants)
  (list 'raised reason offset who message irritants #t #f))
(define (returned v) (list 'returned v))
(define (violates who . irritants) (list 'violation who irritants))

(define (nm title . parts)
  (apply string-append title
         (map (lambda (p) (string-append " / " (if (symbol? p) (symbol->string p) p)))
              parts)))

;; b : (U String Integer) ... -> (Listof Integer)
;; The bytes of the ASCII strings and integers given, in order.
(define (b . parts)
  (let loop ((ps parts) (acc '()))
    (cond ((null? ps) (reverse acc))
          ((integer? (car ps)) (loop (cdr ps) (cons (car ps) acc)))
          (else (loop (cdr ps) (append (reverse (bytevector->u8-list (u (car ps)))) acc))))))

;; --- readers under test --------------------------------------------------------

;; chunk-port : Bytevector (Listof Positive-Integer) (Integer -> Any) -> Binary-Input-Port
;; A port whose read procedure gives the next number of bytes from SIZES
;; (cycling), or what is left, and calls ON-READ with the count it gave.
(define (chunk-port bv sizes on-read)
  (let ((pos 0) (ring sizes))
    (make-custom-binary-input-port
     "chunks"
     (lambda (buf start count)
       (let* ((left (- (bytevector-length bv) pos))
              (n (min left count (car ring))))
         (set! ring (if (null? (cdr ring)) sizes (cdr ring)))
         (bytevector-copy! bv pos buf start n)
         (set! pos (+ pos n))
         (on-read n)
         n))
     #f #f #f)))

;; The ways to read: a bytevector; a bytevector port; a port giving 3, 5
;; then 2 bytes a read; the fold over a port; the fold over a port giving
;; a byte a read.
(define hows '(bytes port chunk fold byte))

(define (who-of how)
  (case how
    ((bytes) 'bytevector->json-sequence)
    ((port chunk) 'read-json-sequence)
    (else 'fold-json-sequence)))

(define (port-of how bv)
  (case how
    ((chunk) (chunk-port bv '(3 5 2) noop))
    ((byte) (chunk-port bv '(1) noop))
    (else (open-bytevector-input-port bv))))

;; call : Symbol Bytevector (Listof Any) -> (Listof Any)
;; The values of the stream BV, read the way HOW says, with ARGS after the
;; stream (REPORT and/or options, as given).
(define (call how bv args)
  (case how
    ((bytes) (apply bytevector->json-sequence bv args))
    ((port chunk) (apply read-json-sequence (port-of how bv) args))
    (else (reverse (apply fold-json-sequence (lambda (v acc) (cons v acc)) '()
                          (port-of how bv) args)))))

;; collect : Symbol Bytevector json-options -> (outcome (skip ...))
;; Reads with a REPORT that logs the cond-list of each condition it gets.
(define (collect how bv opts)
  (let ((skips '()))
    (let ((r (outcome (lambda ()
                        (call how bv (list (lambda (c) (set! skips (cons (cond-list c) skips)))
                                           opts))))))
      (list r (reverse skips)))))

;; plain : Symbol Bytevector json-options -> outcome   no REPORT
(define (plain how bv opts)
  (outcome (lambda () (call how bv (list opts)))))

;; frame : Symbol (Listof String) -> Bytevector
;; The texts as a stream of the format: a newline after each, an RS before
;; each, or a space after each.
(define (frame fmt texts)
  (u (apply string-append
            (map (lambda (t)
                   (case fmt
                     ((lines) (string-append t "\n"))
                     ((seq) (string-append "\x1e;" t "\n"))
                     (else (string-append t " "))))
                 texts))))

(define formats '(lines seq values))

;; read-fmt : Symbol Symbol Bytevector Any ... -> (outcome skips)
;; Reads BV as format FMT with the options (stream FMT) and OPTS. Seq gets
;; a REPORT; the others do not.
(define (read-fmt how fmt bv . opts)
  (let ((opt (apply o 'stream fmt opts)))
    (if (eq? fmt 'seq)
        (collect how bv opt)
        (list (plain how bv opt) '()))))

;; --- 1. Reading ----------------------------------------------------------------

(define texts-a
  '("{\"a\":1.50,\"b\":[true,false,null]}" "[1e2,\"x\\u00e9\",-7]" "\"s\"" "-7"
    "true" "false" "null" "0.5"))

(define want-default
  (list '(("a" . 1.5) ("b" . #(#t #f null))) '#(100.0 "x\xe9;" -7) "s" -7 #t #f 'null 0.5))

(define want-custom
  '((table ("a" num "1.50") ("b" . #(#t #f nil)))
    #((num "1e2") "x\xe9;" (num "-7"))
    "s" (num "-7") #t #f nil (num "0.5")))

(for-each
 (lambda (fmt)
   (for-each
    (lambda (how)
      (let ((bv (frame fmt texts-a)))
        (chk (nm "every kind of value, default options" (symbol->string fmt) (symbol->string how))
             (list (returned want-default) '())
             (read-fmt how fmt bv))
        (chk (nm "every kind of value, hashtable text nil" (symbol->string fmt) (symbol->string how))
             (list (returned want-custom) '())
             (read-fmt how fmt bv 'object-mode 'hashtable 'number-mode 'text 'null 'nil))))
    hows))
 formats)

;; The short forms use the defaults: lines, flonum, alist, null.
(for-each
 (lambda (how)
   (chk (nm "short form reads every kind as default lines" (symbol->string how))
        (returned want-default)
        (outcome (lambda () (call how (frame 'lines texts-a) '()))))
   ;; A wrong default stream would read "1 2" as two values (values) or demand a
   ;; REPORT (seq); a wrong default for blank lines would skip the blank.
   (chk (nm "short form: two values on a line is an error" (symbol->string how))
        (rrec 'trailing-garbage 2 1 (who-of how) "trailing-garbage at byte 2 in record 1")
        (outcome (lambda () (call how (u "1 2\n3\n") '()))))
   (chk (nm "short form: a blank line is an error" (symbol->string how))
        (rrec 'blank-line 2 2 (who-of how) "blank-line at byte 2 in record 2")
        (outcome (lambda () (call how (u "1\n\n2") '()))))
   (chk (nm "short form: the last line may lack its newline" (symbol->string how))
        (returned '(1 2))
        (outcome (lambda () (call how (u "1\n2") '())))))
 hows)

;; Each option reaches every record: three records each, the option showing
;; in all three, for every format.
(define option-cases
  ;; options, texts, want (normalised)
  (list
   (list '(object-mode hashtable) '("{\"a\":1}" "{\"b\":[{\"c\":2}]}" "{}")
         '((table ("a" . 1)) (table ("b" . #((table ("c" . 2))))) (table)))
   (list '(number-mode text) '("1.50" "[2e1]" "{\"k\":3.0}")
         '((num "1.50") #((num "2e1")) (("k" num "3.0"))))
   (list '(null nil) '("null" "[null]" "{\"k\":null}")
         '(nil #(nil) (("k" . nil))))
   (list '(number-mode exact) '("0.25" "[1e2]" "3")
         '(1/4 #(100) 3))))

(for-each
 (lambda (case)
   (for-each
    (lambda (fmt)
      (for-each
       (lambda (how)
         (chk (nm "option reaches every record" (symbol->string (car (car case))) (symbol->string (cadr (car case)))
                  (symbol->string fmt) (symbol->string how))
              (list (returned (caddr case)) '())
              (apply read-fmt how fmt (frame fmt (cadr case)) (car case))))
       hows))
    formats))
 option-cases)

;; The limits apply to each record, and the third is the one over. Offsets:
;; lines "[[1]]\n[]\n[[[3]]]\n": the third [ of record 3 is byte 11, so 12.
;; seq: RS 0, [[1]] 1-5, \n 6, RS 7, [] 8-9, \n 10, RS 11, [[[ 12-14: 15.
;; values "[[1]] [] [[[3]]] ": [[1]] 0-4, [] 6-7, [[[ 9-11: 12.
(for-each
 (lambda (how)
   (let ((texts '("[[1]]" "[]" "[[[3]]]")))
     (chk (nm "depth-limit 2 / lines" (symbol->string how))
          (rrec 'nesting-too-deep 12 3 (who-of how) "nesting-too-deep at byte 12 in record 3")
          (plain how (frame 'lines texts) (o 'depth-limit 2)))
     (chk (nm "depth-limit 2 / values" (symbol->string how))
          (rrec 'nesting-too-deep 12 3 (who-of how) "nesting-too-deep at byte 12 in record 3")
          (plain how (frame 'values texts) (o 'depth-limit 2 'stream 'values)))
     (chk (nm "depth-limit 2 / seq" (symbol->string how))
          (list (returned '(#(#(1)) #()))
                (list (skipped 'nesting-too-deep 15 3 (who-of how)
                               "nesting-too-deep at byte 15 in record 3")))
          (collect how (frame 'seq texts) (o 'depth-limit 2 'stream 'seq))))
   ;; digit-limit 3: lines "1\n22\n1234\n": 1234 is bytes 5-8, error at 9.
   ;; seq: RS 0, 1 1, \n 2, RS 3, 22 4-5, \n 6, RS 7, 1234 8-11: 12.
   ;; values "1 22 1234 ": 1234 is bytes 5-8: 9.
   (let ((texts '("1" "22" "1234")))
     (chk (nm "digit-limit 3 / lines" (symbol->string how))
          (rrec 'number-too-long 9 3 (who-of how) "number-too-long at byte 9 in record 3")
          (plain how (frame 'lines texts) (o 'digit-limit 3)))
     (chk (nm "digit-limit 3 / values" (symbol->string how))
          (rrec 'number-too-long 9 3 (who-of how) "number-too-long at byte 9 in record 3")
          (plain how (frame 'values texts) (o 'digit-limit 3 'stream 'values)))
     (chk (nm "digit-limit 3 / seq" (symbol->string how))
          (list (returned '(1 22))
                (list (skipped 'number-too-long 12 3 (who-of how)
                               "number-too-long at byte 12 in record 3")))
          (collect how (frame 'seq texts) (o 'digit-limit 3 'stream 'seq))))
   ;; Over the limit in the first record and in the only one.
   (chk (nm "digit-limit 3 / the first record" (symbol->string how))
        (rrec 'number-too-long 5 1 (who-of how) "number-too-long at byte 5 in record 1")
        (plain how (u "12345\n1\n") (o 'digit-limit 3)))
   ;; blank-lines skip: blank and whitespace-only lines vanish, at the start,
   ;; middle and end, and the default refuses each.
   (chk (nm "blank-lines skip" (symbol->string how))
        (returned '(1 2 3))
        (plain how (u "\n1\n\n  \n2\n3\n\n") (o 'blank-lines 'skip)))
   (chk (nm "blank-lines default is error: the first blank line" (symbol->string how))
        (rrec 'blank-line 0 1 (who-of how) "blank-line at byte 0 in record 1")
        (plain how (u "\n1\n") (o)))
   (chk (nm "blank-lines default is error: whitespace only" (symbol->string how))
        (rrec 'blank-line 4 2 (who-of how) "blank-line at byte 4 in record 2")
        (plain how (u "1\n  \n2") (o))))
 hows)

;; The two-argument forms tell options from a procedure.
(for-each
 (lambda (how)
   (let ((bad (u "1\n[x\nnull\n"))
         (hits '()))
     (chk (nm "(reader x options): options are options" (symbol->string how))
          (returned '(1 nil))
          (outcome (lambda () (call how (u "1\nnull\n") (list (o 'null 'nil))))))
     (chk (nm "(reader x report): a procedure is a REPORT" (symbol->string how))
          (list (returned '(1 null))
                (list (skipped 'unexpected-byte 3 2 (who-of how) "unexpected-byte at byte 3 in record 2")))
          (let* ((r (outcome (lambda ()
                               (call how bad
                                     (list (lambda (c) (set! hits (cons (cond-list c) hits))))))))
                 (seen (reverse hits)))
            (list r seen)))
     (chk (nm "(reader x #f): #f is no REPORT" (symbol->string how))
          (rrec 'unexpected-byte 3 2 (who-of how) "unexpected-byte at byte 3 in record 2")
          (outcome (lambda () (call how bad (list #f)))))
     (chk (nm "(reader x #f options)" (symbol->string how))
          (list (rrec 'unexpected-byte 3 2 (who-of how) "unexpected-byte at byte 3 in record 2")
                (returned '(nil)))
          (list (outcome (lambda () (call how bad (list #f (o 'null 'nil)))))
                (outcome (lambda () (call how (u "null\n") (list #f (o 'null 'nil)))))))
     (chk (nm "(reader x report options)" (symbol->string how))
          (list (returned '(1 nil)) 1)
          (let ((n 0))
            (let ((r (outcome (lambda ()
                                (call how (u "1\n[x\nnull\n")
                                      (list (lambda (c) (set! n (+ n 1))) (o 'null 'nil)))))))
              (list r n))))))
 hows)

;; The empty stream gives (), and the fold its KNIL.
(for-each
 (lambda (how)
   (for-each
    (lambda (fmt)
      (chk (nm "the empty stream" (symbol->string how) (symbol->string fmt))
           (list (returned '()) '())
           (read-fmt how fmt (u ""))))
    formats)
   (chk (nm "the empty stream, values: whitespace only" (symbol->string how))
        (list (returned '()) '())
        (read-fmt how 'values (u " \n\t ")))
   ;; RS and whitespace, no value: a bad record, not an empty one. RS 0, space 1, newline 2.
   (chk (nm "seq: an RS with only whitespace after it is a bad record" (symbol->string how))
        (list (returned (quote ())) (list (skipped (quote unexpected-eof) 3 1 (who-of how) "unexpected-eof at byte 3 in record 1")))
        (read-fmt how (quote seq) (u "\x1e; \n"))))
 hows)

(let ((knil (vector 'knil))
      (kons (lambda (v acc) (list 'k v acc))))
  (for-each
   (lambda (fmt)
     (chk (nm "fold of the empty stream is KNIL" (symbol->string fmt))
          (list #t #t)
          (let* ((opt (o 'stream fmt))
                 (args (if (eq? fmt 'seq) (list (lambda (c) #f) opt) (list opt))))
            (list (eq? knil (apply fold-json-sequence kons knil (open-bytevector-input-port (u "")) args))
                  (eq? knil (apply fold-json-sequence kons knil (port-of 'byte (u "")) args)))))
     ;; (kons value acc): the value first, in stream order, from KNIL.
     (chk (nm "fold: (kons value acc) in stream order" (symbol->string fmt))
          '(k 3 (k 2 (k 1 z)))
          (let* ((opt (o 'stream fmt))
                 (args (if (eq? fmt 'seq) (list (lambda (c) #f) opt) (list opt))))
            (apply fold-json-sequence kons 'z (open-bytevector-input-port (frame fmt '("1" "2" "3"))) args)))
     (chk (nm "fold: the same over a byte-a-time port" (symbol->string fmt))
          '(k 3 (k 2 (k 1 z)))
          (let* ((opt (o 'stream fmt))
                 (args (if (eq? fmt 'seq) (list (lambda (c) #f) opt) (list opt))))
            (apply fold-json-sequence kons 'z (port-of 'byte (frame fmt '("1" "2" "3"))) args))))
   formats)
  ;; The fold's result is what the last KONS returned, not a list.
  (chk "fold: a non-list accumulator"
       10
       (fold-json-sequence + 0 (open-bytevector-input-port (u "1\n2\n3\n4\n")))))

;; --- 2. Errors -----------------------------------------------------------------

;; Sites an error starts from, through each reader.
(for-each
 (lambda (how)
   (let ((who (who-of how)))
     ;; Bad partway through a feed: the x of "[x".
     (chk (nm "error: bad partway" (symbol->string how))
          (rrec 'unexpected-byte 5 3 who "unexpected-byte at byte 5 in record 3")
          (outcome (lambda () (call how (u "1\n2\n[x\n") '()))))
     ;; Found bad at its end: "[1," then the newline at byte 5.
     (chk (nm "error: bad at its end" (symbol->string how))
          (rrec 'unexpected-eof 5 2 who "unexpected-eof at byte 5 in record 2")
          (outcome (lambda () (call how (u "1\n[1,\n2\n") '()))))
     ;; ... and at the end of the input, with no newline: "[1," is 2-4.
     (chk (nm "error: bad at the end of the input" (symbol->string how))
          (rrec 'unexpected-eof 5 2 who "unexpected-eof at byte 5 in record 2")
          (outcome (lambda () (call how (u "1\n[1,") '()))))
     ;; A blank line, at the line's end.
     (chk (nm "error: a blank line" (symbol->string how))
          (rrec 'blank-line 2 2 who "blank-line at byte 2 in record 2")
          (outcome (lambda () (call how (u "1\n\n2") '()))))
     ;; The first byte is bad.
     (chk (nm "error: the very first byte" (symbol->string how))
          (rrec 'unexpected-byte 0 1 who "unexpected-byte at byte 0 in record 1")
          (outcome (lambda () (call how (u "x\n") '()))))
     ;; The error comes after the good records, which a raise discards.
     (chk (nm "error: the record is the bad one's, not the reader's next" (symbol->string how))
          (rrec (quote trailing-garbage) 10 4 who "trailing-garbage at byte 10 in record 4")
          (outcome (lambda () (call how (u "1\n22\n333\n4x\n5\n") '()))))
     ;; Under values: a value cut short at the end of the input, and one
     ;; cut short in the middle of its number list.
     (chk (nm "error: values cut short" (symbol->string how))
          (rrec 'unexpected-eof 5 2 who "unexpected-eof at byte 5 in record 2")
          (outcome (lambda () (call how (u "1 [2,") (list (o 'stream 'values))))))
     (chk (nm "error: values cut short, no comma" (symbol->string how))
          (rrec 'unexpected-eof 4 2 who "unexpected-eof at byte 4 in record 2")
          (outcome (lambda () (call how (u "1 [2") (list (o 'stream 'values))))))
     ;; Under values, values before the error are not lost to a fold, but a
     ;; raise gives the error: "1 2x" is 1, 2, then x at 3 in record 3.
     (chk (nm "error: values then a bad byte" (symbol->string how))
          (rrec 'unexpected-byte 3 3 who "unexpected-byte at byte 3 in record 3")
          (outcome (lambda () (call how (u "1 2x") (list (o 'stream 'values))))))
     ;; The error shape, raw: a record error is a json-error, an error, no
     ;; violation, with who, message and irritants conditions.
     (chk (nm "error: the raw shape" (symbol->string how))
          (list #t #t #t #f #t #t #t)
          (guard (e (#t (list (json-error? e) (l:json-record-error? e) (error? e) (violation? e)
                              (who-condition? e) (message-condition? e) (irritants-condition? e))))
            (call how (u "x\n") '())
            'no-raise))))
 hows)

;; The reader's own codes, through REPORT. "abc RS 1 \n RS 12": abc 0-2, RS 3,
;; 1 at 4, \n 5, RS 6, 12 at 7-8, ending at 9.
(for-each
 (lambda (how)
   (let ((who (who-of how)))
     (chk (nm "seq: bytes before the first RS, and a truncated last record" (symbol->string how))
          (list (returned '(1))
                (list (skipped 'unexpected-byte 0 1 who "unexpected-byte at byte 0 in record 1")
                      (skipped 'truncated 9 3 who "truncated at byte 9 in record 3")))
          (collect how (u "abc\x1e;1\n\x1e;12") (o 'stream 'seq)))
     ;; Truncated at the next RS: RS 0, 1 at 1, RS 2.
     (chk (nm "seq: truncated at the next RS" (symbol->string how))
          (list (returned '(2))
                (list (skipped 'truncated 2 1 who "truncated at byte 2 in record 1")))
          (collect how (u "\x1e;1\x1e;2\n") (o 'stream 'seq)))
     ;; Repeated RS make no record. RS 0, 1 1, \n 2, RS 3, RS 4, [ 5, x 6.
     (chk (nm "seq: repeated RS make no record; a bad one is skipped" (symbol->string how))
          (list (returned '(1 3))
                (list (skipped 'unexpected-byte 6 2 who "unexpected-byte at byte 6 in record 2")))
          (collect how (u "\x1e;1\n\x1e;\x1e;[x\n\x1e;3\n") (o 'stream 'seq)))))
 hows)

;; Non-continuable: a handler that returns gets a &non-continuable violation.
(define (handler-returns thunk)
  (guard (e ((non-continuable-violation? e) 'non-continuable)
            (#t 'other))
    (with-exception-handler (lambda (e) 'handled) thunk)))
(chk "every record error is raised non-continuable"
     (make-list 3 'non-continuable)
     (list (handler-returns (lambda () (bytevector->json-sequence (u "x\n"))))
           (handler-returns (lambda () (read-json-sequence (open-bytevector-input-port (u "x\n")))))
           (handler-returns (lambda () (fold-json-sequence cons '() (open-bytevector-input-port (u "x\n")))))))
(chk "the handler is the same for a late error and a blank line"
     (make-list 3 'non-continuable)
     (list (handler-returns (lambda () (bytevector->json-sequence (u "1\n2\n\n"))))
           (handler-returns (lambda () (read-json-sequence (open-bytevector-input-port (u "1\n[1,\n")))))
           (handler-returns (lambda () (fold-json-sequence cons '() (open-bytevector-input-port (u "1 x"))
                                                           (o 'stream 'values))))))

;; From a port, the offset counts from where the port was: read 3 bytes
;; first. "xyz" then "1\n2\n[x\n": the x is still byte 5 of the stream.
(chk "port: offset counts from where the port was"
     (list (rrec 'unexpected-byte 5 3 'read-json-sequence "unexpected-byte at byte 5 in record 3")
           (rrec 'unexpected-byte 5 3 'fold-json-sequence "unexpected-byte at byte 5 in record 3")
           (rrec 'unexpected-byte 5 3 'read-json-sequence "unexpected-byte at byte 5 in record 3"))
     (let ((p1 (open-bytevector-input-port (u "xyz1\n2\n[x\n")))
           (p2 (open-bytevector-input-port (u "xyz1\n2\n[x\n")))
           (p3 (chunk-port (u "xyz1\n2\n[x\n") '(3 2 1 4) noop)))
       (get-bytevector-n p1 3)
       (get-bytevector-n p2 3)
       (get-bytevector-n p3 3)
       (list (outcome (lambda () (read-json-sequence p1)))
             (outcome (lambda () (fold-json-sequence cons '() p2)))
             (outcome (lambda () (read-json-sequence p3))))))
(chk "port: values read from where the port was"
     (returned '(1 2))
     (let ((p (open-bytevector-input-port (u "xyz1\n2\n"))))
       (get-bytevector-n p 3)
       (outcome (lambda () (read-json-sequence p)))))

;; --- 3. REPORT -----------------------------------------------------------------

;; It gets the condition that would have been raised: assert both sides for
;; the same bad record. "1\n[x\n3\n": the x is byte 3 of record 2.
(for-each
 (lambda (how)
   (let ((who (who-of how))
         (bad (u "1\n[x\n3\n")))
     (chk (nm "REPORT gets what would have been raised" (symbol->string how))
          (list (rrec 'unexpected-byte 3 2 who "unexpected-byte at byte 3 in record 2")
                (list (returned '(1 3))
                      (list (skipped 'unexpected-byte 3 2 who "unexpected-byte at byte 3 in record 2"))))
          (list (outcome (lambda () (call how bad '())))
                (collect how bad (o))))))
 hows)

;; Returning skips the record, and the later values still arrive. The whole
;; event log: "1\n[x\n3\n[\n5\n" has bad records 2 (x at 3) and 4 ([ at 7,
;; the newline at 8 ends it).
(let ((log '()))
  (define (note! x) (set! log (cons x log)))
  (let ((r (fold-json-sequence
            (lambda (v acc) (note! (list 'value v)) (cons v acc))
            '()
            (open-bytevector-input-port (u "1\n[x\n3\n[\n5\n"))
            (lambda (c) (note! (list 'skip (cond-list c)))))))
    (chk "REPORT: skipping, with the whole event log, at once"
         (list '(5 3 1)
               (list '(value 1)
                     (list 'skip (skipped 'unexpected-byte 3 2 'fold-json-sequence
                                          "unexpected-byte at byte 3 in record 2"))
                     '(value 3)
                     (list 'skip (skipped 'unexpected-eof 8 4 'fold-json-sequence
                                          "unexpected-eof at byte 8 in record 4"))
                     '(value 5)))
         (list r (reverse log)))))

;; The same through a port, whose reads are logged: the skip comes as soon
;; as the record that is bad has come, not at the end.
(for-each
 (lambda (fmt)
   (let ((log '()))
     (define (note! x) (set! log (cons x log)))
     (let ((r (read-json-sequence
               (chunk-port (u "1\n[x\n3\n") '(2 3 2) (lambda (n) (note! (list 'read n))))
               (lambda (c) (note! (list 'skip (l:json-error-reason c) (l:json-error-offset c)
                                        (l:json-error-record c))))
               (o))))
       (chk "REPORT: called as the bad record comes, between reads"
            (list '(1 3)
                  '((read 2) (read 3) (skip unexpected-byte 3 2) (read 2) (read 0)))
            (list r (reverse log))))))
 '(lines))

;; Raising from REPORT stops the stream, and what comes out is the condition.
(for-each
 (lambda (how)
   (let ((who (who-of how))
         (seen '()))
     (let ((got (guard (e (#t e))
                  (call how (u "1\n[x\n3\n[y\n")
                        (list (lambda (c) (set! seen (cons c seen)) (raise c)))))))
       (chk (nm "REPORT raising stops the stream: the same object" (symbol->string how))
            (list 1 #t (skipped 'unexpected-byte 3 2 who "unexpected-byte at byte 3 in record 2"))
            (list (length seen) (eq? got (car seen)) (cond-list got))))))
 hows)

;; ... and no value after the raise reaches the fold.
(let ((vals '()))
  (chk "REPORT raising stops the stream: later values never arrive"
       (list '(1) 'stopped)
       (let ((r (guard (e ((l:json-record-error? e) 'stopped))
                  (fold-json-sequence (lambda (v acc) (set! vals (cons v vals)) acc) #f
                                      (open-bytevector-input-port (u "1\n[x\n3\n"))
                                      (lambda (c) (raise c))))))
         (list (reverse vals) r))))

;; seq without REPORT, and values with one, raise before anything is read.
(define (counted-port bv)
  (let ((reads 0))
    (cons (chunk-port bv '(4) (lambda (n) (set! reads (+ reads 1))))
          (lambda () reads))))

(define report-proc (lambda (c) #f))
(define seq-refusal-rows
  ;; name, thunk from a port and a kons, expected outcome
  (list
   (list "seq without REPORT: read-json-sequence"
         (lambda (p k) (read-json-sequence p (o 'stream 'seq)))
         (violates 'read-json-sequence))
   (list "seq with #f for REPORT: read-json-sequence"
         (lambda (p k) (read-json-sequence p #f (o 'stream 'seq)))
         (violates 'read-json-sequence))
   (list "seq without REPORT: fold-json-sequence"
         (lambda (p k) (fold-json-sequence k 0 p (o 'stream 'seq)))
         (violates 'fold-json-sequence))
   (list "seq with #f for REPORT: fold-json-sequence"
         (lambda (p k) (fold-json-sequence k 0 p #f (o 'stream 'seq)))
         (violates 'fold-json-sequence))
   (list "values with REPORT: read-json-sequence"
         (lambda (p k) (read-json-sequence p report-proc (o 'stream 'values)))
         (violates 'read-json-sequence report-proc))
   (list "values with REPORT: fold-json-sequence"
         (lambda (p k) (fold-json-sequence k 0 p report-proc (o 'stream 'values)))
         (violates 'fold-json-sequence report-proc))))

;; The stream holds good records in either format, so a procedure that
;; failed to refuse would read them.
(for-each
 (lambda (row)
   (let* ((cp (counted-port (u "\x1e;1\n\x1e;2\n")))
          (konses 0)
          (r (outcome (lambda ()
                        ((cadr row) (car cp) (lambda (v acc) (set! konses (+ konses 1)) acc))))))
     (chk (car row) (list (caddr row) 0 0) (list r ((cdr cp)) konses))))
 seq-refusal-rows)

(chk "seq without REPORT, and values with one: bytevector->json-sequence"
     (list (violates 'bytevector->json-sequence)
           (violates 'bytevector->json-sequence)
           (violates 'bytevector->json-sequence report-proc))
     (list (outcome (lambda () (bytevector->json-sequence (u "\x1e;1\n") (o 'stream 'seq))))
           (outcome (lambda () (bytevector->json-sequence (u "\x1e;1\n") #f (o 'stream 'seq))))
           (outcome (lambda () (bytevector->json-sequence (u "1 2 ") report-proc (o 'stream 'values))))))

;; A REPORT that is neither a procedure nor #f.
(for-each
 (lambda (how)
   (for-each
    (lambda (bad)
      (chk (nm "REPORT that is not a procedure" (symbol->string how) (car bad))
           (list (violates (who-of how) (cdr bad)) (violates (who-of how) (cdr bad)))
           (list (outcome (lambda () (call how (u "1\n") (list (cdr bad)))))
                 (outcome (lambda () (call how (u "1\n") (list (cdr bad) (o))))))))
    (list (cons "number" 5) (cons "string" "report") (cons "symbol" (quote report)) (cons "list" (list 1)))))
 hows)

;; --- 4. Ports ------------------------------------------------------------------

;; Values go on as their records arrive: a port gives one whole line a call
;; and logs each call; KONS logs each value. The joint log interleaves.
(define (interleaved fmt texts sizes opts)
  (let ((log '()))
    (define (note! x) (set! log (cons x log)))
    (let* ((bv (frame fmt texts))
           (p (chunk-port bv sizes (lambda (n) (note! (list 'read n)))))
           (args (if (eq? fmt 'seq) (list (lambda (c) (note! 'skip)) opts) (list opts)))
           (r (apply fold-json-sequence (lambda (v acc) (note! (list 'value v)) (+ acc 1)) 0 p args)))
      (list r (reverse log)))))

(chk "ports: lines arrive as their records do"
     (list 3 '((read 2) (value 1) (read 2) (value 2) (read 2) (value 3) (read 0)))
     (interleaved 'lines '("1" "2" "3") '(2) (o)))
;; A record comes at its newline: reads of 3 bytes hold "[1]" and "\n" apart.
(chk "ports: a record arrives when its newline does"
     (list 2 '((read 3) (read 1) (value #(1)) (read 3) (read 1) (value #(2)) (read 0)))
     (interleaved 'lines '("[1]" "[2]") '(3 1) (o)))
;; seq: a record ends at the next RS, so value n waits for read n+1.
;; RS 1 \n is 3 bytes.
(chk "ports: seq records arrive at the next RS"
     (list 3 '((read 3) (read 3) (value 1) (read 3) (value 2) (read 0) (value 3)))
     (interleaved 'seq '("1" "2" "3") '(3) (o 'stream 'seq)))
;; values: an array is announced at its ], with its space not yet read.
(chk "ports: values arrive as they complete"
     (list 3 '((read 4) (value #(1)) (read 4) (value #(2)) (read 4) (value #(3)) (read 0)))
     (interleaved 'values '("[1]" "[2]" "[3]") '(4) (o 'stream 'values)))
;; And the numbers: 1, space 3, and the space ends the number.
(chk "ports: values numbers arrive at their whitespace"
     (list 3 '((read 3) (value 11) (read 3) (value 22) (read 3) (value 33) (read 0)))
     (interleaved 'values '("11" "22" "33") '(3) (o 'stream 'values)))

;; An error stops the reading at once: the lines after the bad one are not
;; read from the port. Reads of 2, 3, 2, 2 bytes: "1\n", "[x\n", "3\n", "4\n".
(chk "ports: an error ends the reading where it is found"
     (list (rrec 'unexpected-byte 3 2 'read-json-sequence "unexpected-byte at byte 3 in record 2")
           '(2 3)
           (rrec 'unexpected-byte 3 2 'fold-json-sequence "unexpected-byte at byte 3 in record 2")
           '(2 3))
     (let* ((log '()) (note (lambda (n) (set! log (cons n log))))
            (r1 (outcome (lambda () (read-json-sequence (chunk-port (u "1\n[x\n3\n4\n") '(2 3 2 2) note)))))
            (l1 (reverse log))
            (_ (set! log '()))
            (r2 (outcome (lambda () (fold-json-sequence cons '() (chunk-port (u "1\n[x\n3\n4\n") '(2 3 2 2) note)))))
            (l2 (reverse log)))
       (list r1 l1 r2 l2)))
;; ... and so does a REPORT that raises.
(chk "ports: a REPORT that raises ends the reading where it is"
     (list #t '(2 3))
     (let* ((log '())
            (got (guard (e (#t e))
                   (read-json-sequence (chunk-port (u "1\n[x\n3\n4\n") '(2 3 2 2) (lambda (n) (set! log (cons n log))))
                                       (lambda (c) (raise c))))))
       (list (l:json-record-error? got) (reverse log))))

;; A port giving one byte a read: read count is the length plus the EOF.
(let ((reads 0))
  (chk "ports: one byte per read, every byte taken, once"
       (list (returned '(1 "a" #(2 3))) 13)
       (let* ((bv (u "1\n\"a\"\n[2,3]\n"))
              (p (chunk-port bv '(1) (lambda (n) (set! reads (+ reads 1)))))
              (r (outcome (lambda () (read-json-sequence p)))))
         (list r reads))))

;; A stream longer than the port's buffer, with records across the boundary.
(define (records n)
  ;; N lines `[i,"abc"]`
  (let loop ((i n) (acc '()))
    (if (= i 0)
        acc
        (loop (- i 1) (cons (string-append "[" (number->string i) ",\"abc\"]") acc)))))
(define (records-want n)
  (let loop ((i n) (acc '()))
    (if (= i 0) acc (loop (- i 1) (cons (vector i "abc") acc)))))

(let* ((texts (records 3000))
       (bv (frame 'lines texts))
       (want (records-want 3000))
       (len (bytevector-length bv)))
  (unless (> len 30000) (error (quote test-easy-sequence) "the long stream is too short to cross a buffer" len))
  (chk "long stream: read from a bytevector port"
       (returned want)
       (outcome (lambda () (read-json-sequence (open-bytevector-input-port bv)))))
  (chk "long stream: through a port giving odd sized chunks"
       (returned want)
       (outcome (lambda () (read-json-sequence (chunk-port bv '(4093 1 8191 7 16385 3) noop)))))
  (chk "long stream: fold, through odd chunks"
       (returned want)
       (outcome (lambda () (reverse (fold-json-sequence cons '() (chunk-port bv '(4093 1 8191 7 16385 3) noop))))))
  (chk "long stream: seq through odd chunks"
       (list (returned want) '())
       (let ((skips '()))
         (let ((r (outcome (lambda ()
                             (read-json-sequence (chunk-port (frame 'seq texts) '(4093 1 8191 7 16385 3) noop)
                                                 (lambda (c) (set! skips (cons c skips)))
                                                 (o 'stream 'seq))))))
           (list r (reverse skips)))))
  (chk "long stream: values through odd chunks"
       (list (returned want) '())
       (list (outcome (lambda ()
                        (read-json-sequence (chunk-port (frame 'values texts) '(4093 1 8191 7 16385 3) noop)
                                            (o 'stream 'values))))
             '()))
  ;; A bad record after 3000 good ones: its offset is the length of those
  ;; bytes, plus the [ and x.
  (chk "long stream: an error late in it, offset from the stream's start"
       (rrec 'unexpected-byte (+ len 1) 3001 'read-json-sequence
             (string-append "unexpected-byte at byte " (number->string (+ len 1)) " in record 3001"))
       (let ((bad (u (string-append (utf8->string bv) "[x\n"))))
         (outcome (lambda () (read-json-sequence (chunk-port bad '(4093 1 8191 7 16385 3) noop))))))
  (chk "long stream: the same error from a bytevector"
       (rrec 'unexpected-byte (+ len 1) 3001 'bytevector->json-sequence
             (string-append "unexpected-byte at byte " (number->string (+ len 1)) " in record 3001"))
       (outcome (lambda () (bytevector->json-sequence (u (string-append (utf8->string bv) "[x\n")))))))

;; One record longer than a whole read: a 40000 byte string between others.
(let* ((long (make-string 40000 #\q))
       (bv (u (string-append "1\n\"" long "\"\n2\n"))))
  (chk "long record: a record across several reads"
       (list (returned (list 1 long 2)) (returned (list 1 long 2)))
       (list (outcome (lambda () (read-json-sequence (open-bytevector-input-port bv))))
             (outcome (lambda () (read-json-sequence (chunk-port bv '(9000 1 777) noop)))))))

;; Re-entrancy: KONS reads other streams, mid-read, with the same procedures
;; and other options. A reader or buffer shared at module level would be
;; overwritten.
(define (inner-bytes) (bytevector->json-sequence (u "[10,20]\n[30]\n")))
(define (inner-fold)
  (fold-json-sequence (lambda (v acc) (cons v acc)) '()
                      (chunk-port (u "\x1e;\"p\"\n\x1e;\"q\"\n") '(2) noop)
                      (lambda (c) #f) (o 'stream 'seq)))
(define (inner-values)
  (norm-list (read-json-sequence (open-bytevector-input-port (u "7 8 [9] "))
                                 (o 'stream 'values 'number-mode 'text))))
(define (inner-error)
  (guard (e ((l:json-record-error? e) (cond-list e)))
    (bytevector->json-sequence (u "5\n6\n[x\n"))))

(define inner-want
  (list '(#(10 20) #(30))
        '("q" "p")
        '((num "7") (num "8") #((num "9")))
        (skipped 'unexpected-byte 5 3 'bytevector->json-sequence
                 "unexpected-byte at byte 5 in record 3")))

(let* ((log '())
       (r (fold-json-sequence
           (lambda (v acc)
             (set! log (cons (cons (norm v) (list (inner-bytes) (inner-fold) (inner-values) (inner-error)))
                             log))
             (cons (norm v) acc))
           '()
           (chunk-port (u "1\n\"two\"\n[3]\n") '(1 2) noop))))
  (chk "re-entrancy: KONS reads other streams mid-read"
       (list '(#(3) "two" 1)
             (list (cons 1 inner-want) (cons "two" inner-want) (cons '#(3) inner-want)))
       (list r (reverse log))))

;; The same, with the outer stream bytes, and the inner ones reading while the
;; outer REPORT is called.
(let* ((log '())
       (r (bytevector->json-sequence
           (u "1\n[x\n3\n")
           (lambda (c) (set! log (cons (list (cond-list c) (inner-bytes) (inner-values)) log))))))
  (chk "re-entrancy: REPORT reads other streams mid-read"
       (list '(1 3)
             (list (list (skipped 'unexpected-byte 3 2 'bytevector->json-sequence
                                  "unexpected-byte at byte 3 in record 2")
                         '(#(10 20) #(30))
                         '((num "7") (num "8") #((num "9"))))))
       (list r (reverse log))))

;; Two levels deep, outer values, with the same inner stream every time.
(chk "re-entrancy: two levels deep"
     '((2 (("y" (1 2)) (#("x") (1 2)))) (1 (("y" (1 2)) (#("x") (1 2)))))
     (fold-json-sequence
      (lambda (v acc)
        (cons (list v (fold-json-sequence
                       (lambda (w a) (cons (list w (bytevector->json-sequence (u "1\n2\n"))) a))
                       '()
                       (open-bytevector-input-port (u "[\"x\"]\n\"y\"\n"))))
              acc))
      '()
      (open-bytevector-input-port (u "1 2 "))
      (o 'stream 'values)))

;; From a port's own read procedure, mid-read: each of its 7 calls (6 bytes
;; and the EOF) reads another stream.
(let* ((mid '())
       (p (chunk-port (u "1\n2\n3\n") '(1)
                      (lambda (n) (set! mid (cons (bytevector->json-sequence (u "[0]\n")) mid)))))
       (r (read-json-sequence p)))
  (chk "re-entrancy: a port that reads another stream on every read"
       (list '(1 2 3) (make-list 7 '(#(0))))
       (list r mid)))

;; What the caller's code raises passes through, not relabelled.
(define mine
  (condition (l:make-json-error 'mine 99)
             (make-who-condition 'my-who)
             (make-message-condition "my message")
             (make-irritants-condition '(my irritant))))

(chk "pass-through: a KONS raising a &json-error"
     (list #t (list 'mine 99 #f 'my-who "my message" '(my irritant)))
     (let ((got (guard (e (#t e))
                  (fold-json-sequence (lambda (v acc) (raise mine)) 0
                                      (open-bytevector-input-port (u "1\n2\n"))))))
       (list (eq? got mine)
             (list (l:json-error-reason got) (l:json-error-offset got) (l:json-record-error? got)
                   (condition-who got) (condition-message got) (condition-irritants got)))))
(chk "pass-through: a KONS raising, through each reader's stream"
     (list #t #t)
     (list (eq? mine (guard (e (#t e))
                       (fold-json-sequence (lambda (v acc) (raise mine)) 0
                                           (open-bytevector-input-port (u "1 2 "))
                                           (o 'stream 'values))))
           (eq? mine (guard (e (#t e))
                       (fold-json-sequence (lambda (v acc) (raise mine)) 0
                                           (open-bytevector-input-port (u "\x1e;1\n"))
                                           (lambda (c) #f) (o 'stream 'seq))))))
(chk "pass-through: a REPORT raising its own &json-error"
     (list #t (list 'mine 99 #f 'my-who "my message" '(my irritant)))
     (let ((got (guard (e (#t e))
                  (bytevector->json-sequence (u "1\n[x\n3\n") (lambda (c) (raise mine))))))
       (list (eq? got mine)
             (list (l:json-error-reason got) (l:json-error-offset got) (l:json-record-error? got)
                   (condition-who got) (condition-message got) (condition-irritants got)))))
(chk "pass-through: a REPORT raising its own, through a port"
     #t
     (eq? mine (guard (e (#t e))
                 (read-json-sequence (chunk-port (u "1\n[x\n3\n") '(2 3 2) noop)
                                     (lambda (c) (raise mine))))))
;; A port whose read procedure raises passes its error through too.
(chk "pass-through: a port's read procedure raising a &json-error"
     #t
     (eq? mine (guard (e (#t e))
                 (read-json-sequence
                  (make-custom-binary-input-port "raises" (lambda (bv s c) (raise mine)) #f #f #f)))))

;; --- 5. Writing ----------------------------------------------------------------

(define (written vs . opts)
  (let-values (((p get) (open-bytevector-output-port)))
    (write-json-sequence p vs (apply o opts))
    (bytevector->u8-list (get))))
(define (written-bv vs . opts)
  (bytevector->u8-list (json-sequence->bytevector vs (apply o opts))))

(define vals
  (list "\x3b1;" "a\nb" "c\rd" "e\x1e;f" "\xFEFF;g" 1 (vector 1 2) '(("k" . #t)) 'null))

;; Alpha is CE B1, U+FEFF is EF BB BF, U+001E is written as \u001e.
(define lines-bytes
  (b "\"" #xCE #xB1 "\"\n"
     "\"a\\nb\"\n"
     "\"c\\rd\"\n"
     "\"e\\u001ef\"\n"
     "\"" #xEF #xBB #xBF "g\"\n"
     "1\n[1,2]\n{\"k\":true}\nnull\n"))
(define seq-bytes
  (b 30 "\"" #xCE #xB1 "\"\n"
     30 "\"a\\nb\"\n"
     30 "\"c\\rd\"\n"
     30 "\"e\\u001ef\"\n"
     30 "\"" #xEF #xBB #xBF "g\"\n"
     30 "1\n" 30 "[1,2]\n" 30 "{\"k\":true}\n" 30 "null\n"))

(chk "writing: lines, bytes"
     (list lines-bytes lines-bytes)
     (list (written vals 'stream 'lines) (written-bv vals 'stream 'lines)))
(chk "writing: values, bytes (compact, a newline after each)"
     (list lines-bytes lines-bytes)
     (list (written vals 'stream 'values) (written-bv vals 'stream 'values)))
(chk "writing: seq, bytes (RS before each)"
     (list seq-bytes seq-bytes)
     (list (written vals 'stream 'seq) (written-bv vals 'stream 'seq)))
(chk "writing: the default is lines, through the short forms"
     (list (b "1\n\"a\"\n[true]\n") (b "1\n\"a\"\n[true]\n"))
     (let-values (((p get) (open-bytevector-output-port)))
       (write-json-sequence p (list 1 "a" (vector #t)))
       (list (bytevector->u8-list (get))
             (bytevector->u8-list (json-sequence->bytevector (list 1 "a" (vector #t)))))))
(chk "writing: no values writes nothing, in each format"
     (make-list 6 '())
     (list (written '()) (written-bv '())
           (written '() 'stream 'seq) (written-bv '() 'stream 'seq)
           (written '() 'stream 'values) (written-bv '() 'stream 'values)))

;; indent 2 under seq and values: the record spans lines.
(define indent-vals (list "\x3b1;" (vector 1 2) '(("k" . #t)) (vector) '()))
(define indent-seq
  (b 30 "\"" #xCE #xB1 "\"\n"
     30 "[\n  1,\n  2\n]\n"
     30 "{\n  \"k\": true\n}\n"
     30 "[]\n"
     30 "{}\n"))
(define indent-values
  (b "\"" #xCE #xB1 "\"\n"
     "[\n  1,\n  2\n]\n"
     "{\n  \"k\": true\n}\n"
     "[]\n"
     "{}\n"))
(chk "writing: indent 2 under seq"
     (list indent-seq indent-seq)
     (list (written indent-vals 'stream 'seq 'indent 2)
           (written-bv indent-vals 'stream 'seq 'indent 2)))
(chk "writing: indent 2 under values"
     (list indent-values indent-values)
     (list (written indent-vals 'stream 'values 'indent 2)
           (written-bv indent-vals 'stream 'values 'indent 2)))
(chk "writing: null and the number mode reach the writer"
     (list (b "null\n") (b "null\n"))
     (list (written (list 'nil) 'null 'nil) (written-bv (list 'nil) 'null 'nil)))

;; indent above 0 under lines raises an assertion violation: the easy
;; procedure's who, and nothing written, not even for no values.
(chk "writing: indent under lines is refused, nothing written"
     (list (violates 'write-json-sequence 2) "pre"
           (violates 'write-json-sequence 3) "pre"
           (violates 'json-sequence->bytevector 2)
           (violates 'json-sequence->bytevector 1))
     (let-values (((p get) (open-bytevector-output-port)))
       (put-bytevector p (u "pre"))
       (let* ((r1 (outcome (lambda () (write-json-sequence p (list 1 2) (o 'indent 2)))))
              (a (utf8->string (get)))
              (_ (put-bytevector p (u "pre")))
              (r2 (outcome (lambda () (write-json-sequence p '() (o 'indent 3)))))
              (c (utf8->string (get))))
         (list r1 a r2 c
               (outcome (lambda () (json-sequence->bytevector (list 1) (o 'indent 2))))
               (outcome (lambda () (json-sequence->bytevector '() (o 'indent 1))))))))

;; A refused value raises with the easy procedure's who, and the reason,
;; message and irritants put-json-record gives, offset #f.
(define key-table (let ((h (make-eqv-hashtable))) (hashtable-set! h 1 "x") h))
(define improper-alist (cons (cons "a" 1) 5))
(define refusals
  ;; value, options, reason, message, irritants
  (list
   (list 1/3 '() 'unwritable-number "a number JSON can't express" (list 1/3))
   (list 'sym '() 'unwritable-value "a value JSON can't express" (list 'sym))
   (list key-table '() 'unwritable-key "an object's key is not a string" (list 1))
   (list (vector (vector 1)) '(depth-limit 1) 'nesting-too-deep
         "more arrays and objects open at once than depth-limit" (list (vector 1)))
   (list improper-alist '() 'unwritable-value
         "a list that is not an alist: it is improper or circular" (list improper-alist))
   (list +inf.0 '(stream seq) 'unwritable-number "a number JSON can't express" (list +inf.0))
   (list (vector 'null) '(null nil stream values) 'unwritable-value "a value JSON can't express"
         (list 'null))))

(define ri 0)
(for-each
 (lambda (row)
   (set! ri (+ ri 1))
   (let* ((v (car row)) (opts (apply o (cadr row))) (reason (caddr row))
          (message (cadddr row)) (irritants (list-ref row 4))
          (want (lambda (who) (list 'raised reason #f who message irritants #t #f))))
     (chk (nm "refused value: put-json-record" (number->string ri) (symbol->string reason))
          (want 'put-json-record)
          (outcome (lambda ()
                     (let-values (((p get) (open-bytevector-output-port)))
                       (put-json-record p v opts)))))
     (chk (nm "refused value: write-json-sequence" (number->string ri) (symbol->string reason))
          (want 'write-json-sequence)
          (outcome (lambda ()
                     (let-values (((p get) (open-bytevector-output-port)))
                       (write-json-sequence p (list v) opts)))))
     (chk (nm "refused value: json-sequence->bytevector" (number->string ri) (symbol->string reason))
          (want 'json-sequence->bytevector)
          (outcome (lambda () (json-sequence->bytevector (list v) opts))))))
 refusals)

;; write-json-sequence writes the records before a refused value, and
;; nothing of its record, nor of any after it.
(chk "write-json-sequence: records before a refused value stay written (lines)"
     (list (raised 'unwritable-number #f 'write-json-sequence "a number JSON can't express" 1/3)
           (b "pre" "1\n\"a\"\n"))
     (let-values (((p get) (open-bytevector-output-port)))
       (put-bytevector p (u "pre"))
       (let ((r (outcome (lambda () (write-json-sequence p (list 1 "a" 1/3 2))))))
         (list r (bytevector->u8-list (get))))))
(chk "write-json-sequence: records before a refused value stay written (seq)"
     (list (raised 'unwritable-value #f 'write-json-sequence "a value JSON can't express" 'sym)
           (b 30 "1\n" 30 "\"a\"\n"))
     (let-values (((p get) (open-bytevector-output-port)))
       (let ((r (outcome (lambda () (write-json-sequence p (list 1 "a" 'sym 2) (o 'stream 'seq))))))
         (list r (bytevector->u8-list (get))))))
(chk "write-json-sequence: a refusal at the first value writes nothing"
     (list #t '())
     (let-values (((p get) (open-bytevector-output-port)))
       (let ((r (outcome (lambda () (write-json-sequence p (list 1/3 1) (o 'stream 'seq))))))
         (list (eq? (car r) 'raised) (bytevector->u8-list (get))))))

;; A refusal deep inside a value writes nothing of its record: the records
;; before stay, and no [ or comma of the refused one.
(chk "write-json-sequence: a refusal inside a container writes nothing of the record"
     (list (raised 'unwritable-number #f 'write-json-sequence "a number JSON can't express" 1/3)
           (b "1\n")
           (raised 'unwritable-number #f 'write-json-sequence "a number JSON can't express" 1/3)
           (b 30 "1\n"))
     (let ((run (lambda (opts)
                  (let-values (((p get) (open-bytevector-output-port)))
                    (let ((r (outcome (lambda () (write-json-sequence p (list 1 (vector 2 (list (cons "k" (vector 3 1/3)))) 4) opts)))))
                      (list r (bytevector->u8-list (get))))))))
       (append (run (o)) (run (o 'stream 'seq)))))

;; A port that raises a &json-error from its write procedure: it comes out
;; eq?, not relabelled. A value bigger than the buffer makes write! run.
(define big-string (make-string 100000 #\a))
(define (port-raising thunk)
  (make-custom-binary-output-port "raising" (lambda (bv start count) (thunk) count) #f #f #f))
(chk "pass-through: write-json-sequence, a port raising a &json-error"
     (list #t (list 'mine 99 #f 'my-who "my message" '(my irritant)))
     (let ((got (guard (e (#t e))
                  (write-json-sequence (port-raising (lambda () (raise mine)))
                                       (list 1 big-string 2)))))
       (list (eq? got mine)
             (list (l:json-error-reason got) (l:json-error-offset got) (l:json-record-error? got)
                   (condition-who got) (condition-message got) (condition-irritants got)))))
(chk "pass-through: write-json-sequence, a port raising a record error from a reader"
     (list #f 'unexpected-byte 'bytevector->json-sequence)
     (let ((got (guard (e (#t e))
                  (write-json-sequence
                   (port-raising (lambda () (bytevector->json-sequence (u "x\n"))))
                   (list big-string) (o 'stream 'seq)))))
       (list (eq? got mine) (l:json-error-reason got) (condition-who got))))
(chk "pass-through: a port's other condition passes through"
     '(other-condition)
     (outcome (lambda ()
                (write-json-sequence (port-raising (lambda () (raise (make-i/o-write-error))))
                                     (list big-string)))))

;; A VALUES that is not a list: not a pair, improper, circular.
(define circular-values (let ((l (list 1 2))) (set-cdr! (cdr l) l) l))
(let loop ((bads (list 5 "str" #f (vector 1 2) (cons 1 2) (cons 1 (cons 2 3))))
           (i 0))
  (unless (null? bads)
    (let ((bad (car bads)))
      (chk (string-append "VALUES that is not a list, " (number->string i))
           (list (violates 'write-json-sequence bad) (violates 'json-sequence->bytevector bad))
           (let-values (((p get) (open-bytevector-output-port)))
             (list (outcome (lambda () (write-json-sequence p bad)))
                   (outcome (lambda () (json-sequence->bytevector bad)))))))
    (loop (cdr bads) (+ i 1))))
(chk "VALUES that is circular"
     (list (list 'violation 'write-json-sequence) (list 'violation 'json-sequence->bytevector))
     (let-values (((p get) (open-bytevector-output-port)))
       (list (who-only (outcome (lambda () (write-json-sequence p circular-values))))
             (who-only (outcome (lambda () (json-sequence->bytevector circular-values)))))))
(chk "VALUES that is not a list: the other arities, with options"
     (list (violates 'write-json-sequence 5) (violates 'json-sequence->bytevector 5))
     (let-values (((p get) (open-bytevector-output-port)))
       (list (outcome (lambda () (write-json-sequence p 5 (o 'stream 'seq))))
             (outcome (lambda () (json-sequence->bytevector 5 (o 'stream 'seq)))))))
(chk "VALUES: the empty list is a list"
     (list (returned (void)) (returned '()))
     (let-values (((p get) (open-bytevector-output-port)))
       (list (let ((r (outcome (lambda () (write-json-sequence p '())))))
               (if (eq? (car r) 'returned) (returned (void)) r))
             (returned (bytevector->u8-list (get))))))

;; --- 6. Round trips ------------------------------------------------------------

;; Includes the strings of section 5: newline, CR, RS, a leading U+FEFF.
(define trip-vals
  (list "\x3b1;\x3b2;" "a\nb" "c\rd" "e\x1e;f" "\xFEFF;g" "" 1 -2 1.5 (vector 1 (vector) '())
        '(("k" . #t) ("j" . #f)) 'null #f))

(for-each
 (lambda (fmt)
   (for-each
    (lambda (indent)
      (unless (and (eq? fmt 'lines) (> indent 0))
        (for-each
         (lambda (how)
           (chk (nm "round trip" (symbol->string fmt) (number->string indent) (symbol->string how))
                (list (returned trip-vals) '())
                (let ((wopt (o 'stream fmt 'indent indent)))
                  (read-fmt how fmt (json-sequence->bytevector trip-vals wopt)))))
         hows)
        ;; written to a port, then read back
        (chk (nm "round trip, written to a port" (symbol->string fmt) (number->string indent))
             (list (returned trip-vals) '())
             (let-values (((p get) (open-bytevector-output-port)))
               (write-json-sequence p trip-vals (o 'stream fmt 'indent indent))
               (read-fmt 'byte fmt (get))))))
    '(0 2)))
 formats)

;; --- 7. The one-document readers refuse stream values --------------------------

(chk "stream values is refused by the one-document readers"
     (list (list 'violation 'string->json) (list 'violation 'bytevector->json) (list 'violation 'read-json))
     (let ((v (o 'stream 'values)))
       (list (who-only (outcome (lambda () (string->json "[1]" v))))
             (who-only (outcome (lambda () (bytevector->json (u "[1]") v))))
             (who-only (outcome (lambda () (read-json (open-bytevector-input-port (u "[1]")) v)))))))
(for-each
 (lambda (fmt)
   (chk (nm "the one-document readers still read one document" (symbol->string fmt))
        (let ((r (returned (vector 1)))) (list r r r))
        (let ((v (o 'stream fmt)))
          (list (outcome (lambda () (string->json "[1]" v)))
                (outcome (lambda () (bytevector->json (u "[1]") v)))
                (outcome (lambda () (read-json (open-bytevector-input-port (u "[1]")) v)))))))
 '(lines seq))

;; --- 8. Arguments --------------------------------------------------------------

(define (text-in) (open-string-input-port "1\n"))
(define (bin-in) (open-bytevector-input-port (u "1\n")))
(define (bin-out) (let-values (((p get) (open-bytevector-output-port))) p))
(define (text-out) (let-values (((p get) (open-string-output-port))) p))

(define argument-cases
  ;; name, who, thunk
  (list
   (list "read-json-sequence: a textual port" 'read-json-sequence
         (lambda () (read-json-sequence (text-in))))
   (list "read-json-sequence: an output port" 'read-json-sequence
         (lambda () (read-json-sequence (bin-out))))
   (list "read-json-sequence: not a port" 'read-json-sequence
         (lambda () (read-json-sequence (u "1\n"))))
   (list "read-json-sequence: a textual port, with options" 'read-json-sequence
         (lambda () (read-json-sequence (text-in) (o))))
   (list "read-json-sequence: not options" 'read-json-sequence
         (lambda () (read-json-sequence (bin-in) #f 'options)))
   (list "read-json-sequence: not options, with a report" 'read-json-sequence
         (lambda () (read-json-sequence (bin-in) (lambda (c) #f) (vector))))
   (list "bytevector->json-sequence: a string" 'bytevector->json-sequence
         (lambda () (bytevector->json-sequence "1\n")))
   (list "bytevector->json-sequence: a port" 'bytevector->json-sequence
         (lambda () (bytevector->json-sequence (bin-in) (o))))
   (list "bytevector->json-sequence: not options" 'bytevector->json-sequence
         (lambda () (bytevector->json-sequence (u "1\n") #f 'options)))
   (list "bytevector->json-sequence: a list of bytes" 'bytevector->json-sequence
         (lambda () (bytevector->json-sequence (list 49 10))))
   (list "fold-json-sequence: KONS is not a procedure" 'fold-json-sequence
         (lambda () (fold-json-sequence 'cons '() (bin-in))))
   (list "fold-json-sequence: KONS is not a procedure, with options" 'fold-json-sequence
         (lambda () (fold-json-sequence 5 '() (bin-in) (o))))
   (list "fold-json-sequence: a textual port" 'fold-json-sequence
         (lambda () (fold-json-sequence cons '() (text-in))))
   (list "fold-json-sequence: an output port" 'fold-json-sequence
         (lambda () (fold-json-sequence cons '() (bin-out))))
   (list "fold-json-sequence: a bytevector" 'fold-json-sequence
         (lambda () (fold-json-sequence cons '() (u "1\n"))))
   (list "fold-json-sequence: not options" 'fold-json-sequence
         (lambda () (fold-json-sequence cons '() (bin-in) #f 'options)))
   (list "write-json-sequence: a textual port" 'write-json-sequence
         (lambda () (write-json-sequence (text-out) (list 1))))
   (list "write-json-sequence: an input port" 'write-json-sequence
         (lambda () (write-json-sequence (bin-in) (list 1))))
   (list "write-json-sequence: a bytevector" 'write-json-sequence
         (lambda () (write-json-sequence (u "") (list 1))))
   (list "write-json-sequence: not options" 'write-json-sequence
         (lambda () (write-json-sequence (bin-out) (list 1) 'options)))
   (list "json-sequence->bytevector: not options" 'json-sequence->bytevector
         (lambda () (json-sequence->bytevector (list 1) 'options)))
   (list "json-sequence->bytevector: not options, a record" 'json-sequence->bytevector
         (lambda () (json-sequence->bytevector (list 1) (make-i/o-write-error))))))

(for-each
 (lambda (row)
   (chk (car row)
        (list 'violation (cadr row))
        (let ((r (outcome (caddr row))))
          (list (car r) (cadr r)))))
 argument-cases)

;; The raw shape, irritants and all, of one violation each.
(chk "arguments: the raw violation, a textual port"
     (violates 'read-json-sequence "a port")
     (let* ((p (text-in))
            (r (outcome (lambda () (read-json-sequence p)))))
       (list (car r) (cadr r) (if (equal? (caddr r) (list p)) (list "a port") (caddr r)))))
(chk "arguments: the raw violation, options"
     (violates 'bytevector->json-sequence 'options)
     (outcome (lambda () (bytevector->json-sequence (u "1\n") #f 'options))))
(chk "arguments: the raw violation, KONS"
     (violates 'fold-json-sequence 'cons)
     (outcome (lambda () (fold-json-sequence 'cons '() (bin-in)))))
(chk "arguments: the raw violation, the writer's port"
     (violates 'write-json-sequence "")
     (let ((r (outcome (lambda () (write-json-sequence "" (list 1))))))
       r))

;; --- 9. Re-exports -------------------------------------------------------------

(chk "re-exports: the record error is (jsonparse error)'s"
     '(#t #t #t #t)
     (list (eq? json-record-error? l:json-record-error?)
           (eq? json-error-record l:json-error-record)
           (eq? (record-type-descriptor &json-record-error)
                (record-type-descriptor l:&json-record-error))
           (eq? (record-type-parent (record-type-descriptor &json-record-error))
                (record-type-descriptor l:&json-error))))

;; --- end -----------------------------------------------------------------------

(display "test-easy-sequence: ")
(display (- (real-time) started))
(display " ms; pass ")
(display (test-runner-pass-count runner))
(display " fail ")
(display (test-runner-fail-count runner))
(newline)

(exit (suite-exit-status runner))
