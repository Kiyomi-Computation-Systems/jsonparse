#!r6rs
;;; (jsonparse-testing): what every suite shares.
;;;
;;;   suite-exit-form    the last datum of every tests/test-*.sps
;;;   suite-exit-status  the verdict that form exits with
;;;   describe           a raised object as text, for evidence
;;;   capture-command    run a command; its exit status, stdout and stderr
;;;   call-with-temp-directory
;;;                      a fresh mktemp -d directory, removed after a call
;;;
;;; Test-only: it lives in tests/, which make test puts on Chez's library
;;; path, not in src/. Its own suite is tests/test-jsonparse-testing.sps.
;;; The check programs' suites run each program in a fresh Chez through
;;; capture-command, and write the trees git cannot hold (an empty
;;; directory, a header with a CR) into call-with-temp-directory.
(library (jsonparse-testing)
  (export suite-exit-form suite-exit-status describe
          capture-command call-with-temp-directory)
  (import (rnrs)
          (srfi :64)
          (only (chezscheme) critical-section delete-directory display-condition
                file-directory? get-process-id getenv make-mutex mkdir system
                with-mutex)
          ;; Chez's file-exists? takes a second argument, #f not to follow a
          ;; symbolic link; (rnrs)'s takes one.
          (prefix (only (chezscheme) file-exists?) chez:))

  ;; suite-exit-form : Sexp
  ;; The last datum of every tests/test-*.sps, exactly: make check-suites
  ;; reads each suite as data and compares its last datum with this one.
  ;; `runner` is the suite's own binding for the runner it makes current. A
  ;; suite that never makes it current leaves it with no test, and fails.
  (define suite-exit-form '(exit (suite-exit-status runner)))

  ;; suite-exit-status : Test-Runner -> (U 0 1)
  ;; 0 when RUNNER saw a pass, and no failure and no unexpected pass.
  ;; Otherwise 1, after a line on the error port with the runner's counts.
  ;; Expected failures and skips count neither way. SRFI-64 sets no exit
  ;; status of its own. The answer is 0 or 1, never a count: exit statuses
  ;; wrap at 256, so 256 failures would exit 0.
  (define (suite-exit-status runner)
    (unless (test-runner? runner)
      (assertion-violation 'suite-exit-status "not a SRFI-64 test runner" runner))
    (let ((pass (test-runner-pass-count runner))
          (fail (test-runner-fail-count runner))
          (xpass (test-runner-xpass-count runner)))
      (if (and (> pass 0) (= fail 0) (= xpass 0))
          0
          (let ((err (current-error-port)))
            ;; The runner's own summary, on stdout, comes first.
            (flush-output-port (current-output-port))
            (put-string err
              (string-append "suite-exit-status: exit 1 (pass " (number->string pass)
                             ", fail " (number->string fail)
                             ", xpass " (number->string xpass)
                             "): a suite needs a pass, and no fail or xpass\n"))
            (flush-output-port err)
            1))))

  ;; describe : Any -> String
  ;; A condition as Chez displays it, anything else as `write` writes it.
  ;; Evidence for a test's expected value, never raising itself.
  (define (describe obj)
    (guard (e (#t "<the raised object could not be printed>"))
      (call-with-string-output-port
       (lambda (p)
         (if (condition? obj) (display-condition obj p) (write obj p))))))

  ;; --- capture-command -----------------------------------------------------

  ;; capture-command : (Listof String) -> (List Integer String String)
  ;; Runs ARGV, a command's name and then its arguments, through /bin/sh.
  ;; Each one is quoted, so it arrives as one word, unchanged. stdin is
  ;; /dev/null. The answer is the exit status as Chez's `system` reports it,
  ;; then all the command wrote to stdout and to stderr, as UTF-8. A non-zero
  ;; exit is an answer, not a raise, so a test compares the whole list with
  ;; what it expects.
  ;;
  ;; A NUL is refused: `system` takes a C string, which would end there and
  ;; run whatever came before it. The two streams go through two files in a
  ;; directory of the call's own (make-capture-directory), removed after,
  ;; however the call ends. Any thread may call it, and calls on several at
  ;; once share no file.
  (define (capture-command argv)
    (check-command argv)
    (let ((dir #f))
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          ;; Made and recorded in one critical section, so that no escape
          ;; leaves a directory the after thunk cannot see.
          (critical-section (set! dir (make-capture-directory)))
          (let* ((out (string-append dir "/out"))
                 (err (string-append dir "/err"))
                 (status (system (string-append (join-words (map shell-quote argv))
                                                " </dev/null >" (shell-quote out)
                                                " 2>" (shell-quote err)))))
            (let* ((stdout (file->string out))
                   (stderr (file->string err)))
              (list status stdout stderr))))
        (lambda ()
          (when dir
            (for-each (lambda (name)
                        (guard (e (#t #f)) (remove-files (string-append dir "/" name))))
                      '("out" "err"))
            (delete-directory dir))))))

  ;; make-capture-directory : -> String
  ;; A fresh directory for one capture's files: the scratch directory, then
  ;; jsonparse-testing-PID-N, N counted for this process under a mutex. Chez's
  ;; mkdir makes it with mode 700, and refuses a name that anything already
  ;; holds, a dangling symbolic link included. So no two captures share a
  ;; file, in this process or any other, and none writes through a name
  ;; someone else planted. A name that is taken costs the next N, up to 100
  ;; tries; any other failure raises, before the command runs.
  (define (make-capture-directory)
    (let ((base (string-append (scratch-root) "/jsonparse-testing-"
                               (number->string (get-process-id)) "-")))
      (let try ((tries 1))
        (let ((dir (string-append base (number->string (next-capture)))))
          (cond
            ((guard (e (#t #f)) (mkdir dir #o700) #t) dir)
            ((and (< tries 100) (chez:file-exists? dir #f)) (try (+ tries 1)))
            (else (error 'capture-command "could not make a directory for the command's output"
                         dir)))))))

  ;; next-capture : -> Positive-Integer
  ;; How many captures this process has begun, this one included. The mutex
  ;; is held through critical-section around with-mutex, so no escape can
  ;; leave it held.
  (define (next-capture)
    (critical-section
     (with-mutex capture-mutex
       (set! captures (+ captures 1))
       captures)))

  (define capture-mutex (make-mutex))
  (define captures 0)

  (define (check-command argv)
    (unless (and (pair? argv) (list? argv))
      (assertion-violation 'capture-command "a command is a non-empty list of strings" argv))
    (for-each
     (lambda (arg)
       (unless (string? arg)
         (assertion-violation 'capture-command "an argument is not a string" arg))
       (when (memv #\nul (string->list arg))
         (assertion-violation 'capture-command
                              "an argument holds a NUL, which would end the command there"
                              arg)))
     argv))

  ;; scratch-root : -> String
  ;; $TMPDIR, or /tmp when it is unset or empty, without the slashes it may
  ;; end with, as macOS's does: a name is appended to it after one slash.
  (define (scratch-root)
    (let ((dir (getenv "TMPDIR")))
      (let loop ((dir (if (and dir (not (string=? dir ""))) dir "/tmp")))
        (let ((n (string-length dir)))
          (if (and (> n 0) (char=? (string-ref dir (- n 1)) #\/))
              (loop (substring dir 0 (- n 1)))
              dir)))))

  ;; shell-quote : String -> String
  ;; S as one POSIX shell word: in single quotes, each ' written as '\''.
  (define (shell-quote s)
    (call-with-string-output-port
     (lambda (p)
       (put-char p #\')
       (string-for-each (lambda (c)
                          (if (char=? c #\')
                              (put-string p "'\\''")
                              (put-char p c)))
                        s)
       (put-char p #\'))))

  (define (join-words words)
    (fold-left (lambda (line word) (string-append line " " word))
               (car words) (cdr words)))

  ;; A capture file the shell did not create is a raise, never an empty
  ;; answer, since it means the command did not run as asked.
  (define (file->string path)
    (unless (file-exists? path)
      (error 'capture-command "the shell did not create a capture file" path))
    (let* ((port (open-file-input-port path))
           (bytes (get-bytevector-all port)))
      (close-port port)
      (if (eof-object? bytes) "" (utf8->string bytes))))

  (define (remove-files . paths)
    (for-each (lambda (path) (when (file-exists? path) (delete-file path))) paths))

  ;; --- temporary directories -----------------------------------------------

  ;; call-with-temp-directory : (String -> Any) -> Any
  ;; Makes a fresh directory with `mktemp -d`, under $TMPDIR or /tmp, and
  ;; answers (PROC DIR), DIR being its absolute path. Afterwards the directory
  ;; and all it holds are removed, whether PROC returns, raises or escapes.
  ;; It raises before PROC runs when mktemp's answer is refused, below.
  (define (call-with-temp-directory proc)
    (let ((dir (make-temp-directory)))
      (dynamic-wind
        (lambda () #f)
        (lambda () (proc dir))
        (lambda () (remove-temp-directory dir)))))

  ;; remove-temp-directory : String -> Unit
  ;; Removes the directory DIR and all it holds; DIR may be gone already. It
  ;; raises when the directory is still there afterwards. DIR is one
  ;; make-temp-directory answered, which is why it is safe to remove: an
  ;; absolute path, not /, and exactly mktemp's one line.
  (define (remove-temp-directory dir)
    (when (file-exists? dir)
      (capture-command (list "rm" "-rf" dir))
      (when (file-exists? dir)
        (error 'remove-temp-directory "could not remove the directory" dir))))

  ;; make-temp-directory : -> String
  ;; A fresh directory from `mktemp -d`, given a template under $TMPDIR, or
  ;; /tmp: a bare `mktemp -d` honours TMPDIR on Linux and ignores it on
  ;; macOS, while both read a template alike. mktemp prints the path and a
  ;; newline. The path is that line, whole: $TMPDIR may hold a space, and a
  ;; path cut at whitespace names another directory, which a removal would
  ;; then destroy. So the answer must be exactly one line, an absolute path,
  ;; not the root, to a directory that exists. Any other answer (a relative
  ;; path, a second line, a missing directory, a failure) is refused with a
  ;; raise, and nothing is removed.
  (define (make-temp-directory)
    (let* ((made (capture-command
                  (list "mktemp" "-d" (string-append (scratch-root) "/jsonparse-testing.XXXXXX"))))
           (dir (single-line (cadr made))))
      (if (and (= (car made) 0) dir (absolute-path? dir) (not (string=? dir "/"))
               (file-directory? dir))
          dir
          (error 'make-temp-directory
                 "mktemp -d did not answer one absolute path to a directory" made))))

  ;; single-line : String -> (U String #f)
  ;; TEXT without its one final newline, when that leaves a line: not empty,
  ;; and with no newline in it.
  (define (single-line text)
    (let ((n (string-length text)))
      (and (> n 1)
           (char=? (string-ref text (- n 1)) #\newline)
           (let ((line (substring text 0 (- n 1))))
             (and (not (memv #\newline (string->list line))) line)))))

  (define (absolute-path? s)
    (and (> (string-length s) 0) (char=? (string-ref s 0) #\/))))
