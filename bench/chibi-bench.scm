;;; bench/chibi-bench.scm: Chibi's side of the benchmarks (ADR-0013,
;;; ADR-0024).
;;;
;;;   chibi-scheme -h 1G bench/chibi-bench.scm ROUNDS ROUND-BYTES FILE...
;;;
;;; -h 1G starts the heap at 1 GB. At Chibi's default heap, the collector
;;; thrashes once a large value stays live while it is walked: on
;;; canada.json a tree+walk pass took 17 to 21 s, against 37 ms with the
;;; bigger heap. tree alone took the same either way.
;;;
;;; Two lanes per file, in this order:
;;;
;;;   tree       one pass reads one value with (chibi json)'s (json-read port)
;;;   tree+walk  the same, then a walk of the value counting nine names
;;;
;;; Chibi has no compiler: this file is interpreted, so the walk and the
;;; loops are interpreted code. json-read itself is C (json.so, sexp_json_read).
;;; A pass starts from the file's bytes in memory: open-input-bytevector makes
;;; the port inside the pass (a Chibi port reads characters from its bytes as
;;; UTF-8, so decoding is part of json-read), one value is read, and the pass
;;; fails unless only whitespace follows it.
;;;
;;; json-read builds: an object as an alist with symbol keys (each key
;;; interned; {} is ()), an array as a vector, a string as a fresh string, a
;;; number as a Scheme number, true as #t, false as #f and null as the symbol
;;; null. All seven kinds are told apart.
;;;
;;; Chibi has no monotonic clock. The best it has is gettimeofday, through
;;; (chibi time)'s get-time-of-day: a wall clock in whole microseconds.
;;;
;;; Output, method and checks are ADR-0023's and ADR-0024's; see
;;; bench/yajl-bench.c, which this follows.
(import (scheme base) (scheme write) (scheme file) (scheme process-context)
        (only (chibi) string-size) (chibi json) (chibi ast) (chibi time))

(define (die . parts)
  (let ((e (current-error-port)))
    (display "chibi-bench: " e)
    (for-each (lambda (p) (display p e)) parts)
    (newline e)
    (exit 1)))

;;; ---- the clock ----------------------------------------------------------

(define (now-ns)
  (let ((tv (car (get-time-of-day))))
    (* 1000 (+ (* 1000000 (timeval-seconds tv)) (timeval-microseconds tv)))))

;; The clock must tick in microseconds or finer: over many reads it must show
;; a step of 1000 ns, and none finer than that can exist in whole microseconds.
(define (check-clock!)
  (let loop ((i 0) (last (now-ns)) (step #f))
    (let ((t (now-ns)))
      (cond ((and step (>= i 1000)) step)
            ((> i 2000000) (die "clock never ticked"))
            ((= t last) (loop (+ i 1) last step))
            (else (if (< (abs (- t last)) 1000000)
                      (loop (+ i 1) t (if step (min step (abs (- t last))) (abs (- t last))))
                      (loop (+ i 1) t step)))))))

;;; ---- output --------------------------------------------------------------

(define (put-string s)
  (write-char #\")
  (string-for-each
   (lambda (c)
     (if (or (char=? c #\") (char=? c #\\)) (write-char #\\))
     (write-char c))
   s)
  (write-char #\"))

(define (put . parts) (for-each display parts))

(define (one-line s)
  (let* ((s (list->string
             (map (lambda (c) (if (or (char<? c #\space) (char>? c #\~)) #\space c))
                  (string->list s))))
         (n (string-length s)))
    (if (> n 100) (substring s 0 100) s)))

(define (exception-text e)
  (one-line
   (if (error-object? e)
       (let ((o (open-output-string)))
         (write-string (error-object-message e) o)
         (for-each (lambda (x) (write-char #\space o) (write x o))
                   (error-object-irritants e))
         (get-output-string o))
       (let ((o (open-output-string))) (write e o) (get-output-string o)))))

;;; ---- input ---------------------------------------------------------------

(define (read-file path)
  (let ((in (open-binary-input-file path)))
    (let loop ((chunks '()))
      (let ((b (read-bytevector 1048576 in)))
        (if (eof-object? b)
            (begin (close-port in) (apply bytevector-append (reverse chunks)))
            (loop (cons b chunks)))))))

(define (basename path)
  (let loop ((i (- (string-length path) 1)))
    (cond ((< i 0) path)
          ((char=? (string-ref path i) #\/)
           (substring path (+ i 1) (string-length path)))
          (else (loop (- i 1))))))

(define (positive-integer s what)
  (let ((n (and (> (string-length s) 0)
                (let loop ((i 0))
                  (or (= i (string-length s))
                      (and (char<=? #\0 (string-ref s i) #\9) (loop (+ i 1)))))
                (string->number s))))
    (if (and n (exact? n) (> n 0)) n (die what " is not a positive integer: " s))))

;;; ---- one pass ------------------------------------------------------------

(define (json-space? c)
  (or (char=? c #\space) (char=? c #\newline) (char=? c #\return) (char=? c #\tab)))

;; (bytevector -> value): one value from UTF-8 bytes; only whitespace may follow.
(define (read-one bv)
  (let* ((port (open-input-bytevector bv))
         (v (json-read port)))
    (let loop ()
      (let ((c (read-char port)))
        (cond ((eof-object? c) v)
              ((json-space? c) (loop))
              (else (error "trailing garbage after the value")))))))

;;; counts: a vector of nine integers, in this order
(define count-names
  '#(null true false number string key object array text-bytes))

(define (bump! counts i n) (vector-set! counts i (+ (vector-ref counts i) n)))

;; A Chibi string is stored as UTF-8, so its size in bytes is already known;
;; string-size reads it in O(1) (string-ref is O(n) on non-ASCII text).
(define (utf8-length s) (string-size s))

(define (walk! v counts)
  (cond ((string? v) (bump! counts 4 1) (bump! counts 8 (utf8-length v)))
        ((number? v) (bump! counts 3 1))
        ((eq? v #t) (bump! counts 1 1))
        ((eq? v #f) (bump! counts 2 1))
        ((eq? v 'null) (bump! counts 0 1))
        ((vector? v)
         (bump! counts 7 1)
         (let ((n (vector-length v)))
           (let loop ((i 0))
             (if (< i n) (begin (walk! (vector-ref v i) counts) (loop (+ i 1)))))))
        ((or (pair? v) (null? v))
         (bump! counts 6 1)
         (let loop ((l v))
           (if (pair? l)
               (begin
                 (bump! counts 5 1)
                 (bump! counts 8 (utf8-length (symbol->string (car (car l)))))
                 (walk! (cdr (car l)) counts)
                 (loop (cdr l))))))
        (else (error "unknown kind of value" v))))

;;; ---- the lanes -----------------------------------------------------------

(define passes 0)

(define (pass-tree bv counts)
  (read-one bv)
  (set! passes (+ passes 1)))

(define (pass-walk bv counts)
  (let ((v (read-one bv)))
    (walk! v counts)
    (set! passes (+ passes 1))))

(define (run-lane name bytes bv lane pass counted? rounds iterations)
  (define first-counts (make-vector 9 0))
  (define timed-counts (make-vector 9 0))
  (define ns (make-vector rounds 0))
  (define (fail reason)
    (put "(failure (file ") (put-string name) (put ") (parser chibi) (lane " lane
         ") (reason ") (put-string reason) (put "))\n")
    (flush-output-port))
  (define (many n)
    (let loop ((i 0))
      (if (< i n) (begin (pass bv timed-counts) (loop (+ i 1))))))
  (display (string-append "chibi-bench: " name " " (symbol->string lane) "\n")
           (current-error-port))
  (let ((ok (guard (e (#t (fail (exception-text e)) #f))
              (pass bv first-counts)
              #t)))
    (if ok
        (begin
          (set! passes 0)
          (many iterations)                      ; the warm-up round
          (let loop ((r 0))
            (if (< r rounds)
                (begin
                  (gc)
                  (let ((t0 (now-ns)))
                    (many iterations)
                    (vector-set! ns r (- (now-ns) t0)))
                  (loop (+ r 1)))))
          (put "(result (file ") (put-string name)
          (put ") (bytes " bytes ") (parser chibi) (lane " lane
               ") (iterations " iterations ") (round-ns")
          (vector-for-each (lambda (x) (put " " x)) ns)
          (put ") (counts")
          (if counted?
              (let loop ((i 0))
                (if (< i 9)
                    (begin (put " (" (vector-ref count-names i) " . "
                                (vector-ref first-counts i) ")")
                           (loop (+ i 1))))))
          (put ") (passes " passes ")")
          (if counted?
              (begin
                (put " (timed-counts")
                (let loop ((i 0))
                  (if (< i 9)
                      (begin (put " (" (vector-ref count-names i) " . "
                                  (vector-ref timed-counts i) ")")
                             (loop (+ i 1)))))
                (put ")")))
          (put ")\n")
          (flush-output-port)))))

(define (main args)
  (if (< (length args) 3) (die "usage: chibi-bench ROUNDS ROUND-BYTES FILE..."))
  (let ((rounds (positive-integer (car args) "ROUNDS"))
        (round-bytes (positive-integer (cadr args) "ROUND-BYTES"))
        (files (cddr args)))
    (check-clock!)
    (put "(runtime (parser chibi) (version ")
    (put-string (string-append "Chibi-Scheme " chibi-version))
    (put ") (how ")
    (put-string
     (string-append
      "interpreted, with a 1 GB heap (-h 1G): at the default the collector "
      "thrashes in tree+walk; json-read's defaults, a reader in C, from a "
      "bytevector port; timed by gettimeofday, as Chibi has no monotonic clock"))
    (put ") (rounds " rounds ") (round-bytes " round-bytes "))\n")
    (flush-output-port)
    (for-each
     (lambda (path)
       (let* ((bv (read-file path))
              (size (bytevector-length bv)))
         (if (<= size 0) (die "empty file: " path))
         (let ((name (basename path))
               (iterations (quotient (+ round-bytes size -1) size)))
           (run-lane name size bv 'tree pass-tree #f rounds iterations)
           (run-lane name size bv 'tree+walk pass-walk #t rounds iterations))))
     files)))

(guard (e (#t (display "chibi-bench: " (current-error-port))
              (display (exception-text e) (current-error-port))
              (newline (current-error-port))
              (exit 1)))
  (main (cdr (command-line))))
