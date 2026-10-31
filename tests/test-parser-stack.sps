;;; tests/test-parser-stack.sps: the parser's nesting stack (ADR-0004).
;;;
;;; After a value inside a container the machine asks `context` whether the
;;; container is an object or an array, and (jsonparse parser) answers from
;;; its own bytevector stack. These cases are aimed at that stack: every
;;; expected trace and verdict is written by hand here, from the JSON text,
;;; never read back from the parser.
;;;
;;; Each case is run three ways, all pinned:
;;;
;;;   the whole text in one feed    the whole trace, handler calls and
;;;                                 results
;;;   the text in 1-byte feeds      the handler calls, and the verdict
;;;   the text in one feed, bare    the verdict, under a handler with no
;;;   handler                       procedures, whose openers and closers
;;;                                 take the other path
;;;
;;; tests/test-parser-mutants.sps runs this suite against copies of the
;;; library with the stack broken, and requires every copy to fail it. Keep
;;; it fast: it runs once per mutant.
(import (rnrs)
        (srfi :64)
        (jsonparse parser)
        (jsonparse options)
        (jsonparse-testing)
        (jsonparse-testing machine)
        (jsonparse-testing parser))

(define runner (test-runner-simple))
(test-runner-current runner)
(test-begin "parser-stack")

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

;; --- expectations, by hand ------------------------------------------------------

;; events : (Listof Token) -> Trace
;; A token is as, ae, os, oe (the four container calls), (k "text") a key,
;; (n D) a one-digit number, or (s "text") a string; text is ASCII, and
;; short enough to arrive whole under 1-byte feeds.
(define (events tokens)
  (apply append
         (map (lambda (t)
                (cond
                 ((eq? t 'as) '(array-start))
                 ((eq? t 'ae) '(array-end))
                 ((eq? t 'os) '(object-start))
                 ((eq? t 'oe) '(object-end))
                 ((eq? (car t) 'k) (list 'key-start (list 'chars (string->utf8 (cadr t))) 'key-end))
                 ((eq? (car t) 's) (list 'string-start (list 'chars (string->utf8 (cadr t))) 'string-end))
                 (else (list (list 'number-chars (string->utf8 (number->string (cadr t))))
                             'number-end))))
              tokens)))

;; whole-trace : Trace Nat Outcome -> Trace
;; What run-parser records for the whole text of LEN bytes in one feed.
(define (whole-trace evs len outcome)
  (append evs
          (if (eq? (car outcome) 'accepted)
              (list (list 'feed 'need-input #f len) (list 'finish 'finished #f len))
              (list (list 'feed 'error (cadr outcome) (caddr outcome))))))

(define (accepted) '(accepted))
(define (rejected code offset) (list 'rejected code offset))

;; --- running --------------------------------------------------------------------

(define (options limit)
  (if limit (make-json-options 'depth-limit limit) (make-json-options)))

;; A raise is a result of its own, which no expectation equals.
(define-syntax raising
  (syntax-rules ()
    ((_ e) (guard (c (#t (list 'raised))) e))))

(define (event? x) (not (and (pair? x) (memq (car x) '(feed finish)))))

(define (events-of trace) (filter event? trace))

(define (bare-outcome schedule limit)
  (let* ((parser (make-json-parser (make-json-handler) #f (options limit))))
    (let loop ((feeds schedule))
      (if (null? feeds)
          (let ((r (json-parser-finish! parser)))
            (if (eq? (json-result-status r) 'finished)
                (accepted)
                (list 'other (json-result-status r))))
          (let* ((f (car feeds))
                 (r (json-parser-feed! parser (car f) (cadr f) (caddr f))))
            (case (json-result-status r)
              ((need-input) (loop (cdr feeds)))
              ((error) (rejected (json-result-code r) (json-result-offset r)))
              (else (list 'other (json-result-status r)))))))))

;; check : String String (Option Nat) Trace Outcome -> Unit
(define (check name text limit evs outcome)
  (let ((bv (string->utf8 text)))
    (test-equal (string-append name ": whole trace")
      (whole-trace evs (bytevector-length bv) outcome)
      (raising (run-parser (whole-schedule bv) (options limit))))
    (test-equal (string-append name ": 1-byte feeds, handler calls and verdict")
      (list evs outcome)
      (raising (let ((t (run-parser (chunk-schedule bv 1) (options limit))))
                 (list (events-of t) (parser-outcome t)))))
    (test-equal (string-append name ": bare handler, verdict")
      outcome
      (raising (bare-outcome (whole-schedule bv) limit)))))

;; --- 1. mismatched closes -----------------------------------------------------------

(check "[1}" "[1}" #f
       (events '(as (n 1))) (rejected 'unexpected-byte 2))
(check "{\"a\":1]" "{\"a\":1]" #f
       (events '(os (k "a") (n 1))) (rejected 'unexpected-byte 6))
(check "[{\"a\":1]]" "[{\"a\":1]]" #f
       (events '(as os (k "a") (n 1))) (rejected 'unexpected-byte 7))
(check "{\"a\":[1}}" "{\"a\":[1}}" #f
       (events '(os (k "a") as (n 1))) (rejected 'unexpected-byte 7))
(check "[[{}]}" "[[{}]}" #f
       (events '(as as os oe ae)) (rejected 'unexpected-byte 5))
(check "{\"a\":{\"b\":[]]}" "{\"a\":{\"b\":[]]}" #f
       (events '(os (k "a") os (k "b") as ae)) (rejected 'unexpected-byte 12))

;; --- 2. values after a nested close -----------------------------------------------------

(check "[[1],2]" "[[1],2]" #f
       (events '(as as (n 1) ae (n 2) ae)) (accepted))
(check "[{\"a\":1},2]" "[{\"a\":1},2]" #f
       (events '(as os (k "a") (n 1) oe (n 2) ae)) (accepted))
(check "{\"a\":[1],\"b\":2}" "{\"a\":[1],\"b\":2}" #f
       (events '(os (k "a") as (n 1) ae (k "b") (n 2) oe)) (accepted))
(check "{\"a\":{\"b\":1},\"c\":2}" "{\"a\":{\"b\":1},\"c\":2}" #f
       (events '(os (k "a") os (k "b") (n 1) oe (k "c") (n 2) oe)) (accepted))
(check "[[1],\"k\":2]" "[[1],\"k\":2]" #f
       (events '(as as (n 1) ae (s "k"))) (rejected 'unexpected-byte 8))
(check "{\"a\":[1],2}" "{\"a\":[1],2}" #f
       (events '(os (k "a") as (n 1) ae)) (rejected 'unexpected-byte 9))

;; --- 3. alternation at depth ----------------------------------------------------------------

;; The level I of a nest (1 outermost) is an array when odd, an object when
;; even. nest : Nat -> String opens LEVELS of them, the last object holding a
;; 1. closes : Nat -> String closes them, innermost first.
(define (repeat n text)
  (if (= n 0) "" (string-append text (repeat (- n 1) text))))

(define (opening levels)
  (let loop ((i 1) (acc ""))
    (if (> i levels)
        acc
        (loop (+ i 1) (string-append acc (if (odd? i) "[" "{\"a\":"))))))

(define (closing levels)
  (let loop ((i levels) (acc ""))
    (if (< i 1)
        acc
        (loop (- i 1) (string-append acc (if (odd? i) "]" "}"))))))

(define (opening-tokens levels)
  (let loop ((i levels) (acc '()))
    (if (< i 1)
        acc
        (loop (- i 1) (append (if (odd? i) '(as) '(os (k "a"))) acc)))))

(define (closing-tokens levels)
  (let loop ((i levels) (acc '()))
    (if (< i 1)
        (reverse acc)
        (loop (- i 1) (cons (if (odd? i) 'ae 'oe) acc)))))

;; 512 levels: 256 arrays of 1 byte and 256 objects of 5 make 1536 bytes of
;; opens, then the 1 at 1536, then 512 closes at 1537 to 2048.
(define full-open (opening 512))
(define full-close (closing 512))

(check "alternation to depth 512, closed"
       (string-append full-open "1" full-close) #f
       (events (append (opening-tokens 512) '((n 1)) (closing-tokens 512)))
       (accepted))
(check "alternation to depth 512, the outermost close wrong"
       (string-append full-open "1" (substring full-close 0 511) "}") #f
       (events (append (opening-tokens 512) '((n 1))
                       (reverse (cdr (reverse (closing-tokens 512))))))
       (rejected 'unexpected-byte 2048))
(check "alternation to depth 512, the innermost close wrong"
       (string-append full-open "1" "]" (substring full-close 1 512)) #f
       (events (append (opening-tokens 512) '((n 1))))
       (rejected 'unexpected-byte 1537))
(check "alternation one level deeper than 512"
       (string-append full-open "[") #f
       (events (opening-tokens 512))
       (rejected 'nesting-too-deep 1537))

;; --- 4. a full stack at small limits -----------------------------------------------------------

(check "limit 3: array, object, array, then values after closes"
       "[{\"a\":[1]},{\"b\":[2]}]" 3
       (events '(as os (k "a") as (n 1) ae oe os (k "b") as (n 2) ae oe ae))
       (accepted))
(check "limit 3: three arrays, then a value after each close"
       "[[[1],2],3]" 3
       (events '(as as as (n 1) ae (n 2) ae (n 3) ae))
       (accepted))
(check "limit 3: three objects, then a pair after each close"
       "{\"a\":{\"b\":{\"c\":1},\"d\":2},\"e\":3}" 3
       (events '(os (k "a") os (k "b") os (k "c") (n 1) oe (k "d") (n 2) oe (k "e") (n 3) oe))
       (accepted))
(check "limit 3: a fourth level is too deep"
       "[{\"a\":[[" 3
       (events '(as os (k "a") as))
       (rejected 'nesting-too-deep 8))
(check "limit 3: a wrong close at full depth"
       "[{\"a\":[1]]}" 3
       (events '(as os (k "a") as (n 1) ae))
       (rejected 'unexpected-byte 9))
(check "limit 2: object in array, a value after the close"
       "[{\"a\":1},{\"b\":2}]" 2
       (events '(as os (k "a") (n 1) oe os (k "b") (n 2) oe ae))
       (accepted))
(check "limit 2: a third level is too deep"
       "[{\"a\":[1]}]" 2
       (events '(as os (k "a")))
       (rejected 'nesting-too-deep 7))
(check "limit 1: an array of values"
       "[1,2]" 1
       (events '(as (n 1) (n 2) ae))
       (accepted))
(check "limit 1: an object of pairs"
       "{\"a\":1,\"b\":2}" 1
       (events '(os (k "a") (n 1) (k "b") (n 2) oe))
       (accepted))
(check "limit 1: a second level is too deep"
       "[[1]]" 1
       (events '(as))
       (rejected 'nesting-too-deep 2))
(check "limit 1: an object in an array is too deep"
       "[{}]" 1
       (events '(as))
       (rejected 'nesting-too-deep 2))
(check "limit 1: a wrong close"
       "{\"a\":1]" 1
       (events '(os (k "a") (n 1)))
       (rejected 'unexpected-byte 6))

;; --- 5. reset ---------------------------------------------------------------------------------------

;; A parser's context is a two-slot vector: the structural calls and escapes
;; so far, newest first, and a hook, a thunk or #f, that the first number-end
;; runs once. Not recording-handler: reset needs the same parser fed again
;; with a fresh record, and several parsers need a record each.
(define (new-context) (vector '() #f))

(define (note! v x) (vector-set! v 0 (cons x (vector-ref v 0))))

(define (calls v) (reverse (vector-ref v 0)))

(define (note-handler)
  (let ((note (lambda (name) (lambda (v) (note! v name)))))
    (make-json-handler
     'object-start (note 'os) 'object-end (note 'oe)
     'array-start (note 'as) 'array-end (note 'ae)
     'escape (lambda (v scalar) (note! v (list 'escape scalar)))
     'number-end (lambda (v)
                   (let ((hook (vector-ref v 1)))
                     (when hook
                       (vector-set! v 1 #f)
                       (hook)))))))

;; feed-text! : json-parser String Nat -> (List Symbol (Option Symbol) Nat)
;; Feeds TEXT in feeds of CHUNK bytes, and finishes unless a feed errs. The
;; last result's status, code and offset.
(define (feed-text! parser text chunk)
  (let* ((bv (string->utf8 text))
         (to-triple (lambda (r) (list (json-result-status r) (json-result-code r)
                                      (json-result-offset r)))))
    (let loop ((feeds (chunk-schedule bv chunk)))
      (if (null? feeds)
          (to-triple (json-parser-finish! parser))
          (let* ((f (car feeds))
                 (r (json-parser-feed! parser (car f) (cadr f) (caddr f))))
            (if (eq? (json-result-status r) 'need-input)
                (loop (cdr feeds))
                (to-triple r)))))))

;; reset-case : String Nat (Listof (List String (Listof Symbol) Triple)) -> Unit
;; With the depth limit 3, for each of the two chunk sizes: a parser meets
;; every text of TEXTS in turn, reset between, and each leaves the calls and
;; the result written beside it.
(define (reset-case name steps)
  (for-each
   (lambda (chunk-name chunk)
     (test-equal (string-append name ": " chunk-name)
       (map (lambda (s) (list (cadr s) (caddr s))) steps)
       (raising
        (let* ((record (new-context))
               (parser (make-json-parser (note-handler) record (options 3))))
          (let loop ((steps steps) (acc '()))
            (if (null? steps)
                (reverse acc)
                (begin
                  (vector-set! record 0 '())
                  (let ((result (feed-text! parser (car (car steps)) (if chunk chunk 1000))))
                    (json-parser-reset! parser)
                    (loop (cdr steps) (cons (list (calls record) result) acc))))))))))
   '("one feed" "1-byte feeds") '(#f 1)))

(reset-case "an error at full depth, then a full stack topped by an array"
  (list (list "[[[[" '(as as as) '(error nesting-too-deep 4))
        (list "[{\"a\":[1],\"b\":2},3]" '(as os as ae oe ae) '(finished #f 19))))

(reset-case "an error at full depth, then a full stack topped by an object"
  (list (list "[[[[" '(as as as) '(error nesting-too-deep 4))
        (list "{\"a\":[{\"b\":1},2],\"c\":3}" '(os as os oe ae oe) '(finished #f 23))))

(reset-case "a full stack left open, then both tops"
  (list (list "[{\"a\":[" '(as os as) '(error unexpected-eof 7))
        (list "[{\"a\":[1],\"b\":2},3]" '(as os as ae oe ae) '(finished #f 19))
        (list "{\"a\":[{\"b\":1},2],\"c\":3}" '(os as os oe ae oe) '(finished #f 23))))

(reset-case "a wrong close at full depth, then a full stack"
  (list (list "[{\"a\":[1]]" '(as os as ae) '(error unexpected-byte 9))
        (list "{\"a\":[{\"b\":1},2],\"c\":3}" '(os as os oe ae oe) '(finished #f 23))
        (list "[{\"a\":[1],\"b\":2},3]" '(as os as ae oe ae) '(finished #f 19))))


;; --- 6. kinds that do not repeat ----------------------------------------------------------

;; A nest is a list of kinds, outermost first, each a (array) or o (object).
;; A level holds its child, then a sibling value, so every close is followed
;; by a value that needs the right answer; the innermost holds a 1. Text and
;; tokens, written out level by level.
(define (kind-open k) (if (eq? k 'a) "[" "{\"a\":"))
(define (kind-close k) (if (eq? k 'a) "]" "}"))
(define (kind-sibling k) (if (eq? k 'a) ",2" ",\"b\":2"))
(define (kind-sibling-tokens k) (if (eq? k 'a) '((n 2)) '((k "b") (n 2))))
(define (kind-close-token k) (if (eq? k 'a) 'ae 'oe))

(define (nest-text kinds)
  (let ((inner-first (reverse kinds)))
    (apply string-append
           (append (map kind-open kinds)
                   (list "1" (kind-close (car inner-first)))
                   (apply append
                          (map (lambda (k) (list (kind-sibling k) (kind-close k)))
                               (cdr inner-first)))))))

(define (nest-tokens kinds)
  (let ((inner-first (reverse kinds)))
    (append (apply append (map (lambda (k) (if (eq? k 'a) '(as) '(os (k "a")))) kinds))
            (list '(n 1) (kind-close-token (car inner-first)))
            (apply append
                   (map (lambda (k) (append (kind-sibling-tokens k) (list (kind-close-token k))))
                        (cdr inner-first))))))

(define (repeat-kind n k) (if (= n 0) '() (cons k (repeat-kind (- n 1) k))))

(define (nest-check name kinds)
  (check name (nest-text kinds) #f (events (nest-tokens kinds)) (accepted)))

;; The text of a small nest, written out, ties the generator to the JSON.
(check "{\"a\":[[1],2],\"b\":2}" "{\"a\":[[1],2],\"b\":2}" #f
       (events '(os (k "a") as as (n 1) ae (n 2) ae (k "b") (n 2) oe))
       (accepted))
(test-equal "the generator writes the nest o a a as that text"
  "{\"a\":[[1],2],\"b\":2}"
  (nest-text '(o a a)))

(nest-check "an object outside 8 arrays" (cons 'o (repeat-kind 8 'a)))
(nest-check "an object outside 64 arrays" (cons 'o (repeat-kind 64 'a)))
(nest-check "an object outside 511 arrays" (cons 'o (repeat-kind 511 'a)))
(nest-check "an array outside 8 objects" (cons 'a (repeat-kind 8 'o)))
(nest-check "an array outside 64 objects" (cons 'a (repeat-kind 64 'o)))

;; thue-morse : Nat -> (Listof Kind)
;; Level i (from 1) is an object when i-1 has an odd number of 1 bits, else
;; an array: a kind sequence with no period.
(define (thue-morse n)
  (let loop ((i (- n 1)) (acc '()))
    (if (< i 0)
        acc
        (loop (- i 1)
              (cons (let bits ((x i) (odd #f))
                      (if (= x 0)
                          (if odd 'o 'a)
                          (bits (div x 2) (if (odd? x) (not odd) odd))))
                    acc)))))

(test-equal "thue-morse starts a o o a o a a o"
  '(a o o a o a a o)
  (thue-morse 8))
(nest-check "Thue-Morse kinds to depth 512" (thue-morse 512))
(nest-check "Thue-Morse kinds to depth 100" (thue-morse 100))

;; --- 7. parsers are independent ---------------------------------------------------------------

(define doc-a "[{\"a\":[1],\"b\":2},3]")
(define events-a '(as os as ae oe ae))
(define doc-b "{\"a\":[{\"b\":1},2],\"c\":3}")
(define events-b '(os as os oe ae oe))

;; lockstep : String String -> (List Pair Pair)
;; Two parsers, each with its own record, fed one byte of A, then one of B,
;; in turn; then both finished. Each one's calls and last result.
(define (lockstep text-a text-b)
  (let* ((ra (new-context)) (rb (new-context))
         (pa (make-json-parser (note-handler) ra (options 3)))
         (pb (make-json-parser (note-handler) rb (options 3)))
         (a (string->utf8 text-a)) (b (string->utf8 text-b))
         (last-a #f) (last-b #f))
    (let loop ((i 0))
      (when (< i (max (bytevector-length a) (bytevector-length b)))
        (when (< i (bytevector-length a))
          (set! last-a (json-parser-feed! pa a i (+ i 1))))
        (when (< i (bytevector-length b))
          (set! last-b (json-parser-feed! pb b i (+ i 1))))
        (loop (+ i 1))))
    (let* ((fa (json-parser-finish! pa)) (fb (json-parser-finish! pb)))
      (list (list (calls ra) (list (json-result-status fa) (json-result-code fa)))
            (list (calls rb) (list (json-result-status fb) (json-result-code fb)))))))

(test-equal "two documents with different stacks, fed a byte each in turn"
  (list (list events-a '(finished #f)) (list events-b '(finished #f)))
  (raising (lockstep doc-a doc-b)))
(test-equal "the same two, the other way round"
  (list (list events-b '(finished #f)) (list events-a '(finished #f)))
  (raising (lockstep doc-b doc-a)))

;; The outer parser reads doc-a. At its first number-end, inside its handler,
;; an inner parser reads the whole of doc-b; the outer then goes on.
(test-equal "a parse of doc-b inside a handler procedure of the parser reading doc-a"
  (list events-a '(finished #f) events-b '(finished #f))
  (raising
   (let* ((outer (new-context)) (inner (new-context))
          (inner-result #f))
     (vector-set! outer 1
                  (lambda ()
                    (let* ((p (make-json-parser (note-handler) inner (options 3)))
                           (r (begin (json-parser-feed! p (string->utf8 doc-b))
                                     (json-parser-finish! p))))
                      (set! inner-result (list (json-result-status r) (json-result-code r))))))
     (let* ((p (make-json-parser (note-handler) outer (options 3))))
       (json-parser-feed! p (string->utf8 doc-a))
       (let ((r (json-parser-finish! p)))
         (list (calls outer) (list (json-result-status r) (json-result-code r))
               (calls inner) inner-result))))))

;; Two parsers stop between the halves of a surrogate pair, then go on in
;; turn, so each one's high half must still be its own.
(define (split-pairs)
  (let* ((ra (new-context)) (rb (new-context))
         (pa (make-json-parser (note-handler) ra (options 3)))
         (pb (make-json-parser (note-handler) rb (options 3)))
         (feed (lambda (p text) (json-parser-feed! p (string->utf8 text)))))
    (feed pa "[\"\\ud83d")
    (feed pb "[\"\\ud801")
    (feed pa "\\ude00\"]")
    (feed pb "\\udc37\"]")
    (list (calls ra) (calls rb))))

(test-equal "two parsers stopped between the halves of a surrogate pair, fed in turn"
  '((as (escape #x1F600) ae) (as (escape #x10437) ae))
  (raising (split-pairs)))

(define (split-pairs-by-byte)
  (let* ((ra (new-context)) (rb (new-context))
         (pa (make-json-parser (note-handler) ra (options 3)))
         (pb (make-json-parser (note-handler) rb (options 3)))
         (a (string->utf8 "[\"\\ud83d\\ude00\"]"))
         (b (string->utf8 "[\"\\ud801\\udc37\"]")))
    (let loop ((i 0))
      (when (< i (bytevector-length a))
        (json-parser-feed! pa a i (+ i 1))
        (json-parser-feed! pb b i (+ i 1))
        (loop (+ i 1))))
    (list (calls ra) (calls rb))))

(test-equal "the same two pairs, fed a byte each in turn"
  '((as (escape #x1F600) ae) (as (escape #x10437) ae))
  (raising (split-pairs-by-byte)))

(test-end "parser-stack")

(exit (suite-exit-status runner))
