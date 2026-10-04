;;; (bmjson dom) -- a DOM builder over the generated JSON parser's event stream.
;;;
;;; Representation: object -> alist in document order, array -> vector,
;;; string -> string, number -> Scheme number (exact integers, bignums
;;; included; inexact for fractions/exponents), true/false -> #t/#f,
;;; null -> the symbol null. `{}` is '() and `[]` is #(), so neither collides
;;; with null.
;;;
;;; The container stack lives here, in user-context; the parser asks for it
;;; through the `context` decision callback.
(library (bmjson dom)
  (export make-json-dom json-dom-feed! json-dom-finish! json-parse
          json-parse-chunked)
  (import (rnrs) (byte-machine runtime) (generated json))

  ;; frame: #(kind items pending-key)
  (define-record-type st
    (fields (mutable stack) (mutable result) (mutable buf) (mutable hi)))

  (define (fresh-buf! s)
    (let-values (((port extract) (open-bytevector-output-port)))
      (st-buf-set! s (cons port extract))))
  (define (buf-port s) (car (st-buf s)))
  (define (buf-take! s) ((cdr (st-buf s))))

  (define (emit! s v)
    (let ((stack (st-stack s)))
      (if (null? stack)
          (st-result-set! s v)
          (let ((f (car stack)))
            (if (eq? (vector-ref f 0) 'array)
                (vector-set! f 1 (cons v (vector-ref f 1)))
                (begin
                  (vector-set! f 1 (cons (cons (vector-ref f 2) v) (vector-ref f 1)))
                  (vector-set! f 2 #f)))))))

  (define (push! s kind) (st-stack-set! s (cons (vector kind '() #f) (st-stack s))))
  (define (pop! s)
    (let ((f (car (st-stack s))))
      (st-stack-set! s (cdr (st-stack s)))
      (reverse (vector-ref f 1))))

  (define (ev f) (lambda (p s) (f s) callback-continue))

  (define (encode-code-unit! s cu)
    (cond ((<= #xD800 cu #xDBFF) (st-hi-set! s cu))
          (else
           (let ((cp (if (<= #xDC00 cu #xDFFF)
                         (+ #x10000 (* (- (st-hi s) #xD800) #x400) (- cu #xDC00))
                         cu)))
             (put-bytevector (buf-port s) (string->utf8 (string (integer->char cp))))))))

  (define bindings
    (list
     (list 'object-start (ev (lambda (s) (push! s 'object))))
     (list 'array-start  (ev (lambda (s) (push! s 'array))))
     (list 'object-end   (ev (lambda (s) (emit! s (pop! s)))))
     (list 'array-end    (ev (lambda (s) (emit! s (list->vector (pop! s))))))
     (list 'context
           (lambda (p s) (vector-ref (car (st-stack s)) 0)))
     (list 'key-start    (ev fresh-buf!))
     (list 'string-start (ev fresh-buf!))
     (list 'key-end
           (ev (lambda (s) (vector-set! (car (st-stack s)) 2 (utf8->string (buf-take! s))))))
     (list 'string-end   (ev (lambda (s) (emit! s (utf8->string (buf-take! s))))))
     (list 'chars-data
           (lambda (p s bv from to)
             (put-bytevector (buf-port s) bv from (- to from))
             callback-continue))
     (list 'escape
           (lambda (p s) (encode-code-unit! s (parser-field-ref p 'cp)) callback-continue))
     (list 'number-data
           (lambda (p s bv from to)
             (put-bytevector (buf-port s) bv from (- to from))
             callback-continue))
     (list 'number-end
           (lambda (p s)
             (emit! s (string->number (utf8->string (buf-take! s))))
             (fresh-buf! s)
             callback-continue))
     (list 'true  (ev (lambda (s) (emit! s #t))))
     (list 'false (ev (lambda (s) (emit! s #f))))
     (list 'null  (ev (lambda (s) (emit! s 'null))))))

  (define (make-json-dom)
    (let ((s (make-st '() #f #f 0)))
      (fresh-buf! s)
      (make-parser json-parser bindings s)))

  (define (check r)
    (case (parser-result-status r)
      ((error)
       (let ((e (parser-result-error r)))
         (raise (list 'json-error (parser-error-code e) (parser-error-offset e)))))
      (else r)))

  (define (json-dom-feed! p bv start end) (check (parser-feed! p bv start end)))
  (define (json-dom-finish! p)
    (check (parser-finish! p))
    (st-result (parser-user-context p)))

  (define (json-parse bv)
    (let ((p (make-json-dom)))
      (json-dom-feed! p bv 0 (bytevector-length bv))
      (json-dom-finish! p)))

  ;; feed in pieces of `n` bytes
  (define (json-parse-chunked bv n)
    (let ((p (make-json-dom)) (len (bytevector-length bv)))
      (let loop ((i 0))
        (when (< i len)
          (json-dom-feed! p bv i (min len (+ i n)))
          (loop (+ i n))))
      (json-dom-finish! p))))
