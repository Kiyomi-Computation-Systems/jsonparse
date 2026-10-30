#!r6rs
;;; The regeneration check (ADR-0001). src/generated/jsonparse.sls is
;;; committed, and (render-generated) is what it must hold. This suite renders
;;; the machine again and fails unless the file matches byte for byte, naming
;;; the first offset that differs and telling the user to run `make generate`.
;;; It also asserts the file's header and that byte-machine verifies the graph.
;;;
;;; make test runs it from the repository root.
(import (rnrs)
        (srfi :64)
        (jsonparse-testing)
        (jsonparse-grammar)
        (byte-machine verify))

(define runner (test-runner-simple))
(test-runner-current runner)
(let ((e (test-runner-on-test-end runner)))
  (test-runner-on-test-end! runner
    (lambda (r) (e r)
      (when (eq? (test-result-kind r) (quote fail))
        (display "  expected: ") (write (test-result-ref r (quote expected-value))) (newline)
        (display "  actual:   ") (write (test-result-ref r (quote actual-value))) (newline)))))

(define generated-path "src/generated/jsonparse.sls")

;; file-bytes : String -> Bytevector
(define (file-bytes path)
  (let* ((port (open-file-input-port path))
         (bytes (get-bytevector-all port)))
    (close-port port)
    (if (eof-object? bytes) (make-bytevector 0) bytes)))

;; first-difference : Bytevector Bytevector -> (U Natural #f)
;; The first offset at which A and B differ (the shorter's length when one is
;; a prefix of the other), or #f when they are equal.
(define (first-difference a b)
  (let ((n (min (bytevector-length a) (bytevector-length b))))
    (let loop ((i 0))
      (cond ((= i n)
             (if (= (bytevector-length a) (bytevector-length b)) #f n))
            ((= (bytevector-u8-ref a i) (bytevector-u8-ref b i)) (loop (+ i 1)))
            (else i)))))

;; verdict : Bytevector Bytevector -> String
;; "ok" when the rendering equals the committed file, else a message naming
;; the first differing offset.
(define (verdict rendered committed)
  (let ((at (first-difference rendered committed)))
    (if at
        (string-append generated-path " differs from (render-generated) at byte offset "
                       (number->string at) " (rendered " (number->string (bytevector-length rendered))
                       " bytes, committed " (number->string (bytevector-length committed)) " bytes"
                       "): run `make generate`")
        "ok")))

(define committed (file-bytes generated-path))
(define header (string->utf8 "#!r6rs\n"))

(test-begin "generated")

(test-equal "src/generated/jsonparse.sls is what (render-generated) renders, byte for byte"
  "ok"
  (verdict (render-generated) committed))

(test-equal "the file begins with #!r6rs and a line feed"
  header
  (let ((n (bytevector-length header)))
    (if (>= (bytevector-length committed) n)
        (let ((head (make-bytevector n)))
          (bytevector-copy! committed 0 head 0 n)
          head)
        committed)))

(test-equal "byte-machine verifies the graph"
  #t
  (verification-ok? (verify-machine jsonparse-graph)))

;; The verdict itself, on inputs built here: it names the offset and the
;; remedy, and tells equal from a prefix.
(test-equal "verdict names the first differing offset"
  (string-append generated-path " differs from (render-generated) at byte offset 2 (rendered 3 bytes, committed 3 bytes): run `make generate`")
  (verdict (u8-list->bytevector (list 1 2 3)) (u8-list->bytevector (list 1 2 4))))

(test-equal "verdict on a prefix names the shorter's length"
  (string-append generated-path " differs from (render-generated) at byte offset 2 (rendered 2 bytes, committed 3 bytes): run `make generate`")
  (verdict (u8-list->bytevector (list 1 2)) (u8-list->bytevector (list 1 2 3))))

(test-end "generated")

(exit (suite-exit-status runner))
