;;; bench/gambit-bench.scm: Gambit's side of the benchmarks (ADR-0013,
;;; ADR-0024).
;;;
;;;   gambit-bench ROUNDS ROUND-BYTES FILE...
;;;
;;; Two lanes per file, in this order:
;;;
;;;   tree       one pass reads one value with Gambit's `_json' reader,
;;;              (read-json port), at its defaults (not permissive)
;;;   tree+walk  the same, then a walk of the value counting nine names
;;;
;;; A pass starts from the file's bytes in memory: it makes a UTF-8 textual
;;; port over them (open-input-u8vector), so decoding is part of the pass,
;;; reads one value, and fails unless only JSON whitespace follows it.
;;;
;;; read-json builds: an object as a table with keyword keys (the key is
;;; interned by string->keyword), an array as a vector, a string as a fresh
;;; string, a number by string->number (exact integer, flonum), true as #t,
;;; false as #f and null as (void). All seven kinds are told apart.
;;;
;;; Build: gsc -exe cannot link an `(import (_json))' (the program then dies
;;; at start-up, silently), so the installed _json.scm and _json#.scm are
;;; copied unchanged into build/bench/gambit/, with this file, and compiled
;;; into the program; read-json is then the global that file defines.
;;;
;;; Output, method and checks are ADR-0023's and ADR-0024's; see
;;; bench/yajl-bench.c, which this follows.

(define (die . parts)
  (let ((e (current-error-port)))
    (display "gambit-bench: " e)
    (for-each (lambda (p) (display p e)) parts)
    (newline e)
    (exit 1)))

;;; ---- the clock ----------------------------------------------------------
;;; ##get-monotonic-time! is Gambit 4.9.7's CLOCK_MONOTONIC reader. It stores
;;; an integer count of nanoseconds, as the bits of a flonum, in a slot of an
;;; f64vector; `inexact->exact' of that denormal times 2^1074 recovers the
;;; integer exactly. ##get-monotonic-time-frequency! stores the ticks per
;;; second the same way; the harness refuses to run unless it is 1e9.

(define clock-cell (make-f64vector 2 0.))

(define (bits->integer x)
  (* (inexact->exact x) (expt 2 1074)))

(define (now-ns)
  (##get-monotonic-time! clock-cell 0)
  (bits->integer (f64vector-ref clock-cell 0)))

(define (check-clock!)
  (##get-monotonic-time-frequency! clock-cell 1)
  (let ((hz (bits->integer (f64vector-ref clock-cell 1))))
    (if (not (= hz 1000000000))
        (die "monotonic clock is not in nanoseconds: " hz " Hz"))
    (let* ((a (now-ns)) (b (now-ns)))
      (if (< b a) (die "monotonic clock went backwards")))))

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
  (one-line (call-with-output-string '() (lambda (p) (display-exception e p)))))

;;; ---- input ---------------------------------------------------------------

(define (read-file path)
  (let* ((size (file-info-size (file-info path)))
         (bv (make-u8vector size 0))
         (port (open-input-file path)))
    (if (<= size 0) (die "empty file: " path))
    (let loop ((at 0))
      (if (< at size)
          (let ((n (read-subu8vector bv at size port)))
            (if (= n 0) (die "cannot read: " path))
            (loop (+ at n)))))
    (close-input-port port)
    bv))

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

;; (u8vector -> value): one value from UTF-8 bytes; only whitespace may follow.
(define (read-one bv)
  (let* ((port (open-input-u8vector (list init: bv char-encoding: 'UTF-8)))
         (v (read-json port)))
    (let loop ()
      (let ((c (read-char port)))
        (cond ((eof-object? c) v)
              ((json-space? c) (loop))
              (else (error "trailing garbage after the value")))))))

;;; counts: a vector of nine fixnums, in this order
(define count-names
  '#(null true false number string key object array text-bytes))
(define (bump! counts i n) (vector-set! counts i (+ (vector-ref counts i) n)))

(define (utf8-length s)
  (let ((n (string-length s)))
    (let loop ((i 0) (acc 0))
      (if (= i n)
          acc
          (let ((c (char->integer (string-ref s i))))
            (loop (+ i 1)
                  (+ acc (cond ((< c #x80) 1) ((< c #x800) 2) ((< c #x10000) 3) (else 4)))))))))

(define the-null (void))

(define (walk! v counts)
  (cond ((string? v) (bump! counts 4 1) (bump! counts 8 (utf8-length v)))
        ((number? v) (bump! counts 3 1))
        ((eq? v #t) (bump! counts 1 1))
        ((eq? v #f) (bump! counts 2 1))
        ((eq? v the-null) (bump! counts 0 1))
        ((vector? v)
         (bump! counts 7 1)
         (let ((n (vector-length v)))
           (let loop ((i 0))
             (if (< i n) (begin (walk! (vector-ref v i) counts) (loop (+ i 1)))))))
        ((table? v)
         (bump! counts 6 1)
         (table-for-each
          (lambda (k x)
            (bump! counts 5 1)
            (bump! counts 8 (utf8-length (keyword->string k)))
            (walk! x counts))
          v))
        (else (error "unknown kind of value" v))))

;;; ---- the lanes -----------------------------------------------------------

(define passes 0)

;; A pass: counted lanes add into COUNTS.
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
    (put "(failure (file ") (put-string name) (put ") (parser gambit) (lane " lane
              ") (reason ") (put-string reason) (put "))\n")
    (force-output))
  (define (many n)
    (let loop ((i 0))
      (if (< i n) (begin (pass bv timed-counts) (loop (+ i 1))))))
  (display (string-append "gambit-bench: " name " " (symbol->string lane) "\n")
           (current-error-port))
  (let ((ok (with-exception-catcher
             (lambda (e) (fail (exception-text e)) #f)
             (lambda () (pass bv first-counts) #t))))
    (if ok
        (begin
          (set! passes 0)
          (many iterations)                      ; the warm-up round
          (let loop ((r 0))
            (if (< r rounds)
                (begin
                  (##gc)
                  (let* ((t0 (now-ns)))
                    (many iterations)
                    (vector-set! ns r (- (now-ns) t0)))
                  (loop (+ r 1)))))
          (put "(result (file ") (put-string name)
          (put ") (bytes " bytes ") (parser gambit) (lane " lane
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
          (force-output)))))

(define (main args)
  (if (< (length args) 3) (die "usage: gambit-bench ROUNDS ROUND-BYTES FILE..."))
  (let ((rounds (positive-integer (car args) "ROUNDS"))
        (round-bytes (positive-integer (cadr args) "ROUND-BYTES"))
        (files (cddr args)))
    (check-clock!)
    (put "(runtime (parser gambit) (version ")
    (put-string (string-append "Gambit " (system-version-string)))
    (put ") (how ")
    (put-string
     (string-append
      "gsc -exe, no declarations, with the installed _json.scm compiled in; "
      "read-json's defaults, from a UTF-8 port over the bytes"))
    (put ") (rounds " rounds ") (round-bytes " round-bytes "))\n")
    (force-output)
    (for-each
     (lambda (path)
       (let* ((bv (read-file path))
              (size (u8vector-length bv))
              (name (basename path))
              (iterations (quotient (+ round-bytes size -1) size)))
         (run-lane name size bv 'tree pass-tree #f rounds iterations)
         (run-lane name size bv 'tree+walk pass-walk #t rounds iterations)))
     files)))

(with-exception-catcher
 (lambda (e)
   (display "gambit-bench: " (current-error-port))
   (display-exception e (current-error-port))
   (exit 1))
 (lambda () (main (cdr (command-line)))))
