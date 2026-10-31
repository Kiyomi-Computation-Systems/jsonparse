#!r6rs
;;; tests/test-string-alloc.sps: what (jsonparse string) allocates (ADR-0010,
;;; ADR-0016).
;;;
;;; Chez's sstats-bytes counts every byte allocated since the start, so a
;;; difference across a region is what it allocated, whatever the collector
;;; did meanwhile (tests/test-parser-alloc.sps says why bytes-allocated will
;;; not do). Four properties, each held to a relation, never to a byte count:
;;;
;;;   1. No slope across strings: after warm-up, the same string allocates
;;;      the same as the 1st string and as the 20,000th.
;;;   2. A string costs its result plus one copy: at 100, 1,000 and 100,000
;;;      bytes, an assembly allocates at most a baseline plus a margin, the
;;;      baseline being a fresh n-byte bytevector and utf8->string of it.
;;;   3. Growth happens once and is geometric: the first 100 KB string
;;;      allocates the buffer's growth and a second does not; the gap is at
;;;      least the string's size and at most three times it. The buffer
;;;      starts at 256 bytes: a 256-byte string on a new assembler needs no
;;;      growth, and a 257-byte one does.
;;;   5. Nothing is retained: memory in use after a full collection does not
;;;      grow over 10,000 strings of 1,000 bytes (under 1 MB; a leak of any
;;;      per-string object keeps 10 MB or more).
;;;   4. A long number keeps no memory in flonum and exact modes: a
;;;      1,000,000-digit number fed in 1 KB parts allocates what a
;;;      2,000-digit one does, under the default limit of 1,000, and ends in
;;;      a stop. A control: in text mode, which keeps every byte, it
;;;      allocates at least its length.
;;;
;;; Measured on 2026-10-30 with the Guix container's Chez 10.4.1 (the
;;; figures are not pinned: another Chez build may allocate differently),
;;; with automatic collection off inside each region (a collection that fell
;;; in one added 656 bytes):
;;;   - an assembly of 100, 1,000 and 100,000 bytes allocates 688, 5,184 and
;;;     500,192 bytes, exactly the baseline's (result 4 bytes a char, plus
;;;     one bytevector copy); a 160-byte record of (statistics) is inside
;;;     each region
;;;   - the 6th and the 20,006th string of 100 bytes both allocate 688
;;;   - the first 100 KB string, in 1 KB parts: 755,312; the second and the
;;;     third: 500,192; the growth is 255,120 bytes, about 2.6 times the
;;;     string, the doublings from 256 to 131,072 added up
;;;   - a 256-byte string: 1,472 on a new assembler and on a grown one; a
;;;     257-byte one: 2,000 on a new one, 1,472 on a grown one, so the
;;;     growth to 512 bytes costs 528
;;;   - 2,000 and 1,000,000 digits in 1 KB parts, then number!: 160 bytes
;;;     each in flonum and exact modes (the statistics record alone); in
;;;     text mode 10,208 and 7,044,832 (the buffer's doublings)
(import (rnrs)
        (only (chezscheme) bytes-allocated collect collect-maximum-generation collect-request-handler parameterize void getenv sstats-bytes statistics)
        (srfi :64)
        (jsonparse-testing)
        (jsonparse options)
        (jsonparse parser)
        (jsonparse string))

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
;; Bytes allocated by calling THUNK once. The region is the same for every
;; call, so the 160-byte record (statistics) allocates inside it cancels
;; between two measures. Automatic collection is off inside it: a
;; collection that falls in the region allocates bookkeeping of its own
;; (656 bytes seen), and where it falls moves with the build and the
;; architecture.
(define (allocated thunk)
  (parameterize ((collect-request-handler void))
    (let* ((before (sstats-bytes (statistics)))
           (v (thunk))
           (after (sstats-bytes (statistics))))
      (- after before))))

;; A sink the results go to, so no allocation can be optimized away.
(define sink (make-vector 1 #f))

(define (repeat-bytes n byte)
  (make-bytevector n byte))

;; assemble : json-assembler Bytevector -> Void
;; One string from BV, in one part.
(define (assemble! a bv)
  (json-assembler-chars! a bv 0 (bytevector-length bv))
  (vector-set! sink 0 (json-assembler-string! a)))

;; assemble-parts! : json-assembler Bytevector Nat -> Void
;; One string from BV, in parts of K bytes.
(define (assemble-parts! a bv k)
  (let ((len (bytevector-length bv)))
    (let loop ((at 0))
      (when (< at len)
        (let ((end (min len (+ at k))))
          (json-assembler-chars! a bv at end)
          (loop end))))
    (vector-set! sink 0 (json-assembler-string! a))))

(test-begin "string-alloc")

;; --- 1. no slope across strings -----------------------------------------------------

(define text-100 (repeat-bytes 100 97))

(let ((a (make-json-assembler)))
  (for-each (lambda (i) (assemble! a text-100)) '(1 2 3 4 5))
  (let* ((first (allocated (lambda () (assemble! a text-100))))
         (_ (let loop ((i 0)) (when (< i 20000) (assemble! a text-100) (loop (+ i 1)))))
         (late (allocated (lambda () (assemble! a text-100)))))
    (show "slope: 6th string " first " bytes, 20,006th " late)
    (test-equal "no slope: the 20,006th string allocates what the 6th does"
      first late)
    (test-equal "no slope: the measure sees a string at all (the result is 4 bytes a char)"
      #t (>= first (* 4 100)))))

;; --- 2. a string costs its result plus one copy ---------------------------------------

;; baseline : Nat -> Nat
;; Bytes for a fresh N-byte bytevector and utf8->string of it, in the same
;; region shape as an assembly.
(define (baseline n)
  (let ((bv (repeat-bytes n 97)))
    (allocated (lambda ()
                 (let ((copy (make-bytevector n)))
                   (bytevector-copy! bv 0 copy 0 n)
                   (vector-set! sink 0 (utf8->string copy)))))))

;; A big allocation can cross a segment boundary, and the bookkeeping that adds
;; (160 to 320 bytes seen, depending on where the allocation pointer stood)
;; falls on one side of the comparison or the other. The margin allows for
;; it and for 1% of the size; an extra copy of the text costs n more.
(define (margin n) (+ 512 (div n 100)))

(for-each
 (lambda (n)
   (let ((a (make-json-assembler)) (bv (repeat-bytes n 97)))
     ;; Warm up: the buffer grows to n here, and Chez's code is paged in.
     (assemble! a bv) (assemble! a bv) (assemble! a bv)
     (let ((cost (allocated (lambda () (assemble! a bv))))
           (base (baseline n)))
       (show "cost: " n " bytes: assembly " cost ", baseline " base)
       (test-equal (string-append "cost: " (number->string n) " bytes allocate at most the baseline plus the margin")
         #t (<= cost (+ base (margin n))))
       (test-equal (string-append "cost: " (number->string n) " bytes: the baseline is a real measure, at least the result")
         #t (>= base (* 4 n)))
       (test-equal (string-append "cost: " (number->string n) " bytes: the assembly allocates at least the result")
         #t (>= cost (* 4 n))))))
 '(100 1000 100000))

;; --- 3. growth happens once ---------------------------------------------------------------

(define text-100k (repeat-bytes 100000 97))

(let* ((a (make-json-assembler))
       (first (allocated (lambda () (assemble-parts! a text-100k 1000))))
       (second (allocated (lambda () (assemble-parts! a text-100k 1000))))
       (third (allocated (lambda () (assemble-parts! a text-100k 1000)))))
  (show "growth: first 100 KB " first ", second " second ", third " third)
  (test-equal "growth: the first 100 KB string allocates the buffer's growth, at least 100,000 bytes more than the second"
    #t (>= (- first second) 100000))
  (test-equal "growth: the growth is geometric, at most 300,000 bytes more than the second"
    #t (<= (- first second) 300000))
  (test-equal "growth: the third allocates what the second does, give or take a code path's 1 KB"
    #t (<= (abs (- third second)) 1024)))

;; The buffer starts at 256 bytes: 256 bytes fit, and 257 grow it.
(define (fresh-cost n)
  (let ((a (make-json-assembler)) (bv (repeat-bytes n 97)))
    (allocated (lambda () (assemble! a bv)))))

(define (warm-cost n)
  (let ((a (make-json-assembler)) (bv (repeat-bytes n 97)))
    (assemble! a bv)
    (allocated (lambda () (assemble! a bv)))))

(show "start: 256 bytes fresh " (fresh-cost 256) " warm " (warm-cost 256)
      "; 257 fresh " (fresh-cost 257) " warm " (warm-cost 257))

(test-equal "start: a 256-byte string on a new assembler allocates no more than on a grown one"
  #t (<= (fresh-cost 256) (warm-cost 256)))

(test-equal "start: a 257-byte string on a new assembler allocates at least 512 bytes more than on a grown one"
  #t (>= (- (fresh-cost 257) (warm-cost 257)) 512))

;; The buffer's initial size is held by the two assertions above: below 256
;; bytes the first grows, and from 512 bytes the second does not. A check on
;; the constructor's own allocation could not tell sizes of 32 and up apart,
;; since its records make up the difference.

;; --- 4. a long number keeps no memory ---------------------------------------------------------

(define part-1k (repeat-bytes 1000 49))

;; feed-digits! : json-assembler Nat -> Void
;; N digits in 1000-byte parts.
(define (feed-digits! a n)
  (let loop ((left n))
    (when (> left 0)
      (json-assembler-number-chars! a part-1k 0 (min left 1000))
      (loop (- left 1000)))))

;; digits-cost : json-options Nat -> (List Nat Any)
;; Bytes allocated by feeding N digits in 1000-byte parts to an assembler
;; warmed with 2,000-digit numbers only, then taking the number, and what it
;; returned. The warm-up is small on purpose: a buffer that kept every digit
;; would have to grow here, and a warm-up of N digits would hide it.
(define part-1m (repeat-bytes 1000000 49))

;; one-part-cost : json-options -> Nat
;; As digits-cost, for 1,000,000 digits in a single part.
(define (one-part-cost options)
  (let ((a (make-json-assembler options)))
    (let warm ((k 0))
      (when (< k 3)
        (feed-digits! a 2000)
        (vector-set! sink 0 (json-assembler-number! a))
        (warm (+ k 1))))
    (allocated (lambda ()
                 (json-assembler-number-chars! a part-1m 0 1000000)
                 (vector-set! sink 0 (json-assembler-number! a))))))

(define (digits-cost options n)
  (let ((a (make-json-assembler options)))
    (let warm ((k 0))
      (when (< k 3)
        (feed-digits! a 2000)
        (vector-set! sink 0 (json-assembler-number! a))
        (warm (+ k 1))))
    (let* ((result #f)
           (bytes (allocated
                   (lambda ()
                     (feed-digits! a n)
                     (set! result (json-assembler-number! a))))))
      (list bytes result))))

(for-each
 (lambda (mode)
   (let* ((options (make-json-options 'number-mode mode))
          (small (digits-cost options 2000))
          (large (digits-cost options 1000000)))
     (show mode ": 2,000 digits " (car small) ", 1,000,000 digits " (car large))
     (test-equal (string-append (symbol->string mode) ": a 1,000,000-digit number allocates what a 2,000-digit one does")
       #t (<= (abs (- (car large) (car small))) 256))
     (test-equal (string-append (symbol->string mode) ": 1,000,000 digits in a single part allocate what 2,000 digits do")
       #t (<= (abs (- (one-part-cost options) (car small))) 256))
     (test-equal (string-append (symbol->string mode) ": a 2,000-digit and a 1,000,000-digit number both end in a stop")
       '(#t #t)
       (list (json-stop? (cadr small)) (json-stop? (cadr large))))))
 '(flonum exact))

(let* ((options (make-json-options 'number-mode 'text))
       (small (digits-cost options 2000))
       (large (digits-cost options 1000000)))
  (show "text: 2,000 digits " (car small) ", 1,000,000 digits " (car large))
  (test-equal "control: in text mode a 1,000,000-digit number allocates at least its length"
    #t (>= (car large) 1000000))
  (test-equal "control: in text mode the result is a json-number, not a stop"
    #t (json-number? (cadr large))))

;; --- 5. nothing is retained -------------------------------------------------------

;; Memory in use after a full collection, before and after 10,000 strings of
;; 1,000 bytes on one assembler. A per-string leak of anything (the result,
;; the copy taken from the buffer) keeps at least 10 MB.
(define (full-collect!) (collect (collect-maximum-generation) (collect-maximum-generation)))

(define text-1000 (repeat-bytes 1000 97))

(define (retained-growth)
  (let ((a (make-json-assembler)))
    (assemble! a text-1000)
    (full-collect!) (full-collect!)
    (let ((before (bytes-allocated)))
      (let loop ((i 0)) (when (< i 10000) (assemble! a text-1000) (loop (+ i 1))))
      (vector-set! sink 0 #f)
      (full-collect!) (full-collect!)
      (- (bytes-allocated) before))))

(let ((growth (retained-growth)))
  (show "retained: " growth " bytes after 10,000 strings of 1,000 bytes")
  (test-equal "retention: memory in use after a full collection grows by under 1 MB over 10,000 strings"
    #t (< growth 1000000)))

(test-end "string-alloc")

(exit (suite-exit-status runner))
