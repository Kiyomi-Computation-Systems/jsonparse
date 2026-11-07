#!r6rs
;;; tests/test-tree-alloc.sps: what (jsonparse tree) allocates and what it
;;; keeps alive (ADR-0006, ADR-0010, ADR-0017).
;;;
;;; Method as in tests/test-string-alloc.sps: sstats-bytes counts every byte
;;; allocated, so a difference across a region is what it allocated; the
;;; regions run with automatic collection off (a collection inside adds
;;; about 656 bytes); baselines are measured in the same run, never pinned;
;;; retention is memory in use (bytes-allocated) after a full collection.
;;; Five properties:
;;;
;;;   1. An array costs its vector. A builder that has parsed the same
;;;      document twice, reset before each run, allocates for [true, ...] of
;;;      n members the vector (8n + 8 bytes) plus a fixed amount, the same
;;;      at every n from 10 to 100,000 within the noise margin. A pair
;;;      consed per member shows as 16n bytes.
;;;   2. Objects cost their members. For {"k000000":true, ...}, in alist and
;;;      hashtable mode, the cost per member is the same from 100 to 100,000
;;;      members (no slope beyond linear). In alist mode it is also what an
;;;      array of the same keys costs per member, less the array's 8-byte
;;;      slot, plus two pairs: the key and value pair and the list's pair.
;;;   3. The stack grows once, by doubling, from 64 slots. A new builder
;;;      parsing an array of 65,600 members (65,601 slots) allocates the
;;;      vectors of 128, 256, ... 131,072 slots the first time and not the
;;;      second and third. The first array whose first parse grows the stack
;;;      has 64 members (65 slots), and the growth is a 128-slot vector.
;;;   4. Retention. Memory in use after a full collection returns to its
;;;      baseline while the builder is alive when a document of several MB
;;;      was finished, its value dropped and the builder reset; when a
;;;      parse ended in an error (cut off, or stopped by a number past the
;;;      digit limit), with no reset. Controls: a finished builder that
;;;      was not reset keeps the value (about the value's size); one left
;;;      mid-document keeps what it built so far.
;;;      Slots: after a document with a 4 MB string as the first or last
;;;      member of an array or an object (key or value), finished and
;;;      reset, or ended by trailing garbage with no reset, memory is back
;;;      to the baseline taken after a small document.
;;;   5. Stability: every property is checked after each of several heap
;;;      shifts, garbage of varying sizes allocated first, since where the
;;;      allocation pointer stands adds 160 to 320 bytes at a segment
;;;      boundary.
;;;
;;; Measured on 2026-11-06 with the Guix container's Chez 10.4.1 (figures
;;; not pinned; another Chez build may allocate differently). Every cost
;;; below is of a reset, one feed and a finish, on a builder that has parsed
;;; the document twice; it includes the 160-byte record of (statistics) and
;;; the two 32-byte results, and it is the same at every shift unless said:
;;;   - array of n true, n = 10 / 100 / 1,000 / 10,000 / 100,000: 1,024 /
;;;     1,744 / 8,944 / 80,944 / 801,104 (explore run, one shift). Less the
;;;     measured vector (8n + 8), the fixed amount is 976 bytes at every n
;;;     and every shift of the sweep
;;;   - alist objects, same n: 1,936 / 10,576 / 96,976 / 960,976 /
;;;     9,618,576 (to 9,652,176 at the worst shift: segment bookkeeping at
;;;     n = 100,000): 96.0, 96.0 and 96.2 to 96.6 bytes a member between
;;;     sizes. A key array of the same keys: 72.0, 72.0, 72.2
;;;   - hashtable objects: 2,160 / 11,696 / 105,264 / 1,092,144 /
;;;     10,695,568: 104.0, 109.7, 106.7 a member, at every shift; 32 to 38
;;;     more than the key array's. A table filled through an alist (mutant)
;;;     costs about 32 more again
;;;   - growth, n = 65,600 (65,601 slots): the first parse 2,622,096, the
;;;     second and third 525,792. The difference, 2,096,304, is the vectors
;;;     of 128, 256, ... 131,072 slots (2,096,464 by their measured sizes;
;;;     mutants growing by 1.5 and 3 are 34.5n and 25.6n, far outside)
;;;   - the first array whose first parse on a new builder grows the stack
;;;     has 64 members (65 slots); the growth there is 1,040 bytes, the
;;;     size of a 128-slot vector (1,032) and 8 more
;;;   - retention, a 2.4 MB document of 5,000 records (10.76 MB in memory
;;;     as a value): after a full collection the memory in use is within 8
;;;     bytes of the baseline when finished, dropped and reset; within 136
;;;     after a cut-off parse and 896 after a stopped one (the number's
;;;     buffer); the controls: a finished, unreset builder keeps 10,760,016
;;;     (the value), one left mid-document 9,649,136; the grown stack and
;;;     buffers are 65,016 to 65,024 bytes
;;;   - slots: a builder that parsed a document with a 1,000,000-character
;;;     (4 MB) string as its first or last member, key or value, finished
;;;     it and was reset (or ended it on trailing garbage, with no reset),
;;;     holds 32 to 40 bytes more than after a small document (128 after
;;;     the garbage). The baseline is taken after a 16-member small
;;;     document, since a stale slot is only overwritten by one that
;;;     reaches it, and not after the same document, which would count the
;;;     stale slot in
(import (rnrs)
        (only (chezscheme) bytes-allocated collect collect-maximum-generation collect-request-handler parameterize void getenv sstats-bytes statistics)
        (srfi :64)
        (jsonparse-testing)
        (jsonparse options)
        (jsonparse parser)
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

(define shifts '(0 1 17 250 1111 4096 33333 100001 262147))

;; --- documents -------------------------------------------------------------------

(define (pad n w)
  (let ((s (number->string n)))
    (string-append (make-string (- w (string-length s)) #\0) s)))

;; gen : Nat (Nat -> String) String String -> Bytevector
(define (gen n f open close)
  (string->utf8
   (string-append open
                  (apply string-append
                         (reverse (let loop ((i 0) (acc '()))
                                    (if (= i n) acc (loop (+ i 1) (cons (f i) acc))))))
                  close)))

(define (sep i s) (if (= i 0) s (string-append "," s)))

(define (array-doc n) (gen n (lambda (i) (sep i "true")) "[" "]"))
(define (key-array-doc n) (gen n (lambda (i) (sep i (string-append "\"k" (pad i 6) "\""))) "[" "]"))
(define (object-doc n) (gen n (lambda (i) (sep i (string-append "\"k" (pad i 6) "\":true"))) "{" "}"))

(define hashtable-options (make-json-options 'object-mode 'hashtable))

;; run! : json-builder Bytevector -> Void
;; Reset, one feed, finish.
(define (run! b doc)
  (json-builder-reset! b)
  (json-builder-feed! b doc)
  (json-builder-finish! b))

;; cost : json-builder Bytevector -> Nat
(define (cost b doc)
  (allocated (lambda () (run! b doc))))

;; warm-cost : (-> json-builder) Bytevector -> Nat
;; Bytes allocated by a run on a builder that has parsed DOC twice.
(define (warm-cost make doc)
  (let ((b (make)))
    (run! b doc) (run! b doc)
    (cost b doc)))

(define (default-builder) (make-json-builder))
(define (hashtable-builder) (make-json-builder hashtable-options))

(define (name . parts)
  (apply string-append (map (lambda (p) (if (number? p) (number->string p) p)) parts)))

;; The spread of a list of numbers.
(define (spread xs) (- (apply max xs) (apply min xs)))

(test-begin "tree-alloc")

(define sizes '(10 100 1000 10000 100000))
(define array-docs (map array-doc sizes))
(define object-docs (map object-doc sizes))
(define key-array-docs (map key-array-doc sizes))

;; A big allocation can cross a segment boundary, and the bookkeeping that
;; adds falls on one side or the other: 160 to 320 bytes seen. The margin
;; allows for that and for 1% of the size. A pair a member costs 16n.
(define (margin n) (+ 512 (div n 100)))

;; The size of a pair, measured: the same region with and without one.
(define pair-size
  (- (allocated (lambda () (vector-set! sink 0 (cons (vector-ref sink 0) 2))))
     (allocated (lambda () (vector-set! sink 0 (vector-ref sink 0))))))
(vector-set! sink 0 #f)

;; --- 1. an array costs its vector --------------------------------------------------

;; vector-size : Nat -> Nat
;; Bytes of an N-slot vector, measured: it is not 8n + 8 on every build.
(define (vector-size n)
  (- (allocated (lambda () (vector-set! sink 0 (make-vector n #t))))
     (allocated (lambda () (vector-set! sink 0 (make-vector 0 #t))))))

(define (check-arrays! tag)
  (let* ((fixed (map (lambda (n doc) (- (warm-cost default-builder doc) (vector-size n)))
                     sizes array-docs)))
    (show tag " array fixed costs " fixed)
    (for-each
     (lambda (n f)
       (test-equal (name tag " array: n = " n " allocates the vector plus the fixed amount of n = 10, within the margin")
         #t (<= (abs (- f (car fixed))) (margin n))))
     sizes fixed)
    (test-equal (name tag " array: the fixed amount is positive and under 4 KB")
      #t (and (> (car fixed) 0) (< (car fixed) 4096)))))

;; --- 2. objects cost their members ---------------------------------------------------

;; per-member : (List Nat) -> (List Number)
;; Bytes a member between consecutive sizes from 100 up.
(define (per-member costs)
  (let loop ((ns (cdr sizes)) (cs (cdr costs)) (prev-n (cadr sizes)) (prev-c (cadr costs)) (acc '()))
    (if (null? (cdr ns))
        (reverse acc)
        (loop (cdr ns) (cdr cs) (car ns) (car cs)
              (cons (/ (- (cadr cs) (car cs)) (- (cadr ns) (car ns))) acc)))))

(define (check-objects! tag)
  (let* ((alist (map (lambda (doc) (warm-cost default-builder doc)) object-docs))
         (table (map (lambda (doc) (warm-cost hashtable-builder doc)) object-docs))
         (keys (map (lambda (doc) (warm-cost default-builder doc)) key-array-docs))
         (a-rates (per-member alist))
         (t-rates (per-member table))
         (k-rates (per-member keys)))
    (show tag " alist " alist " rates " (map (lambda (r) (inexact r)) a-rates))
    (show tag " table " table " rates " (map (lambda (r) (inexact r)) t-rates))
    (show tag " keys " keys " rates " (map (lambda (r) (inexact r)) k-rates))
    (test-equal (name tag " alist: a member costs the same from 100 to 100,000 members, within 4 bytes")
      #t (<= (spread a-rates) 4))
    (test-equal (name tag " hashtable: a member costs the same from 100 to 100,000 members, within 8 bytes")
      #t (<= (spread t-rates) 8))
    ;; An alist member is a key array's, without its 8-byte slot, plus the
    ;; key and value pair and the list's pair.
    (test-equal (name tag " alist: a member costs a key's string, a slot-free pair of pairs, within 4 bytes")
      #t (let ((diff (- (car (reverse a-rates)) (car (reverse k-rates)) (- (* 2 pair-size) 8))))
           (<= (abs diff) 4)))
    ;; An entry holds a key and a value: two words more than the key array's
    ;; string and slot (measured: 34 bytes more; a table with no entries
    ;; set: 3 more).
    (test-equal (name tag " hashtable: a member costs at least 16 bytes more than a key array's")
      #t (>= (car (reverse t-rates)) (+ 16 (car (reverse k-rates)))))
    ;; Measured: 32 to 38 bytes more than the key array's. A table filled
    ;; through an alist costs about 32 more again, one more pair a member
    ;; and a pair for each entry's key and value.
    (test-equal (name tag " hashtable: a member costs at most 50 bytes more than a key array's")
      #t (<= (apply max t-rates) (+ 50 (car (reverse k-rates)))))))

;; --- 3. the stack grows once ------------------------------------------------------------

;; doubling-cost : Nat -> Nat
;; The vectors a stack allocates growing by doubling from 64 slots to hold
;; PEAK slots: of 128, 256, ... up to the first that holds PEAK, by the
;; measured size of a vector.
(define (doubling-cost peak)
  (let loop ((slots 128) (total 0))
    (let ((total (+ total (vector-size slots))))
      (if (>= slots peak) total (loop (* 2 slots) total)))))

;; An array of 65,600 members has a peak of 65,601 slots: the array's own
;; slot and a slot a member.
(define wide-n 65600)
(define wide-doc (array-doc wide-n))

(define (check-growth! tag)
  (let* ((b (make-json-builder))
         (first (cost b wide-doc))
         (second (cost b wide-doc))
         (third (cost b wide-doc))
         (growth (- first second))
         (doubling (doubling-cost (+ wide-n 1))))
    (show tag " growth: first " first " second " second " third " third " doubling " doubling)
    (test-equal (name tag " growth: the first parse allocates the vectors of 128, 256, ... 131,072 slots more than the second, within the margin")
      #t (<= (abs (- growth doubling)) (margin wide-n)))
    (test-equal (name tag " growth: the third allocates what the second does, within the margin")
      #t (<= (abs (- third second)) (margin wide-n)))))

;; first-growth : Nat -> Integer
;; What the first parse of an N-member array on a new builder allocates
;; more than its second.
(define (first-growth n)
  (let* ((b (make-json-builder)) (doc (array-doc n))
         (first (cost b doc)) (second (cost b doc)))
    (- first second)))

;; The smallest N from 0 to 300 whose first parse grows the stack, or #f.
(define (growth-threshold)
  (let loop ((n 0))
    (cond ((> n 300) #f)
          ((> (first-growth n) 512) n)
          (else (loop (+ n 1))))))

(define (check-initial! tag)
  (let ((threshold (growth-threshold)))
    (show tag " initial: first growth at n = " threshold
          ", growth there " (and threshold (first-growth threshold)))
    ;; An array of N members needs N + 1 slots: the first to grow has 65,
    ;; so the stack starts at 64.
    (test-equal (name tag " initial: the first array whose first parse grows the stack has 64 members, 65 slots")
      64 threshold)
    (test-equal (name tag " initial: that growth is a 128-slot vector, within the margin")
      #t (and threshold (<= (abs (- (first-growth threshold) (vector-size 128))) (margin 0))))))

;; --- 4. retention ------------------------------------------------------------------------

(define (rep s n)
  (let loop ((i 0) (acc '()))
    (if (= i n) (apply string-append acc) (loop (+ i 1) (cons s acc)))))

;; A record: strings in an array in an object in an array.
(define (record i)
  (string-append "{\"id\":" (number->string i)
                 ",\"name\":\"" (rep "n" 60) "\\n\\u00e9"
                 "\",\"tags\":[" (rep (string-append "\"" (rep "t" 40) "\",") 5) "\"end\"]"
                 ",\"nested\":{\"a\":[[\"" (rep "s" 30) "\",true,null,1.5],[\"" (rep "u" 30) "\"]]"
                 ",\"b\":\"" (rep "b" 50) "\"}}"))

(define record-count 5000)
(define (rep-records n)
  (let loop ((i 0) (acc '()))
    (if (= i n) (apply string-append (reverse acc))
        (loop (+ i 1) (cons (if (= i 0) (record i) (string-append "," (record i))) acc)))))

(define body (rep-records record-count))
(define big-text (string-append "[" body "]"))
(define big-doc (string->utf8 big-text))
;; The same, with a 1,001-digit number before the end (the limit is 1,000).
(define stop-doc (string->utf8 (string-append "[" body "," (rep "1" 1001) "]")))
;; The same, cut off in the middle of a string near the end.
(define cut-doc (let ((bv (make-bytevector (- (bytevector-length big-doc) 20))))
                  (bytevector-copy! big-doc 0 bv 0 (bytevector-length bv))
                  bv))
;; Mid-document: the first nine tenths.
(define mid-doc (let ((bv (make-bytevector (div (* 9 (bytevector-length big-doc)) 10))))
                  (bytevector-copy! big-doc 0 bv 0 (bytevector-length bv))
                  bv))

(define (full-collect!) (collect (collect-maximum-generation) (collect-maximum-generation)))
(define (settled) (full-collect!) (full-collect!) (bytes-allocated))

;; feed-in-parts! : json-builder Bytevector -> json-result
;; The last feed's result, in 64 KB parts.
(define (feed-parts! b bv)
  (let ((len (bytevector-length bv)))
    (let loop ((at 0) (r #f))
      (if (= at len)
          r
          (let ((end (min len (+ at 65536))))
            (let ((r (json-builder-feed! b bv at end)))
              (if (eq? (json-result-status r) 'need-input) (loop end r) r)))))))

;; The scenarios each leave the builder in a state; none of them returns
;; anything that holds the value.

(define (finish-and-drop! b)
  (feed-parts! b big-doc)
  (vector-set! sink 0 (json-builder-finish! b))
  (vector-set! sink 0 (json-builder-value b))
  (vector-set! sink 0 #f))

(define (finish-and-hold! b)
  (feed-parts! b big-doc)
  (json-builder-finish! b)
  (vector-set! sink 0 (json-builder-value b)))

(define (cut-off! b)
  (feed-parts! b cut-doc)
  (let ((r (json-builder-finish! b)))
    (list (json-result-status r) (json-result-code r))))

(define (stopped! b)
  (let ((r (feed-parts! b stop-doc)))
    (list (json-result-status r) (json-result-code r))))

(define (mid! b)
  (json-result-status (feed-parts! b mid-doc)))

(define retention-margin 2048)

;; back-to-baseline? : Integer Integer -> Boolean
;; X is memory in use less the baseline taken after the warm-up; GROWN is
;; that baseline less the new builder's. Back to baseline means within the
;; noise of the warm baseline, and within the grown stack and buffers
;; (under 128 KB) of the new builder's: a builder that kept the value
;; through every reset in the warm-up would carry it in the first only.
(define (back-to-baseline? x grown)
  (and (<= (abs x) retention-margin)
       (<= 0 (+ x grown) 131071)))

(define (check-retention! tag)
  (let* ((b (make-json-builder))
         ;; Memory in use with the new builder, before it has seen a byte.
         (fresh (settled)))
    ;; Warm: the stack grows, code is paged in.
    (finish-and-drop! b) (json-builder-reset! b)
    (finish-and-drop! b) (json-builder-reset! b)
    (let* ((base (settled))
           (grown (- base fresh))
           (_ (finish-and-hold! b))
           (held (- (settled) base))
           (_ (vector-set! sink 0 #f))
           (control-finished (- (settled) base))
           (_ (json-builder-reset! b))
           (after-reset (- (settled) base))
           (_ (finish-and-drop! b))
           (_ (json-builder-reset! b))
           (after-drop-reset (- (settled) base))
           (cut-result (cut-off! b))
           (after-cut (- (settled) base))
           (_ (json-builder-reset! b))
           (stop-result (stopped! b))
           (after-stop (- (settled) base))
           (_ (json-builder-reset! b))
           (mid-status (mid! b))
           (control-mid (- (settled) base))
           (_ (json-builder-reset! b))
           (final (- (settled) base)))
      (show tag " retention: base " base " held " held " finished-unreset " control-finished
            " reset " after-reset " drop+reset " after-drop-reset
            " cut " after-cut " stop " after-stop " mid " control-mid " final " final " stack-and-buffers " grown)
      (test-equal (name tag " retention: the value is several MB in memory")
        #t (> held 4000000))
      ;; The warm baseline is taken after resets: this is the new builder's
      ;; to the warm one's difference, the grown stack and the buffers.
      (test-equal (name tag " retention: after the warm-up, a reset builder holds only its grown stack and buffers, under 128 KB")
        #t (< 0 grown 131072))
      (test-equal (name tag " retention: a finished, dropped, reset builder returns to its baseline")
        #t (back-to-baseline? after-drop-reset grown))
      (test-equal (name tag " retention: the cut-off parse answers unexpected-eof")
        '(error unexpected-eof) cut-result)
      (test-equal (name tag " retention: a cut-off parse, not reset, holds nothing")
        #t (back-to-baseline? after-cut grown))
      (test-equal (name tag " retention: the stopped parse answers number-too-long")
        '(error number-too-long) stop-result)
      (test-equal (name tag " retention: a stopped parse, not reset, holds nothing")
        #t (back-to-baseline? after-stop grown))
      (test-equal (name tag " control: a finished builder, value dropped, not reset, keeps the value (within 1%)")
        #t (<= (abs (- control-finished held)) (div held 100)))
      (test-equal (name tag " control: reset lets the finished value go")
        #t (back-to-baseline? after-reset grown))
      (test-equal (name tag " control: a builder left mid-document answers need-input")
        'need-input mid-status)
      (test-equal (name tag " control: a builder left mid-document keeps over half the value")
        #t (> control-mid (div held 2)))
      (test-equal (name tag " control: reset lets the mid-document builder go")
        #t (back-to-baseline? final grown))
      ;; Keeps the builder alive to here, where no assertion can see it.
      (vector-set! sink 0 b)
      (vector-set! sink 0 #f))))

;; --- 4b. no slot holds a member after its container ends ------------------------

;; Each document has a 1,000,000-character string (4 MB in memory) as its
;; first or last member, as a key or a value, in an array and an object.
;; The baseline is taken after a small document, so no slot holds the big
;; string; a slot that close! leaves holding it keeps 4 MB.
(define big-string (make-string 1000000 #\a))
(define (doc-of before after)
  (string->utf8 (string-append before big-string after)))

(define slot-docs
  (list (list "array, string first" (doc-of "[\"" "\",1]") #f)
        (list "array, string last" (doc-of "[1,\"" "\"]") #f)
        (list "object, key first" (doc-of "{\"" "\":1,\"a\":2}") #f)
        (list "object, key last" (doc-of "{\"a\":1,\"" "\":2}") #f)
        (list "object, value first" (doc-of "{\"a\":\"" "\",\"b\":2}") #f)
        (list "object, value last" (doc-of "{\"a\":1,\"b\":\"" "\"}") #f)
        (list "root complete, then garbage, no reset" (doc-of "[\"" "\"]x") #t)
        (list "string root, then garbage, no reset" (doc-of "\"" "\" x") #t)))

;; Wide enough to write over every slot a slot document touches, so that no
;; slot holds a big string at the baseline.
(define small-doc (string->utf8 "[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16]"))

;; parse! : json-builder Bytevector -> json-result
;; Feeds DOC in parts and finishes unless the feed stopped.
(define (parse! b doc)
  (let ((r (feed-parts! b doc)))
    (if (eq? (json-result-status r) 'need-input) (json-builder-finish! b) r)))

;; leftover : json-builder Bytevector Boolean -> (List Integer Symbol Any)
;; Memory in use after a parse of DOC on a reset builder, less the memory
;; with the builder reset after a small document, and the parse's status
;; and code. The value is never taken. The builder is reset after the
;; parse if RESET?.
(define (leftover b doc reset?)
  (json-builder-reset! b)
  (parse! b doc)                          ; warm: the stack and the buffer grow
  (json-builder-reset! b)
  (parse! b small-doc)
  (json-builder-reset! b)
  (let ((base (settled)))
    (let* ((r (parse! b doc))
           (_ (when reset? (json-builder-reset! b)))
           (held (- (settled) base)))
      (json-builder-reset! b)
      (list held (json-result-status r) (json-result-code r)))))

(define (check-slots! tag)
  (let ((b (make-json-builder)))
    (for-each
     (lambda (entry)
       (let* ((label (car entry))
              (garbage? (caddr entry))
              (result (leftover b (cadr entry) (not garbage?))))
         (show tag " slots: " label " " result)
         (test-equal (name tag " slots: " label ": memory returns to the baseline after a small document, within the margin")
           #t (<= (abs (car result)) retention-margin))
         (test-equal (name tag " slots: " label ": the parse ends as it should")
           (if garbage? '(error trailing-garbage) '(finished #f))
           (cdr result))))
     slot-docs)
    ;; Keeps the builder alive to here, where no assertion can see it.
    (vector-set! sink 0 b)
    (vector-set! sink 0 #f)))

;; --- 5. the sweep ------------------------------------------------------------------------

(for-each
 (lambda (k)
   (let ((tag (name "shift " k ":")))
     (shift! k) (check-arrays! tag)
     (shift! k) (check-objects! tag)
     (shift! k) (check-growth! tag)
     (shift! k) (check-initial! tag)))
 shifts)

(for-each
 (lambda (k)
   (shift! k)
   (check-retention! (name "shift " k ":"))
   (shift! k)
   (check-slots! (name "shift " k ":")))
 '(0 17 4096 33333 100001))

;; The documents stay alive to here: a document used for the last time
;; in the last run would be freed before that run's last measurements,
;; and fall below its own baseline.
(vector-set! sink 0 (list big-doc stop-doc cut-doc mid-doc slot-docs))

(test-end "tree-alloc")

(exit (suite-exit-status runner))
