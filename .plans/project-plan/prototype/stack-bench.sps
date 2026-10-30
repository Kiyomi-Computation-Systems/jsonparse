;; Stack measurement (ADR-0004): the prototype parser, whose `context`
;; callback answers from a consumer stack, against (bmjson grammar-fs), which
;; keeps the kind in fields. Run stack-gen.sps first. Paths as in plan §8.
(import (rnrs) (rnrs mutable-pairs)
        (only (chezscheme) iota format collect current-time time-difference time-second time-nanosecond sstats-bytes statistics)
        (byte-machine runtime) (generated json) (generated jsonfs) (bmjson dom))

;; --- inputs (same generators as the M0 bench) ---------------------------------
(define (s->bv s) (string->utf8 s))
(define (join parts sep)
  (if (null? parts) ""
      (fold-left (lambda (acc p) (string-append acc sep p)) (car parts) (cdr parts))))
(define (ints n) (s->bv (string-append "[" (join (map number->string (iota n)) ",") "]")))
(define (record i)
  (format "{\"id\":~a,\"name\":\"user-~a\",\"email\":\"u~a@example.com\",\"score\":~a.5,\"active\":~a,\"tags\":[\"a\",\"b\",\"c\"],\"addr\":{\"city\":\"Tokyo\",\"zip\":\"100-~a\"},\"note\":null}"
          i i i (* i 3) (if (even? i) "true" "false") i))
(define (records n) (s->bv (string-append "[" (join (map record (iota n)) ",") "]")))
(define (long-string n)
  (s->bv (string-append "[\"" (apply string-append (map (lambda (i) "lorem ipsum dolor sit amet, \\n\\u00e9\\ud83d\\ude00 ") (iota n))) "\"]")))

;; --- A0: context callback, list stack (the M0 consumer) -----------------------
(define a0-bindings
  (list (list 'object-start (lambda (p s) (set-car! s (cons 'object (car s))) callback-continue))
        (list 'array-start  (lambda (p s) (set-car! s (cons 'array (car s))) callback-continue))
        (list 'object-end   (lambda (p s) (set-car! s (cdar s)) callback-continue))
        (list 'array-end    (lambda (p s) (set-car! s (cdar s)) callback-continue))
        (list 'context      (lambda (p s) (caar s)))))
(define (a0-ctx) (list '()))

;; --- A1: context callback, bytevector stack (what jsonparse would ship) -------
;; ctx = #(bytevector top-index); byte 1 = object, 0 = array
(define (a1-ctx) (vector (make-bytevector 512 0) 0))
(define (push! s k)
  (let ((i (+ (vector-ref s 1) 1)))
    (bytevector-u8-set! (vector-ref s 0) i k) (vector-set! s 1 i)))
(define (pop! s) (vector-set! s 1 (- (vector-ref s 1) 1)))
(define a1-bindings
  (list (list 'object-start (lambda (p s) (push! s 1) callback-continue))
        (list 'array-start  (lambda (p s) (push! s 0) callback-continue))
        (list 'object-end   (lambda (p s) (pop! s) callback-continue))
        (list 'array-end    (lambda (p s) (pop! s) callback-continue))
        (list 'context      (lambda (p s)
                              (if (fx=? (bytevector-u8-ref (vector-ref s 0) (vector-ref s 1)) 1)
                                  'object 'array)))))

;; --- B0: stack in the machine, nothing bound ----------------------------------
;; --- B1: stack in the machine, the four container events bound to no-ops -------
(define (noop p s) callback-continue)
(define b1-bindings
  (map (lambda (n) (list n noop)) '(object-start array-start object-end array-end)))

(define (run machine bindings mkctx)
  (lambda (bv)
    (let ((p (make-parser machine bindings (mkctx))))
      (parser-feed! p bv 0 (bytevector-length bv))
      (parser-result-status (parser-finish! p)))))

(define variants
  (list (list "A0 callback, list stack" (run json-parser a0-bindings a0-ctx))
        (list "A1 callback, bytevector stack" (run json-parser a1-bindings a1-ctx))
        (list "B0 in-machine, nothing bound" (run jsonfs-parser '() (lambda () #f)))
        (list "B1 in-machine, container events" (run jsonfs-parser b1-bindings (lambda () #f)))
        (list "DOM (prototype, callback stack)" (lambda (bv) (json-parse bv) 'finished))))

;; --- correctness: every variant accepts the inputs and rejects mismatches ----
(define inputs (list (cons "ints-40k" (ints 40000)) (cons "records-2k" (records 2000))
                     (cons "escaped-string" (long-string 5000))))
(for-each
 (lambda (v)
   (when (string=? (car v) "DOM (prototype, callback stack)") (set! v (list (car v) (lambda (bv) (guard (e (#t 'error)) (json-parse bv) 'finished)))))
   (for-each (lambda (in) (assert (eq? 'finished ((cadr v) (cdr in))))) inputs)
   (for-each (lambda (bad) (assert (eq? 'error ((cadr v) (s->bv bad)))))
             '("[1}" "{\"a\":1]" "[{\"a\":[1}]]" "[[1],{\"b\":2]]")))
 variants)
(display "correctness: all four accept the inputs and reject the 4 mismatches\n")

;; --- context-call count per input --------------------------------------------
(define calls 0)
(define counting
  (map (lambda (b) (if (eq? (car b) 'context)
                       (list 'context (lambda (p s) (set! calls (+ calls 1)) ((cadr b) p s)))
                       b))
       a1-bindings))
(for-each (lambda (in)
            (set! calls 0)
            ((run json-parser counting a1-ctx) (cdr in))
            (format #t "  ~16a ~8d bytes ~7d context calls~%" (car in) (bytevector-length (cdr in)) calls))
          inputs)

;; --- timing: 9 rounds x 20 reps, median per parse ----------------------------
(define (median xs) (list-ref (list-sort < xs) (div (length xs) 2)))
(define (time-one f bv reps)
  (collect)
  (let ((t0 (current-time 'time-monotonic)))
    (do ((i 0 (+ i 1))) ((= i reps)) (f bv))
    (let ((d (time-difference (current-time 'time-monotonic) t0)))
      (/ (+ (* 1000.0 (time-second d)) (/ (time-nanosecond d) 1e6)) reps))))
(define (alloc-one f bv)
  (collect)
  (let ((b0 (sstats-bytes (statistics)))) (f bv) (- (sstats-bytes (statistics)) b0)))
(for-each
 (lambda (in)
   (let ((bv (cdr in)) (len (bytevector-length (cdr in))))
     (format #t "~a~%" (car in))
     (for-each
      (lambda (v)
        ((cadr v) bv) ((cadr v) bv)                  ; warm up
        (let ((ms (median (map (lambda (_) (time-one (cadr v) bv 100)) (iota 9)))))
          (format #t "  ~32a ~8,3f ms  ~7,1f MB/s  ~6d B alloc~%"
                  (car v) ms (/ len ms 1000.0) (alloc-one (cadr v) bv))))
      variants)))
 inputs)
