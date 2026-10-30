#!r6rs
;;; The suite for tests/check-suites.sps, the program behind
;;; `make check-suites`. Without it, a check-suites that passed everything
;;; would leave `make test` green while a suite that exits 0 before its
;;; tests reported a pass. Each fixture under tests/fixtures/suites/ is one
;;; fault, or none; this suite runs the program on it in a fresh Chez,
;;; through capture-command, and asserts the exit status and the whole of
;;; stdout and stderr, as text written by hand here. The fixtures are never
;;; suites: make test runs tests/test-*.sps only.
;;;
;;; make test runs it from the repository root with CHEZ exported. To run it
;;; against another copy of the program, name it after the suite:
;;;
;;;   $CHEZ --libdirs ... --program tests/test-check-suites.sps build/copy.sps
(import (rnrs)
        (srfi :64)
        (jsonparse-testing)
        (only (chezscheme) getenv library-directories directory-list))

(define runner (test-runner-simple))
(test-runner-current runner)

(define chez (getenv "CHEZ"))

(define program
  (if (null? (cdr (command-line))) "tests/check-suites.sps" (cadr (command-line))))

(define fixtures "tests/fixtures/suites")

;; libdirs : String
;; The library path this suite was started with, as --libdirs takes it.
(define libdirs
  (let ((dirs (map (lambda (d) (if (pair? d) (car d) d)) (library-directories))))
    (if (null? dirs)
        ""
        (fold-left (lambda (text d) (string-append text ":" d)) (car dirs) (cdr dirs)))))

;; run : (Listof String) -> (List Integer String String)
;; The program in a fresh Chez on the fixtures NAMES: its exit status, stdout
;; and stderr.
(define (run names)
  (capture-command (append (list chez "--libdirs" libdirs "--program" program)
                           (map at names))))

;; at : String -> String
(define (at name) (string-append fixtures "/" name))

;; The shared exit form, as the program writes it.
(define form "(exit (suite-exit-status runner))")

;; passed : Natural -> (List 0 String "")
(define (passed n)
  (list 0
        (string-append "check-suites: every suite ends with " form " ("
                       (number->string n) " checked)\n")
        ""))

;; refused : String ... -> (List 1 "" String)
(define (refused . problems)
  (list 1 ""
        (apply string-append
               (map (lambda (p) (string-append "check-suites: " p "\n")) problems))))

(define (last-datum name datum)
  (string-append (at name) ": its last datum is " datum ", not " form))

(define (early name exit-form)
  (string-append (at name) ": " exit-form
                 " before the last datum would end the suite before its verdict;"
                 " only (exit 1) may exit early"))

;; cases : (Listof (List String (Listof String) Expected))
(define cases
  (list
   (list "a suite that ends with the shared form passes"
         '("good.sps") (passed 1))
   (list "an early (exit 1) is allowed"
         '("early-one.sps") (passed 1))
   (list "a suite with no exit form is named"
         '("no-exit.sps") (refused (last-datum "no-exit.sps" "(display \"no exit form\")")))
   (list "an (exit 0) before the last datum is named"
         '("early-zero.sps") (refused (early "early-zero.sps" "(exit 0)")))
   (list "a bare (exit), which exits 0, is named"
         '("early-bare.sps") (refused (early "early-bare.sps" "(exit)")))
   (list "an (exit #t) is named too: only (exit 1) may exit early"
         '("early-true.sps") (refused (early "early-true.sps" "(exit #t)")))
   (list "an exit form nested in a definition is named"
         '("nested-early.sps") (refused (early "nested-early.sps" "(exit 2)")))
   (list "a quoted exit form is data, so it is named too"
         '("quoted.sps") (refused (early "quoted.sps" "(exit 0)")))
   (list "a datum after the shared form is the last one, so it is named, and the form before it too"
         '("after-form.sps")
         (refused (last-datum "after-form.sps" "(display \"never runs\")")
                  (early "after-form.sps" form)))
   (list "an exit form with another runner is not the shared one"
         '("other-form.sps")
         (refused (last-datum "other-form.sps" "(exit (suite-exit-status other-runner))")))
   (list "an empty file holds no datum"
         '("empty.sps")
         (refused (string-append (at "empty.sps") ": it holds no datum, so it cannot end with " form)))
   (list "a file that cannot be read is named, with Chez's reason"
         '("unreadable.sps")
         (refused (string-append (at "unreadable.sps")
                                 ": it cannot be read as data: Exception in read: unexpected end-of-file reading list before file-position 36 of #<input port "
                                 (at "unreadable.sps") ">; the character position might differ")))
   (list "every bad suite of several is named, in the order given, and the good ones are not"
         '("good.sps" "no-exit.sps" "early-one.sps" "early-zero.sps")
         (refused (last-datum "no-exit.sps" "(display \"no exit form\")")
                  (early "early-zero.sps" "(exit 0)")))
   (list "no suite at all passes: make test refuses that case itself"
         '() (passed 0))))

(test-begin "check-suites")

(test-equal "CHEZ names the Chez to spawn"
  'set
  (if (and chez (not (string=? chez ""))) 'set 'unset))

(unless (and chez (not (string=? chez "")))
  (exit 1))

(for-each
 (lambda (case)
   (test-equal (car case) (caddr case) (run (cadr case))))
 cases)

;; A fixture no case runs guards nothing.
(test-equal "every fixture is named by a case"
  (list-sort string<? (directory-list fixtures))
  (list-sort string<?
             (fold-left (lambda (names case)
                          (fold-left (lambda (names name)
                                       (if (member name names) names (cons name names)))
                                     names (cadr case)))
                        '() cases)))

(test-end "check-suites")

(exit (suite-exit-status runner))
