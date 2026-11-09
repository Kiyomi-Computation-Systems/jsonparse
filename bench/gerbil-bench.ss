;;; bench/gerbil-bench.ss: Gerbil's side of the benchmarks (ADR-0013,
;;; ADR-0024).
;;;
;;;   gerbil-bench ROUNDS ROUND-BYTES FILE...
;;;
;;; Two lanes per file, in this order:
;;;
;;;   tree       one pass reads one value with :std/text/json's
;;;              (bytes->json-object bytes), at its defaults
;;;   tree+walk  the same, then a walk of the value counting nine names
;;;
;;; bytes->json-object takes the file's bytes as they are: it decodes UTF-8
;;; itself, in the pass, and raises unless only whitespace follows the value.
;;;
;;; The reader (Gerbil source, std/text/json/input.ss) builds: an object as a
;;; hash table with symbol keys (json-symbolic-keys is #t: each key is
;;; interned by string->symbol), an array as a list, a string as a fresh
;;; string, a number by string->number, true as #t, false as #f and null as
;;; (void). All seven kinds are told apart: [] is (), null is (void).
;;; Its \u escapes are decoded one at a time: a surrogate pair becomes two
;;; U+FFFD, so on files with such pairs the text-bytes it counts are larger
;;; than the others'.
;;;
;;; Output, method and checks are ADR-0023's and ADR-0024's; see
;;; bench/yajl-bench.c, which this follows.
(import :gerbil/gambit
        :std/text/json
        :std/misc/ports
        :std/sugar)
(export main)

(def (die . parts)
  (let (e (current-error-port))
    (display "gerbil-bench: " e)
    (for-each (lambda (p) (display p e)) parts)
    (newline e)
    (exit 1)))

;;; ---- the clock ----------------------------------------------------------
;;; ##get-monotonic-time! is the Gambit runtime's CLOCK_MONOTONIC reader (the
;;; Gambit under Gerbil 0.18.1 is 4.9.5). It stores an integer count of
;;; nanoseconds, as the bits of a flonum, in a slot of an f64vector;
;;; `inexact->exact' of that denormal times 2^1074 recovers the integer
;;; exactly. ##get-monotonic-time-frequency! stores the ticks per second the
;;; same way; the harness refuses to run unless it is 1e9.

(def clock-cell (make-f64vector 2 0.))

(def (bits->integer x)
  (* (inexact->exact x) (expt 2 1074)))

(def (now-ns)
  (##get-monotonic-time! clock-cell 0)
  (bits->integer (f64vector-ref clock-cell 0)))

(def (check-clock!)
  (##get-monotonic-time-frequency! clock-cell 1)
  (let (hz (bits->integer (f64vector-ref clock-cell 1)))
    (unless (= hz 1000000000)
      (die "monotonic clock is not in nanoseconds: " hz " Hz"))
    (let* ((a (now-ns)) (b (now-ns)))
      (when (< b a) (die "monotonic clock went backwards")))))

;;; ---- output --------------------------------------------------------------

(def (put-string s)
  (write-char #\")
  (string-for-each
   (lambda (c)
     (when (or (char=? c #\") (char=? c #\\)) (write-char #\\))
     (write-char c))
   s)
  (write-char #\"))

(def (put . parts) (for-each display parts))

(def (one-line s)
  (let* ((s (list->string
             (map (lambda (c) (if (or (char<? c #\space) (char>? c #\~)) #\space c))
                  (string->list s))))
         (n (string-length s)))
    (if (> n 100) (substring s 0 100) s)))

(def (exception-text e)
  (one-line (call-with-output-string '() (lambda (p) (display-exception e p)))))

;;; ---- input ---------------------------------------------------------------

(def (basename path)
  (let loop ((i (- (string-length path) 1)))
    (cond ((< i 0) path)
          ((char=? (string-ref path i) #\/)
           (substring path (+ i 1) (string-length path)))
          (else (loop (- i 1))))))

(def (positive-integer s what)
  (let (n (and (> (string-length s) 0)
               (let loop ((i 0))
                 (or (= i (string-length s))
                     (and (char<=? #\0 (string-ref s i) #\9) (loop (+ i 1)))))
               (string->number s)))
    (if (and n (exact? n) (> n 0)) n (die what " is not a positive integer: " s))))

;;; ---- one pass ------------------------------------------------------------

;;; counts: a vector of nine fixnums, in this order
(def count-names
  '#(null true false number string key object array text-bytes))

(def (bump! counts i n) (vector-set! counts i (+ (vector-ref counts i) n)))

(def (utf8-length s)
  (let (n (string-length s))
    (let loop ((i 0) (acc 0))
      (if (= i n)
        acc
        (let (c (char->integer (string-ref s i)))
          (loop (+ i 1)
                (+ acc (cond ((< c #x80) 1) ((< c #x800) 2) ((< c #x10000) 3) (else 4)))))))))

(def the-null (void))

(def (walk! v counts)
  (cond ((string? v) (bump! counts 4 1) (bump! counts 8 (utf8-length v)))
        ((number? v) (bump! counts 3 1))
        ((eq? v #t) (bump! counts 1 1))
        ((eq? v #f) (bump! counts 2 1))
        ((eq? v the-null) (bump! counts 0 1))
        ((null? v) (bump! counts 7 1))
        ((pair? v)
         (bump! counts 7 1)
         (let loop ((l v))
           (when (pair? l) (walk! (car l) counts) (loop (cdr l)))))
        ((table? v)
         (bump! counts 6 1)
         (hash-for-each
          (lambda (k x)
            (bump! counts 5 1)
            (bump! counts 8 (utf8-length (symbol->string k)))
            (walk! x counts))
          v))
        (else (error "unknown kind of value" v))))

;;; ---- the lanes -----------------------------------------------------------

(def passes 0)

(def (pass-tree bv counts)
  (bytes->json-object bv)
  (set! passes (+ passes 1)))

(def (pass-walk bv counts)
  (let (v (bytes->json-object bv))
    (walk! v counts)
    (set! passes (+ passes 1))))

(def (run-lane name bytes bv lane pass counted? rounds iterations)
  (def first-counts (make-vector 9 0))
  (def timed-counts (make-vector 9 0))
  (def ns (make-vector rounds 0))
  (def (fail reason)
    (put "(failure (file ") (put-string name) (put ") (parser gerbil) (lane " lane
         ") (reason ") (put-string reason) (put "))\n")
    (force-output))
  (def (many n)
    (let loop ((i 0))
      (when (< i n) (pass bv timed-counts) (loop (+ i 1)))))
  (display (string-append "gerbil-bench: " name " " (symbol->string lane) "\n")
           (current-error-port))
  (let (ok (with-catch
            (lambda (e) (fail (exception-text e)) #f)
            (lambda () (pass bv first-counts) #t)))
    (when ok
      (set! passes 0)
      (many iterations)                         ; the warm-up round
      (let loop ((r 0))
        (when (< r rounds)
          (##gc)
          (let (t0 (now-ns))
            (many iterations)
            (vector-set! ns r (- (now-ns) t0)))
          (loop (+ r 1))))
      (put "(result (file ") (put-string name)
      (put ") (bytes " bytes ") (parser gerbil) (lane " lane
           ") (iterations " iterations ") (round-ns")
      (vector-for-each (lambda (x) (put " " x)) ns)
      (put ") (counts")
      (when counted?
        (let loop ((i 0))
          (when (< i 9)
            (put " (" (vector-ref count-names i) " . " (vector-ref first-counts i) ")")
            (loop (+ i 1)))))
      (put ") (passes " passes ")")
      (when counted?
        (put " (timed-counts")
        (let loop ((i 0))
          (when (< i 9)
            (put " (" (vector-ref count-names i) " . " (vector-ref timed-counts i) ")")
            (loop (+ i 1))))
        (put ")"))
      (put ")\n")
      (force-output))))

(def (main . args)
  (when (< (length args) 3) (die "usage: gerbil-bench ROUNDS ROUND-BYTES FILE..."))
  (let ((rounds (positive-integer (car args) "ROUNDS"))
        (round-bytes (positive-integer (cadr args) "ROUND-BYTES"))
        (files (cddr args)))
    (check-clock!)
    (put "(runtime (parser gerbil) (version ")
    (put-string (string-append "Gerbil " (gerbil-version-string)
                               " on Gambit " (system-version-string)))
    (put ") (how ")
    (put-string
     (string-append
      "gxc -exe; bytes->json-object's defaults, from the bytes"))
    (put ") (rounds " rounds ") (round-bytes " round-bytes "))\n")
    (force-output)
    (for-each
     (lambda (path)
       (let* ((bv (read-file-u8vector path))
              (size (u8vector-length bv)))
         (when (<= size 0) (die "empty file: " path))
         (let ((name (basename path))
               (iterations (quotient (+ round-bytes size -1) size)))
           (run-lane name size bv 'tree pass-tree #f rounds iterations)
           (run-lane name size bv 'tree+walk pass-walk #t rounds iterations))))
     files)))
