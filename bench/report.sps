#!r6rs
;;; bench/report.sps MACHINE FILES PLAN RESULTS...: prints the benchmarks'
;;; report as Markdown (ADR-0013, ADR-0023, ADR-0024). MACHINE holds
;;; KEY: VALUE lines; FILES the lock's file names, one a line; PLAN the
;;; plan's one form, which the Makefile writes; and each RESULTS file a
;;; harness's runtime, result, failure and too-slow forms. Unless the results
;;; cross-check clean against the plan, it names each problem on stderr,
;;; prints no report and exits 1.
(import (rnrs) (jsonparse-bench report))

(define args (cdr (command-line)))
(when (< (length args) 4)
  (display "usage: report.sps MACHINE FILES PLAN RESULTS...\n" (current-error-port))
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

(define (read-text path) (call-with-port (open-input-file path) get-string-all))

(define files (read-lines (list-ref args 1)))

(define plan
  (let ((path (list-ref args 2)))
    (guard (e ((and (who-condition? e) (eq? (condition-who e) 'read-plan) (message-condition? e))
               (fail (string-append path ": " (condition-message e)))))
      (read-plan (read-text path)))))

(define forms (apply append (map read-forms (list-tail args 3))))
(for-each (lambda (x)
            (unless (or (form-of? 'runtime x) (form-of? 'result x) (form-of? 'failure x)
                        (form-of? 'too-slow x))
              (fail "not a runtime, result, failure or too-slow form; is a harness writing to the results?")))
          forms)

(define runtimes (filter (lambda (x) (form-of? 'runtime x)) forms))
(define results (filter (lambda (x) (not (form-of? 'runtime x))) forms))
(let ((problems (cross-check files plan runtimes results)))
  (unless (null? problems) (apply fail problems)))
(display (report-text (read-machine (read-text (car args))) plan runtimes results))
