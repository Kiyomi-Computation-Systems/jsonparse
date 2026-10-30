#!r6rs
;;; The suite for tests/check-imports.sps, the program behind
;;; `make check-imports`. Every rule it holds has a fixture tree under
;;; tests/fixtures/imports/<case>/, and this suite runs the program on each,
;;; in a fresh Chez, through capture-command. A case asserts the exit status,
;;; the whole of stdout and the whole of stderr, as text written by hand
;;; here, never read back from the program: a substring would pass whenever
;;; another rule produced the same words. Without this suite, deleting a rule
;;; would leave `make test` green: the real tree under src/ breaks none of
;;; them.
;;;
;;; Each case's tree is the one fault it names, in an otherwise legal
;;; setting, so that only that rule can make it fail. The cases that must
;;; pass say so with the program's own pass line, count included. The fixture
;;; trees are never suites: make test runs tests/test-*.sps only.
;;;
;;; make test runs every suite from the repository root, where tests/ is, with
;;; CHEZ exported. Without CHEZ nothing below can run: that fails here, by
;;; name, and never skips. The program runs with this suite's own library
;;; path. To run the suite against another copy of the program, name it after
;;; the suite:
;;;
;;;   $CHEZ --libdirs ... --program tests/test-check-imports.sps build/copy.sps
(import (rnrs)
        (srfi :64)
        (jsonparse-testing)
        (only (chezscheme) getenv library-directories library-list
              file-directory? directory-list))

;; SRFI-64 sets no exit status. This suite's last line turns the runner's
;; counts into one.
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

(define chez (getenv "CHEZ"))

(define program
  (if (null? (cdr (command-line))) "tests/check-imports.sps" (cadr (command-line))))

(define fixtures "tests/fixtures/imports")

;; libdirs : String
;; The library path this suite was started with, as --libdirs takes it.
(define libdirs
  (let ((dirs (map (lambda (d) (if (pair? d) (car d) d)) (library-directories))))
    (if (null? dirs)
        ""
        (fold-left (lambda (text d) (string-append text ":" d)) (car dirs) (cdr dirs)))))

;; run : (Listof String) -> (List Integer String String)
;; The program in a fresh Chez with ARGS: its exit status, stdout and stderr.
(define (run args)
  (capture-command (append (list chez "--libdirs" libdirs "--program" program) args)))

;; root : String -> String
;; The tree of the fixture CASE, as the program is told it and names it.
(define (root case) (string-append fixtures "/" case))

;; at : String String -> String
;; The path the program names for FILE in the fixture tree CASE.
(define (at case file) (string-append (root case) "/" file))

;; ok : Natural -> (List 0 String "")
;; What a pass prints: how many libraries it checked.
(define (ok libraries)
  (list 0
        (string-append "check-imports: ok, libraries checked: " (number->string libraries) "\n")
        ""))

;; refused : String ... -> (List 1 "" String)
;; What a failure prints: PROBLEMS, one line each, and nothing on stdout.
(define (refused . problems)
  (list 1
        ""
        (apply string-append
               (map (lambda (p) (string-append "check-imports: " p "\n")) problems))))

;; The words the program ends an import's refusal with: the allowlist
;; (ADR-0003), and the one-way rule (ADR-0010).
(define allowed-tail
  "but a library may import only the (rnrs ...) libraries except (rnrs eval), (jsonparse ...) libraries, (generated jsonparse) and (byte-machine runtime)")

(define easy-tail
  "but no library may import (jsonparse easy): imports go one way, from the easy layer down (ADR-0010)")

(define composes-tail
  "but (jsonparse easy) may import only the (rnrs ...) libraries except (rnrs eval), and (jsonparse ...) libraries: it composes low-layer exports only (ADR-0010)")

;; imports : String String String String String -> String
;; The complaint about the library LIB, in FILE of the tree CASE, importing
;; IMPORTED, ended with TAIL.
(define (imports case file lib imported tail)
  (string-append (at case file) ": " lib " imports " imported ", " tail))

;; unreadable-spec : String String String String -> String
(define (unreadable-spec case file lib spec)
  (string-append (at case file) ": " lib " has an import it cannot read: " spec))

;; misplaced : String String String String -> String
;; The library LIB, defined in FILE of the tree CASE, belongs at WANT.
(define (misplaced case file lib want)
  (string-append (at case file) ": " lib " is defined here, but its name's path is "
                 (at case want)))

;; not-ours : String String String -> String
(define (not-ours case file lib)
  (string-append (at case file) ": " lib
                 " is neither a (jsonparse ...) library nor (generated jsonparse): every library under "
                 (root case) " is one of them"))

;; not-sls : String String -> String
(define (not-sls case file)
  (string-append (at case file) ": it is not a .sls file, and only .sls libraries belong under "
                 (root case)))

;; undefined : String String String String -> String
(define (undefined case file lib imported)
  (string-append (at case file) ": " lib " imports " imported ", but no library under "
                 (root case) " defines it"))

;; no-header : String String -> String
;; The file at PATH, under ROOT, does not begin with the line #!r6rs.
(define (no-header path root)
  (string-append path ": its first line is not #!r6rs, which every .sls file under " root
                 " begins with, so that Chez reads it as R6RS and not with its own syntax"))

;; stray-directive : String String -> String
;; The file at PATH holds #! on LINES, past the #!r6rs it begins with, or
;; where it has none.
(define (stray-directive path lines)
  (string-append path ": it holds #! on " lines
                 ", and only the #!r6rs it begins with may: a #! may switch Chez's reader to its own syntax, and this check, which cannot tell a directive from text, refuses one in a comment or a string too"))

;; cases : (Listof (List String String Expected))
;; The fixture directory, what it holds, and the program's whole answer for it.
(define cases
  (list
   (list "clean"
         "a legal tree: the generated parser, a low-layer library and the easy layer; every wrapper over an allowed import, nested; version references on imports and on a library's name; (byte-machine runtime) bare, wrapped and versioned; a comment and a string that name (chezscheme) and (jsonparse easy); every file headed #!r6rs"
         (ok 4))
   (list "rnrs-libraries"
         "every (rnrs ...) library but (rnrs eval), imported by one library"
         (ok 1))

   ;; --- rule (a): files, names and places ---
   (list "misnamed"
         "rule (a): a library that is not at its name's path, in a subdirectory, in a file named for another, in one named for a prefix of it, and (generated jsonparse) under jsonparse/; the library at its own path is not named"
         (refused (misplaced "misnamed" "jsonparse/deep/x.sls" "(jsonparse x)" "jsonparse/x.sls")
                  (misplaced "misnamed" "jsonparse/foo.sls" "(jsonparse bar)" "jsonparse/bar.sls")
                  (misplaced "misnamed" "jsonparse/generated.sls" "(generated jsonparse)"
                             "generated/jsonparse.sls")
                  (misplaced "misnamed" "jsonparse/other.sls" "(jsonparse other extra)"
                             "jsonparse/other/extra.sls")))
   (list "case-mismatch"
         "rule (a): a library's path matches its name letter for letter: (jsonparse tree) in jsonparse/Tree.sls is at the wrong path"
         (refused (misplaced "case-mismatch" "jsonparse/Tree.sls" "(jsonparse tree)"
                             "jsonparse/tree.sls")))
   (list "chez-extension"
         "rule (a): Chez prefers tree.chezscheme.sls to tree.sls for (jsonparse tree), so a library in it is at the wrong path"
         (refused (misplaced "chez-extension" "jsonparse/tree.chezscheme.sls" "(jsonparse tree)"
                             "jsonparse/tree.sls")))
   (list "non-sls"
         "rule (a): files that are not .sls: a hidden one, one with no extension, .scm, .txt, .ss, .sls.bak and .SLS; each is named and none is read, so a library one of them holds is undefined"
         (refused (undefined "non-sls" "jsonparse.sls" "(jsonparse)" "(jsonparse old)")
                  (not-sls "non-sls" "jsonparse/.hidden")
                  (not-sls "non-sls" "jsonparse/README")
                  (not-sls "non-sls" "jsonparse/helper.scm")
                  (not-sls "non-sls" "jsonparse/notes.txt")
                  (not-sls "non-sls" "jsonparse/old.ss")
                  (not-sls "non-sls" "jsonparse/shout.SLS")
                  (not-sls "non-sls" "jsonparse/tree.sls.bak")))
   (list "two-libraries"
         "rule (a): a file that holds two libraries, which names the count and the second, off its name's path"
         (refused (string-append (at "two-libraries" "jsonparse/two.sls")
                                 ": it holds 2 libraries, but a file holds exactly one")
                  (misplaced "two-libraries" "jsonparse/two.sls" "(jsonparse three)"
                             "jsonparse/three.sls")))
   (list "not-a-library"
         "rule (a): a datum that is no library form, the first or a later one, one cut short, one with its export and import clauses in the wrong order, one whose name is an improper list, and one with an export clause and no import clause"
         (refused (string-append (at "not-a-library" "jsonparse/d1.sls")
                                 ": datum 1 is (define x 1), not a library form")
                  (string-append (at "not-a-library" "jsonparse/d2.sls")
                                 ": datum 2 is (define y 2), not a library form")
                  (string-append (at "not-a-library" "jsonparse/d3.sls")
                                 ": datum 1 is (define abcdefghijklmnopqrstuvwxyz abcdefghijklmnopqrstuv..., not a library form")
                  (string-append (at "not-a-library" "jsonparse/d4.sls")
                                 ": datum 1 is (library (jsonparse d4)), not a library form")
                  (string-append (at "not-a-library" "jsonparse/d5.sls")
                                 ": datum 1 is (library (jsonparse d5) (import (rnrs)) (export)), not a library form")
                  (string-append (at "not-a-library" "jsonparse/d6.sls")
                                 ": datum 1 is (library (jsonparse . d6) (export) (import (rnrs))), not a library form")
                  (string-append (at "not-a-library" "jsonparse/d7.sls")
                                 ": datum 1 is (library (jsonparse d7) (export)), not a library form")))
   (list "dir-symlink"
         "rule (a): a symbolic link to a directory, which the program names and does not follow"
         (refused (string-append (at "dir-symlink" "linked")
                                 ": it is a symbolic link to a directory, which this check does not follow")))

   ;; --- rule (b): whose libraries ---
   (list "not-jsonparse"
         "rule (b): libraries at their own paths that are neither (jsonparse ...) nor (generated jsonparse): a private copy of (byte-machine runtime), (generated), (generated jsonparse extra), (generated other), (jsonparse-extra) and (util)"
         (refused (not-ours "not-jsonparse" "byte-machine/runtime.sls" "(byte-machine runtime)")
                  (not-ours "not-jsonparse" "generated.sls" "(generated)")
                  (not-ours "not-jsonparse" "generated/jsonparse/extra.sls" "(generated jsonparse extra)")
                  (not-ours "not-jsonparse" "generated/other.sls" "(generated other)")
                  (not-ours "not-jsonparse" "jsonparse-extra.sls" "(jsonparse-extra)")
                  (not-ours "not-jsonparse" "util.sls" "(util)")))

   ;; --- rule (c): the #!r6rs line ---
   (list "header-missing"
         "rule (c): a library with no #!r6rs line, otherwise legal"
         (refused (no-header (at "header-missing" "jsonparse.sls") (root "header-missing"))))
   (list "header-chezscheme"
         "rule (c): a library headed #!chezscheme, reading a repeat vector and an fxvector literal and importing only (rnrs)"
         (refused (no-header (at "header-chezscheme" "jsonparse.sls") (root "header-chezscheme"))))
   (list "header-later"
         "rule (c): the #!r6rs line, and #!chezscheme on a later line, turning Chez's syntax back on"
         (refused (stray-directive (at "header-later" "jsonparse.sls") "line 3")))
   (list "header-in-text"
         "rule (c): #! in a line comment, a block comment and a string, each refused by its line; one file holding it on three lines, twice on one"
         (refused (stray-directive (at "header-in-text" "jsonparse/block.sls") "line 3")
                  (stray-directive (at "header-in-text" "jsonparse/comment.sls") "line 2")
                  (stray-directive (at "header-in-text" "jsonparse/several.sls") "lines 2, 6 and 7")
                  (stray-directive (at "header-in-text" "jsonparse/string.sls") "line 5")))
   (list "header-not-first"
         "rule (c): the #!r6rs line after a comment line: the file does not begin with it, and its #! is on line 2"
         (refused (no-header (at "header-not-first" "jsonparse.sls") (root "header-not-first"))
                  (stray-directive (at "header-not-first" "jsonparse.sls") "line 2")))
   (list "header-variants"
         "rule (c): #!r6rs with the library on the same line is not the line #!r6rs"
         (refused (no-header (at "header-variants" "jsonparse/same-line.sls") (root "header-variants"))))

   ;; --- rule (d): what a library may import ---
   (list "unlisted"
         "rule (d): (chezscheme), third-party and test libraries, near-family names, an (rnrs ...) name R6RS lacks, (rnrs eval), byte-machine's other libraries, and (generated ...) names but (generated jsonparse)"
         (apply refused
                (map (lambda (imported)
                       (imports "unlisted" "jsonparse/tree.sls" "(jsonparse tree)" imported allowed-tail))
                     '("(chezscheme)" "(srfi :1)" "(scheme)" "($system)" "(chezscheme csv7)"
                       "(jsonparse-testing)" "(jsonparse-extras)" "(rnrs foo)" "(rnrs eval)"
                       "(srfi :64)" "(byte-machine graph)" "(byte-machine compile)" "(byte-machine)"
                       "(byte-machine runtime extra)" "(generated)" "(generated other)"
                       "(generated jsonparse extra)"))))
   (list "undefined"
         "rule (d): a (jsonparse ...) library, (jsonparse) itself, and (generated jsonparse), imported when no library under the tree defines them; the one the tree defines is not named"
         (refused (undefined "undefined" "jsonparse/parser.sls" "(jsonparse parser)" "(jsonparse)")
                  (undefined "undefined" "jsonparse/parser.sls" "(jsonparse parser)" "(jsonparse nope-too)")
                  (undefined "undefined" "jsonparse/tree.sls" "(jsonparse tree)" "(jsonparse nope)")
                  (undefined "undefined" "jsonparse/tree.sls" "(jsonparse tree)" "(generated jsonparse)")))

   ;; --- rule (e): nothing imports (jsonparse easy) ---
   (list "imports-easy"
         "rule (e): (jsonparse easy), which the tree defines, imported by the generated parser through library, by a low-layer library bare, by another through only and through for around prefix with a version reference, and by itself"
         (refused (imports "imports-easy" "generated/jsonparse.sls" "(generated jsonparse)"
                           "(jsonparse easy)" easy-tail)
                  (imports "imports-easy" "jsonparse/easy.sls" "(jsonparse easy)"
                           "(jsonparse easy)" easy-tail)
                  (imports "imports-easy" "jsonparse/parser.sls" "(jsonparse parser)"
                           "(jsonparse easy)" easy-tail)
                  (imports "imports-easy" "jsonparse/parser.sls" "(jsonparse parser)"
                           "(jsonparse easy)" easy-tail)
                  (imports "imports-easy" "jsonparse/tree.sls" "(jsonparse tree)"
                           "(jsonparse easy)" easy-tail)))

   (list "easy-composes"
         "rule (e): (jsonparse easy) imports (byte-machine runtime) bare and through only with a version reference, (generated jsonparse) through prefix, and (chezscheme), each named; its (rnrs ...) and (jsonparse ...) imports are not, and a low-layer library beside it imports the runtime and the generated parser freely"
         (refused (imports "easy-composes" "jsonparse/easy.sls" "(jsonparse easy)"
                           "(byte-machine runtime)" composes-tail)
                  (imports "easy-composes" "jsonparse/easy.sls" "(jsonparse easy)"
                           "(generated jsonparse)" composes-tail)
                  (imports "easy-composes" "jsonparse/easy.sls" "(jsonparse easy)"
                           "(byte-machine runtime)" composes-tail)
                  (imports "easy-composes" "jsonparse/easy.sls" "(jsonparse easy)"
                           "(chezscheme)" composes-tail)))

   ;; --- rule (f): import specs ---
   (list "wrapped"
         "rule (f): (chezscheme) imported through only, except, prefix, rename, for, library and for with a meta level; (srfi :1) and (jsonparse easy) through only"
         (refused (imports "wrapped" "jsonparse/w1.sls" "(jsonparse w1)" "(chezscheme)" allowed-tail)
                  (imports "wrapped" "jsonparse/w2.sls" "(jsonparse w2)" "(chezscheme)" allowed-tail)
                  (imports "wrapped" "jsonparse/w3.sls" "(jsonparse w3)" "(chezscheme)" allowed-tail)
                  (imports "wrapped" "jsonparse/w4.sls" "(jsonparse w4)" "(chezscheme)" allowed-tail)
                  (imports "wrapped" "jsonparse/w5.sls" "(jsonparse w5)" "(chezscheme)" allowed-tail)
                  (imports "wrapped" "jsonparse/w6.sls" "(jsonparse w6)" "(chezscheme)" allowed-tail)
                  (imports "wrapped" "jsonparse/w7.sls" "(jsonparse w7)" "(chezscheme)" allowed-tail)
                  (imports "wrapped" "jsonparse/w8.sls" "(jsonparse w8)" "(srfi :1)" allowed-tail)
                  (imports "wrapped" "jsonparse/w9.sls" "(jsonparse w9)" "(jsonparse easy)" easy-tail)))
   (list "wrapped-nested"
         "rule (f): wrappers nested to any depth: five kinds deep around (chezscheme), prefix and only around (jsonparse easy), forty onlys around (srfi :1); a legal nested import beside them is not named"
         (refused (imports "wrapped-nested" "jsonparse/n1.sls" "(jsonparse n1)" "(chezscheme)" allowed-tail)
                  (imports "wrapped-nested" "jsonparse/n2.sls" "(jsonparse n2)" "(jsonparse easy)" easy-tail)
                  (imports "wrapped-nested" "jsonparse/n3.sls" "(jsonparse n3)" "(srfi :1)" allowed-tail)))
   (list "versions-banned"
         "rule (f): a version reference does not hide the library: (chezscheme (9)), (srfi :1 (1 0)), (byte-machine graph (>= 0 8)), (jsonparse easy (1)) and (rnrs eval (6))"
         (refused (imports "versions-banned" "jsonparse.sls" "(jsonparse)" "(chezscheme)" allowed-tail)
                  (imports "versions-banned" "jsonparse.sls" "(jsonparse)" "(srfi :1)" allowed-tail)
                  (imports "versions-banned" "jsonparse.sls" "(jsonparse)" "(byte-machine graph)" allowed-tail)
                  (imports "versions-banned" "jsonparse.sls" "(jsonparse)" "(jsonparse easy)" easy-tail)
                  (imports "versions-banned" "jsonparse.sls" "(jsonparse)" "(rnrs eval)" allowed-tail)))
   (list "cyclic"
         "rule (f): an import spec that contains itself, through only, for, rename and a tail, is named and the program ends. Chez refuses datum labels after #!r6rs, so the file has no header, and rule (c) names it first"
         (refused (no-header (at "cyclic" "jsonparse.sls") (root "cyclic"))
                  (unreadable-spec "cyclic" "jsonparse.sls" "(jsonparse)" "#0=(only #0# x)")
                  (unreadable-spec "cyclic" "jsonparse.sls" "(jsonparse)" "#0=(for #0# run)")
                  (unreadable-spec "cyclic" "jsonparse.sls" "(jsonparse)" "#0=(rename #0# (a b))")
                  (unreadable-spec "cyclic" "jsonparse.sls" "(jsonparse)" "#0=(only (rnrs) . #0#)")))
   (list "cannot-read-spec"
         "rule (f): specs that name no library: a number, a string, an empty list, a wrapper with nothing to wrap, library with no or two or a bare reference, a reference with a bad version or a bad shape"
         (apply refused
                (map (lambda (spec) (unreadable-spec "cannot-read-spec" "jsonparse.sls" "(jsonparse)" spec))
                     '("42" "()" "(only)" "(for)" "(library)" "(library x)" "(library (rnrs) extra)"
                       "(rnrs 5)" "(rnrs (6) base)" "\"str\"" "(rnrs . base)" "(library (rnrs . base))"
                       "((rnrs))" "(only 5)"))))

   ;; --- rule (g): it fails closed ---
   (list "no-datum"
         "rule (g): a file that holds comments and no datum"
         (refused (string-append (at "no-datum" "jsonparse/empty.sls")
                                 ": it holds no datum, so it holds no library")))
   (list "unreadable"
         "rule (g): a file that cannot be read as data"
         (refused (string-append (at "unreadable" "jsonparse/broken.sls")
                                 ": it cannot be read as data: Exception in read: unexpected end-of-file reading list before file-position 63 of #<input port "
                                 (at "unreadable" "jsonparse/broken.sls")
                                 ">; the character position might differ")))))

(test-begin "check-imports")

(test-equal "CHEZ names the Chez to spawn"
  'set
  (if (and chez (not (string=? chez ""))) 'set 'unset))

(unless (and chez (not (string=? chez "")))
  (exit 1))

(for-each
 (lambda (case)
   (test-equal (string-append (car case) ": " (cadr case))
     (caddr case)
     (run (list (root (car case))))))
 cases)

;; A fixture nothing runs guards nothing, and a case with no fixture runs on a
;; missing directory.
(test-equal "every fixture directory is a case above, and every case has its directory"
  (list-sort string<? (map car cases))
  (list-sort string<?
             (filter (lambda (name) (file-directory? (string-append fixtures "/" name)))
                     (directory-list fixtures))))

(test-equal "a slash after the directory changes nothing: no doubled slash in a path it names"
  (caddr (assoc "misnamed" cases))
  (run (list (string-append (root "misnamed") "/"))))

;; --- the cases no fixture tree can hold ----------------------------------------------

;; Git keeps no empty directory, and the program is told a path that need not
;; exist.
(test-equal "rule (g): an empty directory holds no library"
  'refused
  (call-with-temp-directory
   (lambda (dir)
     (let ((want (refused (string-append "no library under " dir)))
           (got (run (list dir))))
       (if (equal? got want) 'refused got)))))

(test-equal "rule (g): a directory that holds only files that are not .sls holds no library, and each is named"
  'refused
  (call-with-temp-directory
   (lambda (dir)
     (capture-command (list "touch" (string-append dir "/notes.txt")))
     (let ((want (refused (string-append dir "/notes.txt: it is not a .sls file, and only .sls libraries belong under " dir)
                          (string-append "no library under " dir)))
           (got (run (list dir))))
       (if (equal? got want) 'refused got)))))

(test-equal "rule (g): a directory that does not exist is named"
  'refused
  (call-with-temp-directory
   (lambda (dir)
     (let* ((missing (string-append dir "/no-such-directory"))
            (want (refused (string-append missing ": not a directory")))
            (got (run (list missing))))
       (if (equal? got want) 'refused got)))))

;; bytes-append : Bytevector ... -> Bytevector
(define (bytes-append . parts)
  (let-values (((out extract) (open-bytevector-output-port)))
    (for-each (lambda (part) (put-bytevector out part)) parts)
    (extract)))

;; Git may change a line's end or keep a trailing space as it likes, so
;; these headers are written at run time: a trailing space, a CRLF line end,
;; and a byte order mark before it. Chez reads all three.
(test-equal "rule (c): a header with a trailing space, a CR before its LF, or a byte order mark before it, is not the line #!r6rs"
  'refused
  (call-with-temp-directory
   (lambda (dir)
     (let ((write-file (lambda (name bytes)
                         (call-with-port (open-file-output-port (string-append dir "/jsonparse/" name))
                           (lambda (port) (put-bytevector port bytes)))))
           (library (lambda (name) (string->utf8 (string-append "(library (jsonparse " name
                                                                 ") (export) (import (rnrs)))\n")))))
       (capture-command (list "mkdir" (string-append dir "/jsonparse")))
       (write-file "a.sls" (bytes-append (string->utf8 "#!r6rs \n") (library "a")))
       (write-file "b.sls" (bytes-append (string->utf8 "#!r6rs\r\n") (library "b")))
       (write-file "c.sls" (bytes-append (u8-list->bytevector '(#xEF #xBB #xBF))
                                         (string->utf8 "#!r6rs\n") (library "c")))
       (let ((want (refused (no-header (string-append dir "/jsonparse/a.sls") dir)
                            (no-header (string-append dir "/jsonparse/b.sls") dir)
                            (no-header (string-append dir "/jsonparse/c.sls") dir)
                            (stray-directive (string-append dir "/jsonparse/c.sls") "line 1")))
             (got (run (list dir))))
         (if (equal? got want) 'refused got))))))

(test-equal "a file is no directory"
  (refused "tests/check-suites.sps: not a directory")
  (run '("tests/check-suites.sps")))

(define usage
  (list 1 "" "check-imports: usage: scheme --program tests/check-imports.sps DIR\n"))

(test-equal "no directory named: the usage line, exit 1" usage (run '()))

(test-equal "two directories named: the usage line, exit 1" usage (run '("a" "b")))

;; --- the lists the program holds are exact ---------------------------------------------
;; The program's lists are read from it as data, never from its output.

;; read-forms : String -> (Listof Any)
(define (read-forms path)
  (call-with-port (open-file-input-port path (file-options) (buffer-mode block)
                                        (make-transcoder (utf-8-codec)))
    (lambda (port)
      (let loop ((found '()))
        (let ((datum (read port)))
          (if (eof-object? datum) (reverse found) (loop (cons datum found))))))))

;; declared : Symbol -> Any
;; What the program's (define NAME '(...)) lists.
(define (declared name)
  (guard (e (#t (list 'unreadable (describe e))))
    (let ((form (find (lambda (form)
                        (and (pair? form) (eq? (car form) 'define)
                             (pair? (cdr form)) (eq? (cadr form) name)))
                      (read-forms program))))
      (if form (cadr (caddr form)) '(not-defined)))))

;; written : Any -> String
(define (written x) (call-with-string-output-port (lambda (p) (write x p))))

;; sorted-libraries : Any -> Any
;; NAMES, a list of library names, sorted as written; (unsortable NAMES) when
;; it is no list of lists. SRFI-64 does not catch a raise in an expected
;; expression, so neither side may raise.
(define (sorted-libraries names)
  (guard (e (#t (list 'unsortable names)))
    (list-sort (lambda (a b) (string<? (written a) (written b))) names)))

(test-equal "rnrs-libraries is the (rnrs ...) libraries this Chez has, but (rnrs eval)"
  (sorted-libraries
   (filter (lambda (name)
             (and (pair? name) (eq? (car name) 'rnrs) (not (equal? name '(rnrs eval)))))
           (library-list)))
  (sorted-libraries (declared 'rnrs-libraries)))

(test-end "check-imports")

(exit (suite-exit-status runner))
