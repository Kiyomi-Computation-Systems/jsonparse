;;; tests/write-golden.sps: writes tests/golden/jsontestsuite.txt, the file
;;; tests/test-conformance.sps compares the machine with.
;;;
;;; Run it deliberately, only when the grammar's answers are meant to change,
;;; and read `git diff tests/golden/jsontestsuite.txt` before committing:
;;;
;;;   scripts/guix-env sh -c 'make deps >/dev/null && $CHEZ --libdirs \
;;;     src:vendor/byte-machine/src:build/scheme-libs:tests:grammar:vendor/byte-machine/test/support/harness \
;;;     --program tests/write-golden.sps tests/golden/jsontestsuite.txt'
;;;
;;; One line per file of tests/corpus/jsontestsuite/test_parsing, sorted by
;;; name: NAME accepted, or NAME rejected CODE OFFSET (one feed, the
;;; generated machine).
(import (rnrs) (jsonparse-testing machine))

(define dir "tests/corpus/jsontestsuite/test_parsing")

(define (main path)
  (call-with-port (open-file-output-port path (file-options no-fail))
    (lambda (out)
      (for-each (lambda (name)
                  (put-bytevector out
                    (string->utf8
                     (string-append (golden-line name (file-bytes (string-append dir "/" name)))
                                    "\n"))))
                (corpus-files dir ".json")))))

(let ((args (command-line)))
  (if (= (length args) 2)
      (main (cadr args))
      (begin (display "usage: write-golden.sps OUTPUT-PATH\n" (current-error-port))
             (exit 1))))
