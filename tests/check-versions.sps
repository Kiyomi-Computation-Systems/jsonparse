#!r6rs
;;; make check-versions: holds byte-machine's three versions together
;;; (ADR-0002). It reads three files as data, with Chez's reader, and
;;; evaluates nothing:
;;;
;;;   Akku.manifest                      the floor of the range its depends
;;;                                      clause gives byte-machine, ^X.Y.Z;
;;;   Akku.lock                          the version in the archive URL it
;;;                                      locks byte-machine at,
;;;                                      .../byte-machine_X.Y.Z_repack.tar.xz;
;;;   vendor/byte-machine/Akku.manifest  the version of the package the
;;;                                      submodule holds.
;;;
;;; The submodule's gitlink is the fourth, but reading it needs git, which
;;; the container lacks (ADR-0008): the package version it checks out
;;; stands for it.
;;;
;;; It writes one line per file, naming the version it read there or why it
;;; read none, then a verdict: all on stdout, exit 0, when the three are one
;;; version; all on stderr, exit 1, otherwise. A version is X.Y.Z, three runs
;;; of decimal digits, compared as text. Anything it cannot read is named and
;;; fails: it never guesses.
;;;
;;; Arguments: [ROOT]. With none the three are read from the current
;;; directory and named as above; with ROOT they are read and named below it.
;;; tests/test-check-versions.sps runs it on a tree for each rule.
(import (rnrs)
        (jsonparse-testing))

(define package "byte-machine")

;; Read = (U (List 'version String) (List 'problem String))
;; What a file says: a version, or why it says none.
(define (version v) (list 'version v))
(define (problem text) (list 'problem text))

;; written : Any -> String
(define (written datum)
  (call-with-string-output-port (lambda (p) (write datum p))))

;; say : Port String -> Unit
(define (say port text)
  (put-string port (string-append "check-versions: " text "\n")))

;; read-data : String -> (U (List 'data (Listof Any)) (List 'unreadable String))
(define (read-data path)
  (guard (e (#t (list 'unreadable (describe e))))
    (call-with-port (open-file-input-port path (file-options) (buffer-mode block)
                                          (make-transcoder (utf-8-codec)))
      (lambda (port)
        (let loop ((found '()))
          (let ((datum (read port)))
            (if (eof-object? datum)
                (list 'data (reverse found))
                (loop (cons datum found)))))))))

;; split : String Char -> (Listof String)
;; TEXT's pieces between each CH, empty ones kept.
(define (split text ch)
  (let loop ((i 0) (start 0) (found '()))
    (cond ((= i (string-length text))
           (reverse (cons (substring text start i) found)))
          ((char=? (string-ref text i) ch)
           (loop (+ i 1) (+ i 1) (cons (substring text start i) found)))
          (else (loop (+ i 1) start found)))))

;; version-text? : Any -> Boolean
;; Whether V is X.Y.Z: three non-empty runs of the digits 0 to 9.
(define (version-text? v)
  (and (string? v)
       (let ((parts (split v #\.)))
         (and (= (length parts) 3)
              (for-all (lambda (part)
                         (and (> (string-length part) 0)
                              (for-all (lambda (c) (and (char<=? #\0 c) (char<=? c #\9)))
                                       (string->list part))))
                       parts)))))

;; prefix? : String String -> Boolean
(define (prefix? prefix s)
  (and (<= (string-length prefix) (string-length s))
       (string=? prefix (substring s 0 (string-length prefix)))))

;; suffix? : String String -> Boolean
(define (suffix? suffix s)
  (let ((n (string-length s)) (m (string-length suffix)))
    (and (>= n m) (string=? (substring s (- n m) n) suffix))))

;; headed? : Symbol Any -> Boolean
(define (headed? key form)
  (and (pair? form) (list? form) (eq? (car form) key)))

;; clause : Any Symbol -> (U (Listof Any) #f)
;; The first element of the list FORM headed by KEY.
(define (clause form key)
  (and (list? form) (find (lambda (c) (headed? key c)) form)))

;; the-package : (Listof Any) ((Listof Any) -> Read) -> Read
;; K of the one akku-package form in DATA.
(define (the-package data k)
  (let ((forms (filter (lambda (d) (headed? 'akku-package d)) data)))
    (if (= (length forms) 1)
        (k (car forms))
        (problem (string-append "it holds " (number->string (length forms))
                                " akku-package forms, but a manifest holds exactly one")))))

;; caret-floor : Any -> (U String #f)
;; X.Y.Z when ENTRY is ("byte-machine" "^X.Y.Z").
(define (caret-floor entry)
  (and (list? entry)
       (= (length entry) 2)
       (string? (cadr entry))
       (prefix? "^" (cadr entry))
       (let ((v (substring (cadr entry) 1 (string-length (cadr entry)))))
         (and (version-text? v) v))))

;; floor-of : (Listof Any) -> Read
;; Akku.manifest's floor for byte-machine: its one entry across the depends
;; clauses, never depends/dev.
(define (floor-of data)
  (the-package data
    (lambda (form)
      (let* ((entries (apply append (map cdr (filter (lambda (c) (headed? 'depends c)) (cdr form)))))
             (ours (filter (lambda (e) (and (pair? e) (equal? (car e) package))) entries)))
        (cond
          ((not (= (length ours) 1))
           (problem (string-append "its depends clauses name byte-machine "
                                   (number->string (length ours))
                                   " times, but a floor needs exactly one")))
          ((caret-floor (car ours)) => version)
          (else
           (problem (string-append "its depends entry for byte-machine is " (written (car ours))
                                   ", not (\"byte-machine\" \"^X.Y.Z\")"))))))))

;; archive-version : String -> (U String #f)
;; X.Y.Z when URL's last segment is byte-machine_X.Y.Z_repack.tar.xz.
(define (archive-version url)
  (let* ((segments (split url #\/))
         (last (list-ref segments (- (length segments) 1)))
         (head "byte-machine_")
         (tail "_repack.tar.xz"))
    (and (prefix? head last)
         (suffix? tail last)
         (> (string-length last) (+ (string-length head) (string-length tail)))
         (let ((v (substring last (string-length head) (- (string-length last) (string-length tail)))))
           (and (version-text? v) v)))))

;; locked-of : (Listof Any) -> Read
;; Akku.lock's version for byte-machine: from the archive URL of its one
;; project named byte-machine, in its one projects form.
(define (locked-of data)
  (let ((forms (filter (lambda (d) (headed? 'projects d)) data)))
    (if (not (= (length forms) 1))
        (problem (string-append "it holds " (number->string (length forms))
                                " projects forms, but a lock holds exactly one"))
        (let ((ours (filter (lambda (p) (equal? (clause p 'name) (list 'name package)))
                            (cdr (car forms)))))
          (if (not (= (length ours) 1))
              (problem (string-append "it locks byte-machine " (number->string (length ours))
                                      " times, but exactly once is wanted"))
              (let ((location (clause (car ours) 'location)))
                (if (and location
                         (= (length location) 2)
                         (headed? 'url (cadr location))
                         (= (length (cadr location)) 2)
                         (string? (cadr (cadr location))))
                    (let ((url (cadr (cadr location))))
                      (cond ((archive-version url) => version)
                            (else (problem (string-append "byte-machine's archive URL is " (written url)
                                                          ", which does not end in /byte-machine_X.Y.Z_repack.tar.xz")))))
                    (problem (string-append "byte-machine's location is " (written location)
                                            ", not (location (url \".../byte-machine_X.Y.Z_repack.tar.xz\"))")))))))))

;; vendored-of : (Listof Any) -> Read
;; The vendored manifest's version: its akku-package form begins with
;; ("byte-machine" "X.Y.Z").
(define (vendored-of data)
  (the-package data
    (lambda (form)
      (let ((head (and (pair? (cdr form)) (cadr form))))
        (cond
          ((not (and (list? head) (= (length head) 2) (string? (car head)) (string? (cadr head))))
           (problem "its akku-package form does not begin with (NAME VERSION)"))
          ((not (string=? (car head) package))
           (problem (string-append "its package is " (written (car head)) ", not " (written package))))
          ((version-text? (cadr head)) (version (cadr head)))
          (else
           (problem (string-append "byte-machine's version is " (written (cadr head)) ", not X.Y.Z"))))))))

;; sources : (Listof (List String ((Listof Any) -> Read) String))
;; Each file below the root, how its version is read, and what its line
;; says before the version.
(define sources
  (list (list "Akku.manifest" floor-of "byte-machine's floor is ")
        (list "Akku.lock" locked-of "byte-machine is locked at ")
        (list "vendor/byte-machine/Akku.manifest" vendored-of "byte-machine is ")))

;; without-slashes : String -> String
(define (without-slashes dir)
  (let ((n (string-length dir)))
    (if (and (> n 1) (char=? (string-ref dir (- n 1)) #\/))
        (without-slashes (substring dir 0 (- n 1)))
        dir)))

;; read-source : String (List String ((Listof Any) -> Read) String) -> (Pair Read String)
;; What the file says, and its line, below PREFIX.
(define (read-source prefix source)
  (let* ((path (string-append prefix (car source)))
         (found (read-data path))
         (result (if (eq? (car found) 'data)
                     ((cadr source) (cadr found))
                     (problem (string-append "it cannot be read as data: " (cadr found))))))
    (cons result
          (string-append path ": "
                         (if (eq? (car result) 'version)
                             (string-append (caddr source) (cadr result))
                             (cadr result))))))

;; main : (Listof String) -> Unit
(define (main args)
  (if (> (length args) 1)
      (begin
        (say (current-error-port) "usage: scheme --program tests/check-versions.sps [ROOT]")
        (exit 1))
      (let* ((prefix (if (null? args) "" (string-append (without-slashes (car args)) "/")))
             (reports (map (lambda (source) (read-source prefix source)) sources))
             (results (map car reports))
             (versions (map cadr (filter (lambda (r) (eq? (car r) 'version)) results)))
             (verdict
              (cond
                ((< (length versions) (length results))
                 "not every version could be read, so they cannot be compared (ADR-0002)")
                ((for-all (lambda (v) (string=? v (car versions))) versions)
                 #f)
                (else "the three versions differ, but they move together (ADR-0002)"))))
        (if verdict
            (begin
              (for-each (lambda (r) (say (current-error-port) (cdr r))) reports)
              (say (current-error-port) verdict)
              (exit 1))
            (begin
              (for-each (lambda (r) (say (current-output-port) (cdr r))) reports)
              (say (current-output-port)
                   (string-append "ok, byte-machine is " (car versions) " in all three"))
              (exit 0))))))

(main (cdr (command-line)))
