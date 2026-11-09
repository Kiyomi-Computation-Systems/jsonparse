#!r6rs
;;; bench/run.sps OUT ROUNDS ROUND-BYTES FILE...: jsonparse's side of the
;;; benchmarks (ADR-0013, ADR-0023).
;;;
;;; For each file, read into memory first, it times each of
;;; (jsonparse-bench)'s lanes with measure, ROUNDS rounds after a warm-up
;;; round, each round enough passes to read ROUND-BYTES. It writes to OUT a
;;; runtime form, then a result form per file and lane: the lane's counts
;;; from one pass outside the timing, and its tally of the passes measure
;;; ran, the warm-up's included, with what they counted. `make bench` runs it
;;; with the libraries compiled ahead of time, and names progress on stderr.
(import (rnrs)
        (only (chezscheme) scheme-version machine-type optimize-level)
        (jsonparse easy)
        (jsonparse-bench))

(define (usage)
  (display "usage: run.sps OUT ROUNDS ROUND-BYTES FILE...\n" (current-error-port))
  (exit 2))

(define args (cdr (command-line)))
(when (< (length args) 4) (usage))

(define (positive s)
  (let ((n (string->number s)))
    (unless (and n (exact? n) (integer? n) (> n 0)) (usage))
    n))

(define out (car args))
(define rounds (positive (cadr args)))
(define round-bytes (positive (caddr args)))
(define paths (cdddr args))

(define (basename path)
  (let loop ((i (- (string-length path) 1)))
    (cond ((< i 0) path)
          ((char=? (string-ref path i) #\/) (substring path (+ i 1) (string-length path)))
          (else (loop (- i 1))))))

(define (read-bytes path)
  (call-with-port (open-file-input-port path) get-bytevector-all))

;; The counts the report checks, from one pass outside the timing.
(define (lane-counts lane bv)
  (case lane
    ((events) (events-counts bv))
    ((tree+walk) (tree-counts (bytevector->json bv)))
    ((scan) (composition bv))
    (else '())))

(define port
  (transcoded-port (open-file-output-port out (file-options no-fail))
                   (make-transcoder (utf-8-codec))))

(write `(runtime (parser jsonparse) (version ,(scheme-version))
                 (machine-type ,(symbol->string (machine-type)))
                 (optimize-level ,(optimize-level))
                 (rounds ,rounds) (round-bytes ,round-bytes))
       port)
(newline port)

(for-each
 (lambda (path)
   (let* ((bv (read-bytes path))
          (name (basename path))
          (iterations (iterations-for (bytevector-length bv) round-bytes)))
     (for-each
      (lambda (lane)
        (display (string-append "run: " name " " (symbol->string lane) "\n") (current-error-port))
        (let ((counts (lane-counts lane bv)))
          (let*-values (((thunk tally) (lane-thunk lane bv))
                        ((ns allocated gc-ns) (measure thunk iterations rounds)))
            (let ((t (tally)))
              (write `(result (file ,name) (bytes ,(bytevector-length bv)) (parser jsonparse)
                              (lane ,lane) (iterations ,iterations) (round-ns ,@ns)
                              (counts ,@counts) (passes ,(car t))
                              ,@(if (null? counts) '() `((timed-counts ,@(cdr t))))
                              (allocated ,allocated) (gc-ns ,gc-ns))
                     port))
            (newline port)
            (flush-output-port port))))
      lanes)))
 paths)

(close-port port)
