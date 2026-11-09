#!r6rs
;;; (jsonparse-bench): what the benchmarks time, and what they count to show
;;; the timing did the whole job (ADR-0013, ADR-0023).
;;;
;;; Five lanes. lane-thunk gives a thunk that runs a lane once on one
;;; bytevector, raising unless it was JSON, and a tally of every pass the
;;; thunk has run:
;;;
;;;   parse      a parser whose handler has no procedures
;;;   events     a parser counting each kind of value, and the bytes of
;;;              every number's and string's text, as yajl's harness counts
;;;   tree       bytevector->json, under the default options
;;;   tree+walk  bytevector->json, then tree-counts on the value
;;;   scan       composition: no parser, only a pass sorting each byte, the
;;;              least a Scheme loop reading a byte at a time does. It
;;;              checks nothing.
;;;
;;; The counts are how the report knows each lane did the whole job: yajl's
;;; events and jsonparse's must agree, and so must the walk and the scan
;;; with the events. The tally is how it knows the timed passes did that
;;; job too: their counts summed must be one pass's counts times the
;;; passes run. measure times the rounds; the report does the rest.
;;;
;;; This is tooling (ADR-0003): it takes Chez's clock, statistics and
;;; collector.
(library (jsonparse-bench)
  (export lanes lane-thunk
          composition
          count-names make-counts counting-handler counts->alist events-counts
          tree-counts utf8-length/scalar
          median mb/s iterations-for measure duration->ns
          synthetic-ints synthetic-records synthetic-escaped synthetic-files)
  (import (rnrs)
          (only (chezscheme)
                collect collect-maximum-generation current-time time-difference
                time-second time-nanosecond statistics sstats-bytes sstats-gc-real)
          (jsonparse parser)
          (jsonparse easy))

  ;; lanes : (Listof Symbol), in the report's order
  (define lanes '(parse events tree tree+walk scan))

  ;; lane-thunk : Symbol Bytevector
  ;;              -> (Values (-> Any) (-> (Pair Nat (Listof (Pair Symbol Nat)))))
  ;; A thunk running LANE once on BV, and a tally: the passes the thunk has
  ;; finished, and what they counted, summed. events counts as
  ;; events-counts does, tree+walk as tree-counts and scan as composition;
  ;; parse and tree count nothing. Each lane but scan raises unless BV is
  ;; one JSON document.
  (define (lane-thunk lane bv)
    (let ((passes 0))
      (define (counted thunk counts-of)
        (values (lambda () (thunk) (set! passes (+ passes 1)))
                (lambda () (cons passes (counts-of)))))
      (case lane
        ((parse)
         (counted (lambda ()
                    (let ((p (make-json-parser empty-handler)))
                      (json-parser-feed! p bv)
                      (check-finished 'parse (json-parser-finish! p))))
                  (lambda () '())))
        ((events)
         (let ((counts (make-counts)))
           (counted (lambda ()
                      (let ((p (make-json-parser counting-handler counts)))
                        (json-parser-feed! p bv)
                        (check-finished 'events (json-parser-finish! p))))
                    (lambda () (counts->alist counts)))))
        ((tree) (counted (lambda () (bytevector->json bv)) (lambda () '())))
        ((tree+walk)
         (let ((sum (summer)))
           (counted (lambda () ((car sum) (tree-counts (bytevector->json bv))))
                    (cdr sum))))
        ((scan)
         (let ((sum (summer)))
           (counted (lambda () ((car sum) (composition bv))) (cdr sum))))
        (else (assertion-violation 'lane-thunk "no such lane" lane)))))

  ;; A pair of an adder, which adds a list of name and count pairs into a
  ;; running sum, and a reader of that sum, '() before any add.
  (define (summer)
    (let ((sum '()))
      (cons (lambda (counts)
              (set! sum (if (null? sum)
                            counts
                            (map (lambda (a b) (cons (car a) (+ (cdr a) (cdr b)))) sum counts))))
            (lambda () sum))))

  (define empty-handler (make-json-handler))

  (define (check-finished who result)
    (unless (eq? (json-result-status result) 'finished)
      (error who "the parse did not finish"
             (json-result-status result) (json-result-code result)
             (json-result-offset result))))

  ;; --- the scan ----------------------------------------------------------------

  ;; What starts a token outside a string: 1 whitespace, 2 a number, 3 a
  ;; string, 0 anything else.
  (define start-class
    (let ((t (make-bytevector 256 0)))
      (for-each (lambda (b) (bytevector-u8-set! t b 1)) '(32 9 10 13))
      (bytevector-u8-set! t (char->integer #\-) 2)
      (do ((b 48 (+ b 1))) ((> b 57)) (bytevector-u8-set! t b 2))
      (bytevector-u8-set! t (char->integer #\") 3)
      t))

  ;; What continues a number: its digits, sign, point and exponent.
  (define number-class
    (let ((t (make-bytevector 256 0)))
      (for-each (lambda (c) (bytevector-u8-set! t (char->integer c) 1))
                (string->list "0123456789+-.eE"))
      t))

  ;; composition : Bytevector -> (List (Pair 'string Nat) (Pair 'number Nat)
  ;;                                   (Pair 'whitespace Nat) (Pair 'other Nat))
  ;; How many of BV's bytes are inside strings, quotes and escapes included;
  ;; in numbers' text; JSON whitespace outside strings; and anything else.
  ;; It checks nothing: a string left open runs to the end.
  (define (composition bv)
    (let ((n (bytevector-length bv)))
      (let loop ((i 0) (s 0) (num 0) (ws 0))
        (if (fx=? i n)
            (list (cons 'string s) (cons 'number num) (cons 'whitespace ws)
                  (cons 'other (fx- n (fx+ s (fx+ num ws)))))
            (let ((c (bytevector-u8-ref start-class (bytevector-u8-ref bv i))))
              (cond ((fx=? c 1) (loop (fx+ i 1) s num (fx+ ws 1)))
                    ((fx=? c 2)
                     (let ((j (number-end bv (fx+ i 1) n)))
                       (loop j s (fx+ num (fx- j i)) ws)))
                    ((fx=? c 3)
                     (let ((j (string-end bv (fx+ i 1) n)))
                       (loop j (fx+ s (fx- j i)) num ws)))
                    (else (loop (fx+ i 1) s num ws))))))))

  ;; The first index at or after I that isn't number text.
  (define (number-end bv i n)
    (if (and (fx<? i n) (fx=? 1 (bytevector-u8-ref number-class (bytevector-u8-ref bv i))))
        (number-end bv (fx+ i 1) n)
        i))

  ;; The index after the quote closing a string whose text starts at I, or N.
  (define (string-end bv i n)
    (if (fx=? i n)
        n
        (let ((b (bytevector-u8-ref bv i)))
          (cond ((fx=? b 34) (fx+ i 1))
                ((fx=? b 92) (string-end bv (fxmin n (fx+ i 2)) n))
                (else (string-end bv (fx+ i 1) n))))))

  ;; --- counting ----------------------------------------------------------------

  ;; count-names : (Listof Symbol)
  ;; What the events lane counts, in order. text-bytes is a string's or a
  ;; key's text as UTF-8, escapes decoded, as yajl hands it over.
  (define count-names
    '(null true false number string key object array number-bytes text-bytes))

  ;; make-counts : -> (Vectorof Fixnum), all zero, one per count name
  (define (make-counts) (make-vector 10 0))

  (define (add! v k n) (vector-set! v k (fx+ (vector-ref v k) n)))

  ;; counts->alist : (Vectorof Fixnum) -> (Listof (Pair Symbol Fixnum))
  (define (counts->alist v) (map cons count-names (vector->list v)))

  ;; counting-handler : json-handler
  ;; Counts into its parser's context, a vector from make-counts.
  (define counting-handler
    (make-json-handler
     'null (lambda (v) (add! v 0 1))
     'boolean (lambda (v b) (add! v (if b 1 2) 1))
     'number-chars (lambda (v bv start end) (add! v 8 (fx- end start)))
     'number-end (lambda (v) (add! v 3 1))
     'chars (lambda (v bv start end) (add! v 9 (fx- end start)))
     'escape (lambda (v scalar) (add! v 9 (utf8-length/scalar scalar)))
     'string-end (lambda (v) (add! v 4 1))
     'key-end (lambda (v) (add! v 5 1))
     'object-start (lambda (v) (add! v 6 1))
     'array-start (lambda (v) (add! v 7 1))))

  ;; events-counts : Bytevector -> (Listof (Pair Symbol Fixnum))
  ;; The counting handler's counts for BV, parsed whole. Raises unless BV is
  ;; one JSON document.
  (define (events-counts bv)
    (let* ((counts (make-counts))
           (p (make-json-parser counting-handler counts)))
      (json-parser-feed! p bv)
      (check-finished 'events-counts (json-parser-finish! p))
      (counts->alist counts)))

  ;; utf8-length/scalar : Fixnum -> (U 1 2 3 4)
  (define (utf8-length/scalar c)
    (cond ((fx<? c #x80) 1)
          ((fx<? c #x800) 2)
          ((fx<? c #x10000) 3)
          (else 4)))

  (define (string-utf8-length s)
    (let ((n (string-length s)))
      (let loop ((i 0) (len 0))
        (if (fx=? i n)
            len
            (loop (fx+ i 1) (fx+ len (utf8-length/scalar (char->integer (string-ref s i)))))))))

  ;; tree-counts : Any -> (Listof (Pair Symbol Fixnum))
  ;; What the counting handler counts but number-bytes, counted on a value
  ;; built under the default options: an object is an alist, the empty one
  ;; included, an array a vector, and null the symbol null. Raises on
  ;; anything else.
  (define (tree-counts value)
    (let ((v (make-vector 9 0)))
      (define (text! s) (add! v 8 (string-utf8-length s)))
      (let walk ((x value))
        (cond ((null? x) (add! v 6 1))
              ((pair? x)
               (add! v 6 1)
               (for-each (lambda (m)
                           (unless (and (pair? m) (string? (car m)))
                             (error 'tree-counts "not an object's member" m))
                           (add! v 5 1)
                           (text! (car m))
                           (walk (cdr m)))
                         x))
              ((vector? x) (add! v 7 1) (vector-for-each walk x))
              ((string? x) (add! v 4 1) (text! x))
              ((number? x) (add! v 3 1))
              ((eq? x #t) (add! v 1 1))
              ((eq? x #f) (add! v 2 1))
              ((eq? x 'null) (add! v 0 1))
              (else (error 'tree-counts "not a value of jsonparse's tree" x))))
      (map cons
           '(null true false number string key object array text-bytes)
           (vector->list v))))

  ;; --- the statistics ---------------------------------------------------------

  ;; median : (Listof Real) -> Real
  ;; The middle value, or the mean of the middle two. Raises on '().
  (define (median l)
    (when (null? l) (assertion-violation 'median "no values" l))
    (let* ((s (list-sort < l)) (n (length s)) (h (div n 2)))
      (if (odd? n)
          (list-ref s h)
          (/ (+ (list-ref s (- h 1)) (list-ref s h)) 2))))

  ;; mb/s : Nat Nat Real -> Flonum
  ;; The rate of ITERATIONS passes over BYTES in NS nanoseconds, where a
  ;; megabyte is 10^6 bytes (ADR-0013).
  (define (mb/s bytes iterations ns)
    (inexact (/ (* bytes iterations 1000) ns)))

  ;; iterations-for : Nat Nat -> Nat
  ;; The fewest passes over a file of SIZE bytes that read at least
  ;; ROUND-BYTES. Raises unless both are positive.
  (define (iterations-for size round-bytes)
    (unless (and (> size 0) (> round-bytes 0))
      (assertion-violation 'iterations-for "an empty file or round" size round-bytes))
    (div (+ round-bytes size -1) size))

  ;; measure : (-> Any) Nat Nat -> (Values (Listof Nat) Nat Nat)
  ;; Runs THUNK ITERATIONS times a round, a warm-up round first and then
  ;; ROUNDS timed ones, each after a full collection. Returns each timed
  ;; round's nanoseconds, the bytes allocated inside them, and the
  ;; nanoseconds they spent collecting. The collections between rounds are
  ;; counted in neither.
  (define (measure thunk iterations rounds)
    (define (run) (do ((i 0 (fx+ i 1))) ((fx=? i iterations)) (thunk)))
    (define ns duration->ns)
    (collect (collect-maximum-generation))
    (run)
    (let loop ((k 0) (acc '()) (allocated 0) (gc 0))
      (if (= k rounds)
          (values (reverse acc) allocated gc)
          (begin
            (collect (collect-maximum-generation))
            (let* ((s0 (statistics))
                   (t0 (current-time 'time-monotonic)))
              (run)
              (let* ((t1 (current-time 'time-monotonic))
                     (s1 (statistics)))
                (loop (+ k 1)
                      (cons (ns (time-difference t1 t0)) acc)
                      (+ allocated (- (sstats-bytes s1) (sstats-bytes s0)))
                      (+ gc (- (ns (sstats-gc-real s1)) (ns (sstats-gc-real s0)))))))))))

  ;; duration->ns : Time -> Nat, a duration's whole length in nanoseconds
  (define (duration->ns t)
    (+ (* (time-second t) 1000000000) (time-nanosecond t)))

  ;; --- M0's synthetic files ------------------------------------------------------

  (define (json-text proc)
    (string->utf8 (call-with-string-output-port proc)))

  (define (separated port n put)
    (do ((i 0 (+ i 1))) ((= i n))
      (unless (= i 0) (put-char port #\,))
      (put i)))

  ;; synthetic-ints : Nat -> Bytevector, an array of 0 to N-1
  (define (synthetic-ints n)
    (json-text
     (lambda (port)
       (put-char port #\[)
       (separated port n (lambda (i) (put-string port (number->string i))))
       (put-char port #\]))))

  ;; synthetic-records : Nat -> Bytevector, an array of N small records
  (define (synthetic-records n)
    (json-text
     (lambda (port)
       (define (put . parts)
         (for-each (lambda (p) (put-string port (if (string? p) p (number->string p)))) parts))
       (put-char port #\[)
       (separated port n
                  (lambda (i)
                    (put "{\"id\":" i ",\"name\":\"user-" i "\",\"email\":\"u" i
                         "@example.com\",\"score\":" (* i 3) ".5,\"active\":"
                         (if (even? i) "true" "false")
                         ",\"tags\":[\"a\",\"b\",\"c\"],\"addr\":{\"city\":\"Tokyo\",\"zip\":\"100-"
                         i "\"},\"note\":null}")))
       (put-char port #\]))))

  ;; synthetic-escaped : Nat -> Bytevector, one string of N phrases, each with
  ;; a \n, a é and a surrogate pair
  (define (synthetic-escaped n)
    (json-text
     (lambda (port)
       (put-string port "[\"")
       (do ((i 0 (+ i 1))) ((= i n))
         (put-string port "lorem ipsum dolor sit amet, \\n\\u00e9\\ud83d\\ude00 "))
       (put-string port "\"]"))))

  ;; synthetic-files : (Listof (Pair String (-> Bytevector)))
  ;; M0's files by name (plan §2). bench/files.lock pins their sha256.
  (define synthetic-files
    (list (cons "ints-40k.json" (lambda () (synthetic-ints 40000)))
          (cons "records-2k.json" (lambda () (synthetic-records 2000)))
          (cons "escaped-string.json" (lambda () (synthetic-escaped 5000))))))
