#!r6rs
;;; tests/test-roundtrip.sps: nativejson-benchmark's 27 round-trip files
;;; (ADR-0012). Reading a file, then writing what was read, gives back the
;;; file's bytes:
;;;
;;;   1. the corpus is all here: roundtrip01.json to roundtrip27.json
;;;   2. in text mode, every file, read in one feed by bytevector->json and
;;;      written by json->bytevector
;;;   3. in flonum mode, every file not in flonum-exceptions, and each listed
;;;      one differs. None is listed: every file came back on 2026-11-08.
;;;      And under (make-json-options), whose number-mode is flonum
;;;   4. both modes again, each file fed to a builder in chunks of 1 to 31
;;;      bytes and written by put-json
;;;
;;; exact mode is no round trip, and isn't checked: it writes 0.0 as 0.
;;; A failing check names each file that differs, with what was written.
(import (rnrs)
        (srfi :64)
        (jsonparse-testing)
        (only (jsonparse-testing machine) file-bytes corpus-files)
        (jsonparse easy)
        (jsonparse parser)
        (jsonparse tree)
        (jsonparse writer))

(define runner (test-runner-simple))
(test-runner-current runner)

;; The simple runner names a failing test but not its values. Print both.
(let ((simple-end (test-runner-on-test-end runner)))
  (test-runner-on-test-end! runner
    (lambda (r)
      (simple-end r)
      (when (memq (test-result-kind r) '(fail xpass))
        (display "  expected: ")
        (write (test-result-ref r 'expected-value))
        (newline)
        (display "  actual:   ")
        (write (test-result-ref r 'actual-value))
        (newline)))))

(define dir "tests/corpus/nativejson-benchmark/files")

;; The files flonum mode doesn't give back, each with its reason.
(define flonum-exceptions '())

(define (bytes name) (file-bytes (string-append dir "/" name)))

;; default is (make-json-options), with no options given.
(define (mode-options mode)
  (if (eq? mode 'default) (make-json-options) (make-json-options 'number-mode mode)))

;; one-feed : String Symbol -> (U Bytevector (List 'error Symbol))
(define (one-feed name mode)
  (let ((o (mode-options mode)))
    (guard (e ((json-error? e) (list 'error (json-error-reason e))))
      (json->bytevector (bytevector->json (bytes name) o) o))))

;; chunked : Nat -> (String Symbol -> (U Bytevector (List 'error Symbol)))
;; Reads the file with a builder in chunks of K bytes, then writes the value
;; with put-json.
(define (chunked k)
  (lambda (name mode)
    (let* ((o (mode-options mode)) (b (make-json-builder o))
           (bv (bytes name)) (n (bytevector-length bv)))
      (let loop ((i 0))
        (if (< i n)
            (let* ((j (min n (+ i k))) (r (json-builder-feed! b bv i j)))
              (if (eq? (json-result-status r) 'error)
                  (list 'error (json-result-code r))
                  (loop j)))
            (let ((r (json-builder-finish! b)))
              (if (eq? (json-result-status r) 'finished)
                  (let-values (((port extract) (open-bytevector-output-port)))
                    (put-json port (json-builder-value b) o)
                    (extract))
                  (list 'error (json-result-code r)))))))))

;; differing : (String Symbol -> Any) Symbol (Listof String) -> (Listof (List String Any))
;; The files whose round trip under MODE isn't their bytes, with what was
;; written.
(define (differing read mode names)
  (let loop ((names names) (acc '()))
    (if (null? names)
        (reverse acc)
        (let ((out (read (car names) mode)))
          (loop (cdr names)
                (if (equal? out (bytes (car names)))
                    acc
                    (cons (list (car names) (if (bytevector? out) (utf8->string out) out)) acc)))))))

(define (count-up from to)
  (if (> from to) '() (cons from (count-up (+ from 1) to))))

(test-begin "roundtrip")

;; --- 1. the corpus --------------------------------------------------------------

(define names (corpus-files dir ".json"))

(test-equal "the corpus is all here: roundtrip01.json to roundtrip27.json"
  (map (lambda (i) (string-append "roundtrip" (if (< i 10) "0" "") (number->string i) ".json"))
       (count-up 1 27))
  names)

;; --- 2 and 3. one feed --------------------------------------------------------

(test-equal "text mode: every file comes back byte for byte"
  '()
  (differing one-feed 'text names))

(test-equal "flonum mode: every file but the listed ones comes back byte for byte, and each listed one differs"
  (map car flonum-exceptions)
  (map car (differing one-feed 'flonum names)))

(test-equal "default options: every file but the listed flonum ones comes back byte for byte"
  (map car flonum-exceptions)
  (map car (differing one-feed 'default names)))

;; --- 4. chunks of 1 to 31 bytes --------------------------------------------------

(define (chunked-failures mode)
  (let loop ((ks (count-up 1 31)) (acc '()))
    (if (null? ks)
        (reverse acc)
        (loop (cdr ks)
              (append (reverse (map (lambda (d) (cons (car ks) d))
                                    (differing (chunked (car ks)) mode names)))
                      acc)))))

(test-equal "text mode, in chunks of 1 to 31 bytes: every file comes back byte for byte"
  '()
  (chunked-failures 'text))

(test-equal "flonum mode, in chunks of 1 to 31 bytes: every file but the listed ones comes back"
  '()
  (filter (lambda (f) (not (assoc (cadr f) flonum-exceptions))) (chunked-failures 'flonum)))

(test-end "roundtrip")

(exit (suite-exit-status runner))
