#!r6rs
;;; (jsonparse-testing property): the arguments, the run record, the seeded
;;; sequence, the generators, draw* and let-pair*, safe-check, shrink, and
;;; the runner.
;;;
;;; The sequence's values below were computed outside Scheme, from the
;;; formulas the library's comments give, so a change to either fails here.
;;; An expected value is one the code under test cannot produce by failing:
;;; a refusal is compared against a sentinel for no raise, and a #f answer
;;; is mapped to a symbol of its own before it is compared.
;; Chez's current-output-port is a parameter, which (rnrs)'s is not.
(import (except (rnrs) current-output-port)
        (srfi :64)
        (only (chezscheme) parameterize current-output-port)
        (jsonparse-testing)
        (jsonparse-testing property))

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

;; raised : (-> Any) -> Any
;; What THUNK raised: (assertion-violation WHO IRRITANTS) for an assertion
;; violation, (other-raise TEXT) for anything else, and the symbol no-raise
;; if THUNK returned.
(define (raised thunk)
  (guard (e ((and (assertion-violation? e) (who-condition? e) (irritants-condition? e))
             (list 'assertion-violation (condition-who e) (condition-irritants e)))
            (#t (list 'other-raise (describe e))))
    (thunk)
    'no-raise))

;; answer : (-> Any) -> Any
;; THUNK's value, but the symbol false for #f, and (raised TEXT) for a raise.
(define (answer thunk)
  (guard (e (#t (list 'raised (describe e))))
    (let ((v (thunk)))
      (if (eq? v #f) 'false v))))

;; captured : (-> Any) -> (List Any String)
;; THUNK's value, and all it wrote on the current output port. A raise is
;; (raised TEXT), and what was written before it.
(define (captured thunk)
  (let-values (((port text) (open-string-output-port)))
    (let ((value (guard (e (#t (list 'raised (describe e))))
                   (parameterize ((current-output-port port)) (thunk)))))
      (list value (text)))))

(define (iota n) (let loop ((i (- n 1)) (acc '())) (if (< i 0) acc (loop (- i 1) (cons i acc)))))

;; draws : (Gen a) State Nat -> (Listof a)
;; N draws of G, in turn, from S.
(define (draws g s n)
  (car ((g-list n g) s)))

;; distinct : (Listof a) -> (Listof a)
;; The values of XS, each once, sorted as written.
(define (distinct xs)
  (let loop ((xs xs) (seen '()))
    (cond ((null? xs)
           (list-sort (lambda (a b) (string<? (written a) (written b))) seen))
          ((member (car xs) seen) (loop (cdr xs) seen))
          (else (loop (cdr xs) (cons (car xs) seen))))))

(define (written x) (call-with-string-output-port (lambda (p) (write x p))))

(define seed 20261030)

(test-begin "property")

;; --- the arguments ------------------------------------------------------------

(test-equal "arguments: none gives the default seed and a multiplier of 1"
  '(20261030 1)
  (answer (lambda () (parse-property-arguments '() 20261030))))

(test-equal "arguments: a seed alone, and a multiplier of 1"
  '(7 1)
  (answer (lambda () (parse-property-arguments '("7") 20261030))))

(test-equal "arguments: a seed and a multiplier"
  '(7 3)
  (answer (lambda () (parse-property-arguments '("7" "3") 20261030))))

(test-equal "arguments: a seed of 0 is a seed"
  '(0 1)
  (answer (lambda () (parse-property-arguments '("0") 20261030))))

(test-equal "arguments: what is not decimal digits, a multiplier of 0, and a third argument are refused"
  '(false false false false false false false false false false false)
  (map (lambda (args) (answer (lambda () (parse-property-arguments args 20261030))))
       '(("x") ("-1") ("1.5") ("+5") ("#x10") ("1e3") ("") ("7" "0") ("7" "x") ("7" "") ("7" "3" "1"))))

;; --- the run ------------------------------------------------------------------

(test-equal "make-property-run keeps its label, seed and multiplier"
  '("demo" 5 2)
  (answer (lambda ()
            (let ((run (make-property-run "demo" 5 2)))
              (list (property-run-label run) (property-run-seed run)
                    (property-run-multiplier run))))))

(test-equal "make-property-run refuses a label that is no string, a seed that is no natural, and a multiplier below 1"
  '((assertion-violation make-property-run (demo))
    (assertion-violation make-property-run (-1))
    (assertion-violation make-property-run (1.5))
    (assertion-violation make-property-run (0))
    no-raise)
  (list (raised (lambda () (make-property-run 'demo 5 1)))
        (raised (lambda () (make-property-run "demo" -1 1)))
        (raised (lambda () (make-property-run "demo" 1.5 1)))
        (raised (lambda () (make-property-run "demo" 5 0)))
        (raised (lambda () (make-property-run "demo" 0 1)))))

;; --- the sequence -------------------------------------------------------------

(test-equal "next-random is x * 1103515245 + 12345, modulo 2^31"
  '(12345 1103527590)
  (list (next-random 0) (next-random 1)))

(test-equal "case-state: the values computed outside Scheme"
  '(472499846 244768813 400858027 308485413 0)
  (list (case-state 20261030 1 0) (case-state 20261030 1 1) (case-state 20261030 2 0)
        (case-state 20261031 1 0) (case-state 0 0 0)))

(test-equal "g-int: the draws from a case's state computed outside Scheme, and the state after"
  '((922 87 717 699 506 208 761 613) . 236789854)
  ((g-list 8 (g-int 1000)) (case-state 20261030 1 0)))

;; 32768 is 1 x 20000 + 12768, so (g-int 20000) draws again whenever the
;; 15 bits are 20000 or more: these draws pass over two such states, which
;; the biased modulo would have answered 4506 and 6208.
(test-equal "g-int: draws that pass over a rejected state, computed outside Scheme, and the state after"
  '((18922 12087 11717 10699 4761 3613 18679 16595) . 1087618395)
  ((g-list 8 (g-int 20000)) (case-state 20261030 1 0)))

(test-equal "seeds count modulo 2^32: a seed of 2^32 or more is its remainder"
  (list (case-state 20261030 1 0) (case-state 0 2 3))
  (list (case-state (+ 4294967296 20261030) 1 0) (case-state (* 3 4294967296) 2 3)))

;; cases : Nat Nat -> (Listof (Listof Integer))
;; 200 cases of property PROP under SEED, each six draws in [-50, 50].
(define (cases-of seed prop)
  (map (lambda (i) (draws (g-range -50 50) (case-state seed prop i) 6)) (iota 200)))

(test-equal "the same seed gives the same cases, and they are not all one case"
  '(same 200)
  (let ((a (cases-of seed 3)) (b (cases-of seed 3)))
    (list (if (equal? a b) 'same 'differ) (length (distinct a)))))

(test-equal "another seed, or another property, gives other cases: every one of 200 differs"
  '(200 200)
  (let ((a (cases-of seed 3)) (b (cases-of (+ seed 1) 3)) (c (cases-of seed 4)))
    (list (length (filter (lambda (x) x) (map (lambda (x y) (not (equal? x y))) a b)))
          (length (filter (lambda (x) x) (map (lambda (x y) (not (equal? x y))) a c))))))

;; Neighbouring cases' states must not lie on a line: an affine case-state
;; repeats the first draw of (g-int 100) in about 1300 of 3999 neighbours,
;; and fills about 2500 of the 10000 pairs of two draws. Chance gives about
;; 40 and 3300.
(test-equal "neighbouring cases are unrelated: the first draw repeats in under 100 of 3999 neighbours, and two draws fill over 3100 of 10000 pairs"
  'unrelated
  (let* ((pairs (map (lambda (i) (draws (g-int 100) (case-state seed 1 i) 2)) (iota 4000)))
         (firsts (map car pairs))
         (repeats (length (filter (lambda (x) x) (map = (cdr firsts) (reverse (cdr (reverse firsts)))))))
         (filled (length (distinct pairs))))
    (if (and (< repeats 100) (> filled 3100)) 'unrelated (list repeats filled))))

;; --- the generators -----------------------------------------------------------

(define s0 (case-state seed 5 0))

(test-equal "g-int: every value in [0, n), and none outside"
  '(0 1 2 3 4 5 6)
  (distinct (draws (g-int 7) s0 2000)))

;; Uniform: 12768 of 20000 values is 63.84%, about 2554 of 4000 draws. The
;; 15 bits modulo 20000 would give those values 25536 of 32768, 77.9%,
;; about 3117.
(test-equal "g-int: uniform where n does not divide 32768: of 4000 draws of (g-int 20000), between 2400 and 2700 are below 12768"
  'uniform
  (let ((below (length (filter (lambda (x) (< x 12768)) (draws (g-int 20000) s0 4000)))))
    (if (<= 2400 below 2700) 'uniform below)))

(test-equal "g-int: n from 1 to 32768, an exact integer; anything else is refused when the generator is made"
  '((assertion-violation g-int (0))
    (assertion-violation g-int (32769))
    (assertion-violation g-int (1.5))
    (assertion-violation g-int (-1))
    (0)
    no-raise)
  (list (raised (lambda () (g-int 0)))
        (raised (lambda () (g-int 32769)))
        (raised (lambda () (g-int 1.5)))
        (raised (lambda () (g-int -1)))
        (distinct (draws (g-int 1) s0 50))
        (raised (lambda () (g-int 32768)))))

(test-equal "g-range: every value in [lo, hi], negative ones included"
  '(-3 -2 -1 0 1 2 3)
  (list-sort < (distinct (draws (g-range -3 3) s0 2000))))

(test-equal "g-range: a span over 32768 stays in range and reaches past 32767 and into its last block; a span of one is its value"
  '(in-range past-32767 past-98303 (5))
  (let ((xs (draws (g-range 0 100000) s0 2000)))
    (list (if (for-all (lambda (x) (<= 0 x 100000)) xs) 'in-range 'out-of-range)
          (if (exists (lambda (x) (> x 32767)) xs) 'past-32767 'never-past-32767)
          (if (exists (lambda (x) (> x 98303)) xs) 'past-98303 'never-past-98303)
          (distinct (draws (g-range 5 5) s0 20)))))

;; (g-range 0 32768) is 32769 values, one past a block: hi is the second
;; block's first value, drawn about once in 32769, so 200000 draws reach it.
(test-equal "g-range: a span of 32769 reaches lo and hi across 200000 draws, and never passes either"
  '(0 32768)
  (let ((xs (draws (g-range 0 32768) s0 200000)))
    (list (apply min xs) (apply max xs))))

(test-equal "g-range: lo above hi is refused"
  '(assertion-violation g-range (3 2))
  (raised (lambda () (g-range 3 2))))

(test-equal "g-const: the value, and the state unchanged"
  '(x . 42)
  ((g-const 'x) 42))

(test-equal "g-pick: every element, and nothing else"
  '(a b c)
  (distinct (draws (g-pick '(a b c)) s0 500)))

(test-equal "g-chance: 0 in n never, n in n always, 1 in 2 both"
  '((#f) (#t) (#f #t))
  (list (distinct (draws (g-chance 0 10) s0 500))
        (distinct (draws (g-chance 10 10) s0 500))
        (distinct (draws (g-chance 1 2) s0 500))))

(test-equal "g-weighted: a weight of 0 is never drawn; every other value is"
  '(a b)
  (distinct (draws (g-weighted '((0 . never) (3 . a) (1 . b))) s0 2000)))

(test-equal "g-choose: draws from a generator picked by weight, never one of weight 0"
  '(10 11 x)
  (distinct (draws (g-choose (list (cons 1 (g-const 'x)) (cons 0 (g-const 'y))
                                   (cons 1 (g-range 10 11))))
                   s0 2000)))

(test-equal "g-list: n draws, and for 0 none, with the state unchanged"
  '(5 () . 7)
  (cons* (length (car ((g-list 5 (g-int 3)) s0)))
         ((g-list 0 (g-int 3)) 7)))

(test-equal "g-list: each draw from the state the one before left"
  (let* ((p1 ((g-int 1000) s0)) (p2 ((g-int 1000) (cdr p1))) (p3 ((g-int 1000) (cdr p2))))
    (cons (list (car p1) (car p2) (car p3)) (cdr p3)))
  ((g-list 3 (g-int 1000)) s0))

(test-equal "g-shuffle: every element comes first in some order, and last in some other"
  '((1 2 3 4 5 6) (1 2 3 4 5 6))
  (let ((orders (draws (g-shuffle '(1 2 3 4 5 6)) s0 200)))
    (list (list-sort < (distinct (map car orders)))
          (list-sort < (distinct (map (lambda (o) (list-ref o 5)) orders))))))

(test-equal "g-shuffle: always a permutation, and more than one order"
  '(permutations several-orders)
  (let ((orders (draws (g-shuffle '(1 2 3 4 5 6)) s0 200)))
    (list (if (for-all (lambda (o) (equal? (list-sort < o) '(1 2 3 4 5 6))) orders)
              'permutations 'not-permutations)
          (if (> (length (distinct orders)) 50) 'several-orders (distinct orders)))))

;; --- draw* and let-pair* --------------------------------------------------------

(test-equal "draw*: each draw from the state the one before left, and the body sees the last state"
  (let* ((p1 ((g-int 1000) s0)) (p2 ((g-range 1 9) (cdr p1))))
    (list (car p1) (car p2) (cdr p2)))
  (let ((s s0))
    (draw* s ((a (g-int 1000)) (b (g-range 1 9)))
      (list a b s))))

(test-equal "draw*: a generator may use the draws before it"
  'lengths-match
  (let loop ((i 0))
    (cond ((= i 100) 'lengths-match)
          ((let ((s (case-state seed 6 i)))
             (draw* s ((n (g-range 0 5)) (xs (g-list n (g-int 10))))
               (= (length xs) n)))
           (loop (+ i 1)))
          (else (list 'mismatch i)))))

(test-equal "draw*: with no binding it is its body"
  'body
  (let ((s s0)) (draw* s () 'body)))

(test-equal "let-pair*: each pair's car and cdr, in turn"
  '(1 2 1 2)
  (let-pair* (((a b) (cons 1 2)) ((c d) (cons a b)))
    (list a b c d)))

;; --- safe-check -----------------------------------------------------------------

(test-equal "safe-check: a pass is #f, evidence is itself"
  '(false (big 9))
  (list (answer (lambda () (safe-check (lambda (c) #f) 9)))
        (answer (lambda () (safe-check (lambda (c) (list 'big c)) 9)))))

(test-equal "safe-check: a check that raises fails, with what it raised"
  '((check-raised "Exception in chk: boom with irritant 7")
    (check-raised "oops"))
  (list (answer (lambda () (safe-check (lambda (c) (error 'chk "boom" c)) 7)))
        (answer (lambda () (safe-check (lambda (c) (raise 'oops)) 7)))))

;; --- shrink -----------------------------------------------------------------------

;; long-list : (Listof Nat) -> (U #f Evidence)
;; The property "every list is shorter than 3", false.
(define (long-list xs)
  (and (>= (length xs) 3) (list 'length (length xs))))

;; list-shrinks : (Listof Nat) -> (Listof (Listof Nat))
;; XS without one element, then XS with one element 0, halved or one less.
(define (list-shrinks xs)
  (define (remove-at xs i) (append (list-head xs i) (list-tail xs (+ i 1))))
  (define (list-head xs i) (if (= i 0) '() (cons (car xs) (list-head (cdr xs) (- i 1)))))
  (define (replace-at xs i x) (append (list-head xs i) (cons x (list-tail xs (+ i 1)))))
  (let ((n (length xs)))
    (append (map (lambda (i) (remove-at xs i)) (iota n))
            (apply append
                   (map (lambda (i)
                          (let ((x (list-ref xs i)))
                            (if (> x 0)
                                (list (replace-at xs i 0) (replace-at xs i (div x 2))
                                      (replace-at xs i (- x 1)))
                                '())))
                        (iota n))))))

(test-equal "shrink: \"every list is shorter than 3\" shrinks to three zeros"
  '(0 0 0)
  (shrink '(57 3 99 12 8 41) long-list list-shrinks))

(test-equal "shrink: every generated list of 3 or more shrinks to three zeros"
  '((0 0 0))
  (distinct
   (map (lambda (i)
          (let ((s (case-state seed 7 i)))
            (draw* s ((n (g-range 3 9)) (xs (g-list n (g-range 0 1000))))
              (shrink xs long-list list-shrinks))))
        (iota 50))))

(test-equal "shrink: a case with no smaller failing case is itself"
  '((1 2 3) (0 0 0))
  (list (shrink '(1 2 3) long-list (lambda (c) '()))
        (shrink '(0 0 0) long-list list-shrinks)))

(test-equal "shrink: it takes the first smaller case that fails, in the order given"
  3
  (shrink 100 (lambda (n) (and (or (>= n 5) (= n 3)) 'fails))
          (lambda (n) (list (div n 2) (- n 1)))))

(test-equal "shrink: it stops after 500 steps"
  500
  (shrink 0 (lambda (n) 'fails) (lambda (n) (list (+ n 1)))))

(test-equal "shrink: a shrink that raises in the check is a failing case, and is taken"
  'raised-case
  (shrink 'start (lambda (c) (if (eq? c 'raised-case) (car c) 'fails))
          (lambda (c) (if (eq? c 'start) '(raised-case) '()))))

;; --- the runner -------------------------------------------------------------------

(define (run-of seed multiplier) (make-property-run "demo" seed multiplier))

;; summary : String Symbol Nat Nat String -> String
(define (summary name ran failed tallies)
  (string-append "demo: " name ": " (number->string ran) " cases, " (number->string failed)
                 " failing" tallies "\n"))

;; reported : Any -> String
(define (reported failure)
  (string-append "demo: failing case:\n" (written failure) "\n"))

(test-equal "runner: a property that holds answers (), and its summary"
  (list '() (summary "P0" 4 0 ""))
  (captured (lambda ()
              (property-failures (run-of seed 1) 'P0 0 4 (lambda (s) (list s))
                                 (lambda (c) #f) (lambda (c) '()) (make-tally)))))

(test-equal "runner: each group of cases comes from case-state of the run's seed, the property and the group's index"
  (map (lambda (i) (case-state seed 9 i)) (iota 5))
  (let ((seen '()))
    (captured (lambda ()
                (property-failures (run-of seed 1) 'P9 9 5 (lambda (s) (list s))
                                   (lambda (c) (set! seen (cons c seen)) #f)
                                   (lambda (c) '()) (make-tally))))
    (reverse seen)))

(test-equal "runner: the multiplier multiplies the groups, and every case of a group runs"
  (list '() (summary "P0" 24 0 ""))
  (captured (lambda ()
              (property-failures (run-of seed 3) 'P0 0 4 (lambda (s) (list 1 2))
                                 (lambda (c) #f) (lambda (c) '()) (make-tally)))))

;; big-cases : Nat Nat -> (Listof (List Nat Nat))
;; Under SEED, for each of N groups whose one case is a draw of (g-int 1000),
;; that case and the group's index, where the case is 500 or more.
(define (big-cases seed n)
  (filter (lambda (x) x)
          (map (lambda (i)
                 (let ((c (car ((g-int 1000) (case-state seed 1 i)))))
                   (and (>= c 500) (list c i))))
               (iota n))))

(define (big c) (and (>= c 500) (list 'big c)))
(define (one-draw s) (list (car ((g-int 1000) s))))

(test-equal "runner: failing cases are shrunk, a case shrunk to one already reported is counted and not reported again, and each reported is written as data with the seed and its index"
  (let* ((found (big-cases seed 20))
         (first (car found))
         (failure (list 'P1 'seed seed 'case (cadr first) 0 'minimised 500 'evidence '(big 500))))
    (list (list failure (list 'and (- (length found) 1) 'more))
          (string-append (reported failure) (summary "P1" 20 (length found) ""))))
  (captured (lambda ()
              (property-failures (run-of seed 1) 'P1 1 20 one-draw big
                                 (lambda (c) (if (> c 500) (list 500 (- c 1)) '()))
                                 (make-tally)))))

(test-equal "runner: at most three failures are reported, then how many more failed"
  (let* ((found (big-cases seed 20))
         (failures (map (lambda (f) (list 'P1 'seed seed 'case (cadr f) 0 'minimised (car f)
                                          'evidence (list 'big (car f))))
                        (list (car found) (cadr found) (caddr found)))))
    (list (append failures (list (list 'and (- (length found) 3) 'more)))
          (string-append (apply string-append (map reported failures))
                         (summary "P1" 20 (length found) ""))))
  (captured (lambda ()
              (property-failures (run-of seed 1) 'P1 1 20 one-draw big (lambda (c) '())
                                 (make-tally)))))

(test-equal "runner: a check that raises is a failing case, with what it raised"
  (let ((failure (list 'P2 'seed 7 'case 0 1 'minimised 2
                       'evidence '(check-raised "Exception in chk: boom with irritant 2"))))
    (list (list failure '(and 1 more))
          (string-append (reported failure) (summary "P2" 6 2 ""))))
  (captured (lambda ()
              (property-failures (run-of 7 1) 'P2 2 2 (lambda (s) (list 1 2 3))
                                 (lambda (c) (if (= c 2) (error 'chk "boom" c) #f))
                                 (lambda (c) '()) (make-tally)))))

(test-equal "runner: the tallies, sorted by name, after the counts"
  (list '() (summary "P3" 6 0 " (one 3, two 3)"))
  (let ((t (make-tally)))
    (captured (lambda ()
                (property-failures (run-of seed 1) 'P3 3 3 (lambda (s) (list 1 2))
                                   (lambda (c) (tally! t (if (= c 1) 'one 'two)) #f)
                                   (lambda (c) '()) t)))))

(test-equal "tally-counts: each key and how often it was tallied"
  '((a . 2) (b . 1))
  (let ((t (make-tally)))
    (tally! t 'a) (tally! t 'b) (tally! t 'a)
    (list-sort (lambda (x y) (string<? (symbol->string (car x)) (symbol->string (car y))))
               (tally-counts t))))

;; The way a suite uses the runner: its actual value is the failures, and
;; its expected value '().
(define reverse-tally (make-tally))

(test-equal "a property as a suite states it: reversing a list twice gives it back"
  '()
  (property-failures (run-of seed 1) 'reverse 10 300
                     (lambda (s)
                       (draw* s ((n (g-range 0 8)) (xs (g-list n (g-range -9 9))))
                         (tally! reverse-tally (if (null? xs) 'empty 'nonempty))
                         (list xs)))
                     (lambda (xs) (and (not (equal? (reverse (reverse xs)) xs))
                                       (list 'got (reverse (reverse xs)))))
                     list-shrinks reverse-tally))

(test-end "property")

(exit (suite-exit-status runner))
