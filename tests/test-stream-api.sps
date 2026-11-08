#!r6rs
;;; tests/test-stream-api.sps: what slice 7 added below the reader (ADR-0020):
;;; the options stream and blank-lines, the parser under stream values,
;;; make-json-result, the builder's EACH, and &json-record-error.
;;;
;;; Every expected value is written by hand, from the bytes of the input.
;;;
;;; 1. The options. 2. The parser under stream values, and the same inputs
;;; under lines and seq. 3. make-json-result. 4. The builder's EACH.
;;; 5. &json-record-error.
(import (rnrs)
        (only (chezscheme) real-time)
        (srfi :64)
        (jsonparse-testing)
        (jsonparse-testing parser)
        (jsonparse error)
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

;; violation-who : (-> Any) -> (U 'no-raise (List 'violation Any))
;; The who of an assertion violation; anything else raised is left to fail.
(define (violation-who thunk)
  (guard (e ((assertion-violation? e)
             (list 'violation (and (who-condition? e) (condition-who e)))))
    (thunk)
    'no-raise))

(define (result->list r)
  (list (json-result-status r) (json-result-code r) (json-result-offset r)))

;; in-order : Expr ... -> (Listof Any)
;; (list E ...) with the expressions evaluated left to right: Chez
;; evaluates a call's arguments in no fixed order.
(define-syntax in-order
  (syntax-rules ()
    ((_ e ...) (in-order-loop (e ...) ()))))
(define-syntax in-order-loop
  (syntax-rules ()
    ((_ () (t ...)) (list t ...))
    ((_ (e rest ...) (t ...)) (let ((v e)) (in-order-loop (rest ...) (t ... v))))))

(define (opts . args) (apply make-json-options args))

(define (sub bv from to)
  (let ((out (make-bytevector (- to from))))
    (bytevector-copy! bv from out 0 (- to from))
    out))

;; norm : Any -> Any
;; A value with each hashtable written as (table mutable? ((key . value) ...)),
;; the pairs sorted by key, and each json-number as (number TEXT).
(define (norm v)
  (cond ((hashtable? v)
         (list 'table (hashtable-mutable? v)
               (list-sort (lambda (a b) (string<? (car a) (car b)))
                          (map (lambda (k) (cons k (norm (hashtable-ref v k 'missing))))
                               (vector->list (hashtable-keys v))))))
        ((json-number? v) (list 'number (json-number-text v)))
        ((vector? v) (vector-map norm v))
        ((pair? v) (cons (norm (car v)) (norm (cdr v))))
        (else v)))

(define (tbl . entries) (list 'table #t entries))

(define (rep n s)
  (let loop ((i 0) (acc '()))
    (if (= i n) (apply string-append acc) (loop (+ i 1) (cons s acc)))))

(define (iota-list n)
  (let loop ((i (- n 1)) (acc '()))
    (if (< i 0) acc (loop (- i 1) (cons i acc)))))

(define (join strs sep)
  (if (null? strs)
      ""
      (let loop ((xs (cdr strs)) (acc (car strs)))
        (if (null? xs) acc (loop (cdr xs) (string-append acc sep (car xs)))))))

(define (nest n)
  (let loop ((i 1) (v (vector)))
    (if (= i n) v (loop (+ i 1) (vector v)))))

;; nest-object : Nat -> alist, N objects deep, each holding "a" and the next.
(define (nest-object n)
  (let loop ((i 1) (v '()))
    (if (= i n) v (loop (+ i 1) (list (cons "a" v))))))

(test-begin "stream-api")

;; --- 1. the options ---------------------------------------------------------------

(test-equal "options: stream defaults to lines" 'lines
  (json-options-stream (make-json-options)))
(test-equal "options: blank-lines defaults to error" 'error
  (json-options-blank-lines (make-json-options)))
(for-each
 (lambda (v)
   (test-equal (string-append "options: stream " (symbol->string v) " reads back") v
     (json-options-stream (make-json-options 'stream v))))
 '(lines seq values))
(for-each
 (lambda (v)
   (test-equal (string-append "options: blank-lines " (symbol->string v) " reads back") v
     (json-options-blank-lines (make-json-options 'blank-lines v)))
   (test-equal (string-append "options: blank-lines " (symbol->string v) " after stream lines reads back")
     (list 'lines v)
     (let ((o (make-json-options 'stream 'lines 'blank-lines v)))
       (list (json-options-stream o) (json-options-blank-lines o))))
   (test-equal (string-append "options: blank-lines " (symbol->string v) " before stream lines reads back")
     (list 'lines v)
     (let ((o (make-json-options 'blank-lines v 'stream 'lines)))
       (list (json-options-stream o) (json-options-blank-lines o)))))
 '(error skip))

(define stream-message "stream is not lines, seq or values")
(define blank-message "blank-lines is not error or skip")
(define only-lines-message "blank-lines applies only under stream lines")

(for-each
 (lambda (v)
   (test-equal (string-append "options: stream " (describe v) " is refused")
     (refused 'make-json-options stream-message v)
     (refusal (lambda () (make-json-options 'stream v)))))
 (list 'line 'Lines "lines" #f #t 0 '() '(lines) (vector 'lines) 'error 'skip))
(for-each
 (lambda (v)
   (test-equal (string-append "options: blank-lines " (describe v) " is refused")
     (refused 'make-json-options blank-message v)
     (refusal (lambda () (make-json-options 'blank-lines v)))))
 (list 'skipped 'Skip "skip" #f #t 0 '() '(skip) (vector 'skip) 'lines 'values))

(test-equal "options: a bad stream after a good option is refused"
  (refused 'make-json-options stream-message 'nope)
  (refusal (lambda () (make-json-options 'indent 2 'stream 'nope))))
(test-equal "options: a bad blank-lines after a good option is refused"
  (refused 'make-json-options blank-message 'nope)
  (refusal (lambda () (make-json-options 'indent 2 'blank-lines 'nope))))
(test-equal "options: a bad blank-lines under stream seq is refused for its value, stream first"
  (refused 'make-json-options blank-message 'nope)
  (refusal (lambda () (make-json-options 'stream 'seq 'blank-lines 'nope))))
(test-equal "options: a bad blank-lines under stream seq is refused for its value, blank-lines first"
  (refused 'make-json-options blank-message 'nope)
  (refusal (lambda () (make-json-options 'blank-lines 'nope 'stream 'seq))))
(test-equal "options: a bad stream after blank-lines skip is refused for its value"
  (refused 'make-json-options stream-message 'nope)
  (refusal (lambda () (make-json-options 'blank-lines 'skip 'stream 'nope))))

(test-equal "options: stream twice"
  (refused 'make-json-options "an option is given twice" 'stream)
  (refusal (lambda () (make-json-options 'stream 'seq 'stream 'values))))
(test-equal "options: stream twice, the same value"
  (refused 'make-json-options "an option is given twice" 'stream)
  (refusal (lambda () (make-json-options 'stream 'lines 'stream 'lines))))
(test-equal "options: blank-lines twice"
  (refused 'make-json-options "an option is given twice" 'blank-lines)
  (refusal (lambda () (make-json-options 'blank-lines 'skip 'blank-lines 'error))))
(test-equal "options: blank-lines twice, the same value"
  (refused 'make-json-options "an option is given twice" 'blank-lines)
  (refusal (lambda () (make-json-options 'blank-lines 'skip 'blank-lines 'skip))))
(test-equal "options: stream with no value"
  (refused 'make-json-options "an option has no value" 'stream)
  (refusal (lambda () (make-json-options 'stream))))
(test-equal "options: blank-lines with no value"
  (refused 'make-json-options "an option has no value" 'blank-lines)
  (refusal (lambda () (make-json-options 'blank-lines))))
(test-equal "options: stream with no value after a good pair"
  (refused 'make-json-options "an option has no value" 'stream)
  (refusal (lambda () (make-json-options 'indent 2 'stream))))

;; blank-lines applies under lines only.
(for-each
 (lambda (row)
   (let ((stream (car row)) (given (cadr row)))
     (test-equal (string-append "options: blank-lines " (symbol->string given) " under stream "
                                (symbol->string stream) " (stream first) is refused")
       (refused 'make-json-options only-lines-message stream)
       (refusal (lambda () (make-json-options 'stream stream 'blank-lines given))))
     (test-equal (string-append "options: blank-lines " (symbol->string given) " under stream "
                                (symbol->string stream) " (blank-lines first) is refused")
       (refused 'make-json-options only-lines-message stream)
       (refusal (lambda () (make-json-options 'blank-lines given 'stream stream))))
     (test-equal (string-append "options: blank-lines " (symbol->string given) " under stream "
                                (symbol->string stream) ", other options between, is refused")
       (refused 'make-json-options only-lines-message stream)
       (refusal (lambda () (make-json-options 'blank-lines given 'indent 4 'stream stream 'null 'nil))))))
 '((seq skip) (seq error) (values skip) (values error)))

;; Every ordered pair of distinct options, each given a non-default value:
;; all eight fields read back as given or as their defaults. The expected
;; values come from these tables, never from the options record.
(define option-names '(depth-limit number-mode digit-limit object-mode null indent stream blank-lines))
(define option-defaults '(512 flonum 1000 alist null 0 lines error))
(define option-readers
  (list json-options-depth-limit json-options-number-mode json-options-digit-limit
        json-options-object-mode json-options-null json-options-indent
        json-options-stream json-options-blank-lines))

(define (read-all o) (map (lambda (r) (r o)) option-readers))

;; (given-list stream-value) : the non-default value of each option; stream is
;; STREAM-VALUE.
(define (given-list stream-value) (list 7 'exact 9 'hashtable 'nil 3 stream-value 'skip))

;; expected-with : (Listof Nat) (Listof Any) -> (Listof Any)
;; The defaults, with the options at INDEXES given.
(define (expected-with indexes givens)
  (let loop ((k 0) (ds option-defaults) (gs givens) (acc '()))
    (if (null? ds)
        (reverse acc)
        (loop (+ k 1) (cdr ds) (cdr gs)
              (cons (if (memv k indexes) (car gs) (car ds)) acc)))))

(define (name-of i) (symbol->string (list-ref option-names i)))

;; Every ordered pair of the options at ALLOWED, given GIVENS.
(define (check-pairs! label givens allowed)
  (for-each
   (lambda (i)
     (for-each
      (lambda (j)
        (unless (= i j)
          (test-equal (string-append "options: " label ": " (name-of i) " then " (name-of j))
            (expected-with (list i j) givens)
            (read-all (make-json-options (list-ref option-names i) (list-ref givens i)
                                         (list-ref option-names j) (list-ref givens j))))))
      allowed))
   allowed))

(check-pairs! "stream seq" (given-list 'seq) '(0 1 2 3 4 5 6))
(check-pairs! "stream values" (given-list 'values) '(0 1 2 3 4 5 6))
(check-pairs! "stream lines" (given-list 'lines) '(0 1 2 3 4 5 6 7))

(define (all-names indexes) (map (lambda (i) (list-ref option-names i)) indexes))

;; All the options, as name value pairs, in order or reversed.
(define (all-args givens indexes)
  (apply append (map (lambda (i) (list (list-ref option-names i) (list-ref givens i))) indexes)))

(for-each
 (lambda (row)
   (let* ((label (car row)) (givens (cadr row)) (indexes (caddr row)))
     (test-equal (string-append "options: all given, " label ", in order")
       (expected-with indexes givens)
       (read-all (apply make-json-options (all-args givens indexes))))
     (test-equal (string-append "options: all given, " label ", reversed")
       (expected-with indexes givens)
       (read-all (apply make-json-options (all-args givens (reverse indexes)))))))
 (list (list "stream seq" (given-list 'seq) '(0 1 2 3 4 5 6))
       (list "stream values" (given-list 'values) '(0 1 2 3 4 5 6))
       (list "blank-lines skip" (given-list 'lines) '(0 1 2 3 4 5 7))
       (list "stream lines and blank-lines skip" (given-list 'lines) '(0 1 2 3 4 5 6 7))))

;; --- 2. the parser under stream values ------------------------------------------------

;; one-feed : String -> Schedule
(define (one-feed s) (list (list (bytes s) 0 (bytes-length* s))))
(define (bytes-length* s) (bytevector-length (bytes s)))

(define values-options (make-json-options 'stream 'values))
(define seq-options (make-json-options 'stream 'seq))
(define lines-options (make-json-options 'stream 'lines))

(define (nc s) (list 'number-chars (bytes s)))
(define (chars s) (list 'chars (bytes s)))
(define (num s) (list (nc s) 'number-end))
(define (str s) (if (string=? s "")
                    (list 'string-start 'string-end)
                    (list 'string-start (chars s) 'string-end)))
(define (feed-ok n) (list 'feed 'need-input #f n))
(define (finish-ok n) (list 'finish 'finished #f n))

;; run-values : String -> Trace
(define (run-values s) (run-parser (one-feed s) values-options))

(define-syntax values-case
  (syntax-rules ()
    ((_ label input expected)
     (test-equal (string-append "values: " label) expected (run-values input)))))

(values-case "1 2" "1 2"
  (list (nc "1") 'number-end (nc "2") (feed-ok 3) 'number-end (finish-ok 3)))
(values-case "numbers of every shape" "-1.5e3 0 \"x\""
  (append (num "-1.5e3") (num "0") (str "x") (list (feed-ok 12) (finish-ok 12))))
(values-case "literals" "true false null"
  (list '(boolean #t) '(boolean #f) 'null (feed-ok 15) (finish-ok 15)))
(values-case "strings with nothing between" "\"a\"\"b\"\"\""
  (append (str "a") (str "b") (str "") (list (feed-ok 8) (finish-ok 8))))
(values-case "containers with nothing between" "[][1]{}{\"k\":[]}"
  (list 'array-start 'array-end
        'array-start (nc "1") 'number-end 'array-end
        'object-start 'object-end
        'object-start 'key-start (chars "k") 'key-end 'array-start 'array-end 'object-end
        (feed-ok 15) (finish-ok 15)))
(values-case "a mix, whitespace only where a number or literal needs it" "\"s\"[]true {}1 \"t\"null"
  (append (str "s") (list 'array-start 'array-end '(boolean #t) 'object-start 'object-end)
          (num "1") (str "t") (list 'null (feed-ok 21) (finish-ok 21))))
(values-case "every kind of whitespace between" "\n 1\r\n[ ]\t{ }  \n"
  (list (nc "1") 'number-end 'array-start 'array-end 'object-start 'object-end
        (feed-ok 15) (finish-ok 15)))
(values-case "a string then a literal, with nothing between, then a string after whitespace" "\"a\"true \"b\""
  (append (str "a") (list '(boolean #t)) (str "b") (list (feed-ok 11) (finish-ok 11))))
(values-case "a literal then a string, with nothing between, is an error" "\"a\"true\"b\""
  (append (str "a") (list '(boolean #t) '(feed error unexpected-byte 7))))
(values-case "a closing bracket then a number" "[]1"
  (list 'array-start 'array-end (nc "1") (feed-ok 3) 'number-end (finish-ok 3)))
(values-case "the empty feed" ""
  (list (feed-ok 0) (finish-ok 0)))
(values-case "whitespace only" " \n\t\r "
  (list (feed-ok 5) (finish-ok 5)))
(test-equal "values: no feed at all finishes with no events"
  (list (finish-ok 0))
  (run-parser '() values-options))
(test-equal "values: empty feeds, then whitespace, finish with no events"
  (list (feed-ok 0) (feed-ok 0) (feed-ok 1) (finish-ok 1))
  (run-parser (list (list (bytes "") 0 0) (list (bytes "") 0 0) (list (bytes " ") 0 1)) values-options))

;; Errors, and the events before them.
(values-case "1-2 is an error at the second value" "1-2"
  (list (nc "1") 'number-end '(feed error unexpected-byte 1)))
(values-case "truefalse is an error at the second value" "truefalse"
  (list '(boolean #t) '(feed error unexpected-byte 4)))
(values-case "1[] is an error at the second value" "1[]"
  (list (nc "1") 'number-end '(feed error unexpected-byte 1)))
(values-case "null{} is an error at the second value" "null{}"
  (list 'null '(feed error unexpected-byte 4)))
(values-case "1 2x gives 1 and 2, then the error" "1 2x"
  (list (nc "1") 'number-end (nc "2") 'number-end '(feed error unexpected-byte 3)))
(values-case "a bracket then a stray byte" "[1] x"
  (list 'array-start (nc "1") 'number-end 'array-end '(feed error unexpected-byte 4)))
(values-case "a stray closing brace" "}"
  (list '(feed error unexpected-byte 0)))
(values-case "a container cut short" "[1,2"
  (list 'array-start (nc "1") 'number-end (nc "2") (feed-ok 4) 'number-end
        '(finish error unexpected-eof 4)))
(values-case "a literal cut short" "tru"
  (list (feed-ok 3) '(finish error unexpected-eof 3)))
(values-case "a value after a value that failed is never read" "1-2 3"
  (list (nc "1") 'number-end '(feed error unexpected-byte 1)))

;; The same inputs under lines and seq: one value.
(for-each
 (lambda (row)
   (let ((input (car row)) (expected (cdr row)))
     (for-each
      (lambda (o-label o)
        (test-equal (string-append o-label ": " (describe input))
          expected
          (run-parser (one-feed input) o)))
      '("lines" "seq") (list lines-options seq-options))))
 (list (list "1 2" (nc "1") 'number-end '(feed error trailing-garbage 2))
       (list "1-2" (nc "1") 'number-end '(feed error trailing-garbage 1))
       (list "truefalse" '(boolean #t) '(feed error trailing-garbage 4))
       (list "1[]" (nc "1") 'number-end '(feed error trailing-garbage 1))
       (list "null{}" 'null '(feed error trailing-garbage 4))
       (list "[]{}" 'array-start 'array-end '(feed error trailing-garbage 2))
       (list "\"a\"\"b\"" 'string-start (chars "a") 'string-end '(feed error trailing-garbage 3))))
(test-equal "lines: the empty stream holds no value"
  (list (feed-ok 0) '(finish error unexpected-eof 0))
  (run-parser (one-feed "") lines-options))
(test-equal "seq: whitespace holds no value"
  (list (feed-ok 3) '(finish error unexpected-eof 3))
  (run-parser (one-feed " \n ") seq-options))

;; A traced parser, for reset and for the one-argument constructor. Its
;; handler notes into TRACE, which stands outside the parser.
(define trace '())
(define (note! x) (set! trace (cons x trace)))
(define traced-handler
  (make-json-handler
   'null (lambda (c) (note! 'null))
   'boolean (lambda (c b) (note! (list 'boolean b)))
   'number-chars (lambda (c bv from to) (note! (nc (utf8->string (sub bv from to)))))
   'number-end (lambda (c) (note! 'number-end))
   'array-start (lambda (c) (note! 'array-start))
   'array-end (lambda (c) (note! 'array-end))))

;; traced-run! : json-parser String -> (List Trace (List Result))
;; Feeds S whole, then finishes unless the feed failed; the trace of this
;; run alone.
(define (traced-run! p s)
  (set! trace '())
  (let* ((f (result->list (json-parser-feed! p (bytes s))))
         (fin (if (eq? (car f) 'need-input)
                  (list (result->list (json-parser-finish! p)))
                  '())))
    (list (reverse trace) (cons f fin))))

(define one-arg-parser (make-json-parser traced-handler))
(test-equal "one-argument make-json-parser reads one value: 1 2 is trailing-garbage at 2"
  (list (list (nc "1") 'number-end) '((error trailing-garbage 2)))
  (traced-run! one-arg-parser "1 2"))
(test-equal "one-argument make-json-parser reads one value: [1] then a number"
  (list (list 'array-start (nc "1") 'number-end 'array-end) '((error trailing-garbage 4)))
  (traced-run! (make-json-parser traced-handler) "[1] 2"))
(test-equal "two-argument make-json-parser reads one value"
  (list (list (nc "1") 'number-end) '((error trailing-garbage 2)))
  (traced-run! (make-json-parser traced-handler 'ctx) "1 2"))
(test-equal "make-json-parser with explicit default options reads one value"
  (list (list (nc "1") 'number-end) '((error trailing-garbage 2)))
  (traced-run! (make-json-parser traced-handler #f (make-json-options)) "1 2"))

;; The bit lasts across a reset.
(let ((p (make-json-parser traced-handler #f values-options)))
  (let ((first (traced-run! p "1 2")))
    (json-parser-reset! p)
    (let ((second (traced-run! p "[3] 4 true")))
      (test-equal "values: before a reset, two values"
        (list (list (nc "1") 'number-end (nc "2") 'number-end) '((need-input #f 3) (finished #f 3)))
        first)
      (test-equal "values: after a reset, two values again"
        (list (list 'array-start (nc "3") 'number-end 'array-end (nc "4") 'number-end '(boolean #t))
              '((need-input #f 10) (finished #f 10)))
        second)
      (json-parser-reset! p)
      (test-equal "values: after a second reset, two values again"
        (list (list (nc "1") 'number-end (nc "2") 'number-end) '((need-input #f 3) (finished #f 3)))
        (traced-run! p "1 2")))))
(let ((p (make-json-parser traced-handler #f values-options)))
  (traced-run! p "1-2")
  (json-parser-reset! p)
  (test-equal "values: after a reset from an error, two values"
    (list (list (nc "1") 'number-end (nc "2") 'number-end) '((need-input #f 3) (finished #f 3)))
    (traced-run! p "1 2")))
(let ((p (make-json-parser traced-handler #f values-options)))
  (traced-run! p "[1")
  (json-parser-reset! p)
  (test-equal "values: after a reset from the middle of a value, two values"
    (list (list (nc "1") 'number-end (nc "2") 'number-end) '((need-input #f 3) (finished #f 3)))
    (traced-run! p "1 2")))
(let ((p (make-json-parser traced-handler #f lines-options)))
  (traced-run! p "1 ")
  (json-parser-reset! p)
  (test-equal "lines: after a reset, 1 2 is still trailing-garbage at 2"
    (list (list (nc "1") 'number-end) '((error trailing-garbage 2)))
    (traced-run! p "1 2"))
  (json-parser-reset! p)
  (test-equal "lines: after a second reset, 1 2 is still trailing-garbage at 2"
    (list (list (nc "1") 'number-end) '((error trailing-garbage 2)))
    (traced-run! p "1 2")))
(let ((p (make-json-parser traced-handler #f seq-options)))
  (traced-run! p "1 ")
  (json-parser-reset! p)
  (test-equal "seq: after a reset, 1 2 is still trailing-garbage at 2"
    (list (list (nc "1") 'number-end) '((error trailing-garbage 2)))
    (traced-run! p "1 2")))

;; The depth limit applies to each value.
(define (depth-options n) (make-json-options 'stream 'values 'depth-limit n))
(test-equal "values: depth-limit 2, [[]] [[]] reads"
  (list 'array-start 'array-start 'array-end 'array-end
        'array-start 'array-start 'array-end 'array-end
        (feed-ok 9) (finish-ok 9))
  (run-parser (one-feed "[[]] [[]]") (depth-options 2)))
(test-equal "values: depth-limit 2, [[[]]] fails"
  (list 'array-start 'array-start '(feed error nesting-too-deep 3))
  (run-parser (one-feed "[[[]]]") (depth-options 2)))
(test-equal "values: depth-limit 2, [[]][[[]]] fails in the second value"
  (list 'array-start 'array-start 'array-end 'array-end
        'array-start 'array-start '(feed error nesting-too-deep 7))
  (run-parser (one-feed "[[]][[[]]]") (depth-options 2)))
(test-equal "values: depth-limit 1, the third value is too deep"
  (list 'array-start 'array-end 'array-start 'array-end 'array-start
        '(feed error nesting-too-deep 8))
  (run-parser (one-feed "[] [] [[]]") (depth-options 1)))
(test-equal "values: depth-limit 0 reads scalars"
  (list (nc "1") 'number-end (nc "2") (feed-ok 3) 'number-end (finish-ok 3))
  (run-parser (one-feed "1 2") (depth-options 0)))
(test-equal "values: depth-limit 0 refuses a container after a scalar"
  (list (nc "1") 'number-end '(feed error nesting-too-deep 3))
  (run-parser (one-feed "1 []") (depth-options 0)))

;; Splits into two feeds give the same events.
(define split-input
  "1 [2,\"a\\u00e9b\x3bb;\"] {\"k\":null} true -4.5 \"z\" 7")
(define split-length (bytevector-length (bytes split-input)))

;; canon : Trace -> (Listof Entry)
;; The events alone, with each run of number-chars or of chars made one.
(define (canon trace)
  (let loop ((xs trace) (acc '()))
    (cond
     ((null? xs) (reverse acc))
     ((and (pair? (car xs)) (memq (caar xs) '(feed finish))) (loop (cdr xs) acc))
     ((and (pair? (car xs)) (memq (caar xs) '(number-chars chars))
           (pair? acc) (pair? (car acc)) (eq? (caar acc) (caar xs)))
      (let* ((a (cadr (car acc))) (b (cadr (car xs)))
             (joined (make-bytevector (+ (bytevector-length a) (bytevector-length b)))))
        (bytevector-copy! a 0 joined 0 (bytevector-length a))
        (bytevector-copy! b 0 joined (bytevector-length a) (bytevector-length b))
        (loop (cdr xs) (cons (list (caar xs) joined) (cdr acc)))))
     (else (loop (cdr xs) (cons (car xs) acc))))))

(define (results-of trace)
  (let loop ((xs trace) (acc '()))
    (cond ((null? xs) (reverse acc))
          ((and (pair? (car xs)) (memq (caar xs) '(feed finish))) (loop (cdr xs) (cons (car xs) acc)))
          (else (loop (cdr xs) acc)))))

(define split-events
  (append (num "1")
          (list 'array-start) (num "2")
          (list 'string-start (chars "a") '(escape 233) (list 'chars (u8-list->bytevector '(98 206 187))) 'string-end
                'array-end
                'object-start 'key-start (chars "k") 'key-end 'null 'object-end
                '(boolean #t))
          (num "-4.5") (str "z") (num "7")))

(test-equal "values: the whole stream in one feed, canonical events"
  split-events
  (canon (run-parser (one-feed split-input) values-options)))
(let ((bv (bytes split-input)))
  (do ((k 0 (+ k 1))) ((> k split-length))
    (let ((trace (run-parser (list (list bv 0 k) (list bv k split-length)) values-options)))
      (test-equal (string-append "values: split at " (number->string k) " gives the same events and results")
        (list split-events
              (list (feed-ok k) (feed-ok split-length) (finish-ok split-length)))
        (list (canon trace) (results-of trace))))))
;; Three feeds, every pair of cuts of a short stream.
(let* ((input "1 [2] \"ab\" null 3") (bv (bytes input)) (len (bytevector-length bv))
       (events (append (num "1") (list 'array-start) (num "2") (list 'array-end)
                       (str "ab") (list 'null) (num "3"))))
  (do ((a 0 (+ a 1))) ((> a len))
    (do ((b a (+ b 1))) ((> b len))
      (let ((trace (run-parser (list (list bv 0 a) (list bv a b) (list bv b len)) values-options)))
        (test-equal (string-append "values: cuts at " (number->string a) " and " (number->string b))
          (list events (list (feed-ok a) (feed-ok b) (feed-ok len) (finish-ok len)))
          (list (canon trace) (results-of trace)))))))
;; An error is at the same offset wherever the feed is cut.
(let* ((input "[1] 2 true{}") (bv (bytes input)) (len (bytevector-length bv)))
  (do ((k 0 (+ k 1))) ((> k len))
    (let ((trace (run-parser (list (list bv 0 k) (list bv k len)) values-options)))
      (test-equal (string-append "values: an error at 10, the feed cut at " (number->string k))
        (list (append (list 'array-start) (num "1") (list 'array-end) (num "2") (list '(boolean #t)))
              (if (<= k 10)
                  (list (feed-ok k) '(feed error unexpected-byte 10))
                  (list '(feed error unexpected-byte 10))))
        (list (canon trace) (results-of trace))))))

;; --- 3. make-json-result -------------------------------------------------------------

(for-each
 (lambda (row)
   (let ((status (car row)) (code (cadr row)) (offset (caddr row)))
     (test-equal (string-append "result: " (describe row) " reads back")
       (list #t status code offset)
       (let ((r (make-json-result status code offset)))
         (list (json-result? r) (json-result-status r) (json-result-code r) (json-result-offset r))))))
 `((need-input #f 0) (need-input #f 12) (finished #f 0) (finished #f 7)
   (error unexpected-byte 3) (error a 0) (error x9-y 41) (error trailing-garbage 1000000000000000000000)
   (need-input #f 1000000000000000000000)
   (error ,(string->symbol "abc-def-0123456789") 5)))

(define status-message "the status is not need-input, finished or error")
(define code-message "the code is not a symbol spelt [a-z][a-z0-9-]* for an error, or #f otherwise")
(define offset-message "the offset is not an exact nonnegative integer")

(for-each
 (lambda (status)
   (test-equal (string-append "result: status " (describe status) " is refused")
     (refused 'make-json-result status-message status)
     (refusal (lambda () (make-json-result status #f 0)))))
 (list 'ok 'Error 'done "error" #f #t 0 '() 'need-inputs))
(test-equal "result: a bad status is refused before a bad code and offset"
  (refused 'make-json-result status-message 'ok)
  (refusal (lambda () (make-json-result 'ok 'Bad -1))))
(test-equal "result: an error with no code is refused"
  (refused 'make-json-result code-message 'error #f)
  (refusal (lambda () (make-json-result 'error #f 0))))
(for-each
 (lambda (code)
   (test-equal (string-append "result: an error with the code " (describe code) " is refused")
     (refused 'make-json-result code-message 'error code)
     (refusal (lambda () (make-json-result 'error code 0)))))
 (list 'Bad 'bAd 'A (string->symbol "1a") (string->symbol "-a") 'a_b (string->symbol "a b") (string->symbol "")
       (string->symbol "a\x3bb;") (string->symbol "a.b") "unexpected-byte" 5 #t '(a)))
(for-each
 (lambda (status)
   (test-equal (string-append "result: " (symbol->string status) " with a code is refused")
     (refused 'make-json-result code-message status 'unexpected-byte)
     (refusal (lambda () (make-json-result status 'unexpected-byte 0))))
   (test-equal (string-append "result: " (symbol->string status) " with a misspelt code is refused")
     (refused 'make-json-result code-message status 'Bad)
     (refusal (lambda () (make-json-result status 'Bad 0))))
   (test-equal (string-append "result: " (symbol->string status) " with the code #t is refused")
     (refused 'make-json-result code-message status #t)
     (refusal (lambda () (make-json-result status #t 0)))))
 '(need-input finished))
(test-equal "result: a bad code is refused before a bad offset"
  (refused 'make-json-result code-message 'error 'Bad)
  (refusal (lambda () (make-json-result 'error 'Bad -1))))
(for-each
 (lambda (offset)
   (test-equal (string-append "result: the offset " (describe offset) " is refused (error)")
     (refused 'make-json-result offset-message offset)
     (refusal (lambda () (make-json-result 'error 'unexpected-byte offset))))
   (test-equal (string-append "result: the offset " (describe offset) " is refused (need-input)")
     (refused 'make-json-result offset-message offset)
     (refusal (lambda () (make-json-result 'need-input #f offset)))))
 (list -1 -1000000000000000000000 1.5 1.0 0.0 3/2 "1" 'a #f +nan.0 +inf.0 '(1)))

;; --- 4. the builder's EACH -----------------------------------------------------------

(test-equal "builder: a good EACH builder is a builder"
  #t
  (json-builder? (make-json-builder values-options car)))

;; collector : json-options -> (Pair json-builder (-> (Listof Any)))
;; A builder whose EACH keeps what it is given; the thunk answers them, in
;; order and normalised.
(define (collector options)
  (let* ((log '())
         (b (make-json-builder options (lambda (v) (set! log (cons v log)) 'ignored))))
    (cons b (lambda () (map norm (reverse log))))))

;; each-run : json-options (Listof String) -> (List (Listof Result) (Listof Any))
;; Every feed's result, then the finish's; then what EACH was given.
(define (each-run options chunks)
  (let* ((c (collector options)) (b (car c)))
    (let loop ((cs chunks) (acc '()))
      (if (null? cs)
          (let ((fin (result->list (json-builder-finish! b))))
            (list (reverse (cons fin acc)) ((cdr c))))
          (loop (cdr cs) (cons (result->list (json-builder-feed! b (bytes (car cs)))) acc))))))

(define (each-values options chunks) (cadr (each-run options chunks)))

(define kinds-input "null true false -2 1.5 \"s\\n\" [1,[2,{}]] {\"a\":1,\"a\":2}")
(define kinds-expected
  (list 'null #t #f -2 1.5 "s\n" (vector 1 (vector 2 '())) '(("a" . 1) ("a" . 2))))

(test-equal "each: every kind arrives in order, in one feed"
  (list '((need-input #f 53) (finished #f 53)) kinds-expected)
  (each-run values-options (list kinds-input)))
(test-equal "each: every kind arrives in order, with nothing between where the grammar allows"
  (list '((need-input #f 23) (finished #f 23))
        (list "a" "b" (vector) '() (vector 1) '(("k" . #())) ""))
  (each-run values-options (list "\"a\"\"b\"[]{}[1]{\"k\":[]}\"\"")))
(test-equal "each: nested containers arrive whole"
  (list '((need-input #f 34) (finished #f 34))
        (list (vector (vector (vector (vector 1))) '(("a" . #(2)))) '(("b" . (("c" . ()))))))
  (each-run values-options (list "[[[[1]]],{\"a\":[2]}] {\"b\":{\"c\":{}}}")))
(test-equal "each: empty and whitespace-only streams hand nothing on"
  (list (list '((need-input #f 0) (finished #f 0)) '())
        (list '((need-input #f 4) (finished #f 4)) '()))
  (list (each-run values-options (list ""))
        (each-run values-options (list " \n\t "))))
(test-equal "each: no feed at all hands nothing on"
  (list '((finished #f 0)) '())
  (each-run values-options '()))

(let ((o (make-json-options 'stream 'values 'object-mode 'hashtable 'null 'nil)))
  (test-equal "each: under object-mode hashtable and null nil"
    (list (tbl (cons "a" (tbl (cons "b" 'nil))))
          (vector 'nil (tbl))
          'nil)
    (each-values o (list "{\"a\":{\"b\":null}} [null,{}] null"))))
(let ((o (make-json-options 'stream 'values 'number-mode 'text)))
  (test-equal "each: under number-mode text"
    (list '(number "12") (vector '(number "1.50") '(number "-0e0")) '(number "7"))
    (each-values o (list "12 [1.50,-0e0] 7"))))
(let ((o (make-json-options 'stream 'values 'number-mode 'exact)))
  (test-equal "each: under number-mode exact"
    (list 3/2 2 (vector 1/4))
    (each-values o (list "1.5 2 [0.25]"))))
(let ((o (make-json-options 'stream 'values 'object-mode 'hashtable 'null 'nil
                            'number-mode 'text 'depth-limit 5 'digit-limit 8)))
  (test-equal "each: under every non-default option"
    (list (tbl (cons "a" (vector 'nil '(number "1e5")))) 'nil)
    (each-values o (list "{\"a\":[null,1e5]} null"))))

(test-equal "each: a number past the digit limit ends the parse with its code, and is not handed on"
  (list '((error number-too-long 8) (error number-too-long 8)) (list 1))
  (each-run (make-json-options 'stream 'values 'digit-limit 3) (list "1 123456 7")))
(test-equal "each: a number past the digit limit at the end of the stream comes at finish"
  (list '((need-input #f 8) (error number-too-long 8)) (list 1))
  (each-run (make-json-options 'stream 'values 'digit-limit 3) (list "1 123456")))
(test-equal "each: a number past the digit limit inside an array ends the parse"
  (list '((error number-too-long 8) (error number-too-long 8)) (list 1))
  (each-run (make-json-options 'stream 'values 'digit-limit 3) (list "1 [12345]")))
(test-equal "each: a number out of range ends the parse with its code, and is not handed on"
  (list '((error number-out-of-range 7) (error number-out-of-range 7)) (list 1))
  (each-run values-options (list "1 1e999 7")))

;; When each arrives: fed a byte at a time, the index of the feed that
;; handed it on, or fin for the finish.
(define (arrivals doc options)
  (let* ((bv (bytes doc)) (at 0) (log '())
         (b (make-json-builder options (lambda (v) (set! log (cons (cons at (norm v)) log)) #f))))
    (do ((k 0 (+ k 1))) ((= k (bytevector-length bv)))
      (set! at k)
      (json-builder-feed! b bv k (+ k 1)))
    (set! at 'fin)
    (let ((fin (result->list (json-builder-finish! b))))
      (list (reverse log) fin))))

(test-equal "each: a string at its closing quote, a container at its close, a number at the byte after it, a literal at its last letter"
  (list '((3 . "ab") (6 . #(1)) (13 . (("k" . 2))) (16 . 12) (20 . #t) (25 . null))
        '(finished #f 26))
  (arrivals "\"ab\"[1]{\"k\":2}12 true null" values-options))
(test-equal "each: a number at the end of the stream arrives at finish"
  (list '((3 . "ab") (fin . 7)) '(finished #f 6))
  (arrivals "\"ab\" 7" values-options))
(test-equal "each: a literal at the end of the stream has arrived before finish"
  (list '((3 . "ab") (8 . null)) '(finished #f 9))
  (arrivals "\"ab\" null" values-options))
(test-equal "each: a number then whitespace arrives with the whitespace"
  (list '((1 . 1)) '(finished #f 2))
  (arrivals "1 " values-options))
(test-equal "each: a string key and value do not arrive until the object closes"
  (list '((8 . (("k" . "v")))) '(finished #f 9))
  (arrivals "{\"k\":\"v\"}" values-options))
(test-equal "each: under lines, a lone number arrives at finish and a lone string at its quote"
  (list '((fin . 12)) '(finished #f 2))
  (arrivals "12" lines-options))
(test-equal "each: under lines, a lone string arrives at its closing quote"
  (list '((3 . "ab")) '(finished #f 4))
  (arrivals "\"ab\"" lines-options))

;; A stop ends the parse; any other answer is ignored.
(define (stop-run doc stop-at answer)
  (let* ((count 0) (log '())
         (b (make-json-builder values-options
                               (lambda (v)
                                 (set! count (+ count 1))
                                 (set! log (cons (norm v) log))
                                 (if (= count stop-at) (make-json-stop 'enough) answer)))))
    (let* ((f (result->list (json-builder-feed! b (bytes doc))))
           (fin (result->list (json-builder-finish! b)))
           (again (result->list (json-builder-feed! b (bytes " 9")))))
      (list f fin again (reverse log)))))

(for-each
 (lambda (row)
   (let ((label (car row)) (doc (cadr row)) (offset (caddr row)) (value (cadddr row)))
     (test-equal (string-append "each: a stop on the first value, " label ", ends the parse with its code")
       (list (list 'error 'enough offset) (list 'error 'enough offset) (list 'error 'enough offset)
             (list value))
       (stop-run doc 1 #f))))
 `(("null" "null " 4 null)
   ("true" "true " 4 #t)
   ("a number" "12 " 2 12)
   ("a string" "\"ab\" " 4 "ab")
   ("an array" "[1] " 3 #(1))
   ("an object" "{\"a\":1} " 7 (("a" . 1)))))
(test-equal "each: a stop on the second value: the first was handed on, the third never is"
  (list '(error enough 3) '(error enough 3) '(error enough 3) '(1 2))
  (stop-run "1 2 3" 2 #f))
(test-equal "each: a stop on a number at the end of the stream comes at finish"
  (list '(need-input #f 2) '(error enough 2) '(error enough 2) '(12))
  (stop-run "12" 1 #f))
(test-equal "each: a stop on the second of two arrays ends at its close"
  (list '(error enough 7) '(error enough 7) '(error enough 7) '(#(1) #(2)))
  (stop-run "[1] [2] [3]" 2 #f))


;; Any other answer is ignored.
(define (answer-run answer)
  (let* ((log '())
         (b (make-json-builder values-options
                               (lambda (v) (set! log (cons (norm v) log)) answer)))
         (f (result->list (json-builder-feed! b (bytes "1 [2] \"x\" null false"))))
         (fin (result->list (json-builder-finish! b))))
    (list f fin (reverse log))))

(for-each
 (lambda (answer)
   (test-equal (string-append "each: the answer " (describe answer) " is ignored")
     (list '(need-input #f 20) '(finished #f 20) '(1 #(2) "x" null #f))
     (answer-run answer)))
 (list #f #t 0 5 'enough 'stop "stop" '() (vector 'enough) (make-json-error 'enough 1)
       (make-json-result 'error 'enough 0) (make-json-handler) car))

;; json-builder-value raises for an EACH builder.
(define each-value-message "this builder hands each value to its procedure and keeps none")
(define (each-value-refusal)
  (refused 'json-builder-value each-value-message))

(let* ((b (make-json-builder values-options (lambda (v) #f)))
       (before (refusal (lambda () (json-builder-value b))))
       (mid (begin (json-builder-feed! b (bytes "[1")) (refusal (lambda () (json-builder-value b)))))
       (done (begin (json-builder-feed! b (bytes ",2]"))
                    (json-builder-finish! b)
                    (refusal (lambda () (json-builder-value b)))))
       (reset (begin (json-builder-reset! b) (refusal (lambda () (json-builder-value b))))))
  (test-equal "each: json-builder-value raises before any byte" (each-value-refusal) before)
  (test-equal "each: json-builder-value raises mid-value" (each-value-refusal) mid)
  (test-equal "each: json-builder-value raises after finished" (each-value-refusal) done)
  (test-equal "each: json-builder-value raises after a reset" (each-value-refusal) reset))
(let ((b (make-json-builder lines-options (lambda (v) #f))))
  (json-builder-feed! b (bytes "[1]"))
  (json-builder-finish! b)
  (test-equal "each: json-builder-value raises after finished, under lines"
    (each-value-refusal)
    (refusal (lambda () (json-builder-value b)))))
(let ((b (make-json-builder lines-options (lambda (v) #f))))
  (json-builder-feed! b (bytes "[1]x"))
  (test-equal "each: json-builder-value raises after an error"
    (each-value-refusal)
    (refusal (lambda () (json-builder-value b)))))
;; A builder with no EACH still gives its value.
(let ((b (make-json-builder lines-options)))
  (json-builder-feed! b (bytes "[1]"))
  (json-builder-finish! b)
  (test-equal "each: a builder with no EACH keeps its value"
    (vector 1)
    (json-builder-value b)))

;; The constructor.
(test-equal "builder: stream values with no EACH raises"
  (refused 'make-json-builder "stream values needs a procedure for each value")
  (refusal (lambda () (make-json-builder values-options))))
(test-equal "builder: stream values with no EACH raises, among other options"
  (refused 'make-json-builder "stream values needs a procedure for each value")
  (refusal (lambda () (make-json-builder (opts 'stream 'values 'null 'nil 'indent 2)))))
(test-equal "builder: no arguments still makes a builder"
  #t
  (json-builder? (make-json-builder)))
(for-each
 (lambda (each)
   (test-equal (string-append "builder: EACH " (describe each) " is not a procedure")
     (refused 'make-json-builder "not a procedure" each)
     (refusal (lambda () (make-json-builder values-options each))))
   (test-equal (string-append "builder: EACH " (describe each) " is not a procedure, under lines")
     (refused 'make-json-builder "not a procedure" each)
     (refusal (lambda () (make-json-builder lines-options each)))))
 (list #f #t 0 'car "car" '() (vector car) (make-json-handler)))
(for-each
 (lambda (o)
   (test-equal (string-append "builder: " (describe o) " is not an options record")
     (refused 'make-json-builder "not an options record" o)
     (refusal (lambda () (make-json-builder o car))))
   (test-equal (string-append "builder: " (describe o) " alone is not an options record")
     (refused 'make-json-builder "not an options record" o)
     (refusal (lambda () (make-json-builder o)))))
 (list #f 5 'lines "lines" '() car (make-json-handler) (make-json-error 'x 1)))

;; Under lines, one value is handed on, and a second is trailing-garbage.
(test-equal "each: lines hands on one value"
  (list '((need-input #f 3) (finished #f 3)) (list (vector 1)))
  (each-run (make-json-options) (list "[1]")))
(test-equal "each: lines hands on one value, with whitespace around it"
  (list '((need-input #f 6) (finished #f 6)) (list (vector 1)))
  (each-run (make-json-options) (list " [1]  ")))
(test-equal "each: lines hands on a lone number at finish"
  (list '((need-input #f 2) (finished #f 2)) (list 12))
  (each-run (make-json-options) (list "12")))
(let ((c (collector (make-json-options 'null 'nil))))
  (test-equal "each: lines, a second value is trailing-garbage and the first stays handed on"
    (list '(error trailing-garbage 4) '(error trailing-garbage 4) (list (vector 1)))
    (in-order (result->list (json-builder-feed! (car c) (bytes "[1] [2]")))
          (result->list (json-builder-finish! (car c)))
          ((cdr c)))))
(let ((c (collector (make-json-options))))
  (test-equal "each: lines, 1 2 hands on 1 and fails at 2"
    (list '(error trailing-garbage 2) '(1))
    (in-order (result->list (json-builder-feed! (car c) (bytes "1 2")))
          ((cdr c)))))
(let ((c (collector (make-json-options))))
  (test-equal "each: lines, nothing at all is unexpected-eof and hands nothing on"
    (list '(error unexpected-eof 0) '())
    (in-order (result->list (json-builder-finish! (car c)))
          ((cdr c)))))

;; An error drops the value being built, and a reset clears the mark.
(for-each
 (lambda (row)
   (let ((label (car row)) (options (cadr row)) (bad (caddr row)) (code+offset (cadddr row)))
     (let* ((c (collector options)) (b (car c))
            (r1 (result->list (json-builder-feed! b (bytes bad)))))
       (json-builder-reset! b)
       (let* ((r2 (result->list (json-builder-feed! b (bytes "2"))))
              (r3 (result->list (json-builder-finish! b))))
         (test-equal (string-append "each: after " label " fails, a reset and 2 hands on 2")
           (list code+offset '(need-input #f 1) '(finished #f 1) '(2))
           (list r1 r2 r3 ((cdr c))))))))
 (list (list "[1,]" values-options "[1,]" '(error unexpected-byte 3))
       (list "[1,]" lines-options "[1,]" '(error unexpected-byte 3))
       (list "[1," values-options "[1,x" '(error unexpected-byte 3))
       (list "{\"a\":[1," values-options "{\"a\":[1,}" '(error unexpected-byte 8))
       (list "{\"a\":" values-options "{\"a\":]" '(error unexpected-byte 5))
       (list "[[[" lines-options "[[[}" '(error unexpected-byte 3))))
(let* ((c (collector values-options)) (b (car c)))
  (json-builder-feed! b (bytes "[1,]"))
  (json-builder-reset! b)
  (test-equal "each: after an error and a reset, a container and a scalar both arrive"
    (list '(need-input #f 6) '(finished #f 6) (list (vector 3) 4))
    (in-order (result->list (json-builder-feed! b (bytes "[3] 4 ")))
          (result->list (json-builder-finish! b))
          ((cdr c)))))
(let* ((c (collector values-options)) (b (car c)))
  (json-builder-feed! b (bytes "{\"a\":[1,2,"))
  (json-builder-reset! b)
  (test-equal "each: a reset in the middle of a value, then a string"
    (list '(need-input #f 3) '(finished #f 3) '("x"))
    (in-order (result->list (json-builder-feed! b (bytes "\"x\"")))
          (result->list (json-builder-finish! b))
          ((cdr c)))))

;; An error after some values: they were handed on, the partial one never.
(test-equal "each: values before an error arrive, the partial value does not"
  (list '(error unexpected-byte 9) '(error unexpected-byte 9) (list 1 (vector 2)))
  (let* ((c (collector values-options)) (b (car c)))
    (in-order (result->list (json-builder-feed! b (bytes "1 [2] [3,x")))
          (result->list (json-builder-finish! b))
          ((cdr c)))))
(test-equal "each: a value cut off by the end of the stream is not handed on"
  (list '(error unexpected-eof 8) (list 1 "a"))
  (let* ((c (collector values-options)) (b (car c)))
    (json-builder-feed! b (bytes "1 \"a\" [2"))
    (in-order (result->list (json-builder-finish! b))
          ((cdr c)))))
(test-equal "each: a string cut off by the end of the stream is not handed on"
  (list '(error unexpected-eof 6) (list 1))
  (let* ((c (collector values-options)) (b (car c)))
    (json-builder-feed! b (bytes "1 \"abc"))
    (in-order (result->list (json-builder-finish! b))
          ((cdr c)))))
(test-equal "each: an error in the second value, byte by byte, hands on the first only"
  (list '(error unexpected-byte 7) (list (vector 1)))
  (let* ((c (collector values-options)) (b (car c)) (bv (bytes "[1] [2,]")) (last #f))
    (let loop ((k 0))
      (when (< k (bytevector-length bv))
        (let ((r (result->list (json-builder-feed! b bv k (+ k 1)))))
          (if (eq? (car r) 'error) (set! last r) (loop (+ k 1))))))
    (list last ((cdr c)))))

;; EACH raising: the raise passes out of the feed, and a reset repairs the builder.
(let* ((armed #t) (log '())
       (b (make-json-builder values-options
                             (lambda (v)
                               (set! log (cons v log))
                               (when (and armed (eqv? v 2)) (raise 'boom))
                               #f)))
       (raised (guard (e ((symbol? e) (list 'raised e)))
                 (json-builder-feed! b (bytes "1 2 3"))))
       (after-raise (violation-who (lambda () (json-builder-feed! b (bytes "4")))))
       (finish-after (violation-who (lambda () (json-builder-finish! b)))))
  (test-equal "each: the raise passes out of the feed" '(raised boom) raised)
  (test-equal "each: values before the raise were handed on, and the raising one" '(1 2) (reverse log))
  (test-equal "each: a builder whose EACH raised refuses another feed until reset"
    '(violation json-parser-feed!) after-raise)
  (test-equal "each: a builder whose EACH raised refuses finish until reset"
    '(violation json-parser-finish!) finish-after)
  (set! armed #f)
  (json-builder-reset! b)
  (test-equal "each: after a reset the builder works again"
    (list '(need-input #f 8) '(finished #f 8) '(1 2 7 #(8) 9))
    (in-order (result->list (json-builder-feed! b (bytes "7 [8] 9 ")))
          (result->list (json-builder-finish! b))
          (reverse log)))
  ;; the log kept only what arrived after the reset, 7 8 9, after 1 2
  #t)
(let* ((armed #t) (log '())
       (b (make-json-builder values-options
                             (lambda (v)
                               (set! log (cons v log))
                               (when (and armed (vector? v)) (raise 'boom))
                               #f)))
       (raised (guard (e ((symbol? e) (list 'raised e)))
                 (json-builder-feed! b (bytes "[1,[2]] 5")))))
  (set! armed #f)
  (json-builder-reset! b)
  (test-equal "each: EACH raising on a container, then a reset: the next values arrive whole"
    (list '(raised boom) (list (vector 1 (vector 2))) '(need-input #f 9) '(finished #f 9)
          (list (vector 1 (vector 2)) 6 (vector 7 (vector 8))))
    (in-order raised (reverse log)
          (result->list (json-builder-feed! b (bytes "6 [7,[8]]")))
          (result->list (json-builder-finish! b))
          (reverse log))))

;; Two EACH builders fed alternately.
(let* ((ca (collector values-options)) (cb (collector (make-json-options 'stream 'values 'null 'nil)))
       (a (car ca)) (b (car cb))
       (feed! (lambda (x s) (json-builder-feed! x (bytes s)))))
  (feed! a "1 [2,")
  (feed! b "3 [4,null,")
  (feed! a " 5]")
  (feed! b " 6] null")
  (feed! a " 8")
  (feed! b " 7")
  (let ((ra (result->list (json-builder-finish! a)))
        (rb (result->list (json-builder-finish! b))))
    (test-equal "each: two builders fed alternately keep their values apart"
      (list '(finished #f 10) '(finished #f 20)
            (list 1 (vector 2 5) 8)
            (list 3 (vector 4 'nil 6) 'nil 7))
      (list ra rb ((cdr ca)) ((cdr cb))))))

;; The stack across values.
(define (array-text n offset)
  (string-append "[" (join (map (lambda (i) (number->string (+ i offset))) (iota-list n)) ",") "]"))
(define (array-value n offset)
  (list->vector (map (lambda (i) (+ i offset)) (iota-list n))))
(define wide-sizes '(63 64 65 127 128 129 300))

(test-equal "each: arrays of 63 to 300 elements, one after another with nothing between"
  (map (lambda (n) (array-value n n)) wide-sizes)
  (each-values values-options (list (apply string-append (map (lambda (n) (array-text n n)) wide-sizes)))))
(test-equal "each: arrays of 300 to 63 elements, one after another with nothing between"
  (map (lambda (n) (array-value n n)) (reverse wide-sizes))
  (each-values values-options (list (apply string-append (map (lambda (n) (array-text n n)) (reverse wide-sizes))))))
(test-equal "each: arrays of 63 to 300 elements, separated by whitespace, fed in 7-byte pieces"
  (map (lambda (n) (array-value n 1000)) wide-sizes)
  (let* ((text (join (map (lambda (n) (array-text n 1000)) wide-sizes) "\n"))
         (bv (bytes text)) (len (bytevector-length bv))
         (c (collector values-options)))
    (let loop ((at 0))
      (when (< at len)
        (json-builder-feed! (car c) bv at (min len (+ at 7)))
        (loop (+ at 7))))
    (json-builder-finish! (car c))
    ((cdr c))))
(test-equal "each: arrays of 63 to 300 elements, with a scalar between, fed whole"
  (apply append (map (lambda (n) (list (array-value n 5) 'null)) wide-sizes))
  (each-values values-options
               (list (apply string-append
                            (map (lambda (n) (string-append (array-text n 5) " null ")) wide-sizes)))))
(test-equal "each: objects with 63 to 300 members, one after another"
  (map (lambda (n) (map (lambda (i) (cons (number->string i) i)) (iota-list n))) wide-sizes)
  (each-values values-options
               (list (apply string-append
                            (map (lambda (n)
                                   (string-append
                                    "{" (join (map (lambda (i) (string-append "\"" (number->string i) "\":" (number->string i)))
                                                   (iota-list n)) ",")
                                    "}"))
                                 wide-sizes)))))
(test-equal "each: arrays of 100 elements, each holding an array of 100, one after another"
  (list (list->vector (map (lambda (i) (array-value 100 i)) (iota-list 100)))
        (list->vector (map (lambda (i) (array-value 100 (+ i 1))) (iota-list 100))))
  (let ((one (lambda (k)
               (string-append "[" (join (map (lambda (i) (array-text 100 (+ i k))) (iota-list 100)) ",") "]"))))
    (each-values values-options (list (string-append (one 0) (one 1))))))

(define (open-run n) (apply string-append (map (lambda (i) "[") (iota-list n))))
(define (close-run n) (apply string-append (map (lambda (i) "]") (iota-list n))))
(for-each
 (lambda (depth)
   (let ((doc (string-append (open-run depth) (close-run depth))))
     (test-equal (string-append "each: two values nested " (number->string depth)
                                " deep, the depth limit, one after another")
       (list (nest depth) (nest depth))
       (each-values (opts 'stream 'values 'depth-limit depth) (list (string-append doc doc))))
     (test-equal (string-append "each: three values nested " (number->string depth)
                                " deep, fed in 5-byte pieces, with a scalar between")
       (list (nest depth) 1 (nest depth) 1 (nest depth))
       (let* ((text (string-append doc " 1 " doc " 1 " doc))
              (bv (bytes text)) (len (bytevector-length bv))
              (c (collector (opts 'stream 'values 'depth-limit depth))))
         (let loop ((at 0))
           (when (< at len)
             (json-builder-feed! (car c) bv at (min len (+ at 5)))
             (loop (+ at 5))))
         (json-builder-finish! (car c))
         ((cdr c))))
     (test-equal (string-append "each: a value one deeper than the limit " (number->string depth)
                                " fails, after one that fits")
       (list (list 'error 'nesting-too-deep (+ (string-length doc) 1 (+ depth 1))) (list (nest depth)))
       (let ((c (collector (opts 'stream 'values 'depth-limit depth))))
         (in-order (result->list (json-builder-feed! (car c)
                                                 (bytes (string-append doc " " (open-run (+ depth 1)) (close-run (+ depth 1))))))
               ((cdr c)))))))
 '(63 64 65 100 129 300))
(test-equal "each: objects nested 70 deep, one after another"
  (list (nest-object 70) (nest-object 70))
  (let* ((doc (string-append (apply string-append (map (lambda (i) "{\"a\":") (iota-list 69))) "{}"
                             (apply string-append (map (lambda (i) "}") (iota-list 69)))))
         (c (collector (opts 'stream 'values 'depth-limit 70))))
    (json-builder-feed! (car c) (bytes (string-append doc doc)))
    (json-builder-finish! (car c))
    ((cdr c))))

;; --- 5. &json-record-error ----------------------------------------------------------------

(define rec-error (make-json-record-error 'unexpected-byte 12 3))

(test-equal "record-error: reason, offset and record read back"
  '(unexpected-byte 12 3)
  (list (json-error-reason rec-error) (json-error-offset rec-error) (json-error-record rec-error)))
(test-equal "record-error: reason, offset and record read back, other values"
  '(blank-line 0 1)
  (let ((e (make-json-record-error 'blank-line 0 1)))
    (list (json-error-reason e) (json-error-offset e) (json-error-record e))))
(test-equal "record-error: json-error? and json-record-error? hold, and so do the condition predicates"
  '(#t #t #t #t #f)
  (list (json-error? rec-error) (json-record-error? rec-error) (error? rec-error)
        (condition? rec-error) (violation? rec-error)))
(test-equal "record-error: a plain json-error is not a record error"
  '(#t #f #t)
  (let ((e (make-json-error 'unexpected-byte 12)))
    (list (json-error? e) (json-record-error? e) (error? e))))
(test-equal "record-error: json-record-error? is #f for other things"
  '(#f #f #f #f)
  (list (json-record-error? 5) (json-record-error? (make-error))
        (json-record-error? (make-message-condition "m")) (json-record-error? 'unexpected-byte)))
(test-equal "record-error: the condition type works in a predicate and an accessor"
  '(#t #f 3 unexpected-byte 12)
  (list ((condition-predicate (record-type-descriptor &json-record-error)) rec-error)
        ((condition-predicate (record-type-descriptor &json-record-error)) (make-json-error 'x 1))
        ((condition-accessor (record-type-descriptor &json-record-error) json-error-record) rec-error)
        ((condition-accessor (record-type-descriptor &json-error) json-error-reason) rec-error)
        ((condition-accessor (record-type-descriptor &json-error) json-error-offset) rec-error)))
(test-equal "record-error: the parent type's predicate holds"
  '(#t #t)
  (list ((condition-predicate (record-type-descriptor &json-error)) rec-error) ((condition-predicate (record-type-descriptor &error)) rec-error)))
(test-equal "record-error: in a compound condition, with a who and a message"
  (list 'unexpected-byte 12 3 'read-json-sequence "bad" #t)
  (let ((c (condition rec-error (make-who-condition 'read-json-sequence)
                      (make-message-condition "bad"))))
    (list (json-error-reason c) (json-error-offset c) (json-error-record c)
          (condition-who c) (condition-message c) (json-record-error? c))))
(test-equal "record-error: raised, a json-error guard catches it whole"
  '(caught unexpected-byte 12 3)
  (guard (e ((json-error? e)
             (list 'caught (json-error-reason e) (json-error-offset e) (json-error-record e))))
    (raise rec-error)))
(test-equal "record-error: raised, an error guard catches it"
  'caught
  (guard (e ((error? e) 'caught)) (raise rec-error)))
(test-equal "record-error: raised, a record-error guard catches it before a json-error guard"
  'record
  (guard (e ((json-record-error? e) 'record) ((json-error? e) 'plain))
    (raise rec-error)))
(test-equal "record-error: raised plain, a record-error guard does not catch it"
  'plain
  (guard (e ((json-error? e) 'plain))
    (guard (e2 ((json-record-error? e2) 'record))
      (raise (make-json-error 'x 1)))))
(test-equal "record-error: raise-continuable passes the condition on"
  3
  (with-exception-handler
   (lambda (e) (json-error-record e))
   (lambda () (raise-continuable rec-error))))
(test-equal "record-error: json-error-record on a plain json-error raises a violation"
  '(raised #t)
  (guard (e ((violation? e) (list 'raised #t)))
    (json-error-record (make-json-error 'x 1))
    'no-raise))
(test-equal "record-error: json-error-record on a non-condition raises a violation"
  '(raised #t)
  (guard (e ((violation? e) (list 'raised #t)))
    (json-error-record 5)
    'no-raise))
(test-equal "record-error: json-error-reason of a record error is the reason, not the record"
  'blank-line
  (json-error-reason (make-json-record-error 'blank-line 7 9)))

(test-end "stream-api")

(display "elapsed ms: ")
(display (- (real-time) started))
(newline)
(display "pass ")
(display (test-runner-pass-count runner))
(display " fail ")
(display (test-runner-fail-count runner))
(newline)

(exit (suite-exit-status runner))
