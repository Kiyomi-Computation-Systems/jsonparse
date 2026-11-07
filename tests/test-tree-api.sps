;;; tests/test-tree-api.sps: (jsonparse tree)'s contract and the object-mode
;;; and null options (ADR-0017), held to the header comments.
;;;
;;; Every expected value is written by hand. The one comparison with another
;;; component is section 7: a builder's results against a parser with an empty
;;; handler, fed the same schedule.
;;;
;;; 1. The options. 2. make-json-builder and json-builder?. 3. Defaults
;;; through the constructor. 7. Results (placed here so that a builder that
;;; answers a non-result is caught by assertions, before the lifecycle's
;;; setup code trips over it). 4. The lifecycle: value, feed and finish after
;;; each status, reset. 5. Independent builders. 6. Refusals of the
;;; procedures. 8. Sub-ranges.
(import (rnrs)
        (only (chezscheme) real-time)
        (srfi :64)
        (jsonparse-testing)
        (jsonparse options)
        (jsonparse parser)
        (jsonparse string)
        (jsonparse tree))

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
        (newline)))))

(define started (real-time))

;; --- helpers -----------------------------------------------------------------

(define (bytes s) (string->utf8 s))

(define (sub bv from to)
  (let ((out (make-bytevector (- to from))))
    (bytevector-copy! bv from out 0 (- to from))
    out))

;; refusal : (-> Any) -> (U 'no-raise (List Boolean Any Any Any))
;; What an assertion violation carried: is it one, its who, message, irritants.
(define (refusal thunk)
  (guard (e (#t (list (assertion-violation? e)
                      (and (who-condition? e) (condition-who e))
                      (and (message-condition? e) (condition-message e))
                      (and (irritants-condition? e) (condition-irritants e)))))
    (thunk)
    'no-raise))

(define (refused who message . irritants) (list #t who message irritants))

(define (result->list r)
  (list (json-result-status r) (json-result-code r) (json-result-offset r)))

;; chunks-of : Bytevector Positive-Integer -> (Listof Bytevector)
(define (chunks-of bv k)
  (let ((len (bytevector-length bv)))
    (let loop ((start 0) (acc '()))
      (if (>= start len)
          (reverse acc)
          (let ((end (min len (+ start k))))
            (loop end (cons (sub bv start end) acc)))))))

;; norm : Any -> Any
;; A value with each hashtable written as (table mutable? ((key . value) ...)),
;; the pairs sorted by key, so a test can state a table in full.
(define (norm v)
  (cond ((hashtable? v)
         (list 'table (hashtable-mutable? v)
               (list-sort (lambda (a b) (string<? (car a) (car b)))
                          (map (lambda (k) (cons k (norm (hashtable-ref v k 'missing))))
                               (vector->list (hashtable-keys v))))))
        ((vector? v) (vector-map norm v))
        ((pair? v) (cons (norm (car v)) (norm (cdr v))))
        (else v)))

;; tbl : the expected form of a mutable hashtable, entries sorted by key.
(define (tbl . entries) (list 'table #t entries))

(define (feed-list b chunks)
  (let loop ((cs chunks) (acc '()))
    (if (null? cs)
        (reverse acc)
        (let ((r (result->list (json-builder-feed! b (car cs)))))
          (loop (cdr cs) (cons r acc))))))

(define (value-of b)
  (guard (e ((and (assertion-violation? e)
                  (who-condition? e) (eq? (condition-who e) 'json-builder-value)
                  (message-condition? e) (equal? (condition-message e) no-value-message))
             'no-value)
            (#t (list 'raised-other (describe e))))
    (norm (json-builder-value b))))

;; run : json-builder (Listof Bytevector) -> (List (Listof Result) Value)
;; Every feed's result, then the finish's; then the value, or no-value.
(define (run b chunks)
  (guard (e (#t (list 'raised (describe e))))
    (let* ((fs (feed-list b chunks))
           (fin (result->list (json-builder-finish! b))))
      (list (append fs (list fin)) (value-of b)))))

(define (value-refusal b) (refusal (lambda () (json-builder-value b))))

(define no-value-message "there is no value until finish answers finished")

(define (no-value-refusal status) (refused 'json-builder-value no-value-message status))

;; ok-results : n k -> the results of a valid document of N bytes fed in chunks
;; of K bytes: need-input at each running offset, then finished at N.
(define (ok-results n k)
  (let loop ((at k) (acc '()))
    (if (>= (- at k) n)
        (append (reverse acc) (list (list 'finished #f n)))
        (loop (+ at k) (cons (list 'need-input #f (min n at)) acc)))))

(define (opts . args) (apply make-json-options args))

(define (nest n)
  (let loop ((i 1) (v (vector)))
    (if (= i n) v (loop (+ i 1) (vector v)))))

(define (rep n b) (make-bytevector n b))

(define (cat . bvs)
  (let* ((n (apply + (map bytevector-length bvs)))
         (out (make-bytevector n)))
    (let loop ((bs bvs) (at 0))
      (unless (null? bs)
        (bytevector-copy! (car bs) 0 out at (bytevector-length (car bs)))
        (loop (cdr bs) (+ at (bytevector-length (car bs))))))
    out))

;; --- the suite's own records ---------------------------------------------------

(define-record-type thing (fields tag))
(define-record-type hidden (fields tag) (opaque #t))

(test-begin "tree-api")

;; --- 1. the options --------------------------------------------------------------

(test-equal "options: object-mode defaults to alist" 'alist
  (json-options-object-mode (make-json-options)))
(test-equal "options: null defaults to the symbol null" 'null
  (json-options-null (make-json-options)))
(test-equal "options: object-mode alist reads back" 'alist
  (json-options-object-mode (make-json-options 'object-mode 'alist)))
(test-equal "options: object-mode hashtable reads back" 'hashtable
  (json-options-object-mode (make-json-options 'object-mode 'hashtable)))
(test-equal "options: object-mode leaves null alone" 'null
  (json-options-null (make-json-options 'object-mode 'hashtable)))
(test-equal "options: null leaves object-mode alone" 'alist
  (json-options-object-mode (make-json-options 'null 'nil)))
(test-equal "options: the two given together read back, either order"
  '((hashtable nil) (hashtable nil))
  (let ((a (make-json-options 'object-mode 'hashtable 'null 'nil))
        (b (make-json-options 'null 'nil 'object-mode 'hashtable)))
    (list (list (json-options-object-mode a) (json-options-null a))
          (list (json-options-object-mode b) (json-options-null b)))))

(let ((empty-symbol (string->symbol ""))
      (thing (make-thing 1))
      (condition (make-assertion-violation)))
  (for-each
   (lambda (row)
     (test-equal (string-append "options: null " (car row) " reads back, eq?")
       #t
       (eq? (cdr row) (json-options-null (make-json-options 'null (cdr row))))))
   (list (cons "nil" 'nil) (cons "the empty symbol" empty-symbol)
         (cons "a record of the suite's own" thing)
         (cons "a condition" condition))))

(define object-mode-message "object-mode is not alist or hashtable")
(define null-message "null is not a symbol, or a record that is not a hashtable")

(for-each
 (lambda (v)
   (test-equal (string-append "options: object-mode " (describe v) " is refused")
     (refused 'make-json-options object-mode-message v)
     (refusal (lambda () (make-json-options 'object-mode v)))))
 (list 'list "alist" #f 'vector 'alists 'hashtables 'Alist 'HASHTABLE 'assoc 'eq-hashtable
       'hash-table 'table 'Hashtable "hashtable" 'alist:))

(for-each
 (lambda (v)
   (test-equal (string-append "options: null " (describe v) " is refused")
     (refused 'make-json-options null-message v)
     (refusal (lambda () (make-json-options 'null v)))))
 (list #f #t 0 -1 1.5 "null" (vector) (vector 1) '() '(1) (cons 1 2)
       (make-hashtable string-hash string=?) (make-eq-hashtable)
       (make-json-number "1") #\n (bytes "null") (eof-object) car
       (make-hidden 1)))

;; Every ordered pair of distinct options, each given a non-default value:
;; all five fields read back as given or as their defaults. The expected
;; values come from these tables, never from the options record.
(define option-names '(depth-limit number-mode digit-limit object-mode null))
(define option-defaults '(512 flonum 1000 alist null))
(define option-givens '(7 exact 9 hashtable nil))
(define option-readers
  (list json-options-depth-limit json-options-number-mode json-options-digit-limit
        json-options-object-mode json-options-null))

(define (read-all o) (map (lambda (r) (r o)) option-readers))

(do ((i 0 (+ i 1))) ((= i 5))
  (do ((j 0 (+ j 1))) ((= j 5))
    (unless (= i j)
      (test-equal (string-append "options: " (symbol->string (list-ref option-names i))
                                 " then " (symbol->string (list-ref option-names j)))
        (let loop ((k 0) (acc '()))
          (if (= k 5)
              (reverse acc)
              (loop (+ k 1)
                    (cons (if (or (= k i) (= k j)) (list-ref option-givens k) (list-ref option-defaults k))
                          acc))))
        (read-all (make-json-options (list-ref option-names i) (list-ref option-givens i)
                                     (list-ref option-names j) (list-ref option-givens j)))))))

(test-equal "options: all five given, in order"
  option-givens
  (read-all (make-json-options 'depth-limit 7 'number-mode 'exact 'digit-limit 9
                               'object-mode 'hashtable 'null 'nil)))
(test-equal "options: all five given, reversed"
  option-givens
  (read-all (make-json-options 'null 'nil 'object-mode 'hashtable 'digit-limit 9
                               'number-mode 'exact 'depth-limit 7)))

(test-equal "options: object-mode twice"
  (refused 'make-json-options "an option is given twice" 'object-mode)
  (refusal (lambda () (make-json-options 'object-mode 'alist 'object-mode 'hashtable))))
(test-equal "options: null twice"
  (refused 'make-json-options "an option is given twice" 'null)
  (refusal (lambda () (make-json-options 'null 'a 'null 'b))))
(test-equal "options: object-mode with no value"
  (refused 'make-json-options "an option has no value" 'object-mode)
  (refusal (lambda () (make-json-options 'object-mode))))
(test-equal "options: null with no value"
  (refused 'make-json-options "an option has no value" 'null)
  (refusal (lambda () (make-json-options 'null))))
(test-equal "options: null with no value after a good pair"
  (refused 'make-json-options "an option has no value" 'null)
  (refusal (lambda () (make-json-options 'object-mode 'hashtable 'null))))

;; --- 2. make-json-builder and json-builder? ------------------------------------------

(for-each
 (lambda (v)
   (test-equal (string-append "builder: " (describe v) " is not an options record")
     (refused 'make-json-builder "not an options record" v)
     (refusal (lambda () (make-json-builder v)))))
 (list 5 #f 'options (vector) (make-json-handler) '() (bytes "{}")
       (make-json-parser (make-json-handler))))

(let* ((b (make-json-builder))
       (b2 (make-json-builder (opts 'null 'nil)))
       (kinds (list (cons "a builder" b) (cons "a second builder" b2)
                    (cons "a parser" (make-json-parser (make-json-handler)))
                    (cons "an assembler" (make-json-assembler))
                    (cons "an options record" (make-json-options))
                    (cons "a handler" (make-json-handler))
                    (cons "a vector" (vector 1)) (cons "a symbol" 'builder)
                    (cons "#f" #f))))
  (test-equal "json-builder?: true of builders only"
    '(#t #t #f #f #f #f #f #f #f)
    (map (lambda (k) (json-builder? (cdr k))) kinds)))

(test-equal "json-result?: true of the results of a feed, a finish and an error"
  '(#t #t #t #t)
  (guard (e (#t 'raised))
    (let* ((b (make-json-builder))
           (f (json-builder-feed! b (bytes "[1]")))
           (g (json-builder-finish! b))
           (c (make-json-builder))
           (h (json-builder-feed! c (bytes "[}")))
           (k (json-builder-finish! c)))
      (list (json-result? f) (json-result? g) (json-result? h) (json-result? k)))))

;; --- 3. defaults through the constructor -------------------------------------------------

(define big-digits-ok (cat (bytes "[") (rep 1000 49) (bytes "]")))
(define big-digits-bad (cat (bytes "[") (rep 1001 49) (bytes "]")))
(define repunit-1000 (div (- (expt 10 1000) 1) 9))

(define (ok-run n value) (list (list (list 'need-input #f n) (list 'finished #f n)) value))

(define (error-run code offset)
  (list (list (list 'error code offset) (list 'error code offset)) 'no-value))

;; (label bytes non-default-options): each input tells a default builder apart
;; from the builder with the non-default options.
(define default-rows
  (list
   (list "null is the symbol null" (bytes "[null]") (opts 'null 'nil))
   (list "an object is an alist" (bytes "{\"a\":1,\"a\":2}") (opts 'object-mode 'hashtable))
   (list "1.5 is a flonum and 1 exact" (bytes "[1.5,1]") (opts 'number-mode 'exact))
   (list "1000 digits are accepted" big-digits-ok (opts 'digit-limit 999))
   (list "1001 digits are number-too-long" big-digits-bad (opts 'digit-limit 1001))
   (list "512 deep is accepted" (cat (rep 512 91) (rep 512 93)) (opts 'depth-limit 511))
   (list "513 deep is nesting-too-deep" (rep 513 91) (opts 'depth-limit 513))))

(define (whole b bv) (run b (list bv)))

;; Whole-feed expectations, written out per row (the 1-byte form is checked
;; after: the same error at the same offset, and the same value).
(define default-whole
  (list
   (cons "null is the symbol null" (ok-run 6 (vector 'null)))
   (cons "an object is an alist" (ok-run 13 '(("a" . 1) ("a" . 2))))
   (cons "1.5 is a flonum and 1 exact" (ok-run 7 (vector 1.5 1)))
   (cons "1000 digits are accepted" (ok-run 1002 (vector repunit-1000)))
   (cons "1001 digits are number-too-long" (error-run 'number-too-long 1002))
   (cons "512 deep is accepted" (ok-run 1024 (nest 512)))
   (cons "513 deep is nesting-too-deep" (error-run 'nesting-too-deep 513))))

(define nondefault-whole
  (list
   (cons "null is the symbol null" (ok-run 6 (vector 'nil)))
   (cons "an object is an alist" (ok-run 13 (tbl '("a" . 2))))
   (cons "1.5 is a flonum and 1 exact" (ok-run 7 (vector 3/2 1)))
   (cons "1000 digits are accepted" (error-run 'number-too-long 1001))
   (cons "1001 digits are number-too-long" (ok-run 1003 (vector (+ (* repunit-1000 10) 1))))
   (cons "512 deep is accepted" (error-run 'nesting-too-deep 512))
   (cons "513 deep is nesting-too-deep"
         (list (list '(need-input #f 513) '(error unexpected-eof 513)) 'no-value))))

(for-each
 (lambda (row)
   (let ((label (car row)) (bv (cadr row)) (non-default (caddr row)))
     (let ((want (cdr (assoc label default-whole))))
       (for-each
        (lambda (maker-label maker)
          (test-equal (string-append "defaults: " maker-label ", " label ", whole")
            want
            (whole (maker) bv)))
        (list "no argument" "explicit options")
        (list (lambda () (make-json-builder))
              (lambda () (make-json-builder (make-json-options)))))
       (let ((chunked (run (make-json-builder) (chunks-of bv 1))))
         (test-equal (string-append "defaults: " label ", in 1-byte chunks: the same value")
           (cadr want)
           (cadr chunked))
         (test-equal (string-append "defaults: " label ", in 1-byte chunks: the same final result")
           (car (reverse (car want)))
           (car (reverse (car chunked)))))
       (test-equal (string-append "defaults: " label ": the run differs from a non-default builder's")
         #t
         (not (equal? want (whole (make-json-builder non-default) bv)))))))
 default-rows)

;; The non-default builders give what the table says they give (so that a
;; row tells defaults apart for the reason it claims to).
(for-each
 (lambda (row)
   (let ((label (car row)) (bv (cadr row)))
     (test-equal (string-append "defaults: non-default builder: " label)
       (cdr (assoc label nondefault-whole))
       (whole (make-json-builder (caddr row)) bv))))
 default-rows)

(test-equal "defaults: a depth-limit of 513 takes 513 deep"
  '(need-input #f 513)
  (result->list (json-builder-feed! (make-json-builder (opts 'depth-limit 513)) (rep 513 91))))

;; --- 7. results --------------------------------------------------------------------------------------------

(define (parser-run options chunks)
  (let ((p (make-json-parser (make-json-handler) #f options)))
    (let loop ((cs chunks) (acc '()))
      (if (null? cs)
          (reverse (cons (json-parser-finish! p) acc))
          (loop (cdr cs) (cons (json-parser-feed! p (car cs)) acc))))))

(define (builder-run options chunks)
  (let ((b (make-json-builder options)))
    (let loop ((cs chunks) (acc '()))
      (if (null? cs)
          (reverse (cons (json-builder-finish! b) acc))
          (loop (cdr cs) (cons (json-builder-feed! b (car cs)) acc))))))

(define (with-empties chunks)
  (let loop ((cs chunks) (acc (list (bytes ""))))
    (if (null? cs)
        (reverse acc)
        (loop (cdr cs) (cons (bytes "") (cons (car cs) acc))))))

;; (label options bytes finish-result): the final result of a whole run.
(define result-cases
  (list
   (list "an array and an object" (opts) (bytes "[1,{\"a\":null}]") '(finished #f 14))
   (list "an empty object" (opts) (bytes "{}") '(finished #f 2))
   (list "a string" (opts) (bytes "\"s\"") '(finished #f 3))
   (list "a number" (opts) (bytes "7") '(finished #f 1))
   (list "all the literals and an escape pair" (opts)
         (bytes "[true,false,null,\"\\uD83D\\uDE00\\n\",-1.5e2]") '(finished #f 41))
   (list "hashtable mode" (opts 'object-mode 'hashtable 'null 'nil) (bytes "{\"a\":{\"a\":null}}")
         '(finished #f 16))
   (list "empty input" (opts) (bytes "") '(error unexpected-eof 0))
   (list "unexpected-byte" (opts) (bytes "[}") '(error unexpected-byte 1))
   (list "unexpected-byte after a comma" (opts) (bytes "[1,}") '(error unexpected-byte 3))
   (list "unexpected-eof" (opts) (bytes "[1,") '(error unexpected-eof 3))
   (list "unexpected-eof in a literal" (opts) (bytes "tru") '(error unexpected-eof 3))
   (list "invalid-number" (opts) (bytes "[01]") '(error invalid-number 2))
   (list "invalid-number, a bare minus" (opts) (bytes "[-]") '(error invalid-number 2))
   (list "invalid-escape" (opts) (bytes "\"a\\q\"") '(error invalid-escape 3))
   (list "invalid-surrogate" (opts) (bytes "\"\\uDE00\"") '(error invalid-surrogate 7))
   (list "invalid-utf8" (opts) (u8-list->bytevector '(34 97 255 34)) '(error invalid-utf8 2))
   (list "control-character" (opts) (u8-list->bytevector '(34 97 10 34)) '(error control-character 2))
   (list "nesting-too-deep" (opts 'depth-limit 2) (bytes "[[[") '(error nesting-too-deep 3))
   (list "trailing-garbage" (opts) (bytes "[]x") '(error trailing-garbage 2))
   (list "trailing-garbage after a scalar" (opts) (bytes "1 2") '(error trailing-garbage 2))))

(for-each
 (lambda (row)
   (let ((label (car row)) (options (cadr row)) (bv (caddr row)) (final (cadddr row)))
     (let ((schedules (list (cons "whole" (if (= 0 (bytevector-length bv)) '() (list bv)))
                            (cons "1 byte" (chunks-of bv 1))
                            (cons "2 bytes" (chunks-of bv 2))
                            (cons "3 bytes" (chunks-of bv 3))
                            (cons "3 bytes with empty feeds" (with-empties (chunks-of bv 3))))))
       (for-each
        (lambda (s)
          (let* ((pr (parser-run options (cdr s)))
                 (br (guard (e (#t '())) (builder-run options (cdr s)))))
            (test-equal (string-append "results: " label ", " (car s) ": json-result? of each")
              (map (lambda (_) #t) pr)
              (map json-result? br))
            (test-equal (string-append "results: " label ", " (car s) ": as the parser's")
              (map result->list pr)
              (map result->list br))
            (test-equal (string-append "results: " label ", " (car s) ": the final answer")
              final
              (result->list (car (reverse br))))))
        schedules))))
 result-cases)

;; --- 4. the lifecycle ------------------------------------------------------------------------

(test-equal "value: before any feed"
  (no-value-refusal 'need-input)
  (value-refusal (make-json-builder)))

(for-each
 (lambda (row)
   (let ((label (car row)) (doc (cadr row)) (want (caddr row)))
     (let ((b (make-json-builder)))
       (let* ((fed (feed-list b (chunks-of doc 1)))
              (during (value-refusal b))
              (fin (result->list (json-builder-finish! b)))
              (v (value-of b)))
         (test-equal (string-append "value: after need-input feeds, " label)
           (list (no-value-refusal 'need-input) (list 'finished #f (bytevector-length doc)) want)
           (list during fin v))))
     ;; the root is complete before the last byte, for the scalar rows
     (let ((b (make-json-builder)))
       (json-builder-feed! b doc)
       (test-equal (string-append "value: after one whole need-input feed, " label)
         (no-value-refusal 'need-input)
         (value-refusal b)))))
 (list (list "a complete scalar `1 `" (bytes "1 ") 1)
       (list "a complete array" (bytes "[1]") (vector 1))
       (list "a complete object" (bytes "{\"a\":[]}") '(("a" . #())))
       (list "a string" (bytes "\"s\"") "s")))

(let ((b (make-json-builder)) (doc (bytes "[1,[2]]")))
  (test-equal "value: refused after every 1-byte feed, then there after finish"
    (list (list (no-value-refusal 'need-input) (no-value-refusal 'need-input)
                (no-value-refusal 'need-input) (no-value-refusal 'need-input)
                (no-value-refusal 'need-input) (no-value-refusal 'need-input)
                (no-value-refusal 'need-input))
          '(finished #f 7) (vector 1 (vector 2)))
    (let loop ((i 0) (acc '()))
      (if (< i 7)
          (let ((_ (json-builder-feed! b (sub doc i (+ i 1)))))
            (loop (+ i 1) (cons (value-refusal b) acc)))
          (let* ((fin (result->list (json-builder-finish! b)))
                 (v (value-of b)))
            (list (reverse acc) fin v))))))

;; After an error.
(for-each
 (lambda (row)
   (let ((label (car row)) (opt (cadr row)) (first-chunks (caddr row)) (error-result (cadddr row)))
     (let* ((b (make-json-builder opt))
            (fed (feed-list b first-chunks))
            (v1 (value-refusal b))
            (again (result->list (json-builder-feed! b (bytes "[1]"))))
            (again2 (result->list (json-builder-feed! b (bytes ""))))
            (fin (result->list (json-builder-finish! b)))
            (fin2 (result->list (json-builder-finish! b)))
            (v2 (value-refusal b)))
       (test-equal (string-append "error: " label ": the feed, then every later feed and finish answer it")
         (list error-result error-result error-result error-result error-result)
         (list (car (reverse fed)) again again2 fin fin2))
       (test-equal (string-append "error: " label ": there is no value, then or later")
         (list (no-value-refusal 'error) (no-value-refusal 'error))
         (list v1 v2)))))
 (list (list "a bad byte" (opts) (list (bytes "[}")) '(error unexpected-byte 1))
       (list "a bad byte, 1-byte feeds" (opts) (chunks-of (bytes "[1,}") 1) '(error unexpected-byte 3))
       (list "a root already complete" (opts) (list (bytes "[1]x")) '(error trailing-garbage 3))
       (list "a stop: number-too-long" (opts 'digit-limit 3) (list (bytes "[1234]"))
             '(error number-too-long 5))
       (list "a stop, 1-byte feeds" (opts 'digit-limit 3) (chunks-of (bytes "[1234]") 1)
             '(error number-too-long 5))
       (list "a stop: number-out-of-range" (opts) (list (bytes "[1e999]"))
             '(error number-out-of-range 6))
       (list "nesting" (opts 'depth-limit 2) (list (bytes "[[[1")) '(error nesting-too-deep 3))))

(test-equal "error: from finish, then the same feed, finish and no value"
  (list '(error unexpected-eof 3) '(error unexpected-eof 3) '(error unexpected-eof 3)
        (no-value-refusal 'error))
  (let* ((b (make-json-builder))
         (_f (json-builder-feed! b (bytes "[1,")))
         (fin (result->list (json-builder-finish! b)))
         (fin2 (result->list (json-builder-finish! b)))
         (feed (result->list (json-builder-feed! b (bytes "2]")))))
    (list fin fin2 feed (value-refusal b))))

;; After finished.
(let* ((b (make-json-builder))
       (f (result->list (json-builder-feed! b (bytes "[1,[2]]"))))
       (fin (result->list (json-builder-finish! b)))
       (v1 (json-builder-value b))
       (v2 (json-builder-value b))
       (g1 (result->list (json-builder-feed! b (bytes "x"))))
       (g2 (result->list (json-builder-feed! b (bytes ""))))
       (g3 (result->list (json-builder-feed! b (bytes "[9]"))))
       (g4 (result->list (json-builder-feed! b (bytes "xyz") 1 2)))
       (h (result->list (json-builder-finish! b)))
       (v3 (json-builder-value b)))
  (test-equal "finished: the results" '((need-input #f 7) (finished #f 7)) (list f fin))
  (test-equal "finished: the value" (vector 1 (vector 2)) v1)
  (test-equal "finished: asking twice gives eq? values" #t (eq? v1 v2))
  (test-equal "finished: feeds and finish after it answer finished at the same offset"
    '((finished #f 7) (finished #f 7) (finished #f 7) (finished #f 7) (finished #f 7))
    (list g1 g2 g3 g4 h))
  (test-equal "finished: the value stays eq? and equal" (list #t (vector 1 (vector 2)))
    (list (eq? v1 v3) v3)))

(let* ((b (make-json-builder (opts 'digit-limit 3)))
       (_ (json-builder-feed! b (bytes "[1234]"))))
  (test-equal "stop: a stopped builder has no value"
    (no-value-refusal 'error)
    (value-refusal b)))

;; Reset, per scenario. Every scenario has depth-limit 5 and digit-limit 3.
(define scenario-options (opts 'depth-limit 5 'digit-limit 3))

(define scenarios
  ;; (label feed-chunks finish?)
  (list
   (list "a fresh builder" '() #f)
   (list "after finished" (list (bytes "[1]")) #t)
   (list "after finished, a string" (list (bytes "\"abc\"")) #t)
   (list "after an error" (list (bytes "[}")) #f)
   (list "after an error inside a string" (list (bytes "[\"abc\\q")) #f)
   (list "after an error inside a key" (list (bytes "{\"abc\\q")) #f)
   (list "after an error inside a number" (list (bytes "[12x")) #f)
   (list "after an error at depth, with values on the stack" (list (bytes "[1,2,[3,[\"x\",}")) #f)
   (list "after an error at the depth limit" (list (bytes "[[[[[[")) #f)
   (list "after an error at depth" (list (bytes "[[[x")) #f)
   (list "after a stop" (list (bytes "[1234]")) #f)
   (list "after a stop at depth" (list (bytes "[1,[2,[12345]]]")) #f)
   (list "after a stop in an object" (list (bytes "{\"a\":[1,{\"b\":1234}]}")) #f)
   (list "mid-document, inside a string" (list (bytes "[\"abc")) #f)
   (list "mid-document, inside a string, 1-byte feeds" (chunks-of (bytes "[\"abc") 1) #f)
   (list "mid-document, inside an escape" (list (bytes "[\"abc\\")) #f)
   (list "mid-document, inside a \\u escape" (list (bytes "[\"abc\\u00")) #f)
   (list "mid-document, after a high surrogate" (list (bytes "\"abc\\uD83D")) #f)
   (list "mid-document, inside a key" (list (bytes "{\"abc")) #f)
   (list "mid-document, after a key" (list (bytes "{\"abc\":")) #f)
   (list "mid-document, inside a number" (list (bytes "[12")) #f)
   (list "mid-document, inside a fraction and exponent" (list (bytes "[1.5e")) #f)
   (list "mid-document, inside a top-level number" (list (bytes "12")) #f)
   (list "mid-document, inside a literal" (list (bytes "[tru")) #f)
   (list "mid-document, a complete root not finished" (list (bytes "[1]")) #f)
   (list "mid-document, a complete scalar not finished" (list (bytes "1 ")) #f)
   (list "mid-document, deep inside arrays" (list (bytes "[[[[[")) #f)
   (list "mid-document, deep inside arrays and objects" (list (bytes "{\"a\":[{\"b\":[")) #f)
   (list "mid-document, deep with values on the stack"
         (list (bytes "[1,[2,[3,[\"x\",{\"k\":")) #f)
   (list "mid-document, deep with values, 1-byte feeds"
         (chunks-of (bytes "[1,[2,[3,[\"x\",{\"k\":") 1) #f)))

;; (label bytes value): the next documents.
(define next-docs
  (list (list "an array of a string" (bytes "[\"z\"]") (vector "z"))
        (list "an object" (bytes "{\"k\":\"v\"}") '(("k" . "v")))
        (list "an array of a number" (bytes "[7]") (vector 7))
        (list "5 deep, the depth limit" (bytes "[[[[[7]]]]]") (vector (vector (vector (vector (vector 7))))))
        (list "a top-level number" (bytes "7") 7)
        (list "a top-level string" (bytes "\"z\"") "z")
        (list "an array of a fraction" (bytes "[1.5]") (vector 1.5))
        (list "a mixed document" (bytes "{\"a\":[null,true,\"s\"],\"b\":{}}")
              '(("a" . #(null #t "s")) ("b" . ())))))

;; prepare : the setup's outcome, ok or what it raised, which the test states.
(define (prepare b chunks finish?)
  (guard (e (#t (list 'setup-raised (describe e))))
    (feed-list b chunks)
    (when finish? (json-builder-finish! b))
    'ok))

(for-each
 (lambda (scenario)
   (let ((label (car scenario)) (chunks (cadr scenario)) (finish? (caddr scenario)))
     (for-each
      (lambda (doc)
        (for-each
         (lambda (k)
           (let ((b (make-json-builder scenario-options))
                 (bv (cadr doc)))
             (let* ((setup (prepare b chunks finish?))
                    (_reset (json-builder-reset! b))
                    (v0 (value-refusal b))
                    (r (run b (chunks-of bv k))))
               (test-equal (string-append "reset: " label ", then " (car doc) ", in "
                                          (number->string k) "-byte chunks")
                 (list 'ok (no-value-refusal 'need-input)
                       (list (ok-results (bytevector-length bv) k) (caddr doc)))
                 (list setup v0 r)))))
         (list 1 100)))
      next-docs)))
 scenarios)

(test-equal "reset: the value is refused after a reset that follows finished"
  (no-value-refusal 'need-input)
  (let ((b (make-json-builder)))
    (json-builder-feed! b (bytes "[1]"))
    (json-builder-finish! b)
    (json-builder-reset! b)
    (value-refusal b)))

;; Deep, then a document at the limit, in a single builder reused through a
;; chain of errors, stops, and mid-document resets.
(test-equal "reset: a chain of different endings, then one nested exactly to the limit"
  (list (ok-results 11 1) (vector (vector (vector (vector (vector 7))))))
  (let ((b (make-json-builder scenario-options)))
    (feed-list b (list (bytes "[[[x")))
    (json-builder-reset! b)
    (feed-list b (list (bytes "[[[")))
    (json-builder-reset! b)
    (feed-list b (list (bytes "[1,[2,[12345]]]")))
    (json-builder-reset! b)
    (feed-list b (list (bytes "{\"a\":[{\"b\":[")))
    (json-builder-reset! b)
    (let ((r (run b (chunks-of (bytes "[[[[[7]]]]]") 1))))
      (list (car r) (cadr r)))))

(test-equal "reset: the options are kept (the depth limit, the digit limit, null, object-mode)"
  (list '(error nesting-too-deep 3) '(error number-too-long 5) (vector 'nil) (tbl '("a" . 1)))
  (let ((b (make-json-builder (opts 'depth-limit 2 'digit-limit 3 'null 'nil 'object-mode 'hashtable))))
    (json-builder-feed! b (bytes "[[x"))
    (json-builder-reset! b)
    (let* ((d (result->list (json-builder-feed! b (bytes "[[["))))
           (_ (json-builder-reset! b))
           (n (result->list (json-builder-feed! b (bytes "[1234]"))))
           (_2 (json-builder-reset! b))
           (r1 (run b (list (bytes "[null]"))))
           (_3 (json-builder-reset! b))
           (r2 (run b (list (bytes "{\"a\":1}")))))
      (list d n (cadr r1) (cadr r2)))))

;; One builder, 100 documents, a reset between each.
(define (doc-of i)
  (let ((n (number->string i)))
    (case (mod i 5)
      ((0) (cons (bytes (string-append "[" n ",\"s" n "\",{\"k" n "\":null}]"))
                 (vector i (string-append "s" n) (list (cons (string-append "k" n) 'null)))))
      ((1) (cons (bytes (string-append "{\"a" n "\":[" n "," n ".5],\"b\":\"" n "\"}"))
                 (list (cons (string-append "a" n) (vector i (+ i 1/2 0.0)))
                       (cons "b" n))))
      ((2) (cons (bytes (string-append "\"t" n "\\n\"")) (string-append "t" n "\n")))
      ((3) (cons (bytes (string-append "[[" n "],[[" n "]]]"))
                 (vector (vector i) (vector (vector i)))))
      (else (cons (bytes n) i)))))

(test-equal "reuse: 100 documents, each built right, a reset between each"
  (let loop ((i 0) (acc '()))
    (if (= i 100)
        (reverse acc)
        (loop (+ i 1) (cons #t acc))))
  (let ((b (make-json-builder)))
    (let loop ((i 0) (acc '()))
      (if (= i 100)
          (reverse acc)
          (let* ((d (doc-of i))
                 (_ (json-builder-reset! b))
                 (r (run b (chunks-of (car d) (if (even? i) 1 1000))))
                 (n (bytevector-length (car d))))
            (loop (+ i 1)
                  (cons (equal? r (list (ok-results n (if (even? i) 1 1000)) (cdr d)))
                        acc)))))))

(test-equal "reuse: 100 documents, with an error or a half document before each reset"
  (let loop ((i 0) (acc '()))
    (if (= i 100) (reverse acc) (loop (+ i 1) (cons #t acc))))
  (let ((b (make-json-builder)))
    (let loop ((i 0) (acc '()))
      (if (= i 100)
          (reverse acc)
          (let* ((d (doc-of i))
                 (_ (feed-list b (list (case (mod i 4)
                                          ((0) (bytes "[1,{\"x\":[\"half"))
                                          ((1) (bytes "[}"))
                                          ((2) (bytes "{\"y\":12"))
                                          (else (bytes ""))))))
                 (_r (json-builder-reset! b))
                 (r (run b (list (car d))))
                 (n (bytevector-length (car d))))
            (loop (+ i 1) (cons (equal? r (list (ok-results n n) (cdr d))) acc)))))))

;; Reset of a fresh builder, and twice in a row.
(test-equal "reset: a fresh builder, twice, then a document"
  (list (no-value-refusal 'need-input) (ok-results 3 3) (vector 1))
  (let ((b (make-json-builder)))
    (json-builder-reset! b)
    (json-builder-reset! b)
    (let* ((v (value-refusal b))
           (r (run b (list (bytes "[1]")))))
      (list v (car r) (cadr r)))))

;; --- 5. independent builders -------------------------------------------------------------------

(define doc-a (bytes "[1,{\"a\":[null,\"x\"]},\"yy\"]"))
(define want-a (vector 1 '(("a" . #(null "x"))) "yy"))
(define doc-b (bytes "{\"k\":[1.5,null,\"kk\"],\"j\":{\"z\":true},\"m\":[2.5],\"n\":null,\"k\":0}"))
(define want-b (tbl (cons "j" (tbl '("z" . #t))) '("k" . 0) '("m" . #(5/2)) '("n" . nil)))
(define opts-b (opts 'object-mode 'hashtable 'null 'nil 'number-mode 'exact))
(define doc-c (bytes "[[[1]]]"))
(define opts-c (opts 'depth-limit 2))
(define doc-d (bytes "[\"d\",[null],{\"q\":[]},12]"))
(define want-d (vector "d" (vector 'zero) '(("q" . #())) 12))
(define opts-d (opts 'null 'zero))

;; interleave : (Listof (Pair builder bytevector)) -> void
;; One byte to each builder in turn, until every document is spent.
(define (interleave! pairs)
  (let ((longest (apply max (map (lambda (p) (bytevector-length (cdr p))) pairs))))
    (do ((i 0 (+ i 1))) ((= i longest))
      (for-each (lambda (p)
                  (when (< i (bytevector-length (cdr p)))
                    (json-builder-feed! (car p) (cdr p) i (+ i 1))))
                pairs))))

(define (finish-and-value b)
  (let* ((fin (result->list (json-builder-finish! b)))
         (v (value-of b)))
    (list fin v)))

(define (finish-all pairs)
  (let loop ((ps pairs) (acc '()))
    (if (null? ps)
        (reverse acc)
        (loop (cdr ps) (cons (finish-and-value (car (car ps))) acc)))))

(let ((a (make-json-builder)) (b (make-json-builder opts-b)))
  (test-equal "independent: two builders, interleaved in 1-byte feeds"
    (list (list (list 'finished #f (bytevector-length doc-a)) want-a)
          (list (list 'finished #f (bytevector-length doc-b)) want-b))
    (begin (interleave! (list (cons a doc-a) (cons b doc-b)))
           (finish-all (list (cons a doc-a) (cons b doc-b))))))

(let ((a (make-json-builder)) (b (make-json-builder opts-b)))
  (test-equal "independent: two builders, the other way round"
    (list (list (list 'finished #f (bytevector-length doc-b)) want-b)
          (list (list 'finished #f (bytevector-length doc-a)) want-a))
    (begin (interleave! (list (cons b doc-b) (cons a doc-a)))
           (finish-all (list (cons b doc-b) (cons a doc-a))))))

(for-each
 (lambda (order)
   (let ((a (make-json-builder)) (b (make-json-builder opts-b))
         (c (make-json-builder opts-c)) (d (make-json-builder opts-d)))
     (let* ((all (list (cons 'a (cons a doc-a)) (cons 'b (cons b doc-b))
                       (cons 'c (cons c doc-c)) (cons 'd (cons d doc-d))))
            (chosen (map (lambda (k) (assq k all)) order)))
       (begin
         (test-equal (string-append "independent: " (describe order)
                                    ", one hits an error, the rest build their own")
           (map (lambda (k)
                  (case k
                    ((a) (list (list 'finished #f (bytevector-length doc-a)) want-a))
                    ((b) (list (list 'finished #f (bytevector-length doc-b)) want-b))
                    ((c) (list '(error nesting-too-deep 3) 'no-value))
                    (else (list (list 'finished #f (bytevector-length doc-d)) want-d))))
                order)
           (begin (interleave! (map cdr chosen))
                  (finish-all (map cdr chosen))))))))
 '((a b c) (c a b) (a c b) (b a c) (c b a) (a c b d) (c d a b) (d c b a) (b d a c)))

(test-equal "independent: an error in one leaves the others' unfinished documents alone"
  (list '(error unexpected-byte 1) '(need-input #f 4) (list '(finished #f 7) (vector 1 (vector 2))))
  (let ((a (make-json-builder)) (c (make-json-builder)))
    (json-builder-feed! a (bytes "[1,"))
    (let* ((e (result->list (json-builder-feed! c (bytes "[}"))))
           (f (result->list (json-builder-feed! a (bytes "[")))))
      (json-builder-feed! a (bytes "2]]"))
      (list e f (finish-and-value a)))))

(test-equal "independent: a reset of one builder leaves another's document alone"
  (list (list '(finished #f 7) (vector 1 (vector 2))) (list '(finished #f 3) (vector 9)))
  (let ((a (make-json-builder)) (c (make-json-builder)))
    (json-builder-feed! a (bytes "[1,[2"))
    (json-builder-feed! c (bytes "[[[x"))
    (json-builder-reset! c)
    (json-builder-feed! c (bytes "[9"))
    (json-builder-feed! a (bytes "]]"))
    (json-builder-feed! c (bytes "]"))
    (list (finish-and-value a) (finish-and-value c))))

;; --- 6. refusals of the procedures ---------------------------------------------------------------------

(define a-parser (make-json-parser (make-json-handler)))

(for-each
 (lambda (v)
   (let ((label (describe v)))
     (test-equal (string-append "refusal: feed, " label " is not a builder")
       (refused 'json-builder-feed! "not a builder" v)
       (refusal (lambda () (json-builder-feed! v (bytes "[1]")))))
     (test-equal (string-append "refusal: feed with a range, " label " is not a builder")
       (refused 'json-builder-feed! "not a builder" v)
       (refusal (lambda () (json-builder-feed! v (bytes "[1]") 0 3))))
     (test-equal (string-append "refusal: finish, " label " is not a builder")
       (refused 'json-builder-finish! "not a builder" v)
       (refusal (lambda () (json-builder-finish! v))))
     (test-equal (string-append "refusal: value, " label " is not a builder")
       (refused 'json-builder-value "not a builder" v)
       (refusal (lambda () (json-builder-value v))))
     (test-equal (string-append "refusal: reset, " label " is not a builder")
       (refused 'json-builder-reset! "not a builder" v)
       (refusal (lambda () (json-builder-reset! v))))))
 (list 5 #f 'builder (vector) a-parser (make-json-options) (make-json-assembler) '()))

(test-equal "refusal: feed, a non-builder and a non-bytevector: the builder is named"
  (refused 'json-builder-feed! "not a builder" 5)
  (refusal (lambda () (json-builder-feed! 5 "x"))))
(test-equal "refusal: feed, a non-builder and a non-bytevector, four arguments"
  (refused 'json-builder-feed! "not a builder" 5)
  (refusal (lambda () (json-builder-feed! 5 "x" 0 1))))

(define feed-doc (bytes "[1,2]"))

;; Each bad feed; the builder first holds `[1,` and, after the refusal, takes
;; `2]` and finishes as if the refused call had never happened.
(define (refused-feed-case label thunk-of expected)
  (test-equal (string-append "refusal: feed, " label)
    (list expected '(need-input #f 3) '(need-input #f 5) '(finished #f 5) (vector 1 2))
    (guard (e (#t (list 'raised (describe e))))
      (let* ((b (make-json-builder))
             (f1 (result->list (json-builder-feed! b (bytes "[1,"))))
             (r (refusal (lambda () (thunk-of b))))
             (f2 (result->list (json-builder-feed! b (bytes "2]"))))
             (fin (result->list (json-builder-finish! b)))
             (v (value-of b)))
        (list r f1 f2 fin v)))))

;; A refused feed changes nothing: not the status either.
(test-equal "refusal: feed, a refused feed leaves a pending builder with no value, the status unchanged"
  (list (refused 'json-builder-feed! "the range is not within the bytevector" 3 2 5)
        (no-value-refusal 'need-input))
  (guard (e (#t (list 'raised (describe e))))
    (let* ((b (make-json-builder))
           (_ (json-builder-feed! b (bytes "[1,")))
           (r (refusal (lambda () (json-builder-feed! b feed-doc 3 2))))
           (v (value-refusal b)))
      (list r v))))
(test-equal "refusal: feed, a refused feed leaves a finished builder with its value"
  (list (refused 'json-builder-feed! "not a bytevector" "x") (vector 1 2) '(finished #f 5))
  (guard (e (#t (list 'raised (describe e))))
    (let* ((b (make-json-builder))
           (_ (json-builder-feed! b feed-doc))
           (_f (json-builder-finish! b))
           (r (refusal (lambda () (json-builder-feed! b "x"))))
           (v (value-of b))
           (again (result->list (json-builder-finish! b))))
      (list r v again))))
(test-equal "refusal: feed, a refused feed leaves a finished builder with its value, a bad range"
  (list (refused 'json-builder-feed! "the range is not within the bytevector" 0 9 5) (vector 1 2))
  (guard (e (#t (list 'raised (describe e))))
    (let* ((b (make-json-builder))
           (_ (json-builder-feed! b feed-doc))
           (_f (json-builder-finish! b))
           (r (refusal (lambda () (json-builder-feed! b feed-doc 0 9))))
           (v (value-of b)))
      (list r v))))
(test-equal "refusal: feed, a refused feed leaves an errored builder's error"
  (list (refused 'json-builder-feed! "the range is not within the bytevector" 0 9 5)
        '(error unexpected-byte 1) (no-value-refusal 'error))
  (guard (e (#t (list 'raised (describe e))))
    (let* ((b (make-json-builder))
           (_ (json-builder-feed! b (bytes "[}")))
           (r (refusal (lambda () (json-builder-feed! b feed-doc 0 9))))
           (f (result->list (json-builder-feed! b (bytes "")))))
      (list r f (value-refusal b)))))

(define range-message "the range is not within the bytevector")

(refused-feed-case "start after end"
  (lambda (b) (json-builder-feed! b feed-doc 3 2))
  (refused 'json-builder-feed! range-message 3 2 5))
(refused-feed-case "end past the length"
  (lambda (b) (json-builder-feed! b feed-doc 0 6))
  (refused 'json-builder-feed! range-message 0 6 5))
(refused-feed-case "start past the length"
  (lambda (b) (json-builder-feed! b feed-doc 6 6))
  (refused 'json-builder-feed! range-message 6 6 5))
(refused-feed-case "a negative start"
  (lambda (b) (json-builder-feed! b feed-doc -1 3))
  (refused 'json-builder-feed! range-message -1 3 5))
(refused-feed-case "a negative end"
  (lambda (b) (json-builder-feed! b feed-doc 0 -1))
  (refused 'json-builder-feed! range-message 0 -1 5))
(refused-feed-case "a flonum start"
  (lambda (b) (json-builder-feed! b feed-doc 1.0 3))
  (refused 'json-builder-feed! range-message 1.0 3 5))
(refused-feed-case "a flonum end"
  (lambda (b) (json-builder-feed! b feed-doc 1 3.0))
  (refused 'json-builder-feed! range-message 1 3.0 5))
(refused-feed-case "a non-number end"
  (lambda (b) (json-builder-feed! b feed-doc 0 "3"))
  (refused 'json-builder-feed! range-message 0 "3" 5))
(refused-feed-case "a #f start"
  (lambda (b) (json-builder-feed! b feed-doc #f 3))
  (refused 'json-builder-feed! range-message #f 3 5))
(refused-feed-case "a bignum end"
  (lambda (b) (json-builder-feed! b feed-doc 0 (expt 2 70)))
  (refused 'json-builder-feed! range-message 0 (expt 2 70) 5))
(refused-feed-case "a bignum start"
  (lambda (b) (json-builder-feed! b feed-doc (expt 2 70) (expt 2 71)))
  (refused 'json-builder-feed! range-message (expt 2 70) (expt 2 71) 5))
(refused-feed-case "a rational start"
  (lambda (b) (json-builder-feed! b feed-doc 1/2 3))
  (refused 'json-builder-feed! range-message 1/2 3 5))
(refused-feed-case "a string, two arguments"
  (lambda (b) (json-builder-feed! b "[1]"))
  (refused 'json-builder-feed! "not a bytevector" "[1]"))
(refused-feed-case "a list, four arguments"
  (lambda (b) (json-builder-feed! b '(91) 0 1))
  (refused 'json-builder-feed! "not a bytevector" '(91)))
(refused-feed-case "a vector, two arguments"
  (lambda (b) (json-builder-feed! b (vector 91)))
  (refused 'json-builder-feed! "not a bytevector" (vector 91)))
(refused-feed-case "#f, two arguments"
  (lambda (b) (json-builder-feed! b #f))
  (refused 'json-builder-feed! "not a bytevector" #f))

(test-equal "refusal: a good range of the same bytevector is fine, and so are the edges"
  (list '(need-input #f 0) '(need-input #f 0) '(need-input #f 5) '(finished #f 5) (vector 1 2))
  (let* ((b (make-json-builder))
         (e1 (result->list (json-builder-feed! b feed-doc 0 0)))
         (e2 (result->list (json-builder-feed! b feed-doc 5 5)))
         (w (result->list (json-builder-feed! b feed-doc 0 5)))
         (fin (result->list (json-builder-finish! b))))
    (list e1 e2 w fin (value-of b))))

;; --- 8. sub-ranges ------------------------------------------------------------------------------------------

(define doc8
  (bytes "{\"k\\u00e9\":[\"a\\uD83D\\uDE00b\",\"x\xE9;y\",1.5,-3,true,false,null,{}]}"))
(define want8 '(("k\xE9;" . #("a\x1F600;b" "x\xE9;y" 1.5 -3 #t #f null ()))))
(define junk (bytes "}]\",x\\{["))

(define (ranges-of len k lead)
  ;; (start . end) pairs over [lead, lead+len), K bytes each.
  (let loop ((at 0) (acc '()))
    (if (>= at len)
        (reverse acc)
        (let ((e (min len (+ at k))))
          (loop e (cons (cons (+ lead at) (+ lead e)) acc))))))

(define (feed-ranges b bv ranges)
  (let loop ((rs ranges) (acc '()))
    (if (null? rs)
        (reverse acc)
        (loop (cdr rs)
              (cons (result->list (json-builder-feed! b bv (car (car rs)) (cdr (car rs)))) acc)))))

(let* ((lead (bytevector-length junk))
       (len (bytevector-length doc8))
       (big (cat junk doc8 junk))
       (end (bytevector-length big)))
  (for-each
   (lambda (k)
     (let* ((ranges (ranges-of len k lead))
            (extra (append (list (cons 0 0) (cons end end)) ranges (list (cons 3 3))))
            (alone (run (make-json-builder) (chunks-of doc8 k)))
            (b (make-json-builder))
            (fs (feed-ranges b big ranges))
            (fin (result->list (json-builder-finish! b))))
       (test-equal (string-append "ranges: one larger bytevector, " (number->string k) "-byte ranges")
         (list (car alone) want8)
         (list (append fs (list fin)) (value-of b)))
       (let* ((b2 (make-json-builder))
              (fs2 (feed-ranges b2 big extra))
              (fin2 (result->list (json-builder-finish! b2))))
         (test-equal (string-append "ranges: " (number->string k)
                                    "-byte ranges with empty ranges between and junk around")
           (list want8 (list 'finished #f len))
           (list (value-of b2) fin2)))
       ;; each piece in its own bytevector, with junk either side
       (let* ((b3 (make-json-builder))
              (pieces (chunks-of doc8 k))
              (fs3 (let loop ((ps pieces) (acc '()))
                     (if (null? ps)
                         (reverse acc)
                         (let* ((p (car ps))
                                (w (cat junk p junk))
                                (r (json-builder-feed! b3 w lead (+ lead (bytevector-length p)))))
                           (loop (cdr ps) (cons (result->list r) acc))))))
              (fin3 (result->list (json-builder-finish! b3))))
         (test-equal (string-append "ranges: junk-wrapped pieces, " (number->string k) " bytes")
           (list (car alone) want8)
           (list (append fs3 (list fin3)) (value-of b3))))))
   '(1 2 3 5 11 1000)))

(test-end "tree-api")

(display "elapsed ms: ")
(display (- (real-time) started))
(newline)
(display "pass ")
(display (test-runner-pass-count runner))
(display " fail ")
(display (test-runner-fail-count runner))
(newline)

(exit (suite-exit-status runner))
