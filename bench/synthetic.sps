#!r6rs
;;; bench/synthetic.sps DIR: writes M0's synthetic files into DIR (plan §2),
;;; replacing any there. bench/files.lock pins their sha256, and
;;; `scripts/fetch-bench-files --check` holds them to it before `make bench`
;;; times anything.
(import (rnrs) (jsonparse-bench))

(define args (cdr (command-line)))
(unless (= (length args) 1)
  (display "usage: synthetic.sps DIR\n" (current-error-port))
  (exit 2))

(for-each
 (lambda (file)
   (let ((port (open-file-output-port (string-append (car args) "/" (car file))
                                      (file-options no-fail))))
     (put-bytevector port ((cdr file)))
     (close-port port)))
 synthetic-files)
