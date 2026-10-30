#!r6rs
;;; (jsonparse-testing machine): runs the jsonparse machine over bytes, for
;;; the suites that gate the grammar (ADR-0012).
;;;
;;;   the machines  generated-machine, (generated jsonparse)'s; and
;;;                 interpreted-machine, byte-machine's interpreter running
;;;                 the same graph, the other side of the differential
;;;   schedules     whole-schedule, chunk-schedule, random-schedule. A
;;;                 schedule is a list of (bytevector start end) feeds, the
;;;                 shape (byte-machine test property-driver)'s schedules-for
;;;                 returns, so its alphabet runs here too
;;;   a run         run-machine: every callback and every result of one
;;;                 schedule, in order
;;;   views         trace-content, what no schedule may change; and
;;;                 trace-outcome, the verdict
;;;   files         file-bytes, corpus-files
;;;   golden        golden-line, one corpus file's line in a golden file
;;;
;;; The stack that answers `context` is a list, as plain as a stack can be.
;;; It is the reference (jsonparse parser)'s bytevector stack is checked
;;; against (ADR-0004), so it shares no code with it.
;;;
;;; Test-only: it lives in tests/, on make test's library path.
(library (jsonparse-testing machine)
  (export generated-machine interpreted-machine
          whole-schedule chunk-schedule random-schedule
          run-machine trace-content trace-outcome
          file-bytes corpus-files golden-line)
  (import (rnrs)
          (only (chezscheme) directory-list)
          (byte-machine runtime)
          (byte-machine verify)
          (byte-machine interpret)
          (generated jsonparse)
          (jsonparse-grammar)
          (jsonparse-testing property))

  ;; --- the machines ---------------------------------------------------------

  ;; generated-machine : Compiled-Machine
  ;; The committed parser, src/generated/jsonparse.sls.
  (define generated-machine jsonparse-machine)

  ;; interpreted-machine : Compiled-Machine
  ;; The grammar as it stands in grammar/, run by byte-machine's interpreter.
  ;; tests/test-generated.sps holds the two to the same graph.
  (define interpreted-machine
    (make-interpreted-machine (verify-machine jsonparse-graph)))

  ;; --- schedules ------------------------------------------------------------

  ;; whole-schedule : Bytevector -> Schedule
  ;; BV in one feed.
  (define (whole-schedule bv)
    (list (list bv 0 (bytevector-length bv))))

  ;; chunk-schedule : Bytevector Positive-Integer -> Schedule
  ;; BV in feeds of K bytes, the last one shorter, as yajl's runner reads with
  ;; a K-byte buffer. An empty BV is one empty feed.
  (define (chunk-schedule bv k)
    (let ((len (bytevector-length bv)))
      (if (= len 0)
          (whole-schedule bv)
          (let loop ((start 0) (acc '()))
            (if (>= start len)
                (reverse acc)
                (let ((end (min len (+ start k))))
                  (loop end (cons (list bv start end) acc))))))))

  ;; random-schedule : Bytevector State -> (Pair Schedule State)
  ;; BV in feeds whose lengths are drawn from 0 to max(1, min(64, ceil(len/4)))
  ;; bytes, so some feeds are empty and a short input still falls in several
  ;; feeds, and the state after the last draw.
  (define (random-schedule bv state)
    (let* ((len (bytevector-length bv))
          (g (g-range 0 (max 1 (min 64 (div (+ len 3) 4))))))
      (let loop ((start 0) (s state) (acc '()))
        (if (>= start len)
            (cons (reverse (if (null? acc) (whole-schedule bv) acc)) s)
            (draw* s ((n g))
              (let ((end (min len (+ start n))))
                (loop end s (cons (list bv start end) acc))))))))

  ;; --- a run ----------------------------------------------------------------

  (define (copy bv from to)
    (let ((out (make-bytevector (- to from))))
      (bytevector-copy! bv from out 0 (- to from))
      out))

  ;; The bytes SCHEDULE feeds, in order: what stream offsets count.
  (define (schedule-stream schedule)
    (let* ((len (fold-left (lambda (n f) (+ n (- (caddr f) (cadr f)))) 0 schedule))
           (out (make-bytevector len)))
      (fold-left (lambda (at f)
                   (let ((n (- (caddr f) (cadr f))))
                     (bytevector-copy! (car f) (cadr f) out at n)
                     (+ at n)))
                 0 schedule)
      out))

  (define (result-entry tag r stream parser)
    (let ((e (parser-result-error r)))
      (list tag
            (parser-result-status r)
            (parser-result-next r)
            (parser-result-consumed r)
            (parser-result-stream-offset r)
            (and e (list (parser-error-code e)
                         (parser-error-offset e)
                         (parser-error-position-kind e)
                         (parser-error-node-name e)
                         (parser-error-span e)
                         (parser-error-span-offset e)
                         (and (parser-error-span e)
                              (copy stream (parser-error-span-offset e)
                                    (parser-error-offset e)))))
            (parser-state-name parser)
            (parser-active-span parser)
            (map (lambda (nm) (parser-field-ref parser nm))
                 '(depth depth-left cp mode)))))

  ;; run-machine : Compiled-Machine Schedule (Listof (Pair Symbol Nat)) -> Trace
  ;; Makes a parser of MACHINE with FIELDS as its settable fields' starting
  ;; values ('() for the defaults), feeds it SCHEDULE in order, and calls
  ;; parser-finish! unless a feed answered error. The trace lists, in order:
  ;;
  ;;   object-start object-end array-start array-end key-start key-end
  ;;   string-start string-end true false null number-end
  ;;                         one symbol per event
  ;;   (escape CP)           the escape event, with field cp
  ;;   (chars BYTES)         a chars-data fragment, copied
  ;;   (number BYTES)        a number-data fragment, copied
  ;;   (context ANSWER)      the stack's answer to `context`
  ;;   (feed STATUS NEXT CONSUMED STREAM-OFFSET ERROR STATE SPAN FIELDS)
  ;;   (finish STATUS NEXT CONSUMED STREAM-OFFSET ERROR STATE SPAN FIELDS)
  ;;                         STATE is parser-state-name, SPAN parser-active-span,
  ;;                         FIELDS the values of depth, depth-left, cp, mode
  ;;                         each result; ERROR is #f, or (CODE OFFSET
  ;;                         POSITION-KIND NODE-NAME SPAN SPAN-OFFSET
  ;;                         UNDELIVERED): UNDELIVERED is #f, or the bytes
  ;;                         from SPAN-OFFSET to OFFSET that SPAN took and
  ;;                         the error kept from its data callback
  ;;
  ;; Feeding stops at the first result that is not need-input. `context`
  ;; asked with an empty stack raises: the machine asks it only inside a
  ;; container.
  (define (run-machine machine schedule fields)
    (let* ((trace '())
           (stack '())
           (stream (schedule-stream schedule))
           (note! (lambda (x) (set! trace (cons x trace))))
           (event (lambda (name)
                    (lambda (p c) (note! name) callback-continue)))
           (open (lambda (name kind)
                   (lambda (p c)
                     (note! name)
                     (set! stack (cons kind stack))
                     callback-continue)))
           (close (lambda (name)
                    (lambda (p c)
                      (note! name)
                      (set! stack (cdr stack))
                      callback-continue)))
           (fragment (lambda (tag)
                       (lambda (p c bv from to)
                         (note! (list tag (copy bv from to)))
                         callback-continue)))
           (parser
            (make-parser machine
              (list (list 'object-start (open 'object-start 'object))
                    (list 'object-end (close 'object-end))
                    (list 'array-start (open 'array-start 'array))
                    (list 'array-end (close 'array-end))
                    (list 'key-start (event 'key-start))
                    (list 'key-end (event 'key-end))
                    (list 'string-start (event 'string-start))
                    (list 'string-end (event 'string-end))
                    (list 'true (event 'true))
                    (list 'false (event 'false))
                    (list 'null (event 'null))
                    (list 'escape (lambda (p c)
                                    (note! (list 'escape (parser-field-ref p 'cp)))
                                    callback-continue))
                    (list 'chars-data (fragment 'chars))
                    (list 'number-data (fragment 'number))
                    (list 'number-end (event 'number-end))
                    (list 'context (lambda (p c)
                                     (let ((answer (car stack)))
                                       (note! (list 'context answer))
                                       answer))))
              #f
              fields)))
      (let loop ((feeds schedule))
        (if (null? feeds)
            (note! (result-entry 'finish (parser-finish! parser) stream parser))
            (let* ((feed (car feeds))
                   (r (parser-feed! parser (car feed) (cadr feed) (caddr feed))))
              (note! (result-entry 'feed r stream parser))
              (when (eq? (parser-result-status r) 'need-input)
                (loop (cdr feeds))))))
      (reverse trace)))

  ;; --- views ----------------------------------------------------------------

  (define (fragment? x tag) (and (pair? x) (eq? (car x) tag)))

  (define (result? x) (and (pair? x) (memq (car x) '(feed finish))))

  ;; trace-content : Trace -> (Listof Entry)
  ;; What the input decides and the schedule must not: TRACE without its feed
  ;; results, adjacent fragments of one kind joined, and then its outcome.
  ;; An error keeps the bytes its span took since the last fragment, and
  ;; where that fragment fell depends on the feeds, so those bytes are
  ;; joined on as the span's last fragment.
  (define (trace-content trace)
    (let loop ((xs (append trace (undelivered trace))) (acc '()))
      (cond
       ((null? xs) (reverse (cons (trace-outcome trace) acc)))
       ((result? (car xs)) (loop (cdr xs) acc))
       ((and (pair? acc)
             (or (and (fragment? (car xs) 'chars) (fragment? (car acc) 'chars))
                 (and (fragment? (car xs) 'number) (fragment? (car acc) 'number))))
        (loop (cdr xs)
              (cons (list (caar xs) (join (cadar acc) (cadar xs))) (cdr acc))))
       (else (loop (cdr xs) (cons (car xs) acc))))))

  ;; The undelivered bytes of TRACE's error, as a fragment of its span: a
  ;; one-element list, or none.
  (define (undelivered trace)
    (let ((err (list-ref (last-result trace) 5)))
      (if (and err (list-ref err 4))
          (list (list (case (list-ref err 4) ((chars) 'chars) ((number) 'number))
                      (list-ref err 6)))
          '())))

  (define (last-result trace)
    (let loop ((xs trace) (r #f))
      (cond ((null? xs) r)
            ((result? (car xs)) (loop (cdr xs) (car xs)))
            (else (loop (cdr xs) r)))))

  (define (join a b)
    (let ((out (make-bytevector (+ (bytevector-length a) (bytevector-length b)))))
      (bytevector-copy! a 0 out 0 (bytevector-length a))
      (bytevector-copy! b 0 out (bytevector-length a) (bytevector-length b))
      out))

  ;; trace-outcome : Trace -> (U (List 'accepted) (List 'rejected Symbol Nat) (List 'other Symbol))
  ;; The verdict of TRACE's last result: accepted when it finished,
  ;; rejected with the error's code and offset, and other with the status
  ;; for anything else, which no input should give.
  (define (trace-outcome trace)
    (let* ((r (last-result trace))
           (status (cadr r))
           (err (list-ref r 5)))
      (cond ((eq? status 'finished) (list 'accepted))
            ((eq? status 'error) (list 'rejected (car err) (cadr err)))
            (else (list 'other status)))))

  ;; --- files ----------------------------------------------------------------

  ;; file-bytes : String -> Bytevector
  ;; The bytes of the file at PATH; an empty file is an empty bytevector.
  (define (file-bytes path)
    (let ((bv (call-with-port (open-file-input-port path) get-bytevector-all)))
      (if (eof-object? bv) (make-bytevector 0) bv)))

  ;; corpus-files : String String -> (Listof String)
  ;; The names in directory DIR that end in SUFFIX, sorted.
  (define (corpus-files dir suffix)
    (let ((n (string-length suffix)))
      (list-sort string<?
                 (filter (lambda (name)
                           (and (>= (string-length name) n)
                                (string=? suffix
                                          (substring name (- (string-length name) n)
                                                     (string-length name)))))
                         (directory-list dir)))))

  ;; --- golden lines ---------------------------------------------------------

  ;; golden-line : String Bytevector -> String
  ;; NAME's line in a golden file: the generated machine reads BV in one
  ;; feed, and the line is "NAME accepted", "NAME rejected CODE OFFSET", or
  ;; "NAME other STATUS" for a verdict no input should give.
  (define (golden-line name bv)
    (let ((o (trace-outcome (run-machine generated-machine (whole-schedule bv) '()))))
      (define (text x) (if (symbol? x) (symbol->string x) (number->string x)))
      (apply string-append name
             (map (lambda (x) (string-append " " (text x))) o)))))
