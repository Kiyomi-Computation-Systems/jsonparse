#!r6rs
;;; bench/chez-peers.sps PARSER ROUNDS ROUND-BYTES FILE...: SRFI 180's and
;;; chez-json's side of the benchmarks (ADR-0023, ADR-0024), on Chez.
;;;
;;; PARSER is srfi-180 or chez-json; the Makefile runs one per process, each
;;; with its own round bytes. Lanes, in this order:
;;;
;;;   srfi-180   events     json-fold, counting with srfi-180-fold-counts
;;;              tree       json-read
;;;              tree+walk  json-read, then srfi-180-tree-counts
;;;   chez-json  tree       json->scm
;;;              tree+walk  json->scm, then chez-json-tree-counts
;;;
;;; Each pass starts from the file's bytes in memory and makes a UTF-8
;;; textual port over them, so decoding is part of the pass. The port's
;;; transcoder raises on bytes that aren't UTF-8, where Chez's default
;;; would put in U+FFFD. A pass fails unless only whitespace follows the
;;; value, as in every other harness: neither library checks.
;;;
;;; The method, (jsonparse-bench)'s as in bench/run.sps: for each file and
;;; lane, one first pass outside the timing, whose counts are the result's;
;;; if it raises, a failure form, and no timing. If it took longer than
;;; pass-limit-ns, a too-slow form with its time and counts, and no timing:
;;; SRFI 180's reference implementation slows with the square of the
;;; numbers it has read, and takes minutes a pass on canada.json, which
;;; the method would run 11 times a lane (ADR-0024). Then measure: a warm-up
;;; round and ROUNDS timed rounds of iterations-for's passes, each round
;;; after a full collection. A pass counts in passes once it has finished,
;;; and adds what it counted to the timed counts. A pass that raises there
;;; is the harness's error: it exits 1.
;;;
;;; The runtime form's version takes each comparator's commit from
;;; bench/comparators.lock, which pins the file compiled, and so does the
;;; include in (jsonparse-bench srfi-180): run it from the repository's
;;; root. Forms go to stdout, progress to stderr.
(import (rnrs)
        (only (chezscheme) scheme-version optimize-level display-condition
              current-time time-difference)
        (only (jsonparse-bench) measure iterations-for duration->ns)
        (jsonparse-bench walks)
        (only (jsonparse-bench srfi-180) json-fold json-read json-error? json-error-reason)
        (only (json parser) json->scm))

(define (die . parts)
  (let ((e (current-error-port)))
    (display "chez-peers: " e)
    (for-each (lambda (p) (display p e)) parts)
    (newline e))
  (exit 1))

(define (usage)
  (die "usage: chez-peers.sps srfi-180|chez-json ROUNDS ROUND-BYTES FILE..."))

;; positive-integer : String String -> Nat
;; S's value when it is decimal digits naming a positive integer; otherwise
;; the harness exits 1.
(define (positive-integer s what)
  (let ((n (and (> (string-length s) 0)
                (for-all (lambda (c) (char<=? #\0 c #\9)) (string->list s))
                (string->number s))))
    (unless (and n (> n 0))
      (die what " is not a positive integer: " s))
    n))

(define (basename path)
  (let loop ((i (- (string-length path) 1)))
    (cond ((< i 0) path)
          ((char=? (string-ref path i) #\/) (substring path (+ i 1) (string-length path)))
          (else (loop (- i 1))))))

(define (read-bytes path)
  (let ((bv (guard (e (#t (die "cannot read " path)))
              (call-with-port (open-file-input-port path) get-bytevector-all))))
    (if (eof-object? bv) (die path " is empty") bv)))

;; --- the lanes ------------------------------------------------------------------

(define transcoder
  (make-transcoder (utf-8-codec) (eol-style none) (error-handling-mode raise)))

;; port-over : Bytevector -> Textual-Input-Port, a fresh UTF-8 port over BV
(define (port-over bv) (open-bytevector-input-port bv transcoder))

;; json-read returns the eof object for a port holding no value.
(define (srfi-180-value x)
  (if (eof-object? x) (error 'json-read "no JSON value") x))

;; only-whitespace-after : Textual-Input-Port -> Void
;; Raises unless PORT holds nothing more but JSON's whitespace.
(define (only-whitespace-after port)
  (let loop ()
    (let ((c (read-char port)))
      (cond ((eof-object? c))
            ((memv c '(#\space #\tab #\newline #\return)) (loop))
            (else (error 'chez-peers "bytes after the value" c))))))

;; read-whole : (Textual-Input-Port -> Any) Bytevector -> Any
;; What READ reads from a fresh port over BV, which must hold no more.
(define (read-whole read bv)
  (let* ((port (port-over bv)) (value (read port)))
    (only-whitespace-after port)
    value))

;; A lane: its name, and a pass over a file's bytes that returns what it
;; counted, '() in an uncounted lane.
(define (lane name pass) (cons name pass))

;; lanes-of : Symbol -> (Listof (Pair Symbol (Bytevector -> (Listof (Pair Symbol Nat)))))
(define (lanes-of parser)
  (case parser
    ((srfi-180)
     (list (lane 'events
                 (lambda (bv)
                   (let* ((port (port-over bv))
                          (counts (srfi-180-fold-counts
                                   (lambda (proc array-start array-end object-start object-end seed)
                                     (json-fold proc array-start array-end object-start object-end
                                                seed port)))))
                     (only-whitespace-after port)
                     counts)))
           (lane 'tree (lambda (bv) (srfi-180-value (read-whole json-read bv)) '()))
           (lane 'tree+walk
                 (lambda (bv) (srfi-180-tree-counts (srfi-180-value (read-whole json-read bv)))))))
    ((chez-json)
     (list (lane 'tree (lambda (bv) (read-whole json->scm bv) '()))
           (lane 'tree+walk (lambda (bv) (chez-json-tree-counts (read-whole json->scm bv))))))
    (else (usage))))

;; --- the runtime form's strings -------------------------------------------------

;; locked-commit : String -> String
;; The first eight hex digits of the commit in the URL that
;; bench/comparators.lock gives for NAME.
(define (locked-commit name)
  (define (fields line)
    (let loop ((cs (string->list line)) (field '()) (acc '()))
      (define (flush) (if (null? field) acc (cons (list->string (reverse field)) acc)))
      (cond ((null? cs) (reverse (flush)))
            ((memv (car cs) '(#\space #\tab)) (loop (cdr cs) '() (flush)))
            (else (loop (cdr cs) (cons (car cs) field) acc)))))
  (define (segments url)
    (let loop ((cs (string->list url)) (seg '()) (acc '()))
      (cond ((null? cs) (reverse (cons (list->string (reverse seg)) acc)))
            ((char=? (car cs) #\/) (loop (cdr cs) '() (cons (list->string (reverse seg)) acc)))
            (else (loop (cdr cs) (cons (car cs) seg) acc)))))
  (define (commit? s)
    (and (= (string-length s) 40)
         (for-all (lambda (c) (or (char<=? #\0 c #\9) (char<=? #\a c #\f))) (string->list s))))
  (let ((lines (guard (e (#t (die "cannot read bench/comparators.lock; run from the repository's root")))
                 (call-with-input-file "bench/comparators.lock"
                   (lambda (p)
                     (let loop ((acc '()))
                       (let ((l (get-line p)))
                         (if (eof-object? l) (reverse acc) (loop (cons l acc))))))))))
    (let find ((ls lines))
      (if (null? ls)
          (die "bench/comparators.lock pins no " name)
          (let ((fs (fields (car ls))))
            (if (and (= (length fs) 3) (string=? (car fs) name))
                (let ((c (find-first commit? (segments (caddr fs)))))
                  (if c (substring c 0 8) (die "no commit in the lock's URL for " name)))
                (find (cdr ls))))))))

(define (find-first ok? l)
  (cond ((null? l) #f) ((ok? (car l)) (car l)) (else (find-first ok? (cdr l)))))

(define (runtime-strings parser)
  (let ((compiled (string-append "compiled ahead of time, optimize-level "
                                 (number->string (optimize-level))
                                 "; each pass reads a UTF-8 port over the bytes,"
                                 " which raises on bad UTF-8")))
    (case parser
      ((srfi-180)
       (values (string-append "SRFI 180 reference " (locked-commit "srfi-180-body.scm")
                              "; " (scheme-version))
               (string-append compiled "; json-fold and json-read at their defaults;"
                              " an R6RS wrapper with our valid-number?, JSON's number"
                              " grammar by hand, for upstream's (chibi regexp) one")))
      ((chez-json)
       (values (string-append "chez-json " (locked-commit "chez-json-parser.scm")
                              "; " (scheme-version))
               (string-append compiled "; json->scm"))))))

;; --- one lane on one file -------------------------------------------------------

;; A lane whose first pass takes longer than this, 10 s, is not timed.
(define pass-limit-ns 10000000000)

;; reason : Any -> String, a raised object as one short line
(define (reason e)
  (let* ((text (cond ((json-error? e) (json-error-reason e))
                     ((condition? e)
                      (call-with-string-output-port (lambda (p) (display-condition e p))))
                     (else (call-with-string-output-port (lambda (p) (write e p))))))
         (line (list->string (map (lambda (c) (if (memv c '(#\newline #\return #\tab)) #\space c))
                                  (string->list text)))))
    (if (> (string-length line) 160) (substring line 0 160) line)))

(define (emit form)
  (write form)
  (newline)
  (flush-output-port (current-output-port)))

(define (run-lane parser rounds name bv iterations lane)
  (let ((lane-name (car lane)) (pass (cdr lane)))
    (display (string-append "chez-peers: " (symbol->string parser) " " name " "
                            (symbol->string lane-name) "\n")
             (current-error-port))
    (let* ((t0 (current-time 'time-monotonic))
           (first (guard (e (#t (cons 'failed (reason e))))
                    (cons 'counted (pass bv))))
           (pass-ns (duration->ns (time-difference (current-time 'time-monotonic) t0))))
      (cond
        ((eq? (car first) 'failed)
         (emit `(failure (file ,name) (parser ,parser) (lane ,lane-name) (reason ,(cdr first)))))
        ((> pass-ns pass-limit-ns)
         (emit `(too-slow (file ,name) (bytes ,(bytevector-length bv)) (parser ,parser)
                          (lane ,lane-name) (pass-ns ,pass-ns) (limit-ns ,pass-limit-ns)
                          (counts ,@(cdr first)))))
        (else
          (let* ((counts (cdr first))
                 (sums (make-vector (length counts) 0))
                 (passes 0))
            (define (add! counted)
              (let loop ((i 0) (c counted))
                (unless (null? c)
                  (vector-set! sums i (+ (vector-ref sums i) (cdar c)))
                  (loop (+ i 1) (cdr c)))))
            (let-values (((ns allocated gc-ns)
                          (guard (e (#t (die name " " lane-name ": a timed pass raised: " (reason e))))
                            (measure (lambda ()
                                       (add! (pass bv))
                                       (set! passes (+ passes 1)))
                                     iterations rounds))))
              (emit `(result (file ,name) (bytes ,(bytevector-length bv)) (parser ,parser)
                             (lane ,lane-name) (iterations ,iterations) (round-ns ,@ns)
                             (counts ,@counts) (passes ,passes)
                             ,@(if (null? counts)
                                   '()
                                   `((timed-counts ,@(map cons (map car counts)
                                                          (vector->list sums))))))))))))))

;; --- main -----------------------------------------------------------------------

(define args (cdr (command-line)))
(when (< (length args) 4) (usage))

(define parser
  (let ((p (string->symbol (car args))))
    (if (memq p '(srfi-180 chez-json)) p (usage))))
(define rounds (positive-integer (cadr args) "ROUNDS"))
(define round-bytes (positive-integer (caddr args) "ROUND-BYTES"))
(define paths (cdddr args))

(let-values (((version how) (runtime-strings parser)))
  (emit `(runtime (parser ,parser) (version ,version) (how ,how)
                  (rounds ,rounds) (round-bytes ,round-bytes))))

(for-each
 (lambda (path)
   (let* ((bv (read-bytes path))
          (iterations (iterations-for (bytevector-length bv) round-bytes)))
     (for-each (lambda (lane) (run-lane parser rounds (basename path) bv iterations lane))
               (lanes-of parser))))
 paths)

(exit 0)
