#!r6rs
;;; make check-corpora: holds the vendored test corpora to ADR-0012. Each
;;; corpus lives in its own directory below tests/corpus/ with its upstream
;;; license and a SOURCE file saying where the data came from, so that anyone
;;; can find, refetch and relicense it. JSON_checker's files are never
;;; vendored, because its license (the "shall be used for Good, not Evil"
;;; clause) is not one we can pass on.
;;;
;;; Given a directory, it fails unless:
;;;
;;;   - every entry directly inside it is a directory, not a file or a
;;;     symbolic link;
;;;   - there is at least one such directory;
;;;   - each holds a non-empty regular file LICENSE and a regular file SOURCE,
;;;     and SOURCE has each of the keys name, url, commit, fetched, taken and
;;;     license exactly once, as `key: value` lines with a non-empty value;
;;;   - commit is 40 lowercase hex digits and url starts with https://;
;;;   - no file anywhere below it is a JSON_checker file: named pass<digits>.json
;;;     or fail<digits>.json, or holding the text `JSON Test Pattern pass`,
;;;     JSON_checker's own marker.
;;;
;;; It names every problem on stderr, one line each, then exits 1. When there
;;; is none it writes one summary line on stdout and exits 0.
;;;
;;; Arguments: DIR (make passes tests/corpus). tests/test-check-corpora.sps
;;; runs it on a tree for each rule.
(import (rnrs)
        (only (chezscheme) directory-list file-directory? file-symbolic-link?))

;; say : Port String -> Unit
(define (say port text)
  (put-string port (string-append "check-corpora: " text "\n")))

(define keys '("name" "url" "commit" "fetched" "taken" "license"))

;; without-slashes : String -> String
(define (without-slashes dir)
  (let ((n (string-length dir)))
    (if (and (> n 1) (char=? (string-ref dir (- n 1)) #\/))
        (without-slashes (substring dir 0 (- n 1)))
        dir)))

;; join : String String -> String
(define (join dir name) (string-append dir "/" name))

;; present? : String -> Boolean
;; Whether PATH names anything, a dangling symbolic link included.
(define (present? path) (or (file-symbolic-link? path) (file-exists? path)))

;; entries : String -> (Listof String)
(define (entries dir) (list-sort string<? (directory-list dir)))

;; prefix? : String String -> Boolean
(define (prefix? prefix s)
  (and (<= (string-length prefix) (string-length s))
       (string=? prefix (substring s 0 (string-length prefix)))))

;; file-bytes : String -> Bytevector
(define (file-bytes path)
  (let* ((port (open-file-input-port path))
         (bytes (get-bytevector-all port)))
    (close-port port)
    (if (eof-object? bytes) (make-bytevector 0) bytes)))

;; bytes-contain? : Bytevector Bytevector -> Boolean
(define (bytes-contain? hay needle)
  (let ((n (bytevector-length hay)) (m (bytevector-length needle)))
    (let outer ((i 0))
      (and (<= (+ i m) n)
           (or (let inner ((j 0))
                 (or (= j m)
                     (and (= (bytevector-u8-ref hay (+ i j)) (bytevector-u8-ref needle j))
                          (inner (+ j 1)))))
               (outer (+ i 1)))))))

;; digits? : String -> Boolean
;; Whether S is one or more of the digits 0 to 9.
(define (digits? s)
  (and (> (string-length s) 0)
       (for-all (lambda (c) (and (char<=? #\0 c) (char<=? c #\9))) (string->list s))))

;; checker-name? : String -> Boolean
;; Whether the file name NAME is pass<digits>.json or fail<digits>.json.
(define (checker-name? name)
  (let ((n (string-length name)))
    (and (> n 5)
         (string=? ".json" (substring name (- n 5) n))
         (let ((stem (substring name 0 (- n 5))))
           (or (and (prefix? "pass" stem) (digits? (substring stem 4 (string-length stem))))
               (and (prefix? "fail" stem) (digits? (substring stem 4 (string-length stem)))))))))

(define marker (string->utf8 "JSON Test Pattern pass"))

;; scan : String -> (Listof String)
;; The problems with every file below DIR, symbolic links not followed.
(define (scan dir)
  (apply append
         (map (lambda (name)
                (let ((path (join dir name)))
                  (cond
                    ((file-symbolic-link? path)
                     (cons (string-append path ": is a symbolic link; links below a corpus are never followed (ADR-0012)")
                           (if (checker-name? name) (list (checker-problem path)) '())))
                    ((file-directory? path) (scan path))
                    (else
                     (append
                      (if (checker-name? name) (list (checker-problem path)) '())
                      (if (bytes-contain? (file-bytes path) marker)
                          (list (string-append path ": holds the text \"JSON Test Pattern pass\", so it is a JSON_checker file (ADR-0012)"))
                          '()))))))
              (entries dir))))

;; checker-problem : String -> String
(define (checker-problem path)
  (string-append path ": is named like a JSON_checker file, pass<digits>.json or fail<digits>.json (ADR-0012)"))

;; split-lines : String -> (Listof String)
(define (split-lines text)
  (let loop ((i 0) (start 0) (found '()))
    (cond ((= i (string-length text))
           (reverse (if (> i start) (cons (substring text start i) found) found)))
          ((char=? (string-ref text i) #\newline)
           (loop (+ i 1) (+ i 1) (cons (substring text start i) found)))
          (else (loop (+ i 1) start found)))))

;; trim : String -> String
;; S without leading and trailing spaces, tabs and carriage returns.
(define (trim s)
  (let* ((blank? (lambda (c) (memv c '(#\space #\tab #\return))))
         (n (string-length s))
         (a (let loop ((i 0)) (if (and (< i n) (blank? (string-ref s i))) (loop (+ i 1)) i)))
         (b (let loop ((i n)) (if (and (> i a) (blank? (string-ref s (- i 1)))) (loop (- i 1)) i))))
    (substring s a b)))

;; source-fields : String -> (Listof (Pair String String))
;; The `key: value` lines of TEXT, split at each line's first colon.
(define (source-fields text)
  (let loop ((lines (split-lines text)) (found '()))
    (if (null? lines)
        (reverse found)
        (let ((colon (let find ((i 0))
                       (cond ((= i (string-length (car lines))) #f)
                             ((char=? (string-ref (car lines) i) #\:) i)
                             (else (find (+ i 1)))))))
          (loop (cdr lines)
                (if colon
                    (cons (cons (trim (substring (car lines) 0 colon))
                                (trim (substring (car lines) (+ colon 1) (string-length (car lines)))))
                          found)
                    found))))))

;; lowercase-hex? : String -> Boolean
(define (lowercase-hex? s)
  (for-all (lambda (c) (or (and (char<=? #\0 c) (char<=? c #\9))
                           (and (char<=? #\a c) (char<=? c #\f))))
           (string->list s)))

;; source-problems : String String -> (Listof String)
;; The problems with the SOURCE file at PATH, whose text is TEXT.
(define (source-problems path text)
  (let ((all (source-fields text)))
    (apply append
           (map (lambda (key)
                  (let* ((mine (filter (lambda (f) (string=? (car f) key)) all))
                         (n (length mine))
                         (value (and (= n 1) (cdar mine)))
                         (say-key (lambda (t) (string-append path ": " t))))
                    (cond
                      ((= n 0) (list (say-key (string-append "key " key " is missing"))))
                      ((> n 1) (list (say-key (string-append "key " key " appears "
                                                             (number->string n) " times, but exactly once is wanted"))))
                      ((string=? value "") (list (say-key (string-append "key " key " has an empty value"))))
                      ((and (string=? key "commit")
                            (not (and (= (string-length value) 40) (lowercase-hex? value))))
                       (list (say-key (string-append "commit is \"" value "\", not 40 lowercase hex digits"))))
                      ((and (string=? key "url") (not (prefix? "https://" value)))
                       (list (say-key (string-append "url is \"" value "\", which does not start with https://"))))
                      (else '()))))
                keys))))

;; regular-problem : String -> (U String #f)
;; Why PATH is no regular file, or #f.
(define (regular-problem path)
  (cond ((not (present? path)) "is missing")
        ((file-symbolic-link? path) "is a symbolic link, not a regular file")
        ((file-directory? path) "is not a regular file")
        (else #f)))

;; corpus-problems : String -> (Listof String)
;; The problems with the corpus directory DIR: LICENSE, SOURCE, then every
;; file below it.
(define (corpus-problems dir)
  (let* ((license (join dir "LICENSE"))
         (source (join dir "SOURCE"))
         (license-why (regular-problem license))
         (source-why (regular-problem source)))
    (append
     (cond (license-why (list (string-append license ": " license-why)))
           ((= 0 (bytevector-length (file-bytes license)))
            (list (string-append license ": is empty")))
           (else '()))
     (if source-why
         (list (string-append source ": " source-why))
         (source-problems source (bytevector->latin-1 (file-bytes source))))
     (scan dir))))

;; bytevector->latin-1 : Bytevector -> String
(define (bytevector->latin-1 bytes)
  (list->string (map integer->char (bytevector->u8-list bytes))))

;; main : (Listof String) -> Unit
(define (main args)
  (if (not (= (length args) 1))
      (begin
        (say (current-error-port) "usage: scheme --program tests/check-corpora.sps DIR")
        (exit 1))
      (let ((root (without-slashes (car args))))
        (if (not (file-directory? root))
            (begin
              (say (current-error-port) (string-append root ": is not a directory"))
              (exit 1))
            (let* ((names (entries root))
                   (dirs (filter (lambda (name)
                                   (let ((p (join root name)))
                                     (and (not (file-symbolic-link? p)) (file-directory? p))))
                                 names))
                   (problems
                    (append
                     (apply append
                            (map (lambda (name)
                                   (let ((p (join root name)))
                                     (cond ((file-symbolic-link? p)
                                            (list (string-append p ": is a symbolic link, not a directory")))
                                           ((file-directory? p) (corpus-problems p))
                                           (else (list (string-append p ": is a file, not a directory"))))))
                                 names))
                     (if (null? dirs)
                         (list (string-append root ": holds no corpus directory"))
                         '()))))
              (if (null? problems)
                  (begin
                    (say (current-output-port)
                         (string-append "ok, " (number->string (length dirs)) " corpora under " root))
                    (exit 0))
                  (begin
                    (for-each (lambda (p) (say (current-error-port) p)) problems)
                    (exit 1))))))))

(main (cdr (command-line)))
