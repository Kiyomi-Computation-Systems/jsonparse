#!r6rs
;;; (jsonparse-testing string): runs (jsonparse parser) with a
;;; (jsonparse string) assembler and records each value it builds, for the
;;; suites that test the assembler.
;;;
;;;   assembling-handler  a handler with all fourteen procedures, which
;;;                       builds every key, string and number with the
;;;                       assembler its context holds, and notes each value
;;;   run-assembler       every value and every result of one schedule, in
;;;                       order
;;;
;;; Schedules are (jsonparse-testing machine)'s: lists of (bytevector start
;;; end) feeds.
;;;
;;; Test-only: it lives in tests/, on make test's library path.
(library (jsonparse-testing string)
  (export assembling-handler run-assembler)
  (import (rnrs)
          (jsonparse parser)
          (jsonparse string))

  ;; A session, the handler's context: the entries, newest first, and the
  ;; assembler.
  (define-record-type session (fields (mutable entries) assembler))

  (define (note! r entry) (session-entries-set! r (cons entry (session-entries r))))

  ;; assembling-handler : json-handler
  ;; Each procedure notes in its context, a session, the values it hears:
  ;;
  ;;   null object-start object-end array-start array-end
  ;;                          the procedure's name
  ;;   (boolean B)            B is #t or #f
  ;;   (key S) (string S)     the assembler's string, from key-end or
  ;;                          string-end
  ;;   (number N)             the assembler's number, a real
  ;;   (json-number TEXT)     the assembler's json-number, by its text
  ;;   stop                   the assembler's number was a stop, which
  ;;                          number-end returns to the parser
  ;;
  ;; chars, escape and number-chars give their parts to the assembler and
  ;; note nothing; string-start and key-start note nothing.
  (define assembling-handler
    (let ((named (lambda (name) (lambda (r) (note! r name)))))
      (make-json-handler
       'null (named 'null)
       'boolean (lambda (r b) (note! r (list 'boolean b)))
       'number-chars (lambda (r bv from to)
                       (json-assembler-number-chars! (session-assembler r) bv from to))
       'number-end (lambda (r)
                     (let ((n (json-assembler-number! (session-assembler r))))
                       (cond ((json-stop? n) (note! r 'stop) n)
                             ((json-number? n) (note! r (list 'json-number (json-number-text n))))
                             (else (note! r (list 'number n))))))
       'string-start (lambda (r) #f)
       'chars (lambda (r bv from to) (json-assembler-chars! (session-assembler r) bv from to))
       'escape (lambda (r scalar) (json-assembler-escape! (session-assembler r) scalar))
       'string-end (lambda (r) (note! r (list 'string (json-assembler-string! (session-assembler r)))))
       'object-start (named 'object-start)
       'key-start (lambda (r) #f)
       'key-end (lambda (r) (note! r (list 'key (json-assembler-string! (session-assembler r)))))
       'object-end (named 'object-end)
       'array-start (named 'array-start)
       'array-end (named 'array-end))))

  (define (result-entry tag r)
    (list tag (json-result-status r) (json-result-code r) (json-result-offset r)))

  ;; run-assembler : Schedule json-options -> Trace
  ;; Makes an assembler and a parser with assembling-handler, both under
  ;; OPTIONS, feeds the parser SCHEDULE in order, and finishes unless a feed
  ;; answered other than need-input. The trace is the handler's entries,
  ;; with each result in its place as
  ;;
  ;;   (feed STATUS CODE OFFSET)
  ;;   (finish STATUS CODE OFFSET)
  (define (run-assembler schedule options)
    (let* ((r (make-session '() (make-json-assembler options)))
           (parser (make-json-parser assembling-handler r options)))
      (let loop ((feeds schedule))
        (if (null? feeds)
            (note! r (result-entry 'finish (json-parser-finish! parser)))
            (let* ((feed (car feeds))
                   (res (json-parser-feed! parser (car feed) (cadr feed) (caddr feed))))
              (note! r (result-entry 'feed res))
              (when (eq? (json-result-status res) 'need-input)
                (loop (cdr feeds))))))
      (reverse (session-entries r)))))
