#!r6rs
;;; The suite for tests/check-corpora.sps, the program behind
;;; `make check-corpora` (ADR-0012). Each tree under tests/fixtures/corpora/
;;; is a directory of corpora with one fault, or none, and this suite runs
;;; the program on it in a fresh Chez, through capture-command. A case asserts
;;; the exit status and the whole of stdout and stderr, as text written by
;;; hand here, never read back from the program.
;;;
;;; The passing tree, ok, holds two corpora with names that lookalike
;;; JSON_checker's (bypass1.json, pass.json, passes1.json, pass1.txt,
;;; xfail2.json) and a near miss of its marker, so a program that matched a
;;; substring of a name, or of the marker, fails here. Each fault tree holds
;;; one corpus c, good but for one fault.
;;;
;;; What git cannot hold, an empty directory, and what a checkout may turn
;;; into a copy, a symbolic link, are built at test time in a temporary
;;; directory.
;;;
;;; make test runs it from the repository root with CHEZ exported.
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

(define program "tests/check-corpora.sps")

(define fixtures "tests/fixtures/corpora")

;; absolute : String -> String
;; PATH, made absolute from this suite's current directory.
(define (absolute path)
  (if (and (> (string-length path) 0) (char=? (string-ref path 0) #\/))
      path
      (string-append (current-directory) "/" path)))

;; libdirs : String
;; The library path this suite was started with, as --libdirs takes it.
(define libdirs
  (let ((dirs (map (lambda (d) (absolute (if (pair? d) (car d) d))) (library-directories))))
    (if (null? dirs)
        ""
        (fold-left (lambda (text d) (string-append text ":" d)) (car dirs) (cdr dirs)))))

;; run : (Listof String) -> (List Integer String String)
;; The program in a fresh Chez with ARGS: its exit status, stdout and stderr.
(define (run args)
  (capture-command (append (list chez "--libdirs" libdirs "--program" program) args)))

;; root : String -> String
(define (root case) (string-append fixtures "/" case))

;; lines : String ... -> String
;; Each line prefixed with the program's name, and ended.
(define (lines . texts)
  (apply string-append
         (map (lambda (t) (string-append "check-corpora: " t "\n")) texts)))

;; refused : String ... -> (List 1 "" String)
(define (refused . texts) (list 1 "" (apply lines texts)))

;; at : String String -> String
;; The path the program names for FILE in the corpus c of the tree CASE.
(define (at case file) (string-append (root case) "/c/" file))

;; sourced : String String -> (List 1 "" String)
;; Refused with one line naming the tree CASE's c/SOURCE and TEXT.
(define (sourced case text) (refused (string-append (at case "SOURCE") ": " text)))

;; checker-name / checker-text : String -> String
(define (checker-name path)
  (string-append path ": is named like a JSON_checker file, pass<digits>.json or fail<digits>.json (ADR-0012)"))
(define (checker-text path)
  (string-append path ": holds the text \"JSON Test Pattern pass\", so it is a JSON_checker file (ADR-0012)"))

(define hex-tail ", not 40 lowercase hex digits")
(define not-https ", which does not start with https://")

;; cases : (Listof (List String String Expected))
(define cases
  (list
   (list "ok"
         "two good corpora, with lookalike file names and a near miss of the marker, pass"
         (list 0 (lines (string-append "ok, 2 corpora under " (root "ok"))) ""))

   ;; --- the entries ---
   (list "stray-file"
         "a file beside the corpus is not a directory"
         (refused (string-append (root "stray-file") "/README: is a file, not a directory")))

   ;; --- LICENSE ---
   (list "license-missing"
         "there is no LICENSE"
         (refused (string-append (at "license-missing" "LICENSE") ": is missing")))
   (list "license-empty"
         "LICENSE is empty"
         (refused (string-append (at "license-empty" "LICENSE") ": is empty")))
   (list "license-dir"
         "LICENSE is a directory"
         (refused (string-append (at "license-dir" "LICENSE") ": is not a regular file")))

   ;; --- SOURCE ---
   (list "source-missing"
         "there is no SOURCE"
         (refused (string-append (at "source-missing" "SOURCE") ": is missing")))
   (list "source-dir"
         "SOURCE is a directory"
         (refused (string-append (at "source-dir" "SOURCE") ": is not a regular file")))
   (list "key-missing"
         "SOURCE has no taken key"
         (sourced "key-missing" "key taken is missing"))
   (list "key-twice"
         "SOURCE gives name twice"
         (sourced "key-twice" "key name appears 2 times, but exactly once is wanted"))
   (list "value-empty"
         "SOURCE's fetched has no value"
         (sourced "value-empty" "key fetched has an empty value"))
   (list "commit-short"
         "commit is 16 hex digits"
         (sourced "commit-short" (string-append "commit is \"0123456789abcdef\"" hex-tail)))
   (list "commit-long"
         "commit is 41 hex digits"
         (sourced "commit-long" (string-append "commit is \"0123456789abcdef0123456789abcdef012345678\"" hex-tail)))
   (list "commit-upper"
         "commit is 40 hex digits, in capitals"
         (sourced "commit-upper" (string-append "commit is \"0123456789ABCDEF0123456789ABCDEF01234567\"" hex-tail)))
   (list "commit-nonhex"
         "commit is 40 characters, the last a g"
         (sourced "commit-nonhex" (string-append "commit is \"0123456789abcdef0123456789abcdef0123456g\"" hex-tail)))
   (list "url-http"
         "url is http://, not https://"
         (sourced "url-http" (string-append "url is \"http://example.org/widgets\"" not-https)))
   (list "url-bare"
         "url has no scheme"
         (sourced "url-bare" (string-append "url is \"example.org/widgets\"" not-https)))

   ;; --- JSON_checker ---
   (list "checker-pass"
         "data/pass1.json is named like a JSON_checker file; its content is innocent"
         (refused (checker-name (at "checker-pass" "data/pass1.json"))))
   (list "checker-fail"
         "data/deep/fail23.json, two directories down, is named like one"
         (refused (checker-name (at "checker-fail" "data/deep/fail23.json"))))
   (list "checker-content"
         "data/renamed.json holds JSON_checker's marker under another name"
         (refused (checker-text (at "checker-content" "data/renamed.json"))))
   (list "checker-both"
         "data/pass3.json is named like one and holds the marker: both are named"
         (refused (checker-name (at "checker-both" "data/pass3.json"))
                  (checker-text (at "checker-both" "data/pass3.json"))))

   ;; --- several problems at once ---
   (list "two-problems"
         "a stray file, an empty LICENSE and no SOURCE: all three are named, in order"
         (refused (string-append (root "two-problems") "/README: is a file, not a directory")
                  (string-append (at "two-problems" "LICENSE") ": is empty")
                  (string-append (at "two-problems" "SOURCE") ": is missing")))))

;; shell : String String ... -> Unit
;; Runs `sh -c SCRIPT sh ARGS ...`, and raises unless it exits 0.
(define (shell script . args)
  (let ((r (capture-command (append (list "sh" "-c" script "sh") args))))
    (unless (equal? r (list 0 "" ""))
      (error 'shell "setup command failed" script r))))

(test-begin "check-corpora")

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

(test-equal "a slash after the root changes nothing: no doubled slash in a path it names"
  (caddr (assoc "stray-file" cases))
  (run (list (string-append (root "stray-file") "//"))))

(test-equal "a root that does not exist is named"
  (refused "tests/fixtures/corpora/no-such-root: is not a directory")
  (run '("tests/fixtures/corpora/no-such-root")))

(test-equal "a root that is a file is named"
  (refused "tests/fixtures/corpora/ok/alpha/SOURCE: is not a directory")
  (run '("tests/fixtures/corpora/ok/alpha/SOURCE")))

(test-equal "no argument: the usage line, exit 1"
  (list 1 "" "check-corpora: usage: scheme --program tests/check-corpora.sps DIR\n")
  (run '()))

(test-equal "two arguments: the usage line, exit 1"
  (list 1 "" "check-corpora: usage: scheme --program tests/check-corpora.sps DIR\n")
  (run '("a" "b")))

;; --- what git cannot hold ---------------------------------------------------

(define (link-problem path)
  (string-append path ": is a symbolic link; links below a corpus are never followed (ADR-0012)"))

(define good-corpus (absolute (string-append fixtures "/ok/alpha")))

;; temp-case : String (String -> Unit) (String -> (List Integer String String)) -> Unit
;; Makes a fresh directory, lets SETUP fill it, runs the program on it, and
;; asserts the result equals EXPECTED applied to the directory's name.
(define (temp-case name setup expected)
  (let ((r (call-with-temp-directory
            (lambda (dir)
              (setup dir)
              (list (expected dir) (run (list dir)))))))
    (test-equal name (car r) (cadr r))))

(temp-case "an empty directory holds no corpus"
  (lambda (dir) #f)
  (lambda (dir) (refused (string-append dir ": holds no corpus directory"))))

(temp-case "a symbolic link to a good corpus is not a directory, though its target is one"
  (lambda (dir)
    (shell "cp -R \"$1\" \"$2/real\" && ln -s \"$2/real\" \"$2/link\"" good-corpus dir))
  (lambda (dir) (refused (string-append dir "/link: is a symbolic link, not a directory"))))

(temp-case "a symbolic link alone leaves no corpus directory"
  (lambda (dir)
    (shell "ln -s \"$1\" \"$2/link\"" good-corpus dir))
  (lambda (dir)
    (refused (string-append dir "/link: is a symbolic link, not a directory")
             (string-append dir ": holds no corpus directory"))))

(temp-case "a LICENSE that is a symbolic link to a file is not a regular file"
  (lambda (dir)
    (shell "cp -R \"$1\" \"$2/c\" && rm \"$2/c/LICENSE\" && ln -s SOURCE \"$2/c/LICENSE\"" good-corpus dir))
  (lambda (dir)
    (refused (string-append dir "/c/LICENSE: is a symbolic link, not a regular file")
             (link-problem (string-append dir "/c/LICENSE")))))

(temp-case "a dangling SOURCE link is not a regular file, and is not missing"
  (lambda (dir)
    (shell "cp -R \"$1\" \"$2/c\" && rm \"$2/c/SOURCE\" && ln -s nowhere \"$2/c/SOURCE\"" good-corpus dir))
  (lambda (dir)
    (refused (string-append dir "/c/SOURCE: is a symbolic link, not a regular file")
             (link-problem (string-append dir "/c/SOURCE")))))

(temp-case "below a corpus, a dangling link is named, and not followed"
  (lambda (dir)
    (shell "cp -R \"$1\" \"$2/c\" && ln -s nowhere \"$2/c/data/dangling\"" good-corpus dir))
  (lambda (dir) (refused (link-problem (string-append dir "/c/data/dangling")))))

(temp-case "below a corpus, a link to a file is named"
  (lambda (dir)
    (shell "cp -R \"$1\" \"$2/c\" && ln -s a.json \"$2/c/data/tofile\"" good-corpus dir))
  (lambda (dir) (refused (link-problem (string-append dir "/c/data/tofile")))))

(temp-case "below a corpus, a link to a directory is named, and its files are not scanned"
  (lambda (dir)
    (shell "cp -R \"$1\" \"$2/c\" && ln -s deep \"$2/c/data/todir\"" good-corpus dir))
  (lambda (dir) (refused (link-problem (string-append dir "/c/data/todir")))))

(temp-case "a link named like JSON_checker's is named twice: as a link and by its name"
  (lambda (dir)
    (shell "cp -R \"$1\" \"$2/c\" && ln -s nowhere \"$2/c/data/pass2.json\"" good-corpus dir))
  (lambda (dir)
    (let ((p (string-append dir "/c/data/pass2.json")))
      (refused (link-problem p) (checker-name p)))))

(temp-case "an empty SOURCE lacks all six keys, named in order"
  (lambda (dir)
    (shell "cp -R \"$1\" \"$2/c\" && : > \"$2/c/SOURCE\"" good-corpus dir))
  (lambda (dir)
    (apply refused
           (map (lambda (key) (string-append dir "/c/SOURCE: key " key " is missing"))
                '("name" "url" "commit" "fetched" "taken" "license")))))

(test-end "check-corpora")

(exit (suite-exit-status runner))
