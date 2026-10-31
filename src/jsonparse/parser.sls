#!r6rs
;;; (jsonparse parser): the push parser the low layer is built on (ADR-0010).
;;;
;;; Feed it bytes in chunks of any size. As the JSON goes by it calls the
;;; procedures of a handler, and each feed and finish answers with a result.
;;; Bad input is a result, never an exception.
;;;
;;; A handler is made from name and procedure pairs, in YAJL's order:
;;;
;;;   null          (context)
;;;   boolean       (context b)              b is #t or #f
;;;   number-chars  (context bv start end)   part of a number's text
;;;   number-end    (context)                the number is complete
;;;   string-start  (context)
;;;   chars         (context bv start end)   part of a string's or a key's
;;;                                          text between escapes, as
;;;                                          UTF-8
;;;   escape        (context scalar)         one escaped character, as a
;;;                                          Unicode scalar value. A
;;;                                          surrogate pair arrives as one
;;;                                          call, once its low half is read
;;;   string-end    (context)
;;;   object-start  (context)
;;;   key-start     (context)                a key's text arrives as a
;;;   key-end       (context)                string's does, by chars and
;;;                                          escape
;;;   object-end    (context)
;;;   array-start   (context)
;;;   array-end     (context)
;;;
;;; Any of them may be left out. The machine then has no callback for it,
;;; except for the four container procedures: the stack's own callbacks run
;;; either way. CONTEXT is the value given to make-json-parser.
;;;
;;; Text arrives in parts:
;;;
;;;   - The bytes of `bv` from `start` to `end` are the caller's own, never
;;;     copied, and are the procedure's to read only while it runs: copy what
;;;     is needed.
;;;   - A text may arrive in several parts, split wherever the feeds and
;;;     escapes fall. No part is empty: the empty string calls only
;;;     string-start and string-end.
;;;   - A part may end inside a character, whose other bytes come in the
;;;     next part. The machine has checked a part's bytes only as far as they
;;;     go, so decode text after joining its parts. If the character is never
;;;     completed, the parse ends in an error after the part was delivered.
;;;
;;; A procedure's return value is ignored, except a stop: returning
;;; (make-json-stop CODE) ends the parse with the error CODE, at the stream
;;; offset where the procedure ran. For the procedures that receive parts,
;;; that offset depends on where the feeds split the text. A stop from
;;; number-end, string-end or key-end lands at the same offset however the
;;; input is split. json-stop? recognises a stop, so that a procedure
;;; calling another can pass its stop on.
;;;
;;; If a procedure raises, or escapes through a continuation, the exception
;;; or escape passes out of the feed. Feeding or finishing the parser then
;;; raises until it is reset. Feeding, finishing or resetting a parser from
;;; inside its own procedures raises. A reset does not tell the handler:
;;; whatever its context holds for a text or value left unfinished, the
;;; caller resets too.
;;;
;;; A result has a status, a code and an offset:
;;;
;;;   need-input  every byte was read; feed more, or finish. The code is #f,
;;;               the offset the bytes read so far
;;;   finished    the input ended after a whole value. The code is #f
;;;   error       the input is not JSON, or a procedure stopped the parse.
;;;               The code says why, such as unexpected-byte or
;;;               nesting-too-deep, and the offset is where, in bytes from
;;;               the start of the stream
;;;
;;; finished and error stick: feeding or finishing again gives the same
;;; status and code until the parser is reset. A reset parser is as good as
;;; new, with the same handler, context and options.
;;;
;;; The machine asks which container a value is in, and this library answers
;;; from its own stack (ADR-0004): one byte per open container, in a
;;; bytevector sized from the depth limit when the parser is made
;;; (ADR-0005). Parsing allocates nothing per byte, per value or per
;;; container. It allocates a fixed amount per feed and per finish, most of
;;; it byte-machine's own result, plus what the handler allocates.
(library (jsonparse parser)
  (export make-json-handler json-handler?
          make-json-stop json-stop?
          make-json-parser json-parser?
          json-parser-feed! json-parser-finish! json-parser-reset!
          json-parser-offset
          json-result? json-result-status json-result-code json-result-offset)
  (import (rnrs)
          (byte-machine runtime)
          (generated jsonparse)
          (jsonparse options))

  ;; --- handlers ---------------------------------------------------------------

  ;; The handler's names, in YAJL's order. A handler keeps its procedures in
  ;; a vector in this order, #f where one was left out.
  (define handler-names
    '(null boolean number-chars number-end
      string-start chars escape string-end
      object-start key-start key-end object-end
      array-start array-end))

  (define (handler-index name)
    (let loop ((names handler-names) (i 0))
      (cond ((null? names) #f)
            ((eq? (car names) name) i)
            (else (loop (cdr names) (+ i 1))))))

  ;; json-handler? : Any -> Boolean
  (define-record-type (json-handler new-json-handler json-handler?)
    (fields (immutable procedures handler-procedures))
    (sealed #t)
    (opaque #t))

  ;; make-json-handler : (Listof Any) -> json-handler
  ;; A handler from NAME PROCEDURE pairs. Raises for an unknown name, a name
  ;; given twice, a name with no procedure, and a value that is not a
  ;; procedure: a misspelt name cannot leave a procedure silently unused.
  (define (make-json-handler . args)
    (let ((procedures (make-vector (length handler-names) #f)))
      (let loop ((xs args))
        (cond
         ((null? xs) (new-json-handler procedures))
         ((null? (cdr xs))
          (assertion-violation 'make-json-handler "a name has no procedure" (car xs)))
         (else
          (let ((i (handler-index (car xs))) (proc (cadr xs)))
            (cond
             ((not i) (assertion-violation 'make-json-handler "unknown name" (car xs)))
             ((vector-ref procedures i)
              (assertion-violation 'make-json-handler "a name is given twice" (car xs)))
             ((not (procedure? proc))
              (assertion-violation 'make-json-handler "not a procedure" (car xs) proc))
             (else
              (vector-set! procedures i proc)
              (loop (cddr xs))))))))))

  (define (handler-ref handler name)
    (vector-ref (handler-procedures handler) (handler-index name)))

  ;; --- stops ------------------------------------------------------------------

  ;; json-stop? : Any -> Boolean
  ;; A stop holds the failure byte-machine is handed, made once, here.
  (define-record-type (json-stop new-json-stop json-stop?)
    (fields (immutable failure json-stop-failure))
    (sealed #t)
    (opaque #t))

  (define (code-name? sym)
    (let ((s (symbol->string sym)))
      (define (lower? c) (and (char<=? #\a c) (char<=? c #\z)))
      (define (rest? c) (or (lower? c) (and (char<=? #\0 c) (char<=? c #\9)) (char=? c #\-)))
      (and (> (string-length s) 0)
           (lower? (string-ref s 0))
           (let loop ((i 1))
             (or (= i (string-length s))
                 (and (rest? (string-ref s i)) (loop (+ i 1))))))))

  ;; make-json-stop : Symbol -> json-stop
  ;; What a handler procedure returns to end the parse with the error CODE.
  ;; CODE is a symbol spelt [a-z][a-z0-9-]*, or it raises.
  (define (make-json-stop code)
    (unless (and (symbol? code) (code-name? code))
      (assertion-violation 'make-json-stop "the code is not a symbol spelt [a-z][a-z0-9-]*" code))
    (new-json-stop (make-callback-failure code #f)))

  (define (outcome x)
    (if (json-stop? x) (json-stop-failure x) callback-continue))

  ;; --- the stack --------------------------------------------------------------
  ;;
  ;; The parser's own state, the context byte-machine hands every callback:
  ;; the stack and how many entries it holds, the high half of a surrogate
  ;; pair, and the caller's context.

  (define-record-type state
    (fields (immutable stack) (mutable depth) (mutable high) (immutable user)))

  (define object-entry 0)
  (define array-entry 1)

  (define (push! s entry)
    (bytevector-u8-set! (state-stack s) (state-depth s) entry)
    (state-depth-set! s (fx+ (state-depth s) 1)))

  (define (pop! s)
    (state-depth-set! s (fx- (state-depth s) 1)))

  ;; The machine asks only inside a container, after a value.
  (define (answer-context p s)
    (if (fx=? (bytevector-u8-ref (state-stack s) (fx- (state-depth s) 1)) object-entry)
        'object
        'array))

  ;; --- the callbacks ------------------------------------------------------------
  ;;
  ;; Each takes byte-machine's (parser context ...) and calls the handler's
  ;; procedure with the caller's context. An open pushes before its
  ;; procedure runs, and a close pops before its procedure runs.

  (define (opener entry proc)
    (if proc
        (lambda (p s) (push! s entry) (outcome (proc (state-user s))))
        (lambda (p s) (push! s entry) callback-continue)))

  (define (closer proc)
    (if proc
        (lambda (p s) (pop! s) (outcome (proc (state-user s))))
        (lambda (p s) (pop! s) callback-continue)))

  (define (event proc)
    (lambda (p s) (outcome (proc (state-user s)))))

  (define (boolean-event proc b)
    (lambda (p s) (outcome (proc (state-user s) b))))

  (define (fragment proc)
    (lambda (p s bv start end) (outcome (proc (state-user s) bv start end))))

  ;; byte-machine hands over an empty part when the text between two escapes
  ;; is empty, or a whole string is. The handler never sees one.
  (define (text-fragment proc)
    (lambda (p s bv start end)
      (if (fx=? start end)
          callback-continue
          (outcome (proc (state-user s) bv start end)))))

  ;; The machine announces each UTF-16 code unit in field cp, and has
  ;; already checked that a high half is followed by a low half.
  (define (escape proc)
    (lambda (p s)
      (let ((unit (parser-field-ref p 'cp)))
        (cond
         ((fx<=? #xD800 unit #xDBFF)
          (state-high-set! s unit)
          callback-continue)
         ((fx<=? #xDC00 unit #xDFFF)
          (outcome (proc (state-user s)
                         (fx+ #x10000
                              (fx+ (fxarithmetic-shift-left (fx- (state-high s) #xD800) 10)
                                   (fx- unit #xDC00))))))
         (else (outcome (proc (state-user s) unit)))))))

  ;; The machine's bindings for HANDLER: the stack's always, the rest only
  ;; for the procedures it has.
  (define (bindings handler)
    (define (h name) (handler-ref handler name))
    (define (optional name make . extra)
      (let ((proc (h name)))
        (if proc (list (list name (apply make proc extra))) '())))
    (append
     (list (list 'object-start (opener object-entry (h 'object-start)))
           (list 'object-end (closer (h 'object-end)))
           (list 'array-start (opener array-entry (h 'array-start)))
           (list 'array-end (closer (h 'array-end)))
           (list 'context answer-context))
     (optional 'null event)
     (let ((proc (h 'boolean)))
       (if proc
           (list (list 'true (boolean-event proc #t))
                 (list 'false (boolean-event proc #f)))
           '()))
     (let ((proc (h 'number-chars)))
       (if proc (list (list 'number-data (fragment proc))) '()))
     (optional 'number-end event)
     (optional 'string-start event)
     (let ((proc (h 'chars)))
       (if proc (list (list 'chars-data (text-fragment proc))) '()))
     (optional 'escape escape)
     (optional 'string-end event)
     (optional 'key-start event)
     (optional 'key-end event)))

  ;; --- parsers ------------------------------------------------------------------

  ;; json-parser? : Any -> Boolean
  (define-record-type (json-parser new-json-parser json-parser?)
    (fields (immutable machine json-parser-machine)
            (immutable state json-parser-state))
    (sealed #t)
    (opaque #t))

  (define default-options (make-json-options))

  ;; make-json-parser : json-handler [Any [json-options]] -> json-parser
  ;; A parser that calls HANDLER's procedures with CONTEXT (default #f),
  ;; under OPTIONS (default (make-json-options)).
  (define make-json-parser
    (case-lambda
      ((handler) (make-json-parser handler #f default-options))
      ((handler context) (make-json-parser handler context default-options))
      ((handler context options)
       (unless (json-handler? handler)
         (assertion-violation 'make-json-parser "not a handler" handler))
       (unless (json-options? options)
         (assertion-violation 'make-json-parser "not an options record" options))
       (let* ((limit (json-options-depth-limit options))
              (s (make-state (make-bytevector limit 0) 0 0 context)))
         (new-json-parser
          (make-parser jsonparse-machine (bindings handler) s
                       (list (cons 'depth-left limit)))
          s)))))

  ;; json-result? : Any -> Boolean
  ;; json-result-status : json-result -> (U 'need-input 'finished 'error)
  ;; json-result-code : json-result -> (Option Symbol)
  ;; json-result-offset : json-result -> Nonnegative-Integer
  (define-record-type (json-result make-json-result json-result?)
    (fields (immutable status json-result-status)
            (immutable code json-result-code)
            (immutable offset json-result-offset))
    (sealed #t)
    (opaque #t))

  (define (result r)
    (let ((e (parser-result-error r)))
      (if e
          (make-json-result 'error (parser-error-code e) (parser-error-offset e))
          (make-json-result (parser-result-status r) #f (parser-result-stream-offset r)))))

  ;; Refusals of the calling code's mistakes. byte-machine refuses a parser
  ;; fed from inside its own procedures, or after one raised, with its own
  ;; condition type, which callers can't name; these come first.
  (define (check-parser who parser)
    (unless (json-parser? parser)
      (assertion-violation who "not a parser" parser)))

  (define (check-not-busy who parser)
    (when (eq? (parser-lifecycle (json-parser-machine parser)) 'busy)
      (assertion-violation who "called from inside one of the parser's own handler procedures")))

  (define (check-usable who parser)
    (check-not-busy who parser)
    (when (eq? (parser-lifecycle (json-parser-machine parser)) 'poisoned)
      (assertion-violation who "a handler procedure raised or escaped: reset the parser before using it again")))

  ;; json-parser-feed! : json-parser Bytevector [Nonnegative-Fixnum Nonnegative-Fixnum] -> json-result
  ;; Parses the bytes of BV from START up to END, or all of BV. Raises
  ;; unless 0 <= START <= END <= (bytevector-length BV).
  (define json-parser-feed!
    (case-lambda
      ((parser bv)
       (check-parser 'json-parser-feed! parser)
       (unless (bytevector? bv)
         (assertion-violation 'json-parser-feed! "not a bytevector" bv))
       (json-parser-feed! parser bv 0 (bytevector-length bv)))
      ((parser bv start end)
       (check-parser 'json-parser-feed! parser)
       (unless (bytevector? bv)
         (assertion-violation 'json-parser-feed! "not a bytevector" bv))
       (unless (and (fixnum? start) (fixnum? end)
                    (fx<=? 0 start end (bytevector-length bv)))
         (assertion-violation 'json-parser-feed! "the range is not within the bytevector"
                              start end (bytevector-length bv)))
       (check-usable 'json-parser-feed! parser)
       (result (parser-feed! (json-parser-machine parser) bv start end)))))

  ;; json-parser-finish! : json-parser -> json-result
  ;; Tells PARSER the input has ended.
  (define (json-parser-finish! parser)
    (check-parser 'json-parser-finish! parser)
    (check-usable 'json-parser-finish! parser)
    (result (parser-finish! (json-parser-machine parser))))

  ;; json-parser-reset! : json-parser -> Void
  ;; Makes PARSER as good as new, for the next stream.
  (define (json-parser-reset! parser)
    (check-parser 'json-parser-reset! parser)
    (check-not-busy 'json-parser-reset! parser)
    (parser-reset! (json-parser-machine parser))
    (state-depth-set! (json-parser-state parser) 0)
    (state-high-set! (json-parser-state parser) 0))

  ;; json-parser-offset : json-parser -> Nonnegative-Integer
  ;; The bytes PARSER has read since it was made or reset. A handler
  ;; procedure that reaches its parser through its context may call it.
  (define (json-parser-offset parser)
    (check-parser 'json-parser-offset parser)
    (parser-stream-offset (json-parser-machine parser))))
