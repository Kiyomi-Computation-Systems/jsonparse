;;; bench/guile-bench.scm: guile-json's side of the benchmarks (ADR-0013, ADR-0024).
;;;
;;;   guile --no-auto-compile -c '(load-compiled "build/bench/guile/guile-bench.go")' \
;;;     ROUNDS ROUND-BYTES FILE...
;;;
;;; Parser `guile-json`, two lanes, in this order:
;;;
;;;   tree       json->scm at its defaults, from a bytevector input port over
;;;              the file's bytes with its encoding set to UTF-8, both made
;;;              inside the pass; json->scm itself fails unless only
;;;              whitespace follows the value
;;;   tree+walk  the same, then a walk of the value counting nine names
;;;
;;; guile-json 4's values: an object is an alist of (string . value) pairs
;;; ('() for {}), an array a vector, null the symbol null, true and false #t
;;; and #f, strings strings, numbers numbers.
;;;
;;; Method as bench/yajl-bench.c's: one first pass outside the timing, a
;;; warm-up round, ROUNDS timed rounds after (gc), the passes counted as they
;;; finish. Clock: CLOCK_MONOTONIC, by clock_gettime(2) through Guile's
;;; foreign function interface. Guile's own clocks aren't monotonic:
;;; get-internal-real-time reads CLOCK_REALTIME, and SRFI 19's
;;; time-monotonic gettimeofday. Compiled by `guild compile` into
;;; build/bench/guile/.
(use-modules (json) (rnrs io ports) (rnrs bytevectors) (ice-9 match)
             (ice-9 format) (srfi srfi-1) (system foreign))

(define (die . parts)
  (let ((e (current-error-port)))
    (display "guile-bench: " e)
    (for-each (lambda (p) (display p e)) parts)
    (newline e))
  (exit 1))

;; Writes S as a Scheme string literal.
(define (put-string s)
  (write-char #\")
  (string-for-each
   (lambda (c)
     (when (or (char=? c #\") (char=? c #\\)) (write-char #\\))
     (write-char c))
   s)
  (write-char #\"))

;; CLOCK_MONOTONIC is 1 on Linux and 6 on macOS. A struct timespec is two
;; longs on both, seconds then nanoseconds.
(define clock-monotonic
  (let ((os (utsname:sysname (uname))))
    (cond ((string=? os "Linux") 1)
          ((string=? os "Darwin") 6)
          (else (die "no CLOCK_MONOTONIC known for " os)))))

(define clock-gettime
  (pointer->procedure int (dynamic-func "clock_gettime" (dynamic-link)) (list int '*)))

(define timespec (make-bytevector (* 2 (sizeof long)) 0))

(define (now-ns)
  (unless (zero? (clock-gettime clock-monotonic (bytevector->pointer timespec)))
    (die "clock_gettime failed"))
  (+ (* 1000000000 (bytevector-sint-ref timespec 0 (native-endianness) (sizeof long)))
     (bytevector-sint-ref timespec (sizeof long) (native-endianness) (sizeof long))))

(define (positive-integer s what)
  (let ((n (and (> (string-length s) 0)
                (string-every char-numeric? s)
                (string->number s))))
    (unless (and n (exact-integer? n) (> n 0))
      (die what " is not a positive integer: " s))
    n))

(define (basename p)
  (let ((i (string-rindex p #\/))) (if i (substring p (+ i 1)) p)))

(define (read-file path)
  (call-with-input-file path get-bytevector-all #:binary #t))

(define names '(null true false number string key object array text-bytes))
(define NUL 0) (define TRU 1) (define FALS 2) (define NUM 3) (define STR 4)
(define KEY 5) (define OBJ 6) (define ARR 7) (define TXT 8)
(define (slot name) (list-index (lambda (n) (eq? n name)) names))

(define (bump! c i n) (vector-set! c i (+ (vector-ref c i) n)))

;; Walks guile-json's value.
(define (walk! v c)
  (cond
   ((string? v) (bump! c STR 1) (bump! c TXT (string-utf8-length v)))
   ((vector? v)
    (bump! c ARR 1)
    (let ((n (vector-length v)))
      (do ((i 0 (+ i 1))) ((= i n))
        (walk! (vector-ref v i) c))))
   ((or (null? v) (pair? v))
    (bump! c OBJ 1)
    (let loop ((l v))
      (unless (null? l)
        (bump! c KEY 1)
        (bump! c TXT (string-utf8-length (caar l)))
        (walk! (cdar l) c)
        (loop (cdr l)))))
   ((number? v) (bump! c NUM 1))
   ((eq? v #t) (bump! c TRU 1))
   ((eq? v #f) (bump! c FALS 1))
   ((eq? v 'null) (bump! c NUL 1))
   (else (error "unexpected value" v))))

;; Reads one value from BV. json->scm raises unless only whitespace follows.
(define (read-tree bv)
  (let ((port (open-bytevector-input-port bv)))
    (set-port-encoding! port "UTF-8")
    (json->scm port)))

(define passes 0)

(define (run-pass pass-fn bv counts)
  (pass-fn bv counts)
  (set! passes (+ passes 1)))

(define (tree-pass bv counts) (read-tree bv) #t)
(define (walk-pass bv counts) (walk! (read-tree bv) counts))

(define (flat-reason key args)
  (let* ((m (with-output-to-string
              (lambda () (display key) (display " ")
                      (write (if (and (pair? args) (not (port? (car args)))) args '())))))
         (m (string-map (lambda (c) (if (or (char=? c #\newline) (char=? c #\return)) #\space c)) m)))
    (if (> (string-length m) 100) (substring m 0 100) m)))

(define (put-counts c)
  (for-each (lambda (n) (format #t " (~a . ~a)" n (vector-ref c (slot n)))) names))

(define (run-lane name bv size lane-name pass-fn counted? rounds round-bytes)
  (let* ((iterations (quotient (+ round-bytes size -1) size))
         (counts (make-vector 9 0))
         (scratch (make-vector 9 0))
         (failure
          (begin
            (format (current-error-port) "guile-bench: ~a ~a\n" name lane-name)
            (catch #t
              (lambda () (pass-fn bv (and counted? counts)) #f)
              (lambda (key . args) (flat-reason key args))))))
    (cond
     (failure
      (display "(failure (file ") (put-string name)
      (format #t ") (parser guile-json) (lane ~a) (reason " lane-name)
      (put-string failure) (display "))\n"))
     (else
      (set! passes 0)
      (do ((i 0 (+ i 1))) ((= i iterations))
        (run-pass pass-fn bv (and counted? scratch)))
      (let ((ns (map (lambda (r)
                       (gc)
                       (let ((t0 (now-ns)))
                         (do ((i 0 (+ i 1))) ((= i iterations))
                           (run-pass pass-fn bv (and counted? scratch)))
                         (- (now-ns) t0)))
                     (iota rounds))))
        (display "(result (file ") (put-string name)
        (format #t ") (bytes ~a) (parser guile-json) (lane ~a) (iterations ~a) (round-ns"
                size lane-name iterations)
        (for-each (lambda (t) (format #t " ~a" t)) ns)
        (display ") (counts")
        (when counted? (put-counts counts))
        (format #t ") (passes ~a)" passes)
        (when counted?
          (display " (timed-counts") (put-counts scratch) (display ")"))
        (display ")\n"))))))

;; guile-json's version is in its store path, once the profile's symlink is
;; resolved: .../guile-json-4.7.3/...
(define (json-version)
  (let* ((found (%search-load-path "json/parser.scm"))
         (file (if found (canonicalize-path found) ""))
         (m (string-contains file "guile-json-")))
    (if m
        (let* ((start (+ m (string-length "guile-json-")))
               (end (or (string-index file #\/ start) (string-length file))))
          (substring file start end))
        "unknown")))

(define (main args)
  (when (< (length args) 3) (die "usage: guile-bench ROUNDS ROUND-BYTES FILE..."))
  (let ((rounds (positive-integer (car args) "ROUNDS"))
        (round-bytes (positive-integer (cadr args) "ROUND-BYTES")))
    (display "(runtime (parser guile-json) (version ")
    (put-string (string-append "guile-json " (json-version) " on Guile " (version)))
    (display ") (how ")
    (put-string "compiled by guild; json->scm's defaults, from a UTF-8 bytevector port")
    (format #t ") (rounds ~a) (round-bytes ~a))\n" rounds round-bytes)
    (for-each
     (lambda (path)
       (let* ((bv (catch #t (lambda () (read-file path))
                    (lambda _ (die "cannot read " path))))
              (size (bytevector-length bv))
              (name (basename path)))
         (when (zero? size) (die "empty: " path))
         (run-lane name bv size 'tree tree-pass #f rounds round-bytes)
         (run-lane name bv size 'tree+walk walk-pass #t rounds round-bytes)))
     (cddr args))
    (force-output)))

(main (cdr (command-line)))
