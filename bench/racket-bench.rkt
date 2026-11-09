#lang racket/base
;; bench/racket-bench.rkt: Racket's side of the benchmarks (ADR-0013, ADR-0024).
;;
;;   racket racket-bench.rkt ROUNDS ROUND-BYTES FILE...
;;
;; Parser `racket`, two lanes, in this order:
;;
;;   tree       read-json at its defaults, from (open-input-bytes bv) made
;;              inside the pass; fails unless only whitespace follows the value
;;   tree+walk  the same, then a walk of the jsexpr counting nine names
;;
;; Method as bench/yajl-bench.c's: one first pass outside the timing, a
;; warm-up round, ROUNDS timed rounds after (collect-garbage 'major), the
;; passes counted as they finish. Clock: current-inexact-monotonic-milliseconds
;; (Racket CS's monotonic clock, a flonum of ms), turned into exact ns.
;; Built with compiler/cm's managed-compile-zo (what `raco make` calls; the
;; racket-minimal in the bench container has no `raco make` command), with
;; PLTCOMPILEDROOTS=$(CURDIR)/build/bench/racket:. so no .zo lands in bench/.
(require json racket/file racket/symbol)

(define (die . parts)
  (let ((e (current-error-port)))
    (fprintf e "racket-bench: ")
    (for-each (lambda (p) (display p e)) parts)
    (newline e))
  (exit 1))

;; Writes S as a Scheme string literal.
(define (put-string s)
  (write-char #\")
  (for ((c (in-string s)))
    (when (or (char=? c #\") (char=? c #\\)) (write-char #\\))
    (write-char c))
  (write-char #\"))

(define (now-ns)
  (inexact->exact (round (* (current-inexact-monotonic-milliseconds) 1000000.0))))

(define (positive-integer s what)
  (unless (regexp-match? #rx"^[0-9]+$" s) (die what " is not a positive integer: " s))
  (let ((n (string->number s)))
    (when (zero? n) (die what " is not a positive integer: " s))
    n))

(define (basename p)
  (let-values (((base name dir?) (split-path p))) (path->string name)))

(define names '(null true false number string key object array text-bytes))
(define (slot name)
  (case name
    ((null) 0) ((true) 1) ((false) 2) ((number) 3) ((string) 4)
    ((key) 5) ((object) 6) ((array) 7) ((text-bytes) 8)))
(define NUL 0) (define TRU 1) (define FALS 2) (define NUM 3) (define STR 4)
(define KEY 5) (define OBJ 6) (define ARR 7) (define TXT 8)

(define (bump! c i n) (vector-set! c i (+ (vector-ref c i) n)))

;; Walks a jsexpr: hasheq with symbol keys, lists, 'null.
(define (walk! v c)
  (cond
    ((string? v) (bump! c STR 1) (bump! c TXT (string-utf-8-length v)))
    ((hash? v)
     (bump! c OBJ 1)
     (for (((k x) (in-hash v)))
       (bump! c KEY 1)
       (bump! c TXT (string-utf-8-length (symbol->immutable-string k)))
       (walk! x c)))
    ((or (pair? v) (null? v))
     (bump! c ARR 1)
     (for ((x (in-list v))) (walk! x c)))
    ((number? v) (bump! c NUM 1))
    ((eq? v #t) (bump! c TRU 1))
    ((eq? v #f) (bump! c FALS 1))
    ((eq? v 'null) (bump! c NUL 1))
    (else (error 'walk "unexpected value" v))))

;; Reads one value from BV, and fails unless only whitespace follows.
(define (read-tree bv)
  (let* ((in (open-input-bytes bv))
         (v (read-json in)))
    (let loop ()
      (let ((b (read-byte in)))
        (cond ((eof-object? b) v)
              ((or (eqv? b 32) (eqv? b 9) (eqv? b 10) (eqv? b 13)) (loop))
              (else (error 'read-tree "data after the value")))))))

(define passes 0)

;; A pass: PASS-FN takes the bytes and a counts vector (or #f).
(define (run-pass pass-fn bv counts)
  (pass-fn bv counts)
  (set! passes (+ passes 1)))

(define (tree-pass bv counts) (read-tree bv) (void))
(define (walk-pass bv counts) (walk! (read-tree bv) counts))

(define (flat-reason e)
  (let* ((m (if (exn? e) (exn-message e) (format "~a" e)))
         (m (regexp-replace* #rx"[\r\n]+" m " ")))
    (if (> (string-length m) 100) (substring m 0 100) m)))

(define (put-counts c)
  (for ((n (in-list names)))
    (printf " (~a . ~a)" n (vector-ref c (slot n)))))

(define (run-lane name bv size lane-name pass-fn counted? rounds round-bytes)
  (define iterations (quotient (+ round-bytes size -1) size))
  (define counts (make-vector 9 0))
  (define scratch (make-vector 9 0))
  (eprintf "racket-bench: ~a ~a\n" name lane-name)
  (define failure
    (with-handlers ((exn:break? raise) ((lambda (e) #t) flat-reason))
      (pass-fn bv (and counted? counts))
      #f))
  (cond
    (failure
     (printf "(failure (file ") (put-string name)
     (printf ") (parser racket) (lane ~a) (reason " lane-name)
     (put-string failure) (printf "))\n"))
    (else
     (set! passes 0)
     (for ((i (in-range iterations))) (run-pass pass-fn bv (and counted? scratch)))
     (define ns
       (for/list ((r (in-range rounds)))
         (collect-garbage 'major)
         (let ((t0 (now-ns)))
           (for ((i (in-range iterations))) (run-pass pass-fn bv (and counted? scratch)))
           (- (now-ns) t0))))
     (printf "(result (file ") (put-string name)
     (printf ") (bytes ~a) (parser racket) (lane ~a) (iterations ~a) (round-ns" size lane-name iterations)
     (for ((t (in-list ns))) (printf " ~a" t))
     (printf ") (counts")
     (when counted? (put-counts counts))
     (printf ") (passes ~a)" passes)
     (when counted?
       (printf " (timed-counts") (put-counts scratch) (printf ")"))
     (printf ")\n"))))

(define (main args)
  (when (< (length args) 3) (die "usage: racket-bench ROUNDS ROUND-BYTES FILE..."))
  (define rounds (positive-integer (car args) "ROUNDS"))
  (define round-bytes (positive-integer (cadr args) "ROUND-BYTES"))
  (printf "(runtime (parser racket) (version ")
  (put-string (format "Racket ~a [~a]" (version)
                      (let ((vm (system-type 'vm))) (if (eq? vm 'chez-scheme) "cs" vm))))
  (printf ") (how ")
  (put-string "compiled by compiler/cm (raco make's engine); read-json's defaults, from a bytes port")
  (printf ") (rounds ~a) (round-bytes ~a))\n" rounds round-bytes)
  (for ((path (in-list (cddr args))))
    (define bv (with-handlers ((exn:fail? (lambda (e) (die "cannot read " path))))
                 (file->bytes path)))
    (define size (bytes-length bv))
    (when (zero? size) (die "empty: " path))
    (define name (basename path))
    (run-lane name bv size 'tree tree-pass #f rounds round-bytes)
    (run-lane name bv size 'tree+walk walk-pass #t rounds round-bytes))
  (flush-output))

(module+ main
  (main (vector->list (current-command-line-arguments))))
