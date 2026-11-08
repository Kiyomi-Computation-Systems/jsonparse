#!r6rs
;;; tests/test-docs.sps: every name a (jsonparse ...) library exports is in
;;; the docs, M1's exit criterion of a documented API.
;;;
;;;   1. the libraries are the eight under src/jsonparse, each read as data,
;;;      and each export list holds a name known to be there
;;;   2. every exported name appears in some docs/*.md file as a whole name:
;;;      neither character beside it may continue a Scheme identifier, so
;;;      json-error? doesn't count as json-error
;;;
;;; A failing check lists each library and name that no doc mentions.
(import (rnrs)
        (srfi :64)
        (jsonparse-testing)
        (only (jsonparse-testing machine) corpus-files))

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

(define src-dir "src/jsonparse")
(define docs-dir "docs")

(define (read-text path)
  (call-with-port (open-file-input-port path (file-options) (buffer-mode block)
                                        (make-transcoder (utf-8-codec)))
                  get-string-all))

;; exports : String -> (Listof Symbol)
;; The names the library at PATH exports: plain identifiers, and the
;; second of each pair in a rename.
(define (exports path)
  (let ((form (call-with-port (open-file-input-port path (file-options) (buffer-mode block)
                                                    (make-transcoder (utf-8-codec)))
                              read)))
    (apply append
           (map (lambda (spec)
                  (cond ((symbol? spec) (list spec))
                        ((and (pair? spec) (eq? (car spec) 'rename)) (map cadr (cdr spec)))
                        (else (list (list 'unknown-export-spec spec)))))
                (apply append
                       (map cdr (filter (lambda (clause) (and (pair? clause) (eq? (car clause) 'export)))
                                        (cddr form))))))))

(define (stem name) (substring name 0 (- (string-length name) 4)))

(define libraries (map stem (corpus-files src-dir ".sls")))

(define export-lists
  (map (lambda (lib) (exports (string-append src-dir "/" lib ".sls"))) libraries))

;; The docs, one string.
(define docs
  (apply string-append
         (map (lambda (f) (read-text (string-append docs-dir "/" f)))
              (corpus-files docs-dir ".md"))))

;; constituent? : Char -> Boolean, a character that may continue an identifier
(define (constituent? c)
  (or (char-alphabetic? c) (char-numeric? c) (and (memv c (string->list "!$%&*/:<=>?^_~+-.@")) #t)))

;; mentioned-in? : String String -> Boolean, NAME somewhere in TEXT as a whole name
(define (mentioned-in? name text)
  (let ((n (string-length name)) (d (string-length text)))
    (let loop ((i 0))
      (cond ((> (+ i n) d) #f)
            ((and (string=? name (substring text i (+ i n)))
                  (or (= i 0) (not (constituent? (string-ref text (- i 1)))))
                  (or (= (+ i n) d) (not (constituent? (string-ref text (+ i n))))))
             #t)
            (else (loop (+ i 1)))))))

(test-begin "docs")

(test-equal "the libraries under src/jsonparse"
  '("easy" "error" "options" "parser" "sequence" "string" "tree" "writer")
  libraries)

(test-equal "a whole name is found, but not as part of a longer one"
  '(#t #t #t #t #f #f #f)
  (map (lambda (text) (mentioned-in? "json-error" text))
       '("json-error" "`json-error`" "(json-error x)" "a json-error, b"
         "json-error?" "json-error-reason" "&json-error")))

(test-equal "each library's export list holds a name known to be there"
  '(#t #t #t #t #t #t #t #t)
  (map (lambda (names known) (and (memq known names) #t))
       export-lists
       '(read-json-sequence make-json-error json-options-blank-lines make-json-result
         json-reader? json-assembler? json-builder? put-json-record)))

(test-equal "each library exports as many names as it did on 2026-11-08"
  '(("easy" . 26) ("error" . 9) ("options" . 10) ("parser" . 15) ("sequence" . 6) ("string" . 11) ("tree" . 6) ("writer" . 3))
  (map (lambda (lib names) (cons lib (length names))) libraries export-lists))

(test-equal "every exported name is in the docs"
  '()
  (apply append
         (map (lambda (lib names)
                (map (lambda (name) (list lib name))
                     (filter (lambda (name) (not (and (symbol? name) (mentioned-in? (symbol->string name) docs))))
                             names)))
              libraries export-lists)))

(test-end "docs")

(exit (suite-exit-status runner))
