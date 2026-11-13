#!r6rs
;;; The suite for scripts/bench-chez, which times a Chez benchmark program
;;; for make bench and make bench-callbacks (ADR-0023, jsonparse #22). A Chez
;;; process that compiled its libraries times them differently from one that
;;; loads their objects, so the script compiles the program's imports in a
;;; process of their own, then times the program, and fails if the timed
;;; process still compiled a library.
;;;
;;; Each case writes a small program and its libraries into a fresh
;;; directory, runs the script on them through capture-command, and asserts
;;; the exit status, stdout and stderr, written by hand here. The cases:
;;;
;;;   1. a program's imports are compiled before it runs, so the timed
;;;      process names nothing on its stdout;
;;;   2. a second run on the same objects compiles nothing at all;
;;;   3. a library the timed process had to compile fails the run. A library
;;;      loaded at run time is one the compile step can't see, and only
;;;      --compile-imported-libraries makes Chez name it: without it, Chez
;;;      compiles the library in memory and says nothing;
;;;   4. the program's own exit status is the script's;
;;;   5. a compile that fails stops the script before anything is timed;
;;;   6. BENCH_PIN prefixes the timed process;
;;;   7. too few arguments, or no CHEZ, is a usage error;
;;;   8. the compile step compiles as the timed process would: a library
;;;      records Chez's compile parameters as it is expanded, and the timed
;;;      process compares them with its own;
;;;   9. anything at all on the timed process's stdout fails the run, even
;;;      when the program fails too;
;;;  10. a program whose first datum isn't its import form is refused;
;;;  11. make bench and make bench-callbacks time through the script: the
;;;      one line each prints under make -n that names its program;
;;;  12. CHEZ may name Chez by a bare command found on PATH, even chez, the
;;;      name Homebrew gives it and the Makefile picks on macOS.
;;;
;;; make test runs it from the repository root with CHEZ exported. To run it
;;; against another copy of the script, name it after the suite:
;;;
;;;   $CHEZ --libdirs ... --program tests/test-bench-chez.sps build/copy.sh
(import (rnrs)
        (srfi :64)
        (jsonparse-testing))

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

(define script
  (if (null? (cdr (command-line))) "scripts/bench-chez" (cadr (command-line))))

;; write-text : String String -> Void
;; TEXT as the whole of the file PATH.
(define (write-text path text)
  (call-with-port (open-file-output-port path (file-options no-fail) (buffer-mode block)
                                         (native-transcoder))
    (lambda (port) (put-string port text))))

;; read-text : String -> (U String #f)
;; The whole of the file PATH, "" when it is empty, or #f when there is none.
(define (read-text path)
  (and (file-exists? path)
       (let ((text (call-with-port (open-file-input-port path (file-options) (buffer-mode block)
                                                         (native-transcoder))
                     get-string-all)))
         (if (eof-object? text) "" text))))

;; The compile parameters case 8 compares: every one that changes what Chez
;; makes of a library, as Chez 10.4.1 names them.
(define parameters
  "(optimize-level) (debug-level) (enable-cross-library-optimization)
   (generate-inspector-information) (generate-procedure-source-information)
   (generate-interrupt-trap) (enable-unsafe-application)
   (enable-unsafe-variable-reference) (enable-arithmetic-left-associative)
   (enable-error-source-expression) (commonization-level)
   (compile-interpret-simple) (enable-type-recovery)
   (undefined-variable-warnings) (compile-profile) (generate-covin-files)")

;; setup : String -> Void
;; Under DIR, the libraries (t x), (t y) and (t params) in lib/, and the
;; programs the cases run. Each program writes to stderr only, but
;; stdout.sps, so the timed process's stdout is Chez's alone.
(define (setup dir)
  (capture-command (list "mkdir" "-p" (string-append dir "/lib/t") (string-append dir "/bad/t")))
  (write-text (string-append dir "/lib/t/x.sls")
              "(library (t x) (export x) (import (rnrs)) (define x 1))\n")
  (write-text (string-append dir "/lib/t/y.sls")
              "(library (t y) (export y) (import (rnrs)) (define y 2))\n")
  ;; compiled is the parameters as the library was expanded; running, as the
  ;; process that calls it has them.
  (write-text (string-append dir "/lib/t/params.sls")
              (string-append
               "(library (t params) (export compiled running)\n"
               "  (import (chezscheme))\n"
               "  (define-syntax at-expand\n"
               "    (lambda (stx)\n"
               "      (syntax-case stx ()\n"
               "        ((k) (datum->syntax #'k (list 'quote (list " parameters ")))))))\n"
               "  (define compiled (at-expand))\n"
               "  (define (running) (list " parameters ")))\n"))
  ;; Its import form is not its first line: the script must read the form.
  (write-text (string-append dir "/static.sps")
              "#!r6rs\n;; static\n(import (rnrs) (t x))\n(display x (current-error-port))\n(newline (current-error-port))\n")
  (write-text (string-append dir "/dynamic.sps")
              "(import (rnrs) (rnrs eval) (t x))\n(display (+ x (eval 'y (environment '(t y)))) (current-error-port))\n(newline (current-error-port))\n")
  (write-text (string-append dir "/exits.sps")
              "(import (rnrs) (t x))\n(exit (+ x 2))\n")
  (write-text (string-append dir "/dynamic-exits.sps")
              "(import (rnrs) (rnrs eval) (t x))\n(exit (+ x (eval 'y (environment '(t y)))))\n")
  (write-text (string-append dir "/pinned.sps")
              "(import (rnrs) (only (chezscheme) getenv) (t x))\n(display (or (getenv \"BENCH_CHEZ_PIN\") \"unpinned\") (current-error-port))\n(newline (current-error-port))\n")
  (write-text (string-append dir "/params.sps")
              "(import (rnrs) (t params))\n(write (if (equal? compiled (running)) 'same (list compiled (running))) (current-error-port))\n(newline (current-error-port))\n")
  (write-text (string-append dir "/stdout.sps")
              "(import (rnrs) (t x))\n(display \"x\")\n")
  (write-text (string-append dir "/no-import.sps")
              "(display \"no import\")\n(import (rnrs))\n")
  ;; A library that can't be read: its list never closes.
  (write-text (string-append dir "/bad/t/x.sls")
              "(library (t x) (export x) (import (rnrs)) (define x 1)\n"))

;; libdirs : String String -> String
;; lib/ under DIR, paired with the objdir OBJ under DIR.
(define (libdirs dir obj)
  (string-append dir "/lib::" dir "/" obj))

;; compiled : String String String -> String
;; The line Chez writes when it compiles the library NAME under DIR's lib/
;; into OBJ.
(define (compiled dir obj name)
  (string-append "compiling " dir "/lib/t/" name ".sls with output to "
                 dir "/" obj "/t/" name ".so\n"))

;; refused : String -> String
;; The script's line when the timed process wrote to stdout, then what it
;; wrote.
(define (refused stdout)
  (string-append "bench-chez: the timed process wrote to stdout, where Chez names each library it compiles, so the run doesn't count:\n"
                 stdout))

;; run : String String String String . String -> (List Integer String String)
;; The script on PROGRAM under DIR, its timed stdout to DIR's OUT, with the
;; libraries under DIR's lib/ and objects in OBJ, and no BENCH_PIN.
(define (run dir out obj program . args)
  (capture-command (append (list "env" "-u" "BENCH_PIN" "sh" script (string-append dir "/" out)
                                 (libdirs dir obj) (string-append dir "/" program))
                           args)))

(test-begin "bench-chez")

(test-equal "1. the program's imports compile before it runs, into the objdir, and the timed process names nothing on stdout"
  'compiled-first
  (call-with-temp-directory
   (lambda (dir)
     (setup dir)
     (let* ((result (run dir "out" "obj" "static.sps"))
            (out (read-text (string-append dir "/out")))
            (object (file-exists? (string-append dir "/obj/t/x.so")))
            (want (list (list 0 "" (string-append (compiled dir "obj" "x") "1\n")) "" #t))
            (got (list result out object)))
       (if (equal? got want) 'compiled-first got)))))

(test-equal "2. a second run on the same objects compiles nothing"
  'loaded
  (call-with-temp-directory
   (lambda (dir)
     (setup dir)
     (run dir "out" "obj" "static.sps")
     (let ((got (run dir "out2" "obj" "static.sps")))
       (if (equal? got (list 0 "" "1\n")) 'loaded got)))))

(test-equal "3. a library the timed process had to compile fails the run, and is named"
  'refused
  (call-with-temp-directory
   (lambda (dir)
     (setup dir)
     (let ((want (list 1 ""
                       (string-append (compiled dir "obj" "x") "3\n"
                                      (refused (compiled dir "obj" "y")))))
           (got (run dir "out" "obj" "dynamic.sps")))
       (if (equal? got want) 'refused got)))))

(test-equal "4. the program's own exit status is the script's"
  'exit-3
  (call-with-temp-directory
   (lambda (dir)
     (setup dir)
     (let ((got (run dir "out" "obj" "exits.sps")))
       (if (equal? got (list 3 "" (compiled dir "obj" "x"))) 'exit-3 got)))))

;; The unreadable library is compiled into obj/ from bad/, which this case
;; puts on the path in lib/'s place.
(test-equal "5. a compile that fails names Chez's error and stops the script before anything is timed"
  'stopped
  (call-with-temp-directory
   (lambda (dir)
     (setup dir)
     (let* ((result (capture-command (list "env" "-u" "BENCH_PIN" "sh" script (string-append dir "/out")
                                           (string-append dir "/bad::" dir "/obj")
                                           (string-append dir "/static.sps"))))
            (timed (file-exists? (string-append dir "/out")))
            (want (list (list 1 ""
                              (string-append
                               "compiling " dir "/bad/t/x.sls with output to " dir "/obj/t/x.so\n"
                               "Exception in read: unexpected end-of-file reading list at line 1, char 1 of "
                               dir "/bad/t/x.sls\n"
                               "bench-chez: compiling " dir "/static.sps's libraries failed, so nothing was timed\n"))
                        #f))
            (got (list result timed)))
       (if (equal? got want) 'stopped got)))))

(test-equal "6. BENCH_PIN prefixes the timed process, and without it the program runs as it is"
  'pinned
  (call-with-temp-directory
   (lambda (dir)
     (setup dir)
     (let* ((plain (run dir "out" "obj" "pinned.sps"))
            (pinned (capture-command (list "env" "BENCH_PIN=env BENCH_CHEZ_PIN=yes"
                                           "sh" script (string-append dir "/out2")
                                           (libdirs dir "obj")
                                           (string-append dir "/pinned.sps"))))
            (want (list (list 0 "" (string-append (compiled dir "obj" "x") "unpinned\n"))
                        (list 0 "" "yes\n"))))
       (if (equal? (list plain pinned) want) 'pinned (list plain pinned))))))

(test-equal "7. too few arguments is a usage error"
  '(2 "" "usage: bench-chez STDOUT LIBDIRS PROGRAM [ARG...]\n")
  (capture-command (list "sh" script "out" "lib::obj")))

(test-equal "7. no CHEZ is a usage error"
  '(2 "" "bench-chez: CHEZ names no Chez\n")
  (capture-command (list "env" "-u" "CHEZ" "sh" script "out" "lib::obj" "p.sps")))

(test-equal "8. the compile step compiles with the timed process's own compile parameters"
  'same
  (call-with-temp-directory
   (lambda (dir)
     (setup dir)
     (let ((got (run dir "out" "obj" "params.sps")))
       (if (equal? got (list 0 "" (string-append (compiled dir "obj" "params") "same\n")))
           'same
           got)))))

(test-equal "9. anything on the timed process's stdout fails the run, and is shown"
  'refused
  (call-with-temp-directory
   (lambda (dir)
     (setup dir)
     (let ((got (run dir "out" "obj" "stdout.sps")))
       (if (equal? got (list 1 "" (string-append (compiled dir "obj" "x") (refused "x"))))
           'refused
           got)))))

(test-equal "9. a program that fails after the timed process compiled a library fails as a compile, not with its own status"
  'refused
  (call-with-temp-directory
   (lambda (dir)
     (setup dir)
     (let ((got (run dir "out" "obj" "dynamic-exits.sps")))
       (if (equal? got (list 1 "" (string-append (compiled dir "obj" "x")
                                                 (refused (compiled dir "obj" "y")))))
           'refused
           got)))))

(test-equal "10. a program whose first datum isn't its import form is refused before anything is timed"
  'refused
  (call-with-temp-directory
   (lambda (dir)
     (setup dir)
     (let* ((result (run dir "out" "obj" "no-import.sps"))
            (timed (file-exists? (string-append dir "/out")))
            (want (list (list 1 ""
                              (string-append
                               "bench-chez: the program's first datum is not an import form\n"
                               "bench-chez: compiling " dir "/no-import.sps's libraries failed, so nothing was timed\n"))
                        #f))
            (got (list result timed)))
       (if (equal? got want) 'refused got)))))

;; lines-naming : String String -> (Listof String)
;; The lines of TEXT that hold NEEDLE, in order.
(define (lines-naming text needle)
  (define (holds? line)
    (let search ((i 0))
      (and (<= (+ i (string-length needle)) (string-length line))
           (or (string=? (substring line i (+ i (string-length needle))) needle)
               (search (+ i 1))))))
  (let split ((start 0) (i 0) (out '()))
    (cond ((= i (string-length text))
           (let ((line (substring text start i)))
             (reverse (if (holds? line) (cons line out) out))))
          ((char=? (string-ref text i) #\newline)
           (let ((line (substring text start i)))
             (split (+ i 1) (+ i 1) (if (holds? line) (cons line out) out))))
          (else (split start (+ i 1) out)))))

;; Each target runs its program once, and that line goes through the script.
;; BENCH_CPU is empty, so BENCH_PIN is too, and the lines don't depend on
;; this machine's cores.
(test-equal "11. make bench times bench/run.sps through the script"
  '("BENCH_PIN='' sh scripts/bench-chez build/bench/jsonparse-stdout.txt \"src::build/bench/obj/src:vendor/byte-machine/src::build/bench/obj/byte-machine:bench::build/bench/obj/bench\" bench/run.sps \\")
  (let ((result (capture-command (list "make" "-n" "--no-print-directory" "bench-inside"
                                       "BENCH_PARSERS=" "BENCH_CPU="))))
    (if (= (car result) 0) (lines-naming (cadr result) "bench/run.sps") result)))

(test-equal "11. make bench-callbacks times bench/callbacks.sps through the script"
  '("BENCH_PIN='' sh scripts/bench-chez build/bench/callbacks-stdout.txt \"src::build/bench/callbacks-obj/src:vendor/byte-machine/src::build/bench/callbacks-obj/byte-machine:bench::build/bench/callbacks-obj/bench\" bench/callbacks.sps \\")
  (let ((result (capture-command (list "make" "-n" "--no-print-directory" "bench-callbacks-inside"
                                       "BENCH_CPU="))))
    (if (= (car result) 0) (lines-naming (cadr result) "bench/callbacks.sps") result)))

;; A chez of its own in DIR's bin/, first on PATH, which logs each run to
;; DIR's ran, then runs the Chez that CHEZ names. Both of the script's
;; processes must start through it.
(test-equal "12. CHEZ may name Chez by a bare command, even chez, the name Homebrew gives it"
  'through-path
  (call-with-temp-directory
   (lambda (dir)
     (setup dir)
     (let* ((found (capture-command (list "sh" "-c" "command -v \"$CHEZ\"")))
            (real (let ((text (cadr found)))
                    (substring text 0 (max 0 (- (string-length text) 1)))))
            (bin (string-append dir "/bin")))
       (capture-command (list "mkdir" "-p" bin))
       (write-text (string-append bin "/chez")
                   (string-append "#!/bin/sh\necho ran >>'" dir "/ran'\nexec '" real "' \"$@\"\n"))
       (capture-command (list "chmod" "+x" (string-append bin "/chez")))
       (let* ((result (capture-command
                       (list "env" "-u" "BENCH_PIN" "CHEZ=chez"
                             "sh" "-c" "PATH=\"$1:$PATH\"; export PATH; shift; exec sh \"$@\""
                             "sh" bin script (string-append dir "/out") (libdirs dir "obj")
                             (string-append dir "/static.sps"))))
              (want (list (list 0 "" (string-append (compiled dir "obj" "x") "1\n"))
                          "ran\nran\n"))
              (got (list result (read-text (string-append dir "/ran")))))
         (if (and (= (car found) 0) (equal? got want)) 'through-path (list found got)))))))

(test-end "bench-chez")

(exit (suite-exit-status runner))
