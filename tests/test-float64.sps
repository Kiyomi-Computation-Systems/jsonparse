#!r6rs
;;; tests/test-float64.sps: parse-number-fxx-test-data's more-test-cases.txt
;;; and lemire-fast-float.txt, and our own hard cases in
;;; tests/fixtures/float64/hard-cases.txt (ADR-0012, ADR-0011). Each line
;;; holds a number's text and the bits of its nearest float64, so every
;;; expectation in 3 to 5 comes from the file, never from Chez's reader,
;;; which flonum mode converts with. 6 to 8 compare with what 3 and 4 read.
;;;
;;; The hard cases are texts whose rounding needs digits past the 17th, up
;;; to the 800th, and ties at the subnormal and overflow edges, where
;;; rounding twice goes wrong. The corpus files have no such texts. Their
;;; bits came from Python's float() on the host; here each is checked
;;; against its text's exact value, rounded by hand.
;;;
;;;   1. the filter: a line's text is kept when it matches JSON's number
;;;      grammar, checked by hand here. The texts dropped are pinned
;;;   2. the counts of each kind of text, per file
;;;   3. flonum mode, with the digit limit raised past the longest text: a
;;;      text with a fraction or an exponent reads as the flonum with exactly
;;;      the line's bits, or as number-out-of-range where they are infinite
;;;   4. an integer text reads as the exact integer of its digits. With e0
;;;      after it, the same number, it reads as the flonum with the bits
;;;   5. each text with - in front: the same bits with the sign set, or the
;;;      negated integer
;;;   6. the default options: exactly the texts of more than 1,000 digits
;;;      are number-too-long, and every other reads as in 3 and 4
;;;   7. each text fed to a builder one byte at a time gives what one feed
;;;      gives, under both digit limits, so the digits are counted across
;;;      feeds
;;;   8. each text inside an array, ended by ], and with - in front, reads as
;;;      it does alone
;;;
;;; A flonum's bits are read with bytevector-ieee-double-set!, and the line's
;;; hex digits and an integer's digits are decoded here, digit by digit.
;;; A failing check prints each text that failed, with what it read as.
(import (rnrs)
        (srfi :64)
        (jsonparse-testing)
        (jsonparse easy)
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

(define dir "tests/corpus/parse-number-fxx/files/")

;; --- decoding, by hand ------------------------------------------------------------

(define (digit? c) (char<=? #\0 c #\9))

(define (digit-value c) (- (char->integer c) (char->integer #\0)))

;; hex->integer : String -> Nat, upper-case hex digits
(define (hex->integer s)
  (fold-left (lambda (acc c)
               (+ (* acc 16)
                  (if (digit? c) (digit-value c) (+ 10 (- (char->integer c) (char->integer #\A))))))
             0 (string->list s)))

;; digits->integer : String -> Nat, a string of decimal digits
(define (digits->integer s)
  (fold-left (lambda (acc c) (+ (* acc 10) (digit-value c))) 0 (string->list s)))

;; bits : Flonum -> Nat, its IEEE double bits
(define (bits x)
  (let ((b (make-bytevector 8)))
    (bytevector-ieee-double-set! b 0 x (endianness big))
    (bytevector-u64-ref b 0 (endianness big))))

(define sign-bit (expt 2 63))
(define infinite-bits #x7FF0000000000000)

;; json-number-text? : String -> Boolean, JSON's number grammar (RFC 8259 §6)
(define (json-number-text? s)
  (let ((n (string-length s)))
    (define (at i) (and (< i n) (string-ref s i)))
    (define (digits i) (if (and (at i) (digit? (at i))) (digits (+ i 1)) i))
    (let* ((i (if (eqv? (at 0) #\-) 1 0))
           (i (cond ((eqv? (at i) #\0) (+ i 1))
                    ((and (at i) (digit? (at i))) (digits i))
                    (else #f)))
           (i (and i (if (eqv? (at i) #\.)
                         (let ((j (digits (+ i 1)))) (and (> j (+ i 1)) j))
                         i)))
           (i (and i (if (memv (at i) '(#\e #\E))
                         (let* ((k (+ i 1))
                                (k (if (memv (at k) '(#\+ #\-)) (+ k 1) k))
                                (j (digits k)))
                           (and (> j k) j))
                         i))))
      (and i (= i n)))))

(define (count-digits s) (length (filter digit? (string->list s))))

(define (integer-text? s)
  (not (exists (lambda (c) (memv c '(#\. #\e #\E))) (string->list s))))

;; --- the files ------------------------------------------------------------------

;; A line: its f64 bits and its text.
(define-record-type entry (fields bits text))

;; read-lines : String -> (Listof String)
(define (read-lines path)
  (call-with-port
   (open-file-input-port path (file-options) (buffer-mode block)
                         (make-transcoder (latin-1-codec) (eol-style lf)))
   (lambda (p)
     (let loop ((acc '()))
       (let ((l (get-line p)))
         (if (eof-object? l) (reverse acc) (loop (cons l acc))))))))

;; Two formats. parse-number-fxx's, from its README: f16, f32 and f64 bits,
;; then the text from column 31. Our own: the f64 bits, then the text from
;; column 17, and a line starting # is a comment.
(define (fxx-line? l)
  (and (> (string-length l) 31)
       (char=? (string-ref l 4) #\space)
       (char=? (string-ref l 13) #\space)
       (char=? (string-ref l 30) #\space)))

(define (bits-line? l)
  (and (> (string-length l) 17)
       (char=? (string-ref l 16) #\space)
       (for-all (lambda (c) (or (digit? c) (char<=? #\A c #\F))) (string->list (substring l 0 16)))))

(define (comment? l) (and (> (string-length l) 0) (char=? (string-ref l 0) #\#)))

;; A source: its name, its path and its format.
(define sources
  (list (list "more-test-cases.txt" (string-append dir "more-test-cases.txt") 'fxx)
        (list "lemire-fast-float.txt" (string-append dir "lemire-fast-float.txt") 'fxx)
        (list "hard-cases.txt" "tests/fixtures/float64/hard-cases.txt" 'bits)))

(define files (map car sources))

;; The lines that hold numbers: every line of a corpus file, and each line
;; of our own that isn't a comment.
(define lines
  (map (lambda (s)
         (filter (lambda (l) (not (and (eq? (caddr s) 'bits) (comment? l))))
                 (read-lines (cadr s))))
       sources))

(define entries
  (map (lambda (s ls)
         (if (eq? (caddr s) 'fxx)
             (map (lambda (l) (make-entry (hex->integer (substring l 14 30)) (substring l 31 (string-length l))))
                  (filter fxx-line? ls))
             (map (lambda (l) (make-entry (hex->integer (substring l 0 16)) (substring l 17 (string-length l))))
                  (filter bits-line? ls))))
       sources lines))
(define kept (map (lambda (es) (filter (lambda (e) (json-number-text? (entry-text e))) es)) entries))

;; kind : entry -> Symbol
(define (kind e)
  (let ((magnitude (bitwise-and (entry-bits e) (- sign-bit 1))))
    (cond ((integer-text? (entry-text e)) 'integer)
          ((= magnitude infinite-bits) 'infinite)
          ((= magnitude 0) 'zero)
          (else 'finite))))

;; --- an exact oracle, for our own hard cases -----------------------------------------

;; text->exact : String -> Exact-Rational, a JSON number's value, decoded
;; digit by digit. Exact arithmetic is fine for the hard cases, whose
;; exponents are small, not for the corpus files' 1e-9223372036854775808.
(define (text->exact s)
  (let* ((cs (string->list s))
         (negative (char=? (car cs) #\-))
         (cs (if negative (cdr cs) cs)))
    (let loop ((cs cs) (digits '()) (scale 0) (in-fraction #f))
      (cond
       ((or (null? cs) (memv (car cs) '(#\e #\E)))
        (let* ((e (if (null? cs)
                      0
                      (let* ((rest (cdr cs))
                             (minus (and (pair? rest) (char=? (car rest) #\-)))
                             (rest (if (and (pair? rest) (memv (car rest) '(#\+ #\-))) (cdr rest) rest))
                             (v (digits->integer (list->string rest))))
                        (if minus (- v) v))))
               (v (* (digits->integer (list->string (reverse digits))) (expt 10 (- e scale)))))
          (if negative (- v) v)))
       ((char=? (car cs) #\.) (loop (cdr cs) digits scale #t))
       (else (loop (cdr cs) (cons (car cs) digits) (if in-fraction (+ scale 1) scale) in-fraction))))))

;; nearest-bits : Exact-Rational -> Nat, the bits of the float64 nearest Q,
;; ties to even; an infinity past the greatest.
(define (nearest-bits q)
  (let ((sign (if (negative? q) sign-bit 0)) (q (abs q)))
    (if (zero? q)
        sign
        (let* ((e (- (bitwise-length (numerator q)) (bitwise-length (denominator q))))
               (e (if (> (expt 2 e) q) (- e 1) e))
               (e (max e -1022))
               (m (/ q (expt 2 (- e 52))))
               (n (floor m))
               (r (- m n))
               (n (if (or (> r 1/2) (and (= r 1/2) (odd? n))) (+ n 1) n))
               (e (if (= n (expt 2 53)) (+ e 1) e))
               (n (if (= n (expt 2 53)) (expt 2 52) n)))
          (cond ((>= n (expt 2 52))
                 (if (> (+ e 1023) 2046)
                     (bitwise-ior sign infinite-bits)
                     (bitwise-ior sign (bitwise-arithmetic-shift-left (+ e 1023) 52) (- n (expt 2 52)))))
                (else (bitwise-ior sign n)))))))

;; --- reading ---------------------------------------------------------------------

(define raised (make-json-options 'digit-limit 2000))

;; one-feed : String json-options -> (U Number (List 'error Symbol))
(define (one-feed text o)
  (guard (e ((json-error? e) (list 'error (json-error-reason e))))
    (bytevector->json (string->utf8 text) o)))

;; byte-by-byte : String json-options -> (U Number (List 'error Symbol))
(define (byte-by-byte text o)
  (let* ((b (make-json-builder o)) (bv (string->utf8 text)) (n (bytevector-length bv)))
    (let loop ((i 0))
      (if (< i n)
          (let ((r (json-builder-feed! b bv i (+ i 1))))
            (if (eq? (json-result-status r) 'error)
                (list 'error (json-result-code r))
                (loop (+ i 1))))
          (let ((r (json-builder-finish! b)))
            (if (eq? (json-result-status r) 'finished)
                (json-builder-value b)
                (list 'error (json-result-code r))))))))

;; A flonum as its bits, so -0.0 and 0.0 differ; anything else as itself.
(define (shown v) (if (flonum? v) (list 'flonum-bits (bits v)) v))

;; expect-flonum : Nat -> Any, what a text whose nearest float64 has BITS
;; reads as, shown
(define (expect-flonum b)
  (if (= (bitwise-and b (- sign-bit 1)) infinite-bits)
      '(error number-out-of-range)
      (list 'flonum-bits b)))

;; failures : (entry -> (Listof (List String Any))) -> (Listof (List String Any Any))
;; Each check gives (text expected actual) triples; the failing ones.
(define (failures check)
  (let loop ((es (apply append kept)) (acc '()))
    (if (null? es)
        (reverse acc)
        (loop (cdr es)
              (append (reverse (filter (lambda (t) (not (equal? (cadr t) (caddr t)))) (check (car es))))
                      acc)))))

(test-begin "float64")

;; --- 1. the filter ------------------------------------------------------------------

(test-equal "filter: JSON numbers are kept"
  '(#t #t #t #t #t #t #t #t #t #t)
  (map json-number-text? '("0" "-0" "7" "10" "1.5" "0.25" "1e5" "1E+5" "2e-3" "-12.5E-03")))

(test-equal "filter: what isn't a JSON number is dropped"
  '(#f #f #f #f #f #f #f #f #f #f #f #f #f #f #f #f)
  (map json-number-text? '("" "-" ".5" "1." "01" "+1" "1e" "1e+" "--1" "0x1" "1.5.2" "Infinity" "NaN" " 1" "1 " "1.e2")))

(test-equal "filter: every line has its format's columns"
  (map length lines)
  (map length entries))

(test-equal "filter: the texts dropped from each file"
  '(() (".0" "9007199254740992.e-256" ".4999999" ".5" ".5000001" "1.e2") ())
  (map (lambda (es) (map entry-text (filter (lambda (e) (not (json-number-text? (entry-text e)))) es)))
       entries))

(test-equal "hard cases: each line's bits are its text's exact value rounded to the nearest float64, ties to even, here"
  '()
  (filter (lambda (t) (not (= (cadr t) (caddr t))))
          (map (lambda (e) (list (entry-text e) (entry-bits e) (nearest-bits (text->exact (entry-text e)))))
               (list-ref entries 2))))

(test-equal "the oracle: ties go to even, and past the greatest float64 is infinite"
  (list #x3FF0000000000000 #x3FF0000000000002 0 2 #x7FEFFFFFFFFFFFFF infinite-bits (bitwise-ior sign-bit 1))
  (list (nearest-bits (+ 1 (expt 2 -53))) (nearest-bits (+ 1 (* 3 (expt 2 -53))))
        (nearest-bits (expt 2 -1075)) (nearest-bits (* 3 (expt 2 -1075)))
        (nearest-bits (* (- (expt 2 53) 1) (expt 2 971))) (nearest-bits (expt 2 1024))
        (nearest-bits (- (expt 2 -1074)))))

;; --- 2. the counts -------------------------------------------------------------------

(test-equal "counts: lines, kept, integers, finite, zero and infinite, most digits, and over 1,000 digits"
  '(("more-test-cases.txt" 60 60 5 5 23 27 31 0)
    ("lemire-fast-float.txt" 3299 3293 2688 467 15 123 1023 2)
    ("hard-cases.txt" 24 24 0 21 2 1 800 0))
  (map (lambda (name ls es)
         (let ((kinds (map kind es)) (ds (map (lambda (e) (count-digits (entry-text e))) es)))
           (list name (length ls) (length es)
                 (length (filter (lambda (k) (eq? k 'integer)) kinds))
                 (length (filter (lambda (k) (eq? k 'finite)) kinds))
                 (length (filter (lambda (k) (eq? k 'zero)) kinds))
                 (length (filter (lambda (k) (eq? k 'infinite)) kinds))
                 (fold-left max 0 ds)
                 (length (filter (lambda (d) (> d 1000)) ds)))))
       files lines kept))

;; --- 3. fractions and exponents ------------------------------------------------------

(test-equal "flonum mode: a text with a fraction or an exponent reads as its float64 bits, or number-out-of-range"
  '()
  (failures
   (lambda (e)
     (if (integer-text? (entry-text e))
         '()
         (list (list (entry-text e) (expect-flonum (entry-bits e))
                     (shown (one-feed (entry-text e) raised))))))))

;; --- 4. integers ----------------------------------------------------------------------

(test-equal "flonum mode: an integer text reads as the exact integer of its digits"
  '()
  (failures
   (lambda (e)
     (let ((t (entry-text e)))
       (if (integer-text? t)
           (list (list t (digits->integer t) (one-feed t raised)))
           '())))))

(test-equal "flonum mode: an integer text with e0 after it reads as its float64 bits"
  '()
  (failures
   (lambda (e)
     (let ((t (entry-text e)))
       (if (integer-text? t)
           (list (list t (expect-flonum (entry-bits e))
                       (shown (one-feed (string-append t "e0") raised))))
           '())))))

;; --- 5. the sign ---------------------------------------------------------------------------

(test-equal "flonum mode: each text with - in front reads as the same bits with the sign set"
  '()
  (failures
   (lambda (e)
     (let ((t (entry-text e)) (negated (bitwise-ior (entry-bits e) sign-bit)))
       (if (integer-text? t)
           (list (list t (- (digits->integer t)) (one-feed (string-append "-" t) raised))
                 (list t (expect-flonum negated)
                       (shown (one-feed (string-append "-" t "e0") raised))))
           (list (list t (expect-flonum negated)
                       (shown (one-feed (string-append "-" t) raised)))))))))

;; --- 6. the default digit limit ---------------------------------------------------------

(define default-options (make-json-options))

(test-equal "default options: a text of more than 1,000 digits is number-too-long, and any other reads as with the limit raised"
  '()
  (failures
   (lambda (e)
     (let ((t (entry-text e)))
       (list (list t
                   (if (> (count-digits t) 1000)
                       '(error number-too-long)
                       (shown (one-feed t raised)))
                   (shown (one-feed t default-options))))))))

;; --- 7. a byte at a time -----------------------------------------------------------------

(test-equal "chunking: each text fed a byte at a time reads as in one feed, under both digit limits"
  '()
  (failures
   (lambda (e)
     (let ((t (entry-text e)))
       (list (list t (shown (one-feed t raised)) (shown (byte-by-byte t raised)))
             (list t (shown (one-feed t default-options)) (shown (byte-by-byte t default-options))))))))

;; --- 8. ended by ] ----------------------------------------------------------------------

(test-equal "inside an array: each text, and with - in front, ended by ], reads as it does alone"
  '()
  (failures
   (lambda (e)
     (map (lambda (t)
            (let ((v (one-feed (string-append "[" t "]") raised)))
              (list t (shown (one-feed t raised))
                    (if (and (vector? v) (= (vector-length v) 1)) (shown (vector-ref v 0)) v))))
          (list (entry-text e) (string-append "-" (entry-text e)))))))

(test-end "float64")

(exit (suite-exit-status runner))
