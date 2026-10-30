#!r6rs
;;; make check-suites: reads every suite named on the command line as data,
;;; with Chez's reader, and names each suite that breaks one of two rules:
;;;
;;;   - its last datum is exactly suite-exit-form, the shared exit form;
;;;   - no datum before the last holds an exit form but (exit 1), however
;;;     deeply nested: any other would end the suite before its verdict.
;;;
;;; It names every suite that breaks a rule, every one with no datum and every
;;; one it cannot read, on stderr, then exits 1.
;;;
;;; Reading data, not text, is the point: an exit line in a comment or a
;;; string is not a datum, and a datum after the exit line, which would never
;;; run, is the last one. Data is all it sees, so a quoted '(exit 0) trips
;;; the second rule too: build such a list another way.
;;;
;;; With no suite named it passes: make test refuses that case itself.
(import (rnrs)
        (jsonparse-testing))

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

(define (written datum)
  (call-with-string-output-port (lambda (p) (write datum p))))

;; early-exits : Any -> (Listof Pair)
;; Every list in DATUM, DATUM itself and each list nested in it, whose car is
;; the symbol exit and which is not exactly (exit 1), in the order they
;; appear. It visits a list's elements, never its tails: in '(quit exit) the
;; tail (exit) is no exit form.
(define (early-exits datum)
  (if (pair? datum)
      (append (if (and (eq? (car datum) 'exit) (not (equal? datum '(exit 1))))
                  (list datum)
                  '())
              (let walk ((rest datum))
                (if (pair? rest)
                    (append (early-exits (car rest)) (walk (cdr rest)))
                    '())))
      '()))

;; complaints : String -> (Listof String)
;; What is wrong with the suite at PATH, in the order found: its last datum
;; first, then each early exit. Empty when the suite is right.
(define (complaints path)
  (let ((found (read-data path))
        (form (written suite-exit-form)))
    (case (car found)
      ((data)
       (let ((data (cadr found)))
         (if (null? data)
             (list (string-append path ": it holds no datum, so it cannot end with " form))
             (append
              (let ((last (car (reverse data))))
                (if (equal? last suite-exit-form)
                    '()
                    (list (string-append path ": its last datum is " (written last)
                                         ", not " form))))
              (map (lambda (exit-form)
                     (string-append path ": " (written exit-form)
                                    " before the last datum would end the suite before"
                                    " its verdict; only (exit 1) may exit early"))
                   (apply append (map early-exits (reverse (cdr (reverse data))))))))))
      (else
       (list (string-append path ": it cannot be read as data: " (cadr found)))))))

(define suites (cdr (command-line)))

(define all-complaints (apply append (map complaints suites)))

(for-each (lambda (c)
            (put-string (current-error-port) (string-append "check-suites: " c "\n")))
          all-complaints)

(when (null? all-complaints)
  (put-string (current-output-port)
              (string-append "check-suites: every suite ends with "
                             (written suite-exit-form) " ("
                             (number->string (length suites)) " checked)\n")))

(exit (if (null? all-complaints) 0 1))
