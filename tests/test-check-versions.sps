#!r6rs
;;; The suite for tests/check-versions.sps, the program behind
;;; `make check-versions`. Each tree under tests/fixtures/versions/<case>/
;;; holds the three files the program reads, with one fault, or none, and
;;; this suite runs the program on each in a fresh Chez, through
;;; capture-command. A case asserts the exit status and the whole of stdout
;;; and stderr, as text written by hand here, never read back from the
;;; program.
;;;
;;; The passing tree, lookalikes, holds 1.12.3, which no default holds, and
;;; names that begin with byte-machine's before byte-machine's own, so a
;;; program that knew 0.8.0, or matched a prefix, fails here. Each fault tree
;;; is lookalikes with one change, but the four that differ in version only,
;;; which are copies of the repository's own three files.
;;;
;;; make test runs it from the repository root with CHEZ exported. To run it
;;; against another copy of the program, name it after the suite:
;;;
;;;   $CHEZ --libdirs ... --program tests/test-check-versions.sps build/copy.sps
(import (rnrs)
        (srfi :64)
        (jsonparse-testing)
        (only (chezscheme) getenv library-directories directory-list file-directory?
              current-directory))

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
  (if (null? (cdr (command-line))) "tests/check-versions.sps" (cadr (command-line))))

(define fixtures "tests/fixtures/versions")

;; absolute : String -> String
;; PATH, made absolute from this suite's current directory.
(define (absolute path)
  (if (and (> (string-length path) 0) (char=? (string-ref path 0) #\/))
      path
      (string-append (current-directory) "/" path)))

;; libdirs : String
;; The library path this suite was started with, as --libdirs takes it,
;; each directory absolute, so that a program started elsewhere finds them.
(define libdirs
  (let ((dirs (map (lambda (d) (absolute (if (pair? d) (car d) d))) (library-directories))))
    (if (null? dirs)
        ""
        (fold-left (lambda (text d) (string-append text ":" d)) (car dirs) (cdr dirs)))))

;; run : (Listof String) -> (List Integer String String)
;; The program in a fresh Chez with ARGS: its exit status, stdout and stderr.
(define (run args)
  (capture-command (append (list chez "--libdirs" libdirs "--program" program) args)))

;; run-in : String -> (List Integer String String)
;; The program in a fresh Chez started in the directory DIR, with no
;; argument.
(define (run-in dir)
  (capture-command (list "sh" "-c" "cd \"$1\" && exec \"$2\" --libdirs \"$3\" --program \"$4\""
                         "sh" dir chez libdirs (absolute program))))

;; root : String -> String
(define (root case) (string-append fixtures "/" case))

;; The three files, below a root.
(define manifest "Akku.manifest")
(define lock "Akku.lock")
(define vendored "vendor/byte-machine/Akku.manifest")

;; in : String String -> String
;; The path the program names for FILE in the tree CASE.
(define (in case file) (string-append (root case) "/" file))

;; lines : String ... -> String
;; Each line prefixed with the program's name, and ended.
(define (lines . texts)
  (apply string-append
         (map (lambda (t) (string-append "check-versions: " t "\n")) texts)))

;; passed : String ... -> (List 0 String "")
(define (passed . texts) (list 0 (apply lines texts) ""))

;; refused : String ... -> (List 1 "" String)
(define (refused . texts) (list 1 "" (apply lines texts)))

;; What each file's line says, at PREFIX (a tree's root and a slash, or "").
(define (floor-line prefix v) (string-append prefix manifest ": byte-machine's floor is " v))
(define (lock-line prefix v) (string-append prefix lock ": byte-machine is locked at " v))
(define (vendored-line prefix v) (string-append prefix vendored ": byte-machine is " v))

;; The verdicts.
(define (agree v) (string-append "ok, byte-machine is " v " in all three"))
(define differ "the three versions differ, but they move together (ADR-0002)")
(define unread "not every version could be read, so they cannot be compared (ADR-0002)")

;; at : String -> String
;; A tree's root and a slash, the prefix of the paths the program names.
(define (at case) (string-append (root case) "/"))

;; good : String -> (List String String String)
;; The three lines of the tree CASE when each reads as lookalikes' 1.12.3.
(define (good case)
  (list (floor-line (at case) "1.12.3") (lock-line (at case) "1.12.3")
        (vendored-line (at case) "1.12.3")))

;; with : (List String String String) Natural String -> (List String String String)
;; LINES with the one at INDEX replaced by LINE.
(define (with lines index line)
  (let loop ((ls lines) (i 0))
    (cond ((null? ls) '())
          ((= i index) (cons line (cdr ls)))
          (else (cons (car ls) (loop (cdr ls) (+ i 1)))))))

;; problem : String String String -> String
(define (problem case file text) (string-append (in case file) ": " text))

;; refused-with : String Natural String String -> (List 1 "" String)
;; lookalikes' lines in the tree CASE, but the file at INDEX says TEXT, and
;; the verdict is that a version could not be read. FILE is that file.
(define (refused-with case index file text)
  (apply refused (append (with (good case) index (problem case file text)) (list unread))))

(define range-tail ", not (\"byte-machine\" \"^X.Y.Z\")")

;; cases : (Listof (List String String Expected))
(define cases
  (list
   (list "lookalikes"
         "the three agree at 1.12.3; a dependency and a project whose names begin with byte-machine's come before byte-machine's own, and depends/dev names another floor"
         (apply passed (append (good "lookalikes") (list (agree "1.12.3")))))

   ;; --- the versions differ ---
   (list "floor-differs"
         "the repository's three files, but the floor is ^0.9.0"
         (refused (floor-line (at "floor-differs") "0.9.0")
                  (lock-line (at "floor-differs") "0.8.0")
                  (vendored-line (at "floor-differs") "0.8.0")
                  differ))
   (list "lock-differs"
         "the repository's three files, but the lock is at 0.9.0"
         (refused (floor-line (at "lock-differs") "0.8.0")
                  (lock-line (at "lock-differs") "0.9.0")
                  (vendored-line (at "lock-differs") "0.8.0")
                  differ))
   (list "vendor-differs"
         "the repository's three files, but the vendored package is 0.9.0"
         (refused (floor-line (at "vendor-differs") "0.8.0")
                  (lock-line (at "vendor-differs") "0.8.0")
                  (vendored-line (at "vendor-differs") "0.9.0")
                  differ))
   (list "all-differ"
         "the repository's three files, at 1.0.0, 2.0.0 and 3.0.0"
         (refused (floor-line (at "all-differ") "1.0.0")
                  (lock-line (at "all-differ") "2.0.0")
                  (vendored-line (at "all-differ") "3.0.0")
                  differ))

   ;; --- Akku.manifest's floor ---
   (list "floor-not-caret"
         "the floor's range is >=1.12.3, not ^X.Y.Z"
         (refused-with "floor-not-caret" 0 manifest
                       (string-append "its depends entry for byte-machine is (\"byte-machine\" \">=1.12.3\")" range-tail)))
   (list "floor-short"
         "the floor's range is ^1.12, with no patch number"
         (refused-with "floor-short" 0 manifest
                       (string-append "its depends entry for byte-machine is (\"byte-machine\" \"^1.12\")" range-tail)))
   (list "floor-dev-only"
         "byte-machine is named in depends/dev alone, which is no floor"
         (refused-with "floor-dev-only" 0 manifest
                       "its depends clauses name byte-machine 0 times, but a floor needs exactly one"))
   (list "floor-twice"
         "byte-machine is named twice in depends"
         (refused-with "floor-twice" 0 manifest
                       "its depends clauses name byte-machine 2 times, but a floor needs exactly one"))
   (list "two-packages"
         "Akku.manifest holds two akku-package forms"
         (refused-with "two-packages" 0 manifest
                       "it holds 2 akku-package forms, but a manifest holds exactly one"))

   ;; --- Akku.lock ---
   (list "lock-git"
         "the lock takes byte-machine from git, not from an archive"
         (refused-with "lock-git" 1 lock
                       "byte-machine's location is (location (git \"https://github.com/Kiyomi-Computation-Systems/byte-machine.git\")), not (location (url \".../byte-machine_X.Y.Z_repack.tar.xz\"))"))
   (list "lock-url-shape"
         "the lock's archive ends in _repack.tar.gz, not _repack.tar.xz; its name and version are right"
         (refused-with "lock-url-shape" 1 lock
                       "byte-machine's archive URL is \"https://archive.akkuscm.org/archive/pkg/b/byte-machine_1.12.3_repack.tar.gz\", which does not end in /byte-machine_X.Y.Z_repack.tar.xz"))
   (list "lock-url-name"
         "the lock's archive is byte-mashine_1.12.3_repack.tar.xz, a name as long as byte-machine's; its version and ending are right"
         (refused-with "lock-url-name" 1 lock
                       "byte-machine's archive URL is \"https://archive.akkuscm.org/archive/pkg/b/byte-mashine_1.12.3_repack.tar.xz\", which does not end in /byte-machine_X.Y.Z_repack.tar.xz"))
   (list "lock-url-overlap"
         "the lock's archive is byte-machine_repack.tar.xz, whose name and ending overlap, with no version between them"
         (refused-with "lock-url-overlap" 1 lock
                       "byte-machine's archive URL is \"https://archive.akkuscm.org/archive/pkg/b/byte-machine_repack.tar.xz\", which does not end in /byte-machine_X.Y.Z_repack.tar.xz"))
   (list "lock-twice"
         "the lock names two projects byte-machine"
         (refused-with "lock-twice" 1 lock
                       "it locks byte-machine 2 times, but exactly once is wanted"))
   (list "lock-missing"
         "the lock holds byte-machin, and so no byte-machine"
         (refused-with "lock-missing" 1 lock
                       "it locks byte-machine 0 times, but exactly once is wanted"))
   (list "two-projects"
         "the lock holds two projects forms"
         (refused-with "two-projects" 1 lock
                       "it holds 2 projects forms, but a lock holds exactly one"))
   (list "unreadable"
         "the lock cannot be read as data"
         (refused-with "unreadable" 1 lock
                       (string-append "it cannot be read as data: Exception in read: unexpected end-of-file reading list before file-position 73 of #<input port "
                                      (in "unreadable" lock) ">; the character position might differ")))

   ;; --- the vendored manifest ---
   (list "vendor-name"
         "the vendored package is byte-machines"
         (refused-with "vendor-name" 2 vendored
                       "its package is \"byte-machines\", not \"byte-machine\""))
   (list "vendor-version-shape"
         "the vendored version is 1.12.3-rc1, not X.Y.Z"
         (refused-with "vendor-version-shape" 2 vendored
                       "byte-machine's version is \"1.12.3-rc1\", not X.Y.Z"))
   (list "vendor-version-empty"
         "the vendored version is 1.12., whose third part is empty"
         (refused-with "vendor-version-empty" 2 vendored
                       "byte-machine's version is \"1.12.\", not X.Y.Z"))
   (list "vendor-shape"
         "the vendored akku-package form does not begin with (NAME VERSION)"
         (refused-with "vendor-shape" 2 vendored
                       "its akku-package form does not begin with (NAME VERSION)"))
   (list "vendor-missing"
         "there is no vendor/byte-machine, as when the submodule was never fetched"
         (refused-with "vendor-missing" 2 vendored
                       (string-append "it cannot be read as data: Exception in open-file-input-port: failed for "
                                      (in "vendor-missing" vendored) ": no such file or directory")))))

(test-begin "check-versions")

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

(test-equal "with no argument, the current directory is the root, and each file is named as it is"
  (passed (floor-line "" "1.12.3") (lock-line "" "1.12.3") (vendored-line "" "1.12.3")
          (agree "1.12.3"))
  (run-in (root "lookalikes")))

(test-equal "a slash after the root changes nothing: no doubled slash in a path it names"
  (caddr (assoc "floor-differs" cases))
  (run (list (string-append (root "floor-differs") "//"))))

(test-equal "a root that does not exist: each file is named, unread"
  (let ((r "tests/fixtures/versions/no-such-root"))
    (refused (string-append r "/" manifest ": it cannot be read as data: Exception in open-file-input-port: failed for "
                            r "/" manifest ": no such file or directory")
             (string-append r "/" lock ": it cannot be read as data: Exception in open-file-input-port: failed for "
                            r "/" lock ": no such file or directory")
             (string-append r "/" vendored ": it cannot be read as data: Exception in open-file-input-port: failed for "
                            r "/" vendored ": no such file or directory")
             unread))
  (run '("tests/fixtures/versions/no-such-root")))

(test-equal "two roots named: the usage line, exit 1"
  (list 1 "" "check-versions: usage: scheme --program tests/check-versions.sps [ROOT]\n")
  (run '("a" "b")))

(test-end "check-versions")

(exit (suite-exit-status runner))
