;;; tests/test-parser-alloc.sps: events-only parsing allocates nothing per
;;; byte, per value or per container (ADR-0004, global constraints).
;;;
;;; Chez's sstats-bytes counts every byte allocated since the start, so the
;;; difference across a feed and a finish is what they allocated, whatever
;;; the collector did meanwhile. (`bytes-allocated` is memory currently in
;;; use: a collection inside the measured region can make it fall.)
;;;
;;; Measured on 2026-10-30 with the Guix container's Chez: byte-machine's
;;; own parser (make-parser on
;;; jsonparse-machine, one `context` callback bound) allocates 864 bytes for
;;; a feed and a finish, whatever the input. Those 864 include the 160-byte
;;; record `(statistics)` itself allocates inside the measured region.
;;; jsonparse, with all fourteen procedures bound as no-ops and with none
;;; bound, allocates 928: the baseline plus 64, the two 32-byte json-result
;;; records, one per feed and one per finish. That held for a 590,003-byte
;;; array of records (and its 593-byte small version), a 1,000,002-byte
;;; string, a 1,000,000-byte number, 60000 open arrays (120,000 bytes) and
;;; 30000 open objects (180,001 bytes), and for their small versions. So the
;;; suite asserts two things:
;;;
;;;   1. a small and a large input allocate the same: a slope of 0, where one
;;;      word per value, byte or container would show as 8 bytes times the
;;;      size gap
;;;   2. on each of several inputs, jsonparse allocates at most the raw
;;;      baseline plus 64 bytes
;;;
;;; The figures above are not pinned: another Chez build or byte-machine
;;; release may allocate differently. The baseline is only required to
;;; measure a parse, more than an empty measured region costs.
;;;
;;; A control: a handler that conses per null, stored where it cannot be
;;; dropped, must show the gap, or the measurement is blind.
(import (except (rnrs) current-output-port)
        (only (chezscheme) sstats-bytes statistics)
        (only (byte-machine runtime) make-parser parser-feed! parser-finish!)
        (only (generated jsonparse) jsonparse-machine)
        (srfi :64)
        (jsonparse-testing)
        (jsonparse options)
        (jsonparse parser))

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

;; --- inputs -----------------------------------------------------------------------

(define (bytes s) (string->utf8 s))

(define (rep s n)
  (let loop ((i 0) (acc '()))
    (if (= i n) (apply string-append acc) (loop (+ i 1) (cons s acc)))))

;; Records covering every event: an object with a key with an escape and a
;; surrogate pair, a string with both, null, booleans and a number.
(define (records n)
  (bytes (string-append "[" (rep "{\"k\\n\\uD83D\\uDE00\":[\"s\\t\\uD83D\\uDE00\",null,true,false,12]}," n) "1]")))
(define (long-string n) (bytes (string-append "\"" (rep "a" n) "\"")))
(define (long-number n) (bytes (rep "1" n)))
(define (nested-arrays n) (bytes (string-append (rep "[" n) (rep "]" n))))
(define (nested-objects n) (bytes (string-append (rep "{\"a\":" n) "0" (rep "}" n))))

;; --- handlers ------------------------------------------------------------------------

(define (no-op c) #f)

(define no-ops
  (make-json-handler
   'null no-op 'boolean (lambda (c b) #f) 'number-chars (lambda (c bv s e) #f)
   'number-end no-op 'string-start no-op 'chars (lambda (c bv s e) #f)
   'escape (lambda (c u) #f) 'string-end no-op 'object-start no-op 'key-start no-op
   'key-end no-op 'object-end no-op 'array-start no-op 'array-end no-op))

(define nothing (make-json-handler))

;; A sink the control writes to, so the allocation cannot be optimized away.
(define sink (make-vector 1 #f))

(define consing-null
  (make-json-handler 'null (lambda (c) (vector-set! sink 0 (cons 1 2)) #f)))

;; --- the measure ---------------------------------------------------------------------

;; measure : json-handler Bytevector Nat -> (List Nat json-result)
;; Bytes allocated by one feed and one finish, and the finish's result.
(define (measure handler bv limit)
  (let* ((p (make-json-parser handler #f (make-json-options 'depth-limit limit)))
         (before (sstats-bytes (statistics)))
         (fed (json-parser-feed! p bv))
         (done (json-parser-finish! p))
         (after (sstats-bytes (statistics))))
    (list (- after before)
          (list (json-result-status fed) (json-result-status done)))))

(define (allocated handler bv limit) (car (measure handler bv limit)))

;; slope : handler Bytevector Bytevector Nat -> (List Nat Nat Nat), the large
;; input's allocation minus the small one's, over three runs.
(define (slope handler small large limit)
  (let loop ((k 0) (acc '()))
    (if (= k 3)
        (reverse acc)
        (let* ((s (allocated handler small limit))
               (l (allocated handler large limit)))
          (loop (+ k 1) (cons (- l s) acc))))))

(define cases
  ;; (label small large depth-limit)
  (list (list "per value: records" (records 10) (records 10000) 512)
        (list "per byte: a string" (long-string 100) (long-string 1000000) 512)
        (list "per byte: a number" (long-number 100) (long-number 1000000) 512)
        (list "per container: nested arrays" (nested-arrays 100) (nested-arrays 60000) 65535)
        (list "per container: nested objects" (nested-objects 100) (nested-objects 30000) 65535)))

(test-begin "parser-alloc")

(for-each
 (lambda (kase)
   (let ((label (car kase)) (small (cadr kase)) (large (caddr kase)) (limit (cadddr kase)))
     (for-each
      (lambda (handler-label handler)
        (test-equal (string-append label ", " handler-label ": the large input allocates what the small one does")
          '(0 0 0)
          (slope handler small large limit)))
      '("all no-ops" "nothing bound")
      (list no-ops nothing))))
 cases)

;; The inputs really parse, so the measure covers the work.
(for-each
 (lambda (kase)
   (test-equal (string-append (car kase) ": the large input finishes")
     '(need-input finished)
     (cadr (measure no-ops (caddr kase) (cadddr kase)))))
 cases)

;; baseline : Bytevector Nat -> Nat
;; Bytes byte-machine's own parser allocates for a feed and a finish of BV,
;; measured as `measure` does, with only the stack's `context` callback bound
;; (it always answers 'array: the inputs below are arrays and scalars).
(define (baseline bv limit)
  (let* ((p (make-parser jsonparse-machine (list (list 'context (lambda (p s) 'array)))
                         #f (list (cons 'depth-left limit))))
         (before (sstats-bytes (statistics)))
         (fed (parser-feed! p bv 0 (bytevector-length bv)))
         (done (parser-finish! p))
         (after (sstats-bytes (statistics))))
    (- after before)))

;; The two json-result records, 32 bytes each.
(define result-margin 64)

(for-each
 (lambda (kase)
   (let ((label (car kase)) (bv (cadr kase)) (limit (caddr kase)))
     (test-equal (string-append "baseline: " label ", jsonparse allocates at most byte-machine's own plus two results")
       #t
       (<= (allocated no-ops bv limit) (+ (baseline bv limit) result-margin)))
     (test-equal (string-append "baseline: " label ", with nothing bound")
       #t
       (<= (allocated nothing bv limit) (+ (baseline bv limit) result-margin)))))
 (list (list "one byte" (bytes "1") 512)
       (list "a short string" (long-string 100) 512)
       (list "a long string" (long-string 1000000) 512)
       (list "a long number" (long-number 1000000) 512)
       (list "flat numbers" (bytes (string-append "[" (rep "1," 10000) "1]")) 512)
       (list "nested arrays" (nested-arrays 60000) 65535)))

(define (empty-region)
  (let* ((before (sstats-bytes (statistics)))
         (after (sstats-bytes (statistics))))
    (- after before)))

(test-equal "baseline: byte-machine's own parser allocates more than an empty measured region"
  #t
  (> (baseline (bytes "1") 512) (empty-region)))

;; The control: 9990 more nulls than the small input, 16 bytes a cons.
(test-equal "control: a handler that conses per null shows the gap"
  #t
  (>= (- (allocated consing-null (records 10000) 512)
         (allocated consing-null (records 10) 512))
      (* 16 9990)))

(test-end "parser-alloc")

(exit (suite-exit-status runner))
