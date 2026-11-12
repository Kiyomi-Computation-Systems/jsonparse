#!r6rs
;;; tests/test-string-alloc.sps: what (jsonparse string) allocates (ADR-0010,
;;; ADR-0016, ADR-0027).
;;;
;;; Chez's sstats-bytes counts every byte allocated since the start, so a
;;; difference across a region is what it allocated, whatever the collector
;;; did meanwhile (tests/test-parser-alloc.sps says why bytes-allocated will
;;; not do). Six properties, each held to a relation, never to a byte count:
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
;;;   6. Which path a number takes (ADR-0027): a short integer allocates
;;;      nothing in flonum and exact modes, and a decimal of up to 15
;;;      digits one flonum, so neither copies its text; one of 16 to 18
;;;      digits less than that copy. One past each bound, exact mode's
;;;      decimals and text mode allocate at least the copy: a bytevector of
;;;      the text and a string of it.
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

;; A text that starts with U+FEFF is decoded after a space, since Chez's
;; utf8->string drops the mark, and that costs a longer copy and a cut.
;; Only the mark pays it: U+FEFE shares its first two bytes, EF BB, and
;; costs what U+FEBF, EF BA BF, does. Each text is 30 bytes and 28
;; characters. Measured on 2026-11-06: 336 bytes for both, 480 with the
;; mark, the same at six heap shifts.
(let* ((text (lambda (b1 b2 b3)
               (let ((bv (repeat-bytes 30 97)))
                 (bytevector-u8-set! bv 0 b1)
                 (bytevector-u8-set! bv 1 b2)
                 (bytevector-u8-set! bv 2 b3)
                 bv)))
       (near (text #xEF #xBB #xBE))
       (other (text #xEF #xBA #xBF))
       (mark (text #xEF #xBB #xBF))
       (a (make-json-assembler)))
  (for-each (lambda (bv) (assemble! a bv) (assemble! a bv)) (list near other mark))
  (let* ((near-cost (allocated (lambda () (assemble! a near))))
         (other-cost (allocated (lambda () (assemble! a other))))
         (mark-cost (allocated (lambda () (assemble! a mark)))))
    (show "U+FEFF: near " near-cost ", other " other-cost ", mark " mark-cost)
    (test-equal "U+FEFF: a text starting U+FEFE costs what one starting U+FEBF does"
      other-cost near-cost)
    (test-equal "U+FEFF: a text starting with the mark costs more, so the measure sees the cut"
      #t (> mark-cost other-cost))))

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

;; --- 6. which path a number takes ---------------------------------------------------

;; ADR-0027: json-assembler-number! reads a short number straight from its
;; buffer, so what a number allocates tells which path took it. Each text
;; goes to a warm assembler in one part and is taken, as in a parse.

;; A flonum, made in a region as a fast decimal's result is.
(define flonum-parts (vector 1.5 2.5))

(define empty-cost (allocated (lambda () (vector-set! sink 0 #f))))

(define flonum-cost
  (allocated (lambda () (vector-set! sink 0 (fl* (vector-ref flonum-parts 0) (vector-ref flonum-parts 1))))))

;; number-cost-on : json-assembler String -> Nat
;; Bytes allocated by giving A the number TEXT in one part and taking it,
;; after three turns of the same to warm it.
(define (number-cost-on a text)
  (let ((bv (string->utf8 text)))
    (define (turn)
      (json-assembler-number-chars! a bv 0 (bytevector-length bv))
      (vector-set! sink 0 (json-assembler-number! a)))
    (turn) (turn) (turn)
    (allocated turn)))

;; number-cost : Mode String -> Nat
;; number-cost-on a new assembler under MODE.
(define (number-cost mode text)
  (number-cost-on (make-json-assembler (make-json-options 'number-mode mode)) text))

;; costs : Mode (Listof String) -> (Listof (List String Nat Nat))
;; Each text, its number-cost, and the copy baseline for its length: a
;; bytevector and a string, what the general path makes first.
(define (costs mode texts)
  (let ((cs (map (lambda (t) (list t (number-cost mode t) (baseline (string-length t)))) texts)))
    (show mode ": text, cost, copy: " cs)
    cs))

;; costs-failing : Mode (Listof String) (Nat Nat -> Boolean) -> (Listof (List String Nat Nat))
;; The costs whose cost and copy fail OK?: none, when every text keeps it.
(define (costs-failing mode texts ok?)
  (filter (lambda (x) (not (ok? (cadr x) (caddr x)))) (costs mode texts)))

(define fast-integers
  '("0" "-0" "7" "-7" "123456789" "-123456789" "123456789012345678" "-123456789012345678"))

;; Measured on 2026-11-11 with the Guix container's Chez 10.4.1 on the
;; NUC (amd64), in bytes, each region with its 160-byte record of
;; (statistics). An empty region 160, one flonum 176. With the fast path:
;;   - the integers below: 160 in both modes, either sign;
;;   - the decimals of up to 15 digits 176, either sign;
;;   - those of 16 to 18 digits 208 to 240, against copies of 288;
;;   - the general path: 19 digits 288 in flonum mode, the copy alone, and
;;     384 in exact mode; 15 and 16 digits at 10^23 and 10^-23 464 to 592,
;;     against copies of 272 to 288; exact mode's decimals 288 to 480, and
;;     text mode 208 to 256, against copies of 192 to 272.
;; Before it, on the same day, every number took the general path: the
;; integers 192 to 288 in flonum mode and 224 to 384 in exact mode, the
;; decimals of up to 15 digits 304 to 560, and those of 16 to 18 digits
;; 400 to 560.
(test-equal "fast path: 0, and an integer of 1, 9 and 18 digits, either sign, in flonum and exact modes, allocates nothing: what an empty region does"
  (map (lambda (t) (list t empty-cost empty-cost)) fast-integers)
  (let ((cs (map (lambda (t) (list t (number-cost 'flonum t) (number-cost 'exact t))) fast-integers)))
    (show "integers: text, flonum, exact: " cs)
    cs))

(test-equal "fast path: an assembler made with no options takes it too: 123456789 allocates nothing"
  empty-cost
  (number-cost-on (make-json-assembler) "123456789"))

(show "empty region " empty-cost ", one flonum " flonum-cost)

(test-equal "fast path: the measure sees one flonum: it costs more than an empty region"
  #t (> flonum-cost empty-cost))

;; Zeros, either sign, a fraction, an exponent or both, an exponent's +
;; and -, and 15 digits at 10^22 and 10^-22, one of them with an exponent
;; of 36 that its fraction brings back to 22.
(define short-decimals
  '("0.0" "-0.0" "0e5" "-0E-5"
    "1.5" "-1.5" "2e3" "2e+3" "-2E-3" "0.25e1" "123456789012345e-5" "-1.23456789012345"
    "123456789012345e22" "-123456789012345e-22" "1.23456789012345e36"))

(test-equal "fast path: in flonum mode, a decimal of at most 15 digits within 10^22 either way allocates at most one flonum"
  '()
  (filter (lambda (x) (> (cadr x) flonum-cost)) (costs 'flonum short-decimals)))

;; 16, 17 and 18 digits, either sign, within 10^22 either way.
(define long-decimals
  '("1234567890123456e22" "-1234567890123456e-22" "12345678901234567e-5" "-12345678901234567e5"
    "123456789012345678e-17" "8116065220191916.38" "811606522019191638e21"))

(test-equal "fast path: in flonum mode, a decimal of 16 to 18 digits within 10^22 either way allocates less than the general path's copy of a text its length: a bytevector and a string"
  '()
  (costs-failing 'flonum long-decimals <))

;; One past each bound: 19 digits, 10^23 and 10^-23. exact mode's
;; decimals, and text mode, take the general path too.
(test-equal "general path: in flonum mode, a 19-digit integer, and decimals of 15 and 16 digits at 10^23 and 10^-23, allocate at least the copy"
  '()
  (costs-failing 'flonum
                 '("1000000000000000000" "-1000000000000000000" "123456789012345e23" "-123456789012345e-23"
                   "1.23456789012345e37" "1234567890123456e23")
                 >=))

(test-equal "general path: in exact mode, a 19-digit integer and every decimal allocate at least the copy"
  '()
  (costs-failing 'exact '("1000000000000000000" "-1000000000000000000" "1.5" "2e3" "123456789012345e-5") >=))

(test-equal "general path: in text mode, an integer and a decimal allocate at least the copy"
  '()
  (costs-failing 'text '("7" "-123456789" "1.5") >=))

(test-end "string-alloc")

(exit (suite-exit-status runner))
