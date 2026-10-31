;;; tests/test-parser-api.sps: (jsonparse options) and (jsonparse parser) held
;;; to their header comments (ADR-0010).
;;;
;;; One fixed document fires all fourteen procedures, with an escape and a
;;; surrogate pair in both a key and a string. Its events, and the offset
;;; each runs at, are written out by hand below (see `doc` and `full-trace`);
;;; no expected value comes from recording-handler or from the parser itself.
(import (except (rnrs) current-output-port)
        (only (byte-machine runtime) callback-pause make-callback-failure)
        (only (jsonparse-grammar) default-depth-limit)
        (srfi :64)
        (jsonparse-testing)
        (jsonparse options)
        (jsonparse parser))

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

;; --- helpers -----------------------------------------------------------------

(define (bytes s) (string->utf8 s))

(define (sub bv from to)
  (let ((out (make-bytevector (- to from))))
    (bytevector-copy! bv from out 0 (- to from))
    out))

;; raised : (-> Any) -> (U 'no-raise (List 'raised Any))
(define (raised thunk)
  (guard (e (#t (list 'raised e)))
    (thunk)
    'no-raise))

;; refusal : (-> Any) -> (U 'no-raise (List Boolean Any Any Any))
;; What an assertion violation carried: is it one, its who, message, irritants.
(define (refusal thunk)
  (guard (e (#t (list (assertion-violation? e)
                      (and (who-condition? e) (condition-who e))
                      (and (message-condition? e) (condition-message e))
                      (and (irritants-condition? e) (condition-irritants e)))))
    (thunk)
    'no-raise))

;; in-order : evaluates its expressions left to right into a list. Chez
;; evaluates a call's arguments right to left in compiled code, and feeds
;; are sequenced.
(define-syntax in-order
  (syntax-rules ()
    ((_) '())
    ((_ e rest ...) (let ((v e)) (cons v (in-order rest ...))))))

(define (refused who message . irritants) (list #t who message irritants))

(define (result->list r)
  (list (json-result-status r) (json-result-code r) (json-result-offset r)))

;; The procedures, in the handler's order, and the shape of each.
(define names
  '(null boolean number-chars number-end string-start chars escape string-end
    object-start key-start key-end object-end array-start array-end))

(define (kind-of name)
  (case name
    ((boolean) 'bool)
    ((number-chars chars) 'text)
    ((escape) 'scalar)
    (else 'plain)))

;; A fixture's context is (vector parser log), the log newest first.
(define (note! c . entry)
  (vector-set! c 1 (cons (cons* (car entry)
                                (json-parser-offset (vector-ref c 0))
                                (cdr entry))
                         (vector-ref c 1))))

;; recorder : Symbol (-> Any) [Procedure] -> Procedure
;; The procedure for NAME: it notes its call with NOTE and returns what
;; (RET) answers.
(define (recorder name ret note)
  (case (kind-of name)
    ((plain) (lambda (c) (note c name) (ret)))
    ((bool) (lambda (c b) (note c name b) (ret)))
    ((text) (lambda (c bv s e)
              (note c name (bytevector->u8-list (sub bv s e)))
              (ret)))
    (else (lambda (c u) (note c name u) (ret)))))

;; handler-of : (Listof Symbol) (Symbol -> (-> Any)) [Procedure] -> json-handler
(define (handler-of which ret-of . note)
  (apply make-json-handler
         (apply append
                (map (lambda (n)
                       (list n (recorder n (ret-of n) (if (null? note) note! (car note)))))
                     which))))

(define (returning v) (lambda (n) (lambda () v)))

(define all-handler (handler-of names (returning 'ok)))

;; fixture : json-handler [json-options] -> (values json-parser context)
(define (fixture handler . options)
  (let* ((c (vector #f '()))
         (p (if (null? options)
                (make-json-parser handler c)
                (make-json-parser handler c (car options)))))
    (vector-set! c 0 p)
    (values p c)))

(define (log-of c) (reverse (vector-ref c 1)))

;; run-whole : json-handler bytevector [json-options] -> (List log feed finish)
(define (run-whole handler bv . options)
  (let-values (((p c) (apply fixture handler options)))
    (let* ((f (result->list (json-parser-feed! p bv)))
           (e (result->list (json-parser-finish! p))))
      (list (log-of c) f e))))

;; --- the fixed document -----------------------------------------------------------
;;
;;   {"k\n\uD83D\uDE00":["s\t\uD83D\uDE00",null,true,false,12]}
;;
;; 58 bytes. Offsets are the stream offset when the procedure runs: just
;; past the byte that completes the event, except that a number is
;; complete only at the byte after it, and a text part is delivered when the
;; byte that ends it (an escape's backslash, a closing quote) is next.
(define doc
  (bytes "{\"k\\n\\uD83D\\uDE00\":[\"s\\t\\uD83D\\uDE00\",null,true,false,12]}"))

(define full-trace
  '((object-start 1) (key-start 2) (chars 3 (107))
    (escape 5 10) (escape 17 128512) (key-end 18)
    (array-start 20) (string-start 21) (chars 22 (115))
    (escape 24 9) (escape 36 128512) (string-end 37)
    (null 42) (boolean 47 #t) (boolean 53 #f)
    (number-chars 56 (49 50)) (number-end 56)
    (array-end 57) (object-end 58)))

;; through-first : Symbol -> Trace, full-trace up to and including NAME's first entry
(define (through-first name)
  (let loop ((xs full-trace) (acc '()))
    (if (eq? (caar xs) name)
        (reverse (cons (car xs) acc))
        (loop (cdr xs) (cons (car xs) acc)))))

(test-begin "parser-api")

;; --- 1. make-json-options ------------------------------------------------------------

(test-equal "options: the default depth limit is 512" 512 (json-options-depth-limit (make-json-options)))
(test-equal "options: the default is the grammar's" default-depth-limit
  (json-options-depth-limit (make-json-options)))
(test-equal "options: 512 is the grammar's default" 512 default-depth-limit)
(test-equal "options: 0 reads back" 0 (json-options-depth-limit (make-json-options 'depth-limit 0)))
(test-equal "options: 65535 reads back" 65535
  (json-options-depth-limit (make-json-options 'depth-limit 65535)))
(test-equal "options: 7 reads back" 7 (json-options-depth-limit (make-json-options 'depth-limit 7)))

(define depth-message "depth-limit is not an exact integer from 0 to 65535")

(for-each
 (lambda (v)
   (test-equal (string-append "options: depth-limit " (describe v) " is refused")
     (refused 'make-json-options depth-message v)
     (refusal (lambda () (make-json-options 'depth-limit v)))))
 (list 65536 -1 1.5 512.0 'x "5" #f))

(test-equal "options: an unknown name"
  (refused 'make-json-options "unknown option" 'depth-limt)
  (refusal (lambda () (make-json-options 'depth-limt 5))))
(test-equal "options: a non-symbol name"
  (refused 'make-json-options "unknown option" 5)
  (refusal (lambda () (make-json-options 5 1))))
(test-equal "options: a name twice"
  (refused 'make-json-options "an option is given twice" 'depth-limit)
  (refusal (lambda () (make-json-options 'depth-limit 1 'depth-limit 2))))
(test-equal "options: a dangling name"
  (refused 'make-json-options "an option has no value" 'depth-limit)
  (refusal (lambda () (make-json-options 'depth-limit))))
(test-equal "options: a dangling name after a good pair"
  (refused 'make-json-options "an option has no value" 'depth-limit)
  (refusal (lambda () (make-json-options 'depth-limit 3 'depth-limit))))
(test-equal "options: a lone unknown name has no value"
  (refused 'make-json-options "an option has no value" 'nope)
  (refusal (lambda () (make-json-options 'nope))))

;; --- 2. make-json-handler wiring -----------------------------------------------------

;; Hand-written: each name's calls on `doc` when it alone is bound, each as
;; (name offset arg ...).
(define wiring
  '((null (null 42))
    (boolean (boolean 47 #t) (boolean 53 #f))
    (number-chars (number-chars 56 (49 50)))
    (number-end (number-end 56))
    (string-start (string-start 21))
    (chars (chars 3 (107)) (chars 22 (115)))
    (escape (escape 5 10) (escape 17 128512) (escape 24 9) (escape 36 128512))
    (string-end (string-end 37))
    (object-start (object-start 1))
    (key-start (key-start 2))
    (key-end (key-end 18))
    (object-end (object-end 58))
    (array-start (array-start 20))
    (array-end (array-end 57))))

(for-each
 (lambda (row)
   (test-equal (string-append "wiring: only " (symbol->string (car row)) " bound")
     (list (cdr row) '(need-input #f 58) '(finished #f 58))
     (run-whole (handler-of (list (car row)) (returning 'ok)) doc)))
 wiring)

(test-equal "wiring: the table covers the fourteen names" names (map car wiring))

(test-equal "wiring: all fourteen bound see the whole trace"
  (list full-trace '(need-input #f 58) '(finished #f 58))
  (run-whole all-handler doc))

(test-equal "wiring: a handler binding nothing parses the document"
  (list '() '(need-input #f 58) '(finished #f 58))
  (run-whole (make-json-handler) doc))

(let ((f (lambda (c) 1)))
  (test-equal "handler: an unknown name"
    (refused 'make-json-handler "unknown name" 'nul)
    (refusal (lambda () (make-json-handler 'nul f))))
  (test-equal "handler: a non-symbol name"
    (refused 'make-json-handler "unknown name" 5)
    (refusal (lambda () (make-json-handler 5 f))))
  (test-equal "handler: a name twice"
    (refused 'make-json-handler "a name is given twice" 'null)
    (refusal (lambda () (make-json-handler 'null f 'null f))))
  (test-equal "handler: a name with no procedure"
    (refused 'make-json-handler "a name has no procedure" 'null)
    (refusal (lambda () (make-json-handler 'null))))
  (test-equal "handler: a name with no procedure after a good pair"
    (refused 'make-json-handler "a name has no procedure" 'array-end)
    (refusal (lambda () (make-json-handler 'null f 'array-end))))
  (test-equal "handler: a value that is not a procedure"
    (refused 'make-json-handler "not a procedure" 'null 5)
    (refusal (lambda () (make-json-handler 'null 5))))
  (test-equal "handler: #f is not a procedure either"
    (refused 'make-json-handler "not a procedure" 'null #f)
    (refusal (lambda () (make-json-handler 'null #f)))))

;; --- 3. return values are ignored unless they are a stop -----------------------------------

(let ((baseline (run-whole (handler-of names (returning (if #f #f))) doc)))
  (test-equal "returns: ordinary returns give the whole trace"
    (list full-trace '(need-input #f 58) '(finished #f 58))
    baseline)
  (for-each
   (lambda (v)
     (test-equal (string-append "returns: " (describe v) " changes nothing")
       baseline
       (run-whole (handler-of names (returning v)) doc)))
   (list #f 0 '() 'a-symbol callback-pause (make-callback-failure 'x #f))))

;; --- 4. make-json-stop -------------------------------------------------------------------

(for-each
 (lambda (code)
   (test-equal (string-append "stop: the code " (describe code) " is accepted and carried")
     (list (list 'error code 5) (list 'error code 5))
     (let ((h (make-json-handler 'null (lambda (c) (make-json-stop code)))))
       (let-values (((p c) (fixture h)))
         (in-order (result->list (json-parser-feed! p (bytes "[null]")))
                   (result->list (json-parser-finish! p)))))))
 '(a a1 a-b z-9-))

(for-each
 (lambda (code)
   (test-equal (string-append "stop: the code " (describe code) " is refused")
     (refused 'make-json-stop "the code is not a symbol spelt [a-z][a-z0-9-]*" code)
     (refusal (lambda () (make-json-stop code)))))
 (list "a" 'A (string->symbol "a b") (string->symbol "1a") (string->symbol "-a")
       (string->symbol "a_b") (string->symbol "") 5))

(let* ((p #f)
       (escaped
        (call/cc
         (lambda (k)
           (set! p (make-json-parser (make-json-handler 'null (lambda (c) (k 'escaped)))))
           (json-parser-feed! p (bytes "[null]"))))))
  (test-equal "escape: the escape passes out of the feed"
    'escaped escaped)
  (test-equal "escape: the next feed and finish are refused"
    (list (refused 'json-parser-feed! "a handler procedure raised or escaped: reset the parser before using it again")
          (refused 'json-parser-finish! "a handler procedure raised or escaped: reset the parser before using it again"))
    (let* ((a (refusal (lambda () (json-parser-feed! p (bytes "[null]")))))
           (b (refusal (lambda () (json-parser-finish! p)))))
      (list a b)))
  (json-parser-reset! p)
  (test-equal "escape: a reset recovers the parser"
    (list '(need-input #f 3) '(finished #f 3))
    (let* ((f (result->list (json-parser-feed! p (bytes "[1]"))))
           (e (result->list (json-parser-finish! p))))
      (list f e))))

;; --- 4b. json-stop? ---------------------------------------------------------------------

(test-equal "json-stop?: #t on a stop, #f on other values"
  '(#t #f #f #f #f #f)
  (list (json-stop? (make-json-stop 'halt)) (json-stop? #f) (json-stop? 'halt)
        (json-stop? callback-pause) (json-stop? (make-callback-failure 'halt #f))
        (json-stop? (vector))))

;; A wrapper that returns the inner procedure's stop, and only a stop.
(let* ((inner (lambda (c) (make-json-stop 'inner-code)))
       (wrap (lambda (c)
               (let ((r (inner c)))
                 (if (json-stop? r) r 'not-a-stop)))))
  (test-equal "json-stop?: a wrapper returning the inner stop stops the parse with its code"
    (list '(error inner-code 5) '(error inner-code 5))
    (let-values (((p c) (fixture (make-json-handler 'null wrap))))
      (let* ((f (result->list (json-parser-feed! p (bytes "[null]"))))
             (e (result->list (json-parser-finish! p))))
        (list f e)))))

;; Where each procedure's first call runs, by hand (the offsets in full-trace).
(define stop-offsets
  '((null . 42) (boolean . 47) (number-chars . 56) (number-end . 56)
    (string-start . 21) (chars . 3) (escape . 5) (string-end . 37)
    (object-start . 1) (key-start . 2) (key-end . 18) (object-end . 58)
    (array-start . 20) (array-end . 57)))

(test-equal "stop: the table covers the fourteen names" names (map car stop-offsets))

;; A handler of all fourteen whose NAME procedure returns a stop once.
(define (stopping-handler name)
  (let ((armed #t))
    (handler-of names
                (lambda (n)
                  (if (eq? n name)
                      (lambda ()
                        (if armed
                            (begin (set! armed #f) (make-json-stop 'halt))
                            'ok))
                      (lambda () 'ok))))))

(for-each
 (lambda (row)
   (let ((name (car row)) (offset (cdr row)))
     (let-values (((p c) (fixture (stopping-handler name))))
       (let* ((f (result->list (json-parser-feed! p doc)))
              (log1 (log-of c))
              (again (result->list (json-parser-feed! p (bytes "]"))))
              (fin (result->list (json-parser-finish! p)))
              (fin2 (result->list (json-parser-finish! p)))
              (log2 (log-of c)))
         (test-equal (string-append "stop from " (symbol->string name) ": the error and the calls made")
           (list (list 'error 'halt offset) (through-first name))
           (list f log1))
         (test-equal (string-append "stop from " (symbol->string name) ": feeding and finishing repeat it")
           (list (list 'error 'halt offset) (list 'error 'halt offset) (list 'error 'halt offset)
                 log1)
           (list again fin fin2 log2))
         (json-parser-reset! p)
         (test-equal (string-append "stop from " (symbol->string name) ": after a reset the handler and context are kept")
           (list (append (through-first name) full-trace) '(need-input #f 58) '(finished #f 58))
           (let* ((f2 (result->list (json-parser-feed! p doc)))
                  (e2 (result->list (json-parser-finish! p))))
             (list (log-of c) f2 e2)))))))
 stop-offsets)

;; --- 5. results ----------------------------------------------------------------------------

(let-values (((p c) (fixture (make-json-handler))))
  (let* ((a (result->list (json-parser-feed! p (bytes "[1,"))))
         (b (result->list (json-parser-feed! p (bytes "2,"))))
         (d (result->list (json-parser-feed! p (bytes "3]"))))
         (f (result->list (json-parser-finish! p)))
         (g (result->list (json-parser-feed! p (bytes "zz"))))
         (h (result->list (json-parser-finish! p))))
    (test-equal "results: need-input offsets accumulate, finished is the total length, and both stick"
      '((need-input #f 3) (need-input #f 5) (need-input #f 7)
        (finished #f 7) (finished #f 7) (finished #f 7))
      (list a b d f g h))))

(test-equal "results: finishing a number at the end of input"
  (list '(need-input #f 2) '(finished #f 2))
  (let-values (((p c) (fixture (make-json-handler))))
    (in-order (result->list (json-parser-feed! p (bytes "12")))
              (result->list (json-parser-finish! p)))))

(test-equal "results: an empty feed is need-input at the offset so far"
  (list '(need-input #f 0) '(need-input #f 1) '(need-input #f 1))
  (let-values (((p c) (fixture (make-json-handler))))
    (in-order (result->list (json-parser-feed! p (bytes "")))
              (result->list (json-parser-feed! p (bytes "[")))
              (result->list (json-parser-feed! p (bytes ""))))))

(test-equal "results: finish on no input is unexpected-eof at 0"
  '(error unexpected-eof 0)
  (let-values (((p c) (fixture (make-json-handler))))
    (result->list (json-parser-finish! p))))

;; (label bytes depth-limit feed-result finish-result)
(define error-cases
  `(("unexpected-byte" ,(bytes "[}") #f (error unexpected-byte 1) (error unexpected-byte 1))
    ("unexpected-byte after a comma" ,(bytes "[1,}") #f (error unexpected-byte 3) (error unexpected-byte 3))
    ("unexpected-eof" ,(bytes "[1,") #f (need-input #f 3) (error unexpected-eof 3))
    ("unexpected-eof in a literal" ,(bytes "tru") #f (need-input #f 3) (error unexpected-eof 3))
    ("invalid-number" ,(bytes "[01]") #f (error invalid-number 2) (error invalid-number 2))
    ("invalid-number, a bare minus" ,(bytes "[-]") #f (error invalid-number 2) (error invalid-number 2))
    ("invalid-escape" ,(bytes "\"a\\q\"") #f (error invalid-escape 3) (error invalid-escape 3))
    ("invalid-surrogate, a lone low half" ,(bytes "\"\\uDE00\"") #f
     (error invalid-surrogate 7) (error invalid-surrogate 7))
    ("invalid-surrogate, a high half then a byte" ,(bytes "\"\\uD83Dx\"") #f
     (error invalid-surrogate 7) (error invalid-surrogate 7))
    ("invalid-surrogate, a high half then a non-surrogate escape" ,(bytes "\"\\uD83D\\u0041\"") #f
     (error invalid-surrogate 13) (error invalid-surrogate 13))
    ("invalid-utf8" ,(u8-list->bytevector '(34 97 255 34)) #f
     (error invalid-utf8 2) (error invalid-utf8 2))
    ("control-character" ,(u8-list->bytevector '(34 97 10 34)) #f
     (error control-character 2) (error control-character 2))
    ("nesting-too-deep" ,(bytes "[[[") 2 (error nesting-too-deep 3) (error nesting-too-deep 3))
    ("nesting-too-deep at limit 0" ,(bytes "[") 0 (error nesting-too-deep 1) (error nesting-too-deep 1))
    ("trailing-garbage" ,(bytes "[]x") #f (error trailing-garbage 2) (error trailing-garbage 2))
    ("trailing-garbage after a scalar" ,(bytes "1 2") #f (error trailing-garbage 2) (error trailing-garbage 2))))

(for-each
 (lambda (row)
   (let-values (((label bv limit feed-expected finish-expected)
                 (apply values row)))
     (test-equal (string-append "error: " label)
       (list '() feed-expected finish-expected)
       (if limit
           (run-whole (make-json-handler) bv (make-json-options 'depth-limit limit))
           (run-whole (make-json-handler) bv)))))
 error-cases)

(test-equal "error: the nine grammar codes are all covered"
  '(control-character invalid-escape invalid-number invalid-surrogate invalid-utf8
    nesting-too-deep trailing-garbage unexpected-byte unexpected-eof)
  (let loop ((rows error-cases) (acc '()))
    (if (null? rows)
        (list-sort (lambda (a b) (string<? (symbol->string a) (symbol->string b))) acc)
        (let ((code (cadr (list-ref (car rows) 4))))
          (loop (cdr rows) (if (memq code acc) acc (cons code acc)))))))

;; --- 6. json-parser-feed! ---------------------------------------------------------------------

(test-equal "feed: the two-argument form gives the hand-pinned trace"
  (list '(need-input #f 58) full-trace)
  (let-values (((p c) (fixture all-handler)))
    (in-order (result->list (json-parser-feed! p doc)) (log-of c))))

(test-equal "feed: the four-argument whole range gives the hand-pinned trace"
  (list '(need-input #f 58) full-trace)
  (let-values (((p c) (fixture all-handler)))
    (in-order (result->list (json-parser-feed! p doc 0 (bytevector-length doc))) (log-of c))))

(test-equal "feed: a range in the middle parses only that range"
  (list '((array-start 1) (number-chars 2 (49)) (number-end 2) (number-chars 4 (50)) (number-end 4) (array-end 5)) '(need-input #f 5) '(finished #f 5))
  (let ((bv (u8-list->bytevector '(255 255 91 49 44 50 93 255 255))))
    (let-values (((p c) (fixture all-handler)))
      (let* ((f (result->list (json-parser-feed! p bv 2 7)))
             (e (result->list (json-parser-finish! p))))
        (list (log-of c) f e)))))

(test-equal "feed: an empty range at the end is need-input at 0"
  '(need-input #f 0)
  (let-values (((p c) (fixture all-handler)))
    (result->list (json-parser-feed! p doc 58 58))))

(let ((bv (bytes "[1,2]")))
  (define (feed-refusal make-thunk)
    (let-values (((p c) (fixture all-handler)))
      (json-parser-feed! p (bytes "[1,"))
      (let* ((r (refusal (make-thunk p)))
             (offset (json-parser-offset p))
             (log1 (log-of c))
             (next (result->list (json-parser-feed! p (bytes "2]"))))
             (fin (result->list (json-parser-finish! p))))
        (list r offset log1 next fin (length (log-of c))))))
  (define log-after-first-feed '((array-start 1) (number-chars 2 (49)) (number-end 2)))
  (define (refused-feed . irritants)
    (list (apply refused 'json-parser-feed! "the range is not within the bytevector" irritants)
          3 log-after-first-feed '(need-input #f 5) '(finished #f 5) 6))
  (define (refused-other message irritant)
    (list (refused 'json-parser-feed! message irritant)
          3 log-after-first-feed '(need-input #f 5) '(finished #f 5) 6))
  (test-equal "feed: start after end"
    (refused-feed 3 2 5)
    (feed-refusal (lambda (p) (lambda () (json-parser-feed! p bv 3 2)))))
  (test-equal "feed: end past the length"
    (refused-feed 0 6 5)
    (feed-refusal (lambda (p) (lambda () (json-parser-feed! p bv 0 6)))))
  (test-equal "feed: start below 0"
    (refused-feed -1 3 5)
    (feed-refusal (lambda (p) (lambda () (json-parser-feed! p bv -1 3)))))
  (test-equal "feed: a flonum start"
    (refused-feed 1.0 3 5)
    (feed-refusal (lambda (p) (lambda () (json-parser-feed! p bv 1.0 3)))))
  (test-equal "feed: a non-number end"
    (refused-feed 0 "3" 5)
    (feed-refusal (lambda (p) (lambda () (json-parser-feed! p bv 0 "3")))))
  (test-equal "feed: a bignum end"
    (refused-feed 0 (expt 2 70) 5)
    (feed-refusal (lambda (p) (lambda () (json-parser-feed! p bv 0 (expt 2 70))))))
  (test-equal "feed: a non-bytevector, four arguments"
    (refused-other "not a bytevector" "[1]")
    (feed-refusal (lambda (p) (lambda () (json-parser-feed! p "[1]" 0 3)))))
  (test-equal "feed: a non-bytevector, two arguments"
    (refused-other "not a bytevector" '(91))
    (feed-refusal (lambda (p) (lambda () (json-parser-feed! p '(91))))))
  (test-equal "feed: a non-parser, four arguments"
    (list (refused 'json-parser-feed! "not a parser" 'p) 3 'no-raise)
    (list (refusal (lambda () (json-parser-feed! 'p bv 0 5))) 3 'no-raise))
  (test-equal "feed: a non-parser and a non-bytevector, two arguments"
    (refused 'json-parser-feed! "not a parser" 5)
    (refusal (lambda () (json-parser-feed! 5 "x"))))
  (test-equal "feed: a non-parser and a non-bytevector, four arguments"
    (refused 'json-parser-feed! "not a parser" 5)
    (refusal (lambda () (json-parser-feed! 5 "x" 0 1))))
  (test-equal "feed: a non-parser, two arguments"
    (refused 'json-parser-feed! "not a parser" 5)
    (refusal (lambda () (json-parser-feed! 5 bv)))))

;; --- 7. make-json-parser -----------------------------------------------------------------------

;; contexts-seen : json-handler -> (values handler (-> (Listof Any)))
;; A handler of all fourteen that notes only the context it was called with.
(define (context-handler)
  (let ((seen '()))
    (values (handler-of names (returning 'ok) (lambda (c . entry) (set! seen (cons c seen))))
            (lambda () seen))))

(let ((ctx (vector 'the-context)))
  (let-values (((h seen) (context-handler)))
    (let ((p (make-json-parser h ctx)))
      (json-parser-feed! p doc)
      (test-equal "parser: two arguments, the context reaches all nineteen calls, eq?"
        (list 19 #t)
        (list (length (seen)) (for-all (lambda (x) (eq? x ctx)) (seen))))))
  (let-values (((h seen) (context-handler)))
    (let ((p (make-json-parser h ctx (make-json-options 'depth-limit 3))))
      (json-parser-feed! p doc)
      (test-equal "parser: three arguments, the context reaches all nineteen calls, eq?"
        (list 19 #t)
        (list (length (seen)) (for-all (lambda (x) (eq? x ctx)) (seen)))))))

(let-values (((h seen) (context-handler)))
  (let ((p (make-json-parser h)))
    (json-parser-feed! p doc)
    (test-equal "parser: one argument, the context is #f"
      (list 19 #t)
      (list (length (seen)) (for-all (lambda (x) (eq? x #f)) (seen))))))

(test-equal "parser: the options' depth limit applies, and the default is 512 deep"
  (list '(error nesting-too-deep 3) '(need-input #f 2)
        '(error nesting-too-deep 513) '(need-input #f 512))
  (let ((run (lambda (limit n)
               (let ((p (if limit
                            (make-json-parser (make-json-handler) #f (make-json-options 'depth-limit limit))
                            (make-json-parser (make-json-handler)))))
                 (result->list (json-parser-feed! p (make-bytevector n 91)))))))
    (list (run 2 3) (run 2 2) (run #f 513) (run #f 512))))

(test-equal "parser: a non-handler, one argument"
  (refused 'make-json-parser "not a handler" 5)
  (refusal (lambda () (make-json-parser 5))))
(let ((o (make-json-options)))
  (test-equal "parser: a non-handler, three arguments"
    (refused 'make-json-parser "not a handler" o)
    (refusal (lambda () (make-json-parser o #f o)))))
(test-equal "parser: a non-options value"
  (refused 'make-json-parser "not an options record" 5)
  (refusal (lambda () (make-json-parser (make-json-handler) #f 5))))
(test-equal "parser: a handler where the options go"
  (refused 'make-json-parser "not an options record" all-handler)
  (refusal (lambda () (make-json-parser all-handler #f all-handler))))

;; --- 8. a non-parser ---------------------------------------------------------------------------

(test-equal "finish: a non-parser"
  (refused 'json-parser-finish! "not a parser" 5)
  (refusal (lambda () (json-parser-finish! 5))))
(test-equal "reset: a non-parser"
  (refused 'json-parser-reset! "not a parser" 'x)
  (refusal (lambda () (json-parser-reset! 'x))))
(test-equal "offset: a non-parser"
  (refused 'json-parser-offset "not a parser" all-handler)
  (refusal (lambda () (json-parser-offset all-handler))))

;; --- 9. json-parser-offset ------------------------------------------------------------------------

(let-values (((p c) (fixture (make-json-handler))))
  (test-equal "offset: 0 when new" 0 (json-parser-offset p))
  (json-parser-feed! p (bytes "[1,"))
  (test-equal "offset: after a feed" 3 (json-parser-offset p))
  (json-parser-feed! p (bytes "2"))
  (test-equal "offset: after another" 4 (json-parser-offset p)))

(test-equal "offset: inside each handler procedure, at each event of the document"
  full-trace
  (car (run-whole all-handler doc)))

;; --- 10. reset ----------------------------------------------------------------------------------------

(let-values (((p c) (fixture (make-json-handler))))
  (json-parser-feed! p (bytes "[[1,"))
  (json-parser-reset! p)
  (test-equal "reset: the offset returns to 0" 0 (json-parser-offset p)))

(let-values (((p c) (fixture (make-json-handler) (make-json-options 'depth-limit 2))))
  (test-equal "reset: an error at full depth" '(error unexpected-byte 2)
    (result->list (json-parser-feed! p (bytes "[[x"))))
  (json-parser-reset! p)
  (test-equal "reset: then [[1]] finishes (the stack is empty again)"
    (list '(need-input #f 5) '(finished #f 5))
    (in-order (result->list (json-parser-feed! p (bytes "[[1]]")))
              (result->list (json-parser-finish! p))))
  (json-parser-reset! p)
  (test-equal "reset: the depth limit is kept"
    '(error nesting-too-deep 3)
    (result->list (json-parser-feed! p (bytes "[[[")))))

(let-values (((p c) (fixture all-handler)))
  (json-parser-feed! p (bytes "[1]"))
  (test-equal "reset: finished" '(finished #f 3) (result->list (json-parser-finish! p)))
  (json-parser-reset! p)
  (test-equal "reset: after finished the parser is reused, with its handler and context"
    (list '(need-input #f 2) '(finished #f 2)
          '((array-start 1) (number-chars 2 (49)) (number-end 2) (array-end 3)
            (object-start 1) (object-end 2)))
    (let* ((f (result->list (json-parser-feed! p (bytes "{}"))))
           (e (result->list (json-parser-finish! p))))
      (list f e (log-of c)))))

;; --- 11. a procedure that raises ----------------------------------------------------------------------------

(let ((boom (list 'boom)))
  (let ((p (make-json-parser (make-json-handler 'null (lambda (c) (raise boom))))))
    (let* ((first (raised (lambda () (json-parser-feed! p (bytes "[null]")))))
           (second (raised (lambda () (json-parser-feed! p (bytes "[null]")))))
           (fin (raised (lambda () (json-parser-finish! p)))))
      (test-equal "raise: the raised object passes out of the feed, eq?"
        #t
        (and (pair? first) (eq? (cadr first) boom)))
      (test-equal "raise: the next feed raises an assertion violation that is not the object"
        '(#t #t)
        (list (and (pair? second) (assertion-violation? (cadr second)))
              (and (pair? second) (not (eq? (cadr second) boom)))))
      (test-equal "raise: the next feed is refused until a reset"
        (refused 'json-parser-feed! "a handler procedure raised or escaped: reset the parser before using it again")
        (refusal (lambda () (json-parser-feed! p (bytes "[null]")))))
      (test-equal "raise: finishing is refused too"
        (refused 'json-parser-finish! "a handler procedure raised or escaped: reset the parser before using it again")
        (refusal (lambda () (json-parser-finish! p))))
      (test-equal "raise: a refused feed was an assertion violation, from the first try"
        (list #t #t)
        (list (and (pair? second) (assertion-violation? (cadr second)))
              (and (pair? fin) (assertion-violation? (cadr fin)))))
      (test-equal "raise: a bad range is still reported as a bad range"
        (refused 'json-parser-feed! "the range is not within the bytevector" 3 2 1)
        (refusal (lambda () (json-parser-feed! p (bytes "x") 3 2))))
      (json-parser-reset! p)
      (test-equal "raise: after a reset the parser works again"
        (list '(need-input #f 3) '(finished #f 3))
        (let* ((f (result->list (json-parser-feed! p (bytes "[1]"))))
               (e (result->list (json-parser-finish! p))))
          (list f e))))))

(test-equal "raise: a condition object passes out eq? too"
  #t
  (let* ((obj (make-assertion-violation))
         (p (make-json-parser (make-json-handler 'array-start (lambda (c) (raise obj)))))
         (r (raised (lambda () (json-parser-feed! p (bytes "[")))))
         )
    (and (pair? r) (eq? (cadr r) obj))))

;; --- 11b. a call from inside the parser's own procedures ------------------------------------------

(define busy-message "called from inside one of the parser's own handler procedures")

;; (label operation who), the operation taking the parser.
(define busy-operations
  (list (list "feed" (lambda (p) (json-parser-feed! p (bytes "1"))) 'json-parser-feed!)
        (list "feed with a range" (lambda (p) (json-parser-feed! p (bytes "1") 0 1)) 'json-parser-feed!)
        (list "finish" (lambda (p) (json-parser-finish! p)) 'json-parser-finish!)
        (list "reset" (lambda (p) (json-parser-reset! p)) 'json-parser-reset!)))

(for-each
 (lambda (row)
   (let ((label (car row)) (op (cadr row)) (who (caddr row)))
     ;; The procedure catches the refusal and returns: the parse goes on.
     (let* ((seen '())
            (box (vector #f))
            (p (make-json-parser
                (make-json-handler 'array-start
                                   (lambda (c)
                                     (set! seen (cons (refusal (lambda () (op (vector-ref c 0)))) seen))
                                     #f))
                box)))
       (vector-set! box 0 p)
       (test-equal (string-append "busy: " label " inside a procedure, caught: refused and the parse goes on")
         (list (list (refused who busy-message))
               '(need-input #f 3) '(finished #f 3))
         (let* ((f (result->list (json-parser-feed! p (bytes "[1]"))))
                (e (result->list (json-parser-finish! p))))
           (list seen f e))))
     ;; The procedure does not catch it: it passes out, and the parser is poisoned.
     (let* ((box (vector #f))
            (p (make-json-parser
                (make-json-handler 'array-start (lambda (c) (op (vector-ref c 0))))
                box)))
       (vector-set! box 0 p)
       (let* ((outer (refusal (lambda () (json-parser-feed! p (bytes "[1]")))))
              (next (refusal (lambda () (json-parser-feed! p (bytes "[1]")))))
              (fin (refusal (lambda () (json-parser-finish! p)))))
         (test-equal (string-append "busy: " label " inside a procedure, uncaught: it passes out of the outer feed")
           (refused who busy-message)
           outer)
         (test-equal (string-append "busy: " label " uncaught: the parser is then poisoned for feed and finish")
           (list (refused 'json-parser-feed! "a handler procedure raised or escaped: reset the parser before using it again")
                 (refused 'json-parser-finish! "a handler procedure raised or escaped: reset the parser before using it again"))
           (list next fin))
         (json-parser-reset! p)
         (test-equal (string-append "busy: " label " uncaught: a reset makes it usable")
           '(need-input #f 0)
           (result->list (json-parser-feed! p (bytes ""))))))))
 busy-operations)


;; --- 12. predicates ----------------------------------------------------------------------------------------------

(let* ((options (make-json-options))
       (handler (make-json-handler))
       (parser (make-json-parser handler))
       (result (json-parser-feed! parser (bytes "")))
       (kinds (list options handler parser result))
       (preds (list json-options? json-handler? json-parser? json-result?)))
  (test-equal "predicates: each is #t on its own kind only"
    '((#t #f #f #f) (#f #t #f #f) (#f #f #t #f) (#f #f #f #t))
    (map (lambda (pred) (map pred kinds)) preds))
  (test-equal "predicates: all #f on a vector, a number, #f"
    '((#f #f #f) (#f #f #f) (#f #f #f) (#f #f #f))
    (map (lambda (pred) (list (pred (vector 1)) (pred 5) (pred #f))) preds)))

(test-end "parser-api")

(exit (suite-exit-status runner))
