#!r6rs
;;; make check-imports: reads every file under the directory named on the
;;; command line (make passes src) as data, with Chez's reader, and evaluates
;;; nothing. It names, on stderr, each place that breaks one of these rules,
;;; with the file and the import or the problem, one line each, then exits 1
;;; (ADR-0001, ADR-0003, ADR-0010):
;;;
;;;   (a) every file is a .sls holding exactly one library form, which stands
;;;       at its name's path: src/jsonparse/tree.sls is (jsonparse tree), and
;;;       src/generated/jsonparse.sls is (generated jsonparse). Any other file
;;;       is named, and so is a symbolic link to a directory, which is not
;;;       followed;
;;;   (b) every library is named (jsonparse ...), or is (generated jsonparse);
;;;   (c) every .sls file begins with the line #!r6rs, and holds #! nowhere
;;;       else. Chez reads a file with no directive, or after #!chezscheme,
;;;       with its own syntax ('#3(0), '#vfx(1 2)), which R6RS lacks and the
;;;       rules here, reading only the data, never see. It fails closed: this
;;;       check cannot tell a directive from text, so a #! in a comment or a
;;;       string is refused too, and the complaint says so. The file is read
;;;       as bytes: the line is #!r6rs and a line feed, with no space,
;;;       carriage return or byte order mark;
;;;   (d) a library imports only the (rnrs ...) libraries but (rnrs eval),
;;;       the (jsonparse ...) libraries and (generated jsonparse), and
;;;       (byte-machine runtime). A (jsonparse ...) library or
;;;       (generated jsonparse) is imported only when a library under the
;;;       directory defines it: Chez would load any other from elsewhere on
;;;       its library path, which this check does not read. (rnrs eval) is
;;;       out because (environment '(chezscheme)) would reach any library
;;;       from a body this check never reads;
;;;   (e) no library imports (jsonparse easy), itself included: imports go
;;;       one way, from the easy layer down. And (jsonparse easy) composes
;;;       low-layer exports only, so it imports only the (rnrs ...)
;;;       libraries but (rnrs eval), and (jsonparse ...) libraries: never
;;;       (byte-machine runtime) or (generated jsonparse) (ADR-0010);
;;;   (f) an import spec is unwrapped to the library it names: through only,
;;;       except, prefix, rename and library, nested to any depth, and for,
;;;       with its import levels. A version reference, the last element of a
;;;       library reference, is dropped: it picks a version of the library the
;;;       name already picks, so it cannot make a library another one. A spec
;;;       it cannot unwrap is named, a cyclic one included;
;;;   (g) it fails closed: a directory with no library under it, a directory
;;;       that does not exist, a file it cannot read as data, and a datum that
;;;       is no library form are each named.
;;;
;;; The lists are allowlists: a library that is not on one is refused, so a
;;; route nobody thought of is closed until a reviewer opens it. Exports are
;;; not read: a library cannot import by exporting.
;;;
;;; On a pass it prints one line to stdout, naming how many libraries it
;;; checked. It exits 0 or 1, never a count. tests/test-check-imports.sps runs
;;; it on a tree for each rule.
(import (rnrs)
        (jsonparse-testing)
        (only (chezscheme) directory-list file-directory? parameterize print-graph))

;; rnrs-libraries : (Listof (Listof Symbol))
;; The standard libraries a library under the directory may import: R6RS's,
;; but for (rnrs eval). tests/test-check-imports.sps requires the list to
;; equal the (rnrs ...) libraries Chez has, but that one.
(define rnrs-libraries
  '((rnrs) (rnrs base) (rnrs arithmetic bitwise) (rnrs arithmetic fixnums)
    (rnrs arithmetic flonums) (rnrs bytevectors) (rnrs conditions)
    (rnrs control) (rnrs enums) (rnrs exceptions) (rnrs files)
    (rnrs hashtables) (rnrs io ports) (rnrs io simple) (rnrs lists)
    (rnrs mutable-pairs) (rnrs mutable-strings) (rnrs programs) (rnrs r5rs)
    (rnrs records inspection) (rnrs records procedural)
    (rnrs records syntactic) (rnrs sorting) (rnrs syntax-case) (rnrs unicode)))

;; The family every library under the directory but the generated parser
;; belongs to (ADR-0001).
(define family 'jsonparse)

;; The generated parser's name (ADR-0001).
(define generated-library '(generated jsonparse))

;; The one byte-machine library a library may import (ADR-0002).
(define runtime-library '(byte-machine runtime))

;; The easy layer, which no library may import (ADR-0010).
(define easy-library '(jsonparse easy))

;; wrappers : (Listof Symbol)
;; The import-set forms that wrap one import set, in their second element.
;; (library <reference>) wraps a reference, and is handled apart.
(define wrappers '(for only except prefix rename))

;; written : Any -> String
;; print-graph makes write label a cyclic datum, #0=(only #0# x), where it
;; would warn on stderr and then do the same.
(define (written datum)
  (call-with-string-output-port
    (lambda (p) (parameterize ((print-graph #t)) (write datum p)))))

;; abbreviated : Any -> String
;; DATUM written, cut to 57 characters and three dots when over 60.
(define (abbreviated datum)
  (let ((text (written datum)))
    (if (> (string-length text) 60)
        (string-append (substring text 0 57) "...")
        text)))

;; say : Port String -> Unit
(define (say port text)
  (put-string port (string-append "check-imports: " text "\n")))

;; suffix? : String String -> Boolean
(define (suffix? s suffix)
  (let ((n (string-length s)) (m (string-length suffix)))
    (and (>= n m) (string=? (substring s (- n m) n) suffix))))

;; joined : String (Pairof String (Listof String)) -> String
;; The strings, a separator between each two. There is always one.
(define (joined separator strings)
  (fold-left (lambda (text s) (string-append text separator s))
             (car strings)
             (cdr strings)))

;; without-slashes : String -> String
;; DIR without the slashes it ends with: a name is appended to it after one.
(define (without-slashes dir)
  (let ((n (string-length dir)))
    (if (and (> n 1) (char=? (string-ref dir (- n 1)) #\/))
        (without-slashes (substring dir 0 (- n 1)))
        dir)))

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

;; header-complaints : String String -> (Listof String)
;; Rule (c) for the file at PATH below ROOT: that it does not begin with the
;; line #!r6rs, and the lines that hold #! anywhere but its first two bytes.
;; A file it cannot read as bytes is left to read-data, which names it.
(define (header-complaints path root)
  (let ((bytes (guard (e (#t #f))
                 (let ((all (call-with-port (open-file-input-port path) get-bytevector-all)))
                   (if (eof-object? all) #vu8() all)))))
    (if (not bytes)
        '()
        (let ((lines (directive-lines bytes)))
          (append
           (if (begins-with-header? bytes)
               '()
               (list (string-append path ": its first line is not #!r6rs, which every .sls file under "
                                    root " begins with, so that Chez reads it as R6RS and not with its own syntax")))
           (if (null? lines)
               '()
               (list (string-append path ": it holds #! on " (line-list lines)
                                    ", and only the #!r6rs it begins with may: a #! may switch Chez's reader to its own syntax, and this check, which cannot tell a directive from text, refuses one in a comment or a string too"))))))))

(define header (string->utf8 "#!r6rs\n"))

;; begins-with-header? : Bytevector -> Boolean
;; Whether BYTES begin with #!r6rs and a line feed.
(define (begins-with-header? bytes)
  (let ((n (bytevector-length header)))
    (and (>= (bytevector-length bytes) n)
         (let loop ((i 0))
           (or (= i n)
               (and (= (bytevector-u8-ref bytes i) (bytevector-u8-ref header i))
                    (loop (+ i 1))))))))

;; directive-lines : Bytevector -> (Listof Natural)
;; The lines, counted from 1, that hold #! at any byte but the first: each
;; line once, in order.
(define (directive-lines bytes)
  (let ((n (bytevector-length bytes)))
    (let loop ((i 0) (line 1) (found '()))
      (cond
        ((>= (+ i 1) n) (reverse found))
        ((= (bytevector-u8-ref bytes i) 10) (loop (+ i 1) (+ line 1) found))
        ((and (> i 0)
              (= (bytevector-u8-ref bytes i) 35)
              (= (bytevector-u8-ref bytes (+ i 1)) 33))
         (loop (+ i 2) line (if (and (pair? found) (= (car found) line)) found (cons line found))))
        (else (loop (+ i 1) line found))))))

;; line-list : (Pairof Natural (Listof Natural)) -> String
;; "line 3", "lines 3 and 5", "lines 2, 6 and 7".
(define (line-list lines)
  (let ((names (map number->string lines)))
    (cond
      ((null? (cdr names)) (string-append "line " (car names)))
      (else
       (let ((last (list-ref names (- (length names) 1)))
             (rest (reverse (cdr (reverse names)))))
         (string-append "lines " (joined ", " rest) " and " last))))))

;; walk : String -> (Listof (Pair String (U 'file 'directory-link)))
;; Everything under DIR, as paths: the files, and the symbolic links to
;; directories, which it does not follow. A link that loops would never end.
(define (walk dir)
  (apply append
         (map (lambda (name)
                (let ((path (string-append dir "/" name)))
                  (cond
                    ((file-directory? path #f) (walk path))
                    ((file-directory? path) (list (cons path 'directory-link)))
                    (else (list (cons path 'file))))))
              (directory-list dir))))

;; reference-name : Any -> (U (Listof Symbol) #f)
;; The name in a library reference: its identifiers, and then at most one
;; list, the version reference, which is dropped. #f when it is no reference.
(define (reference-name ref)
  (and (list? ref)
       (let loop ((rest ref) (found '()))
         (cond
           ((null? rest) (and (pair? found) (reverse found)))
           ((symbol? (car rest)) (loop (cdr rest) (cons (car rest) found)))
           ((and (null? (cdr rest)) (list? (car rest))) (loop (cdr rest) found))
           (else #f)))))

;; spec-name : Any (Listof Any) -> (U (Listof Symbol) #f)
;; The one library an import spec imports, looking through the wrappers at any
;; depth. SEEN holds the specs it is inside, so a cyclic one ends in #f, not
;; in a loop. #f when it is no import spec this check can read.
(define (spec-name spec seen)
  (cond
    ((not (and (list? spec) (pair? spec))) #f)
    ((memq spec seen) #f)
    ((eq? (car spec) 'library)
     (and (= (length spec) 2) (pair? (cadr spec)) (reference-name (cadr spec))))
    ((memq (car spec) wrappers)
     (and (pair? (cdr spec)) (spec-name (cadr spec) (cons spec seen))))
    (else (reference-name spec))))

;; headed? : Symbol Any -> Boolean
(define (headed? key form)
  (and (pair? form) (list? form) (eq? (car form) key)))

;; library-form? : Any -> Boolean
;; (library <name> (export ...) (import ...) <body> ...)
(define (library-form? datum)
  (and (list? datum)
       (>= (length datum) 4)
       (eq? (car datum) 'library)
       (reference-name (cadr datum))
       (headed? 'export (caddr datum))
       (headed? 'import (cadddr datum))
       #t))

;; ours? : (Listof Symbol) -> Boolean
;; Whether NAME is a (jsonparse ...) library or the generated parser.
(define (ours? name)
  (or (eq? (car name) family) (equal? name generated-library)))

;; library-path : String (Listof Symbol) -> String
;; Where a library named NAME stands below ROOT: its identifiers joined by /,
;; then .sls. Chez looks for it there, in each library directory in turn.
(define (library-path root name)
  (string-append root "/" (joined "/" (map symbol->string name)) ".sls"))

;; defined-libraries : (Listof (Pair String (U (List 'data (Listof Any)) (List 'unreadable String))))
;;                     -> (Listof (Listof Symbol))
;; The name of every library form in the files read, those it can read.
(define (defined-libraries reads)
  (apply append
         (map (lambda (entry)
                (let ((found (cdr entry)))
                  (if (eq? (car found) 'data)
                      (map (lambda (form) (reference-name (cadr form)))
                           (filter library-form? (cadr found)))
                      '())))
              reads)))

;; import-complaints : String String (Listof Symbol) Any (Listof (Listof Symbol))
;;                     -> (Listof String)
;; What is wrong with the import spec SPEC of the library NAME, read from PATH
;; below ROOT: none, or one. DEFINED is the libraries defined under ROOT.
(define (import-complaints path root name spec defined)
  (let ((imported (spec-name spec '()))
        (library (written name)))
    (define (refuse imported reason)
      (list (string-append path ": " library " imports " (written imported)
                           ", but " reason)))
    (cond
      ((not imported)
       (list (string-append path ": " library " has an import it cannot read: "
                            (abbreviated spec))))
      ((equal? imported easy-library)
       (refuse imported
               (string-append "no library may import " (written easy-library)
                              ": imports go one way, from the easy layer down (ADR-0010)")))
      ((member imported rnrs-libraries) '())
      ((and (equal? name easy-library) (not (eq? (car imported) family)))
       (refuse imported
               (string-append (written easy-library)
                              " may import only the (rnrs ...) libraries except (rnrs eval), and ("
                              (symbol->string family)
                              " ...) libraries: it composes low-layer exports only (ADR-0010)")))
      ((equal? imported runtime-library) '())
      ((ours? imported)
       (if (member imported defined)
           '()
           (refuse imported (string-append "no library under " root " defines it"))))
      (else
       (refuse imported
               (string-append "a library may import only the (rnrs ...) libraries except (rnrs eval), ("
                              (symbol->string family) " ...) libraries, "
                              (written generated-library) " and " (written runtime-library)))))))

;; library-complaints : String String Any (Listof (Listof Symbol)) -> (Listof String)
;; What is wrong with the library form FORM, read from PATH below ROOT: its
;; family, its place, then its imports, in import order.
(define (library-complaints path root form defined)
  (let* ((name (reference-name (cadr form)))
         (library (written name))
         (want (library-path root name)))
    (append
     (if (ours? name)
         '()
         (list (string-append path ": " library " is neither a (" (symbol->string family)
                              " ...) library nor " (written generated-library)
                              ": every library under " root " is one of them")))
     (if (string=? path want)
         '()
         (list (string-append path ": " library " is defined here, but its name's path is " want)))
     (apply append
            (map (lambda (spec) (import-complaints path root name spec defined))
                 (cdr (cadddr form)))))))

;; data-complaints : String String (Listof Any) (Listof (Listof Symbol)) -> (Listof String)
;; What is wrong with the data of the file at PATH below ROOT: each datum that
;; is no library form, the count when there is more than one library, then each
;; library's own problems, in the order found.
(define (data-complaints path root data defined)
  (let ((forms (filter library-form? data)))
    (append
     (if (null? data)
         (list (string-append path ": it holds no datum, so it holds no library"))
         '())
     (let loop ((rest data) (n 1))
       (cond
         ((null? rest) '())
         ((library-form? (car rest)) (loop (cdr rest) (+ n 1)))
         (else (cons (string-append path ": datum " (number->string n) " is "
                                    (abbreviated (car rest)) ", not a library form")
                     (loop (cdr rest) (+ n 1))))))
     (if (> (length forms) 1)
         (list (string-append path ": it holds " (number->string (length forms))
                              " libraries, but a file holds exactly one"))
         '())
     (apply append
            (map (lambda (form) (library-complaints path root form defined)) forms)))))

;; entry-result : (Pair String (U 'file 'directory-link)) String
;;                (Listof (Pair String Read)) (Listof (Listof Symbol))
;;                -> (Pair (Listof String) Natural)
;; The complaints about one thing under ROOT, and how many libraries it holds.
(define (entry-result entry root reads defined)
  (let ((path (car entry)))
    (cond
      ((eq? (cdr entry) 'directory-link)
       (cons (list (string-append path ": it is a symbolic link to a directory,"
                                  " which this check does not follow"))
             0))
      ((not (suffix? path ".sls"))
       (cons (list (string-append path ": it is not a .sls file, and only .sls libraries belong under "
                                  root))
             0))
      (else
       (let ((found (cdr (assoc path reads)))
             (header (header-complaints path root)))
         (if (eq? (car found) 'data)
             (cons (append header (data-complaints path root (cadr found) defined))
                   (length (filter library-form? (cadr found))))
             (cons (append header
                           (list (string-append path ": it cannot be read as data: " (cadr found))))
                   0)))))))

;; main : (Listof String) -> Unit
(define (main args)
  (cond
    ((not (= (length args) 1))
     (say (current-error-port) "usage: scheme --program tests/check-imports.sps DIR")
     (exit 1))
    ((not (file-directory? (car args)))
     (say (current-error-port) (string-append (car args) ": not a directory"))
     (exit 1))
    (else
     (let* ((root (without-slashes (car args)))
            (entries (list-sort (lambda (a b) (string<? (car a) (car b))) (walk root)))
            (reads (map (lambda (entry) (cons (car entry) (read-data (car entry))))
                        (filter (lambda (entry)
                                  (and (eq? (cdr entry) 'file) (suffix? (car entry) ".sls")))
                                entries)))
            (defined (defined-libraries reads))
            (results (map (lambda (entry) (entry-result entry root reads defined)) entries))
            (checked (apply + (map cdr results)))
            (complaints (append (apply append (map car results))
                                (if (= checked 0)
                                    (list (string-append "no library under " root))
                                    '()))))
       (cond
         ((null? complaints)
          (say (current-output-port)
               (string-append "ok, libraries checked: " (number->string checked)))
          (exit 0))
         (else
          (for-each (lambda (c) (say (current-error-port) c)) complaints)
          (exit 1)))))))

(main (cdr (command-line)))
