#!r6rs
;;; tests/test-docs.sps: every name a (jsonparse ...) library exports is in
;;; the docs, M1's exit criterion of a documented API.
;;;
;;;   1. the libraries are the eight under src/jsonparse, each read as data;
;;;      each export list holds a name known to be there, and as many names
;;;      as it did
;;;   2. docs/reference.md has exactly one entry for each exported name and
;;;      none for anything else, and each entry names exactly the libraries
;;;      that export it
;;;   3. every exported name also appears in a guide, a docs/*.md file other
;;;      than the reference, the home page, README.md, and installing.md, as a
;;;      whole name: neither character beside it may continue a Scheme
;;;      identifier, so json-error? doesn't count as json-error. The guides
;;;      are pinned.
;;;
;;; A failing check lists what differs.
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

;; The guides: every docs/*.md but the reference, the home page and the
;; install page. They name exports without explaining them, so a name only
;; they hold isn't documented.
(define guide-files
  (filter (lambda (f) (not (member f '("reference.md" "README.md" "installing.md"))))
          (corpus-files docs-dir ".md")))

;; The guides, one string.
(define docs
  (apply string-append
         (map (lambda (f) (read-text (string-append docs-dir "/" f))) guide-files)))

;; --- the reference ---------------------------------------------------------------

;; lines : String -> (Listof String)
(define (lines text)
  (let loop ((i 0) (start 0) (acc '()))
    (cond ((= i (string-length text))
           (reverse (if (< start i) (cons (substring text start i) acc) acc)))
          ((char=? (string-ref text i) #\newline)
           (loop (+ i 1) (+ i 1) (cons (substring text start i) acc)))
          (else (loop (+ i 1) start acc)))))

(define (prefix? p s)
  (and (>= (string-length s) (string-length p))
       (string=? p (substring s 0 (string-length p)))))

;; between : String Char Nat -> (Option (Pair String Nat))
;; The text from after the first C at or after I to the next C, and where
;; that next C is.
(define (between s c i)
  (let find ((a i))
    (cond ((>= a (string-length s)) #f)
          ((char=? (string-ref s a) c)
           (let close ((b (+ a 1)))
             (cond ((>= b (string-length s)) #f)
                   ((char=? (string-ref s b) c) (cons (substring s (+ a 1) b) b))
                   (else (close (+ b 1))))))
          (else (find (+ a 1))))))

;; available : String -> (Listof String)
;; The library stems a line names in backquotes, as `(jsonparse easy)`.
(define (available line)
  (let loop ((i 0) (acc '()))
    (let ((q (between line #\` i)))
      (if (not q)
          (reverse acc)
          (loop (+ (cdr q) 1)
                (let ((t (car q)))
                  (if (and (prefix? "(jsonparse " t) (char=? (string-ref t (- (string-length t) 1)) #\)))
                      (cons (substring t 11 (- (string-length t) 1)) acc)
                      acc)))))))

;; entries : (Listof (Pair String (Listof String)))
;; Each reference entry, a ### heading's name in backquotes, with the
;; libraries its Available from line names.
(define entries
  (let loop ((ls (lines (read-text (string-append docs-dir "/reference.md")))) (acc '()))
    (cond ((null? ls) (reverse acc))
          ((prefix? "### `" (car ls))
           (loop (cdr ls) (cons (cons (car (between (car ls) #\` 0)) '()) acc)))
          ((and (prefix? "**Available from:**" (car ls)) (pair? acc))
           (loop (cdr ls) (cons (cons (caar acc) (append (cdar acc) (available (car ls)))) (cdr acc))))
          (else (loop (cdr ls) acc)))))

(define (sorted-strings l) (list-sort string<? l))

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

(test-equal "the guides are every docs page but the reference, the home page and the install page"
  '("easy.md" "parser.md" "sequence.md" "string.md" "tree.md" "writer.md")
  guide-files)

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

(define exported
  (let ((all (apply append (map (lambda (names) (map symbol->string (filter symbol? names))) export-lists))))
    (let loop ((l (sorted-strings all)) (acc '()))
      (cond ((null? l) (reverse acc))
            ((and (pair? acc) (string=? (car l) (car acc))) (loop (cdr l) acc))
            (else (loop (cdr l) (cons (car l) acc)))))))

;; The libraries that export NAME, sorted.
(define (exporters name)
  (sorted-strings
   (apply append (map (lambda (lib names) (if (memq (string->symbol name) names) (list lib) '()))
                      libraries export-lists))))

(test-equal "reference: every exported name has exactly one entry, and nothing else has one"
  exported
  (sorted-strings (map car entries)))

(test-equal "reference: each entry names exactly the libraries that export it"
  '()
  (filter (lambda (t) (not (equal? (cadr t) (caddr t))))
          (map (lambda (e) (list (car e) (exporters (car e)) (sorted-strings (cdr e)))) entries)))

(test-equal "every exported name is in a guide"
  '()
  (apply append
         (map (lambda (lib names)
                (map (lambda (name) (list lib name))
                     (filter (lambda (name) (not (and (symbol? name) (mentioned-in? (symbol->string name) docs))))
                             names)))
              libraries export-lists)))

(test-end "docs")

(exit (suite-exit-status runner))
