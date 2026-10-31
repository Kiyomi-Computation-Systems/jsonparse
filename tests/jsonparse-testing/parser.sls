#!r6rs
;;; (jsonparse-testing parser): runs (jsonparse parser) over a schedule and
;;; records every call its handler gets, for the suites that test it.
;;;
;;;   recording-handler  a handler with all fourteen procedures, each noting
;;;                      its call in the journal its context is
;;;   run-parser         every handler call and every result of one schedule,
;;;                      in order
;;;   machine->parser    the trace (jsonparse-testing machine)'s run-machine
;;;                      records, in the parser's terms: what the parser
;;;                      must record on the same schedule. Its list stack is
;;;                      the reference the parser's stack is checked against
;;;                      (ADR-0004)
;;;   parser-outcome     a trace's verdict
;;;
;;; Schedules are (jsonparse-testing machine)'s: lists of (bytevector start
;;; end) feeds.
;;;
;;; Test-only: it lives in tests/, on make test's library path.
(library (jsonparse-testing parser)
  (export recording-handler run-parser machine->parser parser-outcome)
  (import (rnrs)
          (jsonparse parser))

  (define (copy bv from to)
    (let ((out (make-bytevector (- to from))))
      (bytevector-copy! bv from out 0 (- to from))
      out))

  ;; A journal is a one-field record holding the entries, newest first.
  (define-record-type journal (fields (mutable entries)))

  (define (note! j entry) (journal-entries-set! j (cons entry (journal-entries j))))

  ;; recording-handler : json-handler
  ;; Each procedure notes one entry in its context, a journal:
  ;;
  ;;   null number-end string-start string-end object-start key-start
  ;;   key-end object-end array-start array-end
  ;;                          the procedure's name
  ;;   (boolean B)            B is #t or #f
  ;;   (number-chars BYTES)   the range, copied
  ;;   (chars BYTES)          the range, copied
  ;;   (escape SCALAR)
  (define recording-handler
    (let ((named (lambda (name) (lambda (j) (note! j name))))
          (text (lambda (tag) (lambda (j bv from to) (note! j (list tag (copy bv from to)))))))
      (make-json-handler
       'null (named 'null)
       'boolean (lambda (j b) (note! j (list 'boolean b)))
       'number-chars (text 'number-chars)
       'number-end (named 'number-end)
       'string-start (named 'string-start)
       'chars (text 'chars)
       'escape (lambda (j scalar) (note! j (list 'escape scalar)))
       'string-end (named 'string-end)
       'object-start (named 'object-start)
       'key-start (named 'key-start)
       'key-end (named 'key-end)
       'object-end (named 'object-end)
       'array-start (named 'array-start)
       'array-end (named 'array-end))))

  (define (result-entry tag r)
    (list tag (json-result-status r) (json-result-code r) (json-result-offset r)))

  ;; run-parser : Schedule json-options -> Trace
  ;; Makes a parser with recording-handler and OPTIONS, feeds it SCHEDULE in
  ;; order, and finishes unless a feed answered other than need-input. The
  ;; trace is the handler's entries, with each result in its place as
  ;;
  ;;   (feed STATUS CODE OFFSET)
  ;;   (finish STATUS CODE OFFSET)
  (define (run-parser schedule options)
    (let* ((j (make-journal '()))
           (parser (make-json-parser recording-handler j options)))
      (let loop ((feeds schedule))
        (if (null? feeds)
            (note! j (result-entry 'finish (json-parser-finish! parser)))
            (let* ((feed (car feeds))
                   (r (json-parser-feed! parser (car feed) (cadr feed) (caddr feed))))
              (note! j (result-entry 'feed r))
              (when (eq? (json-result-status r) 'need-input)
                (loop (cdr feeds))))))
      (reverse (journal-entries j))))

  ;; machine->parser : Trace -> Trace
  ;; A run-machine trace as run-parser records the same schedule:
  ;;
  ;;   true, false            (boolean #t), (boolean #f)
  ;;   (number BYTES)         (number-chars BYTES)
  ;;   (chars BYTES)          the same, or nothing when BYTES is empty
  ;;   (escape UNIT)          (escape UNIT) for a unit outside the
  ;;                          surrogates; nothing for a high half; for a low
  ;;                          half, (escape SCALAR) of the pair it ends
  ;;   (context ANSWER)       nothing: the stack is the parser's own
  ;;   a result               (feed|finish STATUS CODE OFFSET): the error's
  ;;                          code and offset, or #f and the stream offset
  ;;   any other event        itself
  (define (machine->parser trace)
    (let loop ((xs trace) (high #f) (acc '()))
      (if (null? xs)
          (reverse acc)
          (let ((x (car xs)))
            (cond
             ((eq? x 'true) (loop (cdr xs) high (cons '(boolean #t) acc)))
             ((eq? x 'false) (loop (cdr xs) high (cons '(boolean #f) acc)))
             ((symbol? x) (loop (cdr xs) high (cons x acc)))
             (else
              (case (car x)
                ((number) (loop (cdr xs) high (cons (list 'number-chars (cadr x)) acc)))
                ((chars) (loop (cdr xs) high
                               (if (= (bytevector-length (cadr x)) 0) acc (cons x acc))))
                ((escape)
                 (let ((unit (cadr x)))
                   (cond
                    ((<= #xD800 unit #xDBFF) (loop (cdr xs) unit acc))
                    ((<= #xDC00 unit #xDFFF)
                     (loop (cdr xs) #f
                           (cons (list 'escape (+ #x10000 (* (- high #xD800) #x400)
                                                  (- unit #xDC00)))
                                 acc)))
                    (else (loop (cdr xs) high (cons x acc))))))
                ((context) (loop (cdr xs) high acc))
                ((feed finish)
                 (let ((status (list-ref x 1)) (err (list-ref x 5)))
                   (loop (cdr xs) high
                         (cons (if err
                                   (list (car x) status (car err) (cadr err))
                                   (list (car x) status #f (list-ref x 4)))
                               acc))))
                (else (assertion-violation 'machine->parser "an entry run-machine never records" x)))))))))

  ;; parser-outcome : Trace -> (U (List 'accepted) (List 'rejected Symbol Nat) (List 'other Symbol))
  ;; The verdict of a run-parser trace's last result.
  (define (parser-outcome trace)
    (let ((r (let loop ((xs trace) (r #f))
               (cond ((null? xs) r)
                     ((and (pair? (car xs)) (memq (caar xs) '(feed finish))) (loop (cdr xs) (car xs)))
                     (else (loop (cdr xs) r))))))
      (case (cadr r)
        ((finished) (list 'accepted))
        ((error) (list 'rejected (caddr r) (cadddr r)))
        (else (list 'other (cadr r)))))))
