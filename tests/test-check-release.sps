#!r6rs
;;; The suite for tests/check-release.sps, the program behind
;;; `make check-release`. Each tree under tests/fixtures/release/<case>/
;;; holds the three files the program reads, with one fault, or none, and
;;; this suite runs the program on each in a fresh Chez, through
;;; capture-command. A case asserts the exit status and the whole of stdout
;;; and stderr, as text written by hand here, never read back from the
;;; program.
;;;
;;; The passing tree, lookalikes, holds 3.14.15, which no default holds, and
;;; a lookalike of each thing the program reads before the thing itself: a
;;; comment naming another version above the manifest's package form, an
;;; Unreleased heading above the newest release, and a "## Status report"
;;; section above the Status. Each fault tree is lookalikes with one change.
;;;
;;; make test runs it from the repository root with CHEZ exported. To run it
;;; against another copy of the program, name it after the suite:
;;;
;;;   $CHEZ --libdirs ... --program tests/test-check-release.sps build/copy.sps
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
  (if (null? (cdr (command-line))) "tests/check-release.sps" (cadr (command-line))))

(define fixtures "tests/fixtures/release")

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
(define changelog "CHANGELOG.md")
(define home "docs/README.md")

;; lines : String ... -> String
;; Each line prefixed with the program's name, and ended.
(define (lines . texts)
  (apply string-append
         (map (lambda (t) (string-append "check-release: " t "\n")) texts)))

;; passed : String ... -> (List 0 String "")
(define (passed . texts) (list 0 (apply lines texts) ""))

;; refused : String ... -> (List 1 "" String)
(define (refused . texts) (list 1 "" (apply lines texts)))

;; at : String -> String
;; A tree's root and a slash, the prefix of the paths the program names.
(define (at case) (string-append (root case) "/"))

;; read-line : String String String -> String
;; The line for FILE, at PREFIX, when it reads the version V.
(define (read-line prefix file v) (string-append prefix file ": jsonparse is " v))

;; The verdicts.
(define (agree v) (string-append "ok, jsonparse is " v " in all three"))
(define differ "the three versions differ, but a release names one (ADR-0022)")
(define unread "not every version could be read, so they cannot be compared (ADR-0022)")

;; good : String -> (List String String String)
;; The three lines of the tree CASE when each reads as lookalikes' 3.14.15.
(define (good case)
  (list (read-line (at case) manifest "3.14.15")
        (read-line (at case) changelog "3.14.15")
        (read-line (at case) home "3.14.15")))

;; with : (List String String String) Natural String -> (List String String String)
;; LINES with the one at INDEX replaced by LINE.
(define (with lines index line)
  (let loop ((ls lines) (i 0))
    (cond ((null? ls) '())
          ((= i index) (cons line (cdr ls)))
          (else (cons (car ls) (loop (cdr ls) (+ i 1)))))))

;; refused-with : String Natural String String -> (List 1 "" String)
;; lookalikes' lines in the tree CASE, but the file at INDEX says TEXT, and
;; the verdict is that a version could not be read. FILE is that file.
(define (refused-with case index file text)
  (apply refused (append (with (good case) index (string-append (at case) file ": " text))
                         (list unread))))

;; differs-with : String Natural String String -> (List 1 "" String)
;; lookalikes' lines in the tree CASE, but the file at INDEX reads V, and the
;; verdict is that the versions differ. FILE is that file.
(define (differs-with case index file v)
  (apply refused (append (with (good case) index (read-line (at case) file v))
                         (list differ))))

;; cases : (Listof (List String String Expected))
(define cases
  (list
   (list "lookalikes"
         "the three agree at 3.14.15, each after a lookalike naming another version"
         (apply passed (append (good "lookalikes") (list (agree "3.14.15")))))

   ;; --- the versions differ ---
   (list "manifest-differs"
         "the manifest gives jsonparse 3.14.16"
         (differs-with "manifest-differs" 0 manifest "3.14.16"))
   (list "changelog-differs"
         "the changelog's newest release is 3.14.9: 3.14.15 has no entry"
         (differs-with "changelog-differs" 1 changelog "3.14.9"))
   (list "status-differs"
         "the home page's Status names v3.14.9"
         (differs-with "status-differs" 2 home "3.14.9"))

   ;; --- Status lines that do name the version ---
   (list "status-space"
         "the Status reads v3.14.15 is the latest release: the version ends at a space"
         (apply passed (append (good "status-space") (list (agree "3.14.15")))))
   (list "status-bare"
         "the Status line is v3.14.15 and nothing more: the version ends at the line's end"
         (apply passed (append (good "status-bare") (list (agree "3.14.15")))))

   ;; --- a version that cannot be read ---
   (list "manifest-version-shape"
         "the manifest gives jsonparse 3.14, not X.Y.Z"
         (refused-with "manifest-version-shape" 0 manifest
                       "its package version is not X.Y.Z: (akku-package (\"jsonparse\" \"3.14\")"))
   (list "manifest-version-letters"
         "the manifest gives jsonparse 3.14.x: a part that is not digits"
         (refused-with "manifest-version-letters" 0 manifest
                       "its package version is not X.Y.Z: (akku-package (\"jsonparse\" \"3.14.x\")"))
   (list "manifest-twice"
         "the manifest has two lines beginning (akku-package (\"jsonparse\", both 3.14.15"
         (refused-with "manifest-twice" 0 manifest
                       "it has 2 lines beginning (akku-package (\"jsonparse\" \", but a manifest has one"))
   (list "changelog-no-release"
         "the changelog has an Unreleased heading and no release"
         (refused-with "changelog-no-release" 1 changelog
                       "it has no release heading, \"## [X.Y.Z] - YYYY-MM-DD\""))
   (list "changelog-empty"
         "the changelog is an empty file"
         (refused-with "changelog-empty" 1 changelog
                       "it has no release heading, \"## [X.Y.Z] - YYYY-MM-DD\""))
   (list "changelog-no-date"
         "the newest release heading has no date"
         (refused-with "changelog-no-date" 1 changelog
                       "its newest release heading is not \"## [X.Y.Z] - YYYY-MM-DD\": ## [3.14.15]"))
   (list "changelog-date-tbd"
         "the newest release heading's date is TBD"
         (refused-with "changelog-date-tbd" 1 changelog
                       "its newest release heading is not \"## [X.Y.Z] - YYYY-MM-DD\": ## [3.14.15] - TBD"))
   (list "changelog-date-slashes"
         "the newest release heading's date is 2031/02/03, ten characters with slashes"
         (refused-with "changelog-date-slashes" 1 changelog
                       "its newest release heading is not \"## [X.Y.Z] - YYYY-MM-DD\": ## [3.14.15] - 2031/02/03"))
   (list "changelog-separator"
         "the newest release heading separates its date with \" : \", not \" - \""
         (refused-with "changelog-separator" 1 changelog
                       "its newest release heading is not \"## [X.Y.Z] - YYYY-MM-DD\": ## [3.14.15] : 2031-02-03"))
   (list "status-missing"
         "the home page has a Status report section but no Status"
         (refused-with "status-missing" 2 home
                       "it has no \"## Status\" section"))
   (list "status-no-version"
         "the home page's Status says Not released yet"
         (refused-with "status-no-version" 2 home
                       "its Status does not begin with the version, \"vX.Y.Z\""))))

(test-begin "check-release")

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
  (passed (read-line "" manifest "3.14.15") (read-line "" changelog "3.14.15")
          (read-line "" home "3.14.15") (agree "3.14.15"))
  (run-in (root "lookalikes")))

(test-equal "a slash after the root changes nothing: no doubled slash in a path it names"
  (caddr (assoc "manifest-differs" cases))
  (run (list (string-append (root "manifest-differs") "//"))))

(test-equal "a root that does not exist: each file is named, missing"
  (let ((r "tests/fixtures/release/no-such-root/"))
    (refused (string-append r manifest ": it is missing")
             (string-append r changelog ": it is missing")
             (string-append r home ": it is missing")
             unread))
  (run '("tests/fixtures/release/no-such-root")))

(test-equal "two roots named: the usage line, exit 1"
  (list 1 "" "check-release: usage: scheme --program tests/check-release.sps [ROOT]\n")
  (run '("a" "b")))

(test-end "check-release")

(exit (suite-exit-status runner))
