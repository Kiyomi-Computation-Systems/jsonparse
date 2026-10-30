#!r6rs
;;; (jsonparse-testing): the shared exit form, the verdict it exits with,
;;; describe, capture-command and call-with-temp-directory.
;;;
;;; An expected value here is one the code under test cannot produce by
;;; failing: SRFI-64 turns a raise in the actual expression into #f, so none
;;; is #f, and a refusal is compared against a sentinel for no raise at all.
;; Chez's current-error-port is a parameter, which (rnrs)'s is not.
(import (except (rnrs) current-error-port)
        (srfi :64)
        (only (chezscheme) parameterize current-error-port getenv putenv
              directory-list file-directory? mkdir iota get-process-id fork-thread
              make-mutex with-mutex make-condition condition-wait
              condition-broadcast real-time library-directories)
        (jsonparse-testing))

(define runner (test-runner-simple))
(test-runner-current runner)

;; runner-after : (-> Any) -> Test-Runner
;; A fresh, silent runner, after `thunk` has run its tests on it.
(define (runner-after thunk)
  (let ((r (test-runner-null)))
    (test-with-runner r (thunk))
    r))

;; verdict : (-> Any) -> (List (U 0 1 Symbol) String)
;; suite-exit-status's answer for a runner `thunk` filled, and what it wrote
;; on the error port. A raise answers the list (raised <description>).
(define (verdict thunk)
  (guard (e (#t (list 'raised (describe e))))
    (let ((r (runner-after thunk)))
      (let-values (((port text) (open-string-output-port)))
        (let ((status (parameterize ((current-error-port port))
                        (suite-exit-status r))))
          (list status (text)))))))

(define (refused-line pass fail xpass)
  (string-append "suite-exit-status: exit 1 (pass " (number->string pass)
                 ", fail " (number->string fail) ", xpass " (number->string xpass)
                 "): a suite needs a pass, and no fail or xpass\n"))

;; Each runner's verdict, computed before the suite begins, under a guard.
(define one-pass
  (verdict (lambda () (test-assert "p" #t))))
(define none
  (verdict (lambda () #t)))
(define pass-and-fail
  (verdict (lambda () (test-assert "p" #t) (test-assert "f" #f))))
(define pass-and-xpass
  (verdict (lambda () (test-assert "p" #t) (test-expect-fail 1) (test-assert "x" #t))))
(define pass-and-xfail
  (verdict (lambda () (test-assert "p" #t) (test-expect-fail 1) (test-assert "x" #f))))
(define pass-and-skip
  (verdict (lambda () (test-assert "p" #t) (test-skip 1) (test-assert "s" #f))))
(define only-fails
  (verdict (lambda () (test-assert "f1" #f) (test-assert "f2" #f))))
(define not-a-runner
  (guard (e ((and (assertion-violation? e) (who-condition? e))
             (list 'assertion-violation (condition-who e) (condition-irritants e)))
            (#t (list 'other (describe e))))
    (suite-exit-status 'not-a-runner)
    'returned))

(test-begin "jsonparse-testing")

;; Built with list, not quoted: make check-suites reads a quoted exit form
;; as one.
(test-equal "suite-exit-form is the shared exit form"
  (list 'exit (list 'suite-exit-status 'runner))
  suite-exit-form)

(test-equal "one pass: 0, and nothing on the error port"
  '(0 "")
  one-pass)

(test-equal "no test at all: 1, saying so"
  (list 1 (refused-line 0 0 0))
  none)

(test-equal "a pass and a fail: 1, with the counts"
  (list 1 (refused-line 1 1 0))
  pass-and-fail)

(test-equal "a pass and an unexpected pass: 1, with the counts"
  (list 1 (refused-line 1 0 1))
  pass-and-xpass)

(test-equal "a pass and an expected failure: 0"
  '(0 "")
  pass-and-xfail)

(test-equal "a pass and a skip: 0"
  '(0 "")
  pass-and-skip)

(test-equal "two fails: 1, never the count of failures"
  (list 1 (refused-line 0 2 0))
  only-fails)

(test-equal "what is not a runner is refused"
  '(assertion-violation suite-exit-status (not-a-runner))
  not-a-runner)

(test-equal "describe writes a non-condition"
  "(a \"b\" 3)"
  (describe '(a "b" 3)))

(test-equal "describe displays a condition"
  "Exception in who: what with irritant 7"
  (describe (condition (make-who-condition 'who)
                       (make-message-condition "what")
                       (make-irritants-condition '(7)))))

;; --- capture-command ------------------------------------------------------

;; raised : (-> Any) -> Any
;; What THUNK raised: (assertion-violation WHO IRRITANTS) for an assertion
;; violation, (other-raise MESSAGE) for any other condition with a message,
;; (other-raise OBJECT) for anything else raised, and the symbol no-raise if
;; THUNK returned.
(define (raised thunk)
  (guard (e ((and (assertion-violation? e) (who-condition? e)
                  (irritants-condition? e))
             (list 'assertion-violation (condition-who e) (condition-irritants e)))
            ((message-condition? e) (list 'other-raise (condition-message e)))
            (#t (list 'other-raise e)))
    (thunk)
    'no-raise))

(test-equal "capture-command: the exit status, stdout and stderr, kept apart"
  '(3 "out\n" "err\n")
  (capture-command '("sh" "-c" "echo out; echo err >&2; exit 3")))

(test-equal "capture-command: each argument arrives as one word, unchanged"
  '(0 "a b|$HOME|it's|\"q\"|back\\slash||*|;|two\nlines|" "")
  (capture-command
   (list "printf" "%s|"
         "a b" "$HOME" "it's" "\"q\"" "back\\slash" "" "*" ";" "two\nlines")))

(test-equal "capture-command: a command that writes nothing answers two empty strings"
  '(0 "" "")
  (capture-command '("true")))

(test-equal "capture-command: output is UTF-8, on stdout and on stderr"
  (list 0
        (string (integer->char #xE9) (integer->char #x3BB))
        (string (integer->char #x3BB) (integer->char #xE9)))
  (capture-command
   '("sh" "-c" "printf '\\303\\251\\316\\273'; printf '\\316\\273\\303\\251' >&2")))

(test-equal "capture-command: an unknown command is the shell's 127, not a raise"
  127
  (car (capture-command '("jsonparse-testing-no-such-command"))))

(test-equal "capture-command: a NUL would cut the command short, so it is refused"
  (list 'assertion-violation 'capture-command (list (string #\a #\nul #\b)))
  (raised (lambda () (capture-command (list "printf" (string #\a #\nul #\b))))))

(test-equal "capture-command: every argument is a string"
  '(assertion-violation capture-command (5))
  (raised (lambda () (capture-command '("echo" 5)))))

(test-equal "capture-command: a command has at least its name"
  '(assertion-violation capture-command (()))
  (raised (lambda () (capture-command '()))))

(test-equal "capture-command: a command is a list, not a string"
  '(assertion-violation capture-command ("echo"))
  (raised (lambda () (capture-command "echo"))))

(test-equal "capture-command: a command is a proper list"
  '(assertion-violation capture-command (("echo" . "x")))
  (raised (lambda () (capture-command '("echo" . "x")))))

;; --- the scratch directory capture-command writes in ----------------------
;; Each capture writes its two files into a directory of its own, in $TMPDIR,
;; which Chez's mkdir makes with mode 700 and refuses to make over a name
;; that is taken. These rows hold that, and what the directory costs: none
;; left behind, however the call ends, and a raise before the command runs
;; when none can be made.

;; call-with-env : String String (-> Any) -> Any
;; THUNK with the environment variable NAME set to VALUE. Afterwards NAME is
;; put back to its old value, or to /tmp when it was unset: putenv cannot
;; unset, and /tmp is where capture-command goes for an unset TMPDIR.
(define (call-with-env name value thunk)
  (let ((old (getenv name)))
    (dynamic-wind
      (lambda () (putenv name value))
      thunk
      (lambda () (putenv name (or old "/tmp"))))))

;; sorted-names : String -> (Listof String)
(define (sorted-names dir) (list-sort string<? (directory-list dir)))

;; capture-in : String (Listof String) -> (List Integer String String)
;; capture-command with $TMPDIR set to DIR.
(define (capture-in dir argv)
  (call-with-env "TMPDIR" dir (lambda () (capture-command argv))))

(test-equal "capture-command: it leaves nothing behind in the scratch directory"
  '((0 "x\n" "") ())
  (call-with-temp-directory
   (lambda (dir)
     (let ((answer (capture-in dir '("sh" "-c" "echo x"))))
       (list answer (directory-list dir))))))

(test-equal "capture-command: its directory's mode is 700"
  '(0 "drwx------")
  (call-with-temp-directory
   (lambda (dir)
     (let ((answer (capture-in dir (list "sh" "-c" "ls -ld \"$1\"/jsonparse-testing-*"
                                         "sh" dir))))
       (list (car answer)
             (substring (cadr answer) 0 (min 10 (string-length (cadr answer)))))))))

(test-equal "capture-command: a raise after its directory is made still removes it"
  '((other-raise "the shell did not create a capture file") ())
  (call-with-temp-directory
   (lambda (dir)
     (let ((answer (raised (lambda ()
                             (capture-in dir
                                         (list "sh" "-c"
                                               "rm \"$1\"/jsonparse-testing-*/out"
                                               "sh" dir))))))
       (list answer (directory-list dir))))))

;; capture-name : Natural -> String
;; The name of capture N's directory, below the scratch directory.
(define (capture-name n)
  (string-append "jsonparse-testing-" (number->string (get-process-id)) "-"
                 (number->string n)))

;; current-capture : String -> Natural
;; The N of the capture that lists DIR, with $TMPDIR at DIR: the one capture
;; directory its command sees there is its own.
(define (current-capture dir)
  (let* ((answer (capture-in dir (list "ls" dir)))
         (line (cadr answer))
         (prefix (capture-name 0)))
    (string->number (substring line (- (string-length prefix) 1)
                               (- (string-length line) 1)))))

(test-equal "capture-command: names taken by a directory, by a symbolic link to one and by a dangling link are skipped, and nothing is written into any"
  '((0 "hi\n" "") () () same-names)
  (call-with-temp-directory
   (lambda (dir)
     (let* ((n (current-capture dir))
            (victim (string-append dir "/victim"))
            (missing (string-append dir "/missing"))
            (planted (string-append dir "/" (capture-name (+ n 2))))
            (link (string-append dir "/" (capture-name (+ n 3))))
            (dangling (string-append dir "/" (capture-name (+ n 4)))))
       (mkdir victim)
       ;; That capture was n, and this one is n + 1. The next, n + 2, finds
       ;; the directory, then n + 3 the link, then n + 4 the dangling link.
       (capture-in dir (list "sh" "-c" "ln -s \"$1\" \"$2\" && ln -s \"$3\" \"$4\""
                             "sh" victim link missing dangling))
       (mkdir planted)
       (let* ((answer (capture-in dir '("echo" "hi")))
              (names (sorted-names dir)))
         (list answer (directory-list planted) (directory-list victim)
               (if (equal? names
                           (list-sort string<?
                                      (list "victim" (capture-name (+ n 2))
                                            (capture-name (+ n 3))
                                            (capture-name (+ n 4)))))
                   'same-names
                   names)))))))

(test-equal "capture-command: when the next 100 names are taken, it raises before the command runs"
  '((other-raise "could not make a directory for the command's output") absent)
  (call-with-temp-directory
   (lambda (dir)
     (let ((n (current-capture dir))
           (marker (string-append dir "/ran")))
       (for-each (lambda (i) (mkdir (string-append dir "/" (capture-name (+ n 1 i)))))
                 (iota 100))
       (let ((answer (raised (lambda () (capture-in dir (list "touch" marker))))))
         (list answer (if (file-exists? marker) 'ran 'absent)))))))

(test-equal "capture-command: with no scratch directory to write in, it raises before the command runs"
  '((other-raise "could not make a directory for the command's output") absent)
  (call-with-temp-directory
   (lambda (dir)
     (let* ((marker (string-append dir "/ran"))
            (answer (raised (lambda ()
                              (capture-in (string-append dir "/missing")
                                          (list "touch" marker))))))
       (list answer (if (file-exists? marker) 'ran 'absent))))))

;; captures-in-threads : Natural Natural
;;                       -> (List (Listof (List Natural (Listof Answer))) Natural)
;; THREADS threads, each running PER-THREAD captures, at once with the others,
;; of a command that prints its token on stdout, sleeps 10 ms, and prints it
;; again on stderr. An Answer is (TOKEN RESULT), RESULT what capture-command
;; answered, or what it raised. The answers come by thread, in order, then
;; how many pairs of captures from different threads ran at the same time,
;; by the clock: without some, nothing here ran at once.
(define (captures-in-threads threads per-thread)
  (let ((mx (make-mutex)) (cv (make-condition)) (by-thread '()) (spans '()))
    (do ((t 0 (+ t 1))) ((= t threads))
      (let ((t t))
        (fork-thread
         (lambda ()
           (let loop ((i 0) (answers '()) (mine '()))
             (if (= i per-thread)
                 (with-mutex mx
                   (set! by-thread (cons (list t (reverse answers)) by-thread))
                   (set! spans (cons (cons t mine) spans))
                   (condition-broadcast cv))
                 (let* ((token (string-append "t" (number->string t) "-"
                                              (number->string i)))
                        (start (real-time))
                        (result (guard (e (#t (list 'raised (describe e))))
                                  (capture-command
                                   (list "sh" "-c"
                                         "printf %s \"$1\"; sleep 0.01; printf %s \"$1\" >&2"
                                         "sh" token))))
                        (end (real-time)))
                   (loop (+ i 1) (cons (list token result) answers)
                         (cons (cons start end) mine)))))))))
    (with-mutex mx
      (let wait ()
        (unless (= (length by-thread) threads)
          (condition-wait cv mx)
          (wait))))
    (list (list-sort (lambda (a b) (< (car a) (car b))) by-thread)
          (overlapping-pairs spans))))

;; overlapping-pairs : (Listof (Pairof Natural (Listof (Pairof Ms Ms)))) -> Natural
;; How many pairs of spans, from different threads, overlap in time.
(define (overlapping-pairs spans)
  (define (overlap? a b) (and (< (car a) (cdr b)) (< (car b) (cdr a))))
  (define (across mine theirs)
    (fold-left (lambda (n a) (+ n (length (filter (lambda (b) (overlap? a b)) theirs))))
               0 mine))
  (let loop ((rest spans) (n 0))
    (if (null? rest)
        n
        (loop (cdr rest)
              (fold-left (lambda (n other) (+ n (across (cdr (car rest)) (cdr other))))
                         n (cdr rest))))))

(test-equal "capture-command: two threads capturing at once, 25 times each, each capture answers its own command's output, the calls overlapped in time, and nothing is left behind"
  (list (map (lambda (t)
               (list t (map (lambda (i)
                              (let ((token (string-append "t" (number->string t) "-"
                                                          (number->string i))))
                                (list token (list 0 token token))))
                            (iota 25))))
             '(0 1))
        'overlapped
        '())
  (call-with-temp-directory
   (lambda (dir)
     (let ((ran (call-with-env "TMPDIR" dir (lambda () (captures-in-threads 2 25)))))
       (list (car ran)
             (if (> (cadr ran) 0) 'overlapped (list 'never-overlapped (cadr ran)))
             (directory-list dir))))))

;; --- call-with-temp-directory ---------------------------------------------
;; The dangerous mistake is a path cut at whitespace, so that the removal
;; destroys a neighbour: those rows keep a canary directory beside the one
;; that is made, and require it to survive.

;; absolute? : String -> Boolean
(define (absolute? s)
  (and (> (string-length s) 0) (char=? (string-ref s 0) #\/)))

;; prefix? : String String -> Boolean
(define (prefix? prefix s)
  (and (<= (string-length prefix) (string-length s))
       (string=? prefix (substring s 0 (string-length prefix)))))

;; write-file : String String -> Unit
(define (write-file path text)
  (call-with-port (open-file-output-port path (file-options no-fail) (buffer-mode block)
                                         (make-transcoder (utf-8-codec)))
    (lambda (p) (put-string p text))))

(define chez (getenv "CHEZ"))

(test-equal "CHEZ names the Chez to spawn"
  'set
  (if (and chez (not (string=? chez ""))) 'set 'unset))

;; libdirs : -> String
;; The library path this suite was started with, as --libdirs takes it.
(define (libdirs)
  (let ((dirs (map (lambda (d) (if (pair? d) (car d) d)) (library-directories))))
    (if (null? dirs)
        ""
        (fold-left (lambda (text d) (string-append text ":" d)) (car dirs) (cdr dirs)))))

;; A suite's own stdin may be /dev/null already, and then a capture-command
;; that left stdin alone would pass. So a Chez is started with stdin a regular
;; file, and its program asks capture-command for a command that reports
;; whether its stdin is /dev/null.
(test-equal "capture-command: stdin is /dev/null, whatever the caller's is"
  (list 0 "(0 \"null\\n\" \"\")" "")
  (call-with-temp-directory
   (lambda (dir)
     (let ((program (string-append dir "/stdin.sps")))
       (write-file program
                   (string-append
                    "#!r6rs\n"
                    "(import (rnrs) (jsonparse-testing))\n"
                    "(write (capture-command\n"
                    "  '(\"sh\" \"-c\" \"if test /dev/stdin -ef /dev/null; then echo null; else echo other; fi\")))\n"))
       (capture-command
        (list "sh" "-c" "exec < \"$1\"; exec \"$2\" --libdirs \"$3\" --program \"$1\""
              "sh" program chez (libdirs)))))))

(test-equal "call-with-temp-directory: TMPDIR ending in slashes does not double them in the name"
  'single-slash
  (call-with-temp-directory
   (lambda (base)
     (let ((made (call-with-env "TMPDIR" (string-append base "//")
                   (lambda () (call-with-temp-directory (lambda (dir) dir))))))
       (if (and (prefix? (string-append base "/jsonparse-testing.") made)
                (not (prefix? (string-append base "//") made)))
           'single-slash
           made)))))

(test-equal "call-with-temp-directory: PROC gets the path of an empty directory, and the directory is gone after"
  '((#t #t ()) removed)
  (let* ((made #f)
         (inside (call-with-temp-directory
                  (lambda (dir)
                    (set! made dir)
                    (list (absolute? dir) (file-directory? dir) (directory-list dir))))))
    (list inside (if (file-exists? made) 'left 'removed))))

(test-equal "call-with-temp-directory: its answer is PROC's, and what the directory held is removed too"
  '(answer ("g" "sub") removed)
  (let* ((made #f)
         (listing #f)
         (value (call-with-temp-directory
                 (lambda (dir)
                   (set! made dir)
                   (capture-command
                    (list "sh" "-c"
                          "mkdir \"$1/sub\" && echo x > \"$1/sub/f\" && echo y > \"$1/g\""
                          "sh" dir))
                   (set! listing (sorted-names dir))
                   'answer))))
    (list value listing (if (file-exists? made) 'left 'removed))))

(test-equal "call-with-temp-directory: the directory is removed when PROC raises, and the raise goes on"
  '(boom removed)
  (let ((made #f))
    (guard (e (#t (list e (if (file-exists? made) 'left 'removed))))
      (call-with-temp-directory
       (lambda (dir) (set! made dir) (raise 'boom)))
      'no-raise)))

(test-equal "call-with-temp-directory: the directory is removed when PROC escapes"
  '(escaped removed)
  (let* ((made #f)
         (value (call/cc
                 (lambda (k)
                   (call-with-temp-directory
                    (lambda (dir) (set! made dir) (k 'escaped)))))))
    (list value (if (file-exists? made) 'left 'removed))))

(test-equal "call-with-temp-directory: TMPDIR holding a space is one path; the directory beside it survives"
  '(inside kept removed)
  (call-with-temp-directory
   (lambda (base)
     (let ((canary (string-append base "/can"))
           (spaced (string-append base "/can ary")))
       (capture-command (list "mkdir" canary spaced))
       (write-file (string-append canary "/keep") "keep\n")
       (let ((inside (call-with-env "TMPDIR" spaced
                       (lambda ()
                         (call-with-temp-directory
                          (lambda (dir)
                            (if (prefix? (string-append spaced "/") dir)
                                'inside
                                'elsewhere)))))))
         (list inside
               (if (file-exists? (string-append canary "/keep")) 'kept 'destroyed)
               (if (null? (directory-list spaced)) 'removed 'left)))))))

(define mktemp-refusal
  '(other-raise "mktemp -d did not answer one absolute path to a directory"))

(test-equal "call-with-temp-directory: a newline in TMPDIR makes two lines, which it refuses; the directory named by the first survives"
  (list mktemp-refusal 'kept 'never-called)
  (call-with-temp-directory
   (lambda (base)
     (let ((canary (string-append base "/can"))
           (newlined (string-append base "/can\nary"))
           (called 'never-called))
       (capture-command (list "mkdir" canary newlined))
       (write-file (string-append canary "/keep") "keep\n")
       (let ((answer (call-with-env "TMPDIR" newlined
                       (lambda ()
                         (raised (lambda ()
                                   (call-with-temp-directory
                                    (lambda (dir) (set! called 'called)))))))))
         (list answer
               (if (file-exists? (string-append canary "/keep")) 'kept 'destroyed)
               called))))))

;; with-fake-mktemp : String String (-> Any) -> Any
;; THUNK with a mktemp ahead of the real one on PATH, which runs BODY, shell
;; commands, and an rm that removes nothing and logs its arguments to
;; BASE/rm-log. So a removal that should have been refused cannot reach a
;; real directory, whatever it is told to remove, and the log shows that none
;; was asked for. BASE is a directory of the caller's making to keep them in.
(define (with-fake-mktemp base body thunk)
  (let ((bin (string-append base "/bin")))
    (capture-command (list "mkdir" bin))
    (write-file (string-append bin "/mktemp") (string-append "#!/bin/sh\n" body "\n"))
    (write-file (string-append bin "/rm")
                (string-append "#!/bin/sh\necho \"$@\" >> '" base "/rm-log'\nexit 0\n"))
    (capture-command (list "chmod" "+x" (string-append bin "/mktemp") (string-append bin "/rm")))
    (call-with-env "PATH" (string-append bin ":" (getenv "PATH")) thunk)))

(for-each
 (lambda (row)
   (let ((name (car row)) (body (cadr row)))
     (test-equal (string-append "call-with-temp-directory refuses a mktemp that answers " name
                                ", and calls nothing, and asks for no removal")
       (list mktemp-refusal 'rm-never-run 'never-called)
       (call-with-temp-directory
        (lambda (base)
          (let ((canary (string-append base "/can"))
                (called 'never-called))
            (capture-command (list "mkdir" canary))
            (let ((answer (with-fake-mktemp base (string-append "CANARY='" canary "'\n" body)
                            (lambda ()
                              (raised (lambda ()
                                        (call-with-temp-directory
                                         (lambda (dir) (set! called 'called)))))))))
              (list answer
                    (if (file-exists? (string-append base "/rm-log")) 'rm-run 'rm-never-run)
                    called))))))))
 '(("a relative path to a directory that exists" "printf 'tests\\n'")
   ("a path that is not there" "printf '/no/such/directory/anywhere\\n'")
   ("the root directory" "printf '/\\n'")
   ("an empty line" "printf '\\n'")
   ("no newline" "printf '%s' \"$CANARY\"")
   ("two lines, the first a directory" "printf '%s\\n%s\\n' \"$CANARY\" \"$CANARY/second\"")
   ("a directory and exit 1" "printf '%s\\n' \"$CANARY\"; exit 1")))

;; read-file : String -> String
(define (read-file path)
  (call-with-port (open-file-input-port path (file-options) (buffer-mode block)
                                        (make-transcoder (utf-8-codec)))
    get-string-all))

;; The rows above expect no removal, so the fake rm must be shown to log one
;; when it is asked for: a good answer is used, and removed with rm -rf. The
;; fake rm removes nothing, so the directory is still there, which is a raise.
(test-equal "call-with-temp-directory: a good answer from mktemp is used, and removed with rm -rf; a directory still there after is a raise"
  'as-expected
  (call-with-temp-directory
   (lambda (base)
     (let ((canary (string-append base "/can"))
           (used 'never-called))
       (capture-command (list "mkdir" canary))
       (let* ((answer (with-fake-mktemp base (string-append "printf '%s\\n' '" canary "'")
                        (lambda ()
                          (raised (lambda ()
                                    (call-with-temp-directory (lambda (dir) (set! used dir))))))))
              (log (guard (e (#t 'no-log)) (read-file (string-append base "/rm-log")))))
         (if (and (equal? used canary)
                  (equal? log (string-append "-rf " canary "\n"))
                  (equal? answer '(other-raise "could not remove the directory")))
             'as-expected
             (list used log answer)))))))

(test-end "jsonparse-testing")

;; This suite tests suite-exit-status, so its exit cannot rest on it alone:
;; a suite-exit-status that ignored failures would pass this suite, and
;; make test with it. Any failure here exits 1 first.
(when (positive? (test-runner-fail-count runner))
  (exit 1))

(exit (suite-exit-status runner))
