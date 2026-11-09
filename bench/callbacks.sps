;;; bench/callbacks.sps OUT MACHINE ROUNDS ROUND-BYTES FILE...: the callback
;;; path's lanes, (jsonparse-bench callbacks)'s, timed on each FILE with
;;; ADR-0023's method, the lanes taking turns, and their report written to
;;; OUT (ADR-0025). MACHINE is scripts/bench-machine's output, read first.
;;;
;;; On each file, m-count's one pass, outside the timing, must count what
;;; the events lane counts. After the lanes are timed, each one's tally must
;;; show the method's passes, and for m-count and events those passes'
;;; counts. Anything else, a file that isn't one JSON document included,
;;; stops it with exit 1 and leaves OUT as it was; bad arguments exit 2.
(import (rnrs)
        (only (chezscheme) scheme-version machine-type optimize-level rename-file display-condition)
        (jsonparse-bench)
        (jsonparse-bench callbacks)
        (only (jsonparse-bench report) read-machine))

(define (usage)
  (display "usage: callbacks.sps OUT MACHINE ROUNDS ROUND-BYTES FILE...\n" (current-error-port))
  (exit 2))

(define args (cdr (command-line)))
(when (< (length args) 5) (usage))

(define (positive s)
  (let ((n (string->number s)))
    (unless (and n (exact? n) (integer? n) (> n 0)) (usage))
    n))

(define out (car args))
(define machine-path (cadr args))
(define rounds (positive (caddr args)))
(define round-bytes (positive (cadddr args)))
(define paths (cddddr args))

(define (basename path)
  (let loop ((i (- (string-length path) 1)))
    (cond ((< i 0) path)
          ((char=? (string-ref path i) #\/) (substring path (+ i 1) (string-length path)))
          (else (loop (- i 1))))))

(define (read-bytes path)
  (let ((bv (call-with-port (open-file-input-port path) get-bytevector-all)))
    (if (eof-object? bv) (make-bytevector 0) bv)))

(define (read-text path)
  (call-with-port (open-file-input-port path (file-options) (buffer-mode block)
                                        (make-transcoder (utf-8-codec)))
    get-string-all))

(define (say . parts)
  (for-each (lambda (x) (display x (current-error-port))) (cons "bench-callbacks: " parts))
  (newline (current-error-port)))

;; row : String -> (List String Nat Nat Nat (Listof (Pair Symbol (Listof Real))))
;; A file's name, bytes, values, m-noop's calls a pass, and each lane's
;; nanoseconds a pass, turn by turn.
(define (row path)
  (let* ((name (basename path))
         (bv (read-bytes path))
         (counts (events-counts bv))
         (iterations (iterations-for (bytevector-length bv) round-bytes)))
    (unless (equal? (machine-counts bv) counts)
      (error 'callbacks.sps "m-count counts other than the events lane" name (machine-counts bv) counts))
    (say name ": " (length callback-lanes) " lanes, taking turns")
    (let* ((lanes (map (lambda (lane)
                         (let-values (((thunk tally) (callback-lane-thunk lane bv)))
                           (list lane thunk tally)))
                       callback-lanes))
           (times (measure-interleaved (map cadr lanes) iterations rounds)))
      (for-each (lambda (l) (check-tally (car l) counts (* iterations (+ rounds 1)) ((caddr l))))
                lanes)
      (list name (bytevector-length bv) (value-count counts) (machine-calls bv)
            (map (lambda (l ns) (cons (car l) (map (lambda (x) (/ x iterations)) ns)))
                 lanes times)))))

(define runtime
  (string-append (scheme-version) " (" (symbol->string (machine-type))
                 "), libraries compiled ahead of time at optimize-level "
                 (number->string (optimize-level))))

(define (condition-text e)
  (call-with-string-output-port (lambda (port) (display-condition e port))))

(guard (e (#t (say (condition-text e)) (exit 1)))
  (let* ((machine (let ((m (read-machine (read-text machine-path))))
                    (for-each (lambda (key)
                                (unless (assq key m)
                                  (error 'callbacks.sps "MACHINE names no key" machine-path key)))
                              '(date cpu arch os pin))
                    m))
         (rows (let loop ((paths paths) (acc '()))
                 (if (null? paths) (reverse acc) (loop (cdr paths) (cons (row (car paths)) acc)))))
         (text (callbacks-text machine runtime rounds round-bytes rows))
         (part (string-append out ".part")))
    (when (file-exists? part) (delete-file part))
    (call-with-port (open-file-output-port part (file-options) (buffer-mode block)
                                           (make-transcoder (utf-8-codec)))
      (lambda (port) (put-string port text)))
    (rename-file part out)
    (say "wrote " out)))
