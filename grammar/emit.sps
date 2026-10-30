#!r6rs
;;; make generate: renders the jsonparse machine and writes it to the path
;;; given as the only argument, src/generated/jsonparse.sls (ADR-0001). This
;;; is the only way that file is written. tests/test-generated.sps renders it
;;; again and compares, so a grammar change that is not regenerated fails
;;; make test.
;;;
;;; Exits 0 having written the file, 1 if the machine does not verify (the
;;; diagnostics go to stderr and nothing is written), 2 on a bad command
;;; line.
(import (rnrs) (jsonparse-grammar))

(define (die status . parts)
  (for-each (lambda (p) (display p (current-error-port))) parts)
  (newline (current-error-port))
  (exit status))

(define out
  (let ((args (cdr (command-line))))
    (if (= (length args) 1)
        (car args)
        (die 2 "usage: emit.sps OUTPUT"))))

(define bytes
  (guard (e ((and (who-condition? e) (eq? (condition-who e) 'render-generated))
             (for-each (lambda (d) (write d (current-error-port))
                               (newline (current-error-port)))
                       (if (irritants-condition? e) (condition-irritants e) '()))
             (die 1 "emit.sps: " (condition-message e) "; nothing written")))
    (render-generated)))

(when (file-exists? out) (delete-file out))
(call-with-port (open-file-output-port out)
  (lambda (port) (put-bytevector port bytes)))
(display (string-append "emit.sps: wrote " (number->string (bytevector-length bytes))
                        " bytes to " out "\n"))
(exit 0)
