#!r6rs
;;; tests/test-parser.sps: (jsonparse parser) held to the reference
;;; (ADR-0004, ADR-0005).
;;;
;;; 1. The differential. The parser's trace (run-parser) must equal
;;;    machine->parser of the reference's trace (run-machine on the
;;;    generated machine, whose plain list stack answers `context`) on the
;;;    same schedule and depth limit. Every JSONTestSuite file and every
;;;    yajl case, and a few nesting shapes the corpus lacks, run under the
;;;    default limit and under 0, 1, 2 and 3:
;;;      - whole, and in chunks of 1, 2, 3, 5, 7, 13 and 64 bytes;
;;;      - files of at most 64 bytes under every schedule schedules-for
;;;        gives: every split, every pair of splits and ten others;
;;;      - longer files under 48 random schedules each.
;;;    A handler with no procedures takes the parser's other branch for
;;;    every open and close, so its results are held to the reference's too.
;;;    A seeded property then runs mutants of these inputs, made as
;;;    tests/test-fuzz.sps makes its own, under random schedules and limits.
;;; 2. Escapes, pinned by hand: scalars, surrogate pairs split at every
;;;    byte, and broken pairs, in a string and in a key.
;;; 3. Empty text: no empty chars part reaches a handler.
;;; 4. Depth limits through the parser: at the limit, one past it, and
;;;    after a close.
;;; 5. Every result of every run has a known status, and a code exactly
;;;    when it is an error.
;;;
;;; Hand-pinned traces are whole: every handler call and every result, in
;;; order. An event fires in the feed that reads its byte: an open or close
;;; at its bracket, string-start and key-start at the opening quote,
;;; string-end and key-end at the closing one, an escape at its last byte
;;; (a pair's at its low half's last), null at its last `l`. An open past
;;; the limit, and a surrogate check after a fourth hex digit, fail at the
;;; offset after their byte; any other error at the offending byte.
;;;
;;; make test runs the default seed. A seed, and a multiplier of the
;;; property's case count, may be given by hand:
;;;
;;;   scripts/guix-env sh -c 'make deps >/dev/null && $CHEZ --libdirs \
;;;     src:vendor/byte-machine/src:build/scheme-libs:tests:grammar:vendor/byte-machine/test/support/harness \
;;;     --program tests/test-parser.sps 12345 20'
(import (rnrs)
        (srfi :64)
        (jsonparse-testing)
        (jsonparse-testing property)
        (jsonparse-testing machine)
        (jsonparse-testing parser)
        (jsonparse parser)
        (jsonparse options)
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
              "usage: test-parser.sps [SEED [MULTIPLIER]]  (decimal digits)\n")
  (exit 1))

(define run (make-property-run "parser" (car parsed) (cadr parsed)))

;; --- bytes ----------------------------------------------------------------------

;; bytes : (U String Byte Bytevector) ... -> Bytevector
;; The parts in order: a string as its UTF-8, an integer as one byte.
(define (bytes . parts)
  (apply cat (map (lambda (p)
                    (cond ((string? p) (string->utf8 p))
                          ((integer? p) (u8-list->bytevector (list p)))
                          (else p)))
                  parts)))

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

;; copies : Nat a -> (Listof a)
(define (copies n x)
  (let loop ((n n) (acc '())) (if (= n 0) acc (loop (- n 1) (cons x acc)))))

;; copies* : Nat (Listof a) -> (Listof a)
(define (copies* n xs) (apply append (copies n xs)))

(define (repeated n text) (apply bytes (copies n text)))

(define (iota n) (let loop ((i (- n 1)) (acc '())) (if (< i 0) acc (loop (- i 1) (cons i acc)))))

(define (take-up-to xs n)
  (if (or (null? xs) (= n 0)) '() (cons (car xs) (take-up-to (cdr xs) (- n 1)))))

;; --- limits ---------------------------------------------------------------------

;; A limit is #f for the default, or a depth limit. The parser takes it as an
;; option, the reference as the starting value of depth-left.
(define (options-for limit)
  (if limit (make-json-options 'depth-limit limit) (make-json-options)))

(define (fields-for limit)
  (if limit (list (cons 'depth-left limit)) '()))

;; --- what every run is held to --------------------------------------------------
;;
;; Every parser run of this suite goes through parser-run or results-of, and
;; every reference run through reference-run, so the counts below see them
;; all.

;; Results by status, codes that break the rule, and empty chars parts.
(define seen-need-input 0)
(define seen-finished 0)
(define seen-error 0)
(define seen-other-status '())
(define seen-bad-code '())
(define parser-empty-chars 0)
(define reference-empty-chars 0)

(define (result-entry? x) (and (pair? x) (memq (car x) '(feed finish))))

(define (empty-chars? x)
  (and (pair? x) (eq? (car x) 'chars) (= (bytevector-length (cadr x)) 0)))

;; observe-parser! : Trace -> Trace
;; Counts TRACE's results and empty chars parts, and answers TRACE.
(define (observe-parser! trace)
  (for-each
   (lambda (x)
     (when (empty-chars? x) (set! parser-empty-chars (+ parser-empty-chars 1)))
     (when (result-entry? x)
       (let ((status (cadr x)) (code (caddr x)))
         (case status
           ((need-input) (set! seen-need-input (+ seen-need-input 1)))
           ((finished) (set! seen-finished (+ seen-finished 1)))
           ((error) (set! seen-error (+ seen-error 1)))
           (else (set! seen-other-status (cons x seen-other-status))))
         (unless (eq? (eq? status 'error) (and code #t))
           (set! seen-bad-code (cons x seen-bad-code))))))
   trace)
  trace)

;; parser-run : Schedule Limit -> (U Trace (List 'raised String))
(define (parser-run schedule limit)
  (guard (e (#t (list 'raised (describe e))))
    (observe-parser! (run-parser schedule (options-for limit)))))

;; reference-run : Schedule Limit -> Trace
;; machine->parser of the reference's trace, counting the raw trace's empty
;; chars parts.
(define (reference-run schedule limit)
  (let ((raw (run-machine generated-machine schedule (fields-for limit))))
    (for-each (lambda (x)
                (when (empty-chars? x)
                  (set! reference-empty-chars (+ reference-empty-chars 1))))
              raw)
    (machine->parser raw)))

;; first-difference : List Any -> (U 'same List)
;; 'same, or where EXPECTED and ACTUAL first part, for traces too long to
;; print whole.
(define (first-difference expected actual)
  (if (not (list? actual))
      (list 'not-a-trace actual)
      (let loop ((i 0) (e expected) (a actual))
        (cond ((and (null? e) (null? a)) 'same)
              ((or (null? e) (null? a) (not (equal? (car e) (car a))))
               (list 'differs-at i
                     'expected (if (null? e) 'end (car e))
                     'actual (if (null? a) 'end (car a))
                     'lengths (length expected) (length actual)))
              (else (loop (+ i 1) (cdr e) (cdr a)))))))

(define (feeds-of schedule)
  (map (lambda (f) (list (cadr f) (caddr f))) schedule))

;; differ : Schedule Limit -> (U #f Evidence)
;; #f when the parser records what the reference does.
(define (differ schedule limit)
  (differ-noting schedule limit (lambda (reference) #f)))

;; differ-noting : Schedule Limit (Trace -> Any) -> (U #f Evidence)
;; differ, handing NOTE the reference's trace first.
(define (differ-noting schedule limit note)
  (let* ((reference (reference-run schedule limit))
         (parser (parser-run schedule limit)))
    (note reference)
    (and (not (equal? parser reference))
         (list 'limit limit 'feeds (feeds-of schedule)
               (first-difference reference parser)))))

;; recording-handler has all fourteen procedures. A handler with none takes
;; the parser's other branch for every open and close, which must push and
;; pop just the same: its results must be the reference's.
(define bare-handler (make-json-handler))

(define (result-of tag r)
  (list tag (json-result-status r) (json-result-code r) (json-result-offset r)))

;; results-of : json-parser Schedule -> (Listof Result-Entry)
;; Feeds PARSER the schedule as run-parser does, and finishes unless a feed
;; answered other than need-input: its results, as run-parser records them.
(define (results-of parser schedule)
  (let loop ((feeds schedule) (acc '()))
    (if (null? feeds)
        (observe-parser! (reverse (cons (result-of 'finish (json-parser-finish! parser)) acc)))
        (let* ((f (car feeds))
               (r (json-parser-feed! parser (car f) (cadr f) (caddr f)))
               (acc (cons (result-of 'feed r) acc)))
          (if (eq? (json-result-status r) 'need-input)
              (loop (cdr feeds) acc)
              (observe-parser! (reverse acc)))))))

;; bare-run : Schedule Limit -> (U (Listof Result-Entry) (List 'raised String))
(define (bare-run schedule limit)
  (guard (e (#t (list 'raised (describe e))))
    (results-of (make-json-parser bare-handler #f (options-for limit)) schedule)))

;; bare-differ : Schedule Limit -> (U #f Evidence)
;; #f when a parser with no procedures has the reference's results.
(define (bare-differ schedule limit)
  (let ((reference (filter result-entry? (reference-run schedule limit)))
        (parser (bare-run schedule limit)))
    (and (not (equal? parser reference))
         (list 'bare 'limit limit 'feeds (feeds-of schedule)
               (first-difference reference parser)))))

;; --- the corpus -----------------------------------------------------------------

;; corpus : (Listof (Pair String Bytevector)), every JSONTestSuite file and
;; every yajl case, by name.
(define (files-in dir)
  (map (lambda (n) (cons (string-append dir "/" n) (file-bytes (string-append dir "/" n))))
       (corpus-files dir ".json")))

(define corpus
  (append (files-in "tests/corpus/jsontestsuite/test_parsing")
          (files-in "tests/corpus/yajl/cases")))

;; No corpus file of 64 bytes or less holds a value in a container nested in
;; the other kind, the one place where an answer from anywhere but the top
;; of the stack goes wrong. These shapes do, and run as the files do.
(define shapes
  (map (lambda (text) (cons (string-append "shape " text) (string->utf8 text)))
       '("[{\"a\":1}]"
         "{\"a\":[1]}"
         "{\"a\":[1,{\"b\":[2,3]}],\"c\":{}}"
         "[[{}],{\"a\":[[]]},[{\"b\":{\"c\":[null]}}]]"
         "{\"a\":{\"b\":[true]},\"c\":[false,{\"d\":\"\\u00e9\\uD834\\uDD1E\"}]}")))

;; inputs : (Listof (Pair String Bytevector)), what the lanes run
(define inputs (append corpus shapes))

(define limits '(#f 0 1 2 3))

;; --- what the differential reached ----------------------------------------------
;;
;; Read from the reference's trace of every lane run, which no parser bug
;; can change: the files that hit nesting-too-deep under a limit of 0 to 3,
;; and those accepted with as many containers open as the limit, 1 to 3,
;; allows.

(define too-deep-files '())
(define full-stack-files '())

(define (note-file! name names) (if (member name names) names (cons name names)))

;; deepest : Trace -> Nat
;; The most containers TRACE's events hold open at once.
(define (deepest trace)
  (let loop ((xs trace) (depth 0) (most 0))
    (cond ((null? xs) most)
          ((memq (car xs) '(array-start object-start))
           (loop (cdr xs) (+ depth 1) (max most (+ depth 1))))
          ((memq (car xs) '(array-end object-end)) (loop (cdr xs) (- depth 1) most))
          (else (loop (cdr xs) depth most)))))

(define (note-reach! name limit reference)
  (when (and limit (<= limit 3))
    (let ((outcome (parser-outcome reference)))
      (when (equal? (take-up-to outcome 2) '(rejected nesting-too-deep))
        (set! too-deep-files (note-file! name too-deep-files)))
      (when (and (equal? outcome '(accepted)) (>= limit 1) (= (deepest reference) limit))
        (set! full-stack-files (note-file! name full-stack-files))))))

;; --- the lanes ------------------------------------------------------------------

;; lane : String (Listof (Pair String (Listof Schedule))) (String Schedule Limit -> (U #f Evidence))
;;        -> (List Nat Nat (Listof Failure))
;; Runs COMPARE on every file's schedules under every limit: the runs, the
;; failures and the first three of them.
(define (lane label work compare)
  (let loop ((work work) (ran 0) (failed 0) (found '()))
    (if (null? work)
        (begin
          (put-string (current-output-port)
                      (string-append "parser: " label ": " (number->string ran) " runs, "
                                     (number->string failed) " failing\n"))
          (list ran failed (reverse found)))
        (let ((name (caar work)) (schedules (cdar work)))
          (let each ((pairs (apply append
                                   (map (lambda (limit)
                                          (map (lambda (s) (cons s limit)) schedules))
                                        limits)))
                     (ran ran) (failed failed) (found found))
            (if (null? pairs)
                (loop (cdr work) ran failed found)
                (let ((evidence (compare name (caar pairs) (cdar pairs))))
                  (cond
                   ((not evidence) (each (cdr pairs) (+ ran 1) failed found))
                   ((< (length found) 3)
                    (each (cdr pairs) (+ ran 1) (+ failed 1) (cons (cons name evidence) found)))
                   (else (each (cdr pairs) (+ ran 1) (+ failed 1) found))))))))))

(define chunk-sizes '(1 2 3 5 7 13 64))

(define split-at-most 64)

(define randoms-per-file 48)

;; schedules-expected : Nat -> Nat
;; What schedules-for gives for L bytes: L+1 splits, (L+1)(L+2)/2 pairs, and
;; 1 whole + 3 with an empty feed + 1 sub-slice + 1 padded + 4 multi-splits.
(define (schedules-expected len)
  (+ (+ len 1) (div (* (+ len 1) (+ len 2)) 2) 10))

(define short-files
  (filter (lambda (f) (<= (bytevector-length (cdr f)) split-at-most)) inputs))

(define long-files
  (filter (lambda (f) (> (bytevector-length (cdr f)) split-at-most)) inputs))

(define chunk-work
  (map (lambda (f)
         (cons (car f) (cons (whole-schedule (cdr f))
                             (map (lambda (k) (chunk-schedule (cdr f) k)) chunk-sizes))))
       inputs))

;; Drawn from one prng, threaded through the short files in order.
(define split-work
  (let loop ((fs short-files) (state (make-prng (property-run-seed run))) (acc '()))
    (if (null? fs)
        (reverse acc)
        (let-values (((schedules state) (schedules-for (cdar fs) state)))
          (loop (cdr fs) state (cons (cons (caar fs) schedules) acc))))))

;; File I's schedules are drawn from (case-state seed 2 I), one after another.
(define random-work
  (map (lambda (f i)
         (cons (car f)
               (let loop ((k 0) (s (case-state (property-run-seed run) 2 i)) (acc '()))
                 (if (= k randoms-per-file)
                     (reverse acc)
                     (let ((drawn (random-schedule (cdr f) s)))
                       (loop (+ k 1) (cdr drawn) (cons (car drawn) acc)))))))
       long-files
       (iota (length long-files))))

(define bare-chunk-sizes '(1 7))

(define bare-work
  (map (lambda (f)
         (cons (car f) (cons (whole-schedule (cdr f))
                             (map (lambda (k) (chunk-schedule (cdr f) k)) bare-chunk-sizes))))
       inputs))

;; The lanes' comparisons: the recording handler's whole trace, noting what
;; the reference reached; and the results of a handler with no procedures.
(define (traces-agree name schedule limit)
  (differ-noting schedule limit (lambda (reference) (note-reach! name limit reference))))

(define (bare-agrees name schedule limit) (bare-differ schedule limit))

;; --- the property: mutants --------------------------------------------------------
;;
;; Mutants of the inputs of at most 4 KB, as tests/test-fuzz.sps makes
;; them: one to three of flip a bit, insert a random byte, insert a
;; structural byte, delete a byte, duplicate a range, truncate. A case is
;; (bytes state limit): the mutant, the state its random schedule is drawn
;; from, and the limit, #f or 0 to 4. The parser must record what the
;; reference does, in one feed and under the random schedule, and a parser
;; with no procedures must have the reference's results under it.

(define groups 1000)
(define mutants-per-group 5)

(define seeds
  (filter (lambda (bv) (<= (bytevector-length bv) 4096)) (map cdr inputs)))

(define structural
  (map char->integer (string->list "[]{}\",:\\0123456789e-")))

(define (insert-at bv i b) (cat (sub bv 0 i) (u8-list->bytevector (list b)) (sub bv i (bytevector-length bv))))

;; mutate : Nat Bytevector -> Gen Bytevector
;; Mutation KIND, 0 to 5, of BV; an empty BV can only grow.
(define (mutate kind bv)
  (let ((len (bytevector-length bv)))
    (if (and (= len 0) (not (memv kind '(1 2))))
        (mutate 1 bv)
        (case kind
          ((0) (lambda (s)
                 (draw* s ((i (g-int len)) (bit (g-int 8)))
                   (let ((out (sub bv 0 len)))
                     (bytevector-u8-set! out i (bitwise-xor (bytevector-u8-ref bv i)
                                                            (bitwise-arithmetic-shift-left 1 bit)))
                     (cons out s)))))
          ((1) (lambda (s)
                 (draw* s ((i (g-range 0 len)) (b (g-int 256)))
                   (cons (insert-at bv i b) s))))
          ((2) (lambda (s)
                 (draw* s ((i (g-range 0 len)) (b (g-pick structural)))
                   (cons (insert-at bv i b) s))))
          ((3) (lambda (s)
                 (draw* s ((i (g-int len)))
                   (cons (cat (sub bv 0 i) (sub bv (+ i 1) len)) s))))
          ((4) (lambda (s)
                 (draw* s ((i (g-int len)) (n (g-range 1 16)))
                   (let ((j (min len (+ i n))))
                     (cons (cat (sub bv 0 j) (sub bv i j) (sub bv j len)) s)))))
          (else (lambda (s)
                  (draw* s ((n (g-int len)))
                    (cons (sub bv 0 n) s))))))))

(define (g-mutant bv)
  (lambda (s)
    (draw* s ((count (g-range 1 3)))
      (let loop ((k count) (bv bv) (s s))
        (if (= k 0)
            (cons bv s)
            (draw* s ((kind (g-int 6)) (next (mutate kind bv)))
              (loop (- k 1) next s)))))))

(define mutant-limits '(#f #f 0 1 2 3 4))

(define (gen-group s)
  (let loop ((k 0) (s s) (acc '()))
    (if (= k mutants-per-group)
        (reverse acc)
        (draw* s ((bv (g-pick seeds)) (m (g-mutant bv)) (st (g-int 32768))
                  (limit (g-pick mutant-limits)))
          (loop (+ k 1) s (cons (list m st limit) acc))))))

(define tally (make-tally))

(define (non-empty-feeds schedule)
  (length (filter (lambda (f) (> (caddr f) (cadr f))) schedule)))

;; check : Case -> (U #f Evidence)
(define (check kase)
  (let* ((bv (car kase)) (limit (caddr kase))
         (schedule (car (random-schedule bv (cadr kase))))
         (outcome (parser-outcome (reference-run (whole-schedule bv) limit))))
    (tally! tally 'case)
    (when (>= (non-empty-feeds schedule) 2) (tally! tally 'two-feeds))
    (tally! tally (if (eq? (car outcome) 'rejected) (cadr outcome) (car outcome)))
    (or (differ (whole-schedule bv) limit)
        (differ schedule limit)
        (bare-differ schedule limit))))

;; shrinks : Case -> (Listof Case)
;; The limit back to the default; the mutant without a half, a quarter,
;; then, if short, any one byte.
(define (shrinks kase)
  (let* ((bv (car kase)) (rest (cdr kase)) (len (bytevector-length bv)))
    (append
     (if (caddr kase) (list (list bv (cadr kase) #f)) '())
     (map (lambda (b) (cons b rest))
          (append
           (if (> len 1)
               (let ((h (div len 2))) (list (sub bv h len) (sub bv 0 h)))
               '())
           (if (> len 8)
               (let ((q (div len 4)))
                 (list (cat (sub bv 0 q) (sub bv (* 2 q) len))
                       (cat (sub bv 0 (* 2 q)) (sub bv (* 3 q) len))))
               '())
           (if (and (> len 0) (<= len 64))
               (map (lambda (i) (cat (sub bv 0 i) (sub bv (+ i 1) len))) (iota len))
               '()))))))

(define (count key) (let ((p (assq key (tally-counts tally)))) (if p (cdr p) 0)))

;; --- hand-pinned traces -------------------------------------------------------------

;; whole : Bytevector Limit -> Trace
(define (whole bv limit) (parser-run (whole-schedule bv) limit))

;; A short expected trace is compared whole, and printed whole when it
;; fails; a long one by its first difference.
(define (test-trace name expected actual)
  (if (> (length expected) 40)
      (test-equal name 'same (first-difference expected actual))
      (test-equal name expected actual)))

(define (done at) (list (list 'feed 'need-input #f at) (list 'finish 'finished #f at)))
(define (refused code at) (list (list 'feed 'error code at)))
(define (esc scalar) (list 'escape scalar))
(define (chars text) (list 'chars (string->utf8 text)))

;; placed : (Listof (Pair Nat Entry)) Schedule -> Trace
;; The trace of an accepted input whose events fire at the given byte
;; offsets, in order, when SCHEDULE feeds it: each feed's events, then its
;; result, and the finish.
(define (placed events schedule)
  (let loop ((feeds schedule) (at 0) (evs events) (acc '()))
    (if (null? feeds)
        (append (reverse acc) (map cdr evs) (list (list 'finish 'finished #f at)))
        (let ((end (+ at (- (caddr (car feeds)) (cadr (car feeds))))))
          (let take ((evs evs) (acc acc))
            (if (and (pair? evs) (< (caar evs) end))
                (take (cdr evs) (cons (cdar evs) acc))
                (loop (cdr feeds) end evs (cons (list 'feed 'need-input #f end) acc))))))))

;; splits : Bytevector -> (Listof Schedule)
;; BV in two feeds, split at every byte boundary, 0 and the end included.
(define (splits bv)
  (let ((len (bytevector-length bv)))
    (map (lambda (k) (list (list bv 0 k) (list bv k len))) (iota (+ len 1)))))

(test-begin "parser")

;; ============ 1. The differential (ADR-0004) ===================================

(let ((r (lane "whole and chunks" chunk-work traces-agree)))
  (test-equal "ADR-0004: every corpus file and shape, whole and in chunks of 1, 2, 3, 5, 7, 13 and 64, under limits default, 0, 1, 2, 3: the parser records what the reference does"
    (list 'runs (* (length inputs) (length limits) (+ 1 (length chunk-sizes))) 'failures 0 '())
    (list 'runs (car r) 'failures (cadr r) (caddr r))))

(let ((r (lane "splits" split-work traces-agree)))
  (test-equal "ADR-0004: every corpus file and shape of at most 64 bytes, under every split, every pair of splits and schedules-for's others, under every limit: the parser records what the reference does"
    (list 'runs (* (length limits)
                   (fold-left + 0 (map (lambda (f) (schedules-expected (bytevector-length (cdr f))))
                                       short-files)))
          'failures 0 '())
    (list 'runs (car r) 'failures (cadr r) (caddr r))))

(let ((r (lane "random schedules" random-work traces-agree)))
  (test-equal "ADR-0004: every corpus file and shape over 64 bytes, under 48 random schedules each, under every limit: the parser records what the reference does"
    (list 'runs (* (length long-files) (length limits) randoms-per-file) 'failures 0 '())
    (list 'runs (car r) 'failures (cadr r) (caddr r))))

(let ((r (lane "no procedures" bare-work bare-agrees)))
  (test-equal "ADR-0004: every corpus file and shape, whole and in chunks of 1 and 7, under every limit: a parser whose handler has no procedures has the reference's results"
    (list 'runs (* (length inputs) (length limits) (+ 1 (length bare-chunk-sizes))) 'failures 0 '())
    (list 'runs (car r) 'failures (cadr r) (caddr r))))

;; What the lanes reached. Measured: 326 of the 381 inputs hit
;; nesting-too-deep under a limit of 0 to 3, and 113 were accepted with the
;; stack full at 1, 2 or 3. Lanes run under the default limit alone would
;; reach neither, which is what the floors are for.
(test-equal "ADR-0005: under limits 0 to 3, over 250 inputs hit nesting-too-deep and over 80 were accepted with the stack full"
  '(#t #t)
  (list (> (length too-deep-files) 250) (> (length full-stack-files) 80)))

(test-equal "ADR-0004: no mutant of the inputs, under a random schedule and limit, makes the parser and the reference differ"
  '()
  (property-failures run 'mutants 1 groups gen-group check shrinks tally))

;; Measured at the default seed and five others: of 5000 cases, 4442 to
;; 4503 fell in two or more non-empty feeds, 224 to 234 were accepted, and
;; 503 to 543 hit nesting-too-deep. The floors are about half of that.
(test-equal "ADR-0004: over 100 mutants were accepted and over 250 hit nesting-too-deep, and 80% fell in two or more feeds"
  '(#t #t #t)
  (list (> (count 'accepted) 100)
        (> (count 'nesting-too-deep) 250)
        (>= (* 5 (count 'two-feeds)) (* 4 (count 'case)))))

;; ============ 2. Escapes (RFC 8259 §7; ADR-0015) ================================
;; The handler gets one escape call per escaped character, as a Unicode
;; scalar value: a surrogate pair is one call, once its low half is read.

(define escapes
  '(("\\u00e9" 233)
    ("\\uD834\\uDD1E" #x1D11E)
    ("\\uD800\\uDC00" #x10000)
    ("\\uDBFF\\uDFFF" #x10FFFF)
    ("\\u0000" 0)
    ("\\\"" 34) ("\\\\" 92) ("\\/" 47) ("\\b" 8)
    ("\\f" 12) ("\\n" 10) ("\\r" 13) ("\\t" 9)))

(for-each
 (lambda (e)
   (let* ((text (car e)) (scalar (cadr e))
          (in-string (bytes "\"" text "\""))
          (in-key (bytes "{\"" text "\":null}")))
     (test-trace (string-append "RFC 8259 §7: \"" text "\" is one escape call with " (number->string scalar))
       (append (list 'string-start (esc scalar) 'string-end)
               (done (bytevector-length in-string)))
       (whole in-string #f))
     (test-trace (string-append "RFC 8259 §7: the key \"" text "\" is one escape call with " (number->string scalar))
       (append (list 'object-start 'key-start (esc scalar) 'key-end 'null 'object-end)
               (done (bytevector-length in-key)))
       (whole in-key #f))))
 escapes)

(test-trace "RFC 8259 §7: text either side of a pair is two chars parts and one escape call"
  (append (list 'string-start (chars "ab") (esc #x1D11E) (chars "c") 'string-end) (done 17))
  (whole (bytes "\"ab\\uD834\\uDD1Ec\"") #f))
(test-trace "RFC 8259 §7: in a key, text either side of a pair is two chars parts and one escape call"
  (append (list 'object-start 'key-start (chars "ab") (esc #x1D11E) (chars "c") 'key-end
                'null 'object-end)
          (done 24))
  (whole (bytes "{\"ab\\uD834\\uDD1Ec\":null}") #f))

;; Split at every byte, from 0 to 14: the high half's escape is read in one
;; feed and the low half's in the next whenever the split falls between
;; bytes 7 and 12, so the parser must hold the high half across feeds.
(let ((bv (bytes "\"\\uD834\\uDD1E\"")))
  (test-equal "RFC 8259 §7: a pair in a string split across two feeds at every byte is one escape call, the same scalar"
    (map (lambda (s) (placed '((0 . string-start) (12 . (escape #x1D11E)) (13 . string-end)) s))
         (splits bv))
    (map (lambda (s) (parser-run s #f)) (splits bv))))
(let ((bv (bytes "{\"\\uD834\\uDD1E\":null}")))
  (test-equal "RFC 8259 §7: a pair in a key split across two feeds at every byte is one escape call, the same scalar"
    (map (lambda (s) (placed '((0 . object-start) (1 . key-start) (13 . (escape #x1D11E))
                               (14 . key-end) (19 . null) (20 . object-end))
                             s))
         (splits bv))
    (map (lambda (s) (parser-run s #f)) (splits bv))))

;; A broken pair is invalid-surrogate, and the handler gets no escape call
;; for any part of it. After a high half the machine wants `\u`: another
;; byte is refused where it stands, and a `\u` that is no low half after
;; its fourth digit. A lone low half is refused after its fourth digit.
(define broken-pairs
  '(("a lone high half then a plain character" "\\uD800a" 7)
    ("a high half then \\n" "\\uD800\\n" 8)
    ("a high half then \\u0041, no low half" "\\uD800\\u0041" 13)
    ("a lone low half" "\\uDC00" 7)))

(for-each
 (lambda (b)
   (let ((name (car b)) (text (cadr b)) (at (caddr b)))
     (test-trace (string-append "RFC 8259 §7: in a string, " name " is invalid-surrogate at "
                                (number->string at) ", with no escape call")
       (cons 'string-start (refused 'invalid-surrogate at))
       (whole (bytes "\"" text "\"") #f))
     (test-trace (string-append "RFC 8259 §7: in a key, " name " is invalid-surrogate at "
                                (number->string (+ at 1)) ", with no escape call")
       (append (list 'object-start 'key-start) (refused 'invalid-surrogate (+ at 1)))
       (whole (bytes "{\"" text "\":null}") #f))))
 broken-pairs)

;; ============ 3. Empty text (ADR-0015) ==========================================
;; byte-machine hands over an empty part for "" and between two escapes; the
;; handler never sees one, in one feed or one byte at a time.

(define empty-texts
  (list (list "\"\"" '((0 . string-start) (1 . string-end)))
        (list "\"\\n\\t\"" '((0 . string-start) (2 . (escape 10)) (4 . (escape 9)) (5 . string-end)))
        (list "{\"\":\"\"}" '((0 . object-start) (1 . key-start) (2 . key-end)
                              (4 . string-start) (5 . string-end) (6 . object-end)))))

(for-each
 (lambda (t)
   (let ((bv (bytes (car t))) (events (cadr t)))
     (test-equal (string-append "ADR-0015: " (car t) " in one feed gives no chars call")
       (placed events (whole-schedule bv))
       (whole bv #f))
     (test-equal (string-append "ADR-0015: " (car t) " one byte at a time gives no chars call")
       (placed events (chunk-schedule bv 1))
       (parser-run (chunk-schedule bv 1) #f))))
 empty-texts)

;; ============ 4. Depth limits (ADR-0005) ========================================
;; N arrays or objects nested round null are accepted under limit N; one
;; more is nesting-too-deep after the bracket that opens it: the (N+1)th `[`
;; is at N, the (N+1)th `{` of `{"a":` at 5N.

(define (arrays n) (bytes (repeated n "[") "null" (repeated n "]")))
(define (objects n) (bytes (repeated n "{\"a\":") "null" (repeated n "}")))

(define (arrays-accepted n)
  (append (copies n 'array-start) (list 'null) (copies n 'array-end) (done (+ (* 2 n) 4))))
(define (objects-accepted n)
  (append (copies* n (list 'object-start 'key-start (chars "a") 'key-end))
          (list 'null) (copies n 'object-end) (done (+ (* 6 n) 4))))

;; At limit 0, nesting to the limit is a top-level null, which arrays and
;; objects share, so it is one case.
(test-trace "ADR-0005: limit 0: a top-level null is accepted"
  (append (list 'null) (done 4))
  (whole (bytes "null") 0))

(for-each
 (lambda (limit)
   (let* ((n (or limit 512))
          (label (string-append "ADR-0005: " (if limit (string-append "limit " (number->string n))
                                                  "the default limit, 512")
                                ": ")))
     (when (> n 0)
       (test-trace (string-append label "arrays nested " (number->string n) " deep are accepted")
         (arrays-accepted n)
         (whole (arrays n) limit)))
     (test-trace (string-append label "arrays nested " (number->string (+ n 1))
                                " deep are nesting-too-deep at " (number->string (+ n 1)))
       (append (copies n 'array-start) (refused 'nesting-too-deep (+ n 1)))
       (whole (arrays (+ n 1)) limit))
     (when (> n 0)
       (test-trace (string-append label "objects nested " (number->string n) " deep are accepted")
         (objects-accepted n)
         (whole (objects n) limit)))
     (test-trace (string-append label "objects nested " (number->string (+ n 1))
                                " deep are nesting-too-deep at " (number->string (+ (* 5 n) 1)))
       (append (copies* n (list 'object-start 'key-start (chars "a") 'key-end))
               (refused 'nesting-too-deep (+ (* 5 n) 1)))
       (whole (objects (+ n 1)) limit))))
 '(0 1 2 3 #f 65535))

;; Every run above passes its options. A parser made without them takes
;; the default, 512, through either shorter arity of make-json-parser.
(define (default-results make bv)
  (guard (e (#t (list 'raised (describe e))))
    (results-of (make) (whole-schedule bv))))

(test-equal "ADR-0005: made with only a handler, a parser accepts 512 nested arrays and refuses 513 at 513"
  (list (done 1028) (refused 'nesting-too-deep 513))
  (list (default-results (lambda () (make-json-parser bare-handler)) (arrays 512))
        (default-results (lambda () (make-json-parser bare-handler)) (arrays 513))))
(test-equal "ADR-0005: made with a handler and a context, a parser accepts 512 nested arrays and refuses 513 at 513"
  (list (done 1028) (refused 'nesting-too-deep 513))
  (list (default-results (lambda () (make-json-parser bare-handler 'context)) (arrays 512))
        (default-results (lambda () (make-json-parser bare-handler 'context)) (arrays 513))))

;; A close gives back one place, and only one: after closes, reopening past
;; the limit still fails, and one limit higher the same input is accepted.
(test-trace "ADR-0005: limit 2: [[],[[]]] reopens past the limit after a close, at 6"
  (append '(array-start array-start array-end array-start) (refused 'nesting-too-deep 6))
  (whole (bytes "[[],[[]]]") 2))
(test-trace "ADR-0005: limit 3: [[],[[]]] is accepted"
  (append '(array-start array-start array-end array-start array-start array-end array-end array-end)
          (done 9))
  (whole (bytes "[[],[[]]]") 3))
(test-trace "ADR-0005: limit 3: [[[]],[[[]]]] reopens past the limit after two closes, at 9"
  (append '(array-start array-start array-start array-end array-end array-start array-start)
          (refused 'nesting-too-deep 9))
  (whole (bytes "[[[]],[[[]]]]") 3))
(test-trace "ADR-0005: limit 4: [[[]],[[[]]]] is accepted"
  (append '(array-start array-start array-start array-end array-end
            array-start array-start array-start array-end array-end array-end array-end)
          (done 13))
  (whole (bytes "[[[]],[[[]]]]") 4))
(test-trace "ADR-0005: limit 2: {\"a\":[],\"b\":[[]]} reopens past the limit after a close, at 14"
  (append (list 'object-start 'key-start (chars "a") 'key-end 'array-start 'array-end
                'key-start (chars "b") 'key-end 'array-start)
          (refused 'nesting-too-deep 14))
  (whole (bytes "{\"a\":[],\"b\":[[]]}") 2))
(test-trace "ADR-0005: limit 3: {\"a\":[],\"b\":[[]]} is accepted"
  (append (list 'object-start 'key-start (chars "a") 'key-end 'array-start 'array-end
                'key-start (chars "b") 'key-end 'array-start 'array-start 'array-end 'array-end
                'object-end)
          (done 17))
  (whole (bytes "{\"a\":[],\"b\":[[]]}") 3))

;; The top of the 16-bit field: 65535 opens and closes with nothing inside,
;; and a 65536th open, its `[` at 65535, fails after it.
(test-trace "ADR-0005: limit 65535: 65535 `[` then 65535 `]` are accepted"
  (append (copies 65535 'array-start) (copies 65535 'array-end) (done 131070))
  (whole (bytes (repeated 65535 "[") (repeated 65535 "]")) 65535))
(test-trace "ADR-0005: limit 65535: 65536 `[` are nesting-too-deep at 65536"
  (append (copies 65535 'array-start) (refused 'nesting-too-deep 65536))
  (whole (repeated 65536 "[") 65535))

;; ============ 5. Every result, every run ========================================
;; The grammar has no stop or pause node, so a result is need-input,
;; finished or error, and it has a code exactly when it is an error. Every
;; run above was counted, and each status was seen.

(test-equal "ADR-0010: every result of every run is need-input, finished or error, each seen, with a code exactly when it is an error"
  '(need-input #t finished #t error #t other () bad-code ())
  (list 'need-input (> seen-need-input 0) 'finished (> seen-finished 0) 'error (> seen-error 0)
        'other (take-up-to seen-other-status 3) 'bad-code (take-up-to seen-bad-code 3)))

(test-equal "ADR-0015: no run gave the handler an empty chars part, while the reference was handed some"
  '(parser 0 reference-had-some #t)
  (list 'parser parser-empty-chars 'reference-had-some (> reference-empty-chars 0)))

(test-end "parser")

(exit (suite-exit-status runner))
