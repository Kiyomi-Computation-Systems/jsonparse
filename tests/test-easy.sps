;;; tests/test-easy.sps: (jsonparse easy), and check-json of (jsonparse
;;; writer), held to ADR-0019.
;;;
;;; Every expectation is written by hand. Non-ASCII characters are written
;;; as \x...; escapes. Anything that can raise is run through `outcome`, which
;;; tags what happened, so a raise never equals an expected #f, and a
;;; no-raise never equals an expected raise.
;;;
;;; 1. Reading. 2. Reading errors. 3. Ports. 4. Writing. 5. json-ref.
;;; 6. json=?. 7. json-null?. 8. check-json. 9. The arguments.
;;; 10. Re-exports. 11. What the review found: exponents of any length,
;;; errors a port raises, non-continuable raises, the irritants of a read
;;; error, check-json's who at every refusal, and false members.
(import (rnrs)
        (rnrs mutable-pairs)
        (only (chezscheme) iota real-time make-list bytes-allocated collect-request-handler parameterize void)
        (srfi :64)
        (jsonparse-testing)
        (jsonparse easy)
        (jsonparse writer)
        (prefix (jsonparse error) l:)
        (prefix (jsonparse options) l:)
        (prefix (jsonparse string) l:))

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

(define-record-type (thing make-thing thing?) (fields a))
(define-record-type (nothing make-nothing nothing?))

;; bv->str : Bytevector -> String   one character per byte
(define (bv->str bv) (list->string (map integer->char (bytevector->u8-list bv))))

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

;; outcome : (-> Any) Any ... -> (List ...)
;; What the thunk did, caught by type:
;;   (returned NORMALISED-VALUE)
;;   (raised REASON OFFSET WHO MESSAGE IRRITANTS ERROR? VIOLATION?)  a &json-error
;;   (violation WHO IRRITANTS)                         an assertion violation
;;   (other-condition)
;; An irritant that is eq? to one of the HIDE objects is shown as `hidden`,
;; so a circular value is never printed.
(define (outcome thunk . hide)
  (define (shown irritants)
    (map (lambda (i) (if (memq i hide) 'hidden i)) irritants))
  (define (irritants-of e)
    (if (irritants-condition? e) (shown (condition-irritants e)) '()))
  (guard (e ((json-error? e)
             (list 'raised (json-error-reason e) (json-error-offset e)
                   (and (who-condition? e) (condition-who e))
                   (and (message-condition? e) (condition-message e))
                   (irritants-of e) (error? e) (violation? e)))
            ((assertion-violation? e)
             (list 'violation (and (who-condition? e) (condition-who e))
                   (irritants-of e)))
            ((condition? e) (list 'other-condition)))
    (let ((v (thunk)))
      (list 'returned (norm v)))))

;; (raised REASON OFFSET WHO MESSAGE IRRITANT ...) as `outcome` gives it.
(define (raised reason offset who message . irritants)
  (list 'raised reason offset who message irritants #t #f))
(define (violates who . irritants) (list 'violation who irritants))
(define (returned v) (list 'returned v))

(define (nm title . parts)
  (apply string-append title
         (map (lambda (p) (string-append " / " (if (symbol? p) (symbol->string p) p)))
              parts)))

;; The three readers.
(define hows '(string bytes port))
(define (who-of how)
  (case how ((string) 'string->json) ((bytes) 'bytevector->json) (else 'read-json)))

;; read-with : Symbol String json-options -> Any
(define (read-with how text o)
  (case how
    ((string) (string->json text o))
    ((bytes) (bytevector->json (string->utf8 text) o))
    (else (read-json (open-bytevector-input-port (string->utf8 text)) o))))

;; read-short : Symbol String -> Any   the one-argument forms
(define (read-short how text)
  (case how
    ((string) (string->json text))
    ((bytes) (bytevector->json (string->utf8 text)))
    (else (read-json (open-bytevector-input-port (string->utf8 text))))))

(define (read-out how text . opts)
  (outcome (lambda () (read-with how text (apply l:make-json-options opts)))))
(define (read-out1 how text)
  (outcome (lambda () (read-short how text))))

;; The &json-error a reader raises, offset counted in characters for a
;; string and in bytes otherwise.
(define (reader-error how reason char-off byte-off)
  (let ((off (if (eq? how 'string) char-off byte-off))
        (unit (if (eq? how 'string) " at character " " at byte ")))
    (raised reason off (who-of how)
            (string-append (symbol->string reason) unit (number->string off)))))

;; Same offset in characters and bytes.
(define (ascii-error how reason off) (reader-error how reason off off))

(define (make-table) (make-hashtable string-hash string=?))
(define (table . entries)
  (let ((h (make-table)))
    (for-each (lambda (e) (hashtable-set! h (car e) (cdr e))) entries)
    h))
(define (fill! h entries)
  (for-each (lambda (e) (hashtable-set! h (string-copy (car e)) (cdr e))) entries)
  h)

(define m-num "a number JSON can't express")
(define m-key "an object's key is not a string")
(define m-val "a value JSON can't express")
(define m-list "a list that is not an alist: it is improper or circular")
(define m-member "a list that is not an alist: a member is not a pair")
(define m-deep "more arrays and objects open at once than depth-limit")
(define m-dup "a hashtable holds two keys with the same text")

(define (nest-vec k inner) (if (= k 0) inner (vector (nest-vec (- k 1) inner))))
(define (nest-depth v)
  (if (vector? v)
      (+ 1 (if (= (vector-length v) 1) (nest-depth (vector-ref v 0)) 0))
      0))

(define the-null (make-nothing))
(define (spaces n) (make-string n #\space))

;; ============================================================================
(test-begin "easy")

;; --- 1. Reading ----------------------------------------------------------------

(define all-kinds-text
  "{\"a\":[1,-2,2.5,\"s\\n\",true,false,null],\"b\":{},\"c\":[],\"d\":\"\"}")
(define all-kinds-value
  '(("a" . #(1 -2 2.5 "s\n" #t #f null)) ("b" . ()) ("c" . #()) ("d" . "")))

(for-each
 (lambda (how)
   (chk (nm "every kind" how) (returned all-kinds-value) (read-out1 how all-kinds-text))
   (chk (nm "scalars" how) (list (returned 7) (returned "x") (returned #t) (returned #f)
                                 (returned 'null) (returned 1.5))
        (let* ((a (read-out1 how "7")) (b (read-out1 how " \"x\" ")) (c (read-out1 how "true"))
               (d (read-out1 how "false")) (e (read-out1 how "null")) (f (read-out1 how "1.5")))
          (list a b c d e f)))
   (chk (nm "bignum" how) (returned 123456789012345678901234567890)
        (read-out1 how "123456789012345678901234567890"))
   (chk (nm "string escapes" how)
        (returned "\"\\/\b\f\n\r\t\x3b1;\x1F600;")
        (read-out1 how "\"\\\"\\\\\\/\\b\\f\\n\\r\\t\\u03b1\\ud83d\\ude00\""))
   (chk (nm "non-ASCII text" how) (returned "\xE9;\x20AC;\x1F600;")
        (read-out1 how "\"\xE9;\x20AC;\x1F600;\""))
   (chk (nm "inner U+FEFF" how) (returned "a\xFEFF;b")
        (read-out1 how "\"a\xFEFF;b\""))
   ;; --- options, each non-default ---
   (chk (nm "object-mode hashtable, last duplicate wins" how)
        (returned '(table ("a" . 3) ("b" . (table ("x" . 2)))))
        (read-out how "{\"a\":1,\"b\":{\"x\":1,\"x\":2},\"a\":3}" 'object-mode 'hashtable))
   (chk (nm "default object-mode keeps duplicates" how)
        (returned '(("a" . 1) ("a" . 3)))
        (read-out1 how "{\"a\":1,\"a\":3}"))
   (chk (nm "number-mode exact" how) (returned (vector 1/2 100 -3/8 1/1000))
        (read-out how "[0.5,1e2,-0.375,1e-3]" 'number-mode 'exact))
   (chk (nm "number-mode text" how)
        (returned (vector '(num "0.50") '(num "1E2") '(num "-0") '(num "7")))
        (read-out how "[0.50,1E2,-0,7]" 'number-mode 'text))
   (chk (nm "default number-mode flonum" how) (returned (vector 0.5 100.0 7))
        (read-out1 how "[0.5,1e2,7]"))
   (chk (nm "digit-limit 3 allows 3 digits" how) (returned (vector 123))
        (read-out how "[123]" 'digit-limit 3))
   (chk (nm "digit-limit 3 refuses 4" how)
        (ascii-error how 'number-too-long 5)
        (read-out how "[1234]" 'digit-limit 3))
   (chk (nm "depth-limit 2 allows 2" how) (returned (vector (vector 1)))
        (read-out how "[[1]]" 'depth-limit 2))
   (chk (nm "depth-limit 2 refuses 3" how)
        (ascii-error how 'nesting-too-deep 3)
        (read-out how "[[[1]]]" 'depth-limit 2))
   (chk (nm "depth-limit 0 allows a scalar only" how)
        (list (returned 5) (ascii-error how 'nesting-too-deep 1))
        (let* ((a (read-out how "5" 'depth-limit 0))
               (b (read-out how "[]" 'depth-limit 0)))
          (list a b)))
   (chk (nm "null nil" how) (returned (vector 'nil "x"))
        (read-out how "[null,\"x\"]" 'null 'nil))
   (chk (nm "null record" how) (returned (vector the-null 1))
        (read-out how "[null,1]" 'null the-null))
   ;; --- the one-argument form is (make-json-options) ---
   (chk (nm "default depth 512 is allowed" how) (returned 512)
        (let ((r (read-out1 how (string-append (make-string 512 #\[) (make-string 512 #\])))))
          (returned (nest-depth (cadr r)))))
   (chk (nm "default depth 513 is refused" how)
        (ascii-error how 'nesting-too-deep 513)
        (read-out1 how (string-append (make-string 513 #\[) (make-string 513 #\]))))
   (chk (nm "default null is the symbol null" how) (returned (vector 'null))
        (read-out1 how "[null]"))
   (chk (nm "default digit-limit 1000: 1000 digits" how) (returned 1000)
        (let ((r (read-out1 how (string-append "[" (make-string 1000 #\1) "]"))))
          (returned (string-length (number->string (vector-ref (cadr r) 0))))))
   (chk (nm "default digit-limit 1000: 1001 digits" how)
        (ascii-error how 'number-too-long 1002)
        (read-out1 how (string-append "[" (make-string 1001 #\1) "]"))))
 hows)

;; --- 2. Reading errors ---------------------------------------------------------

;; (text reason offset): ASCII, so characters and bytes agree.
(define ascii-errors
  (list
   (list "[1,2,]" 'unexpected-byte 5)
   (list "{\"a\":nul" 'unexpected-eof 8)
   (list "" 'unexpected-eof 0)
   (list "[1," 'unexpected-eof 3)
   (list "01" 'invalid-number 1)
   (list "[-]" 'invalid-number 2)
   (list "\"\\q\"" 'invalid-escape 2)
   (list "\"\\ud800\"" 'invalid-surrogate 7)
   (list "\"\x1;\"" 'control-character 1)
   (list "[true] x" 'trailing-garbage 7)
   (list "1 2" 'trailing-garbage 2)))

(for-each
 (lambda (how)
   (for-each
    (lambda (row)
      (chk (nm "error" how (car row))
           (ascii-error how (cadr row) (caddr row))
           (read-out how (car row))))
    ascii-errors)
   (chk (nm "number-out-of-range" how) (ascii-error how 'number-out-of-range 5)
        (read-out how "1e999"))
   (chk (nm "number-out-of-range, exact" how) (ascii-error how 'number-out-of-range 14)
        (read-out how "[1e99999999999]" 'number-mode 'exact))
   (chk (nm "number-too-long, exact" how) (ascii-error how 'number-too-long 4)
        (read-out how "1234" 'number-mode 'exact 'digit-limit 2))
   (chk (nm "text mode has no digit limit" how)
        (returned (vector '(num "1e1000000")))
        (read-out how "[1e1000000]" 'number-mode 'text 'digit-limit 2))
   ;; the options reach the error too
   (chk (nm "nesting-too-deep under depth-limit 1" how)
        (ascii-error how 'nesting-too-deep 2)
        (read-out how "[[1]]" 'depth-limit 1)))
 hows)

;; Errors after multibyte characters, in characters and in bytes.
;; Each row: text, reason, character offset, byte offset.
(define multibyte-errors
  (list
   ;; [ " C " , ]  with C of 1, 2, 3 and 4 bytes: the ] is at character 5
   (list "[\"a\",]" 'unexpected-byte 5 5)
   (list "[\"\xE9;\",]" 'unexpected-byte 5 6)
   (list "[\"\x20AC;\",]" 'unexpected-byte 5 7)
   (list "[\"\x1F600;\",]" 'unexpected-byte 5 8)
   (list "[\"a\xE9;\x20AC;\x1F600;\",]" 'unexpected-byte 8 14)
   (list "[\"\xE9;\xE9;\x20AC;\x20AC;\",]" 'unexpected-byte 8 14)
   ;; the error is on a multibyte character itself
   (list "[\xE9;]" 'unexpected-byte 1 1)
   (list "[\x1F600;]" 'unexpected-byte 1 1)
   (list "[1,\x20AC;]" 'unexpected-byte 3 3)
   (list "[\"\xE9;\" \x1F600;]" 'unexpected-byte 5 6)
   (list "[tru\x3b1;]" 'unexpected-byte 4 4)
   (list "[1\x3b1;]" 'unexpected-byte 2 2)
   (list "[-\x3b1;]" 'invalid-number 2 2)
   (list "[1.\x3b1;]" 'invalid-number 3 3)
   (list "[1]\x20AC;" 'trailing-garbage 3 3)
   (list "[\"\\\x3b1;\"]" 'invalid-escape 3 3)
   (list "[\"\x1F600;\x20AC;\\q\"]" 'invalid-escape 5 10)
   (list "[\"\\ud800\x3b1;\"]" 'invalid-surrogate 8 8)
   (list "\"\xE9;\x1;\"" 'control-character 2 3)
   (list "\"\x1F600;\x1F600;\x1;\"" 'control-character 3 9)
   ;; the end of the input, after multibyte characters
   (list "[\"\x3b1;\"" 'unexpected-eof 4 5)
   (list "[\"\x1F600;\x20AC;\x3b1;" 'unexpected-eof 5 11)
   (list "\"\x1F600;" 'unexpected-eof 2 5)
   ;; offset 0
   (list "x" 'unexpected-byte 0 0)
   (list "\x20AC;" 'unexpected-byte 0 0)
   ;; U+FEFF first is the bytes EF BB BF: JSON allows none before a value
   (list "\xFEFF;[]" 'unexpected-byte 0 0)
   (list "\xFEFF;" 'unexpected-byte 0 0)
   (list "[\xFEFF;]" 'unexpected-byte 1 1)
   (list "[1,\"\xFEFF;\"\xFEFF;" 'unexpected-byte 6 8)))

(for-each
 (lambda (how)
   (for-each
    (lambda (row)
      (chk (nm "multibyte error" how (car row))
           (reader-error how (cadr row) (caddr row) (cadddr row))
           (read-out how (car row))))
    multibyte-errors))
 hows)

;; The same error through a short form and with options is the same condition.
(chk "string->json short form error"
     (raised 'unexpected-byte 3 'string->json "unexpected-byte at character 3")
     (outcome (lambda () (string->json "[1,\x3b1;]"))))
(chk "string->json with options, error"
     (raised 'unexpected-byte 3 'string->json "unexpected-byte at character 3")
     (outcome (lambda () (string->json "[1,\x3b1;]" (l:make-json-options 'indent 3)))))

;; The first character U+FEFF, as bytes and in a string.
(chk "bytevector: BOM first"
     (raised 'unexpected-byte 0 'bytevector->json "unexpected-byte at byte 0")
     (outcome (lambda () (bytevector->json (u8-list->bytevector '(#xEF #xBB #xBF 91 93))))))
(chk "port: BOM first"
     (raised 'unexpected-byte 0 'read-json "unexpected-byte at byte 0")
     (outcome (lambda ()
                (read-json (open-bytevector-input-port
                            (u8-list->bytevector '(#xEF #xBB #xBF 91 93)))))))

;; invalid-utf8 exists only for bytes and ports.
(define bad-utf8
  ;; bytes, offset
  (list (list '(34 #xC3 #x28 34) 2)
        (list '(34 #xC0 #x80 34) 1)
        (list '(34 #xE2 #x82 34) 3)
        (list '(34 #xF0 #x9F #x98 34) 4)
        (list '(34 #xED #xA0 #x80 34) 2)
        (list '(34 #x80 34) 1)
        (list '(91 49 44 34 #xC3 #x28 34 93) 5)))
(for-each
 (lambda (how)
   (for-each
    (lambda (row)
      (chk (nm "invalid-utf8" how (number->string (car (car row))) (number->string (cadr row)))
           (raised 'invalid-utf8 (cadr row) (who-of how)
                   (string-append "invalid-utf8 at byte " (number->string (cadr row))))
           (let ((bv (u8-list->bytevector (car row))))
             (outcome (lambda ()
                        (if (eq? how 'bytes)
                            (bytevector->json bv)
                            (read-json (open-bytevector-input-port bv))))))))
    bad-utf8))
 '(bytes port))
(chk "bytevector: truncated multibyte character at the end"
     (raised 'unexpected-eof 2 'bytevector->json "unexpected-eof at byte 2")
     (outcome (lambda () (bytevector->json (u8-list->bytevector '(34 #xC3))))))

;; --- 3. read-json and ports ----------------------------------------------------

;; padded : Natural -> String   a valid document N characters long: #(1)
(define (padded n) (string-append "[" (spaces (- n 3)) "1]"))
;; long-string : Natural -> String   a document N characters long: a string
(define (long-string n) (string-append "\"" (make-string (- n 2) #\a) "\""))

(for-each
 (lambda (n)
   (let ((ns (number->string n)))
     ;; only a port is read in chunks
     (chk (nm "size array" ns) (returned (vector 1)) (read-out1 'port (padded n)))
     (chk (nm "size string" ns) (returned (make-string (- n 2) #\a))
          (read-out1 'port (long-string n)))
     (let ((p (open-bytevector-input-port (string->utf8 (padded n)))))
       (chk (nm "size array, port left at its end" ns) (list (returned (vector 1)) n #t)
            (let* ((r (outcome (lambda () (read-json p))))
                   (pos (port-position p))
                   (eof (eof-object? (get-u8 p))))
              (list r pos eof))))))
 '(16383 16384 16385 32769))

;; A document, then a lot of whitespace: the port is read to its end.
(let ((p (open-bytevector-input-port (string->utf8 (string-append "[1]" (spaces 40000))))))
  (chk "success reads to EOF" (list (returned (vector 1)) 40003 #t)
       (let* ((r (outcome (lambda () (read-json p))))
              (pos (port-position p))
              (eof (eof-object? (get-u8 p))))
         (list r pos eof))))

;; error-doc : Natural -> String
;; A document of 50000 characters whose first error, an x, is at index E.
(define (error-doc e)
  (let ((head (string-append "[" (spaces (- e 1)) "x")))
    (string-append head (spaces (- 50000 (string-length head))))))

;; After an error, the port has been read to the end of the 16384-byte
;; chunk that holds it, and no further.
(for-each
 (lambda (row)
   (let* ((e (car row)) (es (number->string e))
          (p (open-bytevector-input-port (string->utf8 (error-doc e)))))
     (chk (nm "error byte" es "port position")
          (list (ascii-error 'port 'unexpected-byte e) (cadr row))
          (let* ((r (outcome (lambda () (read-json p))))
                 (pos (port-position p)))
            (list r pos)))
     ;; the same through a port that gives one byte at a time
     (let* ((doc (string->utf8 (error-doc e)))
            (given 0)
            (cp (make-custom-binary-input-port
                 "slow"
                 (lambda (bv start count)
                   (if (>= given (bytevector-length doc))
                       0
                       (begin (bytevector-u8-set! bv start (bytevector-u8-ref doc given))
                              (set! given (+ given 1))
                              1)))
                 #f #f #f)))
       (chk (nm "error byte" es "one byte per read, bytes taken")
            (list (ascii-error 'port 'unexpected-byte e) (cadr row))
            (let* ((r (outcome (lambda () (read-json cp)))))
              (list r given))))))
 ;; error index, port position after
 '((5 16384) (16383 16384) (16384 32768) (32767 32768) (32768 49152)
   (49151 49152) (49152 50000) (49999 50000)))

;; A custom port that gives one byte per read: value, and EOF.
(let* ((doc (string->utf8 (string-append "{\"k\":[1, 2.5, \"\x3b1;\", null]}" (spaces 20000))))
       (given 0)
       (cp (make-custom-binary-input-port
            "slow"
            (lambda (bv start count)
              (if (>= given (bytevector-length doc))
                  0
                  (begin (bytevector-u8-set! bv start (bytevector-u8-ref doc given))
                         (set! given (+ given 1))
                         1)))
            #f #f #f)))
  (chk "one byte per read: value, all taken"
       (list (returned '(("k" . #(1 2.5 "\x3b1;" null)))) 20026)
       (let ((r (outcome (lambda () (read-json cp)))))
         (list r given))))

;; A multibyte character split across the chunk boundary at 16384.
;; Each row: the character, its bytes before the boundary.
(for-each
 (lambda (row)
   (let* ((c (car row)) (j (cadr row))
          (lead (- 16384 j 1))
          (text (string-append "\"" (make-string lead #\a) c "bbbbbbbbbb\""))
          (want (string-append (make-string lead #\a) c "bbbbbbbbbb")))
     (for-each
      (lambda (how)
        (chk (nm "split character" (number->string (string-length c)) (number->string j) how)
             (returned want)
             (read-out1 how text)))
      hows)))
 '(("\xE9;" 1) ("\x20AC;" 1) ("\x20AC;" 2) ("\x1F600;" 1) ("\x1F600;" 2) ("\x1F600;" 3)))

;; An invalid byte straight after the boundary.
(let ((bv (u8-list->bytevector
           (append '(34) (make-list 16382 97) '(#xE2 #x28 34)))))
  (chk "invalid-utf8 right after the chunk boundary"
       (raised 'invalid-utf8 16384 'read-json "invalid-utf8 at byte 16384")
       (outcome (lambda () (read-json (open-bytevector-input-port bv))))))

;; Errors in the second chunk and later.
(for-each
 (lambda (how)
   (chk (nm "error in the second chunk" how)
        (ascii-error how 'unexpected-byte 20003)
        (read-out how (string-append "[" (spaces 20000) "1,]x")))
   (chk (nm "error in the second chunk after multibyte characters" how)
        (reader-error how 'unexpected-byte 10004 20004)
        (read-out how (string-append "[\"" (make-string 10000 #\x3b1) "\",]")))
   (chk (nm "error in the fourth chunk" how)
        (ascii-error how 'trailing-garbage 50001)
        (read-out how (string-append "[1]" (spaces 49998) "x"))))
 hows)

;; Only a port is read in chunks.
(chk "nested document over many chunks"
     (returned (nest-vec 299 (vector)))
     (read-out 'port (string-append (make-string 300 #\[) (spaces 20000) (make-string 300 #\]))))
(chk "number split across the boundary"
     (returned (vector 12345.5))
     (read-out 'port (string-append "[" (spaces 16380) "12345.5]")))

;; A port that is not at its start: offsets count from where it was.
(let ((p (open-bytevector-input-port (string->utf8 "xyz12[1,]"))))
  (get-bytevector-n p 5)
  (chk "port not at its start, error"
       (list (raised 'unexpected-byte 3 'read-json "unexpected-byte at byte 3") 9)
       (let ((r (outcome (lambda () (read-json p)))))
         (list r (port-position p)))))
(let ((p (open-bytevector-input-port (string->utf8 "xyz12{\"a\":[true]}"))))
  (get-bytevector-n p 5)
  (chk "port not at its start, value" (returned '(("a" . #(#t))))
       (outcome (lambda () (read-json p)))))
(let ((p (open-bytevector-input-port
          (string->utf8 (string-append (spaces 100) "[" (spaces 16400) "x")))))
  (get-bytevector-n p 100)
  (chk "port not at its start, error in the second chunk"
       (raised 'unexpected-byte 16401 'read-json "unexpected-byte at byte 16401")
       (outcome (lambda () (read-json p)))))

;; An empty port.
(chk "empty port"
     (raised 'unexpected-eof 0 'read-json "unexpected-eof at byte 0")
     (outcome (lambda () (read-json (open-bytevector-input-port (make-bytevector 0))))))
(chk "port at its end"
     (raised 'unexpected-eof 0 'read-json "unexpected-eof at byte 0")
     (let ((p (open-bytevector-input-port (string->utf8 "[]"))))
       (get-bytevector-n p 2)
       (outcome (lambda () (read-json p)))))
(chk "empty bytevector"
     (raised 'unexpected-eof 0 'bytevector->json "unexpected-eof at byte 0")
     (outcome (lambda () (bytevector->json (make-bytevector 0)))))

;; Re-entrancy: a port whose read procedure calls the readers on other
;; documents while a read is under way. The outer document is long enough for
;; two chunks, and the port gives a byte at a time, so a read buffer or a
;; builder shared between calls would be overwritten mid-read.
;; reentrant-port : Bytevector Natural (-> Any) -> Binary-Input-Port
;; Calls INNER on every EVERY-th call of its read procedure.
(define (reentrant-port doc every inner)
  (let ((given 0) (calls 0))
    (make-custom-binary-input-port
     "reentrant"
     (lambda (bv start count)
       (set! calls (+ calls 1))
       (when (= 0 (mod calls every)) (inner))
       (if (>= given (bytevector-length doc))
           0
           (begin (bytevector-u8-set! bv start (bytevector-u8-ref doc given))
                  (set! given (+ given 1))
                  1)))
     #f #f #f)))

;; distinct : (Listof Any) -> (Listof Any)   by equal?
(define (distinct xs)
  (let loop ((xs xs) (acc '()))
    (cond ((null? xs) (reverse acc))
          ((member (car xs) acc) (loop (cdr xs) acc))
          (else (loop (cdr xs) (cons (car xs) acc))))))

(let* ((inner-log '())
       (deep-log '())
       (deep
        (lambda ()
          (set! deep-log
                (cons (outcome (lambda ()
                                 (string->json "[true,{\"z\":false}]"
                                               (l:make-json-options 'object-mode 'hashtable))))
                      deep-log))))
       (inner
        (lambda ()
          (let* ((a (outcome (lambda ()
                               (read-json (reentrant-port (string->utf8 "{\"q\":[\"zzz\",9,null]}")
                                                          5 deep)
                                          (l:make-json-options 'null 'nil)))))
                 (b (outcome (lambda ()
                               (string->json "[8,8,8]" (l:make-json-options 'number-mode 'text)))))
                 (c (outcome (lambda () (bytevector->json (string->utf8 "[1,2,"))))))
            (set! inner-log (cons (list a b c) inner-log)))))
       (doc (string->utf8 (string-append "[" (apply string-append (make-list 8300 "1,")) "2]")))
       (p (reentrant-port doc 500 inner))
       (r (outcome (lambda () (read-json p)))))
  (chk "re-entrant read, outer value"
       (returned (list->vector (append (make-list 8300 1) '(2))))
       r)
  (chk "re-entrant read, every inner read kept its own result"
       (list (list (returned '(("q" . #("zzz" 9 nil))))
                   (returned (vector '(num "8") '(num "8") '(num "8")))
                   (raised 'unexpected-eof 5 'bytevector->json "unexpected-eof at byte 5")))
       (distinct inner-log))
  (chk "re-entrant read, every inner-inner read kept its own result"
       (list (returned (vector #t '(table ("z" . #f)))))
       (distinct deep-log)))

;; --- 4. Writing ------------------------------------------------------------------

;; Three ways to write V under OPT ...: json->string, json->bytevector (as a
;; string of one character per byte) and write-json after the bytes "pre".
(define (wr-string v . opts) (json->string v (apply l:make-json-options opts)))
(define (wr-bytes v . opts) (bv->str (json->bytevector v (apply l:make-json-options opts))))
(define (wr-port v . opts)
  (let-values (((p extract) (open-bytevector-output-port)))
    (put-bytevector p (string->utf8 "pre"))
    (write-json p v (apply l:make-json-options opts))
    (bv->str (extract))))
;; utf8 : String -> String   the string's UTF-8 bytes, one character per byte
(define (utf8 s) (bv->str (string->utf8 s)))

;; Each row: value, options, the JSON text.
(define write-cases
  (list
   (list '() '() "{}")
   (list (vector) '() "[]")
   (list 'null '() "null")
   (list #t '() "true")
   (list #f '() "false")
   (list "x" '() "\"x\"")
   (list -17 '() "-17")
   (list 2.5 '() "2.5")
   (list 1/8 '() "0.125")
   (list (expt 10 30) '() "1000000000000000000000000000000")
   (list (l:make-json-number "1.50e+3") '() "1.50e+3")
   (list '(("k" . #(1 "x" #t #f null)) ("j" . ())) '()
         "{\"k\":[1,\"x\",true,false,null],\"j\":{}}")
   (list (table (cons "b" 2) (cons "a" 1)) '() "{\"a\":1,\"b\":2}")
   (list "a\"b\\c\n\x1;" '() "\"a\\\"b\\\\c\\n\\u0001\"")
   (list "\xE9;\x20AC;\x1F600;" '() "\"\xE9;\x20AC;\x1F600;\"")
   (list "\xFEFF;a" '() "\"\xFEFF;a\"")
   (list "\xFEFF;" '() "\"\xFEFF;\"")
   (list '(("\xE9;" . "\x3b1;")) '() "{\"\xE9;\":\"\x3b1;\"}")
   (list '(("a" . #(1 2)) ("b" . 3)) '(indent 2)
         "{\n  \"a\": [\n    1,\n    2\n  ],\n  \"b\": 3\n}")
   (list (vector 'nil 1 'nil) '(null nil) "[null,1,null]")
   (list (vector the-null "x") (list 'null the-null) "[null,\"x\"]")
   (list '(("a" . nil)) '(null nil) "{\"a\":null}")
   (list (nest-vec 2 (vector)) '(depth-limit 3) "[[[]]]")))

(for-each
 (lambda (row)
   (let ((v (car row)) (opts (cadr row)) (text (caddr row)))
     (chk (nm "json->string" text) text (apply wr-string v opts))
     (chk (nm "json->bytevector" text) (utf8 text) (apply wr-bytes v opts))
     (chk (nm "write-json" text) (string-append "pre" (utf8 text)) (apply wr-port v opts))))
 write-cases)

(chk "json->bytevector bytes of a non-ASCII string"
     '(34 #xC3 #xA9 #xE2 #x82 #xAC #xF0 #x9F #x98 #x80 34)
     (bytevector->u8-list (json->bytevector "\xE9;\x20AC;\x1F600;")))
(chk "json->bytevector bytes of a string starting with U+FEFF"
     '(34 #xEF #xBB #xBF 97 34)
     (bytevector->u8-list (json->bytevector "\xFEFF;a")))
(chk "json->string of a string starting with U+FEFF keeps it, length"
     (list 4 #\" #\xFEFF #\a #\")
     (let ((s (json->string "\xFEFF;a")))
       (cons (string-length s) (string->list s))))

;; The short forms use the defaults: null is the symbol null, indent 0.
(chk "short forms: default null and compact"
     (list "[null,{\"a\":[1]}]" "[null,{\"a\":[1]}]" "pre[null,{\"a\":[1]}]")
     (let ((v (vector 'null '(("a" . #(1))))))
       (let-values (((p extract) (open-bytevector-output-port)))
         (put-bytevector p (string->utf8 "pre"))
         (write-json p v)
         (let* ((a (json->string v)) (b (bv->str (json->bytevector v))) (c (bv->str (extract))))
           (list a b c)))))
(chk "short forms: default depth-limit 512"
     (list (returned 1024) (raised 'nesting-too-deep #f 'json->string m-deep (vector)))
     (let* ((a (outcome (lambda () (string-length (json->string (nest-vec 511 (vector)))))))
            (b (outcome (lambda () (json->string (nest-vec 512 (vector)))))))
       (list a b)))

(chk "short forms: default null is not nil"
     (list (raised 'unwritable-value #f 'json->string m-val 'nil)
           (raised 'unwritable-value #f 'json->bytevector m-val 'nil)
           (raised 'unwritable-value #f 'write-json m-val 'nil))
     (let* ((a (outcome (lambda () (json->string (vector 'nil)))))
            (b (outcome (lambda () (json->bytevector (vector 'nil)))))
            (c (outcome (lambda ()
                          (let-values (((p extract) (open-bytevector-output-port)))
                            (write-json p (vector 'nil)))))))
       (list a b c)))

;; Refusals: put-json's, raised again with the easy procedure as the who.
(define circular-list (let ((l (list (cons "a" 1)))) (set-cdr! l l) l))
(define dup-table (let ((h (make-eqv-hashtable)))
                    (hashtable-set! h (string-copy "a") 1)
                    (hashtable-set! h (string-copy "a") 2)
                    h))
(define self-vec (let ((v (vector 0))) (vector-set! v 0 v) v))
(define improper (cons (cons "a" 1) 5))
(define key-table (let ((h (make-eqv-hashtable))) (hashtable-set! h 1 "x") h))

;; Each row: value, options, reason, message, irritants (the list), hide.
(define refusal-cases
  (list
   (list 1/3 '() 'unwritable-number m-num (list 1/3) '())
   (list (vector 1 "ok" +inf.0) '() 'unwritable-number m-num (list +inf.0) '())
   (list (list (cons "a" (vector 2.5 (expt 2 70)))  (cons 1 2)) '() 'unwritable-key m-key (list 1) '())
   (list 'sym '() 'unwritable-value m-val (list 'sym) '())
   (list (vector "a" (vector 'nil)) '() 'unwritable-value m-val (list 'nil) '())
   (list (vector 'null) '(null nil) 'unwritable-value m-val (list 'null) '())
   (list improper '() 'unwritable-value m-list (list improper) '())
   (list (list (cons "a" 1) 5) '() 'unwritable-value m-member (list 5) '())
   (list circular-list '() 'unwritable-value m-list (list 'hidden) (list circular-list))
   (list (vector (vector 1)) '(depth-limit 1) 'nesting-too-deep m-deep (list (vector 1)) '())
   (list self-vec '() 'nesting-too-deep m-deep (list 'hidden) (list self-vec))
   (list dup-table '() 'unwritable-key m-dup (list "a") '())
   (list key-table '() 'unwritable-key m-key (list 1) '())))

(for-each
 (lambda (row)
   (let* ((v (car row)) (opts (cadr row)) (reason (caddr row)) (message (cadddr row))
          (irritants (list-ref row 4)) (hide (list-ref row 5))
          (o (apply l:make-json-options opts))
          (label (symbol->string reason))
          (want (lambda (who) (list 'raised reason #f who message irritants #t #f)))
          (run (lambda (thunk) (apply outcome thunk hide))))
     (chk (nm "put-json" label message) (want 'put-json)
          (run (lambda () (let-values (((p extract) (open-bytevector-output-port)))
                            (put-json p v o)))))
     (chk (nm "json->string" label message) (want 'json->string)
          (run (lambda () (json->string v o))))
     (chk (nm "json->bytevector" label message) (want 'json->bytevector)
          (run (lambda () (json->bytevector v o))))
     (chk (nm "write-json" label message) (want 'write-json)
          (run (lambda () (let-values (((p extract) (open-bytevector-output-port)))
                            (write-json p v o)))))
     ;; nothing written on a refusal
     (chk (nm "write-json writes nothing" label message) "pre"
          (let-values (((p extract) (open-bytevector-output-port)))
            (put-bytevector p (string->utf8 "pre"))
            (run (lambda () (write-json p v o)))
            (bv->str (extract))))))
 refusal-cases)

;; A refusal in the middle of a long value writes nothing either.
(chk "write-json writes nothing for a late refusal"
     (list (raised 'unwritable-number #f 'write-json m-num 1/3) "pre")
     (let-values (((p extract) (open-bytevector-output-port)))
       (put-bytevector p (string->utf8 "pre"))
       (let ((r (outcome (lambda () (write-json p (vector "aaaa" '(("k" . #(1 2))) 1/3))))))
         (list r (bv->str (extract))))))

;; --- 5. json-ref -----------------------------------------------------------------

(define (ref v . steps) (outcome (lambda () (apply json-ref v steps))))
(define (not-found . steps) (raised 'not-found #f 'json-ref "no value at the end of this path" steps))

(chk "json-ref: alist member" (returned 2) (ref '(("a" . 1) ("b" . 2)) "b"))
(chk "json-ref: alist, the last duplicate wins" (returned 3)
     (ref '(("a" . 1) ("b" . 2) ("a" . 3)) "a"))
(chk "json-ref: alist, the last of three" (returned 'last)
     (ref '(("a" . first) ("a" . mid) ("a" . last) ("b" . 0)) "a"))
(chk "json-ref: alist, missing" (not-found "c") (ref '(("a" . 1)) "c"))
(chk "json-ref: key text is case-sensitive" (not-found "A") (ref '(("a" . 1)) "A"))
(chk "json-ref: an alist's value is returned whole" (returned '(("x" . #(1))))
     (ref '(("a" . (("x" . #(1))))) "a"))
(chk "json-ref: a string key in an alist with fresh text" (returned 1)
     (ref '(("abc" . 1)) (string-copy "abc")))
(chk "json-ref: composed and decomposed e-acute differ"
     (list (returned 1) (returned 2))
     (let* ((al (list (cons "\xE9;" 1) (cons "e\x301;" 2)))
            (a (ref al "\xE9;")) (b (ref al "e\x301;")))
       (list a b)))
(chk "json-ref: the empty alist" (not-found "a") (ref '() "a"))

;; Values that are false-looking are found, not missing.
(define falsy-members
  (list (cons "f" #f) (cons "n" 'null) (cons "e" '()) (cons "z" 0) (cons "s" "") (cons "v" (vector))))
(for-each
 (lambda (row)
   (chk (nm "json-ref: falsy value in an alist" (car row)) (returned (cdr row))
        (ref falsy-members (string-copy (car row)))))
 falsy-members)
(chk "json-ref: falsy values in a vector" (list (returned #f) (returned 'null) (returned '()) (returned 0))
     (let* ((v (vector #f 'null '() 0))
            (a (ref v 0)) (b (ref v 1)) (c (ref v 2)) (d (ref v 3)))
       (list a b c d)))
(chk "json-ref: falsy values through a path" (returned #f)
     (ref (vector (list (cons "k" (vector 1 #f)))) 0 "k" 1))

;; Hashtables of each equivalence: keys fresh strings, lookup by text.
(define table-kinds
  (list (cons 'string=? (lambda () (make-hashtable string-hash string=?)))
        (cons 'equal (lambda () (make-hashtable equal-hash equal?)))
        (cons 'eqv make-eqv-hashtable)
        (cons 'eq make-eq-hashtable)))

(for-each
 (lambda (kind)
   (let* ((k (car kind))
          (h (fill! ((cdr kind))
                    (list (cons "a" 1) (cons "A" 2) (cons "\xE9;" 3) (cons "\xC9;" 4)
                          (cons "e\x301;" 5) (cons "abc" 6)))))
     (for-each
      (lambda (row)
        (chk (nm "json-ref: table" k (car row)) (returned (cdr row))
             (ref h (string-copy (car row)))))
      '(("a" . 1) ("A" . 2) ("\xE9;" . 3) ("\xC9;" . 4) ("e\x301;" . 5) ("abc" . 6)))
     (chk (nm "json-ref: table, falsy values" k)
          (list (returned #f) (returned 'null) (returned '()))
          (let ((h2 (fill! ((cdr kind)) (list (cons "f" #f) (cons "n" 'null) (cons "e" '())))))
            (let* ((a (ref h2 "f")) (b (ref h2 "n")) (c (ref h2 "e"))) (list a b c))))
     (chk (nm "json-ref: table, missing" k) (not-found "zz") (ref h "zz"))
     (chk (nm "json-ref: table, a prefix of a key" k) (not-found "ab") (ref h "ab"))
     (chk (nm "json-ref: table, nested path" k) (returned 6)
          (ref (list (cons "t" (vector 0 h))) "t" 1 (string-copy "abc") ) )))
 table-kinds)

;; A string-ci=? table merges case; the lookup is by text all the same.
(let ((h (fill! (make-hashtable string-ci-hash string-ci=?)
                (list (cons "Abc" 1) (cons "\xE9;" 2) (cons "e\x301;" 3)))))
  (chk "json-ref: ci table, same text" (list (returned 1) (returned 2) (returned 3))
       (let* ((a (ref h (string-copy "Abc"))) (b (ref h "\xE9;")) (c (ref h "e\x301;")))
         (list a b c)))
  (chk "json-ref: ci table, other case is not found" (not-found "abc") (ref h "abc"))
  (chk "json-ref: ci table, other case is not found, upper" (not-found "ABC") (ref h "ABC"))
  (chk "json-ref: ci table, other case, non-ASCII" (not-found "\xC9;") (ref h "\xC9;")))

;; Two keys with the same text in a table not keyed by string=?.
(chk "json-ref: eqv table with two same-text keys"
     (raised 'unwritable-key #f 'json-ref m-dup "a")
     (ref dup-table "a"))
(chk "json-ref: eqv table with two same-text keys, reached through a path"
     (raised 'unwritable-key #f 'json-ref m-dup "a")
     (ref (vector 0 (list (cons "t" dup-table))) 1 "t" "a"))
(let ((h (make-eq-hashtable)))
  (hashtable-set! h (string-copy "k") 1)
  (hashtable-set! h (string-copy "k") 2)
  (hashtable-set! h (string-copy "q") 3)
  (chk "json-ref: eq table with two same-text keys, and one other"
       (list (raised 'unwritable-key #f 'json-ref m-dup "k") (returned 3))
       (let* ((a (ref h "k")) (b (ref h "q"))) (list a b))))

;; vectors
(let ((v (vector 'a 'b 'c)))
  (chk "json-ref: vector index 0" (returned 'a) (ref v 0))
  (chk "json-ref: vector last index" (returned 'c) (ref v 2))
  (chk "json-ref: vector one past the end" (not-found 3) (ref v 3))
  (chk "json-ref: vector far past the end" (not-found 99) (ref v 99))
  (chk "json-ref: empty vector" (not-found 0) (ref (vector) 0))
  (chk "json-ref: bignum step is just not found" (not-found (expt 10 30)) (ref v (expt 10 30)))
  (chk "json-ref: bignum step into an alist is just not found" (not-found (expt 10 30))
       (ref '(("a" . 1)) (expt 10 30))))

;; zero steps
(chk "json-ref: zero steps, a scalar" (returned 5) (ref 5))
(chk "json-ref: zero steps, a value JSON can't write" (returned 'sym) (ref 'sym))
(chk "json-ref: zero steps, a ratio" (returned 1/3) (ref 1/3))
(chk "json-ref: zero steps, the null list" (returned '()) (ref '()))
(chk "json-ref: zero steps, a table is itself"
     #t (let ((h (table (cons "a" 1)))) (eq? (json-ref h) h)))
(chk "json-ref: zero steps, a vector is itself"
     #t (let ((v (vector 1))) (eq? (json-ref v) v)))
(chk "json-ref: zero steps, a circular list is itself"
     #t (eq? (json-ref circular-list) circular-list))

;; a step into a value of the wrong kind
(chk "json-ref: key into a number" (not-found "a") (ref 5 "a"))
(chk "json-ref: key into a string" (not-found "a") (ref "a" "a"))
(chk "json-ref: key into a vector" (not-found "a") (ref (vector 1) "a"))
(chk "json-ref: key into #t" (not-found "a") (ref #t "a"))
(chk "json-ref: key into null" (not-found "a") (ref 'null "a"))
(chk "json-ref: key into the empty list" (not-found "a") (ref '() "a"))
(chk "json-ref: index into an alist" (not-found 0) (ref '(("a" . 1)) 0))
(chk "json-ref: index into the empty list" (not-found 0) (ref '() 0))
(chk "json-ref: index into a table" (not-found 0) (ref (table (cons "0" 1)) 0))
(chk "json-ref: index into a string" (not-found 0) (ref "abc" 0))
(chk "json-ref: index into a number" (not-found 0) (ref 7 0))
(chk "json-ref: index into #f" (not-found 0) (ref #f 0))

;; improper, circular and non-pair members
(chk "json-ref: improper list"
     (raised 'unwritable-value #f 'json-ref m-list improper)
     (ref improper "b"))
(chk "json-ref: circular list"
     (raised 'unwritable-value #f 'json-ref m-list 'hidden)
     (outcome (lambda () (json-ref circular-list "b")) circular-list))
(chk "json-ref: a member that is not a pair"
     (raised 'unwritable-value #f 'json-ref m-member 5)
     (ref (list (cons "a" 1) 5) "b"))
(chk "json-ref: a member that is not a pair, even after the key is found"
     (raised 'unwritable-value #f 'json-ref m-member 5)
     (ref (list (cons "a" 1) 5) "a"))
(chk "json-ref: a member that is not a pair, before the key"
     (raised 'unwritable-value #f 'json-ref m-member "str")
     (ref (list "str" (cons "a" 1)) "a"))
(chk "json-ref: a vector is not a list member"
     (raised 'unwritable-value #f 'json-ref m-member (vector 1))
     (ref (list (vector 1)) "a"))
(chk "json-ref: an improper list met in the middle of a path"
     (raised 'unwritable-value #f 'json-ref m-list improper)
     (ref (vector 0 improper) 1 "b"))

;; not-found: the steps taken, the failing step last
(let ((v '(("users" . #((("name" . "Ada") ("tags" . #("x" "y"))) (("name" . "Bo")))))))
  (chk "json-ref: a path" (returned "y") (ref v "users" 0 "tags" 1))
  (chk "json-ref: a path, the whole value" (returned "Bo") (ref v "users" 1 "name"))
  (chk "json-ref: failing at the first step" (not-found "people") (ref v "people" 0 "name"))
  (chk "json-ref: failing in the middle" (not-found "users" 2)
       (ref v "users" 2 "name"))
  (chk "json-ref: failing at the last step" (not-found "users" 0 "tags" 2)
       (ref v "users" 0 "tags" 2))
  (chk "json-ref: failing on a wrong kind, later steps not taken"
       (not-found "users" 0 "name" "first")
       (ref v "users" 0 "name" "first" "more")))
(chk "json-ref: path through tables of two kinds"
     (returned 'deep)
     (ref (list (cons "t" (fill! (make-eqv-hashtable)
                                 (list (cons "u" (vector 0 (table (cons "v" 'deep))))))))
          "t" "u" 1 "v"))
(chk "json-ref: the irritant is a fresh list of the steps"
     (list (list "a" 0 "b") #t)
     (let ((r (guard (e ((json-error? e) (condition-irritants e)))
                (json-ref '(("a" . #(1))) "a" 0 "b"))))
       (list (car r) (null? (cdr r)))))
(chk "json-ref: the irritant, who, offset" (list 'json-ref #f 'not-found)
     (guard (e ((json-error? e)
                (list (condition-who e) (json-error-offset e) (json-error-reason e))))
       (json-ref (vector) 0)))

;; a bad step is an assertion violation
(chk "json-ref: a symbol step" (violates 'json-ref 'a) (ref (vector 1 2) 'a))
(chk "json-ref: a flonum step" (violates 'json-ref 1.0) (ref (vector 1 2) 1.0))
(chk "json-ref: a negative step" (violates 'json-ref -1) (ref (vector 1 2) -1))
(chk "json-ref: a ratio step" (violates 'json-ref 1/2) (ref (vector 1 2) 1/2))
(chk "json-ref: a character step" (violates 'json-ref #\a) (ref '(("a" . 1)) #\a))
(chk "json-ref: #f step" (violates 'json-ref #f) (ref '(("a" . 1)) #f))
(chk "json-ref: a bad step after good ones" (violates 'json-ref 'x)
     (ref (vector (vector 1)) 0 0 'x))
(chk "json-ref: a bad step is refused even where an earlier step fails"
     (violates 'json-ref 'x) (ref 5 "a" 'x))
(chk "json-ref: a negative flonum zero is no step" (violates 'json-ref -0.0)
     (ref (vector 1) -0.0))

;; A default: 'default and a value, last. It replaces not-found only.
(define fallback (vector 'fallback))
(chk "json-ref: a default for a missing key, a past-the-end index and a wrong-kind step"
     (list (returned 'd) (returned 'd) (returned 'd) (returned 'd))
     (let* ((a (ref '(("a" . 1)) "b" 'default 'd))
            (b (ref (vector 1 2) 2 'default 'd))
            (c (ref (vector 1 2) "a" 'default 'd))
            (d (ref '(("a" . 1)) 0 'default 'd)))
       (list a b c d)))
(chk "json-ref: a default where the first step fails, and where the last does"
     (list (returned 'd) (returned 'd))
     (let* ((v (list (cons "a" (vector (list (cons "b" 1))))))
            (first (ref v "x" 0 "b" 'default 'd))
            (last (ref v "a" 0 "c" 'default 'd)))
       (list first last)))
(chk "json-ref: a value that is found wins over the default"
     (list (returned 3) (returned #f) (returned 'null) (returned '()) (returned 0) (returned ""))
     (let* ((a (ref '(("a" . 1) ("a" . 3)) "a" 'default 'd))
            (b (ref falsy-members "f" 'default 'd))
            (c (ref falsy-members "n" 'default 'd))
            (d (ref falsy-members "e" 'default 'd))
            (e (ref falsy-members "z" 'default 'd))
            (f (ref falsy-members "s" 'default 'd)))
       (list a b c d e f)))
(chk "json-ref: the default is returned itself, of any kind"
     (list #t "" 0 #f 'default '())
     (list (eq? fallback (json-ref '() "a" 'default fallback))
           (json-ref '() "a" 'default "")
           (json-ref (vector) 0 'default 0)
           (json-ref '(("a" . 1)) "b" 'default #f)
           (json-ref '(("a" . 1)) "b" 'default 'default)
           (json-ref '(("a" . 1)) "b" 'default '())))
(chk "json-ref: with no steps, a default gives the value itself"
     (returned '(("a" . 1)))
     (ref '(("a" . 1)) 'default 'd))
(let ((t (make-table)) (e (make-eqv-hashtable)))
  (hashtable-set! t "a" 1)
  (hashtable-set! e (string #\a) 1)
  (chk "json-ref: a default through hashtables"
       (list (returned 1) (returned 'd) (returned 1) (returned 'd))
       (let* ((a (ref t "a" 'default 'd)) (b (ref t "b" 'default 'd))
              (c (ref e "a" 'default 'd)) (d (ref e "b" 'default 'd)))
         (list a b c d))))
(chk "json-ref: a default doesn't hide a list that is not an alist"
     (list (raised 'unwritable-value #f 'json-ref
                   "a list that is not an alist: a member is not a pair" 5)
           (raised 'unwritable-value #f 'json-ref
                   "a list that is not an alist: it is improper or circular" (cons (cons "a" 1) 5)))
     (let* ((a (ref (list (cons "a" 1) 5) "b" 'default 'd))
            (b (ref (cons (cons "a" 1) 5) "b" 'default 'd)))
       (list a b)))
(let ((e (make-eqv-hashtable)))
  (hashtable-set! e (string #\a) 1)
  (hashtable-set! e (string #\a) 2)
  (chk "json-ref: a default doesn't hide two keys with one text"
       (raised 'unwritable-key #f 'json-ref "a hashtable holds two keys with the same text" "a")
       (ref e "a" 'default 'd)))
(chk "json-ref: a default doesn't excuse a bad step"
     (list (violates 'json-ref 'x) (violates 'json-ref -1))
     (let* ((a (ref (vector 1) 'x 'default 'd))
            (b (ref 5 "a" -1 'default 'd)))
       (list a b)))
(chk "json-ref: 'default with no value after it"
     (list (violates 'json-ref) (violates 'json-ref))
     (let* ((a (ref (vector 1) 0 'default))
            (b (ref (vector 1) 'default)))
       (list a b)))
(chk "json-ref: only the symbol default marks a default"
     (list (violates 'json-ref 'x) (violates 'json-ref 'dflt) (returned 2))
     (let* ((a (ref (vector 1) 'x 'd))
            (b (ref '(("a" . 1)) "b" 'dflt 'd))
            (c (ref '(("default" . (("x" . 2)))) "default" "x")))
       (list a b c)))
(chk "json-ref: 'default anywhere but second to last is a bad step"
     (list (violates 'json-ref 'default) (violates 'json-ref 'default))
     (let* ((a (ref (vector 1) 0 'default 'd 'e))
            (b (ref (vector 1) 'default 1 'default 2)))
       (list a b)))

;; --- 6. json=? ---------------------------------------------------------------------

(define (jeq a b . opts)
  (outcome (lambda () (json=? a b (apply l:make-json-options opts)))))
(define (jeq2 a b) (outcome (lambda () (json=? a b))))
(define yes (returned #t))
(define no (returned #f))

;; Forms of a member list: an alist, and hashtables of each equivalence
;; (when the members hold no duplicate key).
(define (alist-form ms) ms)
(define (table-forms ms)
  (list (fill! (make-hashtable string-hash string=?) ms)
        (fill! (make-hashtable equal-hash equal?) ms)
        (fill! (make-eqv-hashtable) ms)))
(define (forms ms) (cons ms (table-forms ms)))

;; every pair of forms of A and of B, both ways round: J=? gives WANT.
(define (all-forms-give want title a-members b-members)
  (let ((fa (forms a-members)) (fb (forms b-members)))
    (let loop-a ((xs fa) (i 0))
      (unless (null? xs)
        (let loop-b ((ys fb) (j 0))
          (unless (null? ys)
            (let ((x (car xs)) (y (car ys)))
              (chk (nm title (string-append "form " (number->string i) "," (number->string j)))
                   want (jeq2 x y))
              (chk (nm title (string-append "form " (number->string j) "," (number->string i) " flipped"))
                   want (jeq2 y x)))
            (loop-b (cdr ys) (+ j 1))))
        (loop-a (cdr xs) (+ i 1))))))

(all-forms-give yes "same members shuffled"
                (list (cons "a" 1) (cons "b" "x") (cons "c" #t))
                (list (cons "c" #t) (cons "a" 1) (cons "b" "x")))
(all-forms-give yes "same members, nested objects shuffled"
                (list (cons "o" (list (cons "p" 1) (cons "q" (vector 2 (list (cons "r" 3) (cons "s" 4)))))))
                (list (cons "o" (list (cons "q" (vector 2 (list (cons "s" 4) (cons "r" 3)))) (cons "p" 1)))))
(all-forms-give no "a subset of the members"
                (list (cons "a" 1))
                (list (cons "a" 1) (cons "b" 2)))
(all-forms-give no "the same keys, one value different"
                (list (cons "a" 1) (cons "b" 2) (cons "c" 3))
                (list (cons "a" 1) (cons "b" 2) (cons "c" 4)))
(all-forms-give no "keys differing in case"
                (list (cons "a" 1))
                (list (cons "A" 1)))
(all-forms-give no "keys differing in case, non-ASCII"
                (list (cons "\xE9;" 1))
                (list (cons "\xC9;" 1)))
(all-forms-give no "composed and decomposed keys"
                (list (cons "\xE9;" 1))
                (list (cons "e\x301;" 1)))
(all-forms-give no "a different key"
                (list (cons "a" 1) (cons "b" 2))
                (list (cons "a" 1) (cons "c" 2)))
(all-forms-give no "the same key count, one key moved"
                (list (cons "a" 1) (cons "b" 1))
                (list (cons "a" 1) (cons "a2" 1)))
(all-forms-give yes "empty" '() '())
(all-forms-give no "empty against one member" '() (list (cons "a" 1)))
(all-forms-give no "nested value differs deep"
                (list (cons "o" (list (cons "p" (vector 1 2 (list (cons "q" 1)))))))
                (list (cons "o" (list (cons "p" (vector 1 2 (list (cons "q" 2))))))))

;; duplicates: the last wins, in an alist
(let ((dup (list (cons "a" 1) (cons "b" 5) (cons "a" 2))))
  (chk "duplicates: alist against a table of the last"
       (list yes yes no no)
       (let* ((a (jeq2 dup (table (cons "a" 2) (cons "b" 5))))
              (b (jeq2 (table (cons "a" 2) (cons "b" 5)) dup))
              (c (jeq2 dup (table (cons "a" 1) (cons "b" 5))))
              (d (jeq2 (table (cons "a" 1) (cons "b" 5)) dup)))
         (list a b c d)))
  (chk "duplicates: alist against an alist of the last"
       (list yes yes no no)
       (let* ((a (jeq2 dup (list (cons "b" 5) (cons "a" 2))))
              (b (jeq2 (list (cons "b" 5) (cons "a" 2)) dup))
              (c (jeq2 dup (list (cons "a" 1) (cons "b" 5))))
              (d (jeq2 (list (cons "a" 1) (cons "b" 5)) dup)))
         (list a b c d)))
  (chk "duplicates: two alists with duplicates"
       (list yes no)
       (let* ((a (jeq2 dup (list (cons "a" 9) (cons "a" 2) (cons "b" 5) (cons "b" 5))))
              (b (jeq2 dup (list (cons "a" 2) (cons "a" 9) (cons "b" 5)))))
         (list a b)))
  (chk "duplicates: the count of duplicates is not the count of keys"
       (list yes yes)
       (let* ((a (jeq2 (list (cons "a" 1) (cons "a" 1)) (list (cons "a" 1))))
              (b (jeq2 (list (cons "a" 1)) (list (cons "a" 1) (cons "a" 1)))))
         (list a b)))
  (chk "duplicates: more entries but fewer keys"
       (list no no)
       (let* ((a (jeq2 (list (cons "a" 1) (cons "a" 1) (cons "a" 1)) (list (cons "a" 1) (cons "b" 1))))
              (b (jeq2 (list (cons "a" 1) (cons "b" 1)) (list (cons "a" 1) (cons "a" 1) (cons "a" 1)))))
         (list a b))))
(chk "a table with duplicate-text keys is refused, not compared"
     (raised 'unwritable-key #f 'json=? m-dup "a")
     (jeq2 dup-table (list (cons "a" 2))))

;; arrays
(chk "arrays: equal" (list yes yes)
     (let* ((a (jeq2 (vector 1 "a" #t) (vector 1 "a" #t))) (b (jeq2 (vector) (vector)))) (list a b)))
(chk "arrays: a shorter one" (list no no)
     (let* ((a (jeq2 (vector 1 2) (vector 1 2 3))) (b (jeq2 (vector 1 2 3) (vector 1 2)))) (list a b)))
(chk "arrays: empty against longer" (list no no)
     (let* ((a (jeq2 (vector) (vector 1))) (b (jeq2 (vector 1) (vector)))) (list a b)))
(chk "arrays: order" (list no no)
     (let* ((a (jeq2 (vector 1 2) (vector 2 1))) (b (jeq2 (vector "a" "b") (vector "b" "a")))) (list a b)))
(chk "arrays: nested, the last element differs" no
     (jeq2 (vector (vector 1 (vector 2)) 3) (vector (vector 1 (vector 2)) 4)))
(chk "arrays: of objects in different forms" yes
     (jeq2 (vector (list (cons "a" 1) (cons "b" 2)) (list (cons "c" 3)))
           (vector (table (cons "b" 2) (cons "a" 1)) (table (cons "c" 3)))))
(chk "arrays: of objects, one value differs" no
     (jeq2 (vector (list (cons "a" 1)) (list (cons "c" 3)))
           (vector (table (cons "a" 1)) (table (cons "c" 4)))))
(chk "arrays: a number against a string" no (jeq2 (vector 1) (vector "1")))

;; numbers, equal
(define equal-number-groups
  (list
   (list 1 1.0 (l:make-json-number "1e0") (l:make-json-number "10e-1") (l:make-json-number "1")
         (l:make-json-number "1.0") (l:make-json-number "0.1e1") (l:make-json-number "1E0"))
   (list 100 100.0 (l:make-json-number "100") (l:make-json-number "1e2") (l:make-json-number "10E1")
         (l:make-json-number "1.00e2") (l:make-json-number "0.01e4") (l:make-json-number "100.0"))
   (list 0 -0.0 0.0 (l:make-json-number "-0") (l:make-json-number "0") (l:make-json-number "0.0")
         (l:make-json-number "-0.0e5") (l:make-json-number "0e-7"))
   (list 1/2 0.5 (l:make-json-number "0.5") (l:make-json-number "0.50") (l:make-json-number "5e-1")
         (l:make-json-number "50e-2"))
   (list 1/20 (l:make-json-number "0.05") (l:make-json-number "5e-2"))
   (list 1/50 (l:make-json-number "0.02") (l:make-json-number "2e-2"))
   (list 1/10 (l:make-json-number "0.1") (l:make-json-number "1e-1"))
   (list 3/40 (l:make-json-number "0.075") (l:make-json-number "75e-3"))
   (list (expt 10 400) (l:make-json-number "1e400") (l:make-json-number "10e399")
         (l:make-json-number "1000e397"))
   (list -250 -250.0 (l:make-json-number "-2.5e2") (l:make-json-number "-250"))
   (list 123 (l:make-json-number "12.3e1") (l:make-json-number "1230e-1"))
   (list 1230 (l:make-json-number "123e1") (l:make-json-number "1.23e3"))))

(define (show-num x) (if (l:json-number? x) (string-append "json-number " (l:json-number-text x))
                         (number->string x)))
(for-each
 (lambda (group)
   (for-each
    (lambda (a)
      (for-each
       (lambda (b)
         (unless (eq? a b)
           (chk (nm "equal numbers" (show-num a) (show-num b)) yes (jeq2 a b))))
       group))
    group))
 equal-number-groups)

;; numbers, not equal
(define unequal-numbers
  (list
   (list 0.1 (l:make-json-number "0.1"))
   (list 0.1 1/10)
   (list 0.1 (l:make-json-number "1e-1"))
   (list 0.2 1/5)
   (list (l:make-json-number "1.000000000000000000001") 1)
   (list (l:make-json-number "1.000000000000000000001") 1.0)
   (list (l:make-json-number "1e400") (expt 10 401))
   (list (l:make-json-number "1e400") (expt 10 399))
   (list (l:make-json-number "1e400") (l:make-json-number "1e401"))
   (list (l:make-json-number "100") 1)
   (list (l:make-json-number "100") (l:make-json-number "10"))
   (list (l:make-json-number "1e2") (l:make-json-number "1e3"))
   (list (l:make-json-number "1e2") 10)
   (list (l:make-json-number "10") 1/10)
   (list (l:make-json-number "-1") 1)
   (list (l:make-json-number "-1") (l:make-json-number "1"))
   (list (l:make-json-number "-1e0") 1)
   (list -1 1)
   (list -1/2 1/2)
   (list (l:make-json-number "-0.5") 0.5)
   (list 1 2)
   (list 1/20 1/2)
   (list 1/50 1/5)
   (list 1/40 (l:make-json-number "0.25"))
   (list 1/8 (l:make-json-number "0.12"))
   (list 0 (l:make-json-number "0.0000000000000000000000001"))
   (list 0 1)
   (list (l:make-json-number "12") (l:make-json-number "21"))
   (list (l:make-json-number "1e0") (l:make-json-number "11e-1"))
   (list 1 1.5)))
(for-each
 (lambda (row)
   (let ((a (car row)) (b (cadr row)))
     (chk (nm "unequal numbers" (show-num a) (show-num b)) no (jeq2 a b))
     (chk (nm "unequal numbers flipped" (show-num b) (show-num a)) no (jeq2 b a))))
 unequal-numbers)
(chk "numbers inside arrays and objects, equal" yes
     (jeq2 (vector (list (cons "n" 1)) (l:make-json-number "1e2"))
           (vector (table (cons "n" 1.0)) 100)))
(chk "numbers: text mode against exact mode, same document" yes
     (jeq2 (string->json "{\"a\":[1.50,1e2,-0.25,7]}" (l:make-json-options 'number-mode 'text))
           (string->json "{\"a\":[1.5,100,-0.25,7]}" (l:make-json-options 'number-mode 'exact
                                                                           'object-mode 'hashtable))))
(chk "numbers: flonum mode against exact mode, 0.1" no
     (jeq2 (string->json "[0.1]") (string->json "[0.1]" (l:make-json-options 'number-mode 'exact))))
(chk "numbers: flonum mode against exact mode, 0.5" yes
     (jeq2 (string->json "[0.5]") (string->json "[0.5]" (l:make-json-options 'number-mode 'exact))))

;; raising
(define m-val-raise (lambda (irr) (raised 'unwritable-value #f 'json=? m-val irr)))
(chk "json=?: a symbol in a" (m-val-raise 'sym) (jeq2 'sym 5))
(chk "json=?: a symbol in b" (m-val-raise 'sym) (jeq2 5 'sym))
(chk "json=?: a symbol in a, equal to b" (m-val-raise 'sym) (jeq2 'sym 'sym))
(chk "json=?: a ratio in a" (raised 'unwritable-number #f 'json=? m-num 1/3) (jeq2 1/3 1/3))
(chk "json=?: a ratio in b" (raised 'unwritable-number #f 'json=? m-num 1/3) (jeq2 "x" 1/3))
(chk "json=?: infinity in b" (raised 'unwritable-number #f 'json=? m-num +inf.0) (jeq2 +inf.0 1))
(chk "json=?: a bad element in a, b differs at its first element"
     (m-val-raise 'bad) (jeq2 (vector 1 'bad) (vector 2 3)))
(chk "json=?: a bad element in b, b differs at its first element"
     (m-val-raise 'bad) (jeq2 (vector 2 3) (vector 1 'bad)))
(chk "json=?: a bad element in b, a and b differ in length"
     (m-val-raise 'bad) (jeq2 (vector 1) (vector 1 2 'bad)))
(chk "json=?: a bad member in b, objects with other keys"
     (m-val-raise 'bad) (jeq2 (list (cons "a" 1)) (list (cons "b" 'bad))))
(chk "json=?: a bad member in a, objects with other keys"
     (m-val-raise 'bad) (jeq2 (list (cons "b" 'bad)) (list (cons "a" 1))))
(chk "json=?: an improper alist in b"
     (raised 'unwritable-value #f 'json=? m-list improper)
     (jeq2 (list (cons "z" 1)) improper))
(chk "json=?: a non-string key in a"
     (raised 'unwritable-key #f 'json=? m-key 1) (jeq2 (list (cons 1 2)) '()))
(chk "json=?: a non-string key in b"
     (raised 'unwritable-key #f 'json=? m-key 1) (jeq2 '() (list (cons 1 2))))
(chk "json=?: a table with a non-string key"
     (raised 'unwritable-key #f 'json=? m-key 1) (jeq2 '() key-table))
(chk "json=?: the null of other options, a" (m-val-raise 'nil) (jeq2 (vector 'nil) (vector 'nil)))
(chk "json=?: the null of other options, b" (m-val-raise 'nil) (jeq2 (vector 'null) (vector 'nil)))
(chk "json=?: the options' null is accepted, and equal" yes
     (jeq (vector 'nil 1) (vector 'nil 1) 'null 'nil))
(chk "json=?: the options' null is accepted, and unequal" no
     (jeq (vector 'nil 1) (vector 1 'nil) 'null 'nil))
(chk "json=?: the default null is refused under another null"
     (m-val-raise 'null) (jeq (vector 'null) (vector 'nil) 'null 'nil))
(chk "json=?: a record null" yes (jeq the-null the-null 'null the-null))
(chk "json=?: a record null against a number" no (jeq the-null 5 'null the-null))
(let ((other (make-thing 2)))
  (chk "json=?: a record null, another record is no null"
       (m-val-raise other)
       (outcome (lambda () (json=? other the-null (l:make-json-options 'null the-null))))))
(chk "json=?: past depth-limit, a"
     (raised 'nesting-too-deep #f 'json=? m-deep (vector 1))
     (jeq (vector (vector 1)) 5 'depth-limit 1))
(chk "json=?: past depth-limit, b"
     (raised 'nesting-too-deep #f 'json=? m-deep (vector 1))
     (jeq 5 (vector (vector 1)) 'depth-limit 1))
(chk "json=?: at depth-limit" yes (jeq (vector (vector 1)) (vector (vector 1)) 'depth-limit 2))
(chk "json=?: past the default depth-limit 512"
     (raised 'nesting-too-deep #f 'json=? m-deep (vector))
     (jeq2 (nest-vec 512 (vector)) 5))
(chk "json=?: at the default depth-limit 512" yes
     (jeq2 (nest-vec 511 (vector)) (nest-vec 511 (vector))))
(chk "json=?: a vector that contains itself, a"
     (raised 'nesting-too-deep #f 'json=? m-deep 'hidden)
     (outcome (lambda () (json=? self-vec 5)) self-vec))
(chk "json=?: a vector that contains itself, b"
     (raised 'nesting-too-deep #f 'json=? m-deep 'hidden)
     (outcome (lambda () (json=? 5 self-vec)) self-vec))
(chk "json=?: a vector that contains itself, against itself"
     (raised 'nesting-too-deep #f 'json=? m-deep 'hidden)
     (outcome (lambda () (json=? self-vec self-vec)) self-vec))
(let ((m (list (cons "a" #f))))
  (set-cdr! (car m) m)
  (chk "json=?: an object that contains itself"
       (raised 'nesting-too-deep #f 'json=? m-deep 'hidden)
       (outcome (lambda () (json=? m '())) m)))
(let ((h (make-table)))
  (hashtable-set! h "a" h)
  (chk "json=?: a table that contains itself"
       (raised 'nesting-too-deep #f 'json=? m-deep 'hidden)
       (outcome (lambda () (json=? '() h)) h)))
(chk "json=?: a circular list"
     (raised 'unwritable-value #f 'json=? m-list 'hidden)
     (outcome (lambda () (json=? circular-list '())) circular-list))
(chk "json=?: a json-number is no number to refuse" yes
     (jeq2 (l:make-json-number "1e999999") (l:make-json-number "1e999999")))

;; booleans, null, and kinds against each other
(chk "json=?: booleans" (list yes yes no no no)
     (let* ((a (jeq2 #t #t)) (b (jeq2 #f #f)) (c (jeq2 #t #f)) (d (jeq2 #f #t)) (e (jeq2 #t 1)))
       (list a b c d e)))
(chk "json=?: null" (list yes no no no)
     (let* ((a (jeq2 'null 'null)) (b (jeq2 'null #f)) (c (jeq2 #f 'null)) (d (jeq2 'null '())))
       (list a b c d)))
(chk "json=?: the empty list against the empty vector" (list no no)
     (let* ((a (jeq2 '() (vector))) (b (jeq2 (vector) '()))) (list a b)))
(chk "json=?: the empty list against an empty table, both ways" (list yes yes)
     (let* ((a (jeq2 '() (make-table))) (b (jeq2 (make-table) '()))) (list a b)))
(chk "json=?: strings" (list yes no no no)
     (let* ((a (jeq2 (string-copy "ab") (string-copy "ab"))) (b (jeq2 "a" "A"))
            (c (jeq2 "\xE9;" "e\x301;")) (d (jeq2 "" "a")))
       (list a b c d)))
(chk "json=?: kinds against each other" (list no no no no no no no no no)
     (let* ((a (jeq2 "1" 1)) (b (jeq2 "true" #t)) (c (jeq2 "null" 'null))
            (d (jeq2 (vector 1) 1)) (e (jeq2 (list (cons "a" 1)) (vector 1)))
            (f (jeq2 (table) '(("a" . 1)))) (g (jeq2 1 #t)) (h (jeq2 0 #f))
            (i (jeq2 "" (vector))))
       (list a b c d e f g h i)))
(chk "json=?: a json-number against a string and a boolean" (list no no no no)
     (let* ((a (jeq2 (l:make-json-number "1") "1")) (b (jeq2 "1" (l:make-json-number "1")))
            (c (jeq2 (l:make-json-number "1") #t)) (d (jeq2 #t (l:make-json-number "1"))))
       (list a b c d)))
(chk "json=?: a number against null, an array, an object" (list no no no no no no)
     (let* ((a (jeq2 0 'null)) (b (jeq2 'null 0)) (c (jeq2 0 (vector))) (d (jeq2 (vector) 0))
            (e (jeq2 0 '())) (f (jeq2 '() 0)))
       (list a b c d e f)))

;; --- 7. json-null? -----------------------------------------------------------------

(define (jnull v . opts)
  (outcome (lambda () (json-null? v (apply l:make-json-options opts)))))
(chk "json-null?: default, null" yes (outcome (lambda () (json-null? 'null))))
(chk "json-null?: default, nil" no (outcome (lambda () (json-null? 'nil))))
(chk "json-null?: default, the others" (list no no no no no no)
     (let* ((a (outcome (lambda () (json-null? #f)))) (b (outcome (lambda () (json-null? '()))))
            (c (outcome (lambda () (json-null? 0)))) (d (outcome (lambda () (json-null? "null"))))
            (e (outcome (lambda () (json-null? (vector))))) (f (outcome (lambda () (json-null? the-null)))))
       (list a b c d e f)))
(chk "json-null?: given nil, nil" yes (jnull 'nil 'null 'nil))
(chk "json-null?: given nil, null" no (jnull 'null 'null 'nil))
(chk "json-null?: given nil, the others" (list no no)
     (let* ((a (jnull #f 'null 'nil)) (b (jnull '() 'null 'nil))) (list a b)))
(chk "json-null?: given a record, that record" yes (jnull the-null 'null the-null))
(chk "json-null?: given a record, another record" no (jnull (make-thing 2) 'null the-null))
(chk "json-null?: given a record, the symbol null" no (jnull 'null 'null the-null))
(let ((thing-null (make-thing 7)))
  (chk "json-null?: a record with equal fields is not the null"
       (list yes no)
       (let* ((a (jnull thing-null 'null thing-null)) (b (jnull (make-thing 7) 'null thing-null)))
         (list a b))))
(chk "json-null?: other options are no matter" yes (jnull 'nil 'null 'nil 'indent 3 'depth-limit 2))
(chk "json-null?: of something unwritable" no (jnull 1/3))

;; --- 8. check-json -----------------------------------------------------------------

(define (chkj v . opts)
  (outcome (lambda () (check-json v (apply l:make-json-options opts)) 'ok)))
(define (chkj1 v) (outcome (lambda () (check-json v) 'ok)))
(define (putj v . opts)
  (outcome (lambda ()
             (let-values (((p extract) (open-bytevector-output-port)))
               (put-json p v (apply l:make-json-options opts)))
             'ok)))

(chk "check-json: a good value" (returned 'ok)
     (chkj1 '(("a" . #(1 2.5 "s" #t #f null)) ("b" . ()))))
(chk "check-json: a value that is good, given options" (returned 'ok)
     (chkj (vector 'nil (vector 1)) 'null 'nil 'depth-limit 2))
(chk "check-json: unwritable-number"
     (raised 'unwritable-number #f 'check-json m-num 1/3) (chkj1 (vector 1/3)))
(chk "check-json: unwritable-key"
     (raised 'unwritable-key #f 'check-json m-key 1) (chkj1 (list (cons 1 2))))
(chk "check-json: unwritable-value"
     (raised 'unwritable-value #f 'check-json m-val 'sym) (chkj1 (vector 'sym)))
(chk "check-json: nesting-too-deep"
     (raised 'nesting-too-deep #f 'check-json m-deep (vector 1))
     (chkj (vector (vector 1)) 'depth-limit 1))
(chk "check-json: the default null is null, not nil"
     (list (returned 'ok) (raised 'unwritable-value #f 'check-json m-val 'nil))
     (let* ((a (chkj1 (vector 'null))) (b (chkj1 (vector 'nil)))) (list a b)))
(chk "check-json: given nil, null is refused"
     (raised 'unwritable-value #f 'check-json m-val 'null) (chkj (vector 'null) 'null 'nil))
(chk "check-json: the default depth-limit is 512"
     (list (returned 'ok) (raised 'nesting-too-deep #f 'check-json m-deep (vector)))
     (let* ((a (chkj1 (nest-vec 511 (vector)))) (b (chkj1 (nest-vec 512 (vector))))) (list a b)))
(chk "check-json: indent is no matter" (returned 'ok) (chkj (vector 1) 'indent 4))
(chk "check-json: a table holding two keys of one text"
     (raised 'unwritable-key #f 'check-json m-dup "a") (chkj1 dup-table))
(chk "check-json: a bad options record"
     (violates 'check-json 5)
     (outcome (lambda () (check-json (vector 1) 5))))
(chk "check-json: bad options that are some other record"
     (violates 'check-json the-null)
     (outcome (lambda () (check-json (vector 1) the-null))))
(chk "check-json: bad options, before the value is looked at"
     (violates 'check-json "o")
     (outcome (lambda () (check-json 'sym "o"))))

;; put-json still names itself.
(for-each
 (lambda (row)
   (let ((v (car row)) (opts (cadr row)) (reason (caddr row)) (message (cadddr row))
         (irritant (list-ref row 4)))
     (chk (nm "put-json still says put-json" (symbol->string reason))
          (raised reason #f 'put-json message irritant)
          (apply putj v opts))
     (chk (nm "check-json says check-json" (symbol->string reason))
          (raised reason #f 'check-json message irritant)
          (apply chkj v opts))))
 (list (list 1/3 '() 'unwritable-number m-num 1/3)
       (list (list (cons 1 2)) '() 'unwritable-key m-key 1)
       (list 'sym '() 'unwritable-value m-val 'sym)
       (list (vector (vector)) '(depth-limit 1) 'nesting-too-deep m-deep (vector))))
(chk "put-json: bad options still a violation of put-json"
     (violates 'put-json 5)
     (outcome (lambda ()
                (let-values (((p extract) (open-bytevector-output-port)))
                  (put-json p (vector 1) 5)))))

;; --- 9. The arguments --------------------------------------------------------------

(define a-thing (make-thing 1))
(define text-in (open-string-input-port "[1]"))
(define bin-in (open-bytevector-input-port (string->utf8 "[1]")))
(define bin-out (call-with-values open-bytevector-output-port (lambda (p get) p)))
(define text-out (call-with-values open-string-output-port (lambda (p get) p)))

;; Each row: label, who, the bad argument, a thunk that passes it.
(define argument-cases
  (list
   (list "string->json: a bytevector" 'string->json (make-bytevector 2 1)
         (lambda (x) (string->json x)))
   (list "string->json: a symbol" 'string->json 'abc (lambda (x) (string->json x)))
   (list "string->json: a number, with options" 'string->json 5
         (lambda (x) (string->json x (l:make-json-options))))
   (list "string->json: a list" 'string->json '("[1]") (lambda (x) (string->json x)))
   (list "bytevector->json: a string" 'bytevector->json "[1]" (lambda (x) (bytevector->json x)))
   (list "bytevector->json: a vector" 'bytevector->json (vector 91 93)
         (lambda (x) (bytevector->json x (l:make-json-options))))
   (list "bytevector->json: #f" 'bytevector->json #f (lambda (x) (bytevector->json x)))
   (list "read-json: a string" 'read-json "[1]" (lambda (x) (read-json x)))
   (list "read-json: a bytevector" 'read-json (make-bytevector 2 1) (lambda (x) (read-json x)))
   (list "read-json: a textual input port" 'read-json text-in (lambda (x) (read-json x)))
   (list "read-json: a textual input port, with options" 'read-json text-in
         (lambda (x) (read-json x (l:make-json-options))))
   (list "read-json: a binary output port" 'read-json bin-out (lambda (x) (read-json x)))
   (list "read-json: a textual output port" 'read-json text-out (lambda (x) (read-json x)))
   (list "write-json: a textual output port" 'write-json text-out
         (lambda (x) (write-json x (vector 1))))
   (list "write-json: a binary input port" 'write-json bin-in
         (lambda (x) (write-json x (vector 1))))
   (list "write-json: a textual input port" 'write-json text-in
         (lambda (x) (write-json x (vector 1) (l:make-json-options))))
   (list "write-json: a bytevector" 'write-json (make-bytevector 2 1)
         (lambda (x) (write-json x (vector 1))))
   (list "write-json: a string" 'write-json "port" (lambda (x) (write-json x 1)))
   ;; non-options records
   (list "string->json: options of another record" 'string->json a-thing
         (lambda (x) (string->json "[1]" x)))
   (list "string->json: options a list" 'string->json '(depth-limit 3)
         (lambda (x) (string->json "[1]" x)))
   (list "bytevector->json: options a number" 'bytevector->json 3
         (lambda (x) (bytevector->json (string->utf8 "[1]") x)))
   (list "bytevector->json: options of another record" 'bytevector->json a-thing
         (lambda (x) (bytevector->json (string->utf8 "[1]") x)))
   (list "read-json: options of another record" 'read-json a-thing
         (lambda (x) (read-json (open-bytevector-input-port (string->utf8 "[1]")) x)))
   (list "read-json: options a symbol" 'read-json 'o
         (lambda (x) (read-json (open-bytevector-input-port (string->utf8 "[1]")) x)))
   (list "json->string: options of another record" 'json->string a-thing
         (lambda (x) (json->string (vector 1) x)))
   (list "json->string: options #f" 'json->string #f (lambda (x) (json->string (vector 1) x)))
   (list "json->bytevector: options of another record" 'json->bytevector a-thing
         (lambda (x) (json->bytevector (vector 1) x)))
   (list "json->bytevector: options a string" 'json->bytevector "opts"
         (lambda (x) (json->bytevector (vector 1) x)))
   (list "write-json: options of another record" 'write-json a-thing
         (lambda (x) (write-json bin-out (vector 1) x)))
   (list "write-json: options a number" 'write-json 7
         (lambda (x) (write-json bin-out (vector 1) x)))
   (list "json=?: options of another record" 'json=? a-thing
         (lambda (x) (json=? (vector 1) (vector 1) x)))
   (list "json=?: options a list" 'json=? '()
         (lambda (x) (json=? 1 1 x)))
   (list "json-null?: options of another record" 'json-null? a-thing
         (lambda (x) (json-null? 'null x)))
   (list "json-null?: options a symbol" 'json-null? 'null
         (lambda (x) (json-null? 'null x)))))

(for-each
 (lambda (row)
   (let ((label (car row)) (who (cadr row)) (bad (caddr row)) (call (cadddr row)))
     (chk label (violates who bad) (outcome (lambda () (call bad))))))
 argument-cases)

;; A refused write wrote nothing to a good port; an argument refusal comes
;; before reading.
(chk "write-json: bad options write nothing"
     (list (violates 'write-json a-thing) "")
     (let-values (((p extract) (open-bytevector-output-port)))
       (let ((r (outcome (lambda () (write-json p (vector 1) a-thing)))))
         (list r (bv->str (extract))))))
(chk "read-json: a bad argument takes no byte from a good port"
     (list (violates 'read-json a-thing) 0)
     (let* ((p (open-bytevector-input-port (string->utf8 "[1]")))
            (r (outcome (lambda () (read-json p a-thing)))))
       (list r (port-position p))))

;; --- 10. Re-exports ------------------------------------------------------------------

(chk "re-exports are the low layer's bindings"
     '(#t #t #t #t #t #t #t #t #t)
     (list (eq? json-error? l:json-error?)
           (eq? json-error-reason l:json-error-reason)
           (eq? json-error-offset l:json-error-offset)
           (eq? make-json-options l:make-json-options)
           (eq? json-options? l:json-options?)
           (eq? make-json-number l:make-json-number)
           (eq? json-number? l:json-number?)
           (eq? json-number-text l:json-number-text)
           (eq? (record-type-descriptor &json-error) (record-type-descriptor l:&json-error))))
(chk "&json-error in a condition-type position"
     (list #t #f)
     (let ((pred (condition-predicate (record-type-descriptor &json-error))))
       (list (pred (l:make-json-error 'x 1))
             (pred (make-violation)))))
(chk "&json-error as the parent of a new condition type"
     (list #t 'r 4)
     (let ()
       (define-condition-type &mine &json-error make-mine mine? (extra mine-extra))
       (let ((c (make-mine 'r 4 'e)))
         (list (json-error? c) (json-error-reason c) (json-error-offset c)))))
(chk "a json-number made through easy is read back by the low layer's accessor"
     "1e5"
     (l:json-number-text (make-json-number "1e5")))
(chk "options made through easy are the low layer's"
     (list 3 'text)
     (let ((o (make-json-options 'depth-limit 3 'number-mode 'text)))
       (list (l:json-options-depth-limit o) (l:json-options-number-mode o))))

;; --- 11. What the review found ----------------------------------------------------

;; json=? on json-numbers whose exponents have more digits than a fixnum
;; holds. An exponent of 20 digits or more is added to as text, below its
;; 19 low digits: a carry and a borrow of exactly one, a borrow through a
;; trailing 0, a short low part, a negative exponent shifted, and long
;; exponents met by short ones. Each answer was worked out with Python's
;; integers.
(define (jn text) (make-json-number text))
(define (same?-out a b) (outcome (lambda () (json=? a b))))
(for-each
 (lambda (c)
   (chk (nm "json=?: long exponents" (car c) (cadr c)) (returned (caddr c))
        (same?-out (jn (car c)) (jn (cadr c))))
   (chk (nm "json=?: long exponents, swapped" (car c) (cadr c)) (returned (caddr c))
        (same?-out (jn (cadr c)) (jn (car c)))))
 '(("10e999999999999999999999" "1e1000000000000000000000" #t)
   ("0.1e10000000000000000000" "1e9999999999999999999" #t)
   ("10e-10000000000000000001" "1e-10000000000000000000" #t)
   ("10e9999999999999999999" "1e10000000000000000000" #t)
   ("0.1e100000000000000000000" "1e99999999999999999999" #t)
   ("1e100000000000000000005" "1e105" #f)
   ("0.1e000000000000000000000" "1e-1" #t)
   ("1e1000000000000000000" "10e999999999999999999" #t)
   ("1e1000000000000000000" "1e999999999999999999" #f)
   ("0.1e1000000000000000001" "1e1000000000000000000" #t)
   ("0.1e1000000000000000000" "1e999999999999999999" #t)
   ("0.1e1000000000000000000" "1e1000000000000000000" #f)
   ("1000e999999999999999999999" "1e1000000000000000000002" #t)
   ("1000e999999999999999999999" "1e1000000000000000000003" #f)
   ("1000e999999999999999999999" "1e1000000000000000000001" #f)
   ("1e-1000000000000000000" "10e-1000000000000000001" #t)
   ("1e-1000000000000000000" "0.1e-999999999999999999" #t)
   ("1e-1000000000000000000" "1e1000000000000000000" #f)
   ("-1e1000000000000000000" "1e1000000000000000000" #f)
   ("-1e1000000000000000000" "-10e999999999999999999" #t)
   ("1e0001000000000000000000" "1e+1000000000000000000" #t)
   ("1.5e123456789012345678901234567890" "15e123456789012345678901234567889" #t)
   ("1.5e123456789012345678901234567890" "15e123456789012345678901234567890" #f)
   ("0e123456789012345678901234567890" "0" #t)))

(chk "json=?: a long exponent never equals a Scheme number"
     (list (returned #f) (returned #f) (returned #f))
     (list (same?-out (jn "1e1000000000000000000") (expt 10 18))
           (same?-out (jn "1e-1000000000000000000") 0)
           (same?-out 1.5 (jn "15e-100000000000000000001"))))

;; Allocation, with collection off: quadratic in the exponent's digits
;; costs 16 times as much for 4 times the digits, linear about 4 times.
(define (bytes-of thunk)
  (parameterize ((collect-request-handler void))
    (let ((b0 (bytes-allocated)))
      (thunk)
      (- (bytes-allocated) b0))))
(define (exponent-cost n)
  (let ((a (jn (string-append "1e" (make-string n #\7))))
        (b (jn (string-append "10e" (make-string n #\7)))))
    (json=? a b)
    (bytes-of (lambda () (json=? a b)))))
(chk "json=?: comparing exponents of 16,000 digits costs under 6 times what 4,000 do"
     #t
     (let ((small (exponent-cost 4000)) (large (exponent-cost 16000)))
       (< large (* 6 small))))

;; A port's own &json-error, raised from inside its write!, passes through
;; write-json as put-json passes it: write-json only relabels its own
;; refusals. The value is larger than any port buffer, so write! runs
;; during the write.
(define big-value (make-string 100000 #\a))
(define (port-raising thunk)
  (make-custom-binary-output-port "raising" (lambda (bv start count) (thunk) count) #f #f #f))
(chk "write-json: a port's read error passes through as it was raised"
     (raised 'unexpected-byte 0 'string->json "unexpected-byte at character 0")
     (outcome (lambda () (write-json (port-raising (lambda () (string->json "x"))) big-value))))
(chk "write-json: a port's not-found passes through as it was raised"
     (raised 'not-found #f 'json-ref "no value at the end of this path" '("b"))
     (outcome (lambda ()
                (write-json (port-raising (lambda () (json-ref '(("a" . 1)) "b"))) big-value))))
(chk "write-json: a port's other condition passes through"
     '(other-condition)
     (outcome (lambda ()
                (write-json (port-raising (lambda () (raise (make-i/o-write-error)))) big-value))))
(chk "put-json: a port's read error passes through as it was raised"
     (raised 'unexpected-byte 0 'string->json "unexpected-byte at character 0")
     (outcome (lambda () (put-json (port-raising (lambda () (string->json "x"))) big-value))))

;; Every raise is non-continuable: a handler that returns gets a
;; &non-continuable, never a value back.
(define (handler-returns thunk)
  (guard (e ((non-continuable-violation? e) 'non-continuable)
            (#t 'other))
    (with-exception-handler (lambda (e) 'handled) thunk)))
(chk "every &json-error is raised non-continuable"
     (make-list 12 'non-continuable)
     (map handler-returns
          (list (lambda () (string->json "x"))
                (lambda () (bytevector->json (string->utf8 "x")))
                (lambda () (read-json (open-bytevector-input-port (string->utf8 "x"))))
                (lambda () (json->string 1/3))
                (lambda () (json->bytevector 1/3))
                (lambda () (let-values (((p get) (open-bytevector-output-port))) (write-json p 1/3)))
                (lambda () (json-ref '(("a" . 1)) "b"))
                (lambda () (json-ref (cons (cons "a" 1) 5) "a"))
                (lambda () (json-ref (list (cons "a" 1) 5) "a"))
                (lambda () (let ((t (make-eqv-hashtable)))
                             (hashtable-set! t (string #\a) 1)
                             (hashtable-set! t (string #\a) 2)
                             (json-ref t "a")))
                (lambda () (json=? 1/3 1))
                (lambda () (json=? 1 'nil)))))

;; A read error carries an irritants condition, empty, as R6RS's error
;; gives: a handler can always ask for the irritants.
(define (irritants-condition-of thunk)
  (guard (e ((json-error? e)
             (and (irritants-condition? e) (list 'irritants (condition-irritants e)))))
    (thunk)
    'no-raise))
(chk "a read error's irritants are an empty list, through each reader"
     '((irritants ()) (irritants ()) (irritants ()))
     (map irritants-condition-of
          (list (lambda () (string->json "x"))
                (lambda () (bytevector->json (string->utf8 "x")))
                (lambda () (read-json (open-bytevector-input-port (string->utf8 "x")))))))

;; check-json names itself at every refusal the writer makes.
(chk "check-json: its who at a hashtable key that is not a string"
     (raised 'unwritable-key #f 'check-json "an object's key is not a string" 1)
     (outcome (lambda () (let ((t (make-eqv-hashtable))) (hashtable-set! t 1 2) (check-json t)))))
(chk "check-json: its who at an improper list"
     (raised 'unwritable-value #f 'check-json "a list that is not an alist: it is improper or circular"
             (cons (cons "a" 1) 5))
     (outcome (lambda () (check-json (cons (cons "a" 1) 5)))))
(chk "check-json: its who at a member that is not a pair"
     (raised 'unwritable-value #f 'check-json "a list that is not an alist: a member is not a pair" 5)
     (outcome (lambda () (check-json (list (cons "a" 1) 5)))))
(chk "check-json: its who at an alist key that is not a string"
     (raised 'unwritable-key #f 'check-json "an object's key is not a string" 'a)
     (outcome (lambda () (check-json (list (cons 'a 1))))))

;; Members whose value is #f: present, not missing.
(let ((t (make-table)))
  (hashtable-set! t "a" #f)
  (chk "json=?: members whose value is #f"
       (list (returned #t) (returned #f) (returned #t) (returned #f) (returned #f))
       (list (same?-out '(("a" . #f)) '(("a" . #f)))
             (same?-out '(("a" . #f)) '(("b" . #f)))
             (same?-out t '(("a" . #f)))
             (same?-out t '(("b" . #f)))
             (same?-out '(("a" . #f) ("b" . 1)) '(("c" . #f) ("b" . 1))))))

(test-end "easy")

(display "elapsed ms: ")
(display (- (real-time) started))
(newline)
(display "pass ")
(display (test-runner-pass-count runner))
(display " fail ")
(display (test-runner-fail-count runner))
(newline)

(exit (suite-exit-status runner))
