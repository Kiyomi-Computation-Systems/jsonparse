#!r6rs
;;; make check-release: holds jsonparse's own version together across the
;;; three places a release names it (ADR-0022). It reads three files as
;;; text and evaluates nothing:
;;;
;;;   Akku.manifest    the version its akku-package form gives jsonparse,
;;;                    ("jsonparse" "X.Y.Z");
;;;   CHANGELOG.md     the newest release: the first heading
;;;                    "## [X.Y.Z] - YYYY-MM-DD", after any
;;;                    "## [Unreleased]";
;;;   docs/README.md   the home page's Status, whose first line begins
;;;                    "vX.Y.Z".
;;;
;;; It writes one line per file, naming the version it read there or why it
;;; read none, then a verdict: all on stdout, exit 0, when the three are one
;;; version; all on stderr, exit 1, otherwise. A version is X.Y.Z, three runs
;;; of decimal digits, compared as text. Anything it cannot read is named and
;;; fails: it never guesses.
;;;
;;; Arguments: [ROOT]. With none the three are read from the current
;;; directory and named as above; with ROOT they are read and named below it.
;;; tests/test-check-release.sps runs it on a tree for each rule.
(import (rnrs))

(define package "jsonparse")

;; Read = (U (List 'version String) (List 'problem String))
;; What a file says: a version, or why it says none.
(define (version v) (list 'version v))
(define (problem text) (list 'problem text))

;; say : Port String -> Void
;; TEXT as one line, prefixed with the program's name.
(define (say port text)
  (put-string port "check-release: ")
  (put-string port text)
  (put-char port #\newline))

;; prefix? : String String -> Boolean
(define (prefix? prefix s)
  (and (>= (string-length s) (string-length prefix))
       (string=? prefix (substring s 0 (string-length prefix)))))

;; index-of : String Char Integer -> (U Integer #f)
(define (index-of s ch start)
  (let loop ((i start))
    (cond ((= i (string-length s)) #f)
          ((char=? (string-ref s i) ch) i)
          (else (loop (+ i 1))))))

;; lines : String -> (Listof String)
(define (lines text)
  (let loop ((start 0) (acc '()))
    (let ((nl (index-of text #\newline start)))
      (if nl
          (loop (+ nl 1) (cons (substring text start nl) acc))
          (reverse (cons (substring text start (string-length text)) acc))))))

;; digits? : String -> Boolean
;; One or more decimal digits and nothing else.
(define (digits? s)
  (and (> (string-length s) 0)
       (for-all (lambda (c) (and (char<=? #\0 c) (char<=? c #\9))) (string->list s))))

;; version-text? : String -> Boolean
;; X.Y.Z, three runs of decimal digits.
(define (version-text? s)
  (let* ((a (index-of s #\. 0))
         (b (and a (index-of s #\. (+ a 1)))))
    (and a b
         (digits? (substring s 0 a))
         (digits? (substring s (+ a 1) b))
         (digits? (substring s (+ b 1) (string-length s))))))

;; date-text? : String -> Boolean
;; YYYY-MM-DD, in digits.
(define (date-text? s)
  (and (= (string-length s) 10)
       (char=? (string-ref s 4) #\-)
       (char=? (string-ref s 7) #\-)
       (digits? (substring s 0 4))
       (digits? (substring s 5 7))
       (digits? (substring s 8 10))))

;; read-text : String -> (U String #f)
;; The file's text, "" for an empty file, or #f when there is none.
(define (read-text path)
  (and (file-exists? path)
       (let ((text (call-with-input-file path get-string-all)))
         (if (eof-object? text) "" text))))

;; manifest-version : String -> Read
;; The version in the line holding (akku-package ("jsonparse" "X.Y.Z").
(define (manifest-version text)
  (let* ((head (string-append "(akku-package (\"" package "\" \""))
         (hits (filter (lambda (l) (prefix? head l)) (lines text))))
    (cond
      ((not (= (length hits) 1))
       (problem (string-append "it has " (number->string (length hits))
                               " lines beginning " head ", but a manifest has one")))
      (else
       (let* ((rest (substring (car hits) (string-length head) (string-length (car hits))))
              (end (index-of rest #\" 0))
              (v (and end (substring rest 0 end))))
         (if (and v (version-text? v))
             (version v)
             (problem (string-append "its package version is not X.Y.Z: " (car hits)))))))))

;; changelog-version : String -> Read
;; The newest release: the first "## [" heading but "## [Unreleased]",
;; which must read "## [X.Y.Z] - YYYY-MM-DD".
(define (changelog-version text)
  (let ((heads (filter (lambda (l) (and (prefix? "## [" l) (not (prefix? "## [Unreleased]" l))))
                       (lines text))))
    (if (null? heads)
        (problem "it has no release heading, \"## [X.Y.Z] - YYYY-MM-DD\"")
        (let* ((h (car heads))
               (close (index-of h #\] 4))
               (v (and close (substring h 4 close)))
               (tail (and close (substring h (+ close 1) (string-length h)))))
          (if (and v (version-text? v)
                   (prefix? " - " tail)
                   (date-text? (substring tail 3 (string-length tail))))
              (version v)
              (problem (string-append "its newest release heading is not \"## [X.Y.Z] - YYYY-MM-DD\": " h)))))))

;; status-version : String -> Read
;; The first non-blank line after "## Status", which must begin "vX.Y.Z"
;; and then a comma, a space or its end.
(define (status-version text)
  (let ((after (member "## Status" (lines text))))
    (if (not after)
        (problem "it has no \"## Status\" section")
        (let ((body (filter (lambda (l) (> (string-length l) 0)) (cdr after))))
          (if (or (null? body) (not (prefix? "v" (car body))))
              (problem "its Status does not begin with the version, \"vX.Y.Z\"")
              (let* ((l (car body))
                     (end (let loop ((i 1))
                            (if (or (= i (string-length l))
                                    (memv (string-ref l i) '(#\, #\space)))
                                i
                                (loop (+ i 1)))))
                     (v (substring l 1 end)))
                (if (version-text? v)
                    (version v)
                    (problem (string-append "its Status does not begin with the version, \"vX.Y.Z\": " l)))))))))

;; The three files, with what reads each.
(define sources
  (list (cons "Akku.manifest" manifest-version)
        (cons "CHANGELOG.md" changelog-version)
        (cons "docs/README.md" status-version)))

;; read-source : String (Pairof String (String -> Read)) -> (Pairof Read String)
;; What one file says, and the line reporting it.
(define (read-source prefix source)
  (let* ((name (string-append prefix (car source)))
         (text (read-text name))
         (r (if text ((cdr source) text) (problem "it is missing"))))
    (cons r (string-append name ": "
                           (if (eq? (car r) 'version)
                               (string-append package " is " (cadr r))
                               (cadr r))))))

;; without-slashes : String -> String
(define (without-slashes dir)
  (let loop ((d dir))
    (if (and (> (string-length d) 1) (char=? (string-ref d (- (string-length d) 1)) #\/))
        (loop (substring d 0 (- (string-length d) 1)))
        d)))

(define (main args)
  (if (> (length args) 1)
      (begin
        (say (current-error-port) "usage: scheme --program tests/check-release.sps [ROOT]")
        (exit 1))
      (let* ((prefix (if (null? args) "" (string-append (without-slashes (car args)) "/")))
             (reports (map (lambda (source) (read-source prefix source)) sources))
             (results (map car reports))
             (versions (map cadr (filter (lambda (r) (eq? (car r) 'version)) results)))
             (verdict
              (cond
                ((< (length versions) (length results))
                 "not every version could be read, so they cannot be compared (ADR-0022)")
                ((for-all (lambda (v) (string=? v (car versions))) versions)
                 #f)
                (else "the three versions differ, but a release names one (ADR-0022)"))))
        (if verdict
            (begin
              (for-each (lambda (r) (say (current-error-port) (cdr r))) reports)
              (say (current-error-port) verdict)
              (exit 1))
            (begin
              (for-each (lambda (r) (say (current-output-port) (cdr r))) reports)
              (say (current-output-port)
                   (string-append "ok, jsonparse is " (car versions) " in all three"))
              (exit 0))))))

(main (cdr (command-line)))
