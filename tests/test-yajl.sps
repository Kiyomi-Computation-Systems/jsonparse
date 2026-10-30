#!r6rs
;;; yajl's 58 parsing cases (ADR-0012), through (jsonparse-testing yajl).
;;;
;;; Each case runs in one feed and in feeds of 1 to 31 bytes, as yajl's
;;; run_tests.sh reads it, and every run must give the same events:
;;;
;;;   - a plain case gives the gold's events, unless the divergence list
;;;     below names it with jsonparse's own events and the reason;
;;;   - an option-prefixed case is rejected in strict mode, after a prefix of
;;;     the gold's events;
;;;   - an am_ case gives the gold's events with mode bit 0 set, yajl's
;;;     allow-multiple.
;;;
;;; The unit cases come first: their expected values are written by hand.
(import (rnrs)
        (srfi :64)
        (jsonparse-testing)
        (jsonparse-testing machine)
        (jsonparse-testing yajl))

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

;; --- helpers ------------------------------------------------------------------

;; answer : (-> Any) -> Any
;; THUNK's value, but the symbol false for #f, and (raised TEXT) for a raise.
(define (answer thunk)
  (guard (e (#t (list 'raised (describe e))))
    (let ((v (thunk)))
      (if (eq? v #f) 'false v))))

;; raised? : (-> Any) -> (U 'raised 'no-raise)
(define (raised? thunk)
  (guard (e (#t 'raised))
    (thunk)
    'no-raise))

(define (u8 s) (string->utf8 s))

;; bytes : (U String (Listof Byte)) ... -> Bytevector
;; The parts, a string as its UTF-8 and a list as its bytes, in order.
(define (bytes . parts)
  (u8-list->bytevector
   (apply append (map (lambda (p) (if (string? p) (bytevector->u8-list (u8 p)) p))
                      parts))))

(define (range from to)
  (if (> from to) '() (cons from (range (+ from 1) to))))

(define (repeat n x) (if (= n 0) '() (cons x (repeat (- n 1) x))))

(define (but-last xs) (reverse (cdr (reverse xs))))

(define (string-prefix? p s)
  (and (<= (string-length p) (string-length s))
       (string=? p (substring s 0 (string-length p)))))

(define (string-contains? s part)
  (let ((n (string-length part)))
    (let loop ((i 0))
      (and (<= (+ i n) (string-length s))
           (or (string=? part (substring s i (+ i n)))
               (loop (+ i 1)))))))

;; test-events : String (Listof Event) (Listof Event) -> Void
;; A test that ACTUAL is alike EXPECTED, as same-events? holds. When alike,
;; ACTUAL is EXPECTED to SRFI-64; otherwise both are printed as they are.
(define (test-events name expected actual)
  (test-equal name expected (if (same-events? expected actual) expected actual)))

;; Hand-written trace results, the shape run-machine notes.
(define finished '(finish finished 0 0 0 #f))
(define (error-result code) (list 'feed 'error 0 0 0 (list code 0 'byte 'e #f #f #f)))

(test-begin "yajl")

;; --- unit: gold-events ----------------------------------------------------------

(test-equal "gold-events: every callback line yajl_test prints, and memory leaks: gives none"
  (list '(map-open) (list 'key (u8 "k")) '(array-open) '(integer "-12") '(double 3.14157)
        '(double 6e-6) '(bool #t) '(bool #f) '(null) (list 'string (u8 "x"))
        (list 'string (u8 "")) '(array-close) '(map-close))
  (answer (lambda ()
            (gold-events
             (bytes "map open '{'\nkey: 'k'\narray open '['\ninteger: -12\n"
                    "double: 3.14157\ndouble: 6e-06\nbool: true\nbool: false\nnull\n"
                    "string: 'x'\nstring: ''\narray close ']'\nmap close '}'\n"
                    "memory leaks:\t0\n")))))

(test-equal "gold-events: a lexical or a parse error line is (rejected), whatever its text"
  (list (list (list 'string (u8 "a")) '(rejected)) '((rejected)))
  (list (answer (lambda ()
                  (gold-events (bytes "string: 'a'\nlexical error: invalid char in json text.\n"
                                      "memory leaks:\t0\n"))))
        (answer (lambda ()
                  (gold-events (bytes "parse error: premature EOF\nmemory leaks:\t0\n"))))))

;; The first quote and newline is followed by a line that reads, null, and
;; then by one that does not: the value runs to the second.
(test-equal "gold-events: a value holding a quote and newline, NUL and a byte UTF-8 forbids runs to the pair after which the rest reads"
  (list (list 'string (bytes "a'\nnull\nb" '(0 255))) (list 'key (u8 "q")))
  (answer (lambda ()
            (gold-events (bytes "string: 'a'\nnull\nb" '(0 255) "'\nkey: 'q'\nmemory leaks:\t0\n")))))

(test-equal "gold-events: a line that is none of yajl_test's raises"
  '(raised raised raised)
  (list (raised? (lambda () (gold-events (bytes "null\nnul\n"))))
        (raised? (lambda () (gold-events (bytes "double: x\n"))))
        (raised? (lambda () (gold-events (bytes "string: 'a\n"))))))

;; --- unit: trace-events ---------------------------------------------------------

;; U+1D11E is the pair D834 DD1E, and F0 9D 84 9E in UTF-8.
(test-equal "trace-events: fragments and escapes in a key and a string, a pair made one code point, and the containers"
  (list '(map-open) (list 'key (bytes "k" '(#xC3 #xBF))) '(array-open)
        (list 'string (bytes "ab\nc" '(#xF0 #x9D #x84 #x9E) "d")) '(array-close) '(map-close))
  (answer (lambda ()
            (trace-events
             (list 'object-start 'key-start '(chars #vu8(107)) '(escape #xFF) '(chars #vu8())
                   'key-end 'array-start '(feed need-input 0 0 0 #f) 'string-start
                   '(chars #vu8(97)) '(feed need-input 0 0 0 #f) '(chars #vu8(98))
                   '(escape #x0A) '(chars #vu8(99)) '(escape #xD834) '(escape #xDD1E)
                   '(chars #vu8(100)) 'string-end '(context array) 'array-end
                   '(context object) 'object-end finished)))))

(test-equal "trace-events: a number is an integer with no '.', 'e' or 'E' in its text, else a double; and the literals"
  '((array-open) (integer "-12") (double 100000.0) (double 300.0) (double 2.5) (integer "0")
    (bool #t) (bool #f) (null) (array-close))
  (answer (lambda ()
            (trace-events
             (list 'array-start '(number #vu8(45 49)) '(number #vu8(50)) 'number-end
                   '(number #vu8(49 101 53)) 'number-end '(number #vu8(51 69 50)) 'number-end
                   '(number #vu8(50 46 53)) 'number-end '(number #vu8(48)) 'number-end
                   'true 'false 'null 'array-end finished)))))

(test-equal "trace-events: a string, key or number an error cuts short is left out, and the error is (rejected)"
  '(((array-open) (rejected)) ((map-open) (rejected)) ((array-open) (rejected)))
  (list (answer (lambda ()
                  (trace-events (list 'array-start 'string-start '(chars #vu8(97))
                                      '(escape #xD834) (error-result 'invalid-surrogate)))))
        (answer (lambda ()
                  (trace-events (list 'object-start 'key-start '(chars #vu8(97))
                                      (error-result 'invalid-utf8)))))
        (answer (lambda ()
                  (trace-events (list 'array-start '(number #vu8(48))
                                      (error-result 'invalid-number)))))))

(test-equal "trace-events: an outcome neither accepted nor rejected ends the list as itself, and a foreign entry raises"
  '(((null) (other need-input)) raised)
  (list (answer (lambda () (trace-events (list 'null '(feed need-input 0 0 0 #f)))))
        (raised? (lambda () (trace-events (list 'bogus finished))))))

;; --- unit: comparing --------------------------------------------------------------

(test-equal "same-double?: six significant digits, as %g prints"
  '(#t false #t false #t false)
  (map (lambda (p) (answer (lambda () (same-double? (car p) (cdr p)))))
       '((3.141569 . 3.14157) (3.1416 . 3.14157) (0.00011999999999999999 . 0.00012)
         (1.2e-5 . 1.2e-6) (-6e-6 . -6e-6) (-6e-6 . 6e-6))))

;; %g gives 10 for 9.999996, and 9.99999 for 9.999994; 1234565 is a tie, and
;; %g gives 1.23456e+06, to even.
(test-equal "same-double?: rounding that carries into the exponent, a tie to even, and the sign of zero"
  '(#t false #t false false)
  (map (lambda (p) (answer (lambda () (same-double? (car p) (cdr p)))))
       '((9.999996 . 10.0) (9.999994 . 10.0) (1234565.0 . 1234560.0)
         (1234565.0 . 1234570.0) (0.0 . -0.0))))

(test-equal "same-events? and events-prefix?: doubles by same-double?, all else by equal?, and length"
  '(#t false false #t #t false false #t)
  (list (answer (lambda () (same-events? '((double 3.141569) (null)) '((double 3.14157) (null)))))
        (answer (lambda () (same-events? '((double 3.1416)) '((double 3.14157)))))
        (answer (lambda () (same-events? '((null)) '((null) (null)))))
        (answer (lambda () (events-prefix? '() '((null)))))
        (answer (lambda () (events-prefix? '((double 3.141569)) '((double 3.14157) (null)))))
        (answer (lambda () (events-prefix? '((bool #t)) '((bool #f) (null)))))
        (answer (lambda () (events-prefix? '((null) (null)) '((null)))))
        (answer (lambda () (events-prefix? (list (list 'key (u8 "a"))) (list (list 'key (u8 "a"))))))))

;; --- the corpus -----------------------------------------------------------------

(define dir "tests/corpus/yajl/cases/")

(define cases
  (map (lambda (file) (substring file 0 (- (string-length file) 5)))
       (corpus-files dir ".json")))

(define (case-input name) (file-bytes (string-append dir name ".json")))
(define (case-gold name) (gold-events (file-bytes (string-append dir name ".json.gold"))))

;; yajl's run_tests.sh turns on an option for these four prefixes only:
;; comments, garbage, multiple values and partial values. fg_ and np_ cases
;; run with none.
(define option-prefixes '("ac_" "ag_" "am_" "ap_"))

(define (option-prefix name)
  (find (lambda (p) (string-prefix? p name)) option-prefixes))

(test-equal "the corpus holds yajl's 58 cases"
  58
  (length cases))

(test-equal "the cases by option prefix, and those with none, fg_ and np_ among them"
  '(("ac_" 2) ("ag_" 3) ("am_" 4) ("ap_" 4) (none 45))
  (append (map (lambda (p)
                 (list p (length (filter (lambda (n) (equal? (option-prefix n) p)) cases))))
               option-prefixes)
          (list (list 'none (length (filter (lambda (n) (not (option-prefix n))) cases))))))

;; --- runs -----------------------------------------------------------------------

;; schedules : Bytevector -> (Listof (Pair Label Schedule))
;; BV in one feed, labelled whole, then in feeds of K bytes for K from 1 to
;; 31, labelled K.
(define (schedules bv)
  (cons (cons 'whole (whole-schedule bv))
        (map (lambda (k) (cons k (chunk-schedule bv k))) (range 1 31))))

(define (events-of bv fields schedule)
  (trace-events (run-machine generated-machine schedule fields)))

;; failures : Bytevector Fields (Events -> Boolean) -> (U '() (List (Listof Label) Events))
;; '() when OK? holds of every schedule's events; otherwise the labels of
;; the schedules it fails, and the first one's events.
(define (failures bv fields ok?)
  (let loop ((ss (schedules bv)) (labels '()) (shown #f))
    (if (null? ss)
        (if (null? labels) '() (list (reverse labels) shown))
        (let ((events (events-of bv fields (cdar ss))))
          (if (ok? events)
              (loop (cdr ss) labels shown)
              (loop (cdr ss) (cons (caar ss) labels) (or shown events)))))))

;; --- the divergences --------------------------------------------------------------

;; Each plain case whose events differ from yajl's: its name, jsonparse's
;; own events, and why.
(define divergences
  `(("deep_arrays" ,(append (repeat 512 '(array-open)) '((rejected)))
     "ADR-0005: the depth limit defaults to 512, so the 513th [ is nesting-too-deep; yajl has none")
    ("high_overflow" ((integer "9223372036854775808"))
     "ADR-0011: integers are exact, so there is no integer overflow")
    ("isolated_surrogate_marker" ((rejected))
     "RFC 8259 section 8.2: a lone surrogate is unpredictable; the machine enforces pairing, where yajl prints ?")
    ("leading_zero_in_number" ((map-open) (key ,(u8 "bad thing")) (rejected))
     "RFC 8259 section 6: 01 has a leading zero; jsonparse rejects it as one malformed number, where yajl prints integer 0 first")
    ("low_overflow" ((integer "-9223372036854775808"))
     "ADR-0011: integers are exact, so there is no integer overflow")))

(define (divergence name) (assoc name divergences))

(define plain-cases
  (filter (lambda (n) (and (not (option-prefix n)) (not (divergence n)))) cases))

(test-equal "every divergence names a plain case once, with a reason citing an ADR or an RFC"
  '()
  (let loop ((ds divergences) (seen '()) (bad '()))
    (if (null? ds)
        (reverse bad)
        (let* ((name (caar ds)) (reason (caddr (car ds)))
               (ok (and (member name cases) (not (option-prefix name)) (not (member name seen))
                        (or (string-prefix? "ADR-" reason) (string-prefix? "RFC " reason))
                        (string-contains? reason ": ")
                        (> (string-length reason) (string-length "ADR-0000: ")))))
          (loop (cdr ds) (cons name seen) (if ok bad (cons name bad)))))))

(for-each
 (lambda (d)
   (let ((name (car d)) (expected (cadr d)))
     (let ((bv (case-input name)) (gold (case-gold name)))
       (test-events (string-append name " diverges: one feed gives jsonparse's own events")
         expected (events-of bv '() (whole-schedule bv)))
       (test-equal (string-append name " diverges: chunks of 1 to 31 bytes give them too")
         '() (failures bv '() (lambda (e) (same-events? expected e))))
       (test-equal (string-append name " still differs from the gold")
         'differs
         (if (same-events? gold (events-of bv '() (whole-schedule bv))) 'equals-gold 'differs)))))
 divergences)

;; 1,024 arrays nest in deep_arrays; a limit of 1,024 lets every one open.
(let ((bv (case-input "deep_arrays")) (gold (case-gold "deep_arrays")))
  (test-events "deep_arrays with depth-left 1024: one feed gives the gold's events"
    gold (events-of bv '((depth-left . 1024)) (whole-schedule bv)))
  (test-equal "deep_arrays with depth-left 1024: chunks of 1 to 31 bytes give them too"
    '() (failures bv '((depth-left . 1024)) (lambda (e) (same-events? gold e)))))

;; --- the plain cases --------------------------------------------------------------

(for-each
 (lambda (name)
   (let ((bv (case-input name)) (gold (case-gold name)))
     (test-events (string-append name ": one feed gives the gold's events")
       gold (events-of bv '() (whole-schedule bv)))
     (test-equal (string-append name ": chunks of 1 to 31 bytes give them too")
       '() (failures bv '() (lambda (e) (same-events? gold e))))))
 plain-cases)

;; --- the option-prefixed cases ----------------------------------------------------

;; Each option-prefixed case and the events strict mode gives before it
;; rejects, read off the input: a comment is refused at its /, garbage at
;; its x, a second top-level value where it starts, and a partial value at
;; the end of input.
(define strict-events
  `(("ac_difficult_json_c_test_case_with_comments" ((map-open) (key ,(u8 "glossary")) (map-open)))
    ("ac_simple_with_comments" ((map-open) (key ,(u8 "this")) (string ,(u8 "is"))))
    ("ag_false_then_garbage" ((bool #f)))
    ("ag_null_then_garbage" ((null)))
    ("ag_true_then_garbage" ((bool #t)))
    ("am_eof" ((map-open) (key ,(u8 "123"))))
    ("am_integers" ((integer "1221")))
    ("am_multiple" ((map-open) (map-close)))
    ("am_stuff" ((map-open) (map-close)))
    ("ap_array_open" ((array-open)))
    ("ap_eof_str" ())
    ("ap_map_open" ((map-open)))
    ("ap_partial_ok" ((array-open) (string ,(u8 "foo")) (string ,(u8 "bar"))))))

(test-equal "strict-events pins every option-prefixed case, and no other"
  (filter option-prefix cases)
  (map car strict-events))

(for-each
 (lambda (pin)
   (let* ((name (car pin)) (before (cadr pin))
          (expected (append before '((rejected))))
          (bv (case-input name)) (gold (case-gold name)))
     (test-events (string-append name ": strict mode, one feed, gives the pinned events and rejects")
       expected (events-of bv '() (whole-schedule bv)))
     (test-equal (string-append name ": strict mode, chunks of 1 to 31 bytes give them too")
       '() (failures bv '() (lambda (e) (same-events? expected e))))
     (test-equal (string-append name ": the pinned events are a prefix of the gold's")
       'prefix
       (if (events-prefix? before gold) 'prefix (list 'not-a-prefix before gold)))))
 strict-events)

;; Mode bit 0 is yajl's allow-multiple, -m.
(for-each
 (lambda (name)
   (let ((bv (case-input name)) (gold (case-gold name)))
     (test-events (string-append name " with mode bit 0: one feed gives the gold's events")
       gold (events-of bv '((mode . 1)) (whole-schedule bv)))
     (test-equal (string-append name " with mode bit 0: chunks of 1 to 31 bytes give them too")
       '() (failures bv '((mode . 1)) (lambda (e) (same-events? gold e))))))
 (filter (lambda (n) (equal? (option-prefix n) "am_")) cases))

;; --- keys ---------------------------------------------------------------------------

(test-equal "no case's key holds NUL, which yajl_test's %s would print cut short"
  '()
  (filter (lambda (name)
            (let ((bv (case-input name)))
              (exists (lambda (e)
                        (and (eq? (car e) 'key)
                             (memv 0 (bytevector->u8-list (cadr e)))))
                      (events-of bv '() (whole-schedule bv)))))
          cases))

(test-end "yajl")

(exit (suite-exit-status runner))
