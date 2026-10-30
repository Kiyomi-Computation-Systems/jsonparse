;;; tests/test-fuzz.sps: mutation fuzzing (ADR-0012 §5).
;;;
;;; Seeded byte mutations of the JSONTestSuite y_ and n_ files, up to 4 KB
;;; (the larger ones are deep nests, which die at the depth limit and
;;; mutate to nothing new): flip a bit, insert a random byte, insert a
;;; structural byte, delete a byte, duplicate a range, truncate; one to
;;; three of them to a mutant. Each mutant is held to these:
;;;
;;;   1. running it never raises
;;;   2. the verdict is accepted or rejected, and a rejection's offset is
;;;      in [0, length]
;;;   3. trace-content is the same under one feed and under a random
;;;      schedule
;;;   4. the generated and the interpreted machine give equal raw traces
;;;      under that random schedule
;;;
;;; Each case also sets depth-left (default, 0, 1, 2, 3 or 4) and mode (0 or 1)
;;; on all three runs, so nesting-too-deep and several top-level values are
;;; reached; random schedules scale their feeds with the input.
;;;
;;; make test runs the default seed. A seed, and a multiplier of the case
;;; count, may be given by hand, and run longer:
;;;
;;;   scripts/guix-env sh -c 'make deps >/dev/null && $CHEZ --libdirs \
;;;     src:vendor/byte-machine/src:build/scheme-libs:tests:grammar:vendor/byte-machine/test/support/harness \
;;;     --program tests/test-fuzz.sps 12345 20'
;;;
;;; A failing mutant is printed with its seed, its group and its place in
;;; the group, shrunk, as bytes.
(import (except (rnrs) current-output-port)
        (srfi :64)
        (jsonparse-testing)
        (jsonparse-testing property)
        (jsonparse-testing machine))

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

;; groups : the property's groups at a multiplier of 1; each group is
;; mutants-per-group mutants of one file.
(define groups 4000)
(define mutants-per-group 5)

(define parsed (parse-property-arguments (cdr (command-line)) default-seed))

(unless parsed
  (put-string (current-error-port)
              "usage: test-fuzz.sps [SEED [MULTIPLIER]]  (decimal digits)\n")
  (exit 1))

(define run (make-property-run "fuzz" (car parsed) (cadr parsed)))

;; --- the corpus -----------------------------------------------------------------

(define dir "tests/corpus/jsontestsuite/test_parsing")

(define (prefix? p s)
  (and (>= (string-length s) (string-length p))
       (string=? p (substring s 0 (string-length p)))))

;; seeds : (Listof Bytevector), the y_ and n_ files of at most 4 KB
(define seeds
  (filter (lambda (bv) (<= (bytevector-length bv) 4096))
          (map (lambda (n) (file-bytes (string-append dir "/" n)))
               (filter (lambda (n) (or (prefix? "y_" n) (prefix? "n_" n)))
                       (corpus-files dir ".json")))))

;; --- mutations ------------------------------------------------------------------

(define (sub bv from to)
  (let ((out (make-bytevector (- to from))))
    (bytevector-copy! bv from out 0 (- to from))
    out))

(define (cat . bvs)
  (let ((out (make-bytevector (fold-left + 0 (map bytevector-length bvs)))))
    (fold-left (lambda (at bv)
                 (bytevector-copy! bv 0 out at (bytevector-length bv))
                 (+ at (bytevector-length bv)))
               0 bvs)
    out))

(define structural
  (map char->integer (string->list "[]{}\",:\\0123456789e-")))

;; insert-at : Bytevector Nat Nat -> Bytevector
(define (insert-at bv i b) (cat (sub bv 0 i) (bytevector b) (sub bv i (bytevector-length bv))))

(define (bytevector . xs) (u8-list->bytevector xs))

;; mutate : Nat Bytevector -> Gen Bytevector
;; The generator of mutation KIND (0 to 5) of BV; an empty BV can only grow.
(define (mutate kind bv)
  (let ((len (bytevector-length bv)))
    (cond
     ((and (= len 0) (not (memv kind '(1 2))))
      (mutate 1 bv))
     (else
      (case kind
        ;; flip one bit
        ((0) (lambda (s)
               (draw* s ((i (g-int len)) (bit (g-int 8)))
                 (let ((out (sub bv 0 len)))
                   (bytevector-u8-set! out i (bitwise-xor (bytevector-u8-ref bv i)
                                                          (bitwise-arithmetic-shift-left 1 bit)))
                   (cons out s)))))
        ;; insert a random byte
        ((1) (lambda (s)
               (draw* s ((i (g-range 0 len)) (b (g-int 256)))
                 (cons (insert-at bv i b) s))))
        ;; insert a structural byte
        ((2) (lambda (s)
               (draw* s ((i (g-range 0 len)) (b (g-pick structural)))
                 (cons (insert-at bv i b) s))))
        ;; delete a byte
        ((3) (lambda (s)
               (draw* s ((i (g-int len)))
                 (cons (cat (sub bv 0 i) (sub bv (+ i 1) len)) s))))
        ;; duplicate a range, in place
        ((4) (lambda (s)
               (draw* s ((i (g-int len)) (n (g-range 1 16)))
                 (let ((j (min len (+ i n))))
                   (cons (cat (sub bv 0 j) (sub bv i j) (sub bv j len)) s)))))
        ;; truncate
        (else (lambda (s)
                (draw* s ((n (g-int len)))
                  (cons (sub bv 0 n) s)))))))))

;; g-mutant : Bytevector -> Gen Bytevector
;; BV through one to three mutations.
(define (g-mutant bv)
  (lambda (s)
    (draw* s ((count (g-range 1 3)))
      (let loop ((k count) (bv bv) (s s))
        (if (= k 0)
            (cons bv s)
            (draw* s ((kind (g-int 6)) (next (mutate kind bv)))
              (loop (- k 1) next s)))))))


;; --- the property -----------------------------------------------------------------

;; A case is (bytes state depth-left mode): the mutant; the state its random
;; schedule is drawn from; and the settable fields, depth-left #f for the
;; default of 512.
(define depth-lefts '(#f #f #f 0 1 2 3 4))

(define (fields-of kase)
  (append (if (caddr kase) (list (cons 'depth-left (caddr kase))) '())
          (if (= (cadddr kase) 0) '() (list (cons 'mode (cadddr kase))))))

(define (gen-group s)
  (let loop ((k 0) (s s) (acc '()))
    (if (= k mutants-per-group)
        (reverse acc)
        (draw* s ((bv (g-pick seeds)) (m (g-mutant bv)) (st (g-int 32768))
                  (dl (g-pick depth-lefts)) (mode (g-pick '(0 0 1))))
          (loop (+ k 1) s (cons (list m st dl mode) acc))))))

(define tally (make-tally))

;; top-level-values : Trace -> Nat
;; How many values the trace's events complete at depth 0.
(define (top-level-values trace)
  (let loop ((xs trace) (depth 0) (n 0))
    (cond
     ((null? xs) n)
     (else
      (case (if (symbol? (car xs)) (car xs) #f)
        ((array-start object-start) (loop (cdr xs) (+ depth 1) n))
        ((array-end object-end)
         (loop (cdr xs) (- depth 1) (if (= depth 1) (+ n 1) n)))
        ((string-end true false null number-end)
         (loop (cdr xs) depth (if (= depth 0) (+ n 1) n)))
        (else (loop (cdr xs) depth n)))))))

(define (non-empty-feeds schedule)
  (length (filter (lambda (f) (> (caddr f) (cadr f))) schedule)))

;; check : Case -> (U #f Evidence)
(define (check kase)
  (let* ((bv (car kase))
         (len (bytevector-length bv))
         (fields (fields-of kase))
         (schedule (car (random-schedule bv (cadr kase))))
         (whole (run-machine generated-machine (whole-schedule bv) fields))
         (chunked (run-machine generated-machine schedule fields))
         (interpreted (run-machine interpreted-machine schedule fields))
         (outcome (trace-outcome whole)))
    (tally! tally 'case)
    (when (>= (non-empty-feeds schedule) 2) (tally! tally 'two-feeds))
    (tally! tally (if (eq? (car outcome) 'rejected) (cadr outcome) (car outcome)))
    (when (and (eq? (car outcome) 'accepted) (= (cadddr kase) 1)
               (> (top-level-values whole) 1))
      (tally! tally 'accepted-several-values))
    (cond
     ((not (memq (car outcome) '(accepted rejected)))
      (list 'verdict outcome))
     ((and (eq? (car outcome) 'rejected) (not (<= 0 (caddr outcome) len)))
      (list 'offset-outside outcome 'length len))
     ((not (equal? (trace-content whole) (trace-content chunked)))
      (list 'content-differs-by-schedule
            (trace-content whole) (trace-content chunked)))
     ((not (equal? chunked interpreted))
      (list 'machines-differ chunked interpreted))
     (else #f))))

;; shrinks : Case -> (Listof Case)
;; The mutant without a half, a quarter, then (if short) any one byte; and
;; the fields back to their defaults.
(define (shrinks kase)
  (let* ((bv (car kase)) (rest (cdr kase)) (len (bytevector-length bv)))
    (append
     (if (or (caddr kase) (not (= 0 (cadddr kase))))
         (list (list bv (cadr kase) #f 0))
         '())
     (map (lambda (b) (cons b rest))
          (append
           (if (> len 1)
               (let ((h (div len 2)))
                 (list (sub bv h len) (sub bv 0 h)))
               '())
           (if (> len 8)
               (let ((q (div len 4)))
                 (list (cat (sub bv 0 q) (sub bv (* 2 q) len))
                       (cat (sub bv 0 (* 2 q)) (sub bv (* 3 q) len))))
               '())
           (if (and (> len 0) (<= len 64))
               (let loop ((i 0) (acc '()))
                 (if (= i len)
                     (reverse acc)
                     (loop (+ i 1) (cons (cat (sub bv 0 i) (sub bv (+ i 1) len)) acc))))
               '()))))))

(test-begin "fuzz")

(test-equal "fuzz: no mutant breaks an invariant"
  '()
  (property-failures run 'invariants 1 groups gen-group check shrinks tally))

;; What the cases reached. Measured at the default seed and three others:
;; 88% of cases fell in two or more non-empty feeds (the rest are mutants of
;; 0 or 1 bytes, and short ones whose draws were empty), so 80% is the floor,
;; and the property's 4000 groups make a dip below it a change in the
;; schedule or the corpus, not luck. Accepted several-value cases with mode 1
;; were 43 to 60 of 20000.
(define (count key) (let ((p (assq key (tally-counts tally)))) (if p (cdr p) 0)))

(test-equal "fuzz: the mutants were accepted and rejected, for many reasons, with the depth limit reached"
  '(#t #t #t #t)
  (let ((counts (tally-counts tally)))
    (list (> (count 'accepted) 0)
          (> (length counts) 9)
          (exists (lambda (p) (and (not (memq (car p) '(accepted case two-feeds accepted-several-values)))
                                   (> (cdr p) 20)))
                  counts)
          (> (count 'nesting-too-deep) 0))))

(test-equal "fuzz: at least 80% of cases fell in two or more non-empty feeds"
  #t
  (>= (* 5 (count 'two-feeds)) (* 4 (count 'case))))

(test-equal "fuzz: some case with mode 1 was accepted holding several top-level values"
  #t
  (> (count 'accepted-several-values) 0))

(test-end "fuzz")

(exit (suite-exit-status runner))
