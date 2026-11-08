#!r6rs
;;; (jsonparse tree): builds a JSON value from bytes fed in chunks
;;; (ADR-0006, ADR-0010, ADR-0017).
;;;
;;; A builder holds a parser, an assembler and a stack of values. Feed it
;;; the input as it comes, finish it when the input ends, then take the
;;; value:
;;;
;;;   (define b (make-json-builder))
;;;   (json-builder-feed! b (string->utf8 "{\"a\": [1, null]}"))
;;;   (json-builder-finish! b)        ; a result whose status is finished
;;;   (json-builder-value b)          ; => (("a" . #(1 null)))
;;;
;;; The value is made of (ADR-0006, ADR-0011):
;;;
;;;   object        by the options' object-mode: an alist of (key . value)
;;;                 pairs in document order, every duplicate kept; or a
;;;                 fresh mutable hashtable keyed by string, the last
;;;                 duplicate winning
;;;   array         a vector
;;;   string, key   a string
;;;   number        by the options' number-mode
;;;   true, false   #t, #f
;;;   null          the options' null, the symbol null by default
;;;
;;; json-builder-feed! and json-builder-finish! answer with the parser's
;;; results: bad input is a result, never an exception. A number the
;;; assembler refuses ends the parse with its code, number-too-long or
;;; number-out-of-range, at the same offset however the input is split.
;;;
;;; json-builder-value gives the value once json-builder-finish! has
;;; answered finished, and raises at any other time. The builder keeps the
;;; value until it is reset. A parse that ends in an error drops what it
;;; built at once, so a bad document holds no memory.
;;;
;;; json-builder-reset! makes a builder as good as new, for the next
;;; document: it resets the parser and the assembler too.
;;;
;;; A builder given a procedure, EACH, hands it every top-level value as
;;; soon as the value is complete, and keeps none of them (ADR-0020):
;;;
;;;   (define b (make-json-builder (make-json-options 'stream 'values)
;;;                                (lambda (v) (display v))))
;;;   (json-builder-feed! b (string->utf8 "1 [2] {}"))   ; shows 1, #(2) and ()
;;;
;;; That is how a stream of values is read: the options' stream values
;;; needs EACH. EACH's return value is ignored, unless it is a stop
;;; (make-json-stop), which ends the parse with its code, as a handler
;;; procedure's does. json-builder-value raises for such a builder.
;;;
;;; The stack holds each value until its container ends, plus a slot for
;;; each open container. A container is built once, at its end, from the
;;; slots it fills: an array is one vector, an alist one pair per member
;;; and one per key and value, a hashtable is made with room for its
;;; members. The stack grows by doubling and never shrinks, like the
;;; assembler's buffer, and a slot is cleared as soon as its value moves
;;; into a container.
(library (jsonparse tree)
  (export make-json-builder json-builder?
          json-builder-feed! json-builder-finish!
          json-builder-value json-builder-reset!)
  (import (rnrs)
          (jsonparse options)
          (jsonparse parser)
          (jsonparse string))

  ;; --- the stack --------------------------------------------------------------

  ;; The handler's context. The stack's slots from 0 below top hold values
  ;; and marks; every slot from top up is #f. A mark is the mark before it:
  ;; an open container's slot holds its parent's mark, and mark is the slot
  ;; after the innermost one's, where its members begin. So mark is at
  ;; least 1 while a container is open, and 0 when none is: the outermost
  ;; container saves 0 and puts it back when it closes. EACH is #f, or the
  ;; procedure every top-level value goes to.
  (define-record-type state
    (fields (mutable stack state-stack state-stack-set!)
            (mutable top state-top state-top-set!)
            (mutable mark state-mark state-mark-set!)
            (immutable assembler state-assembler)
            (immutable hashtables? state-hashtables?)
            (immutable null state-null)
            (immutable each state-each))
    (sealed #t))

  (define initial-size 64)

  (define (push! s v)
    (let ((stack (state-stack s)) (top (state-top s)))
      (if (fx<? top (vector-length stack))
          (vector-set! stack top v)
          (let ((new (make-vector (fx* 2 (vector-length stack)) #f)))
            (do ((i 0 (fx+ i 1))) ((fx=? i top))
              (vector-set! new i (vector-ref stack i)))
            (vector-set! new top v)
            (state-stack-set! s new)))
      (state-top-set! s (fx+ top 1))))

  (define (open! s)
    (push! s (state-mark s))
    (state-mark-set! s (state-top s)))

  ;; Clears the slots from FROM below the top, and makes FROM the top.
  (define (drop! s from)
    (let ((stack (state-stack s)))
      (do ((i from (fx+ i 1))) ((fx=? i (state-top s)))
        (vector-set! stack i #f))
      (state-top-set! s from)))

  ;; Replaces the innermost open container's slot and members with V,
  ;; built from them, and goes back to its parent's mark.
  (define (close! s v)
    (let* ((stack (state-stack s))
           (slot (fx- (state-mark s) 1)))
      (state-mark-set! s (vector-ref stack slot))
      (vector-set! stack slot v)
      (drop! s (fx+ slot 1))))

  (define (array-end! s)
    (let* ((stack (state-stack s))
           (mark (state-mark s))
           (n (fx- (state-top s) mark))
           (v (make-vector n)))
      (do ((i 0 (fx+ i 1))) ((fx=? i n))
        (vector-set! v i (vector-ref stack (fx+ mark i))))
      (close! s v)))

  ;; The members sit as key, value, key, value, ... from the mark.
  (define (object-end! s)
    (let ((stack (state-stack s))
          (mark (state-mark s))
          (top (state-top s)))
      (close! s
              (if (state-hashtables? s)
                  (let ((h (make-hashtable string-hash string=?
                                           (fxdiv (fx- top mark) 2))))
                    (do ((i mark (fx+ i 2))) ((fx=? i top) h)
                      (hashtable-set! h (vector-ref stack i)
                                      (vector-ref stack (fx+ i 1)))))
                  (let loop ((i (fx- top 2)) (members '()))
                    (if (fx<? i mark)
                        members
                        (loop (fx- i 2)
                              (cons (cons (vector-ref stack i)
                                          (vector-ref stack (fx+ i 1)))
                                    members))))))))

  (define (empty! s)
    (drop! s 0)
    (state-mark-set! s 0)
    (json-assembler-reset! (state-assembler s)))

  ;; --- the handler ------------------------------------------------------------

  (define (text! s) (push! s (json-assembler-string! (state-assembler s))))

  (define handler
    (make-json-handler
     'null (lambda (s) (push! s (state-null s)))
     'boolean push!
     'number-chars (lambda (s bv start end)
                     (json-assembler-number-chars! (state-assembler s) bv start end))
     'number-end (lambda (s)
                   (let ((n (json-assembler-number! (state-assembler s))))
                     (if (json-stop? n) n (push! s n))))
     'chars (lambda (s bv start end)
              (json-assembler-chars! (state-assembler s) bv start end))
     'escape (lambda (s scalar) (json-assembler-escape! (state-assembler s) scalar))
     'string-end text!
     'object-start open!
     'key-end text!
     'object-end object-end!
     'array-start open!
     'array-end array-end!))

  ;; With no container open, the value just pushed is a whole top-level
  ;; value: it leaves the stack for EACH, whose answer goes to the parser.
  (define (top-level! s)
    (when (fx=? (state-mark s) 0)
      (let ((v (vector-ref (state-stack s) 0)))
        (drop! s 0)
        ((state-each s) v))))

  (define each-handler
    (make-json-handler
     'null (lambda (s) (push! s (state-null s)) (top-level! s))
     'boolean (lambda (s b) (push! s b) (top-level! s))
     'number-chars (lambda (s bv start end)
                     (json-assembler-number-chars! (state-assembler s) bv start end))
     'number-end (lambda (s)
                   (let ((n (json-assembler-number! (state-assembler s))))
                     (if (json-stop? n)
                         n
                         (begin (push! s n) (top-level! s)))))
     'chars (lambda (s bv start end)
              (json-assembler-chars! (state-assembler s) bv start end))
     'escape (lambda (s scalar) (json-assembler-escape! (state-assembler s) scalar))
     'string-end (lambda (s) (text! s) (top-level! s))
     'object-start open!
     'key-end text!
     'object-end (lambda (s) (object-end! s) (top-level! s))
     'array-start open!
     'array-end (lambda (s) (array-end! s) (top-level! s))))

  ;; --- the builder ------------------------------------------------------------

  ;; json-builder? : Any -> Boolean
  (define-record-type (json-builder new-json-builder json-builder?)
    (fields (immutable parser builder-parser)
            (immutable state builder-state)
            ;; The status of the last result, need-input before the first.
            (mutable status builder-status builder-status-set!))
    (sealed #t)
    (opaque #t))

  (define default-options (make-json-options))

  ;; make-json-builder : [json-options [(Any -> Any)]] -> json-builder
  ;; A builder under OPTIONS (default (make-json-options)): its parser's
  ;; depth limit and stream, its assembler's number mode and digit limit,
  ;; and its object mode and null. Given EACH, it hands EACH every
  ;; top-level value and keeps none. Stream values needs EACH.
  (define make-json-builder
    (case-lambda
      (() (make-json-builder default-options))
      ((options)
       (unless (json-options? options)
         (assertion-violation 'make-json-builder "not an options record" options))
       (when (eq? (json-options-stream options) 'values)
         (assertion-violation 'make-json-builder
                              "stream values needs a procedure for each value"))
       (build options #f))
      ((options each)
       (unless (json-options? options)
         (assertion-violation 'make-json-builder "not an options record" options))
       (unless (procedure? each)
         (assertion-violation 'make-json-builder "not a procedure" each))
       (build options each))))

  (define (build options each)
    (let ((s (make-state (make-vector initial-size #f) 0 0
                         (make-json-assembler options)
                         (eq? (json-options-object-mode options) 'hashtable)
                         (json-options-null options)
                         each)))
      (new-json-builder (make-json-parser (if each each-handler handler) s options)
                        s 'need-input)))

  (define (check-builder who b)
    (unless (json-builder? b)
      (assertion-violation who "not a builder" b)))

  ;; Notes R's status, and drops what was built if it is an error.
  (define (noted b r)
    (builder-status-set! b (json-result-status r))
    (when (eq? (json-result-status r) 'error)
      (empty! (builder-state b)))
    r)

  ;; json-builder-feed! : json-builder Bytevector [Nonnegative-Fixnum Nonnegative-Fixnum] -> json-result
  ;; Parses the bytes of BV from START up to END, or all of BV, building as
  ;; it goes. Raises unless 0 <= START <= END <= (bytevector-length BV).
  (define json-builder-feed!
    (case-lambda
      ((b bv)
       (check-builder 'json-builder-feed! b)
       (unless (bytevector? bv)
         (assertion-violation 'json-builder-feed! "not a bytevector" bv))
       (json-builder-feed! b bv 0 (bytevector-length bv)))
      ((b bv start end)
       (check-builder 'json-builder-feed! b)
       (unless (bytevector? bv)
         (assertion-violation 'json-builder-feed! "not a bytevector" bv))
       (unless (and (fixnum? start) (fixnum? end)
                    (fx<=? 0 start end (bytevector-length bv)))
         (assertion-violation 'json-builder-feed! "the range is not within the bytevector"
                              start end (bytevector-length bv)))
       (noted b (json-parser-feed! (builder-parser b) bv start end)))))

  ;; json-builder-finish! : json-builder -> json-result
  ;; Tells B the input has ended. Once this answers finished, the value is
  ;; ready.
  (define (json-builder-finish! b)
    (check-builder 'json-builder-finish! b)
    (noted b (json-parser-finish! (builder-parser b))))

  ;; json-builder-value : json-builder -> Any
  ;; The value B built. Raises unless B's last result was finished, and
  ;; for a builder that hands its values to a procedure.
  (define (json-builder-value b)
    (check-builder 'json-builder-value b)
    (when (state-each (builder-state b))
      (assertion-violation 'json-builder-value
                           "this builder hands each value to its procedure and keeps none"))
    (unless (eq? (builder-status b) 'finished)
      (assertion-violation 'json-builder-value
                           "there is no value until finish answers finished"
                           (builder-status b)))
    (vector-ref (state-stack (builder-state b)) 0))

  ;; json-builder-reset! : json-builder -> Void
  ;; Makes B as good as new, for the next document, and drops its value.
  (define (json-builder-reset! b)
    (check-builder 'json-builder-reset! b)
    (json-parser-reset! (builder-parser b))
    (empty! (builder-state b))
    (builder-status-set! b 'need-input)))
