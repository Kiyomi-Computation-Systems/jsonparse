;;; tests/test-number.sps: (jsonparse string)'s numbers held to ADR-0011 and
;;; ADR-0016, with the number-mode and digit-limit options.
;;;
;;; The oracle builds a number's expected value from its digits alone, as
;;; integer x 10^(exponent - fraction digits) with its sign, never with
;;; string->number, which the library converts with:
;;;
;;;   all modes but text  more digits than the limit is number-too-long,
;;;                       first: past the limit the text is not kept
;;;   flonum              a plain number, with no fraction and no exponent,
;;;                       is that exact integer. Any other is inexact of the
;;;                       value, -0.0 when the value is zero and the sign
;;;                       negative, and number-out-of-range when infinite
;;;   exact               the value, or number-out-of-range when the
;;;                       significand's digits plus the exponent's absolute
;;;                       value pass the limit
;;;   text                a json-number of the bytes
;;;
;;; 1. The oracle lanes. The reference machine (run-machine) gives each
;;;    number's bytes, and, from a run in 1-byte feeds, the offset of the
;;;    byte its number-end fires at, where a stop must land. The assembler's
;;;    numbers and the parser's results must be what the reference and the
;;;    oracle make of the same schedule, in all three modes, under the
;;;    default limit and under 3:
;;;      - every corpus file with a number: whole, in chunks of 1, 2, 3, 5,
;;;        7, 13 and 64; under every schedule schedules-for gives when it
;;;        has at most 64 bytes; and under 48 random schedules otherwise.
;;;        Of the 79 files, 75 have at most 64 bytes, and the other four
;;;        71, 84, 137 and 1599;
;;;      - a seeded property of generated numbers in small documents, under
;;;        random schedules and limits.
;;; 2. ADR-0011's pinned values, in every mode.
;;; 3. The digit limit's boundary: 1,000 digits and 1,001, in each part of
;;;    a number and spread across them; text mode at 1,000,001; small
;;;    limits across positions; parts given to the assembler directly.
;;; 4. exact mode's range, at the default limit and small ones.
;;; 5. Stops through the parser, under every schedule, and resets.
;;; 6. json-assembler-number! refusing, and empty after a stop or a raise;
;;;    an assembler's own defaults; assemblers with interleaved parts.
;;; 7. json-number, and a grammar differential with the parser, over / and
;;;    : too, the bytes either side of the digits.
;;; 8. The number-mode and digit-limit options.
;;;
;;; make test runs the default seed. A seed, and a multiplier of the
;;; properties' case counts, may be given by hand:
;;;
;;;   scripts/guix-env sh -c 'make deps >/dev/null && $CHEZ --libdirs \
;;;     src:vendor/byte-machine/src:build/scheme-libs:tests:grammar:vendor/byte-machine/test/support/harness \
;;;     --program tests/test-number.sps 12345 20'
(import (rnrs)
        (rnrs mutable-strings)
        (only (chezscheme) cpu-time)
        (srfi :64)
        (jsonparse-testing)
        (jsonparse-testing property)
        (jsonparse-testing machine)
        (jsonparse-testing parser)
        (jsonparse-testing string)
        (jsonparse parser)
        (jsonparse options)
        (jsonparse string)
        (only (byte-machine test property-driver) schedules-for)
        (only (byte-machine test prng) make-prng))

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

;; --- the arguments --------------------------------------------------------------

(define default-seed 20261030)

(define parsed (parse-property-arguments (cdr (command-line)) default-seed))

(unless parsed
  (put-string (current-error-port)
              "usage: test-number.sps [SEED [MULTIPLIER]]  (decimal digits)\n")
  (exit 1))

(define run (make-property-run "number" (car parsed) (cadr parsed)))

;; --- helpers --------------------------------------------------------------------

;; bytes : (U String Bytevector) ... -> Bytevector
(define (bytes . parts)
  (apply cat (map (lambda (p) (if (string? p) (string->utf8 p) p)) parts)))

(define (cat . bvs)
  (let ((out (make-bytevector (fold-left + 0 (map bytevector-length bvs)))))
    (fold-left (lambda (at bv)
                 (bytevector-copy! bv 0 out at (bytevector-length bv))
                 (+ at (bytevector-length bv)))
               0 bvs)
    out))

(define (sub bv from to)
  (let ((out (make-bytevector (- to from))))
    (bytevector-copy! bv from out 0 (- to from))
    out))

(define (iota n) (let loop ((i (- n 1)) (acc '())) (if (< i 0) acc (loop (- i 1) (cons i acc)))))

(define (take-up-to xs n)
  (if (or (null? xs) (= n 0)) '() (cons (car xs) (take-up-to (cdr xs) (- n 1)))))

(define (str . parts) (apply string-append parts))

(define (zeros n) (make-string n #\0))

;; refusal : (-> Any) -> (U 'no-raise (List 'raised Boolean Any Any Any))
;; What a raise carried: whether it is an assertion violation, its who,
;; message and irritants.
(define (raised-entry e)
  (list 'raised (assertion-violation? e)
        (and (who-condition? e) (condition-who e))
        (and (message-condition? e) (condition-message e))
        (and (irritants-condition? e) (condition-irritants e))))

(define (refusal thunk)
  (guard (e (#t (raised-entry e)))
    (thunk)
    'no-raise))

(define (refused who message . irritants) (list 'raised #t who message irritants))

(define (options-for mode limit) (make-json-options 'number-mode mode 'digit-limit limit))

(define bare-handler (make-json-handler))

;; stop-code : json-stop -> Symbol
;; The code a parse ends with when its number-end returns STOP.
(define (stop-code stop)
  (let ((p (make-json-parser (make-json-handler 'number-end (lambda (c) stop)) #f)))
    (json-parser-feed! p (bytes "0") 0 1)
    (json-result-code (json-parser-finish! p))))

;; taken : (U Real json-number json-stop) -> Outcome
;; Outcome = (number V) | (json-number TEXT) | (stop CODE) | (raised ...)
(define (taken n)
  (cond ((json-stop? n) (list 'stop (stop-code n)))
        ((json-number? n) (list 'json-number (json-number-text n)))
        (else (list 'number n))))

;; give! : json-assembler String -> Unit
;; PART as the range of a bytevector with digits on both sides, which the
;; assembler must neither keep nor count.
(define (give! a part)
  (let ((bv (bytes "77" part "77")))
    (json-assembler-number-chars! a bv 2 (- (bytevector-length bv) 2))))

;; assemble-with : json-assembler (Listof String) -> Outcome
;; Gives A the parts in turn and takes the number.
(define (assemble-with a parts)
  (guard (e (#t (raised-entry e)))
    (for-each (lambda (p) (give! a p)) parts)
    (taken (json-assembler-number! a))))

;; assemble : Mode Limit (Listof String) -> Outcome
;; assemble-with a fresh assembler under MODE and LIMIT.
(define (assemble mode limit parts)
  (assemble-with (make-json-assembler (options-for mode limit)) parts))

;; outcomes : Mode Limit (Listof String) -> (Listof (List String Outcome))
;; Each text in one part, beside its outcome.
(define (outcomes mode limit texts)
  (map (lambda (t) (list t (assemble mode limit (list t)))) texts))

;; --- the oracle -----------------------------------------------------------------

(define (digit-char? c) (and (char<=? #\0 c) (char<=? c #\9)))

;; digits-value : String -> Nat
(define (digits-value s)
  (let loop ((i 0) (v 0))
    (if (= i (string-length s))
        v
        (loop (+ i 1) (+ (* v 10) (- (char->integer (string-ref s i)) 48))))))

;; anatomy : String -> (List Boolean String (U String #f) Boolean (U String #f))
;; A JSON number's parts: whether it is negative, its integer digits, its
;; fraction digits, whether its exponent is negative, and its exponent
;; digits; #f for a fraction or an exponent it lacks. Raises for any text
;; but a number: the oracle is misused.
(define (anatomy text)
  (let* ((n (string-length text))
         (at (lambda (i) (and (< i n) (string-ref text i))))
         (run-end (lambda (i)
                    (let loop ((j i))
                      (if (and (< j n) (digit-char? (string-ref text j))) (loop (+ j 1)) j))))
         (neg (eqv? (at 0) #\-))
         (i0 (if neg 1 0))
         (i1 (run-end i0))
         (has-frac (eqv? (at i1) #\.))
         (i2 (if has-frac (run-end (+ i1 1)) i1))
         (has-exp (and (memv (at i2) '(#\e #\E)) #t))
         (sign-at (+ i2 1))
         (eneg (and has-exp (eqv? (at sign-at) #\-)))
         (i3 (if (and has-exp (memv (at sign-at) '(#\+ #\-))) (+ sign-at 1) sign-at))
         (i4 (if has-exp (run-end i3) i2)))
    (unless (and (= i4 n) (> i1 i0)
                 (or (not has-frac) (> i2 (+ i1 1)))
                 (or (not has-exp) (> i4 i3)))
      (assertion-violation 'anatomy "not a number the oracle reads" text))
    (list neg
          (substring text i0 i1)
          (and has-frac (substring text (+ i1 1) i2))
          eneg
          (and has-exp (substring text i3 i4)))))

(define (decimal-length n) (string-length (number->string n)))

;; expected-number : String Mode Limit -> Outcome
;; What the assembler must make of TEXT, a JSON number.
(define (expected-number text mode limit)
  (if (eq? mode 'text)
      (list 'json-number text)
      (let* ((a (anatomy text))
             (neg (list-ref a 0))
             (frac (or (list-ref a 2) ""))
             (exp-digits (or (list-ref a 4) ""))
             (sig-digits (string-append (list-ref a 1) frac))
             (sig (digits-value sig-digits))
             (e (* (if (list-ref a 3) -1 1) (digits-value exp-digits)))
             (scale (- e (string-length frac)))
             (signed (lambda (v) (if neg (- v) v))))
        (cond
         ((> (+ (string-length sig-digits) (string-length exp-digits)) limit)
          '(stop number-too-long))
         ((eq? mode 'exact)
          (if (> (+ (string-length sig-digits) (abs e)) limit)
              '(stop number-out-of-range)
              (list 'number (signed (* sig (expt 10 scale))))))
         ((not (or (list-ref a 2) (list-ref a 4))) (list 'number (signed sig)))
         ((= sig 0) (list 'number (if neg -0.0 0.0)))
         (else
          ;; The value lies in [10^(m-1), 10^m), m = MAGNITUDE. At m - 1 >= 309
          ;; it passes the largest flonum, about 1.8e308; at m <= -324 it is
          ;; under half the smallest, about 2.5e-324, and rounds to zero.
          (let ((magnitude (+ scale (decimal-length sig))))
            (cond ((>= (- magnitude 1) 309) '(stop number-out-of-range))
                  ((<= magnitude -324) (list 'number (if neg -0.0 0.0)))
                  (else
                   (let ((x (inexact (signed (* sig (expt 10 scale))))))
                     (if (infinite? x) '(stop number-out-of-range) (list 'number x)))))))))))

;; --- views ----------------------------------------------------------------------

(define (result-entry? x) (and (pair? x) (memq (car x) '(feed finish)) #t))

(define (number-entry? x)
  (or (eq? x 'stop) (and (pair? x) (memq (car x) '(number json-number)) #t)))

(define (last-result trace)
  (fold-left (lambda (r x) (if (result-entry? x) x r)) #f trace))

;; actual-view : Trace -> View
;; A run-assembler trace's numbers, stops and results, in order.
(define (actual-view trace) (filter (lambda (x) (or (result-entry? x) (number-entry? x))) trace))

;; outcome-view : Trace -> View
;; TRACE's entries but its results, then its last result: what no schedule
;; may change.
(define (outcome-view trace)
  (append (filter (lambda (x) (not (result-entry? x))) trace) (list (last-result trace))))

;; number-end-offsets : Bytevector -> (Listof Nat)
;; The offset of the byte each of the reference's number-ends fires at,
;; from a run in 1-byte feeds: the feeds answered before it. One that fires
;; at finish is at the input's length.
(define (number-end-offsets bv)
  (let loop ((xs (run-machine generated-machine (chunk-schedule bv 1) '())) (fed 0) (acc '()))
    (cond ((null? xs) (reverse acc))
          ((eq? (car xs) 'number-end) (loop (cdr xs) fed (cons fed acc)))
          ((and (pair? (car xs)) (eq? (caar xs) 'feed)) (loop (cdr xs) (+ fed 1) acc))
          (else (loop (cdr xs) fed acc)))))

;; expected-view : Trace (Listof Nat) Mode Limit -> View
;; What actual-view must give for the schedule whose reference trace, in
;; the parser's terms, is REFERENCE: its results, and each number the
;; oracle makes of its bytes. A stop ends the view with an error result at
;; the stop's offset in ENDS, from the feed or the finish it fired in.
(define (expected-view reference ends mode limit)
  (let loop ((xs reference) (ends ends) (parts '()) (acc '()))
    (if (null? xs)
        (reverse acc)
        (let ((x (car xs)))
          (cond
           ((result-entry? x) (loop (cdr xs) ends parts (cons x acc)))
           ((eq? x 'number-end)
            (let ((e (expected-number (utf8->string (apply cat (reverse parts))) mode limit)))
              (if (eq? (car e) 'stop)
                  (reverse (cons (list (car (find result-entry? (cdr xs))) 'error (cadr e) (car ends))
                                 (cons 'stop acc)))
                  (loop (cdr xs) (cdr ends) '() (cons e acc)))))
           ((and (pair? x) (eq? (car x) 'number-chars))
            (loop (cdr xs) ends (cons (cadr x) parts) acc))
           (else (loop (cdr xs) ends parts acc)))))))

(define modes '(flonum exact text))

(define (feeds-of schedule) (map (lambda (f) (list (cadr f) (caddr f))) schedule))

;; reach-key : Mode Entry -> (U Symbol #f)
;; What kind of outcome an expected entry is, for the tallies.
(define (reach-key mode x)
  (cond
   ((result-entry? x)
    (and (eq? (cadr x) 'error) (memq (caddr x) '(number-too-long number-out-of-range))
         (string->symbol (str (symbol->string mode) "-" (symbol->string (caddr x))))))
   ((not (pair? x)) #f)
   ((eq? (car x) 'json-number) 'text)
   ((eq? (car x) 'number)
    (let ((v (cadr x)))
      (case mode
        ((flonum) (cond ((exact? v) 'flonum-integer)
                        ((and (zero? v) (eqv? v -0.0)) 'flonum-negative-zero)
                        ((zero? v) 'flonum-zero)
                        (else 'flonum-real)))
        (else (if (integer? v) 'exact-integer 'exact-ratio)))))
   (else #f)))

(define (note-reach! tally mode view)
  (for-each (lambda (x) (let ((k (reach-key mode x))) (when k (tally! tally k)))) view))

(define (count-of tally key) (let ((p (assq key (tally-counts tally)))) (if p (cdr p) 0)))

;; views-differ : Tally Schedule (Listof Nat) (Listof Limit) -> (U #f Evidence)
;; #f when, in every mode under every limit, the assembler gives what the
;; reference and the oracle make of SCHEDULE.
(define (views-differ tally schedule ends limits)
  (let ((reference (machine->parser (run-machine generated-machine schedule '()))))
    (let loop ((cases (apply append (map (lambda (m) (map (lambda (l) (cons m l)) limits)) modes))))
      (if (null? cases)
          #f
          (let* ((mode (caar cases)) (limit (cdar cases))
                 (expected (guard (e (#t (list 'oracle-raised (describe e))))
                             (expected-view reference ends mode limit)))
                 (actual (guard (e (#t (list 'raised (describe e))))
                           (actual-view (run-assembler schedule (options-for mode limit))))))
            (note-reach! tally mode expected)
            (if (equal? expected actual)
                (loop (cdr cases))
                (list 'mode mode 'limit limit 'feeds (feeds-of schedule)
                      'expected expected 'actual actual)))))))

;; --- 1. the corpus lanes --------------------------------------------------------

(define (files-in dir)
  (map (lambda (n) (cons (string-append dir "/" n) (file-bytes (string-append dir "/" n))))
       (corpus-files dir ".json")))

(define (has-number? bv)
  (exists (lambda (x) (and (pair? x) (eq? (car x) 'number)))
          (run-machine generated-machine (whole-schedule bv) '())))

;; number-files : (Listof (Pair String Bytevector)), every JSONTestSuite file
;; and yajl case in which the reference meets a number.
(define number-files
  (filter (lambda (f) (has-number? (cdr f)))
          (append (files-in "tests/corpus/jsontestsuite/test_parsing")
                  (files-in "tests/corpus/yajl/cases"))))

(define lane-limits '(1000 3))

(define corpus-tally (make-tally))

;; lane : String (Listof (Pair String (Listof Schedule))) -> (List Nat Nat (Listof Failure))
;; Runs views-differ on every file's schedules: the runs, the failures, and
;; the first three.
(define (lane label work)
  (let loop ((work work) (ran 0) (failed 0) (found '()))
    (if (null? work)
        (begin
          (put-string (current-output-port)
                      (str "number: " label ": " (number->string ran) " runs, "
                           (number->string failed) " failing\n"))
          (list ran failed (reverse found)))
        (let* ((name (caar work))
               (ends (number-end-offsets (cdr (assoc name number-files)))))
          (let each ((schedules (cdar work)) (ran ran) (failed failed) (found found))
            (if (null? schedules)
                (loop (cdr work) ran failed found)
                (let ((evidence (views-differ corpus-tally (car schedules) ends lane-limits)))
                  (cond
                   ((not evidence) (each (cdr schedules) (+ ran 1) failed found))
                   ((< (length found) 3)
                    (each (cdr schedules) (+ ran 1) (+ failed 1) (cons (cons name evidence) found)))
                   (else (each (cdr schedules) (+ ran 1) (+ failed 1) found))))))))))

(define chunk-sizes '(1 2 3 5 7 13 64))

(define split-at-most 64)

(define randoms-per-file 48)

;; schedules-expected : Nat -> Nat
;; What schedules-for gives for L bytes: L+1 splits, (L+1)(L+2)/2 pairs, and
;; 10 others.
(define (schedules-expected len)
  (+ (+ len 1) (div (* (+ len 1) (+ len 2)) 2) 10))

(define short-files (filter (lambda (f) (<= (bytevector-length (cdr f)) split-at-most)) number-files))

(define long-files (filter (lambda (f) (> (bytevector-length (cdr f)) split-at-most)) number-files))

(define chunk-work
  (map (lambda (f)
         (cons (car f) (cons (whole-schedule (cdr f))
                             (map (lambda (k) (chunk-schedule (cdr f) k)) chunk-sizes))))
       number-files))

;; Drawn from one prng, threaded through the short files in order.
(define split-work
  (let loop ((fs short-files) (state (make-prng (property-run-seed run))) (acc '()))
    (if (null? fs)
        (reverse acc)
        (call-with-values (lambda () (schedules-for (cdar fs) state))
          (lambda (schedules state)
            (loop (cdr fs) state (cons (cons (caar fs) schedules) acc)))))))

;; File I's schedules are drawn from (case-state seed 1 I), one after another.
(define random-work
  (map (lambda (f i)
         (cons (car f)
               (let loop ((k 0) (s (case-state (property-run-seed run) 1 i)) (acc '()))
                 (if (= k randoms-per-file)
                     (reverse acc)
                     (let ((drawn (random-schedule (cdr f) s)))
                       (loop (+ k 1) (cdr drawn) (cons (car drawn) acc)))))))
       long-files
       (iota (length long-files))))

;; --- 1. the property: generated numbers -------------------------------------------
;;
;; A case is (DOC LIMIT STATE): a small document holding two generated
;; numbers, a digit limit, and the state DOC's random schedule is drawn
;; from. The numbers have a sign or none, an integer part of 0 or of up to
;; 40 digits, a fraction or none, and an exponent or none, with e or E,
;; +, - or no sign, and up to 4 digits or a value near the flonum range's
;; ends. Every mode must give what the reference and the oracle make of
;; it, in one feed and under the random schedule.

(define (g-string-of n g)
  (lambda (s)
    (draw* s ((cs (g-list n g))) (cons (list->string cs) s))))

(define g-digit (g-pick (string->list "00123456789")))

(define g-nonzero (g-pick (string->list "123456789")))

(define g-length (g-choose (list (cons 6 (g-range 1 3)) (cons 3 (g-range 4 17)) (cons 1 (g-range 18 40)))))

;; g-digits : Gen String, a run of digits; NONZERO-FIRST for an integer part.
(define (g-digits nonzero-first)
  (lambda (s)
    (draw* s ((n g-length) (first (if nonzero-first g-nonzero g-digit))
              (rest (g-string-of (- n 1) g-digit)))
      (cons (str (string first) rest) s))))

(define g-exponent-digits
  (g-choose (list (cons 3 (lambda (s) (draw* s ((n (g-range 1 4)) (d (g-string-of n g-digit))) (cons d s))))
                  (cons 2 (lambda (s)
                            (draw* s ((v (g-choose (list (cons 1 (g-range 280 330)) (cons 1 (g-range 300 345)))))
                                      (pad (g-range 0 2)))
                              (cons (str (zeros pad) (number->string v)) s)))))))

(define g-number
  (lambda (s)
    (draw* s ((neg (g-chance 1 3))
              (int (g-choose (list (cons 1 (g-const "0")) (cons 3 (g-digits #t)))))
              (frac? (g-chance 1 2))
              (frac (g-digits #f))
              (exp? (g-chance 1 2))
              (e (g-pick '("e" "E")))
              (sign (g-pick '("" "+" "-")))
              (exp g-exponent-digits))
      (cons (str (if neg "-" "") int (if frac? (str "." frac) "") (if exp? (str e sign exp) ""))
            s))))

(define wrappers
  (list (lambda (a b) a)
        (lambda (a b) (str " " a "\n"))
        (lambda (a b) (str "[" a "]"))
        (lambda (a b) (str "[" a "," b "]"))
        (lambda (a b) (str "{\"k\":" a ",\"j\":[" b "]}"))))

(define property-limits '(1000 1000 1000 1 2 3 4 6 10 20 40))

(define (gen-number-group s)
  (let loop ((k 0) (s s) (acc '()))
    (if (= k 5)
        (reverse acc)
        (draw* s ((a g-number) (b g-number) (wrap (g-pick wrappers))
                  (limit (g-pick property-limits)) (st (g-int 32768)))
          (loop (+ k 1) s (cons (list (wrap a b) limit st) acc))))))

(define property-tally (make-tally))

(define (number-check kase)
  (let* ((bv (string->utf8 (car kase)))
         (ends (number-end-offsets bv))
         (limits (list (cadr kase))))
    (or (views-differ property-tally (whole-schedule bv) ends limits)
        (views-differ property-tally (car (random-schedule bv (caddr kase))) ends limits))))

;; A case shrinks by its limit back to the default.
(define (number-shrinks kase)
  (if (= (cadr kase) 1000) '() (list (list (car kase) 1000 (caddr kase)))))

;; --- 7. the grammar differential --------------------------------------------------

;; With / and :, the bytes on either side of the digits, 47 and 58.
(define alphabet (string->list "-+.eE019/:"))

;; strings-of-length : Nat -> (Listof String), every string of N characters
;; from the alphabet.
(define (strings-of-length n)
  (if (= n 0)
      '("")
      (apply append (map (lambda (s) (map (lambda (c) (str (string c) s)) alphabet))
                         (strings-of-length (- n 1))))))

;; parser-accepts? : String -> Boolean
;; Whether (jsonparse parser) accepts TEXT as a whole document.
(define (parser-accepts? text)
  (let* ((bv (string->utf8 text))
         (p (make-json-parser bare-handler #f))
         (r (json-parser-feed! p bv 0 (bytevector-length bv))))
    (eq? 'finished
         (json-result-status (if (eq? (json-result-status r) 'need-input) (json-parser-finish! p) r)))))

;; verdicts : String -> (List Boolean Boolean Boolean)
;; The parser's verdict on TEXT, make-json-number's, and a text-mode
;; assembler's: whether each takes it, the last two keeping its text.
(define (verdicts text)
  (let* ((parser (parser-accepts? text))
         (record (guard (e (#t #f)) (string=? text (json-number-text (make-json-number text)))))
         (assembler (equal? (assemble 'text 1 (list text)) (list 'json-number text))))
    (list parser record assembler)))

(define (grammar-check text)
  (let ((v (verdicts text)))
    (and (not (and (eq? (car v) (cadr v)) (eq? (car v) (caddr v))))
         (list 'text text 'parser-record-assembler v))))

(define (g-alphabet-string n) (g-string-of n (g-pick alphabet)))

;; A longer case: a string of 5 to 16 characters from the alphabet, or a
;; generated number with one character replaced, inserted or deleted, or
;; none.
(define g-mutated-number
  (lambda (s)
    (draw* s ((n g-number) (kind (g-int 4)) (c (g-pick alphabet)))
      (let ((len (string-length n)))
        (draw* s ((i (g-int len)))
          (cons (case kind
                  ((0) n)
                  ((1) (str (substring n 0 i) (string c) (substring n (+ i 1) len)))
                  ((2) (str (substring n 0 i) (string c) (substring n i len)))
                  (else (str (substring n 0 i) (substring n (+ i 1) len))))
                s))))))

(define (gen-grammar-group s)
  (draw* s ((a (lambda (s) (draw* s ((n (g-range 5 16)) (t (g-alphabet-string n))) (cons t s))))
            (b g-mutated-number)
            (c g-mutated-number))
    (list a b c)))

(define (string-shrinks text)
  (map (lambda (i) (str (substring text 0 i) (substring text (+ i 1) (string-length text))))
       (iota (string-length text))))

(test-begin "number")

;; ============ 1. The oracle lanes ===============================================

(let ((r (lane "corpus whole and chunks" chunk-work)))
  (test-equal "ADR-0016: every corpus number, whole and in chunks of 1, 2, 3, 5, 7, 13 and 64, in all three modes under limits 1000 and 3: the oracle's values and stops"
    (list 'runs (* (length number-files) (+ 1 (length chunk-sizes))) 'failures 0 '())
    (list 'runs (car r) 'failures (cadr r) (caddr r))))

(let ((r (lane "corpus splits" split-work)))
  (test-equal "ADR-0016: every corpus number in a file of at most 64 bytes, under every split, every pair of splits and schedules-for's others, in all three modes under limits 1000 and 3"
    (list 'runs (fold-left + 0 (map (lambda (f) (schedules-expected (bytevector-length (cdr f))))
                                    short-files))
          'failures 0 '())
    (list 'runs (car r) 'failures (cadr r) (caddr r))))

(let ((r (lane "corpus randoms" random-work)))
  (test-equal "ADR-0016: every corpus number in a longer file, under 48 random schedules, in all three modes under limits 1000 and 3"
    (list 'runs (* (length long-files) randoms-per-file) 'failures 0 '())
    (list 'runs (car r) 'failures (cadr r) (caddr r))))

(test-equal "the corpus lanes met 79 files, 4 of them over 64 bytes"
  '(79 4) (list (length number-files) (length long-files)))

;; Read from the expected views, which come from the reference and the
;; oracle: the lanes checked each kind of outcome.
(test-equal "the corpus lanes expected each kind of outcome: flonum integers, reals, zeros and both stops; exact integers, ratios and both stops; text"
  '()
  (filter (lambda (k) (= (count-of corpus-tally k) 0))
          '(flonum-integer flonum-real flonum-zero flonum-number-too-long flonum-number-out-of-range
            exact-integer exact-ratio exact-number-too-long exact-number-out-of-range text)))

(test-equal "ADR-0016: generated numbers in small documents, under random schedules and limits, in all three modes: the oracle's values and stops"
  '()
  (property-failures run 'generated-numbers 2 400 gen-number-group number-check number-shrinks
                     property-tally))

(test-equal "the property expected each kind of outcome, negative zero included"
  '()
  (filter (lambda (k) (= (count-of property-tally k) 0))
          '(flonum-integer flonum-real flonum-zero flonum-negative-zero flonum-number-too-long
            flonum-number-out-of-range exact-integer exact-ratio exact-number-too-long
            exact-number-out-of-range text)))

;; ============ 2. ADR-0011's pinned values =========================================

(define pinned-texts
  '("1e400" "-1e400" "1e-400" "-1e-400" "-0" "-0.0" "1.5" "1e2" "1.0"
    "1.7976931348623157e308" "1.7976931348623159e308" "5e-324" "2.4703282292062327e-324"
    "9007199254740993" "9007199254740993.0"))

;; The largest flonum is (2^53 - 1) x 2^971; the smallest above zero 2^-1074,
;; about 4.94e-324. 1.7976931348623159e308 is past the largest by more than
;; half its spacing of 2^971, and 2.4703282292062327e-324 is under half
;; the smallest, 2^-1075 = 2.47032822920623272...e-324. 2^53 + 1 is a tie,
;; which rounds to the even 2^53.
(test-equal "ADR-0011: flonum: 1e400 out of range, 1e-400 0.0 and -1e-400 -0.0, -0 exact 0, -0.0 -0.0, 1.5 1e2 1.0 flonums, the largest flonum and one past it, the smallest and one under half of it, 2^53+1 exact and with .0 rounded to 2^53"
  (list (list "1e400" '(stop number-out-of-range))
        (list "-1e400" '(stop number-out-of-range))
        (list "1e-400" (list 'number 0.0))
        (list "-1e-400" (list 'number -0.0))
        (list "-0" (list 'number 0))
        (list "-0.0" (list 'number -0.0))
        (list "1.5" (list 'number (inexact 3/2)))
        (list "1e2" (list 'number (inexact 100)))
        (list "1.0" (list 'number (inexact 1)))
        (list "1.7976931348623157e308" (list 'number (inexact (* (- (expt 2 53) 1) (expt 2 971)))))
        (list "1.7976931348623159e308" '(stop number-out-of-range))
        (list "5e-324" (list 'number (inexact (expt 2 -1074))))
        (list "2.4703282292062327e-324" (list 'number 0.0))
        (list "9007199254740993" (list 'number 9007199254740993))
        (list "9007199254740993.0" (list 'number (inexact (expt 2 53)))))
  (outcomes 'flonum 1000 pinned-texts))

(test-equal "ADR-0011: exact: every pinned value exact, -0 and -0.0 0, 1.5 3/2, 1e2 100, 1.0 1"
  (list (list "1e400" (list 'number (expt 10 400)))
        (list "-1e400" (list 'number (- (expt 10 400))))
        (list "1e-400" (list 'number (/ 1 (expt 10 400))))
        (list "-1e-400" (list 'number (/ -1 (expt 10 400))))
        (list "-0" (list 'number 0))
        (list "-0.0" (list 'number 0))
        (list "1.5" (list 'number 3/2))
        (list "1e2" (list 'number 100))
        (list "1.0" (list 'number 1))
        (list "1.7976931348623157e308" (list 'number (* 17976931348623157 (expt 10 292))))
        (list "1.7976931348623159e308" (list 'number (* 17976931348623159 (expt 10 292))))
        (list "5e-324" (list 'number (/ 5 (expt 10 324))))
        (list "2.4703282292062327e-324" (list 'number (/ 24703282292062327 (expt 10 340))))
        (list "9007199254740993" (list 'number 9007199254740993))
        (list "9007199254740993.0" (list 'number 9007199254740993)))
  (outcomes 'exact 1000 pinned-texts))

(test-equal "ADR-0011: text: every pinned value is a json-number of its text"
  (map (lambda (t) (list t (list 'json-number t))) pinned-texts)
  (outcomes 'text 1000 pinned-texts))

;; The range rule is exact mode's: flonum mode reads these by their value.
(test-equal "ADR-0011: flonum: 1e999 and 10^309 with a fraction are out of range, but 1e-1000, 0e1000 and -0e5000 are zeros, and a plain integer of 400 digits is exact"
  (list (list "1e999" '(stop number-out-of-range))
        (list (str "1" (zeros 309) ".0") '(stop number-out-of-range))
        (list "1e-1000" (list 'number 0.0))
        (list "0e1000" (list 'number 0.0))
        (list "-0e5000" (list 'number -0.0))
        (list (str "1" (zeros 399)) (list 'number (expt 10 399))))
  (outcomes 'flonum 1000 (list "1e999" (str "1" (zeros 309) ".0") "1e-1000" "0e1000" "-0e5000"
                               (str "1" (zeros 399)))))

;; ============ 3. The digit limit's boundary =======================================

;; bracketed-view : String Mode Limit (U Nat #f) -> View
;; The outcome of [TEXT], whole or in chunks of K.
(define (bracketed-view text mode limit k)
  (let* ((bv (bytes "[" text "]"))
         (schedule (if k (chunk-schedule bv k) (whole-schedule bv))))
    (outcome-view (run-assembler schedule (options-for mode limit)))))

(define (bracketed-accepted text entry)
  (list 'array-start entry 'array-end (list 'finish 'finished #f (+ (string-length text) 2))))

(define (bracketed-refused text code)
  (list 'array-start 'stop (list 'feed 'error code (+ (string-length text) 1))))

;; in-brackets : String Mode Limit -> (List View View)
;; [TEXT] whole and in chunks of 7.
(define (in-brackets text mode limit)
  (list (bracketed-view text mode limit #f) (bracketed-view text mode limit 7)))

(define (twice x) (list x x))

;; 1,000 digits in each place, and 1,001.
(define int-1000 (str "1" (zeros 999)))
(define int-1001 (str "1" (zeros 1000)))
(define frac-1000 (str "0.5" (zeros 998)))
(define frac-1001 (str "0.5" (zeros 999)))
(define exp-1000 (str "1e" (zeros 998) "2"))
(define exp-1001 (str "1e" (zeros 999) "2"))
;; 333 integer digits, 333 in the fraction and 334 in the exponent, with
;; a sign, a point, an E and the exponent's sign: 1,000 digits, 1,004
;; bytes. Its value is (10^332 + 1/2) x 10^-330.
(define spread-1000 (str "-1" (zeros 332) ".5" (zeros 332) "E-" (zeros 331) "330"))
(define spread-1001 (str "-1" (zeros 332) ".5" (zeros 332) "E-" (zeros 332) "330"))
(define spread-value (- (+ 100 (/ 1 (* 2 (expt 10 330))))))

(test-equal "ADR-0011: flonum: 1,000 digits are accepted in the integer part, the fraction, the exponent, and spread across them with a sign, a point, an E and an exponent sign"
  (list (twice (bracketed-accepted int-1000 (list 'number (expt 10 999))))
        (twice (bracketed-accepted frac-1000 (list 'number 0.5)))
        (twice (bracketed-accepted exp-1000 (list 'number 100.0)))
        (twice (bracketed-accepted spread-1000 (list 'number -100.0))))
  (list (in-brackets int-1000 'flonum 1000) (in-brackets frac-1000 'flonum 1000)
        (in-brackets exp-1000 'flonum 1000) (in-brackets spread-1000 'flonum 1000)))

(test-equal "ADR-0011: exact: 1,000 digits are accepted in the integer part, the fraction, the exponent, and spread across them"
  (list (twice (bracketed-accepted int-1000 (list 'number (expt 10 999))))
        (twice (bracketed-accepted frac-1000 (list 'number 1/2)))
        (twice (bracketed-accepted exp-1000 (list 'number 100)))
        (twice (bracketed-accepted spread-1000 (list 'number spread-value))))
  (list (in-brackets int-1000 'exact 1000) (in-brackets frac-1000 'exact 1000)
        (in-brackets exp-1000 'exact 1000) (in-brackets spread-1000 'exact 1000)))

(test-equal "ADR-0011: flonum: 1,001 digits are number-too-long in the integer part, the fraction, the exponent, and spread across them"
  (map (lambda (t) (twice (bracketed-refused t 'number-too-long)))
       (list int-1001 frac-1001 exp-1001 spread-1001))
  (map (lambda (t) (in-brackets t 'flonum 1000)) (list int-1001 frac-1001 exp-1001 spread-1001)))

(test-equal "ADR-0011: exact: 1,001 digits are number-too-long in the integer part, the fraction, the exponent, and spread across them"
  (map (lambda (t) (twice (bracketed-refused t 'number-too-long)))
       (list int-1001 frac-1001 exp-1001 spread-1001))
  (map (lambda (t) (in-brackets t 'exact 1000)) (list int-1001 frac-1001 exp-1001 spread-1001)))

(test-equal "ADR-0011: text: 1,001 digits are a json-number of the text, in each place"
  (map (lambda (t) (twice (bracketed-accepted t (list 'json-number t))))
       (list int-1001 frac-1001 exp-1001 spread-1001))
  (map (lambda (t) (in-brackets t 'text 1000)) (list int-1001 frac-1001 exp-1001 spread-1001)))

;; A million and one digits: the text is compared whole, and shown by its
;; length.
(define huge (str "1" (zeros 1000000)))

(define (huge-view text mode)
  (map (lambda (x)
         (if (and (pair? x) (eq? (car x) 'json-number))
             (list 'json-number 'same-text (string=? (cadr x) text) 'length (string-length (cadr x)))
             x))
       (bracketed-view text mode 1000 #f)))

(test-equal "ADR-0011: 1,000,001 digits: a json-number of the whole text in text mode, number-too-long in flonum and exact"
  (list (list 'array-start (list 'json-number 'same-text #t 'length 1000001) 'array-end
              (list 'finish 'finished #f 1000003))
        (bracketed-refused huge 'number-too-long)
        (bracketed-refused huge 'number-too-long))
  (list (huge-view huge 'text) (huge-view huge 'flonum) (huge-view huge 'exact)))

(test-equal "ADR-0011: text mode has no limit: 12345 under a limit of 1 is its json-number"
  (twice (bracketed-accepted "12345" (list 'json-number "12345")))
  (in-brackets "12345" 'text 1))

;; small-shapes : Nat -> (Listof String)
;; Every number of N digits, from 1, 2, 3, ... in order, split between an
;; integer part of at least one digit, a fraction and an exponent of any,
;; under a minus sign or none, with e+, E- or e.
(define (small-shapes n)
  (let ((digits "123456789"))
    (apply append
           (map (lambda (a)
                  (apply append
                         (map (lambda (b)
                                (let* ((c (- n a b))
                                       (int (substring digits 0 a))
                                       (frac (substring digits a (+ a b)))
                                       (exp (substring digits (+ a b) n)))
                                  (apply append
                                         (map (lambda (sign)
                                                (map (lambda (e)
                                                       (str sign int (if (> b 0) (str "." frac) "")
                                                            (if (> c 0) (str e exp) "")))
                                                     (if (> c 0) '("e+" "E-" "e") '(""))))
                                              '("" "-")))))
                              (iota (+ (- n a) 1)))))
                (map (lambda (i) (+ i 1)) (iota n))))))

;; The sweep: under limits 1, 2 and 3, every shape of the limit's digits
;; and one more, as [TEXT] in 1-byte feeds, so a feed ends at every byte.
(define (sweep mode)
  (let loop ((cases (apply append
                           (map (lambda (limit)
                                  (map (lambda (t) (cons t limit))
                                       (append (small-shapes limit) (small-shapes (+ limit 1)))))
                                '(1 2 3))))
             (ran 0) (found '()))
    (if (null? cases)
        (list 'ran ran 'differing (take-up-to (reverse found) 3))
        (let* ((text (caar cases)) (limit (cdar cases))
               (e (expected-number text mode limit))
               (expected (if (eq? (car e) 'stop)
                             (bracketed-refused text (cadr e))
                             (bracketed-accepted text e)))
               (actual (bracketed-view text mode limit 1)))
          (loop (cdr cases) (+ ran 1)
                (if (equal? expected actual)
                    found
                    (cons (list 'text text 'limit limit 'expected expected 'actual actual) found)))))))

;; Shapes of N digits: 2 for each split with no exponent and 6 for each
;; with one. 1 digit: 2; 2: 6 + 2 + 2 = 10; 3: 3 x 6 + 3 x 2 = 24; 4: 6 x 6
;; + 4 x 2 = 44.
(define sweep-count (+ (+ 2 10) (+ 10 24) (+ 24 44)))

(test-equal "ADR-0011: flonum: limits 1, 2 and 3, the limit's digits and one more in every place, a feed ending at every byte"
  (list 'ran sweep-count 'differing '())
  (sweep 'flonum))

(test-equal "ADR-0011: exact: limits 1, 2 and 3, the limit's digits and one more in every place, a feed ending at every byte"
  (list 'ran sweep-count 'differing '())
  (sweep 'exact))

(test-equal "the sweep's shapes of 3 digits, as written"
  '("1e+23" "1E-23" "1e23" "-1e+23" "-1E-23" "-1e23"
    "1.2e+3" "1.2E-3" "1.2e3" "-1.2e+3" "-1.2E-3" "-1.2e3"
    "1.23" "-1.23"
    "12e+3" "12E-3" "12e3" "-12e+3" "-12E-3" "-12e3"
    "12.3" "-12.3"
    "123" "-123")
  (small-shapes 3))

;; Parts given to the assembler, crossing the limit of 3 in each way.
(define crossing-parts
  '(("12345")                         ; inside a part
    ("1" "2345")                      ; inside a later part
    ("12" "34")                       ; at a part's last byte
    ("123" "4")                       ; by the next part's first byte
    ("123" "." "4")                   ; past a part of non-digits
    ("-" "1" "." "2" "e" "+" "34")    ; inside the exponent's part
    ("1234" "5" "." "6" "e" "7")))    ; more parts after the limit

(define within-parts
  '(("123") ("1" "23") ("12" "3") ("12" "" "3") ("123" "") ("-" "1" "." "2" "E" "-" "3")))

(test-equal "ADR-0016: flonum, limit 3: parts crossing the limit inside a part, at its end, by the next part's first byte, and past parts of non-digits are number-too-long"
  (map (lambda (p) (list p '(stop number-too-long))) crossing-parts)
  (map (lambda (p) (list p (assemble 'flonum 3 p))) crossing-parts))

(test-equal "ADR-0016: exact, limit 3: the same parts are number-too-long"
  (map (lambda (p) (list p '(stop number-too-long))) crossing-parts)
  (map (lambda (p) (list p (assemble 'exact 3 p))) crossing-parts))

(test-equal "ADR-0016: limit 3: three digits in parts, empty parts and non-digit parts among them, are the number"
  (list (list '("123") '(number 123) '(number 123))
        (list '("1" "23") '(number 123) '(number 123))
        (list '("12" "3") '(number 123) '(number 123))
        (list '("12" "" "3") '(number 123) '(number 123))
        (list '("123" "") '(number 123) '(number 123))
        (list '("-" "1" "." "2" "E" "-" "3") (list 'number (inexact -12/10000)) '(stop number-out-of-range)))
  (map (lambda (p)
         (let* ((f (assemble 'flonum 3 p)) (x (assemble 'exact 3 p))) (list p f x)))
       within-parts))

(test-equal "ADR-0016: limit 1: one digit is the number, a second in the next part is number-too-long"
  (list '(number 5) '(number -5) '(number 0) '(stop number-too-long) '(stop number-too-long)
        '(stop number-too-long))
  (let* ((a (assemble 'exact 1 '("5")))
         (b (assemble 'exact 1 '("-" "5")))
         (c (assemble 'flonum 1 '("0")))
         (d (assemble 'flonum 1 '("5" "0")))
         (e (assemble 'exact 1 '("0" "." "5")))
         (f (assemble 'flonum 1 '("5" "e" "0"))))
    (list a b c d e f)))

;; ============ 4. exact mode's range ===============================================

(test-equal "ADR-0011: exact, limit 1000: 1e999, 1e-999, 1.5e998 and 0e999 accepted; 1e1000, 1e-1000, 1.5e999 and 0e1000 out of range; leading zeros in the exponent count by value"
  (list (list "1e999" (list 'number (expt 10 999)))
        (list "1e1000" '(stop number-out-of-range))
        (list "1e-999" (list 'number (/ 1 (expt 10 999))))
        (list "1e-1000" '(stop number-out-of-range))
        (list "1.5e998" (list 'number (* 15 (expt 10 997))))
        (list "1.5e999" '(stop number-out-of-range))
        (list "0e999" (list 'number 0))
        (list "0e1000" '(stop number-out-of-range))
        (list "1e0000000005" (list 'number 100000))
        (list "-1E+0000000999" (list 'number (- (expt 10 999))))
        (list "1e-0000001000" '(stop number-out-of-range))
        (list (str "1e" (zeros 996) "999") (list 'number (expt 10 999)))
        (list (str "1e" (zeros 995) "1000") '(stop number-out-of-range)))
  (outcomes 'exact 1000
            (list "1e999" "1e1000" "1e-999" "1e-1000" "1.5e998" "1.5e999" "0e999" "0e1000"
                  "1e0000000005" "-1E+0000000999" "1e-0000001000"
                  (str "1e" (zeros 996) "999") (str "1e" (zeros 995) "1000"))))

(test-equal "ADR-0016: exact, limit 5: the same boundaries; every significand digit counts, leading zeros too; too many digits is number-too-long even when out of range too"
  (list (list "1e4" (list 'number 10000))
        (list "1e5" '(stop number-out-of-range))
        (list "1e-4" (list 'number 1/10000))
        (list "1e-5" '(stop number-out-of-range))
        (list "1.5e3" (list 'number 1500))
        (list "1.5e4" '(stop number-out-of-range))
        (list "0e4" (list 'number 0))
        (list "0e5" '(stop number-out-of-range))
        (list "0.0e3" (list 'number 0))
        (list "0.0e4" '(stop number-out-of-range))
        (list "1e004" (list 'number 10000))
        (list "1e005" '(stop number-out-of-range))
        (list "-12.5" (list 'number -25/2))
        (list "1e00009" '(stop number-too-long)))
  (outcomes 'exact 5
            '("1e4" "1e5" "1e-4" "1e-5" "1.5e3" "1.5e4" "0e4" "0e5" "0.0e3" "0.0e4"
              "1e004" "1e005" "-12.5" "1e00009")))

(test-equal "ADR-0016: exact, limit 2: 1e1 accepted, 1e2 out of range, 12 accepted, 1.2 accepted, 1e-1 accepted"
  (list (list "1e1" '(number 10)) (list "1e2" '(stop number-out-of-range)) (list "12" '(number 12))
        (list "1.2" '(number 6/5)) (list "1e-1" '(number 1/10)))
  (outcomes 'exact 2 '("1e1" "1e2" "12" "1.2" "1e-1")))

;; Under the greatest fixnum as the limit, an exponent of 300,000 digits
;; passes the digit count, and is out of range. Its value is never built:
;; building it takes seconds.
(test-equal "ADR-0016: exact, limit the greatest fixnum: an exponent of 300,000 nines is out of range, in under a second"
  '((stop number-out-of-range) under-a-second #t)
  (let* ((text (str "1e" (make-string 300000 #\9)))
         (t0 (cpu-time))
         (r (assemble 'exact (greatest-fixnum) (list text)))
         (t1 (cpu-time)))
    (list r 'under-a-second (< (- t1 t0) 1000))))

;; ============ 5. Stops through the parser ==========================================

;; every-schedule : Bytevector -> (Listof Schedule)
;; Whole, in chunks of 1, 2, 3, 5 and 64, and every schedule schedules-for
;; gives.
(define (every-schedule bv)
  (append (list (whole-schedule bv))
          (map (lambda (k) (chunk-schedule bv k)) '(1 2 3 5 64))
          (call-with-values (lambda () (schedules-for bv (make-prng (property-run-seed run))))
            (lambda (schedules state) schedules))))

;; views-under-every-schedule : String Mode Limit -> (List Nat (Listof View))
;; How many schedules ran, and the distinct outcome views they gave.
(define (views-under-every-schedule text mode limit)
  (let ((schedules (every-schedule (bytes text))))
    (list (length schedules)
          (fold-left (lambda (seen s)
                       (let ((v (guard (e (#t (list 'raised (describe e))))
                                  (outcome-view (run-assembler s (options-for mode limit))))))
                         (if (member v seen) seen (append seen (list v)))))
                     '()
                     schedules))))

(define (schedule-count text) (+ 6 (schedules-expected (bytevector-length (bytes text)))))

(define (stop-cases mode)
  (list
   ;; number-too-long under a limit of 3
   (list "12345" 3 '(stop (finish error number-too-long 5)))
   (list "12345 " 3 '(stop (feed error number-too-long 5)))
   (list "[1, 12345, 2]" 3 '(array-start (number 1) stop (feed error number-too-long 9)))
   (list "{\"a\":[7,{\"b\":-1.25e+3}]}" 3
         '(object-start (key "a") array-start (number 7) object-start (key "b") stop
           (feed error number-too-long 21)))
   (list "[12345" 3 '(array-start stop (finish error number-too-long 6)))
   ;; number-out-of-range
   (if (eq? mode 'flonum)
       (list "1e400" 1000 '(stop (finish error number-out-of-range 5)))
       (list "1e1000" 1000 '(stop (finish error number-out-of-range 6))))
   (if (eq? mode 'flonum)
       (list "[1.5,-1e400,2]" 1000 '(array-start (number 1.5) stop (feed error number-out-of-range 11)))
       (list "[2,1e1000]" 1000 '(array-start (number 2) stop (feed error number-out-of-range 9))))
   (if (eq? mode 'flonum)
       (list "{\"a\":[0.5,{\"b\":1.7976931348623159e308}]}" 1000
             '(object-start (key "a") array-start (number 0.5) object-start (key "b") stop
               (feed error number-out-of-range 37)))
       (list "{\"a\":[1.5,{\"b\":1e3}]}" 3
             '(object-start (key "a") array-start (number 3/2) object-start (key "b") stop
               (feed error number-out-of-range 18))))))

(for-each
 (lambda (mode)
   (for-each
    (lambda (c)
      (let ((text (car c)) (limit (cadr c)) (expected (caddr c)))
        (test-equal (str "ADR-0015: " (symbol->string mode) ", limit " (number->string limit) ": "
                         text ": the values before the stop, and its code and offset, under every schedule")
          (list (schedule-count text) (list expected))
          (views-under-every-schedule text mode limit))))
    (stop-cases mode)))
 '(flonum exact))

(test-equal "ADR-0011: text, limit 3: the same documents have no stop"
  (list (list (schedule-count "[1, 12345, 2]")
              '((array-start (json-number "1") (json-number "12345") (json-number "2") array-end
                 (finish finished #f 13))))
        (list (schedule-count "[1.5,-1e400,2]")
              '((array-start (json-number "1.5") (json-number "-1e400") (json-number "2") array-end
                 (finish finished #f 14)))))
  (list (views-under-every-schedule "[1, 12345, 2]" 'text 3)
        (views-under-every-schedule "[1.5,-1e400,2]" 'text 3)))

;; A parser whose context is (vector ASSEMBLER LOG), its handler noting
;; each number in LOG, newest first.
(define number-handler
  (make-json-handler
   'number-chars (lambda (c bv s e) (json-assembler-number-chars! (vector-ref c 0) bv s e))
   'number-end (lambda (c)
                 (let ((n (json-assembler-number! (vector-ref c 0))))
                   (vector-set! c 1 (cons (if (json-stop? n) 'stop (list 'number n)) (vector-ref c 1)))
                   n))))

(define (result->list r)
  (list (json-result-status r) (json-result-code r) (json-result-offset r)))

;; parse! : json-parser (Listof String) -> Result-List
;; Each text in a feed of its own, then a finish, until a result is not
;; need-input: the last result.
(define (parse! p texts)
  (if (null? texts)
      (result->list (json-parser-finish! p))
      (let* ((bv (bytes (car texts)))
             (r (json-parser-feed! p bv 0 (bytevector-length bv))))
        (if (eq? (json-result-status r) 'need-input)
            (parse! p (cdr texts))
            (result->list r)))))

;; reset-scenario : (Listof String) Boolean (Listof String) -> List
;; Parses the feeds FIRST under a limit of 3, resets the parser, and the
;; assembler when RESET-ASSEMBLER?, then parses the feeds SECOND: each
;; one's numbers and last result.
;;
;; A number's bytes reach number-chars at the end of its feed, or of its
;; span. An error inside a number keeps the bytes its feed read of it from
;; number-chars, so a number is left half-built only by a feed that ends
;; inside it, and an error in a later feed.
(define (reset-scenario first reset-assembler? second)
  (let* ((c (vector (make-json-assembler (options-for 'flonum 3)) '()))
         (p (make-json-parser number-handler c))
         (r1 (parse! p first))
         (log1 (reverse (vector-ref c 1))))
    (json-parser-reset! p)
    (when reset-assembler? (json-assembler-reset! (vector-ref c 0)))
    (vector-set! c 1 '())
    (let ((r2 (parse! p second)))
      (list log1 r1 (reverse (vector-ref c 1)) r2))))

(test-equal "ADR-0015: after a stop, resetting the parser and the assembler: the next document parses"
  '(((number 1) stop) (error number-too-long 8) ((number 123) (number 4.5)) (finished #f 9))
  (reset-scenario '("[1,12345]") #t '("[123,4.5]")))

(test-equal "ADR-0016: an error inside a number past the limit leaves a count; resetting both, the next number of 3 digits is accepted"
  '(() (error invalid-number 6) ((number 123)) (finished #f 5))
  (reset-scenario '("[1234" ".x") #t '("[123]")))

(test-equal "ADR-0016: an error inside a number leaves its text; resetting both, the next number is its own"
  '(() (error invalid-number 4) ((number 7)) (finished #f 3))
  (reset-scenario '("[12" ".x") #t '("[7]")))

;; The two before have teeth: a parser reset does not reach the assembler.
(test-equal "ADR-0015: without the assembler's reset, the count left behind refuses the next number, and the text left behind joins it"
  (list '(() (error invalid-number 6) (stop) (error number-too-long 4))
        ;; "[12" gave number-chars "12"; ".x" kept its "." back with the error.
        (list '() '(error invalid-number 4) '((number 127)) '(finished #f 3)))
  (list (reset-scenario '("[1234" ".x") #f '("[123]"))
        (reset-scenario '("[12" ".x") #f '("[7]"))))

;; ============ 6. json-assembler-number! directly ===================================

;; digit-edges : (Listof String)
;; / and :, the bytes just outside 0 to 9, where each part of a number
;; reads a digit: the integer part's first digit and the rest, the
;; fraction's first and the rest, the exponent's first and the rest.
(define digit-edges
  '(":" "-:" "1:" "12:" "1.:" "1.5:" "1e:" "1e+:" "1e5:"
    "/" "-/" "1/" "12/" "1./" "1.5/" "1E/" "1e-/" "1e5/"))

(define not-numbers
  (append '("abc" "1/2" "#x10" "+1" "01" "1." ".5" "-" "1e" "1e+" "1.5e3x" " 1") digit-edges))

(define (refused-number text)
  (refused 'json-assembler-number! "the parts are not a JSON number" text))

(test-equal "ADR-0016: with no parts, json-assembler-number! raises, in every mode"
  (list (refused-number "") (refused-number "") (refused-number ""))
  (map (lambda (mode) (assemble mode 1000 '())) modes))

(for-each
 (lambda (mode)
   (test-equal (str "ADR-0016: " (symbol->string mode) ": parts that are not a JSON number raise, naming their text")
     (map (lambda (t) (list t (refused-number t))) not-numbers)
     (outcomes mode 1000 not-numbers)))
 modes)

(test-equal "ADR-0016: a non-number in several parts raises with the parts joined"
  (list (refused-number "1/2") (refused-number "#x10") (refused-number "01"))
  (list (assemble 'flonum 1000 '("1" "/" "2")) (assemble 'exact 1000 '("#" "x1" "0"))
        (assemble 'text 1000 '("0" "1"))))

;; in-turn : json-assembler (Listof (Listof String)) -> (Listof Outcome)
;; Each list of parts given and taken, one after the other, on one assembler.
(define (in-turn a part-lists)
  (let loop ((ps part-lists) (acc '()))
    (if (null? ps)
        (reverse acc)
        (let ((o (assemble-with a (car ps)))) (loop (cdr ps) (cons o acc))))))

(test-equal "ADR-0016: after a raise the assembler is empty, in every mode"
  (list (list (refused-number "abc") '(number 7) (refused-number "01") '(number 8))
        (list (refused-number "abc") '(number 7) (refused-number "01") '(number 8))
        (list (refused-number "abc") '(json-number "7") (refused-number "01") '(json-number "8")))
  (map (lambda (mode) (in-turn (make-json-assembler (options-for mode 1000)) '(("abc") ("7") ("0" "1") ("8"))))
       modes))

(test-equal "ADR-0016: limit 4: after a stop the assembler is empty: out of range, then too long"
  (list (list '(stop number-out-of-range) '(number 8) '(stop number-too-long) '(number 1234))
        (list '(stop number-out-of-range) '(number 8) '(stop number-too-long) '(number 1234)))
  (list (in-turn (make-json-assembler (options-for 'flonum 4)) '(("1e400") ("8") ("12" "345") ("1234")))
        (in-turn (make-json-assembler (options-for 'exact 4)) '(("1e4") ("8") ("12" "345") ("1234")))))

(test-equal "ADR-0016: taking a number clears its digit count, and so does a reset"
  (list '(number 12) '(number 12) '(number 123) '(number 123))
  (let* ((a (make-json-assembler (options-for 'flonum 3)))
         (r1 (assemble-with a '("12")))
         (r2 (assemble-with a '("12")))
         (r3 (begin (give! a "99") (json-assembler-reset! a) (assemble-with a '("123"))))
         (r4 (begin (give! a "9999") (json-assembler-reset! a) (assemble-with a '("123")))))
    (list r1 r2 r3 r4)))

(test-equal "ADR-0016: json-assembler-number-chars! and json-assembler-number! refuse what is not theirs"
  (list (refused 'json-assembler-number-chars! "not an assembler" 'a)
        (refused 'json-assembler-number-chars! "not a bytevector" "12")
        (refused 'json-assembler-number-chars! "the range is not within the bytevector" 1 0 2)
        (refused 'json-assembler-number-chars! "the range is not within the bytevector" 0 3 2)
        (refused 'json-assembler-number! "not an assembler" 'a))
  (let ((a (make-json-assembler)) (bv (bytes "12")))
    (list (refusal (lambda () (json-assembler-number-chars! 'a bv 0 2)))
          (refusal (lambda () (json-assembler-number-chars! a "12" 0 2)))
          (refusal (lambda () (json-assembler-number-chars! a bv 1 0)))
          (refusal (lambda () (json-assembler-number-chars! a bv 0 3)))
          (refusal (lambda () (json-assembler-number! 'a))))))

;; The assembler's own defaults, apart from make-json-options's: each
;; text to an assembler made with no options.
(test-equal "ADR-0016: an assembler made with no options is flonum under a limit of 1000: 1.5 a flonum, 1e400 out of range, 1,000 digits accepted, 1,001 too long"
  (list (list 'number (inexact 3/2)) '(stop number-out-of-range) (list 'number (expt 10 999))
        '(stop number-too-long))
  (map (lambda (t) (assemble-with (make-json-assembler) (list t))) (list "1.5" "1e400" int-1000 int-1001)))

;; Three assemblers at once, their parts interleaved. Alone, each would
;; give what it gives here; one count or one text shared between them
;; would not.
(test-equal "ADR-0016: interleaved assemblers keep their own text and digit count: flonum and exact under a limit of 3, text under 1"
  (list '(stop number-too-long) '(number 15) '(json-number "98765.25")
        '(number 999) '(number 12) '(json-number "-0"))
  (let* ((a (make-json-assembler (options-for 'flonum 3)))
         (b (make-json-assembler (options-for 'exact 3)))
         (c (make-json-assembler (options-for 'text 1))))
    (give! a "12") (give! b "1") (give! c "98765") (give! a "34") (give! b ".5") (give! c ".25")
    (give! b "e1")
    (let* ((ra (assemble-with a '()))
           (rb (assemble-with b '()))
           (rc (assemble-with c '())))
      (give! a "1") (give! b "99") (give! c "-") (give! a "2") (give! b "9") (give! c "0")
      (let* ((rb2 (assemble-with b '()))
             (ra2 (assemble-with a '()))
             (rc2 (assemble-with c '())))
        (list ra rb rc rb2 ra2 rc2)))))

;; ============ 7. json-number =======================================================

(define good-numbers '("0" "-0" "1.5" "-1.5e3" "1E+2" "0.000e-0" "123456789012345678901234567890"))

(test-equal "ADR-0016: make-json-number takes a JSON number and keeps its text"
  (map (lambda (t) (list t #t t)) good-numbers)
  (map (lambda (t)
         (let ((n (make-json-number t))) (list t (json-number? n) (json-number-text n))))
       good-numbers))

(define bad-numbers
  (append '("" "01" "1." ".5" "+1" "1e" "1e+" "-" "--1" "abc" " 1" "1 " "1/2" "#x10" "1e5.0" "0x1"
            "\x661;" "1\x0;")
          digit-edges))

(test-equal "ADR-0016: make-json-number refuses a string that is not a JSON number, naming it"
  (map (lambda (t) (refused 'make-json-number "not a JSON number" t)) bad-numbers)
  (map (lambda (t) (refusal (lambda () (make-json-number t)))) bad-numbers))

(test-equal "ADR-0016: make-json-number refuses what is not a string"
  (list (refused 'make-json-number "not a string" 15)
        (refused 'make-json-number "not a string" 'one)
        (refused 'make-json-number "not a string" (bytes "1"))
        (refused 'make-json-number "not a string" #f))
  (map (lambda (x) (refusal (lambda () (make-json-number x)))) (list 15 'one (bytes "1") #f)))

(test-equal "ADR-0016: json-number? knows a record from its text, and json-number-text refuses a string"
  (list #t #f #f (refused 'json-number-text "not a json-number" "1"))
  (list (json-number? (make-json-number "1")) (json-number? "1") (json-number? 1)
        (refusal (lambda () (json-number-text "1")))))

(test-equal "ADR-0016: a record keeps a copy: changing the string it was made from changes nothing"
  "12"
  (let* ((s (string #\1 #\2)) (n (make-json-number s)))
    (string-set! s 0 #\9)
    (json-number-text n)))

(test-equal "ADR-0016: json-number-text gives a copy: changing it changes nothing, for a record made or assembled"
  '("34" "56")
  (let* ((made (make-json-number (string #\3 #\4)))
         (a (make-json-assembler (options-for 'text 1)))
         (assembled (begin (give! a "56") (json-assembler-number! a))))
    (string-set! (json-number-text made) 0 #\7)
    (string-set! (json-number-text assembled) 0 #\7)
    (list (json-number-text made) (json-number-text assembled))))

(define short-strings (apply append (map strings-of-length '(0 1 2 3 4))))

;; 1 + 10 + 100 + 1,000 + 10,000 strings.
(test-equal "ADR-0016: every string of up to 4 characters from -+.eE019/: make-json-number and a text-mode assembler take it exactly when the parser accepts it as a document"
  (list 'strings 11111 'disagreeing '() 'both-verdicts #t)
  (let ((all (map verdicts short-strings)))
    (list 'strings (length short-strings)
          'disagreeing (take-up-to (filter (lambda (x) x) (map grammar-check short-strings)) 3)
          'both-verdicts (and (exists car all) (exists (lambda (v) (not (car v))) all) #t))))

(define grammar-tally (make-tally))

(test-equal "ADR-0016: seeded longer strings: make-json-number and a text-mode assembler take one exactly when the parser accepts it"
  '()
  (property-failures run 'grammar 3 1000 gen-grammar-group
                     (lambda (text)
                       (tally! grammar-tally (if (parser-accepts? text) 'accepted 'refused))
                       (grammar-check text))
                     string-shrinks grammar-tally))

(test-equal "the seeded strings met both verdicts"
  '(#t #t)
  (list (> (count-of grammar-tally 'accepted) 0) (> (count-of grammar-tally 'refused) 0)))

;; ============ 8. The options =======================================================

(test-equal "ADR-0016: the defaults are flonum and 1000"
  '(flonum 1000)
  (let ((o (make-json-options)))
    (list (json-options-number-mode o) (json-options-digit-limit o))))

(test-equal "ADR-0016: every number-mode is taken"
  '(flonum exact text)
  (map (lambda (m) (json-options-number-mode (make-json-options 'number-mode m))) '(flonum exact text)))

(test-equal "ADR-0016: any other number-mode is refused, naming it"
  (map (lambda (v) (refused 'make-json-options "number-mode is not flonum, exact or text" v))
       (list 'float "flonum" #f 'FLONUM 'integer))
  (map (lambda (v) (refusal (lambda () (make-json-options 'number-mode v))))
       (list 'float "flonum" #f 'FLONUM 'integer)))

(test-equal "ADR-0016: digit-limit takes 1 and the greatest fixnum"
  (list 1 (greatest-fixnum))
  (map (lambda (v) (json-options-digit-limit (make-json-options 'digit-limit v)))
       (list 1 (greatest-fixnum))))

(test-equal "ADR-0016: digit-limit refuses 0, -1, 1.5, 1.0, the greatest fixnum plus one and a symbol, naming it"
  (map (lambda (v) (refused 'make-json-options
                            "digit-limit is not an exact integer from 1 to the greatest fixnum" v))
       (list 0 -1 1.5 1.0 (+ (greatest-fixnum) 1) 'many))
  (map (lambda (v) (refusal (lambda () (make-json-options 'digit-limit v))))
       (list 0 -1 1.5 1.0 (+ (greatest-fixnum) 1) 'many)))

(test-equal "ADR-0016: number-mode or digit-limit given twice, or with no value, is refused"
  (list (refused 'make-json-options "an option is given twice" 'number-mode)
        (refused 'make-json-options "an option is given twice" 'digit-limit)
        (refused 'make-json-options "an option has no value" 'number-mode)
        (refused 'make-json-options "an option has no value" 'digit-limit))
  (list (refusal (lambda () (make-json-options 'number-mode 'exact 'number-mode 'exact)))
        (refusal (lambda () (make-json-options 'digit-limit 5 'number-mode 'text 'digit-limit 6)))
        (refusal (lambda () (make-json-options 'digit-limit 5 'number-mode)))
        (refusal (lambda () (make-json-options 'digit-limit)))))

(test-equal "ADR-0016: the accessors give what was set, in any order, beside a depth-limit"
  '((text 7 9) (exact 12 3))
  (map (lambda (o) (list (json-options-number-mode o) (json-options-digit-limit o)
                         (json-options-depth-limit o)))
       (list (make-json-options 'digit-limit 7 'depth-limit 9 'number-mode 'text)
             (make-json-options 'number-mode 'exact 'depth-limit 3 'digit-limit 12))))

(test-end "number")

(exit (suite-exit-status runner))
