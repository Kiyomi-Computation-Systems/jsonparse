#!r6rs
;;; tests/test-sequence-alloc.sps: what (jsonparse sequence) allocates, what
;;; it costs as its input grows, and what it keeps alive (ADR-0020).
;;;
;;; Method as in tests/test-tree-alloc.sps: sstats-bytes counts every byte
;;; allocated, so a difference across a region is what it allocated; the
;;; regions run with automatic collection off; baselines are measured in the
;;; same run, never pinned; retention is memory in use (bytes-allocated)
;;; after a full collection. Every allocation and retention property is
;;; checked after each of several heap shifts, garbage of varying sizes
;;; allocated first, since where the allocation pointer stands adds bytes at
;;; a segment boundary. Five groups:
;;;
;;;   1. A record costs a fixed amount. Reading 1,000 and 4,000 one-line
;;;      records of 123456 costs the same per record, under lines and seq.
;;;      The reader's cost per record lies between the builder's own reset,
;;;      feed and finish, measured in the same run, and that plus 128
;;;      bytes. Under values the cost per value is constant too, is less
;;;      than the lines cost, and lies between an EACH builder's cost over
;;;      the same stream and that plus 96 bytes.
;;;   2. A record is never copied. Records of 1 padded with 10 and with
;;;      10,000 spaces cost the same per record: a copy shows as the
;;;      length. A 100 KB string fed in 1 KB chunks costs the reader at
;;;      most 2 KB more than a builder fed the same chunks, and the 32
;;;      bytes of the result it answers for each feed.
;;;   3. Cost at n and 4n on every part the reader leaves unbounded: by
;;;      allocation where the work allocates, by time (at 16 times the
;;;      input, under 40 times the time) where it doesn't.
;;;   4. Retention. Memory in use after a full collection returns to the
;;;      baseline, taken after a different, small stream, while the reader
;;;      is alive.
;;;   5. The sweep over heap shifts.
;;;
;;; Measured on 2026-11-07 with the Guix container's Chez 10.4.1 (figures not
;;; pinned; another Chez build may allocate differently). Run to run, a
;;; figure varies by about 1% at 4,000 records; the shift changes none:
;;;   - bytes a record of 123456 costs, at 1,000 and at 4,000 records: lines
;;;     944.3 and 944.1; seq the same; values 129.6 and 128.3; the builder's
;;;     own reset, feed and finish 864.2 to 869.4. So the reader adds 75 to
;;;     90 bytes to the builder, under the bound of 128: the dynamic-wind
;;;     and the closure in hand-value! (64 bytes by ADR-0020's
;;;     measurement), the record count and the value fetch
;;;   - a value of 123456 under values, over an EACH builder reading the same
;;;     stream: 80.03 at 1,000 values and 80.01 at 4,000 (the builder 49.0
;;;     and 48.2). Enter and leave thunks made for each call, rather than
;;;     once per reader, make it 112: the lines bound of 128 lets that
;;;     through, and the values bound of 96 doesn't (checked 2026-11-08)
;;;   - a record of 1 padded with 10 or with 10,000 spaces: 930.7 a record
;;;     in lines and seq, 122.1 in values, at both paddings
;;;   - a 100 KB string in 1 KB chunks: reader 558,000, builder 554,608. The
;;;     difference, 3,392, is 101 feeds of a 32-byte result each (the
;;;     reader answers a result of its own for every feed) and 160 bytes.
;;;     So the bound is 2 KB plus a result a feed, not 2 KB alone
;;;   - 1,000 and 4,000 records: lines 944,272 and 3,776,272; seq 944,272 and
;;;     3,803,632; values 129,008 and 513,008; skipped bad records 656,272
;;;     and 2,624,272 (656 each); blank lines under skip 49,200 and 193,200
;;;     (48 to 49 each: the builder is reset for every line, blank or not)
;;;   - 100,000 and 400,000 bytes of padding, a run of RS bytes, or leading
;;;     whitespace: 1,200 bytes, the same at both sizes
;;;   - one string of 65,536 and of 262,144 characters, fed in 4 KB chunks
;;;     to a new reader: 594,112 and 2,385,024 (9.1 bytes a character)
;;;   - time, ms at n and at 16n: records 9 and 150 (lines), 10 and 155 (seq),
;;;     4 and 70 (values); 1,000,000 bytes of record length, RS run or
;;;     leading whitespace 2 to 5 and 46 to 80; 300,000 blank lines 8 and
;;;     135; 100,000 skipped bad records 11 and 175. Linear is a ratio of
;;;     16 to 18; the bound is 40
;;;   - retention, a 1,000,000-character (4 MB) string: memory in use after a
;;;     full collection is within 160 bytes of the baseline in every
;;;     scenario (lines, seq and values; first, last and only record big; a
;;;     bad big record skipped, mid-record, and ending the stream with no
;;;     on-skip and no reset; an EACH builder; an on-value that raised,
;;;     reset). A reader whose on-value raised holds the value, 3,999,608
;;;     bytes, until it is reset under lines and seq, and none under
;;;     values, whose builder cleared its slot before calling EACH
;;;   - the baseline is taken after a bad big record, which grows the
;;;     assembler's buffer (it never shrinks) and hands no value on, then a
;;;     small stream, so a reader that keeps the first value it is handed
;;;     would show
(import (rnrs)
        (only (chezscheme) bytes-allocated collect collect-maximum-generation
              collect-request-handler parameterize void getenv sstats-bytes
              statistics real-time timer-interrupt-handler set-timer)
        (srfi :64)
        (jsonparse-testing)
        (jsonparse options)
        (jsonparse parser)
        (jsonparse sequence)
        (jsonparse tree))

(define runner (test-runner-simple))
(test-runner-current runner)

;; The simple runner names a failing test but not its values. Print both.
(let ((simple-end (test-runner-on-test-end runner)))
  (test-runner-on-test-end! runner
    (lambda (r)
      (simple-end r)
      (when (memq (test-result-kind r) '(fail xpass))
        (display "  expected: ")
        (write (test-result-ref r 'expected-value))
        (newline)
        (display "  actual:   ")
        (write (test-result-ref r 'actual-value))
        (newline)))))

(define verbose? (and (getenv "VERBOSE") #t))
(define (show . xs) (when verbose? (for-each display xs) (newline)))

;; in-order : Expr ... -> (Listof Any)
;; (list E ...) with the expressions evaluated left to right: Chez
;; evaluates a call's arguments in no fixed order.
(define-syntax in-order
  (syntax-rules ()
    ((_ e ...) (in-order-loop (e ...) ()))))
(define-syntax in-order-loop
  (syntax-rules ()
    ((_ () (t ...)) (list t ...))
    ((_ (e rest ...) (t ...)) (let ((v e)) (in-order-loop (rest ...) (t ... v))))))

;; --- the measure ---------------------------------------------------------------

;; allocated : (-> Any) -> Nat
;; Bytes allocated by calling THUNK once, automatic collection off.
(define (allocated thunk)
  (parameterize ((collect-request-handler void))
    (let* ((before (sstats-bytes (statistics)))
           (v (thunk))
           (after (sstats-bytes (statistics))))
      (- after before))))

(define sink (make-vector 1 #f))

;; shift! : Nat -> Void
;; Moves the allocation pointer: garbage of several kinds, sized by K.
(define (shift! k)
  (vector-set! sink 0 (make-bytevector k 0))
  (vector-set! sink 0 (make-vector (div k 7) 0))
  (vector-set! sink 0 (let loop ((i 0) (l '())) (if (< i (div k 11)) (loop (+ i 1) (cons i l)) l)))
  (vector-set! sink 0 (make-string (div k 3) #\a))
  (vector-set! sink 0 #f))

(define shifts '(0 1 17 250 1111 4096 33333 100001))

(define (name . parts)
  (apply string-append
         (map (lambda (p) (cond ((number? p) (number->string p)) ((symbol? p) (symbol->string p)) (else p)))
              parts)))

;; capped-ms : (-> Any) Nat -> (U Nat #f)
;; The wall time in ms of THUNK, or #f if it had run CAP ms and was cut
;; off by a timer interrupt, so that a quadratic reader fails fast rather
;; than hangs. A cut-off reader is not used again.
(define (capped-ms thunk cap)
  (call/cc
   (lambda (k)
     (let ((t0 (real-time)))
       (parameterize ((timer-interrupt-handler
                       (lambda ()
                         (if (> (- (real-time) t0) cap)
                             (k #f)
                             (set-timer 50000)))))
         (set-timer 50000)
         (thunk)
         (set-timer 0)
         (- (real-time) t0))))))

;; best-ms : (-> Any) Nat -> (U Nat #f)
;; The least of three capped times of THUNK; one run if the first took over
;; 300 ms; #f if the first was cut off.
(define (best-ms thunk cap)
  (let ((first (capped-ms thunk cap)))
    (cond ((not first) #f)
          ((> first 300) first)
          (else (let* ((second (capped-ms thunk cap))
                       (third (capped-ms thunk cap)))
                  (min first (or second first) (or third first)))))))

;; --- streams ------------------------------------------------------------------------

(define rs (string (integer->char #x1E)))

(define (rep s n)
  (let loop ((i 0) (acc '()))
    (if (= i n) (apply string-append acc) (loop (+ i 1) (cons s acc)))))

;; A format: its options, whether its reader is given ON-SKIP, and the text
;; before and after a record's body.
(define-record-type fmt (fields name options skip? before after))

(define lines-fmt (make-fmt 'lines (make-json-options) #f "" "\n"))
(define seq-fmt (make-fmt 'seq (make-json-options 'stream 'seq) #t rs "\n"))
(define values-fmt (make-fmt 'values (make-json-options 'stream 'values) #f "" " "))
(define all-fmts (list lines-fmt seq-fmt values-fmt))

(define (record fmt body) (string-append (fmt-before fmt) body (fmt-after fmt)))

;; stream-of : fmt String Nat -> Bytevector
;; N records with BODY.
(define (stream-of fmt body n) (string->utf8 (rep (record fmt body) n)))

(define (ignore-value v) #f)
(define (ignore-skip code record offset) #f)

;; make-reader : fmt -> json-reader
(define (make-reader fmt)
  (if (fmt-skip? fmt)
      (make-json-reader ignore-value ignore-skip (fmt-options fmt))
      (make-json-reader ignore-value (fmt-options fmt))))

;; make-skipping-reader : json-options -> json-reader
(define (make-skipping-reader options)
  (make-json-reader ignore-value ignore-skip options))

;; run! : json-reader Bytevector -> Void
;; Reset, one feed, finish.
(define (run! r bv)
  (json-reader-reset! r)
  (json-reader-feed! r bv)
  (json-reader-finish! r))

;; run-cost : json-reader Bytevector -> Nat
;; Bytes allocated by a run on a reader that has read BV twice.
(define (run-cost r bv)
  (run! r bv) (run! r bv)
  (allocated (lambda () (run! r bv))))

;; The cost of the builder's own reset, feed and finish, N times over BODY.
(define (builder-cost options body n)
  (let* ((bv (string->utf8 body)) (b (make-json-builder options)))
    (define (go)
      (let loop ((i 0))
        (when (< i n)
          (json-builder-reset! b)
          (json-builder-feed! b bv)
          (json-builder-finish! b)
          (loop (+ i 1)))))
    (go) (go)
    (allocated go)))

;; The cost of an EACH builder's reset, feed and finish over N values of
;; BODY, written as values-fmt writes them: what a values reader drives.
(define (each-builder-cost body n)
  (let* ((bv (stream-of values-fmt body n))
         (b (make-json-builder (fmt-options values-fmt) ignore-value)))
    (define (go)
      (json-builder-reset! b)
      (json-builder-feed! b bv)
      (json-builder-finish! b))
    (go) (go)
    (allocated go)))

(define (per n bytes) (/ bytes n))

;; A margin on a per-record figure: 16 bytes, which a pair (16) or a
;; closure per record would use up, and 1.5% of the figure, for the
;; segment bookkeeping that falls on one side of a region or the other.
(define (record-margin rate) (+ 16 (* rate 3/200)))

(test-begin "sequence-alloc")

;; --- 1. a record costs a fixed amount -----------------------------------------------

(define body "123456")

(define (check-record-cost! tag)
  (let* ((rates
          (map (lambda (fmt)
                 (let ((r (make-reader fmt)))
                   (in-order (fmt-name fmt)
                             (per 1000 (run-cost r (stream-of fmt body 1000)))
                             (per 4000 (run-cost r (stream-of fmt body 4000))))))
               all-fmts))
         ;; The builder reads what the reader hands it: the record's body
         ;; and, under seq, the newline that ends it.
         (lines-builder (in-order (per 1000 (builder-cost (fmt-options lines-fmt) body 1000))
                                  (per 4000 (builder-cost (fmt-options lines-fmt) body 4000))))
         (seq-builder (in-order (per 1000 (builder-cost (fmt-options seq-fmt) (string-append body "\n") 1000))
                                (per 4000 (builder-cost (fmt-options seq-fmt) (string-append body "\n") 4000)))))
    (show tag " rates (name 1000 4000) " (map (lambda (x) (list (car x) (inexact (cadr x)) (inexact (caddr x)))) rates)
          " builder " (map inexact lines-builder) " " (map inexact seq-builder))
    (for-each
     (lambda (row builder)
       (let ((fname (car row)) (r1 (cadr row)) (r4 (caddr row)))
         (test-equal (name tag " " fname ": a record costs the same at 1,000 and 4,000 records, within the margin")
           #t (<= (abs (- r4 r1)) (record-margin r1)))
         (for-each
          (lambda (rate b label)
            (test-equal (name tag " " fname ": the reader costs the builder's reset, feed and finish or more, " label)
              #t (>= rate b))
            (test-equal (name tag " " fname ": the reader costs under 128 bytes more than the builder, " label)
              #t (<= (- rate b) 128)))
          (list r1 r4) builder '("1,000 records" "4,000 records"))))
     (list (car rates) (cadr rates)) (list lines-builder seq-builder))
    ;; Values: constant, and under the lines cost.
    (let* ((v (caddr rates)) (v1 (cadr v)) (v4 (caddr v))
           (l1 (cadr (car rates))) (l4 (caddr (car rates)))
           (each (in-order (per 1000 (each-builder-cost body 1000))
                           (per 4000 (each-builder-cost body 4000)))))
      (show tag " values over an EACH builder " (map inexact each))
      ;; 96 lies between the 80 the reader adds and the 112 of enter and
      ;; leave thunks made for each call rather than once per reader.
      (for-each
       (lambda (rate b label)
         (test-equal (name tag " values: the reader costs an EACH builder's reset, feed and finish or more, " label)
           #t (>= rate b))
         (test-equal (name tag " values: the reader costs at most 96 bytes a value more than an EACH builder, " label)
           #t (<= (- rate b) 96)))
       (list v1 v4) each '("1,000 values" "4,000 values"))
      (test-equal (name tag " values: a value costs the same at 1,000 and 4,000 values, within the margin")
        #t (<= (abs (- v4 v1)) (record-margin v1)))
      (test-equal (name tag " values: a value costs less than a lines record")
        #t (and (< v1 l1) (< v4 l4)))
      (test-equal (name tag " values: a value costs under half the builder's reset, feed and finish")
        #t (and (< v1 (div (car lines-builder) 2)) (< v4 (div (cadr lines-builder) 2)))))))

;; --- 2. a record is never copied ---------------------------------------------------------

(define (check-no-copy! tag)
  (for-each
   (lambda (fmt)
     (let* ((r (make-reader fmt)) (n 100)
            (short (per n (run-cost r (stream-of fmt (string-append "1" (rep " " 10)) n))))
            (long (per n (run-cost r (stream-of fmt (string-append "1" (rep " " 10000)) n)))))
       (show tag " " (fmt-name fmt) " padded 10 " (inexact short) " padded 10,000 " (inexact long))
       (test-equal (name tag " " (fmt-name fmt) ": a record of 1 padded with 10 spaces and with 10,000 cost the same, within the margin")
         #t (<= (abs (- long short)) (record-margin short)))))
   all-fmts)
  ;; One record, a 100 KB string, fed in 1 KB chunks.
  (let* ((text (string-append "\"" (rep "abcdefghij" 10240) "\""))
         (bv (string->utf8 text))
         (len (bytevector-length bv))
         (chunk 1024))
    (define (feed-chunks! feed! target)
      (let loop ((at 0))
        (when (< at len)
          (feed! target bv at (min len (+ at chunk)))
          (loop (+ at chunk)))))
    (define (reader-run! r)
      (json-reader-reset! r)
      (feed-chunks! json-reader-feed! r)
      (json-reader-finish! r))
    (define (builder-run! b)
      (json-builder-reset! b)
      (feed-chunks! json-builder-feed! b)
      (json-builder-finish! b))
    (let ((r (make-json-reader ignore-value))
          (b (make-json-builder)))
      (reader-run! r) (reader-run! r)
      (builder-run! b) (builder-run! b)
      (let* ((reader (allocated (lambda () (reader-run! r))))
            (builder (allocated (lambda () (builder-run! b)))))
        (show tag " 100 KB string in 1 KB chunks: reader " reader " builder " builder)
        ;; Each feed of the reader answers a result of its own, which the
        ;; builder's feed does not: the size of make-json-result's.
        (let ((feeds (div (+ len chunk -1) chunk))
              (result-size (- (allocated (lambda () (vector-set! sink 0 (make-json-result 'need-input #f 12345))))
                              (allocated (lambda () (vector-set! sink 0 #f))))))
          (show tag " feeds " feeds " result " result-size)
          (test-equal (name tag " a 100 KB string in 1 KB chunks costs the reader at most 2 KB, and a result a feed, more than a builder")
            #t (<= (- reader builder) (+ 2048 (* feeds result-size)))))))))

;; --- 3. cost at n and 4n --------------------------------------------------------------------

;; A stream and the reader that reads it, for each unbounded part. (SIZE)
;; makes the stream of size SIZE; its reader is made by MAKE.
;; ALLOCATES says whether the work allocates in proportion to the size.
(define-record-type part (fields label make-stream make-reader))

(define (lines-reader) (make-json-reader ignore-value))
(define (skipping-lines-reader) (make-json-reader ignore-value ignore-skip))
(define (blank-skip-reader)
  (make-json-reader ignore-value (make-json-options 'blank-lines 'skip)))
(define (seq-reader) (make-skipping-reader (make-json-options 'stream 'seq)))

(define parts
  (list
   ;; Records.
   (make-part "records, lines" (lambda (n) (string->utf8 (rep "123456\n" n))) lines-reader)
   (make-part "records, seq" (lambda (n) (string->utf8 (rep (string-append rs "123456\n") n))) seq-reader)
   (make-part "records, values" (lambda (n) (string->utf8 (rep "123456 " n)))
              (lambda () (make-json-reader ignore-value (make-json-options 'stream 'values))))
   ;; A record's length, as padding.
   (make-part "record length, lines" (lambda (n) (string->utf8 (string-append "1" (rep " " n) "\n"))) lines-reader)
   (make-part "record length, seq" (lambda (n) (string->utf8 (string-append rs "1" (rep " " n) "\n"))) seq-reader)
   ;; A run of RS bytes.
   (make-part "run of RS bytes" (lambda (n) (string->utf8 (string-append (rep rs n) "1\n"))) seq-reader)
   ;; A run of blank lines.
   (make-part "run of blank lines, skipped" (lambda (n) (string->utf8 (string-append (rep "\n" n) "1\n"))) blank-skip-reader)
   ;; Leading whitespace in a record.
   (make-part "leading whitespace, lines" (lambda (n) (string->utf8 (string-append (rep " " n) "1\n"))) lines-reader)
   (make-part "leading whitespace, seq" (lambda (n) (string->utf8 (string-append rs (rep " " n) "1\n"))) seq-reader)
   ;; Skipped bad records.
   (make-part "skipped bad records, lines" (lambda (n) (string->utf8 (rep "x\n" n))) skipping-lines-reader)
   (make-part "skipped bad records, seq" (lambda (n) (string->utf8 (rep (string-append rs "x\n") n))) seq-reader)))

(define (find-part label)
  (let loop ((ps parts))
    (cond ((null? ps) (error 'find-part "no such part" label))
          ((string=? (part-label (car ps)) label) (car ps))
          (else (loop (cdr ps))))))

;; part-cost : part Nat -> Nat
(define (part-cost p size)
  (let ((r ((part-make-reader p))) (bv ((part-make-stream p) size)))
    (run-cost r bv)))

;; Parts whose work allocates a fixed amount per unit, so the cost at 4n is
;; about 4 times the cost at n: per record, per RS... Parts that don't
;; allocate with size are checked against the same fixed amount at 4n.
(define per-unit-parts
  '("records, lines" "records, seq" "records, values"
    "skipped bad records, lines" "skipped bad records, seq"
    "run of blank lines, skipped"))
(define fixed-parts
  '("record length, lines" "record length, seq" "run of RS bytes"
    "leading whitespace, lines" "leading whitespace, seq"))

(define (check-scaling! tag)
  (for-each
   (lambda (label)
     (let* ((p (find-part label))
            (n 1000)
            (c1 (part-cost p n)) (c4 (part-cost p (* 4 n))))
       (show tag " " label " n " c1 " 4n " c4)
       (test-equal (name tag " " label ": the cost per unit is the same at n and 4n, within the margin")
         #t (<= (abs (- (per (* 4 n) c4) (per n c1))) (record-margin (per n c1))))
       (test-equal (name tag " " label ": the cost at 4n is 4 times the cost at n, within 5%")
         #t (<= (abs (- c4 (* 4 c1))) (+ 4096 (div c1 20))))))
   per-unit-parts)
  (for-each
   (lambda (label)
     (let* ((p (find-part label))
            (n 100000)
            (c1 (part-cost p n)) (c4 (part-cost p (* 4 n))))
       (show tag " " label " n " c1 " 4n " c4)
       (test-equal (name tag " " label ": the cost is the same at n and 4n, within 4 KB")
         #t (<= (abs (- c4 c1)) 4096))
       (test-equal (name tag " " label ": the cost at n is small, under 4 KB")
         #t (< c1 4096))))
   fixed-parts))

;; A record that is one long string, fed in 4 KB chunks to a new reader: it
;; allocates the string and the buffer that grows by doubling, so the cost at
;; 4n is 4 times the cost at n when n is a power of two. A buffer that grew
;; by the chunk, or a copy of what was read so far, would cost more.
(define (long-string-cost size)
  (let* ((r (make-json-reader ignore-value))
         (bv (string->utf8 (string-append "\"" (rep "a" size) "\"\n")))
         (len (bytevector-length bv)))
    (allocated
     (lambda ()
       (let loop ((at 0))
         (when (< at len)
           (json-reader-feed! r bv at (min len (+ at 4096)))
           (loop (+ at 4096))))
       (json-reader-finish! r)))))

(define (check-long-string! tag)
  (let* ((c1 (long-string-cost 65536)) (c4 (long-string-cost 262144)))
    (show tag " long string n " c1 " 4n " c4)
    (test-equal (name tag " a record of one long string: the cost at 4n is 4 times the cost at n, within 5%")
      #t (<= (abs (- c4 (* 4 c1))) (+ 4096 (div c1 20))))
    (test-equal (name tag " a record of one long string: a character costs under 12 bytes")
      #t (< c4 (* 12 262144)))))

;; Time: at 16 times the input, under 40 times the time. The sizes are big
;; enough that the base takes some milliseconds.
(define time-sizes
  '(("records, lines" . 30000) ("records, seq" . 30000) ("records, values" . 30000)
    ("record length, lines" . 1000000) ("record length, seq" . 1000000)
    ("run of RS bytes" . 1000000) ("run of blank lines, skipped" . 300000)
    ("leading whitespace, lines" . 1000000) ("leading whitespace, seq" . 1000000)
    ("skipped bad records, lines" . 100000) ("skipped bad records, seq" . 100000)))

;; The most a run on the base size may take, in ms. Linear reading takes
;; 2 to 11 ms; a quadratic reader is cut off here.
(define base-cap 2000)

;; The floor, in ms, under which a time is quantisation: 16 times the input
;; may take 40 times this at the least.
(define time-floor 5)

;; time-part : String Nat -> (List (U Nat #f) (U Nat #f))
;; The reader's time on the stream for N, and on 16 times as much, which
;; is cut off after 40 times the first. Each is #f if it was cut off.
(define (time-part label n)
  (let* ((p (find-part label)) (r ((part-make-reader p)))
         (small ((part-make-stream p) n)))
    (if (not (capped-ms (lambda () (run! r small)) base-cap))
        (list #f #f)
        (let ((t1 (best-ms (lambda () (run! r small)) base-cap)))
          (if (not t1)
              (list #f #f)
              (let* ((big ((part-make-stream p) (* 16 n)))
                     (t16 (best-ms (lambda () (run! r big)) (* 40 (max t1 time-floor)))))
                (show label " n " n ": " t1 " ms, 16n: " t16 " ms")
                (list t1 t16)))))))

(define (check-time!)
  (for-each
   (lambda (row)
     (let* ((times (time-part (car row) (cdr row))) (t1 (car times)) (t16 (cadr times)))
       (test-equal (string-append "time: " (car row) ": the base size is read in under 2 s")
         #t (and t1 #t))
       (test-equal (string-append "time: " (car row) ": 16 times the input takes under 40 times the time")
         #t (and t1 t16 (< t16 (* 40 (max t1 time-floor)))))))
   time-sizes))

;; --- 4. retention -------------------------------------------------------------------------------

(define (full-collect!) (collect (collect-maximum-generation) (collect-maximum-generation)))
(define (settled) (full-collect!) (full-collect!) (bytes-allocated))

(define retention-margin 2048)

;; A string of a million characters is 4 MB in memory.
(define big-body (string-append "\"" (rep "a" 1000000) "\""))
(define small-body "[1,2,3]")

;; A big string and then a byte that is bad where it stands, in an array.
;; Read first, it grows the reader's buffers, and hands nothing on.
(define bad-big-body (string-append "[1," big-body ",x]"))

;; feed-parts! : json-reader Bytevector -> json-result
;; The last feed's result, in 64 KB parts.
(define (feed-parts! r bv)
  (let ((len (bytevector-length bv)))
    (let loop ((at 0) (res #f))
      (if (= at len)
          res
          (let* ((end (min len (+ at 65536)))
                 (res (json-reader-feed! r bv at end)))
            (if (eq? (json-result-status res) 'need-input) (loop end res) res))))))

(define (result->list r)
  (list (json-result-status r) (json-result-code r)))

;; read! : json-reader Bytevector -> (List Symbol Any)
;; Feeds BV in parts and finishes; the result's status and code. The value
;; is dropped by the reader's procedures.
(define (read! r bv)
  (let ((res (feed-parts! r bv)))
    (result->list (if (and res (eq? (json-result-status res) 'need-input))
                      (json-reader-finish! r)
                      (or res (json-reader-finish! r))))))

;; The scenarios: a name, a format, and the stream. The last record has no
;; separator after it in some, as a stream cut at the end of its last record.
(define (scenarios fmt)
  (let ((before (fmt-before fmt)) (after (fmt-after fmt)))
    (define (rec body) (string-append before body after))
    (list
     (list "first record big" (string-append (rec big-body) (rec "1") (rec "2")))
     (list "last record big" (string-append (rec "1") (rec "2") (rec big-body)))
     (list "last record big, no separator after it" (string-append (rec "1") (rec "2") before big-body))
     (list "only record big" (rec big-body))
     (list "a big array of strings" (string-append (rec (string-append "[" (rep (string-append "\"" (rep "b" 100000) "\",") 9) "\"end\"]")))))))

(define small-streams
  (list (list 'lines "[1]\n[2,3]\n\"x\"\n")
        (list 'seq (string-append rs "[1]\n" rs "[2,3]\n" rs "\"x\"\n"))
        (list 'values "[1] [2,3] \"x\" ")))

(define (small-stream fmt) (cadr (assq (fmt-name fmt) small-streams)))

;; leftover : fmt Bytevector -> (List Integer Any)
;; Memory in use after a reader READS the big stream, less the memory in use
;; after it read a small one. The reader first read a bad big record, which
;; grew its buffers and handed nothing on: a reader that keeps the first
;; value it is given, for good, shows. The reader is alive at both.
(define (leftover fmt bv)
  (let ((r (make-reader fmt))
        (small (string->utf8 (small-stream fmt)))
        (warm (string->utf8 (record fmt bad-big-body))))
    (read! r warm)                               ; warm: the buffers grow
    (json-reader-reset! r)
    (read! r small)
    (json-reader-reset! r)
    (let ((base (settled)))
      (let* ((status (read! r bv))
             (held (- (settled) base)))
        (json-reader-reset! r)
        (vector-set! sink 0 (list r bv small warm))
        (vector-set! sink 0 #f)
        (list held status)))))

(define (check-retention! tag)
  (for-each
   (lambda (fmt)
     (for-each
      (lambda (scenario)
        (let* ((label (car scenario))
               (result (leftover fmt (string->utf8 (cadr scenario)))))
          (show tag " retention " (fmt-name fmt) ": " label " " result)
          (test-equal (name tag " retention, " (fmt-name fmt) ", " label ": memory returns to the baseline after a small stream, within the margin")
            #t (<= (abs (car result)) retention-margin))
          (test-equal (name tag " retention, " (fmt-name fmt) ", " label ": the stream is read to finished")
            '(finished #f) (cadr result))))
      (scenarios fmt)))
   all-fmts))

;; --- bad records -------------------------------------------------------------------------


;; skipped-leftover : Nat -> ... see below

(define (check-bad-records! tag)
  ;; Skip mode: the big record is bad partway, and the stream goes on.
  (for-each
   (lambda (row)
     (let* ((label (car row)) (options (cadr row)) (stream (caddr row)) (expected (cadddr row))
            (bv (string->utf8 stream))
            (skips '())
            (r (make-json-reader ignore-value
                                 (lambda (code rec off) (set! skips (cons code skips)))
                                 options))
            (small (string->utf8 (cadr (assq (json-options-stream options) small-streams)))))
       (read! r bv)
       (json-reader-reset! r)
       (read! r small)
       (json-reader-reset! r)
       (set! skips '())
       (let* ((base (settled))
              (status (read! r bv))
              (held (- (settled) base)))
         (show tag " bad " label " " held " " status " " skips)
         (test-equal (name tag " bad records, skip mode, " label ": the stream is read to finished")
           '(finished #f) status)
         (test-equal (name tag " bad records, skip mode, " label ": the bad record is skipped, once")
           expected (reverse skips))
         (test-equal (name tag " bad records, skip mode, " label ": memory returns to the baseline, within the margin")
           #t (<= (abs held) retention-margin))
         (vector-set! sink 0 (list r bv small))
         (vector-set! sink 0 #f))))
   (list
    (list "lines, bad first" (make-json-options)
          (string-append bad-big-body "\n1\n2\n") '(unexpected-byte))
    (list "lines, bad last" (make-json-options)
          (string-append "1\n2\n" bad-big-body "\n") '(unexpected-byte))
    (list "lines, bad last, no newline" (make-json-options)
          (string-append "1\n2\n" bad-big-body) '(unexpected-byte))
    (list "seq, bad first" (make-json-options 'stream 'seq)
          (string-append rs bad-big-body "\n" rs "1\n" rs "2\n") '(unexpected-byte))
    (list "seq, bad last, no newline" (make-json-options 'stream 'seq)
          (string-append rs "1\n" rs "2\n" rs bad-big-body) '(unexpected-byte))))
  ;; Skip mode, measured with the bad record still being read: the builder
  ;; dropped the value when the error came.
  (for-each
   (lambda (row)
     (let* ((label (car row)) (options (cadr row)) (stream (caddr row))
            (bv (string->utf8 stream))
            (r (make-json-reader ignore-value ignore-skip options))
            (small (string->utf8 (cadr (assq (json-options-stream options) small-streams)))))
       (read! r bv)
       (json-reader-reset! r)
       (read! r small)
       (json-reader-reset! r)
       (let* ((base (settled))
              (res (feed-parts! r bv))
              (held (- (settled) base)))
         (show tag " mid-record " label " " held " " (result->list res))
         (test-equal (name tag " bad records, skip mode, " label ": mid-record, the reader wants more")
           '(need-input #f) (result->list res))
         (test-equal (name tag " bad records, skip mode, " label ": mid-record, the dropped value is not kept")
           #t (<= (abs held) retention-margin))
         (json-reader-reset! r)
         (vector-set! sink 0 (list r bv small))
         (vector-set! sink 0 #f))))
   (list
    (list "lines" (make-json-options) bad-big-body)
    (list "seq" (make-json-options 'stream 'seq) (string-append rs bad-big-body))))
  ;; No ON-SKIP: the big record is bad, it ends the stream, and the reader
  ;; is not reset. The error comes from the feed that reads the bad byte,
  ;; whether or not the record's end has come.
  (for-each
   (lambda (row)
     (let* ((label (car row)) (options (cadr row)) (stream (caddr row)) (fed-expected (cadddr row))
            (bv (string->utf8 stream))
            (r (make-json-reader ignore-value options))
            (small (string->utf8 (cadr (assq (json-options-stream options) small-streams)))))
       (read! r bv)
       (json-reader-reset! r)
       (read! r small)
       (json-reader-reset! r)
       (let* ((base (settled))
              (fed (feed-parts! r bv))
              (status (result->list (if (eq? (json-result-status fed) 'need-input)
                                        (json-reader-finish! r)
                                        fed)))
              (held (- (settled) base)))
         (show tag " no on-skip " label " " held " " (result->list fed) " " status)
         (test-equal (name tag " bad record, no on-skip, " label ": the feeds answer as the stream's end allows")
           fed-expected (result->list fed))
         (test-equal (name tag " bad record, no on-skip, " label ": the stream ends in an error")
           '(error unexpected-byte) status)
         (test-equal (name tag " bad record, no on-skip, " label ": memory returns to the baseline with no reset, within the margin")
           #t (<= (abs held) retention-margin))
         (json-reader-reset! r)
         (vector-set! sink 0 (list r bv small))
         (vector-set! sink 0 #f))))
   (list
    (list "lines, first" (make-json-options) (string-append bad-big-body "\n1\n") '(error unexpected-byte))
    (list "lines, last" (make-json-options) (string-append "1\n" bad-big-body) '(error unexpected-byte))
    (list "lines, last with newline" (make-json-options) (string-append "1\n" bad-big-body "\n") '(error unexpected-byte))
    (list "values, last" (make-json-options 'stream 'values) (string-append "1 " bad-big-body) '(error unexpected-byte)))))

;; --- an EACH builder that handed on a big value -------------------------------------------------

(define (check-each! tag)
  ;; EACH keeps nothing.
  (let* ((b (make-json-builder (make-json-options 'stream 'values) (lambda (v) #f)))
         (big (string->utf8 (string-append big-body " " big-body " ")))
         (warm (string->utf8 (string-append bad-big-body " ")))
         (small (string->utf8 "[1,2,3] ")))
    (define (go! bv) (json-builder-reset! b) (json-builder-feed! b bv) (json-builder-finish! b))
    (go! warm) (go! small)
    (let* ((base (settled))
           (res (result->list (begin (json-builder-reset! b) (json-builder-feed! b big) (json-builder-finish! b))))
           (held (- (settled) base)))
      (show tag " each handed on " held " " res)
      (test-equal (name tag " each: a builder that handed on two big values is finished")
        '(finished #f) res)
      (test-equal (name tag " each: a builder that handed on two big values keeps nothing, within the margin")
        #t (<= (abs held) retention-margin))
      (vector-set! sink 0 (list b big small warm))
      (vector-set! sink 0 #f)))
  ;; EACH raising on a big value: the builder is not reset, and holds nothing.
  (let* ((armed #f)
         (b (make-json-builder (make-json-options 'stream 'values)
                               (lambda (v) (when armed (raise 'boom)) #f)))
         (big (string->utf8 (string-append big-body " ")))
         (warm (string->utf8 (string-append bad-big-body " ")))
         (small (string->utf8 "[1,2,3] ")))
    (define (go! bv)
      (guard (e ((eq? e 'boom) 'raised))
        (json-builder-reset! b) (json-builder-feed! b bv) (json-builder-finish! b)))
    (go! warm) (go! small)
    (set! armed #t)
    (let* ((base (settled))
           (res (go! big))
           (held (- (settled) base)))
      (show tag " each raised " held " " res)
      (test-equal (name tag " each: EACH raising on a big value passes the raise out")
        'raised res)
      (test-equal (name tag " each: EACH raising on a big value, no reset, the builder holds nothing, within the margin")
        #t (<= (abs held) retention-margin))
      (set! armed #f)
      (vector-set! sink 0 (list b big small warm))
      (vector-set! sink 0 #f))))

;; --- a reader whose on-value raised ----------------------------------------------------------------

(define (check-raised! tag)
  (for-each
   (lambda (fmt)
     (let* ((armed #f)
            (r (if (fmt-skip? fmt)
                   (make-json-reader (lambda (v) (when (and armed (string? v)) (raise 'boom)))
                                     ignore-skip (fmt-options fmt))
                   (make-json-reader (lambda (v) (when (and armed (string? v)) (raise 'boom))) (fmt-options fmt))))
            (small (string->utf8 (small-stream fmt)))
            (stream (string->utf8 (string-append (record fmt "1") (record fmt big-body) (record fmt "2")))))
       (define (go! bv) (guard (e ((eq? e 'boom) 'raised)) (read! r bv)))
       (go! stream) (json-reader-reset! r)
       (go! small) (json-reader-reset! r)
       (let ((base (settled)))
         (set! armed #t)
         (let* ((res (go! stream))
                (before-reset (- (settled) base)))
           (set! armed #f)
           (json-reader-reset! r)
           (let ((after-reset (- (settled) base)))
             (show tag " raised " (fmt-name fmt) " " res " before reset " before-reset " after reset " after-reset)
             (test-equal (name tag " on-value raising, " (fmt-name fmt) ": the raise passes out of the reader")
               'raised res)
             (test-equal (name tag " on-value raising, " (fmt-name fmt) ": after the reset memory returns to the baseline, within the margin")
               #t (<= (abs after-reset) retention-margin))
             (test-equal (name tag " on-value raising, " (fmt-name fmt) ": the reader reads again after the reset")
               '(finished #f) (read! r small))
             (json-reader-reset! r)
             (vector-set! sink 0 (list r stream small))
             (vector-set! sink 0 #f))))))
   all-fmts))

;; --- 5. the sweep -------------------------------------------------------------------------------------

(for-each
 (lambda (k)
   (let ((tag (name "shift " k ":")))
     (shift! k) (check-record-cost! tag)
     (shift! k) (check-no-copy! tag)
     (shift! k) (check-scaling! tag)
     (shift! k) (check-long-string! tag)))
 shifts)

(check-time!)

(for-each
 (lambda (k)
   (let ((tag (name "shift " k ":")))
     (shift! k) (check-retention! tag)
     (shift! k) (check-bad-records! tag)
     (shift! k) (check-each! tag)
     (shift! k) (check-raised! tag)))
 '(0 17 4096 100001))

(test-end "sequence-alloc")

(exit (suite-exit-status runner))
