(import (rnrs) (rnrs mutable-pairs) (only (chezscheme) iota format time collect current-time time-difference time-second time-nanosecond sstats-bytes statistics)
        (byte-machine runtime) (generated json) (bmjson dom) (prefix (json parser) cj:))

;; --- inputs -------------------------------------------------------------------
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

;; --- runners ------------------------------------------------------------------
;; events-only consumer: the minimum a context-driven parse needs
(define stack-bindings
  (list (list 'object-start (lambda (p s) (set-car! s (cons 'object (car s))) callback-continue))
        (list 'array-start  (lambda (p s) (set-car! s (cons 'array (car s))) callback-continue))
        (list 'object-end   (lambda (p s) (set-car! s (cdar s)) callback-continue))
        (list 'array-end    (lambda (p s) (set-car! s (cdar s)) callback-continue))
        (list 'context      (lambda (p s) (caar s)))))
(define (bm-events bv)
  (let* ((p (make-parser json-parser stack-bindings (list '())))
         (r (parser-feed! p bv 0 (bytevector-length bv))))
    (assert (eq? (parser-result-status (parser-finish! p)) 'finished))))
(define (bm-dom bv) (json-parse bv))
(define (cj bv) (cj:json-string->scm (utf8->string bv)))

(define (measure thunk reps)
  (collect)
  (let ((t0 (current-time)) (b0 (sstats-bytes (statistics))))
    (do ((i 0 (+ i 1))) ((= i reps)) (thunk))
    (let* ((d (time-difference (current-time) t0))
           (secs (+ (time-second d) (/ (time-nanosecond d) 1e9))))
      (values (/ secs reps) (/ (- (sstats-bytes (statistics)) b0) reps)))))

(define (row name bv reps)
  (let ((len (bytevector-length bv)))
    (format #t "~a (~a bytes)~%" name len)
    (for-each
     (lambda (r)
       (let-values (((s alloc) (measure (lambda () ((cadr r) bv)) (if (eq? (car r) 'chez-json) (max 1 (div reps 4)) reps))))
         (format #t "  ~12a ~10,2f ms  ~8,1f MB/s  ~10,1f alloc B/input-B~%"
                 (car r) (* s 1000) (/ len s 1e6) (/ alloc len))))
     (list (list 'bm-events bm-events) (list 'bm-dom bm-dom) (list 'chez-json cj)))))

(row "ints-40k" (ints 40000) 10)
(row "records-2k" (records 2000) 10)
(row "escaped-string" (long-string 5000) 10)
