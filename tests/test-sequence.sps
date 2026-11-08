;;; tests/test-sequence.sps: the reader of (jsonparse sequence), and
;;; put-json-record of (jsonparse writer), held to ADR-0020 and, for the
;;; formats, to ADR-0014's table of what JSON Lines, NDJSON and RFC 7464 say.
;;;
;;; Every expectation is written by hand from the bytes. Non-ASCII bytes are
;;; written as numbers. A reader is judged by its whole event log: each value
;;; with the record number json-reader-record gave inside on-value, each skip
;;; as on-skip got it, then the final result and the record afterwards:
;;;   ((EVENT ...) STATUS CODE OFFSET RECORD)
;;; Anything that can raise runs through `outcome` or `play`, which tag what
;;; happened, so a raise never equals an expected #f.
;;;
;;; 1. lines. 2. Bad records under lines. 3. seq. 4. values.
;;; 5. Chunking: every stream above, split every way. 6. Records and results.
;;; 7. The procedures' contract (Decision 6). 8. Independence.
;;; 9. Options and defaults. 10. Arguments. 11. SRFI 180's five files.
;;; 12. put-json-record.
(import (rnrs)
        (only (chezscheme) real-time)
        (srfi :64)
        (jsonparse-testing)
        (jsonparse options)
        (jsonparse parser)
        (jsonparse sequence)
        (jsonparse error)
        (jsonparse string)
        (jsonparse writer))

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

(test-begin "sequence")

(define-syntax chk
  (syntax-rules ()
    ((_ name expected expr) (test-equal name expected expr))))

;; --- helpers -----------------------------------------------------------------

(define RS #x1E)

;; bv : (U String Byte) ... -> Bytevector
;; An ASCII string is its bytes; a number is one byte.
(define (bv . parts)
  (call-with-bytevector-output-port
   (lambda (p)
     (for-each (lambda (x)
                 (if (string? x) (put-bytevector p (string->utf8 x)) (put-u8 p x)))
               parts))))

(define (u s) (string->utf8 s))
(define (opts . args) (apply make-json-options args))

;; The three formats, each with options that are not the defaults where the
;; defaults would give the same values.
(define L (opts 'stream 'lines 'depth-limit 40 'digit-limit 50))
(define S (opts 'stream 'seq 'depth-limit 40 'digit-limit 50))
(define V (opts 'stream 'values 'depth-limit 40 'digit-limit 50))
(define LSKIP (opts 'stream 'lines 'blank-lines 'skip 'depth-limit 40 'digit-limit 50))

;; norm : Any -> Any
;; A value with hashtables as (table (key . value) ...) sorted by key, and
;; json-numbers as (num text), so that equal? compares it.
(define (norm v)
  (cond ((vector? v) (vector-map norm v))
        ((hashtable? v)
         (let-values (((ks vs) (hashtable-entries v)))
           (cons 'table
                 (list-sort (lambda (a b) (string<? (car a) (car b)))
                            (let loop ((i 0) (acc '()))
                              (if (= i (vector-length ks))
                                  acc
                                  (loop (+ i 1)
                                        (cons (cons (vector-ref ks i) (norm (vector-ref vs i)))
                                              acc))))))))
        ((pair? v) (map (lambda (m) (cons (car m) (norm (cdr m)))) v))
        ((json-number? v) (list 'num (json-number-text v)))
        (else v)))

;; outcome : (-> Any) -> (List ...)
;;   (returned VALUE)
;;   (raised REASON OFFSET WHO MESSAGE IRRITANTS)   a &json-error
;;   (violation WHO IRRITANTS)                      an assertion violation
;;   (other-condition)
(define (outcome thunk)
  (guard (e ((json-error? e)
             (list 'raised (json-error-reason e) (json-error-offset e)
                   (and (who-condition? e) (condition-who e))
                   (and (message-condition? e) (condition-message e))
                   (if (irritants-condition? e) (condition-irritants e) '())))
            ((assertion-violation? e)
             (list 'violation (and (who-condition? e) (condition-who e))
                   (if (irritants-condition? e) (condition-irritants e) '())))
            ((condition? e) (list 'other-condition)))
    (list 'returned (thunk))))

(define (violates who . irritants) (list 'violation who irritants))
(define (returned v) (list 'returned v))

;; res->list : json-result -> (List Symbol (Option Symbol) Integer)
(define (res->list res)
  (list (json-result-status res) (json-result-code res) (json-result-offset res)))

;; The expected end of a stream read: the events, then the final result and
;; the record number json-reader-record gives after it.
(define (ok events offset record) (list events 'finished #f offset record))
(define (bad events code offset record) (list events 'error code offset record))

;; --- schedules: how the bytes are fed -----------------------------------------
;; A schedule is a list of (BYTEVECTOR START END) feeds.

(define (whole b) (list (list b 0 (bytevector-length b))))

;; cut : Bytevector Index ... -> Schedule   split B at the ascending POINTS
(define (cut b . points)
  (let loop ((ps (append points (list (bytevector-length b)))) (i 0) (acc '()))
    (if (null? ps)
        (reverse acc)
        (loop (cdr ps) (car ps) (cons (list b i (car ps)) acc)))))

;; sized : Bytevector Positive-Integer -> Schedule   chunks of K bytes
(define (sized b k)
  (let ((len (bytevector-length b)))
    (let loop ((i 0) (acc '()))
      (if (>= i len)
          (reverse acc)
          (let ((e (min len (+ i k))))
            (loop e (cons (list b i e) acc)))))))

;; padded : Schedule -> Schedule
;; The same feeds, each from a fresh bytevector with 3 FF bytes before the
;; chunk and 2 after it, so a feed that ignores START or END reads them.
(define (padded sched)
  (let loop ((s sched) (acc '()))
    (if (null? s)
        (reverse acc)
        (let* ((c (car s))
               (n (- (caddr c) (cadr c)))
               (big (make-bytevector (+ n 5) #xFF)))
          (bytevector-copy! (car c) (cadr c) big 3 n)
          (loop (cdr s) (cons (list big 3 (+ 3 n)) acc))))))

;; --- the event log -------------------------------------------------------------

;; logged-reader : json-options Boolean -> (Vector json-reader (-> Log) (-> Void))
;; A reader that logs (v VALUE RECORD) for each value, RECORD being what
;; json-reader-record gave inside on-value, and (skip CODE RECORD OFFSET) for
;; each skip, with (inside N) added when json-reader-record inside on-skip
;; was not the RECORD it was handed.
(define (logged-reader o skip?)
  (let ((log '()))
    (letrec ((r (make-json-reader
                 (lambda (v)
                   (set! log (cons (list 'v (norm v) (json-reader-record r)) log)))
                 (and skip?
                      (lambda (c n off)
                        (set! log (cons (if (eqv? n (json-reader-record r))
                                            (list 'skip c n off)
                                            (list 'skip c n off 'inside (json-reader-record r)))
                                        log))))
                 o)))
      (vector r (lambda () (reverse log)) (lambda () (set! log '()))))))

(define (rig-reader rig) (vector-ref rig 0))
(define (rig-log rig) ((vector-ref rig 1)))
(define (rig-clear! rig) ((vector-ref rig 2)))

;; play : json-options Boolean Schedule -> (List Log Status Code Offset Record)
;; Feeds the schedule, finishes, and answers the log, the finish result and
;; json-reader-record. A raise is (play-raised TEXT).
(define (play o skip? schedule)
  (guard (e (#t (list 'play-raised (describe e))))
    (let* ((rig (logged-reader o skip?))
           (r (rig-reader rig)))
      (for-each (lambda (c) (json-reader-feed! r (car c) (cadr c) (caddr c))) schedule)
      (let ((f (json-reader-finish! r)))
        (list (rig-log rig) (json-result-status f) (json-result-code f)
              (json-result-offset f) (json-reader-record r))))))

;; The streams the chunking section splits: every case! registers one.
(define cases '())

;; case! : String json-options Boolean Bytevector Expected -> Void
;; Reads B in one feed and checks the whole log.
(define (case! name o skip? b expected)
  (set! cases (cons (list name o skip? b expected) cases))
  (chk name expected (play o skip? (whole b))))

;; ===== 1. lines ===============================================================

(case! "lines / [JSONL] one value a line, the last line's \\n present"
       L #f (u "1\n2\n3\n")
       (ok '((v 1 1) (v 2 2) (v 3 3)) 6 4))

(case! "lines / [JSONL] the final \\n is optional"
       L #f (u "1\n2\n3")
       (ok '((v 1 1) (v 2 2) (v 3 3)) 5 4))

(case! "lines / [JSONL] a single line with no \\n"
       L #f (u "7")
       (ok '((v 7 1)) 1 2))

(case! "lines / values of every kind, one a line"
       L #f (u "null\ntrue\nfalse\n-1.5e2\n\"s\"\n[1,[2]]\n{\"a\":{\"b\":[]}}\n\"\\u00e9\"\n")
       (ok `((v null 1) (v #t 2) (v #f 3) (v -150.0 4) (v "s" 5) (v #(1 #(2)) 6)
             (v (("a" . (("b" . #())))) 7) (v "\xE9;" 8))
           59 9))

(case! "lines / [NDJSON] \\r\\n accepted: whitespace around a value is ignored"
       L #f (u "1\r\n2\r\n")
       (ok '((v 1 1) (v 2 2)) 6 3))

(case! "lines / [NDJSON] \\r\\n, the last line's \\n left out"
       L #f (u "1\r\n2\r")
       (ok '((v 1 1) (v 2 2)) 5 3))

(case! "lines / spaces and tabs around a value"
       L #f (u "  1\t \n\t[ 2 ]\t\n")
       (ok '((v 1 1) (v #(2) 2)) 14 3))

(case! "lines / a number ends at its newline: -1 then 0"
       L #f (u "-1\n0\n")
       (ok '((v -1 1) (v 0 2)) 5 3))

;; Blank lines, with no on-skip: the stream's error.
(case! "lines / [JSONL] a blank line is invalid: empty line, blank-line at its \\n"
       L #f (u "1\n\n2\n")
       (bad '((v 1 1)) 'blank-line 2 2))

(case! "lines / a blank line of spaces: blank-line at its \\n"
       L #f (u "1\n   \n2\n")
       (bad '((v 1 1)) 'blank-line 5 2))

(case! "lines / a blank line of one tab"
       L #f (u "1\n\t\n2\n")
       (bad '((v 1 1)) 'blank-line 3 2))

(case! "lines / a blank line of a lone \\r before its \\n"
       L #f (u "1\n\r\n2\n")
       (bad '((v 1 1)) 'blank-line 3 2))

(case! "lines / a blank last line, a lone \\r with no \\n: blank-line at the end"
       L #f (u "1\n\r")
       (bad '((v 1 1)) 'blank-line 3 2))

(case! "lines / a whitespace-only last line with no \\n: blank-line at the end"
       L #f (u "1\n  ")
       (bad '((v 1 1)) 'blank-line 4 2))

(case! "lines / a blank third line is record 3"
       L #f (u "1\n2\n\n3")
       (bad '((v 1 1) (v 2 2)) 'blank-line 4 3))

(case! "lines / a stream of one \\n: blank-line at 0, record 1"
       L #f (u "\n")
       (bad '() 'blank-line 0 1))

(case! "lines / a blank first line before a value"
       L #f (u "\n1\n")
       (bad '() 'blank-line 0 1))

;; Blank lines under 'blank-lines 'skip.
(case! "lines / [NDJSON] blank-lines skip: blank lines vanish, unreported, and still count"
       LSKIP #f (u "1\n\n  \n2\n")
       (ok '((v 1 1) (v 2 4)) 8 5))

(case! "lines / blank-lines skip: a whitespace-only last line with no \\n"
       LSKIP #f (u "1\n  ")
       (ok '((v 1 1)) 4 3))

(case! "lines / blank-lines skip: a stream of one \\n"
       LSKIP #f (u "\n")
       (ok '() 1 2))

(case! "lines / blank-lines skip: tab, lone \\r and empty lines, then a value"
       LSKIP #f (u "\t\n\r\n\n3\n")
       (ok '((v 3 4)) 7 5))

(case! "lines / blank-lines skip with on-skip: only the bad records are reported"
       LSKIP #t (u "1\n\n[x\n\n2")
       (ok '((v 1 1) (skip unexpected-byte 3 4) (v 2 5)) 8 6))

;; With on-skip and the default blank-lines: reported and skipped.
(case! "lines / on-skip, blank-lines error: a blank line is reported, then skipped"
       L #t (u "1\n\n2\n[x\n4\r\n  \n5")
       (ok '((v 1 1) (skip blank-line 2 2) (v 2 3) (skip unexpected-byte 4 6) (v 4 5)
             (skip blank-line 6 13) (v 5 7))
           15 8))

(case! "lines / on-skip: a stream of one \\n is a blank-line at 0"
       L #t (u "\n")
       (ok '((skip blank-line 1 0)) 1 2))

(case! "lines / on-skip: a blank last line with no \\n, reported at the end"
       L #t (u "1\n \t")
       (ok '((v 1 1) (skip blank-line 2 4)) 4 3))

;; A line holding only \x0B; or \x0C; is not blank: they are not JSON whitespace.
(case! "lines / a line of one VT is not blank: unexpected-byte"
       L #f (bv "1\n" #x0B "\n")
       (bad '((v 1 1)) 'unexpected-byte 2 2))

(case! "lines / a line of one FF is not blank: unexpected-byte"
       L #f (bv "1\n" #x0C "\n")
       (bad '((v 1 1)) 'unexpected-byte 2 2))

;; The byte order mark.
(case! "lines / [JSONL] a BOM at the start is an error: unexpected-byte at 0"
       L #f (bv #xEF #xBB #xBF "1\n2\n")
       (bad '() 'unexpected-byte 0 1))

(case! "lines / a BOM at a later line's start: unexpected-byte at its offset"
       L #f (bv "1\n" #xEF #xBB #xBF "2\n")
       (bad '((v 1 1)) 'unexpected-byte 2 2))

(case! "lines / a BOM at a later line's start, on-skip: that line is dropped"
       L #t (bv "1\n" #xEF #xBB #xBF "2\n3\n")
       (ok '((v 1 1) (skip unexpected-byte 2 2) (v 3 3)) 9 4))

(case! "lines / a BOM at the start, on-skip"
       L #t (bv #xEF #xBB #xBF "1\n2\n")
       (ok '((skip unexpected-byte 1 0) (v 2 2)) 7 3))

;; The empty stream.
(case! "lines / the empty stream: finished at 0, no values"
       L #f (bv)
       (ok '() 0 1))

;; A raw \n inside a string.
(case! "lines / a raw \\n inside a string ends the record: both halves are bad (on-skip)"
       L #t (u "[\"a\nb\"]\n")
       (ok '((skip unexpected-eof 1 3) (skip unexpected-byte 2 4)) 8 3))

(case! "lines / a raw \\n inside a string, no on-skip: the first half ends the stream"
       L #f (u "[\"a\nb\"]\n")
       (bad '() 'unexpected-eof 3 1))

;; ===== 2. bad records under lines ===============================================

;; A bad line between good ones: "1\n" BAD "\n3\n". Both ways.
(define (bad-line! label code off b)
  (case! (string-append "lines bad / " label ", no on-skip: the stream ends")
         L #f b (bad '((v 1 1)) code off 2))
  (case! (string-append "lines bad / " label ", on-skip: reading goes on")
         L #t b (ok `((v 1 1) (skip ,code 2 ,off) (v 3 3)) (bytevector-length b) 4)))

(bad-line! "unexpected-byte" 'unexpected-byte 2 (u "1\nx\n3\n"))
(bad-line! "unexpected-eof (an array cut short)" 'unexpected-eof 5 (u "1\n[1,\n3\n"))
(bad-line! "unexpected-eof (a lone minus)" 'unexpected-eof 3 (u "1\n-\n3\n"))
(bad-line! "invalid-number (01)" 'invalid-number 3 (u "1\n01\n3\n"))
(bad-line! "invalid-escape" 'invalid-escape 4 (u "1\n\"\\q\"\n3\n"))
(bad-line! "invalid-surrogate (a lone high surrogate)" 'invalid-surrogate 9 (u "1\n\"\\ud800\"\n3\n"))
(bad-line! "invalid-surrogate (a high surrogate then a non-low)" 'invalid-surrogate 15
           (u "1\n\"\\ud800\\u0041\"\n3\n"))
(bad-line! "invalid-utf8 (a truncated sequence)" 'invalid-utf8 4 (bv "1\n\"" #xC3 "\"\n3\n"))
(bad-line! "invalid-utf8 (a byte that starts nothing)" 'invalid-utf8 3 (bv "1\n\"" #xFF "\"\n3\n"))
(bad-line! "control-character (a raw tab in a string)" 'control-character 4 (u "1\n\"a\t\"\n3\n"))
(bad-line! "trailing-garbage (1 2)" 'trailing-garbage 4 (u "1\n1 2\n3\n"))
(bad-line! "trailing-garbage (an array then a bracket)" 'trailing-garbage 7 (u "1\n[1,2]]\n3\n"))
(bad-line! "unexpected-byte (an object missing its colon)" 'unexpected-byte 6 (u "1\n{\"a\"}\n3\n"))

;; bad-line-with! is bad-line!'s twin for other options.
(define (bad-line-with! label o code off b)
  (case! (string-append "lines bad / " label ", no on-skip")
         o #f b (bad '((v 1 1)) code off 2))
  (case! (string-append "lines bad / " label ", on-skip")
         o #t b (ok `((v 1 1) (skip ,code 2 ,off) (v 3 3)) (bytevector-length b) 4)))

;; The limits, with options that make each reachable.
(let ((o (opts 'stream 'lines 'depth-limit 2)))
  (case! "lines bad / nesting-too-deep under depth-limit 2, no on-skip"
         o #f (u "1\n[[1]]\n[[[1]]]\n[[[[x\n3\n")
         (bad '((v 1 1) (v #(#(1)) 2)) 'nesting-too-deep 11 3))
  (case! "lines bad / nesting-too-deep under depth-limit 2, on-skip: each record is a new parse"
         o #t (u "1\n[[1]]\n[[[1]]]\n[[[[x\n3\n")
         (ok '((v 1 1) (v #(#(1)) 2) (skip nesting-too-deep 3 11) (skip nesting-too-deep 4 19) (v 3 5))
             24 6)))

(let ((o (opts 'stream 'lines 'digit-limit 3)))
  (case! "lines bad / number-too-long under digit-limit 3, no on-skip"
         o #f (u "1\n123\n1234\n12.34\n3\n")
         (bad '((v 1 1) (v 123 2)) 'number-too-long 10 3))
  (case! "lines bad / number-too-long under digit-limit 3, on-skip: integer, fraction, exponent"
         o #t (u "1\n123\n1234\n12.34\n1e2345\n3\n")
         (ok '((v 1 1) (v 123 2) (skip number-too-long 3 10) (skip number-too-long 4 16)
               (skip number-too-long 5 23) (v 3 6))
             26 7)))

(let ((o (opts 'stream 'lines 'number-mode 'exact)))
  (bad-line-with! "number-out-of-range (1e99999999999 in exact mode)" o 'number-out-of-range 15
                  (u "1\n1e99999999999\n3\n")))

;; Where in the stream the bad record is.
(case! "lines bad / the first line is bad, no on-skip"
       L #f (u "x\n2\n3\n")
       (bad '() 'unexpected-byte 0 1))

(case! "lines bad / the first line is bad, on-skip"
       L #t (u "x\n2\n3\n")
       (ok '((skip unexpected-byte 1 0) (v 2 2) (v 3 3)) 6 4))

(case! "lines bad / the last line is bad, with its \\n, no on-skip"
       L #f (u "1\n2\nx\n")
       (bad '((v 1 1) (v 2 2)) 'unexpected-byte 4 3))

(case! "lines bad / the last line is bad, with its \\n, on-skip"
       L #t (u "1\n2\nx\n")
       (ok '((v 1 1) (v 2 2) (skip unexpected-byte 3 4)) 6 4))

(case! "lines bad / the last line is bad, with no \\n, no on-skip"
       L #f (u "1\n2\nx")
       (bad '((v 1 1) (v 2 2)) 'unexpected-byte 4 3))

(case! "lines bad / the last line is bad, with no \\n, on-skip"
       L #t (u "1\n2\nx")
       (ok '((v 1 1) (v 2 2) (skip unexpected-byte 3 4)) 5 4))

(case! "lines bad / the last line is cut short and found bad by finish, no on-skip"
       L #f (u "1\n[1,")
       (bad '((v 1 1)) 'unexpected-eof 5 2))

(case! "lines bad / the last line is cut short and found bad by finish, on-skip"
       L #t (u "1\n[1,")
       (ok '((v 1 1) (skip unexpected-eof 2 5)) 5 3))

;; A record found bad partway: its remaining bytes arrive in later feeds, and
;; are dropped. The dropped bytes would make more errors, or values, if read.
(chk "lines bad / a record bad partway: the rest, in later feeds, is dropped"
     (ok '((v 1 1) (skip unexpected-byte 2 2) (v 4 3)) 14 4)
     (let ((b (u "1\nx]]]]]]]]\n4\n")))
       (play L #t (cut b 3 5 9))))

(chk "lines bad / a record bad partway: dropped bytes that are a value, fed one at a time"
     (ok '((v 1 1) (skip unexpected-byte 2 2) (v 5 3)) 10 4)
     (let ((b (u "1\nx 2 3\n5\n")))
       (play L #t (sized b 1))))

(chk "lines bad / a record bad partway and the next line in the same feed as its end"
     (ok '((skip unexpected-byte 1 0) (v 7 2) (v 8 3)) 9 4)
     (let ((b (u "x...\n7\n8\n")))
       (play L #t (cut b 1 5))))

;; With no on-skip the error sticks.
(let ((b (u "1\nx\n3\n")))
  (chk "lines bad / no on-skip: the error sticks through further feeds and finish"
       (list '((v 1 1))
             '(error unexpected-byte 2)
             '(error unexpected-byte 2)
             '(error unexpected-byte 2)
             '(error unexpected-byte 2)
             2)
       (let* ((rig (logged-reader L #f)) (r (rig-reader rig))
              (a (res->list (json-reader-feed! r b 0 4)))
              (c (res->list (json-reader-feed! r b 4 6)))
              (d (res->list (json-reader-feed! r (u "5\n6\n"))))
              (f (res->list (json-reader-finish! r))))
         (list (rig-log rig) a c d f (json-reader-record r)))))

(let ((b (u "1\n[")))
  (chk "lines bad / no on-skip: an error found by finish sticks through a second finish and a feed"
       (list '((v 1 1))
             '(error unexpected-eof 3)
             '(error unexpected-eof 3)
             '(error unexpected-eof 3)
             2)
       (let* ((rig (logged-reader L #f)) (r (rig-reader rig))
              (fed (json-reader-feed! r b))
              (f1 (res->list (json-reader-finish! r)))
              (f2 (res->list (json-reader-finish! r)))
              (f3 (res->list (json-reader-feed! r (u "2\n")))))
         (list (rig-log rig) f1 f2 f3 (json-reader-record r)))))

(chk "lines bad / no on-skip: a feed after the error hands on no later value"
     (list '((v 1 1)) 'error)
     (let* ((rig (logged-reader L #f)) (r (rig-reader rig)))
       (json-reader-feed! r (u "1\nx\n"))
       (json-reader-feed! r (u "2\n3\n"))
       (list (rig-log rig) (json-result-status (json-reader-finish! r)))))

;; ===== 3. seq =====================================================================

(case! "seq / [RFC7464 2.1] a record after each RS"
       S #t (bv RS "1\n" RS "[2]\n" RS "\"s\"\n")
       (ok '((v 1 1) (v #(2) 2) (v "s" 3)) 13 4))

(case! "seq / [RFC7464 2.2] runs of RS make no empty records"
       S #t (bv RS RS RS "1\n" RS RS "2\n" RS RS RS)
       (ok '((v 1 1) (v 2 2)) 12 3))

(case! "seq / [RFC7464 3] RS bytes only: no records"
       S #t (bv RS RS RS)
       (ok '() 3 1))

(case! "seq / the empty stream"
       S #t (bv)
       (ok '() 0 1))

;; Bytes before the first RS.
(case! "seq / [RFC7464 2.1] a leading \\n before the first RS is one bad record at 0"
       S #t (bv "\n" RS "1\n")
       (ok '((skip unexpected-byte 1 0) (v 1 2)) 4 3))

(case! "seq / a BOM before the first RS is one bad record at 0"
       S #t (bv #xEF #xBB #xBF RS "1\n")
       (ok '((skip unexpected-byte 1 0) (v 1 2)) 6 3))

(case! "seq / a whole value before the first RS is one bad record at 0"
       S #t (bv "[1]" RS "2\n")
       (ok '((skip unexpected-byte 1 0) (v 2 2)) 6 3))

(case! "seq / a leading \\n and no RS at all"
       S #t (bv "\n")
       (ok '((skip unexpected-byte 1 0)) 1 2))

(case! "seq / a whole value and no RS at all"
       S #t (bv "[1]")
       (ok '((skip unexpected-byte 1 0)) 3 2))

(case! "seq / junk before the first RS, the RS then the value (facts)"
       S #t (bv "junk" RS "1\n")
       (ok '((skip unexpected-byte 1 0) (v 1 2)) 7 3))

;; Truncation: a number or a literal with no whitespace after it. Each is
;; tried at an RS and at the end of the input.
(define scalars
  ;; text, its value, its length
  '(("-1" -1) ("0" 0) ("9" 9) ("true" #t) ("false" #f) ("null" null) ("2.5" 2.5)))

(for-each
 (lambda (s)
   (let* ((text (car s)) (n (string-length text)))
     (case! (string-append "seq / [RFC7464 3] " text " at the end of the input is truncated at the end")
            S #t (bv RS text)
            (ok `((skip truncated 1 ,(+ 1 n))) (+ 1 n) 2))
     (case! (string-append "seq / [RFC7464 3] " text " at an RS is truncated at that RS")
            S #t (bv RS text RS "2\n")
            (ok `((skip truncated 1 ,(+ 1 n)) (v 2 2)) (+ n 4) 3))))
 scalars)

;; The same followed by one whitespace byte: a value.
(for-each
 (lambda (s)
   (let* ((text (car s)) (value (cadr s)) (n (string-length text)))
     (for-each
      (lambda (w)
        (let ((wname (car w)) (wb (cdr w)))
          (case! (string-append "seq / " text " then " wname " at the end of the input is a value")
                 S #t (bv RS text wb)
                 (ok `((v ,value 1)) (+ n 2) 2))
          (case! (string-append "seq / " text " then " wname " at an RS is a value")
                 S #t (bv RS text wb RS "2\n")
                 (ok `((v ,value 1) (v 2 2)) (+ n 5) 3))))
      '(("space" . 32) ("tab" . 9) ("LF" . 10) ("CR" . 13)))))
 scalars)

;; Leading whitespace is skipped to find the first byte that matters.
(for-each
 (lambda (w)
   (case! (string-append "seq / " (car w) " then 5, no whitespace after: truncated")
          S #t (bv RS (cdr w) "5")
          (ok '((skip truncated 1 3)) 3 2)))
 '(("space" . 32) ("tab" . 9) ("LF" . 10) ("CR" . 13)))

(case! "seq / the same bytes, trailing whitespace too: spaces around 4 are a value (facts)"
       S #t (bv RS " 4 ")
       (ok '((v 4 1)) 4 2))

;; Strings, arrays and objects need no whitespace after them.
(case! "seq / a string with no whitespace after it is a value"
       S #t (bv RS "\"s\"")
       (ok '((v "s" 1)) 4 2))

(case! "seq / an array with no whitespace after it is a value"
       S #t (bv RS "[1]" RS "[2]")
       (ok '((v #(1) 1) (v #(2) 2)) 8 3))

(case! "seq / an object with no whitespace after it is a value"
       S #t (bv RS "{}" RS "{\"a\":1}")
       (ok '((v () 1) (v (("a" . 1)) 2)) 11 3))

;; VT and FF are not whitespace, in or out of the framing.
(case! "seq / a number then VT is trailing-garbage at the VT, not a value"
       S #t (bv RS "5" #x0B)
       (ok '((skip trailing-garbage 1 2)) 3 2))

(case! "seq / a number then FF is trailing-garbage at the FF"
       S #t (bv RS "5" #x0C)
       (ok '((skip trailing-garbage 1 2)) 3 2))

;; Whitespace-only records.
(case! "seq / a whitespace-only record is unexpected-eof at its end (at an RS and at the end)"
       S #t (bv RS "  " RS "\n")
       (ok '((skip unexpected-eof 1 3) (skip unexpected-eof 2 5)) 5 3))

(case! "seq / a record of one VT is unexpected-byte, not whitespace"
       S #t (bv RS #x0B RS "1\n")
       (ok '((skip unexpected-byte 1 1) (v 1 2)) 5 3))

;; RFC 7464 section 3's warning.
(case! "seq / [RFC7464 3] \"foo\"\\n456\\n in one record is trailing-garbage at the 4"
       S #t (bv RS "\"foo\"\n456\n")
       (ok '((skip trailing-garbage 1 7)) 11 2))

;; A bad record partway: dropped up to the next RS.
(case! "seq / a record bad partway is dropped up to the next RS"
       S #t (bv RS "[1,x" "]]]]" RS "2\n")
       (ok '((skip unexpected-byte 1 4) (v 2 2)) 12 3))

(case! "seq / a bad record, then good ones, then a truncated one, then the end"
       S #t (bv RS "1\n" RS "[x" RS "2\n" RS "3")
       (ok '((v 1 1) (skip unexpected-byte 2 5) (v 2 3) (skip truncated 4 11)) 11 5))

(case! "seq / the facts' stream: values, truncations, whitespace, an unfinished array"
       S #t (bv RS "1\n" RS RS "[2]" RS "3" RS "true" RS "\"s\"" RS " 4 " RS "  " RS "[")
       (ok '((v 1 1) (v #(2) 2) (skip truncated 3 10) (skip truncated 4 15) (v "s" 5)
             (v 4 6) (skip unexpected-eof 7 26) (skip unexpected-eof 8 28))
           28 9))

;; The values themselves do not depend on the framing byte's neighbours.
(case! "seq / a nested value: depth-limit applies per record"
       (opts 'stream 'seq 'depth-limit 3) #t (bv RS "[[[1]]]\n" RS "[[[1]]]\n")
       (ok '((v #(#(#(1))) 1) (v #(#(#(1))) 2)) 18 3))

(chk "seq / make-json-reader without on-skip raises an assertion violation"
     (violates 'make-json-reader)
     (let ((o (outcome (lambda () (make-json-reader (lambda (v) v) S)))))
       (list (car o) (cadr o) '())))

;; ===== 4. values ====================================================================

(case! "values / [] {} \"\" with no space between"
       V #f (u "[]{}\"\"")
       (ok '((v #() 1) (v () 2) (v "" 3)) 6 4))

(case! "values / values one after another"
       V #f (u "1 [2] \"s\"{} null")
       (ok '((v 1 1) (v #(2) 2) (v "s" 3) (v () 4) (v null 5)) 16 6))

(case! "values / two objects touching"
       V #f (u "{\"a\":1}{\"b\":2}")
       (ok '((v (("a" . 1)) 1) (v (("b" . 2)) 2)) 14 3))

(case! "values / the last number ends at the end of the input"
       V #f (u "1 2")
       (ok '((v 1 1) (v 2 2)) 3 3))

(case! "values / the empty stream holds no values: finished at 0"
       V #f (bv)
       (ok '() 0 1))

(case! "values / a whitespace-only stream holds no values"
       V #f (u " \n\t")
       (ok '() 3 1))

(case! "values / 1-2: the 1 is handed on, then unexpected-byte at the minus, record 2"
       V #f (u "1-2")
       (bad '((v 1 1)) 'unexpected-byte 1 2))

(case! "values / truefalse: the true, then unexpected-byte at the f"
       V #f (u "truefalse")
       (bad '((v #t 1)) 'unexpected-byte 4 2))

(case! "values / 1\"a\": the 1, then unexpected-byte at the quote"
       V #f (u "1\"a\"")
       (bad '((v 1 1)) 'unexpected-byte 1 2))

(case! "values / 1 2x (ADR-0020 Consequences): 1 and 2, then the error at 3"
       V #f (u "1 2x")
       (bad '((v 1 1) (v 2 2)) 'unexpected-byte 3 3))

(case! "values / a value cut short: unexpected-eof at the end, record 1"
       V #f (u "[1")
       (bad '() 'unexpected-eof 2 1))

(case! "values / 1 then a value cut short"
       V #f (u "1 [2")
       (bad '((v 1 1)) 'unexpected-eof 4 2))

(case! "values / an error ends the stream: the values after it are not handed on"
       V #f (u "1 2 x 3")
       (bad '((v 1 1) (v 2 2)) 'unexpected-byte 4 3))

(let ((o (opts 'stream 'values)))
  (chk "values / an error sticks through a feed and a second finish"
       (list '((v 1 1)) '(error unexpected-byte 1) '(error unexpected-byte 1)
             '(error unexpected-byte 1) 2)
       (let* ((rig (logged-reader o #f)) (r (rig-reader rig))
              (a (res->list (json-reader-feed! r (u "1-"))))
              (b (res->list (json-reader-feed! r (u "2 3"))))
              (f (res->list (json-reader-finish! r))))
         (list (rig-log rig) a b f (json-reader-record r)))))

(chk "values / on-skip given under values raises an assertion violation"
     (list 'violation 'make-json-reader)
     (let ((o (outcome (lambda () (make-json-reader (lambda (v) v) (lambda (c n off) c) V)))))
       (list (car o) (cadr o))))

(chk "values / on-skip given under values, in the two-argument form, raises too"
     (list 'violation 'make-json-reader)
     (let ((o (outcome (lambda () (make-json-reader (lambda (v) v) (lambda (c n off) c))))))
       ;; two arguments with a procedure second is lines: it must NOT raise.
       (if (eq? (car o) 'returned) (list 'violation 'make-json-reader) o)))

;; ===== 5. chunking ====================================================================

;; Streams of all three formats, beyond those above, that stress the framing:
;; the bytes around \n, \r and RS, and bad records in skip mode.
(case! "chunk stream / lines: CRLF, blank, bad, BOM, good"
       L #t (bv "1\r\n\r\n[x\r\n" #xEF #xBB #xBF "\n 2 \t\r\n\"s\"")
       (ok '((v 1 1) (skip blank-line 2 4) (skip unexpected-byte 3 6) (skip unexpected-byte 4 9)
             (v 2 5) (v "s" 6))
           22 7))

(case! "chunk stream / lines: a bad record split mid-string, then good ones"
       L #t (u "[\"abc\ndef\"]\n{\"k\":[1,2]}\n")
       (ok '((skip unexpected-eof 1 5) (skip unexpected-byte 2 6) (v (("k" . #(1 2))) 3)) 24 4))

(case! "chunk stream / lines: blank-lines skip with a CRLF blank and a last line with no \\n"
       LSKIP #t (u "1\r\n\r\n2\r\n \r\n3")
       (ok '((v 1 1) (v 2 3) (v 3 5)) 12 6))

(case! "chunk stream / seq: runs of RS, truncated, whitespace, bad, string with escapes"
       S #t (bv "x" RS RS "10" RS "10\r\n" RS "[1" RS "\"a\\n\"" RS "-0\t")
       (ok '((skip unexpected-byte 1 0) (skip truncated 2 5) (v 10 3) (skip unexpected-eof 4 13)
             (v "a\n" 5) (v 0 6))
           23 7))

(case! "chunk stream / seq: a bad record whose rest holds LF and CR"
       S #t (bv RS "[1,x\n\r\n]" RS "7\n" RS "8")
       (ok '((skip unexpected-byte 1 4) (v 7 2) (skip truncated 3 14)) 14 4))

(case! "chunk stream / values: touching values, then a number touching a literal"
       V #f (u "[1]{\"a\":\"b\"}\"c\"1 2true null x")
       (bad '((v #(1) 1) (v (("a" . "b")) 2) (v "c" 3) (v 1 4) (v 2 5))
            'unexpected-byte 18 6))

(case! "chunk stream / values: touching values and a final error"
       V #f (u "[1]{\"a\":\"b\"}\"c\"1 2 true null x")
       (bad '((v #(1) 1) (v (("a" . "b")) 2) (v "c" 3) (v 1 4) (v 2 5) (v #t 6) (v null 7))
            'unexpected-byte 29 8))

(case! "chunk stream / values: whitespace of all four kinds between values"
       V #f (u "1\r\n2\t3 \n4")
       (ok '((v 1 1) (v 2 2) (v 3 3) (v 4 4)) 9 5))

;; Every stream registered so far is read under every split and every pair of
;; splits (for streams of at most 40 bytes), in chunks of 1, 2, 3 and 7, plain
;; and padded.
(define (chunking-mismatches name o skip? b expected)
  (let ((len (bytevector-length b))
        (bad-labels (quote ())) (ran 0))
    (define (try! label sched)
      (set! ran (+ ran 1))
      (let ((got (play o skip? sched)))
        (unless (equal? got expected)
          (set! bad-labels (cons (list label got) bad-labels)))))
    (do ((i 0 (+ i 1))) ((> i len))
      (try! (list 'split i) (cut b i))
      (try! (list 'padded-split i) (padded (cut b i)))
      (when (<= len 40)
        (do ((j i (+ j 1))) ((> j len))
          (try! (list 'pair i j) (cut b i j))
          (try! (list 'padded-pair i j) (padded (cut b i j))))))
    (for-each (lambda (k)
                (try! (list 'size k) (sized b k))
                (try! (list 'padded-size k) (padded (sized b k))))
              '(1 2 3 7))
    (cons ran (list-head* (reverse bad-labels) 2))))

(define (list-head* l n)
  (if (or (null? l) (= n 0)) '() (cons (car l) (list-head* (cdr l) (- n 1)))))

;; The positions of the framing bytes: \n, \r and RS.
(define (framing-positions b)
  (let loop ((i 0) (acc '()))
    (cond ((= i (bytevector-length b)) (reverse acc))
          ((memv (bytevector-u8-ref b i) '(10 13 #x1E)) (loop (+ i 1) (cons i acc)))
          (else (loop (+ i 1) acc)))))

;; The splits at each framing byte: before it (it starts a chunk), after it,
;; and on it (it alone in a chunk), each plain and padded.
(define (framing-mismatches name o skip? b expected)
  (let ((bad-labels '()) (ran 0))
    (define (try! label sched)
      (set! ran (+ ran 1))
      (let ((got (play o skip? sched)))
        (unless (equal? got expected)
          (set! bad-labels (cons (list label got) bad-labels)))))
    (for-each
     (lambda (p)
       (for-each (lambda (sched label)
                   (try! (list 'plain label p) sched)
                   (try! (list 'padded label p) (padded sched)))
                 (list (cut b p) (cut b (+ p 1)) (cut b p (+ p 1)))
                 '(before after on)))
     (framing-positions b))
    (cons ran (list-head* (reverse bad-labels) 2))))

(chk "chunking: framing-positions finds \\n, \\r and RS, by hand"
     '(1 2 4)
     (framing-positions (bv "1" 10 13 "x" RS "2")))

(chk "chunking: one stream with 3 framing bytes runs 3 * 3 * 2 = 18 splits"
     (cons 18 '())
     (let ((b (bv "1\r\n2\n")))
       (framing-mismatches "t" L #f b (play L #f (whole b)))))

(chk "chunking: one 6-byte stream runs 14 splits, 56 pairs and 8 sizes: 78 schedules"
     (cons 78 '())
     (let ((b (u "1\n2\n3\n")))
       (chunking-mismatches "t" L #f b (play L #f (whole b)))))

(let ((cs (reverse cases)))
  (chk "chunking: at least 20 streams, all three formats, bad records in skip mode among them"
       '(#t #t #t #t #t)
       (list (>= (length cs) 20)
             (exists (lambda (c) (eq? (json-options-stream (cadr c)) 'lines)) cs)
             (exists (lambda (c) (eq? (json-options-stream (cadr c)) 'seq)) cs)
             (exists (lambda (c) (eq? (json-options-stream (cadr c)) 'values)) cs)
             (exists (lambda (c)
                       (and (caddr c)
                            (exists (lambda (e) (eq? (car e) 'skip)) (car (list-ref c 4)))))
                     cs)))
  ;; Run each stream under every schedule; a failing name appears in the result.
  (let ((fails '()) (framing-ran 0) (chunk-ran 0))
    (for-each
     (lambda (c)
       (let ((name (car c)) (o (cadr c)) (skip? (caddr c)) (b (cadddr c)) (expected (list-ref c 4)))
         (let ((m (chunking-mismatches name o skip? b expected))
               (f (framing-mismatches name o skip? b expected)))
           (set! framing-ran (+ framing-ran (car f)))
           (set! chunk-ran (+ chunk-ran (car m)))
           (unless (null? (cdr m)) (set! fails (cons (list name 'splits (cdr m)) fails)))
           (unless (null? (cdr f)) (set! fails (cons (list name 'framing (cdr f)) fails))))))
     cs)
    (chk "chunking: no stream gives a different log under any split, pair of splits, size or padding"
         '()
         (reverse fails))
    (chk "chunking: the splits before, on and after every \\n, \\r and RS ran: 6 per framing byte, 2952 in all"
         2952
         framing-ran)
    (chk "chunking: every split, every pair of splits, and chunks of 1, 2, 3 and 7 ran: 26494 in all"
         26494
         chunk-ran)))

;; ===== 6. records and results =========================================================

(chk "records / inside on-value and on-skip, json-reader-record is the value's or the bad one's"
     (ok '((v 1 1) (skip blank-line 2 2) (skip unexpected-byte 3 3) (v 2 4)) 6 5)
     (play L #t (whole (u "1\n\nx\n2"))))

(chk "records / the record handed to on-skip is json-reader-record inside it (no `inside` mark)"
     '()
     (filter (lambda (e) (and (eq? (car e) 'skip) (> (length e) 4)))
             (car (play S #t (whole (bv "a" RS "[x" RS "1 " RS "-" RS ""))))))

(chk "records / that stream's events are what they are, so the filter above is not vacuous"
     (ok '((skip unexpected-byte 1 0) (skip unexpected-byte 2 3) (v 1 3) (skip unexpected-eof 4 9)) 10 5)
     (play S #t (whole (bv "a" RS "[x" RS "1 " RS "-" RS ""))))

(chk "records / after an error, json-reader-record is the bad record"
     '(error 3)
     (let* ((rig (logged-reader L #f)) (r (rig-reader rig)))
       (json-reader-feed! r (u "1\n2\nx\n4\n"))
       (list (json-result-status (json-reader-finish! r)) (json-reader-record r))))

(chk "records / after finished, one past the last (lines, seq, values)"
     '(4 4 4)
     (let ((one (lambda (o skip? b)
                  (let* ((rig (logged-reader o skip?)) (r (rig-reader rig)))
                    (json-reader-feed! r b)
                    (json-reader-finish! r)
                    (json-reader-record r)))))
       (list (one L #f (u "1\n2\n3"))
             (one S #t (bv RS "1\n" RS "2\n" RS "3\n"))
             (one V #f (u "1 2 3")))))

(chk "records / a new reader is at record 1"
     '(1 1 1)
     (list (json-reader-record (make-json-reader (lambda (v) v)))
           (json-reader-record (make-json-reader (lambda (v) v) (lambda (c n o) c) S))
           (json-reader-record (make-json-reader (lambda (v) v) V))))

;; After a reset: record 1, and the next stream reads as a fresh reader's does.
(define (after-reset-case! label o skip? before finish-before? after)
  (let* ((fresh (play o skip? (whole after)))
         (rig (logged-reader o skip?)) (r (rig-reader rig)))
    (json-reader-feed! r before)
    (when finish-before? (json-reader-finish! r))
    (json-reader-reset! r)
    (rig-clear! rig)
    (let* ((rec (json-reader-record r))
           (fed (json-reader-feed! r after))
           (f (json-reader-finish! r)))
      (chk (string-append "records / after a reset: " label)
           (list 1 fresh)
           (list rec (list (rig-log rig) (json-result-status f) (json-result-code f)
                           (json-result-offset f) (json-reader-record r)))))))

(after-reset-case! "lines, mid-record" L #t (u "1\n2\n[3") #f (u "4\nx\n5\n"))
(after-reset-case! "lines, after finished" L #t (u "1\n2\n") #t (u "4\nx\n5\n"))
(after-reset-case! "lines, after an error" L #f (u "1\nx\n") #t (u "4\n5\n"))
(after-reset-case! "seq, mid-record, a record bad" S #t (bv RS "1\n" RS "[1,x") #f (bv RS "4\n" RS "5"))
(after-reset-case! "seq, after finished" S #t (bv RS "1\n") #t (bv "[1]" RS "4\n"))
(after-reset-case! "values, after an error" V #f (u "1 x") #t (u "4 5"))
(after-reset-case! "values, after finished" V #f (u "1 2") #t (u "4 5"))
;; A record's first byte, left from before a reset, would make a blank line
;; look like content, or an array look like a truncated number.
(after-reset-case! "lines, mid-record, then a blank line" L #t (u "[3") #f (u "\n4\n"))
(after-reset-case! "lines, mid-record, then a blank line, no on-skip" L #f (u "[3") #f (u "\n4\n"))
(after-reset-case! "seq, mid-record begun with a digit, then an array" S #t (bv RS "12") #f (bv RS "[1]" RS "2\n"))

(define (results-case! label o skip? pieces)
  ;; pieces: byte lists/strings per feed; the last is fed with START and END
  ;; from inside a larger bytevector.
  (let* ((rig (logged-reader o skip?)) (r (rig-reader rig))
         (offsets '()) (total 0))
    (for-each
     (lambda (p)
       (let* ((b (apply bv p)) (n (bytevector-length b))
              (big (make-bytevector (+ n 4) #xFF)))
         (bytevector-copy! b 0 big 2 n)
         (set! total (+ total n))
         (set! offsets (cons (list (res->list (json-reader-feed! r big 2 (+ 2 n))) total) offsets))))
     pieces)
    (let* ((f (res->list (json-reader-finish! r)))
           (again (res->list (json-reader-feed! r (u "99 99\n"))))
           (again2 (res->list (json-reader-feed! r (u "99 99\n") 1 3)))
           (fin2 (res->list (json-reader-finish! r))))
      (chk (string-append "results / " label ": need-input counts bytes fed so far, finished the total; both stick")
           (list (map (lambda (o) (list (list 'need-input #f (cadr o)) (cadr o))) (reverse offsets))
                 (list 'finished #f total) (list 'finished #f total)
                 (list 'finished #f total) (list 'finished #f total))
           (list (map (lambda (o) (list (car o) (cadr o))) (reverse offsets))
                 f again again2 fin2)))))

(results-case! "lines" L #f '(("1\n2") ("\n3\n4") ("") ("5\n")))
(results-case! "seq" S #t (list (list RS "1\n") (list RS "2\n" RS) '("") (list "3" RS)))
(results-case! "values" V #f '(("1 2") (" 3 4") ("") (" 5")))

(chk "results / need-input has no code"
     '(need-input #f 3)
     (res->list (json-reader-feed! (make-json-reader (lambda (v) v)) (u "1\n2"))))

(chk "results / a feed after finish hands on no value"
     (list '((v 1 1)) '(finished #f 2))
     (let* ((rig (logged-reader L #f)) (r (rig-reader rig)))
       (json-reader-feed! r (u "1\n"))
       (json-reader-finish! r)
       (let ((x (res->list (json-reader-feed! r (u "2\n")))))
         (list (rig-log rig) x))))

(chk "results / the results are json-results"
     '(#t #t #t)
     (let ((r (make-json-reader (lambda (v) v))))
       (list (json-result? (json-reader-feed! r (u "1\n")))
             (json-result? (json-reader-finish! r))
             (json-result? (json-reader-feed! r (u "1\n"))))))

;; ===== 7. the procedures' contract ======================================================

(define marker (list 'boom))

;; raised-eq? : (-> Any) -> (U #t 'returned 'other)
;; #t when THUNK raised exactly MARKER.
(define (raised-eq? thunk)
  (guard (e (#t (if (eq? e marker) #t (list 'other (describe e)))))
    (thunk)
    'returned))

;; The formats, as the contract tests use them: options, whether on-skip is
;; given, a stream whose first value is handed on during a feed, one whose is
;; handed on only at finish, a stream whose first bad record is skipped during
;; a feed, one whose is skipped only at finish, and a good stream.
(define contract-formats
  (list
   (list 'lines L #t (u "1\n2\n") (u "1") (u "x\n2\n") (u "[") (u "3\n4\n")
         '((v 3 1) (v 4 2)) 4 3)
   (list 'seq S #t (bv RS "1\n" RS "2\n" RS) (bv RS "1\n") (bv "x" RS "2\n") (bv RS "[")
         (bv RS "3\n" RS "4\n") '((v 3 1) (v 4 2)) 6 3)
   (list 'values V #f (u "1 2 ") (u "1") #f #f (u "3 4")
         '((v 3 1) (v 4 2)) 3 3)))

(define (cf-name f) (list-ref f 0))
(define (cf-opts f) (list-ref f 1))
(define (cf-skip? f) (list-ref f 2))
(define (cf-value-feed f) (list-ref f 3))
(define (cf-value-finish f) (list-ref f 4))
(define (cf-skip-feed f) (list-ref f 5))
(define (cf-skip-finish f) (list-ref f 6))
(define (cf-good f) (list-ref f 7))
(define (cf-good-log f) (list-ref f 8))
(define (cf-good-offset f) (list-ref f 9))
(define (cf-good-record f) (list-ref f 10))

;; A reader whose on-value (or on-skip) misbehaves once, through ACT, which is
;; called with the reader. `armed` says whether the next call misbehaves.
(define (misbehaving-reader f which act)
  (let ((armed #t) (log '()))
    (letrec ((r (make-json-reader
                 (lambda (v)
                   (if (and armed (eq? which 'value))
                       (begin (set! armed #f) (act r))
                       (set! log (cons (list 'v (norm v) (json-reader-record r)) log))))
                 (and (cf-skip? f)
                      (lambda (c n off)
                        (if (and armed (eq? which 'skip))
                            (begin (set! armed #f) (act r))
                            (set! log (cons (list 'skip c n off) log)))))
                 (cf-opts f))))
      (vector r (lambda () (reverse log)) (lambda () (set! log '()))))))

;; What is left once a reader has been poisoned: feed and finish raise, reset
;; works, and then the reader reads a good stream correctly.
(define (check-poisoned-then-reset! label f rig-v)
  (let* ((r (vector-ref rig-v 0))
         (feed-out (outcome (lambda () (json-reader-feed! r (u "9\n")))))
         (feed-range-out (outcome (lambda () (json-reader-feed! r (u "9\n") 0 1))))
         (finish-out (outcome (lambda () (json-reader-finish! r))))
         (feed-again (outcome (lambda () (json-reader-feed! r (u "9\n")))))
         (record-out (outcome (lambda () (json-reader-record r)))))
    (chk (string-append label ": feed and finish then raise an assertion violation")
         (list (violates 'json-reader-feed!) (violates 'json-reader-feed!)
               (violates 'json-reader-finish!) (violates 'json-reader-feed!)
               (returned #t))
         (list feed-out feed-range-out finish-out feed-again
               (returned (and (eq? (car record-out) 'returned) #t))))
    (chk (string-append label ": the reset of a poisoned reader returns")
         (returned 'done)
         (outcome (lambda () (json-reader-reset! r) 'done)))
    ((vector-ref rig-v 2))
    (chk (string-append label ": after the reset it reads a new stream correctly")
         (returned (list (cf-good-log f) (list 'finished #f (cf-good-offset f)) (cf-good-record f)))
         (outcome (lambda ()
                    (let* ((g (cf-good f))
                           (a (json-reader-feed! r g))
                           (fin (json-reader-finish! r)))
                      (list ((vector-ref rig-v 1)) (res->list fin) (json-reader-record r))))))))

(for-each
 (lambda (f)
   (let ((fname (symbol->string (cf-name f))))
     ;; on-value raising, during a feed and during finish.
     (for-each
      (lambda (stage text)
        (let* ((label (string-append "contract / " fname " / on-value raises during " stage))
               (rig (misbehaving-reader f 'value (lambda (r) (raise marker))))
               (r (vector-ref rig 0))
               (got (raised-eq?
                     (lambda ()
                       (json-reader-feed! r text)
                       (when (equal? stage "finish") (json-reader-finish! r))))))
          (chk (string-append label ": the raised object passes out, eq?") #t got)
          (check-poisoned-then-reset! label f rig)))
      '("feed" "finish")
      (list (cf-value-feed f) (cf-value-finish f)))
     ;; on-value escaping through a continuation.
     (for-each
      (lambda (stage text)
        (let* ((label (string-append "contract / " fname " / on-value escapes during " stage))
               (k #f)
               (rig (misbehaving-reader f 'value (lambda (r) (k 'escaped))))
               (r (vector-ref rig 0))
               (got (call-with-current-continuation
                     (lambda (kk)
                       (set! k kk)
                       (json-reader-feed! r text)
                       (when (equal? stage "finish") (json-reader-finish! r))
                       'fell-through))))
          (chk (string-append label ": the escape leaves the feed") 'escaped got)
          (check-poisoned-then-reset! label f rig)))
      '("feed" "finish")
      (list (cf-value-feed f) (cf-value-finish f)))
     ;; on-skip raising and escaping, where the format has an on-skip.
     (when (cf-skip? f)
       (for-each
        (lambda (stage text)
          (let* ((label (string-append "contract / " fname " / on-skip raises during " stage))
                 (rig (misbehaving-reader f 'skip (lambda (r) (raise marker))))
                 (r (vector-ref rig 0))
                 (got (raised-eq?
                       (lambda ()
                         (json-reader-feed! r text)
                         (when (equal? stage "finish") (json-reader-finish! r))))))
            (chk (string-append label ": the raised object passes out, eq?") #t got)
            (check-poisoned-then-reset! label f rig)))
        '("feed" "finish")
        (list (cf-skip-feed f) (cf-skip-finish f)))
       (for-each
        (lambda (stage text)
          (let* ((label (string-append "contract / " fname " / on-skip escapes during " stage))
                 (k #f)
                 (rig (misbehaving-reader f 'skip (lambda (r) (k 'escaped))))
                 (r (vector-ref rig 0))
                 (got (call-with-current-continuation
                       (lambda (kk)
                         (set! k kk)
                         (json-reader-feed! r text)
                         (when (equal? stage "finish") (json-reader-finish! r))
                         'fell-through))))
            (chk (string-append label ": the escape leaves the feed") 'escaped got)
            (check-poisoned-then-reset! label f rig)))
        '("feed" "finish")
        (list (cf-skip-feed f) (cf-skip-finish f))))))
 contract-formats)

;; Feed, finish and reset from inside on-value and on-skip.
(define (reentrant-reader f which)
  (let ((log '()) (done #f))
    (letrec ((try-all
              (lambda (r tag)
                (unless done
                  (set! done #t)
                  (set! log (cons (list tag 'feed
                                        (outcome (lambda () (json-reader-feed! r (u "7\n")))))
                                  log))
                  (set! log (cons (list tag 'feed-range
                                        (outcome (lambda () (json-reader-feed! r (u "7\n") 0 2))))
                                  log))
                  (set! log (cons (list tag 'finish
                                        (outcome (lambda () (json-reader-finish! r))))
                                  log))
                  (set! log (cons (list tag 'reset
                                        (outcome (lambda () (json-reader-reset! r))))
                                  log))))))
      (letrec ((r (make-json-reader
                   (lambda (v)
                     (when (eq? which 'value) (try-all r 'in-value))
                     (set! log (cons (list 'v (norm v) (json-reader-record r)) log)))
                   (and (cf-skip? f)
                        (lambda (c n off)
                          (when (eq? which 'skip) (try-all r 'in-skip))
                          (set! log (cons (list 'skip c n off) log))))
                   (cf-opts f))))
        (vector r (lambda () (reverse log)))))))

(define (violation-list tag)
  (list (list tag 'feed (violates 'json-reader-feed!))
        (list tag 'feed-range (violates 'json-reader-feed!))
        (list tag 'finish (violates 'json-reader-finish!))
        (list tag 'reset (violates 'json-reader-reset!))))

(for-each
 (lambda (f)
   (let ((fname (symbol->string (cf-name f))))
     (let* ((rig (reentrant-reader f 'value)) (r (vector-ref rig 0))
            (text (cf-value-feed f)))
       (json-reader-feed! r text)
       (let ((fin (res->list (json-reader-finish! r))))
         (chk (string-append "contract / " fname " / feed, finish and reset from inside on-value each raise; reading goes on")
              (list (append (violation-list 'in-value)
                            (if (eq? (cf-name f) 'values)
                                '((v 1 1) (v 2 2))
                                '((v 1 1) (v 2 2))))
                    (car fin))
              (list ((vector-ref rig 1)) (car fin)))))
     (when (cf-skip? f)
       (let* ((rig (reentrant-reader f 'skip)) (r (vector-ref rig 0))
              (text (cf-skip-feed f)))
         (json-reader-feed! r text)
         (let ((fin (res->list (json-reader-finish! r))))
           (chk (string-append "contract / " fname " / feed, finish and reset from inside on-skip each raise; reading goes on")
                (list (append (violation-list 'in-skip)
                              (if (eq? (cf-name f) 'lines)
                                  '((skip unexpected-byte 1 0) (v 2 2))
                                  '((skip unexpected-byte 1 0) (v 2 2))))
                      'finished)
                (list ((vector-ref rig 1)) (car fin))))))))
 contract-formats)

;; The procedures' return values are ignored, a stop included.
(for-each
 (lambda (ret-name ret)
   (for-each
    (lambda (f)
      (let ((log '()))
        (letrec ((r (make-json-reader
                     (lambda (v) (set! log (cons (list 'v (norm v)) log)) ret)
                     (and (cf-skip? f)
                          (lambda (c n off) (set! log (cons (list 'skip c n off) log)) ret))
                     (cf-opts f))))
          (let ((text (case (cf-name f)
                        ((lines) (u "1\nx\n3\n"))
                        ((seq) (bv "x" RS "1\n" RS "3\n"))
                        (else (u "1 3")))))
            (json-reader-feed! r text)
            (let ((fin (res->list (json-reader-finish! r))))
              (chk (string-append "contract / " (symbol->string (cf-name f)) " / a return of " ret-name
                                  " from on-value or on-skip is ignored")
                   (case (cf-name f)
                     ((lines) (list '((v 1) (skip unexpected-byte 2) (v 3)) '(finished #f 6)))
                     ((seq) (list '((skip unexpected-byte 0) (v 1) (v 3)) '(finished #f 7)))
                     (else (list '((v 1) (v 3)) '(finished #f 3))))
                   (list (map (lambda (e) (if (eq? (car e) 'skip) (list 'skip (cadr e) (cadddr e)) e))
                              (reverse log))
                         fin)))))))
    (filter (lambda (f) (or (not (eq? (cf-name f) 'values)) (equal? ret-name "a stop"))) contract-formats)))
 '("a stop" "a symbol" "a vector")
 (list (make-json-stop 'halt) 'stop (vector 1 2)))

;; ===== 8. independence ======================================================================

;; Two or three readers, of different formats and options, fed alternately.
(let* ((b1 (u "12\n[3,\nx\n4\r\n\n\"s\""))
       (b2 (bv RS "tr" "ue " RS RS "[1" "]\n" RS "z" RS "9"))
       (b3 (u "{\"a\":1}  2 {\"b\"") )
       (o1 L) (o2 S) (o3 V)
       (rig1 (logged-reader o1 #t)) (rig2 (logged-reader o2 #t)) (rig3 (logged-reader o3 #f))
       (ref1 (play o1 #t (whole b1))) (ref2 (play o2 #t (whole b2))) (ref3 (play o3 #f (whole b3)))
       (c1 (sized b1 3)) (c2 (sized b2 2)) (c3 (sized b3 4)))
  (let loop ((c1 c1) (c2 c2) (c3 c3))
    (unless (and (null? c1) (null? c2) (null? c3))
      (for-each (lambda (cs rig)
                  (unless (null? cs)
                    (let ((c (car cs)))
                      (json-reader-feed! (rig-reader rig) (car c) (cadr c) (caddr c)))))
                (list c1 c2 c3) (list rig1 rig2 rig3))
      (loop (if (null? c1) c1 (cdr c1)) (if (null? c2) c2 (cdr c2)) (if (null? c3) c3 (cdr c3)))))
  (let* ((f1 (json-reader-finish! (rig-reader rig1)))
         (f2 (json-reader-finish! (rig-reader rig2)))
         (f3 (json-reader-finish! (rig-reader rig3))))
    (chk "independence / three readers fed alternately: the lines reader's log is its own"
         ref1
         (list (rig-log rig1) (json-result-status f1) (json-result-code f1)
               (json-result-offset f1) (json-reader-record (rig-reader rig1))))
    (chk "independence / three readers fed alternately: the seq reader's log is its own"
         ref2
         (list (rig-log rig2) (json-result-status f2) (json-result-code f2)
               (json-result-offset f2) (json-reader-record (rig-reader rig2))))
    (chk "independence / three readers fed alternately: the values reader's log is its own"
         ref3
         (list (rig-log rig3) (json-result-status f3) (json-result-code f3)
               (json-result-offset f3) (json-reader-record (rig-reader rig3))))
    (chk "independence / the references are what they are (lines)"
         (ok '((v 12 1) (skip unexpected-eof 2 6) (skip unexpected-byte 3 7) (v 4 4)
               (skip blank-line 5 12) (v "s" 6)) 16 7)
         ref1)
    (chk "independence / the references are what they are (seq)"
         (ok (quote ((v #t 1) (v #(1) 2) (skip unexpected-byte 3 13) (skip truncated 4 16))) 16 5)
         ref2)))

(let* ((rig1 (logged-reader L #t)) (rig2 (logged-reader L #t))
       (r1 (rig-reader rig1)) (r2 (rig-reader rig2)))
  (json-reader-feed! r1 (u "1\n[2"))
  (json-reader-feed! r2 (u "x\n3\n4"))
  (json-reader-feed! r1 (u ",3]\nx"))
  (json-reader-feed! r2 (u "\n"))
  (json-reader-finish! r1)
  (chk "independence / two readers of one format: r1 finished while r2 is mid-stream"
       (list '((v 1 1) (v #(2 3) 2) (skip unexpected-byte 3 8)) 4)
       (list (rig-log rig1) (json-reader-record r1)))
  (json-reader-finish! r2)
  (chk "independence / two readers of one format: r2 unaffected by r1"
       (list '((skip unexpected-byte 1 0) (v 3 2) (v 4 3)) 4)
       (list (rig-log rig2) (json-reader-record r2))))

(define (res->list* res) (res->list res))

(let* ((rig1 (logged-reader L #f)) (r1 (rig-reader rig1))
       (rig2 (logged-reader L #f)) (r2 (rig-reader rig2)))
  (json-reader-feed! r1 (u "1\nx\n"))
  (json-reader-feed! r2 (u "5\n"))
  (chk "independence / one reader's error does not touch another"
       (list '(error unexpected-byte 2) '((v 5 1)) 'need-input)
       (let* ((fin (res->list* (json-reader-finish! r1)))
              (log2 (rig-log rig2))
              (st (json-result-status (json-reader-feed! r2 (u "6")))))
         (list fin log2 st))))

;; Two readers of the same format, fed alternately, each count their own records.
(let* ((ba (u "1 2 3")) (bb (u "[4] [5]"))
       (rig-a (logged-reader V #f)) (rig-b (logged-reader V #f))
       (ra (rig-reader rig-a)) (rb (rig-reader rig-b)))
  (let loop ((ca (sized ba 2)) (cb (sized bb 3)))
    (unless (and (null? ca) (null? cb))
      (unless (null? ca) (json-reader-feed! ra (car (car ca)) (cadr (car ca)) (caddr (car ca))))
      (unless (null? cb) (json-reader-feed! rb (car (car cb)) (cadr (car cb)) (caddr (car cb))))
      (loop (if (null? ca) ca (cdr ca)) (if (null? cb) cb (cdr cb)))))
  (let* ((fa (json-reader-finish! ra)) (fb (json-reader-finish! rb)))
    (chk "independence / two values readers fed alternately: the first's log is its own"
         (ok '((v 1 1) (v 2 2) (v 3 3)) 5 4)
         (list (rig-log rig-a) (json-result-status fa) (json-result-code fa)
               (json-result-offset fa) (json-reader-record ra)))
    (chk "independence / two values readers fed alternately: the second's log is its own"
         (ok '((v #(4) 1) (v #(5) 2)) 7 3)
         (list (rig-log rig-b) (json-result-status fb) (json-result-code fb)
               (json-result-offset fb) (json-reader-record rb)))))

;; ===== 9. options and defaults ================================================================

;; Each option reaches every record of every format.
(define (deep3 x) (bv "[[[" x "]]]"))

(let ((o2 (lambda (fmt) (opts 'stream fmt 'depth-limit 2))))
  (case! "options / depth-limit 2 under lines: a record at the limit, one past it, one at it again"
         (o2 'lines) #t (u "[[1]]\n[[[1]]]\n[[1]]\n")
         (ok '((v #(#(1)) 1) (skip nesting-too-deep 2 9) (v #(#(1)) 3)) 20 4))
  (case! "options / depth-limit 2 under seq"
         (o2 'seq) #t (bv RS "[[1]]\n" RS "[[[1]]]\n" RS "[[1]]\n")
         (ok '((v #(#(1)) 1) (skip nesting-too-deep 2 11) (v #(#(1)) 3)) 23 4))
  (case! "options / depth-limit 2 under values: a value past it ends the stream"
         (o2 'values) #f (u "[[1]] [[[1]]]")
         (bad '((v #(#(1)) 1)) 'nesting-too-deep 9 2)))

(case! "options / depth-limit 0 under lines: a scalar reads, an array does not"
       (opts 'stream 'lines 'depth-limit 0) #t (u "1\n[]\n2\n")
       (ok '((v 1 1) (skip nesting-too-deep 2 3) (v 2 3)) 7 4))

(let ((o3 (lambda (fmt) (opts 'stream fmt 'digit-limit 3))))
  (case! "options / digit-limit 3 under lines: 3 digits read, 4 do not, per record"
         (o3 'lines) #t (u "123\n1234\n12\n")
         (ok '((v 123 1) (skip number-too-long 2 8) (v 12 3)) 12 4))
  (case! "options / digit-limit 3 under seq"
         (o3 'seq) #t (bv RS "123\n" RS "1234\n" RS "12\n")
         (ok '((v 123 1) (skip number-too-long 2 10) (v 12 3)) 15 4))
  (case! "options / digit-limit 3 under values"
         (o3 'values) #f (u "123 1234 12")
         (bad '((v 123 1)) 'number-too-long 8 2)))

;; number-mode, object-mode and null, under every format: the same values.
(define (rows-stream fmt)
  (case fmt
    ((lines) (u "{\"a\":1.5,\"b\":null}\n[0.10,2e2]\n"))
    ((seq) (bv RS "{\"a\":1.5,\"b\":null}\n" RS "[0.10,2e2]\n"))
    (else (u "{\"a\":1.5,\"b\":null} [0.10,2e2]"))))

(define (rows-offset fmt)
  (case fmt ((lines) 30) ((seq) 32) (else 29)))

(for-each
 (lambda (fmt)
   (let ((skip? (eq? fmt 'seq)))
     (case! (string-append "options / " (symbol->string fmt) ": number-mode exact, object-mode hashtable, null nil")
            (opts 'stream fmt 'number-mode 'exact 'object-mode 'hashtable 'null 'nil)
            skip? (rows-stream fmt)
            (ok '((v (table ("a" . 3/2) ("b" . nil)) 1) (v #(1/10 200) 2)) (rows-offset fmt) 3))
     (case! (string-append "options / " (symbol->string fmt) ": number-mode text keeps the text")
            (opts 'stream fmt 'number-mode 'text)
            skip? (rows-stream fmt)
            (ok '((v (("a" . (num "1.5")) ("b" . null)) 1) (v #((num "0.10") (num "2e2")) 2))
                (rows-offset fmt) 3))
     (case! (string-append "options / " (symbol->string fmt) ": the defaults: flonum, alist, null")
            (opts 'stream fmt)
            skip? (rows-stream fmt)
            (ok '((v (("a" . 1.5) ("b" . null)) 1) (v #(0.1 200.0) 2)) (rows-offset fmt) 3))
     (case! (string-append "options / " (symbol->string fmt) ": null is any symbol or record, here a record")
            (opts 'stream fmt 'null 'void)
            skip? (rows-stream fmt)
            (ok '((v (("a" . 1.5) ("b" . void)) 1) (v #(0.1 200.0) 2)) (rows-offset fmt) 3))))
 '(lines seq values))

;; text mode has no digit limit.
(case! "options / number-mode text under a digit-limit 3: no limit applies"
       (opts 'stream 'lines 'number-mode 'text 'digit-limit 3) #f (u "123456789\n")
       (ok '((v (num "123456789") 1)) 10 2))

;; The four argument forms.
(let ((blank-input (u "1\n\n2\n")))
  (define (run-form make)
    (let ((log '()))
      (let* ((r (make (lambda (v) (set! log (cons (list 'v v) log)))
                      (lambda (c n off) (set! log (cons (list 'skip c n off) log)))))
             (a (json-reader-feed! r blank-input))
             (f (json-reader-finish! r)))
        (list (reverse log) (res->list f) (json-reader-record r)))))
  (chk "forms / (make-json-reader on-value): lines, blank-line is an error"
       '(((v 1)) (error blank-line 2) 2)
       (run-form (lambda (on-value on-skip) (make-json-reader on-value))))
  (chk "forms / (make-json-reader on-value options): the options are used (blank-lines skip)"
       '(((v 1) (v 2)) (finished #f 5) 4)
       (run-form (lambda (on-value on-skip)
                   (make-json-reader on-value (opts 'blank-lines 'skip)))))
  (chk "forms / (make-json-reader on-value options): an error under the default blank-lines"
       '(((v 1)) (error blank-line 2) 2)
       (run-form (lambda (on-value on-skip)
                   (make-json-reader on-value (opts 'depth-limit 7)))))
  (chk "forms / (make-json-reader on-value on-skip): default options, blank-line reported"
       '(((v 1) (skip blank-line 2 2) (v 2)) (finished #f 5) 4)
       (run-form (lambda (on-value on-skip) (make-json-reader on-value on-skip))))
  (chk "forms / (make-json-reader on-value on-skip options): both"
       '(((v 1) (v 2)) (finished #f 5) 4)
       (run-form (lambda (on-value on-skip)
                   (make-json-reader on-value on-skip (opts 'blank-lines 'skip)))))
  (chk "forms / (make-json-reader on-value #f options): no on-skip, the options"
       '(((v 1)) (error blank-line 2) 2)
       (run-form (lambda (on-value on-skip)
                   (make-json-reader on-value #f (opts 'stream 'lines 'depth-limit 5)))))
  (chk "forms / (make-json-reader on-value #f options): blank-lines skip"
       '(((v 1) (v 2)) (finished #f 5) 4)
       (run-form (lambda (on-value on-skip)
                   (make-json-reader on-value #f (opts 'blank-lines 'skip)))))
  (chk "forms / (make-json-reader on-value #f): the same as one argument"
       '(((v 1)) (error blank-line 2) 2)
       (run-form (lambda (on-value on-skip)
                   (make-json-reader on-value #f)))))

(chk "forms / (make-json-reader on-value options) under seq needs an on-skip"
     (violates 'make-json-reader)
     (outcome (lambda () (make-json-reader (lambda (v) v) (opts 'stream 'seq)))))

;; ===== 10. arguments ============================================================================

(define (reader) (make-json-reader (lambda (v) v)))

(chk "arguments / a non-procedure on-value"
     (violates 'make-json-reader 5)
     (outcome (lambda () (make-json-reader 5))))

(chk "arguments / a non-procedure on-value, with options"
     (violates 'make-json-reader "f")
     (outcome (lambda () (make-json-reader "f" (opts)))))

(chk "arguments / a non-procedure on-value, with on-skip and options"
     (violates 'make-json-reader 'x)
     (outcome (lambda () (make-json-reader 'x #f (opts)))))

(chk "arguments / an on-skip that is neither a procedure nor #f"
     (violates 'make-json-reader 'skip)
     (outcome (lambda () (make-json-reader (lambda (v) v) 'skip))))

(chk "arguments / an on-skip that is neither, with options"
     (violates 'make-json-reader 7)
     (outcome (lambda () (make-json-reader (lambda (v) v) 7 (opts)))))

(chk "arguments / a non-options record"
     (violates 'make-json-reader 'opts)
     (outcome (lambda () (make-json-reader (lambda (v) v) #f 'opts))))

(chk "arguments / a non-options record that is a reader"
     (list 'violation 'make-json-reader)
     (let ((x (reader)))
       (let ((o (outcome (lambda () (make-json-reader (lambda (v) v) (lambda (c n o) c) x)))))
         (list (car o) (cadr o)))))

(for-each
 (lambda (name proc)
   (chk (string-append "arguments / a non-reader to " name)
        (violates (string->symbol name) 5)
        (outcome (lambda () (proc 5)))))
 '("json-reader-finish!" "json-reader-reset!" "json-reader-record")
 (list json-reader-finish! json-reader-reset! json-reader-record))

(chk "arguments / a non-reader to json-reader-feed!"
     (violates 'json-reader-feed! 5)
     (outcome (lambda () (json-reader-feed! 5 (u "1")))))

(chk "arguments / a non-reader to json-reader-feed!, with START and END"
     (violates 'json-reader-feed! "r")
     (outcome (lambda () (json-reader-feed! "r" (u "1") 0 1))))

(chk "arguments / a parser is not a reader"
     (list 'violation 'json-reader-record)
     (let ((o (outcome (lambda () (json-reader-record (make-json-parser (make-json-handler)))))))
       (list (car o) (cadr o))))

(chk "arguments / json-reader? is #t for a reader and #f otherwise"
     '(#t #f #f #f #f)
     (list (json-reader? (reader)) (json-reader? 5) (json-reader? (vector)) (json-reader? (make-json-options)) (json-reader? (list (reader)))))

(chk "arguments / a non-bytevector"
     (violates 'json-reader-feed! "1")
     (outcome (lambda () (json-reader-feed! (reader) "1"))))

(chk "arguments / a non-bytevector, with START and END"
     (violates 'json-reader-feed! '(1))
     (outcome (lambda () (json-reader-feed! (reader) '(1) 0 1))))

(let ((b (u "12345")))
  (for-each
   (lambda (name start end)
     (chk (string-append "arguments / START and END: " name)
          (violates 'json-reader-feed! start end 5)
          (outcome (lambda () (json-reader-feed! (reader) b start end)))))
   '("END past the end" "START past the end" "reversed" "START negative" "END negative"
     "a flonum START" "a symbol END" "a ratnum START" "a #f END" "a bignum END")
   (list 0 6 4 -1 0 1.0 0 1/2 0 0)
   (list 6 6 2 2 -1 3 'x 3 #f (expt 2 80)))
  (chk "arguments / START and END at the bounds are fine: 0 0, 5 5, 0 5"
       (list (returned '(need-input #f 0)) (returned '(need-input #f 0)) (returned '(need-input #f 5)))
       (let ((r (reader)))
         (list (outcome (lambda () (res->list (json-reader-feed! r b 0 0))))
               (outcome (lambda () (res->list (json-reader-feed! (reader) b 5 5))))
               (outcome (lambda () (res->list (json-reader-feed! (reader) b 0 5))))))))

(chk "arguments / bad arguments to a feed do not poison the reader"
     (list (violates 'json-reader-feed! 0 9 2) '((v 1 1)) '(finished #f 2))
     (let* ((rig (logged-reader L #f)) (r (rig-reader rig))
            (o (outcome (lambda () (json-reader-feed! r (u "1\n") 0 9)))))
       (json-reader-feed! r (u "1\n"))
       (let* ((fin (res->list (json-reader-finish! r)))
              (log (rig-log rig)))
         (list o log fin))))

(chk "arguments / options with a stream the reader knows are not refused: lines with blank-lines"
     '(#t)
     (list (json-reader? (make-json-reader (lambda (v) v) (opts 'blank-lines 'skip)))))

;; ===== 11. SRFI 180's five files ============================================================

(define (file-bytes name)
  (let* ((p (open-file-input-port (string-append "tests/corpus/srfi-180/files/" name)))
         (b (get-bytevector-all p)))
    (close-port p)
    (if (eof-object? b) (bv) b)))

(define (srfi-chunk-cases! name o skip? expected)
  (let ((b (file-bytes name)))
    (for-each
     (lambda (k label)
       (chk (string-append "srfi-180 / " name " / " label)
            expected
            (play o skip? (if k (sized b k) (whole b)))))
     '(#f 1 7 64)
     '("read whole" "in chunks of 1" "in chunks of 7" "in chunks of 64"))))

(define ab '((("a" . 1)) (("b" . 2))))

(srfi-chunk-cases! "sample.jsonl" L #f
                   (ok '((v (("a" . 1)) 1) (v (("b" . 2)) 2)) 18 3))
(srfi-chunk-cases! "sample-crlf-line-separators.jsonl" L #f
                   (ok '((v (("a" . 1)) 1) (v (("b" . 2)) 2)) 20 3))
(srfi-chunk-cases! "sample-no-eol-at-eof.jsonl" L #f
                   (ok '((v (("a" . 1)) 1) (v (("b" . 2)) 2)) 17 3))

(define (log-object count date)
  `(("d" . ,date) ("count" . ,count)))

(srfi-chunk-cases! "json-sequence.log" S #t
                   (ok (let loop ((n 0) (acc '()))
                         (if (= n 10)
                             (reverse acc)
                             (loop (+ n 1)
                                   (cons (list 'v
                                               (log-object n (if (= n 0)
                                                                 "2014-09-22T22:11:26.315Z"
                                                                 "2014-09-22T22:11:26.317Z"))
                                               (+ n 1))
                                         acc))))
                       440 11))

(srfi-chunk-cases! "json-sequence-with-one-broken-json.log" S #t
                   (ok (append
                        (let loop ((n 0) (acc '()))
                          (if (= n 8)
                              (reverse acc)
                              (loop (+ n 1)
                                    (cons (list 'v
                                                (log-object n (if (= n 0)
                                                                  "2014-09-22T22:11:26.315Z"
                                                                  "2014-09-22T22:11:26.317Z"))
                                                (+ n 1))
                                          acc))))
                        '((skip control-character 9 386))
                        (list (list 'v (log-object 9 "2014-09-22T22:11:26.317Z") 10)))
                       431 11))

(chk "srfi-180 / an RS-framed log read as lines: unexpected-byte at the first RS, record 1"
     (bad '() 'unexpected-byte 0 1)
     (play L #f (whole (file-bytes "json-sequence.log"))))

;; ===== 12. put-json-record =====================================================================

;; written : (Binary-Output-Port -> Any) -> (List Outcome Bytes)
(define (written proc)
  (let-values (((p get) (open-bytevector-output-port)))
    (let ((out (outcome (lambda () (proc p) 'done))))
      (list out (bytevector->u8-list (get))))))

(define (bytes-of . parts) (bytevector->u8-list (apply bv parts)))

(define obj '(("a" . 1)))
(define LC (opts 'stream 'lines))
(define SC (opts 'stream 'seq))
(define VC (opts 'stream 'values))
(define SI (opts 'stream 'seq 'indent 2))
(define VI (opts 'stream 'values 'indent 2))

(chk "put-json-record / lines, compact: the value then \\n"
     (list (returned 'done) (bytes-of "{\"a\":1}\n"))
     (written (lambda (p) (put-json-record p obj LC))))

(chk "put-json-record / seq, compact: RS, the value, then \\n"
     (list (returned 'done) (bytes-of RS "{\"a\":1}\n"))
     (written (lambda (p) (put-json-record p obj SC))))

(chk "put-json-record / values, compact: the value then \\n"
     (list (returned 'done) (bytes-of "{\"a\":1}\n"))
     (written (lambda (p) (put-json-record p obj VC))))

(chk "put-json-record / seq with indent 2: RS, the laid-out value, \\n"
     (list (returned 'done) (bytes-of RS "[\n  1,\n  2\n]\n"))
     (written (lambda (p) (put-json-record p (vector 1 2) SI))))

(chk "put-json-record / values with indent 2: the laid-out value, \\n"
     (list (returned 'done) (bytes-of "{\n  \"a\": 1,\n  \"b\": [\n    1\n  ]\n}\n"))
     (written (lambda (p) (put-json-record p '(("a" . 1) ("b" . #(1))) VI))))

(chk "put-json-record / a scalar under each format"
     (list (bytes-of "5\n") (bytes-of RS "\"x\"\n") (bytes-of "null\n"))
     (list (cadr (written (lambda (p) (put-json-record p 5 LC))))
           (cadr (written (lambda (p) (put-json-record p "x" SC))))
           (cadr (written (lambda (p) (put-json-record p 'null VC))))))

(chk "put-json-record / non-ASCII goes out as UTF-8: seq"
     (list (returned 'done) (bytes-of RS "\"" #xCE #xBB "\"\n"))
     (written (lambda (p) (put-json-record p "\x3BB;" SC))))

(chk "put-json-record / lines with indent 2: an assertion violation, nothing written"
     (list (violates 'put-json-record 2) '())
     (written (lambda (p) (put-json-record p obj (opts 'indent 2)))))

(chk "put-json-record / lines with indent 1: an assertion violation, nothing written"
     (list (violates 'put-json-record 1) '())
     (written (lambda (p) (put-json-record p obj (opts 'stream 'lines 'indent 1)))))

(chk "put-json-record / a refused value under lines: put-json's error, who put-json-record, nothing written"
     (list (list 'raised 'unwritable-value #f 'put-json-record "a value JSON can't express" (list car))
           '())
     (written (lambda (p) (put-json-record p (vector 1 car) LC))))

(chk "put-json-record / a refused value under seq: not even the RS is written"
     (list (list 'raised 'unwritable-number #f 'put-json-record "a number JSON can't express" (list +inf.0))
           '())
     (written (lambda (p) (put-json-record p (vector 1 (list (cons "k" +inf.0))) SC))))

(chk "put-json-record / a refused value under seq with indent 2: nothing written"
     (list (list 'raised 'unwritable-number #f 'put-json-record "a number JSON can't express" (list +nan.0))
           '())
     (written (lambda (p) (put-json-record p (vector 1 +nan.0) SI))))

(chk "put-json-record / a refused value under values"
     (list (list 'raised 'unwritable-value #f 'put-json-record "a value JSON can't express" (list 'sym))
           '())
     (written (lambda (p) (put-json-record p 'sym VC))))

(chk "put-json-record / records written before a refusal stay written"
     (list (list 'raised 'unwritable-value #f 'put-json-record "a value JSON can't express" (list car))
           (bytes-of RS "1\n" RS "2\n"))
     (written (lambda (p)
                (put-json-record p 1 SC)
                (put-json-record p 2 SC)
                (put-json-record p car SC))))

(chk "put-json-record / the two-argument form writes lines"
     (list (returned 'done) (bytes-of "[1,2]\n"))
     (written (lambda (p) (put-json-record p (vector 1 2)))))

(let-values (((tp get) (open-string-output-port)))
  (chk "put-json-record / a textual port"
       (violates 'put-json-record tp)
       (outcome (lambda () (put-json-record tp 1 SC)))))


(let ((ip (open-bytevector-input-port (bv "x"))))
  (chk "put-json-record / an input port"
       (violates 'put-json-record ip)
       (outcome (lambda () (put-json-record ip 1)))))

(chk "put-json-record / a non-port"
     (violates 'put-json-record 5)
     (outcome (lambda () (put-json-record 5 1))))

(chk "put-json-record / a non-options record, 2 arguments after the port"
     (violates 'put-json-record 'x)
     (let-values (((p get) (open-bytevector-output-port)))
       (outcome (lambda () (put-json-record p 1 'x)))))

(chk "put-json-record / a non-options record: nothing written"
     '()
     (let-values (((p get) (open-bytevector-output-port)))
       (outcome (lambda () (put-json-record p 1 'x)))
       (bytevector->u8-list (get))))

;; Round trip: what put-json-record writes, a reader reads back.
(define round-values
  (list 1 -2 "s" (vector 1 2) '(("a" . 1)) #t #f 'null 2.5 "\xE9;\x3BB;"
        '(("k" . #(1 (("n" . null)))))))

;; read-back : json-options Schedule -> (List (Listof Value) Status)
(define (read-back o schedule)
  (let ((got '()))
    (let ((r (make-json-reader (lambda (v) (set! got (cons v got)))
                               (and (eq? (json-options-stream o) 'seq)
                                    (lambda (c n off) (set! got (cons (list 'skipped c) got))))
                               o)))
      (for-each (lambda (c) (json-reader-feed! r (car c) (cadr c) (caddr c))) schedule)
      (let* ((fin (json-reader-finish! r))
             (vals (map norm (reverse got))))
        (list vals (json-result-status fin))))))

(for-each
 (lambda (o)
   (let ((fmt (json-options-stream o))
         (indent (json-options-indent o)))
     (let-values (((p get) (open-bytevector-output-port)))
       (for-each (lambda (v) (put-json-record p v o)) round-values)
       (let ((out (get)))
         (chk (string-append "round trip / " (symbol->string fmt) " indent " (number->string indent)
                             ": records written are read back as the same values")
              (list (map norm round-values) 'finished)
              (read-back o (whole out)))
         (chk (string-append "round trip / " (symbol->string fmt) " indent " (number->string indent)
                             ": and in chunks of 1 byte")
              (list (map norm round-values) 'finished)
              (read-back o (sized out 1)))))))
 (list (opts 'stream 'lines) (opts 'stream 'seq) (opts 'stream 'values)
       (opts 'stream 'seq 'indent 2) (opts 'stream 'values 'indent 3)))

(test-end "sequence")

(display "elapsed ms: ")
(display (- (real-time) started))
(newline)
(display "pass ")
(display (test-runner-pass-count runner))
(display " fail ")
(display (test-runner-fail-count runner))
(newline)

(exit (suite-exit-status runner))
