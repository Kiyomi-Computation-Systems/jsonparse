#!r6rs
;;; bench/report.sps MACHINE FILES RESULTS...: prints the benchmarks' report
;;; as Markdown (ADR-0013, ADR-0023). MACHINE holds KEY: VALUE lines, FILES
;;; the lock's file names, one a line, and each RESULTS file a harness's
;;; runtime and result forms. Unless the results cross-check clean, it
;;; names each problem on stderr, prints no report and exits 1.
(import (rnrs) (jsonparse-bench report))

(define args (cdr (command-line)))
(when (< (length args) 3)
  (display "usage: report.sps MACHINE FILES RESULTS...\n" (current-error-port))
  (exit 2))

(define (fail . lines)
  (for-each (lambda (l) (display (string-append "report: " l "\n") (current-error-port))) lines)
  (exit 1))

(define (read-forms path)
  (call-with-port (open-input-file path)
    (lambda (port)
      (let loop ((acc '()))
        (let ((x (read port)))
          (if (eof-object? x) (reverse acc) (loop (cons x acc))))))))

(define (form-of? kind x) (and (pair? x) (eq? (car x) kind)))

(define (read-lines path)
  (call-with-port (open-input-file path)
    (lambda (port)
      (let loop ((acc '()))
        (let ((line (get-line port)))
          (cond ((eof-object? line) (reverse acc))
                ((string=? line "") (loop acc))
                (else (loop (cons line acc)))))))))

(define files (read-lines (cadr args)))
(define forms (apply append (map read-forms (cddr args))))
(for-each (lambda (x)
            (unless (or (form-of? 'runtime x) (form-of? 'result x))
              (fail "neither a runtime nor a result form; is a harness writing to the results?")))
          forms)

(define runtimes (filter (lambda (x) (form-of? 'runtime x)) forms))
(define results (filter (lambda (x) (form-of? 'result x)) forms))
(let ((problems (cross-check files runtimes results)))
  (unless (null? problems) (apply fail problems)))
(display (report-text (read-machine (call-with-port (open-input-file (car args)) get-string-all))
                      runtimes results))
