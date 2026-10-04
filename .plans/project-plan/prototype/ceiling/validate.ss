;; Hand-written iterative JSON validator: the best a Chez byte loop can do.
;; Explicit stack in a bytevector, class table, fixnum ops, no allocation.
(define cls (make-bytevector 256 0)) ; 1 = plain string byte
(do ((i #x20 (fx+ i 1))) ((fx= i 256)) (bytevector-u8-set! cls i 1))
(bytevector-u8-set! cls 34 0) (bytevector-u8-set! cls 92 0)
(do ((i #x80 (fx+ i 1))) ((fx= i 256)) (bytevector-u8-set! cls i 2))
(define (ws? c) (or (fx= c 32) (fx= c 10) (fx= c 13) (fx= c 9)))
(define (digit? c) (and (fx>= c 48) (fx<= c 57)))
(define (validate bv)
  (let ([n (bytevector-length bv)] [stk (make-bytevector 1024 0)])
    (define (fail i) (error 'json "invalid" i))
    (define (skip-ws i) (if (and (fx< i n) (ws? (bytevector-u8-ref bv i))) (skip-ws (fx+ i 1)) i))
    (define (utf8 i) ; i at lead byte >= 0x80; returns index after the sequence
      (let* ([c (bytevector-u8-ref bv i)]
             [k (cond [(fx< c #xC2) (fail i)] [(fx< c #xE0) 1] [(fx< c #xF0) 2] [(fx< c #xF5) 3] [else (fail i)])])
        (let loop ([j 1]) (if (fx> j k) (fx+ i j)
          (if (and (fx< (fx+ i j) n) (fx= (fxand (bytevector-u8-ref bv (fx+ i j)) #xC0) #x80)) (loop (fx+ j 1)) (fail i))))))
    (define (string i) ; i after opening quote
      (let loop ([i i])
        (if (fx>= i n) (fail i)
          (let ([c (bytevector-u8-ref bv i)])
            (case (bytevector-u8-ref cls c)
              [(1) (loop (fx+ i 1))]
              [(2) (loop (utf8 i))]
              [else (cond [(fx= c 34) (fx+ i 1)]
                          [(fx= c 92) (let ([e (bytevector-u8-ref bv (fx+ i 1))])
                                        (if (fx= e 117) (loop (fx+ i 6)) (loop (fx+ i 2))))]
                          [else (fail i)])])))))
    (define (digits i) (if (and (fx< i n) (digit? (bytevector-u8-ref bv i))) (digits (fx+ i 1)) i))
    (define (number i)
      (let* ([i (if (fx= (bytevector-u8-ref bv i) 45) (fx+ i 1) i)]
             [i (let ([j (digits i)]) (if (fx= j i) (fail i) j))]
             [i (if (and (fx< i n) (fx= (bytevector-u8-ref bv i) 46))
                    (let ([j (digits (fx+ i 1))]) (if (fx= j (fx+ i 1)) (fail i) j)) i)]
             [i (if (and (fx< i n) (memv (bytevector-u8-ref bv i) '(101 69)))
                    (let* ([i (fx+ i 1)] [i (if (and (fx< i n) (memv (bytevector-u8-ref bv i) '(43 45))) (fx+ i 1) i)]
                           [j (digits i)]) (if (fx= j i) (fail i) j)) i)])
        i))
    ;; value -> after-value loop with explicit stack (1 = object, 2 = array)
    (let value ([i (skip-ws 0)] [d 0])
      (when (fx>= i n) (fail i))
      (let ([c (bytevector-u8-ref bv i)])
        (define (after i d)
          (let ([i (skip-ws i)])
            (if (fx= d 0) (if (fx= (skip-ws i) n) #t (fail i))
              (let ([c (if (fx< i n) (bytevector-u8-ref bv i) (fail i))] [k (bytevector-u8-ref stk d)])
                (cond [(fx= c 44) (if (fx= k 1)
                                      (let ([i (skip-ws (fx+ i 1))])
                                        (if (fx= (bytevector-u8-ref bv i) 34) (key (fx+ i 1) d) (fail i)))
                                      (value (skip-ws (fx+ i 1)) d))]
                      [(and (fx= c 125) (fx= k 1)) (after (fx+ i 1) (fx- d 1))]
                      [(and (fx= c 93) (fx= k 2)) (after (fx+ i 1) (fx- d 1))]
                      [else (fail i)])))))
        (define (key i d)
          (let ([i (skip-ws (string i))])
            (if (fx= (bytevector-u8-ref bv i) 58) (value (skip-ws (fx+ i 1)) d) (fail i))))
        (cond
          [(fx= c 123) (let ([d (fx+ d 1)] [i (skip-ws (fx+ i 1))])
                         (bytevector-u8-set! stk d 1)
                         (cond [(fx= (bytevector-u8-ref bv i) 125) (after (fx+ i 1) (fx- d 1))]
                               [(fx= (bytevector-u8-ref bv i) 34) (key (fx+ i 1) d)]
                               [else (fail i)]))]
          [(fx= c 91) (let ([d (fx+ d 1)] [i (skip-ws (fx+ i 1))])
                        (bytevector-u8-set! stk d 2)
                        (if (fx= (bytevector-u8-ref bv i) 93) (after (fx+ i 1) (fx- d 1)) (value i d)))]
          [(fx= c 34) (after (string (fx+ i 1)) d)]
          [(or (fx= c 45) (digit? c)) (after (number i) d)]
          [(fx= c 116) (after (fx+ i 4) d)] [(fx= c 102) (after (fx+ i 5) d)] [(fx= c 110) (after (fx+ i 4) d)]
          [else (fail i)])))))
(define (bench f reps)
  (let* ([bv (call-with-port (open-file-input-port f) get-bytevector-all)]
         [t0 (real-time)])
    (do ([k 0 (fx+ k 1)]) ((fx= k reps)) (validate bv))
    (let ([ms (/ (- (real-time) t0) (inexact reps))])
      (printf "  ~22a ~7,3f ms ~8,1f MB/s~%" f ms (/ (bytevector-length bv) ms 1000.0)))))
(for-each (lambda (f) (bench f 200)) '("ints-40k.json" "records-2k.json" "escaped-string.json"))
