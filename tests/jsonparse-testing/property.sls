#!r6rs
;;; (jsonparse-testing property): seeded property tests, modelled on
;;; circuit's tests/test-router-properties.sps (ADR-0012).
;;;
;;;   the arguments  parse-property-arguments: [SEED [MULTIPLIER]]
;;;   the run        make-property-run: a label, a seed and a multiplier
;;;   the sequence   next-random, case-state
;;;   generators     g-int g-range g-const g-pick g-chance g-weighted
;;;                  g-choose g-list g-shuffle, drawn with draw*
;;;   pairs          let-pair*
;;;   the runner     safe-check, shrink, property-failures, and tallies
;;;
;;; A case's random state comes from the seed, the property's number and the
;;; case's index alone, so a seed means the same everywhere. A failing case
;;; is shrunk, then written to stdout as data with the seed and its index,
;;; ready to paste. A suite asserts a property with the runner's failures as
;;; the actual value and '() as the expected one.
;;;
;;; The seed is an argument, in a run record: R6RS forbids assigning an
;;; exported variable, and the library holds no state of its own. A tally is
;;; the caller's, made by make-tally.
;;;
;;; Test-only: it lives in tests/, on make test's library path. Its suite is
;;; tests/test-property.sps.
(library (jsonparse-testing property)
  (export parse-property-arguments
          make-property-run property-run? property-run-label property-run-seed
          property-run-multiplier
          next-random case-state
          g-int g-range g-const g-pick g-chance g-weighted g-choose g-list g-shuffle
          draw* let-pair*
          safe-check shrink property-failures
          make-tally tally! tally-counts)
  (import (rnrs)
          (jsonparse-testing))

  ;; --- the arguments ----------------------------------------------------------

  ;; parse-property-arguments : (Listof String) Nat -> (U (List Nat Positive-Integer) #f)
  ;; A suite's program arguments, [SEED [MULTIPLIER]]: the seed, DEFAULT-SEED
  ;; when none is given, and the multiplier, 1 when none is given. #f when
  ;; either is not decimal digits, the multiplier is 0, or there are more.
  (define (parse-property-arguments args default-seed)
    (let ((nat (lambda (text)
                 (and (> (string-length text) 0)
                      (for-all (lambda (c) (and (char<=? #\0 c) (char<=? c #\9)))
                               (string->list text))
                      (string->number text 10)))))
      (cond ((null? args) (list default-seed 1))
            ((null? (cdr args))
             (let ((s (nat (car args)))) (and s (list s 1))))
            ((null? (cddr args))
             (let ((s (nat (car args))) (m (nat (cadr args))))
               (and s m (> m 0) (list s m))))
            (else #f))))

  ;; --- the run ----------------------------------------------------------------

  ;; A Property-Run is what every property of one suite shares: the label
  ;; its lines on stdout begin with, the seed, and the multiplier of every
  ;; property's case count.
  ;;
  ;; property-run? : Any -> Boolean
  ;; property-run-label : Property-Run -> String
  ;; property-run-seed : Property-Run -> Nat
  ;; property-run-multiplier : Property-Run -> Positive-Integer
  (define-record-type (property-run new-property-run property-run?)
    (fields (immutable label property-run-label)
            (immutable seed property-run-seed)
            (immutable multiplier property-run-multiplier)))

  ;; make-property-run : String Nat Positive-Integer -> Property-Run
  ;; Refuses, with an assertion violation naming the value, a label that is
  ;; no string, a seed that is no exact natural, a multiplier below 1.
  (define (make-property-run label seed multiplier)
    (unless (string? label)
      (assertion-violation 'make-property-run "a label is a string" label))
    (unless (and (integer? seed) (exact? seed) (>= seed 0))
      (assertion-violation 'make-property-run "a seed is an exact natural number" seed))
    (unless (and (integer? multiplier) (exact? multiplier) (>= multiplier 1))
      (assertion-violation 'make-property-run "a multiplier is an exact integer, 1 or more"
                           multiplier))
    (new-property-run label seed multiplier))

  ;; --- the sequence -----------------------------------------------------------

  ;; State = Nat, below 2^31.
  ;; Gen a = State -> (Pair a State): a draw takes the state and answers the
  ;; value and the next state. draw* binds draws in turn, each from the state
  ;; the one before left, so no two draws are ever arguments of one call:
  ;; Chez evaluates a call's arguments right to left in compiled code and
  ;; left to right when interpreted, so two draws as arguments would differ.

  ;; next-random : State -> State
  ;; The linear congruential sequence: x * 1103515245 + 12345, modulo 2^31.
  (define (next-random x) (mod (+ (* x 1103515245) 12345) 2147483648))

  ;; mix : Nat -> State
  ;; X modulo 2^32 through murmur3's 32-bit finalizer, then modulo 2^31. It
  ;; is not affine, so the states of neighbouring cases are unrelated: an
  ;; affine case-state, as the linear sequence alone would give, puts every
  ;; draw of case i on a line in i, and neighbouring cases draw alike.
  (define (mix x)
    (let* ((x (mod x 4294967296))
           (x (bitwise-xor x (bitwise-arithmetic-shift-right x 16)))
           (x (mod (* x #x85ebca6b) 4294967296))
           (x (bitwise-xor x (bitwise-arithmetic-shift-right x 13)))
           (x (mod (* x #xc2b2ae35) 4294967296))
           (x (bitwise-xor x (bitwise-arithmetic-shift-right x 16))))
      (mod x 2147483648)))

  ;; case-state : Nat Nat Nat -> State
  ;; The first state of case INDEX of property PROP under SEED:
  ;; mix(mix(mix(SEED) + PROP) + INDEX). A seed counts modulo 2^32.
  (define (case-state seed prop index)
    (mix (+ (mix (+ (mix seed) prop)) index)))

  ;; g-int : Positive-Integer -> Gen Nat
  ;; A whole number in [0, n), n from 1 to 32768, each as likely as the
  ;; next: the next state's bits 16 to 30, modulo n, drawn again while those
  ;; 15 bits are at or above the largest multiple of n not above 32768. The
  ;; bare modulo would favour the low values whenever n does not divide
  ;; 32768. Any other n is refused when the generator is made, since the
  ;; bits hold no more.
  (define (g-int n)
    (unless (and (integer? n) (exact? n) (<= 1 n 32768))
      (assertion-violation 'g-int "n is an exact integer from 1 to 32768" n))
    (let ((limit (* n (div 32768 n))))
      (lambda (s)
        (let retry ((s (next-random s)))
          (let ((bits (div s 65536)))
            (if (< bits limit)
                (cons (mod bits n) s)
                (retry (next-random s))))))))

  ;; g-range : Integer Integer -> Gen Integer
  ;; A whole number in [lo, hi]. A span over 32768 draws blocks of 32768 and
  ;; draws again when past hi. lo above hi is refused.
  (define (g-range lo hi)
    (unless (and (integer? lo) (exact? lo) (integer? hi) (exact? hi) (<= lo hi))
      (assertion-violation 'g-range "lo and hi are exact integers, lo at most hi" lo hi))
    (let ((n (+ (- hi lo) 1)))
      (if (<= n 32768)
          (let ((g (g-int n)))
            (lambda (s) (draw* s ((i g)) (cons (+ lo i) s))))
          (let* ((blocks (div (+ n 32767) 32768))
                 (g-block (g-int blocks))
                 (g-offset (g-int 32768)))
            (lambda (s)
              (let retry ((s s))
                (draw* s ((a g-block) (b g-offset))
                  (let ((x (+ (* a 32768) b)))
                    (if (< x n) (cons (+ lo x) s) (retry s))))))))))

  ;; g-const : a -> Gen a
  ;; V, and the state unchanged.
  (define (g-const v) (lambda (s) (cons v s)))

  ;; g-pick : (Listof a) -> Gen a
  ;; One of XS, which is not empty.
  (define (g-pick xs)
    (let ((g (g-int (length xs))))
      (lambda (s) (draw* s ((i g)) (cons (list-ref xs i) s)))))

  ;; g-chance : Nat Positive-Integer -> Gen Boolean
  ;; #t K times in N.
  (define (g-chance k n)
    (let ((g (g-int n)))
      (lambda (s) (draw* s ((i g)) (cons (< i k) s)))))

  ;; g-weighted : (Listof (Pair Nat a)) -> Gen a
  ;; One of the values, each as often as its weight; a weight of 0 never.
  (define (g-weighted pairs)
    (let ((g (g-int (fold-left + 0 (map car pairs)))))
      (lambda (s)
        (draw* s ((i g))
          (cons (let loop ((ps pairs) (i i))
                  (if (< i (caar ps)) (cdar ps) (loop (cdr ps) (- i (caar ps)))))
                s)))))

  ;; g-choose : (Listof (Pair Nat (Gen a))) -> Gen a
  ;; A draw from one of the generators, picked by weight.
  (define (g-choose pairs)
    (let ((pick (g-weighted pairs)))
      (lambda (s) (draw* s ((g pick)) (g s)))))

  ;; g-list : Nat (Gen a) -> Gen (Listof a)
  ;; N draws of G, in turn.
  (define (g-list n g)
    (lambda (s)
      (let loop ((i 0) (acc '()) (s s))
        (if (= i n)
            (cons (reverse acc) s)
            (draw* s ((x g)) (loop (+ i 1) (cons x acc) s))))))

  ;; g-shuffle : (Listof a) -> Gen (Listof a)
  ;; XS in an order drawn.
  (define (g-shuffle xs)
    (lambda (s)
      (let loop ((xs xs) (acc '()) (s s))
        (if (null? xs)
            (cons acc s)
            (draw* s ((i (g-int (length xs))))
              (loop (remove-at xs i) (cons (list-ref xs i) acc) s))))))

  (define (remove-at xs i)
    (if (= i 0) (cdr xs) (cons (car xs) (remove-at (cdr xs) (- i 1)))))

  ;; (draw* s ((x g) ...) body ...)
  ;; Binds each x to a draw of its g, in turn, rebinding s to the state each
  ;; draw leaves; a g may use the x before it. The body sees the last s.
  (define-syntax draw*
    (syntax-rules ()
      ((_ s () body0 body ...) (let () body0 body ...))
      ((_ s ((x g) more ...) body0 body ...)
       (let* ((drawn (g s)) (x (car drawn)) (s (cdr drawn)))
         (draw* s (more ...) body0 body ...)))))

  ;; (let-pair* (((a b) e) ...) body ...)
  ;; Binds each pair's car and cdr, in turn, as let*-values would two
  ;; values. Generators answer pairs, never multiple values: Chez 10.4.1's
  ;; cp0 miscompiles a let-values over a producer it inlines in two places,
  ;; and raises "incorrect number of values" where none is wrong.
  (define-syntax let-pair*
    (syntax-rules ()
      ((_ () body0 body ...) (let () body0 body ...))
      ((_ (((a b) e) more ...) body0 body ...)
       (let* ((pr e) (a (car pr)) (b (cdr pr))) (let-pair* (more ...) body0 body ...)))))

  ;; --- the runner -------------------------------------------------------------

  ;; Check = Case -> (U #f Evidence): #f when the case holds.
  ;; Shrinks = Case -> (Listof Case): smaller cases, the likeliest first.

  ;; safe-check : Check Case -> (U #f Evidence)
  ;; A raise in a check is a failing case, (check-raised TEXT), so one raise
  ;; hides no other.
  (define (safe-check check kase)
    (guard (e (#t (list 'check-raised (describe e))))
      (check kase)))

  ;; shrink : Case Check Shrinks -> Case
  ;; The first smaller case that still fails, again and again, until none
  ;; does or 500 steps are taken.
  (define (shrink kase check shrinks)
    (let loop ((kase kase) (steps 0))
      (if (>= steps 500)
          kase
          (let ((next (find (lambda (c) (safe-check check c)) (shrinks kase))))
            (if next (loop next (+ steps 1)) kase)))))

  ;; How many failures a property shrinks and reports; the rest are counted.
  (define shrunk-at-most 3)

  ;; Failure = (List Symbol 'seed Nat 'case Nat Nat 'minimised Case 'evidence Evidence)
  ;;         | (List 'and Positive-Integer 'more)

  ;; property-failures : Property-Run Symbol Nat Nat (State -> (Listof Case))
  ;;                     Check Shrinks Tally -> (Listof Failure)
  ;; Runs N times the run's multiplier groups of cases: group I is GEN-CASES
  ;; of (case-state seed PROP I), and every case of it is checked. The first
  ;; failures, up to three, are shrunk and written to stdout, each as data
  ;; with the seed, I and its place J in the group; one that shrinks to a
  ;; case already reported is counted, not reported again. Then one summary
  ;; line: NAME, the cases run, the failing ones, and TALLY's counts. The
  ;; answer is the failures, then (and K more) when K more failed.
  (define (property-failures run name prop n gen-cases check shrinks tally)
    (let ((seed (property-run-seed run))
          (groups (* n (property-run-multiplier run))))
      (let loop ((i 0) (found '()) (failed 0) (ran 0))
        (if (= i groups)
            (begin
              (summary! run name ran failed tally)
              (append (reverse found)
                      (if (> failed (length found))
                          (list (list 'and (- failed (length found)) 'more))
                          '())))
            (let walk ((cases (gen-cases (case-state seed prop i))) (j 0)
                       (found found) (failed failed) (ran ran))
              (if (null? cases)
                  (loop (+ i 1) found failed ran)
                  (let ((evidence (safe-check check (car cases))))
                    (cond
                      ((not evidence) (walk (cdr cases) (+ j 1) found failed (+ ran 1)))
                      ((< (length found) shrunk-at-most)
                       (let* ((small (shrink (car cases) check shrinks))
                              (ev (safe-check check small))
                              (failure (list name 'seed seed 'case i j 'minimised small 'evidence ev))
                              (seen (exists (lambda (f) (equal? (list-ref f 7) small)) found)))
                         (unless seen (report! run failure))
                         (walk (cdr cases) (+ j 1) (if seen found (cons failure found))
                               (+ failed 1) (+ ran 1))))
                      (else (walk (cdr cases) (+ j 1) found (+ failed 1) (+ ran 1)))))))))))

  ;; report! : Property-Run Failure -> Unit
  (define (report! run failure)
    (let ((out (current-output-port)))
      (put-string out (string-append (property-run-label run) ": failing case:\n"))
      (write failure out)
      (newline out)
      (flush-output-port out)))

  ;; --- tallies ----------------------------------------------------------------

  ;; A Tally counts what a property's cases exercised, by key.
  (define-record-type (tally new-tally tally?)
    (fields (mutable counts tally-counts set-tally-counts!)))

  ;; make-tally : -> Tally
  ;; An empty tally.
  (define (make-tally) (new-tally '()))

  ;; tally! : Tally Symbol -> Unit
  ;; Counts KEY once more.
  (define (tally! t key)
    (let* ((counts (tally-counts t)) (p (assq key counts)))
      (set-tally-counts! t (cons (cons key (if p (+ (cdr p) 1) 1))
                                 (filter (lambda (q) (not (eq? (car q) key))) counts)))))

  ;; tally-counts : Tally -> (Listof (Pair Symbol Positive-Integer))
  ;; Each key counted, and how often, in no set order.

  ;; summary! : Property-Run Symbol Nat Nat Tally -> Unit
  ;; LABEL: NAME: RAN cases, FAILED failing (key count, ...), keys by name.
  (define (summary! run name ran failed tally)
    (let ((out (current-output-port))
          (counts (list-sort (lambda (a b) (string<? (symbol->string (car a))
                                                     (symbol->string (car b))))
                             (tally-counts tally))))
      (put-string out (string-append (property-run-label run) ": " (symbol->string name) ": "
                                     (number->string ran) " cases, " (number->string failed)
                                     " failing"))
      (unless (null? counts)
        (put-string out " (")
        (put-string out (car (fold-left
                              (lambda (acc p)
                                (let ((item (string-append (symbol->string (car p)) " "
                                                           (number->string (cdr p)))))
                                  (if (cdr acc)
                                      (cons (string-append (car acc) ", " item) #t)
                                      (cons item #t))))
                              (cons "" #f)
                              counts)))
        (put-string out ")"))
      (newline out)
      (flush-output-port out))))
