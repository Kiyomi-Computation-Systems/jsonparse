#!r6rs
;;; tests/test-writer-property.sps: round trips between (jsonparse writer)
;;; and the reader, (jsonparse tree)'s builder (ADR-0011, ADR-0018).
;;;
;;; Usage: test-writer-property.sps [SEED [MULTIPLIER]]
;;;
;;; 1. The generator. Trees of every kind of value, drawn with the seeded
;;;    property framework; a tally of what it drew is printed, and asserted.
;;; 2. The round trip, once per option set: write a tree, read it back with
;;;    a builder under the same options, and compare with what the tree
;;;    should read as. That expected value is worked out from the tree alone
;;;    (EXPECT below), not from the writer. The comparison is equal?, which
;;;    on numbers is eqv?: 1 is not 1.0, and -0.0 is not 0.0.
;;;      eqv?-exact   everything in the default (flonum) and exact modes:
;;;                   integers, flonums, and fractions read back as the
;;;                   flonum (inexact q) or as q itself.
;;;      through text  in text mode a number reads back as a json-number of
;;;                   the text written. The expected text of an exact integer
;;;                   is built here by repeated division by ten, and of a
;;;                   fraction by its decimal expansion, repeated
;;;                   multiplication by ten; neither uses the writer's code
;;;                   or number->string. A flonum's text is NOT independent:
;;;                   it comes from Chez's number->string, less the |width
;;;                   suffix, as the writer's does. Only flonum mode's eqv?
;;;                   round trip (2, 4) stands behind flonum text.
;;; 3. Digit limit: a number the writer writes past the default limit is
;;;    refused by the default reader, number-too-long, and is read back
;;;    with a larger limit.
;;; 4. ADR-0011's number property, with many cases: exact numbers in exact
;;;    mode and flonums in flonum mode, eqv?; json-numbers in text mode, by
;;;    text.
;;; 5. The corpus as a fixed point: read, write, read, write again.
;;; 6. The layout changes nothing: all indents read back alike; stripping
;;;    the whitespace outside strings gives the compact output; and the
;;;    output equals the compact output laid out again by a lexer here.
;;;
;;; A tree here (a "gtree") is plain data, so a failing case prints whole:
;;; NULL-MARK stands for the options' null; (%jn TEXT) is a json-number;
;;; (%ht (KEY . V) ...) is a hashtable; a list of (KEY . V) pairs is an
;;; alist; a vector is an array. REALIZE makes the real value.
(import (except (rnrs) current-output-port)
        (srfi :64)
        (jsonparse-testing)
        (jsonparse-testing machine)
        (jsonparse-testing property)
        (jsonparse-testing tree)
        (jsonparse error)
        (jsonparse options)
        (jsonparse parser)
        (jsonparse string)
        (jsonparse tree)
        (jsonparse writer))

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

(define default-seed 20261105)
(define parsed (parse-property-arguments (cdr (command-line)) default-seed))
(unless parsed
  (put-string (current-error-port)
              "usage: test-writer-property.sps [SEED [MULTIPLIER]]  (decimal digits)\n")
  (exit 1))
(define run (make-property-run "writer-property" (car parsed) (cadr parsed)))

;; --- small helpers ----------------------------------------------------------

(define (iota n) (let loop ((i (- n 1)) (acc '())) (if (< i 0) acc (loop (- i 1) (cons i acc)))))

(define (opts . args) (apply make-json-options args))

;; Records of the suite's own to stand for null.
(define-record-type nothing (fields tag))
(define nil-a (make-nothing 'same))
(define nil-b (make-nothing 'same))

;; --- writing and reading ------------------------------------------------------

;; write-bytes : Any json-options -> Bytevector
(define (write-bytes v options)
  (let-values (((port get) (open-bytevector-output-port)))
    (put-json port v options)
    (get)))

;; read-raw : Bytevector json-options -> (U (List 'ok Value) (List 'failed Status Code))
;; A builder under OPTIONS fed the whole of BV.
(define (read-raw bv options)
  (let ((b (make-json-builder options)))
    (json-builder-feed! b bv)
    (let ((r (json-builder-finish! b)))
      (if (eq? (json-result-status r) 'finished)
          (list 'ok (json-builder-value b))
          (list 'failed (json-result-status r) (json-result-code r))))))

;; read-canonical : Bytevector json-options -> (U (List 'ok Canonical) (List 'failed Status Code))
(define (read-canonical bv options)
  (let ((r (read-raw bv options)))
    (if (eq? (car r) 'ok) (list 'ok (canonical (cadr r))) r)))

(define (bv->text bv)
  (guard (e (#t (bytevector->u8-list bv))) (utf8->string bv)))

;; --- generating -----------------------------------------------------------------

;; g-bits : Nat -> Gen Nat
;; A number of K random bits.
(define (g-bits k)
  (lambda (s)
    (let loop ((acc 0) (have 0) (s s))
      (if (>= have k)
          (cons (mod acc (expt 2 k)) s)
          (draw* s ((c (g-int 32768)))
            (loop (+ (* acc 32768) c) (+ have 15) s))))))

(define (g-sign x)
  (lambda (s) (draw* s ((neg (g-chance 1 2))) (cons (if neg (- x) x) s))))

;; --- numbers

(define top-fixnum (greatest-fixnum))
(define bottom-fixnum (least-fixnum))

(define fixnum-edges
  (list 0 1 -1 9 -9 10 -10 99 100 999999999 -999999999 1000000000 -1000000000
        9999999999 -9999999999 10000000000 4294967295 4294967296 -4294967296
        (- (expt 2 31) 1) (expt 2 31) (- (expt 2 32) 1)
        (- (expt 2 53) 1) (expt 2 53) (+ (expt 2 53) 1)
        (- (expt 2 59) 1) (expt 2 59) (- (expt 2 60) 2)
        top-fixnum (- top-fixnum 1) bottom-fixnum (+ bottom-fixnum 1)
        (+ top-fixnum 1) (- bottom-fixnum 1) (- (expt 2 63) 1) (expt 2 63)
        (- (expt 2 64) 1) (expt 2 64) (- (expt 2 63)) 1000000000000000000
        123456789012 -123456789012))

(define g-fixnum-edge (g-pick fixnum-edges))

(define g-fixnum-random
  (lambda (s)
    (draw* s ((k (g-range 1 60)) (x (g-bits k)) (y (g-sign x))) (cons y s))))

(define g-bignum
  (lambda (s)
    (draw* s ((k (g-range 62 400)) (x (g-bits k)) (y (g-sign (+ x (expt 2 61))))) (cons y s))))

;; g-fraction : Nat Nat Nat -> Gen Exact
;; An exact non-integer whose denominator has only 2 and 5 in it: N / (2^a
;; 5^b), N of up to NBITS bits, a and b up to MAXP.
(define (g-fraction nbits maxp)
  (lambda (s)
    (draw* s ((k (g-range 1 nbits)) (n0 (g-bits k)) (n (g-sign n0))
              (a0 (g-range 0 maxp)) (b (g-range 0 maxp)))
      (let* ((a (if (and (= a0 0) (= b 0)) 1 a0))
             (d (* (expt 2 a) (expt 5 b)))
             (q (/ n d)))
        (cons (if (integer? q) (+ q (/ 1 d)) q) s)))))

(define (bits->flonum bits)
  (let ((bv (make-bytevector 8)))
    (bytevector-u64-set! bv 0 bits (endianness big))
    (bytevector-ieee-double-ref bv 0 (endianness big))))

(define g-flonum-random-bits
  (lambda (s)
    (draw* s ((sign (g-range 0 1)) (e (g-range 0 2046)) (m (g-bits 52)))
      (cons (bits->flonum (+ (* sign (expt 2 63)) (* e (expt 2 52)) m)) s))))

(define g-flonum-subnormal
  (lambda (s)
    (draw* s ((sign (g-range 0 1)) (m0 (g-bits 52)))
      (cons (bits->flonum (+ (* sign (expt 2 63)) (max m0 1))) s))))

(define flonum-specials
  (list -0.0 0.0 5e-324 -5e-324 2.2250738585072014e-308 -2.2250738585072014e-308
        2.225073858507201e-308 1.7976931348623157e308 -1.7976931348623157e308
        1e21 1e22 1e23 1e-7 1e-5 0.1 0.5 100.0 3.0 -3.0 123456789012345680000.0
        9007199254740993.0 4.35 1e300 1e-300 12345.678))

(define g-flonum-special (g-pick flonum-specials))

;; A flonum with a short decimal: the nearest to a fraction.
(define g-flonum-decimal
  (lambda (s) (draw* s ((q (g-fraction 40 12))) (cons (inexact q) s))))

(define g-flonum
  (g-choose (list (cons 6 g-flonum-random-bits) (cons 3 g-flonum-subnormal)
                  (cons 3 g-flonum-special) (cons 2 g-flonum-decimal))))

;; g-json-number-text : Gen String
;; JSON number text, in the grammar, that fits a flonum and the default
;; digit limit: a sign, an integer part, a fraction, an exponent.
(define (digits-string n g)
  (lambda (s)
    (draw* s ((ds (g-list n (g-range 0 9))))
      (cons (list->string (map (lambda (d) (integer->char (+ 48 d))) ds)) s))))

(define g-json-number-text
  (lambda (s)
    (draw* s ((neg (g-chance 1 2))
              (int-len (g-range 0 20))
              (lead (g-range 1 9))
              (int-rest (digits-string int-len #f))
              (zero-int (g-chance 1 4))
              (has-frac (g-chance 1 2))
              (frac-len (g-range 1 20))
              (frac (digits-string frac-len #f))
              (has-exp (g-chance 1 2))
              (e-up (g-chance 1 2))
              (e-sign (g-range 0 2))
              (e-val (g-range 0 280))
              (e-pad (g-chance 1 4)))
      (cons (string-append
             (if neg "-" "")
             (if zero-int "0" (string-append (number->string lead) int-rest))
             (if has-frac (string-append "." frac) "")
             (if has-exp
                 (string-append (if e-up "E" "e")
                                (case e-sign ((0) "") ((1) "+") (else "-"))
                                (if e-pad "00" "")
                                (number->string e-val))
                 ""))
            s))))

(define g-json-number
  (lambda (s) (draw* s ((t g-json-number-text)) (cons (list '%jn t) s))))

(define g-number
  (g-choose (list (cons 4 g-fixnum-edge) (cons 4 g-fixnum-random) (cons 2 g-bignum)
                  (cons 7 g-flonum) (cons 5 (g-fraction 64 25)) (cons 4 g-json-number))))

;; --- strings

(define special-chars
  (map integer->char
       '(#x7f #x80 #x7ff #x800 #xd7ff #xe000 #xfffd #xffff #x2028 #x2029
         #x10000 #x1f600 #x10ffff #xe9 #x20ac)))

(define g-char
  (g-choose
   (list (cons 10 (lambda (s) (draw* s ((c (g-range 32 126))) (cons (integer->char c) s))))
         (cons 4 (g-pick (list #\" #\\ #\/ #\space)))
         (cons 7 (lambda (s) (draw* s ((c (g-range 0 31))) (cons (integer->char c) s))))
         (cons 3 (lambda (s) (draw* s ((c (g-range #x80 #x7ff))) (cons (integer->char c) s))))
         (cons 2 (lambda (s) (draw* s ((c (g-range #x800 #xd7ff))) (cons (integer->char c) s))))
         (cons 2 (lambda (s) (draw* s ((c (g-range #xe000 #xffff))) (cons (integer->char c) s))))
         (cons 3 (lambda (s) (draw* s ((c (g-range #x10000 #x10ffff))) (cons (integer->char c) s))))
         (cons 4 (g-pick special-chars)))))

(define all-controls (list->string (map integer->char (iota 32))))
(define every-class
  (string-append all-controls "\"\\/ az\x7f;\xe9;\x7ff;\x800;\x2028;\x2029;\xffff;\x10000;\x10ffff;"))

;; A string, or a key, starts with U+FEFF one time in eight: the reader keeps
;; a leading byte order mark as text (Chez's utf8->string would drop it).
(define (maybe-leading-feff str)
  (lambda (s)
    (draw* s ((feff (g-chance 1 8)))
      (cons (if feff (string-append "\xFEFF;" str) str) s))))

(define (maybe-leading-feff-draw str s)
  ((maybe-leading-feff str) s))

(define g-string
  (g-choose
   (list (cons 30 (lambda (s)
                    (draw* s ((n (g-pick '(0 0 1 2 3 5 8 16))) (cs (g-list n g-char)))
                      (maybe-leading-feff-draw (list->string cs) s))))
         (cons 1 (g-pick (list all-controls every-class "" "\x2028;\x2029;"))))))

;; Keys come from a small pool half the time, so duplicates are common.
(define key-pool '("" "a" "b" "key" "a b" "\"" "\x2028;" "\x10000;" "\n"))
(define g-key (g-choose (list (cons 5 (g-pick key-pool)) (cons 4 g-string))))

;; --- trees

(define (g-scalar)
  (g-choose (list (cons 4 g-string) (cons 8 g-number) (cons 1 (g-const #t))
                  (cons 1 (g-const #f)) (cons 2 (g-const 'NULL-MARK)))))

(define (g-member d)
  (lambda (s) (draw* s ((k g-key) (v (g-tree d))) (cons (cons k v) s))))

(define (g-vector d)
  (lambda (s)
    (draw* s ((n (g-pick '(0 0 1 2 3 4 6))) (xs (g-list n (g-tree d))))
      (cons (list->vector xs) s))))

(define (g-alist d)
  (lambda (s)
    (draw* s ((n (g-pick '(0 0 1 2 3 4 6))) (ms (g-list n (g-member d)))) (cons ms s))))

(define (unique-keys ms)
  (let loop ((ms ms) (seen '()) (kept '()))
    (cond ((null? ms) (reverse kept))
          ((member (caar ms) seen) (loop (cdr ms) seen kept))
          (else (loop (cdr ms) (cons (caar ms) seen) (cons (car ms) kept))))))

(define (g-ht d)
  (lambda (s)
    (draw* s ((ms (g-alist d)))
      (cons (cons '%ht (unique-keys ms)) s))))

;; g-tree : Nat -> Gen GTree
(define (g-tree d)
  (if (= d 0)
      (g-scalar)
      (g-choose (list (cons 6 (g-scalar)) (cons 3 (g-vector (- d 1)))
                      (cons 3 (g-alist (- d 1))) (cons 2 (g-ht (- d 1)))))))

;; g-deep : Gen GTree
;; A chain of 20 to 60 containers, arrays and objects alternating by draw,
;; round a scalar.
(define g-deep
  (lambda (s)
    (draw* s ((n (g-range 20 60)) (leaf (g-scalar)))
      (let loop ((i 0) (t leaf) (s s))
        (if (= i n)
            (cons t s)
            (draw* s ((kind (g-range 0 2)))
              (loop (+ i 1)
                    (case kind
                      ((0) (vector t))
                      ((1) (list (cons "k" t)))
                      (else (list '%ht (cons "" t))))
                    s)))))))

(define g-any-tree
  (g-choose (list (cons 40 (g-tree 5)) (cons 1 g-deep))))

;; five trees to a group
(define (gen-trees s)
  (car ((g-list 5 g-any-tree) s)))

;; --- realizing, expecting ---------------------------------------------------

(define (hashtable-of members null)
  (let ((h (make-hashtable string-hash string=?)))
    (for-each (lambda (m) (hashtable-set! h (car m) (realize (cdr m) null))) members)
    h))

;; realize : GTree Null -> Any
(define (realize t null)
  (cond ((or (string? t) (number? t) (boolean? t)) t)
        ((eq? t 'NULL-MARK) null)
        ((vector? t) (vector-map (lambda (x) (realize x null)) t))
        ((null? t) '())
        ((eq? (car t) '%jn) (make-json-number (cadr t)))
        ((eq? (car t) '%ht) (hashtable-of (cdr t) null))
        (else (map (lambda (m) (cons (car m) (realize (cdr m) null))) t))))

;; The text of a flonum, less Chez's |width suffix on subnormals.
(define (flonum-text x)
  (let* ((s (number->string x)) (n (string-length s)))
    (let loop ((i 0))
      (cond ((= i n) s)
            ((char=? (string-ref s i) #\|) (substring s 0 i))
            (else (loop (+ i 1)))))))

;; The exact decimal expansion of Q, an exact non-integer with a finite
;; decimal, by repeated multiplication by ten.
(define (decimal-text q)
  (let* ((a (abs q))
         (ip (truncate a)))
    (let loop ((f (- a ip)) (ds '()))
      (if (zero? f)
          (string-append (if (negative? q) "-" "") (integer-text ip) "."
                         (list->string (reverse ds)))
          (let* ((g (* f 10)) (d (truncate g)))
            (loop (- g d) (cons (integer->char (+ 48 d)) ds)))))))

;; The decimal text of the exact integer N, by repeated division by ten.
(define (integer-text n)
  (if (zero? n)
      "0"
      (let loop ((m (abs n)) (ds '()))
        (if (zero? m)
            (list->string (if (negative? n) (cons #\- ds) ds))
            (loop (div m 10) (cons (integer->char (+ 48 (mod m 10))) ds))))))

;; The text the writer should have written for number N.
(define (number-text n)
  (cond ((flonum? n) (flonum-text n))
        ((integer? n) (integer-text n))
        (else (decimal-text n))))

(define (exact-of-text text) (string->number (string-append "#e" text)))

;; What reading TEXT, a JSON number, gives in each mode.
(define (read-text text mode)
  (case mode
    ((flonum) (string->number text))
    ((exact) (exact-of-text text))
    (else (list 'json-number text))))

;; expect-number : Number json-options -> Any
;; What the number N reads back as. eqv?-exact in flonum mode (an exact
;; integer stays itself, a flonum stays itself, a fraction becomes the
;; nearest flonum) and in exact mode (a flonum becomes the exact value of
;; its shortest decimal, which is what the text says); through text in text
;; mode.
(define (expect-number n mode)
  (case mode
    ((flonum) (if (and (exact? n) (not (integer? n))) (inexact n) n))
    ((exact) (if (flonum? n) (exact-of-text (flonum-text n)) n))
    (else (list 'json-number (number-text n)))))

(define (sorted-members ms)
  (list-sort (lambda (a b) (string<? (car a) (car b))) ms))

(define (last-wins ms)
  (let loop ((rev (reverse ms)) (seen '()) (kept '()))
    (cond ((null? rev) kept)
          ((member (caar rev) seen) (loop (cdr rev) seen kept))
          (else (loop (cdr rev) (cons (caar rev) seen) (cons (car rev) kept))))))

;; expect : GTree json-options -> Canonical
;; What T reads back as under OPTIONS, from T alone. Under hashtable every
;; object is (hashtable (KEY . V) ...) by key, the last duplicate winning.
;; Under alist an alist keeps every member in order, and a hashtable's
;; members come in the order of their keys.
(define (expect t o)
  (define mode (json-options-number-mode o))
  (define ht? (eq? (json-options-object-mode o) 'hashtable))
  (define (members ms)
    (map (lambda (m) (cons (car m) (expect (cdr m) o))) ms))
  (cond ((string? t) t)
        ((number? t) (expect-number t mode))
        ((boolean? t) t)
        ((eq? t 'NULL-MARK) (json-options-null o))
        ((vector? t) (vector-map (lambda (x) (expect x o)) t))
        ((null? t) (if ht? '(hashtable) '()))
        ((eq? (car t) '%jn) (read-text (cadr t) mode))
        ((eq? (car t) '%ht)
         (let ((ms (sorted-members (members (cdr t)))))
           (if ht? (cons 'hashtable ms) ms)))
        (else
         (if ht?
             (cons 'hashtable (sorted-members (last-wins (members t))))
             (members t)))))

;; --- shrinking ---------------------------------------------------------------

(define (without xs i) (append (list-head* xs i) (list-tail xs (+ i 1))))
(define (list-head* xs i) (if (= i 0) '() (cons (car xs) (list-head* (cdr xs) (- i 1)))))
(define (with-at xs i x) (append (list-head* xs i) (cons x (list-tail xs (+ i 1)))))

;; Smaller lists: one element removed, one replaced by a shrink of it.
(define (list-variants xs shrink-elem)
  (append (map (lambda (i) (without xs i)) (iota (length xs)))
          (apply append
                 (map (lambda (i)
                        (map (lambda (y) (with-at xs i y)) (shrink-elem (list-ref xs i))))
                      (iota (length xs))))))

(define (member-shrinks m)
  (map (lambda (v) (cons (car m) v)) (tree-shrinks (cdr m))))

;; tree-shrinks : GTree -> (Listof GTree)
(define (tree-shrinks t)
  (cond ((string? t)
         (if (string=? t "")
             '()
             (cons "" (map (lambda (i)
                             (string-append (substring t 0 i) (substring t (+ i 1) (string-length t))))
                           (iota (string-length t))))))
        ((number? t) (if (eqv? t 0) '() (list 0)))
        ((vector? t)
         (append (vector->list t)
                 (map list->vector (list-variants (vector->list t) tree-shrinks))))
        ((null? t) '())
        ((pair? t)
         (cond ((eq? (car t) '%jn) (list 0))
               ((eq? (car t) '%ht)
                (append (map cdr (cdr t))
                        (map (lambda (ms) (cons '%ht ms)) (list-variants (cdr t) member-shrinks))))
               (else (append (map cdr t) (list-variants t member-shrinks)))))
        (else '())))

;; --- the tally ------------------------------------------------------------------

(define seen-controls (make-bytevector 32 0))

(define (string-classes str)
  (let ((cs (string->list str)))
    (define (any? p) (exists p cs))
    (define (code c) (char->integer c))
    (for-each (lambda (c) (when (< (code c) 32) (bytevector-u8-set! seen-controls (code c) 1))) cs)
    (append
     (if (null? cs) '(string-empty) '())
     (if (any? (lambda (c) (memv c '(#\backspace #\page #\newline #\return #\tab)))) '(char-ctl-short) '())
     (if (any? (lambda (c) (and (< (code c) 32) (not (memv c '(#\backspace #\page #\newline #\return #\tab)))))) '(char-ctl-long) '())
     (if (any? (lambda (c) (char=? c #\"))) '(char-quote) '())
     (if (any? (lambda (c) (char=? c #\\))) '(char-backslash) '())
     (if (any? (lambda (c) (char=? c #\space))) '(char-space) '())
     (if (any? (lambda (c) (<= 33 (code c) 126))) '(char-ascii) '())
     (if (any? (lambda (c) (= (code c) #x7f))) '(char-del) '())
     (if (any? (lambda (c) (<= #x80 (code c) #x7ff))) '(char-utf8-2) '())
     (if (any? (lambda (c) (<= #x800 (code c) #xffff))) '(char-utf8-3) '())
     (if (any? (lambda (c) (>= (code c) #x10000))) '(char-utf8-4) '())
     (if (any? (lambda (c) (= (code c) #x2028))) '(char-u2028) '())
     (if (any? (lambda (c) (= (code c) #x2029))) '(char-u2029) '()))))

(define (leading-feff? str)
  (and (> (string-length str) 0) (char=? (string-ref str 0) #\xFEFF)))

(define (number-class n)
  (cond ((flonum? n)
         (cond ((eqv? n -0.0) 'flonum-negative-zero)
               ((eqv? n 0.0) 'flonum-zero)
               ((< (abs n) 2.2250738585072014e-308) 'flonum-subnormal)
               ((> (abs n) 1e300) 'flonum-huge)
               (else 'flonum-normal)))
        ((fixnum? n) (if (< (abs n) 1000000000) 'fixnum-short 'fixnum-10-digits-or-more))
        ((integer? n) 'bignum)
        (else 'fraction)))

(define (duplicate-keys? ms)
  (let loop ((ms ms) (seen '()))
    (and (pair? ms)
         (or (and (member (caar ms) seen) #t) (loop (cdr ms) (cons (caar ms) seen))))))

;; classify! : Tally GTree -> Unit
(define (classify! tally t)
  (define (count! k) (tally! tally k))
  (define (strng! str) (for-each count! (string-classes str)))
  (let walk ((t t) (depth 0))
    (define (members! ms)
      (when (null? ms) (count! 'object-empty))
      (when (duplicate-keys? ms) (count! 'object-duplicate-keys))
      (for-each (lambda (m)
                  (when (string=? (car m) "") (count! 'key-empty))
                  (when (leading-feff? (car m)) (count! 'key-leading-feff))
                  (strng! (car m))
                  (walk (cdr m) (+ depth 1)))
                ms))
    (when (> depth 4) (count! 'depth-5-or-more))
    (when (> depth 19) (count! 'depth-20-or-more))
    (cond ((string? t) (count! 'string) (when (leading-feff? t) (count! 'string-leading-feff)) (strng! t))
          ((number? t) (count! (number-class t)))
          ((eq? t #t) (count! 'true))
          ((eq? t #f) (count! 'false))
          ((eq? t 'NULL-MARK) (count! 'null))
          ((vector? t)
           (count! 'array)
           (when (= (vector-length t) 0) (count! 'array-empty))
           (vector-for-each (lambda (x) (walk x (+ depth 1))) t))
          ((null? t) (count! 'object) (count! 'object-alist) (count! 'object-empty))
          ((eq? (car t) '%jn) (count! 'json-number))
          ((eq? (car t) '%ht) (count! 'object) (count! 'object-hashtable) (members! (cdr t)))
          (else (count! 'object) (count! 'object-alist) (members! t)))))

;; --- the properties' common shape ---------------------------------------------------

;; (round-trip-check options) : GTree -> (U #f Evidence)
(define (round-trip-check o)
  (lambda (t)
    (let* ((bytes (write-bytes (realize t (json-options-null o)) o))
           (want (list 'ok (expect t o)))
           (got (read-canonical bytes o)))
      (and (not (equal? want got))
           (list 'wrote (bv->text bytes) 'wanted want 'got got)))))

(define (round-trip-failures name prop o)
  (property-failures run name prop 600 gen-trees (round-trip-check o) tree-shrinks (make-tally)))

;; --- 1. the generator ------------------------------------------------------------------

(test-begin "writer-property")

(define gen-tally (make-tally))

(test-equal "generator: 2000 trees are drawn, each is a tree of the kinds, and the tally is printed"
  '()
  (property-failures run 'generator 0 400 gen-trees
                     (lambda (t) (classify! gen-tally t) #f)
                     tree-shrinks gen-tally))

(define (tally-count k)
  (let ((p (assq k (tally-counts gen-tally)))) (if p (cdr p) 0)))

;; Each class must have appeared at least this often in a run of 2000
;; trees (at multiplier 1; more at a larger one).
(define required-classes
  '((true . 100) (false . 100) (null . 100) (string . 500) (array . 500) (array-empty . 50)
    (object . 500) (object-alist . 300) (object-hashtable . 100) (object-empty . 50)
    (object-duplicate-keys . 30) (key-empty . 30)
    (fixnum-short . 100) (fixnum-10-digits-or-more . 100) (bignum . 30)
    (flonum-normal . 100) (flonum-subnormal . 30) (flonum-negative-zero . 10)
    (flonum-zero . 10) (flonum-huge . 20) (fraction . 100) (json-number . 100)
    (string-empty . 30) (string-leading-feff . 100) (key-leading-feff . 100) (char-ctl-short . 100) (char-ctl-long . 100) (char-quote . 100)
    (char-backslash . 100) (char-space . 100) (char-ascii . 500) (char-del . 20)
    (char-utf8-2 . 100) (char-utf8-3 . 100) (char-utf8-4 . 100)
    (char-u2028 . 20) (char-u2029 . 20) (depth-5-or-more . 20) (depth-20-or-more . 5)))

(test-equal "generator: every class of value, string, number and shape appeared often enough"
  '()
  (filter (lambda (p) p)
          (map (lambda (r) (and (< (tally-count (car r)) (cdr r))
                                (list (car r) 'wanted (cdr r) 'drew (tally-count (car r)))))
               required-classes)))

(test-equal "generator: every one of the 32 control characters appeared in a string"
  (make-bytevector 32 1)
  seen-controls)

;; --- 2. the round trip ----------------------------------------------------------------

(define option-sets
  (list
   (cons 'defaults (opts))
   (cons 'indent2-hashtable (opts 'indent 2 'object-mode 'hashtable))
   (cons 'indent4-nil-exact (opts 'indent 4 'null 'nil 'number-mode 'exact))
   (cons 'record-null-indent2 (opts 'null nil-a 'indent 2))
   (cons 'text-hashtable-void-indent4
         (opts 'number-mode 'text 'object-mode 'hashtable 'null 'void 'indent 4))
   (cons 'exact-hashtable-record
         (opts 'number-mode 'exact 'object-mode 'hashtable 'null nil-b))
   (cons 'text-indent2 (opts 'number-mode 'text 'indent 2))))

(define (option-set-prop i) (+ 10 i))

(for-each
 (lambda (i)
   (test-equal (string-append "round trip: "
                              (symbol->string (car (list-ref option-sets i)))
                              ": every tree reads back as the tree says")
     '()
     (round-trip-failures (string->symbol
                           (string-append "round-trip-"
                                          (symbol->string (car (list-ref option-sets i)))))
                          (option-set-prop i)
                          (cdr (list-ref option-sets i)))))
 (iota (length option-sets)))

;; --- 3. the digit limit -----------------------------------------------------------------

(define (write-top n o) (write-bytes n o))

(define (first-two r) (list (car r) (cadr r) (if (eq? (car r) 'failed) (caddr r) 'none)))

(define digits-1000 (expt 10 999))
(define digits-1001 (expt 10 1000))
;; 1/2^1100 has 1100 places after the point.
(define long-fraction (/ 1 (expt 2 1100)))

(test-equal "digit limit: a 1000-digit integer is read back by the default reader, eqv?"
  (list 'ok #t)
  (let ((r (read-raw (write-top digits-1000 (opts)) (opts))))
    (list (car r) (and (eq? (car r) 'ok) (eqv? (cadr r) digits-1000)))))

(test-equal "digit limit: the writer writes a 1001-digit integer, and the default reader refuses it, number-too-long"
  (list 1001 '(failed error number-too-long))
  (let ((bytes (write-top digits-1001 (opts))))
    (list (bytevector-length bytes) (read-raw bytes (opts)))))

(test-equal "digit limit: the writer writes a fraction of 1101 digits, and the default reader refuses it in exact mode, number-too-long"
  (list 1102 '(failed error number-too-long))
  (let ((bytes (write-top long-fraction (opts))))
    (list (bytevector-length bytes) (read-raw bytes (opts 'number-mode 'exact)))))

(test-equal "digit limit: a larger limit reads both back, eqv?"
  '((ok #t) (ok #t))
  (let ((o (opts 'number-mode 'exact 'digit-limit 2000)))
    (map (lambda (n)
           (let ((r (read-raw (write-top n o) o)))
             (list (car r) (and (eq? (car r) 'ok) (eqv? (cadr r) n)))))
         (list digits-1001 long-fraction))))

;; --- 4. ADR-0011's number property ------------------------------------------------------

;; Cases are numbers; a group is 20 cases.
(define (cases-of g)
  (lambda (s) (car ((g-list 20 g) s))))

(define (number-shrinks n) (if (eqv? n 0) '() (list 0 (if (integer? n) (div n 2) (numerator n)))))

(define g-exact
  (g-choose (list (cons 3 g-fixnum-edge) (cons 3 g-fixnum-random) (cons 2 g-bignum)
                  (cons 8 (g-fraction 120 40)))))

;; check-exact : Number -> (U #f Evidence)
(define (check-exact n)
  (let* ((o (opts 'number-mode 'exact 'digit-limit 5000))
         (bytes (write-bytes n o))
         (got (read-raw bytes o)))
    (and (not (and (eq? (car got) 'ok) (eqv? (cadr got) n)))
         (list 'wrote (bv->text bytes) 'got got))))

(define exact-tally (make-tally))

(test-equal "numbers: every exact integer and fraction with a finite decimal is read back eqv? in exact mode (12000 cases)"
  '()
  (property-failures run 'exact-numbers 40 600 (cases-of g-exact)
                     (lambda (n)
                       (tally! exact-tally (if (integer? n) 'integer 'fraction))
                       (check-exact n))
                     number-shrinks
                     exact-tally))

(define g-flonum-all
  (g-choose (list (cons 10 g-flonum) (cons 2 (lambda (s)
                                              (draw* s ((k (g-range 1 60)) (x (g-bits k)))
                                                (cons (inexact x) s)))))))

(define (check-flonum x)
  (let* ((o (opts))
         (bytes (write-bytes x o))
         (got (read-raw bytes o)))
    (and (not (and (eq? (car got) 'ok) (eqv? (cadr got) x)))
         (list 'wrote (bv->text bytes) 'got got))))

(define flonum-tally (make-tally))

(test-equal "numbers: every finite flonum is read back eqv? in flonum mode, -0.0, subnormals and extremes included (20000 cases)"
  '()
  (property-failures run 'flonums 41 1000 (cases-of g-flonum-all)
                     (lambda (x)
                       (tally! flonum-tally (number-class x))
                       (check-flonum x))
                     (lambda (x) (if (eqv? x 0.0) '() (list 0.0 1.0)))
                     flonum-tally))

(define (check-json-number text)
  (let* ((o (opts 'number-mode 'text))
         (bytes (write-bytes (make-json-number text) o))
         (got (read-raw bytes o)))
    (and (not (and (eq? (car got) 'ok) (json-number? (cadr got))
                   (string=? (json-number-text (cadr got)) text)))
         (list 'wrote (bv->text bytes)
               'got (if (eq? (car got) 'ok) (canonical (cadr got)) got)))))

(test-equal "numbers: every json-number is read back in text mode with its exact text, and written as that text (12000 cases)"
  '()
  (property-failures run 'json-numbers 42 600 (cases-of g-json-number-text)
                     (lambda (text)
                       (or (check-json-number text)
                           (let ((bytes (write-bytes (make-json-number text) (opts))))
                             (and (not (bytevector=? bytes (string->utf8 text)))
                                  (list 'wrote (bv->text bytes) 'wanted text)))))
                     (lambda (text) '())
                     (make-tally)))

;; --- 5. the corpus as a fixed point ----------------------------------------------------

(define jts-dir "tests/corpus/jsontestsuite/test_parsing/")
(define yajl-dir "tests/corpus/yajl/cases/")

(define corpus
  (append
   (map (lambda (f) (cons (string-append jts-dir f) (file-bytes (string-append jts-dir f))))
        (corpus-files jts-dir ".json"))
   (map (lambda (f) (cons (string-append yajl-dir f) (file-bytes (string-append yajl-dir f))))
        (corpus-files yajl-dir ".json"))))

(define corpus-option-sets
  (list (cons 'defaults (opts))
        (cons 'text (opts 'number-mode 'text))
        (cons 'hashtable (opts 'object-mode 'hashtable))
        (cons 'indent2 (opts 'indent 2))))

;; fixed-point : Bytevector json-options -> (U 'rejected #f Evidence)
;; The reader rejects: 'rejected, and the file does not take part.
;; Otherwise read, write, read: the same canonical tree; write again: the
;; first output's bytes.
(define (fixed-point bv o)
  (let ((first (read-raw bv o)))
    (if (not (eq? (car first) 'ok))
        'rejected
        (let* ((out1 (write-bytes (cadr first) o))
               (second (read-raw out1 o)))
          (cond ((not (eq? (car second) 'ok))
                 (list 'wrote (bv->text out1) 'reread second))
                ((not (equal? (canonical (cadr first)) (canonical (cadr second))))
                 (list 'tree-changed (canonical (cadr first)) (canonical (cadr second))))
                (else
                 (let ((out2 (write-bytes (cadr second) o)))
                   (and (not (bytevector=? out1 out2))
                        (list 'second-output-differs (bv->text out1) (bv->text out2))))))))))

;; corpus-run : json-options -> (List Nat (Listof Failure))
;; How many files took part, and the ones that failed.
(define (corpus-run o)
  (let loop ((fs corpus) (took 0) (bad '()))
    (if (null? fs)
        (list took (reverse bad))
        (let ((r (fixed-point (cdar fs) o)))
          (cond ((eq? r 'rejected) (loop (cdr fs) took bad))
                ((not r) (loop (cdr fs) (+ took 1) bad))
                (else (loop (cdr fs) (+ took 1) (cons (list (caar fs) r) bad))))))))

(define corpus-runs
  (map (lambda (p) (cons (car p) (corpus-run (cdr p)))) corpus-option-sets))

(test-equal "corpus: there are 376 files, JSONTestSuite and yajl"
  376
  (length corpus))

(for-each
 (lambda (p)
   (test-equal (string-append "corpus: " (symbol->string (car p))
                              ": every file taking part is a fixed point of read, write, read")
     '()
     (caddr (assq (car p) corpus-runs))))
 corpus-option-sets)

;; The files that took part, counted in this run by CORPUS-RUN. 130 files
;; are valid to the grammar's machine (106 of JSONTestSuite, 24 of yajl), and
;; text mode reads all of them; the other modes also refuse the five whose
;; numbers overflow a flonum (the i_number_*huge_exp and *overflow files).
(test-equal "corpus: text mode takes part with exactly the files the grammar's machine accepts"
  (list 130 130)
  (list (cadr (assq 'text corpus-runs))
        (length (filter (lambda (f) (string=? (golden-line "x" (cdr f)) "x accepted")) corpus))))

(test-equal "corpus: the files that took part (125, 130, 125, 125), under defaults, text, hashtable and indent 2"
  '(125 130 125 125)
  (map (lambda (p) (cadr (assq (car p) corpus-runs))) corpus-option-sets))

;; --- 6. the layout changes nothing --------------------------------------------------------

(define (whitespace? b) (memv b '(32 10 9 13)))

;; strip-layout : Bytevector -> Bytevector
;; BV without the whitespace outside strings. A string starts at a quote and
;; ends at the next quote that no backslash escapes.
(define (strip-layout bv)
  (let-values (((port get) (open-bytevector-output-port)))
    (let loop ((i 0) (in-string #f) (escaped #f))
      (when (< i (bytevector-length bv))
        (let ((b (bytevector-u8-ref bv i)))
          (cond (in-string
                 (put-u8 port b)
                 (loop (+ i 1) (not (and (not escaped) (= b 34))) (and (not escaped) (= b 92))))
                ((whitespace? b) (loop (+ i 1) #f #f))
                (else (put-u8 port b) (loop (+ i 1) (= b 34) #f))))))
    (get)))

;; lay-out : Bytevector Nat -> Bytevector
;; The compact output BV laid out at INDENT: a container with members opens,
;; and each member goes on its own line, one level in; a colon is followed by
;; a space; the close goes on its own line at the container's level; an
;; empty container stays [] or {}.
(define (lay-out bv indent)
  (let-values (((port get) (open-bytevector-output-port)))
    (define (newline-at depth)
      (put-u8 port 10)
      (for-each (lambda (_) (put-u8 port 32)) (iota (* indent depth))))
    (let loop ((i 0) (depth 0) (in-string #f) (escaped #f))
      (when (< i (bytevector-length bv))
        (let ((b (bytevector-u8-ref bv i)))
          (cond (in-string
                 (put-u8 port b)
                 (loop (+ i 1) depth (not (and (not escaped) (= b 34))) (and (not escaped) (= b 92))))
                ((= b 34) (put-u8 port b) (loop (+ i 1) depth #t #f))
                ((memv b '(91 123))
                 (put-u8 port b)
                 (if (and (< (+ i 1) (bytevector-length bv))
                          (memv (bytevector-u8-ref bv (+ i 1)) '(93 125)))
                     (begin (put-u8 port (bytevector-u8-ref bv (+ i 1)))
                            (loop (+ i 2) depth #f #f))
                     (begin (newline-at (+ depth 1))
                            (loop (+ i 1) (+ depth 1) #f #f))))
                ((memv b '(93 125))
                 (newline-at (- depth 1))
                 (put-u8 port b)
                 (loop (+ i 1) (- depth 1) #f #f))
                ((= b 44) (put-u8 port b) (newline-at depth) (loop (+ i 1) depth #f #f))
                ((= b 58) (put-u8 port b) (put-u8 port 32) (loop (+ i 1) depth #f #f))
                (else (put-u8 port b) (loop (+ i 1) depth #f #f))))))
    (get)))

(define layout-indents '(1 2 7))
(define layout-sets
  (list (cons 'defaults '())
        (cons 'hashtable-nil-exact '(object-mode hashtable null nil number-mode exact))
        (cons 'text-record '(number-mode text null nothing))))

(define (layout-options set indent)
  (apply opts 'indent indent
         (let loop ((xs (cdr set)))
           (cond ((null? xs) '())
                 (else (cons (car xs)
                             (cons (if (eq? (cadr xs) 'nothing) nil-a (cadr xs))
                                   (loop (cddr xs)))))))))

;; (layout-check) : GTree -> (U #f Evidence)
(define (layout-check what)
  (lambda (t)
    (let loop ((sets layout-sets))
      (and (pair? sets)
           (let* ((o0 (layout-options (car sets) 0))
                  (v (realize t (json-options-null o0)))
                  (compact (write-bytes v o0))
                  (want (list 'ok (expect t o0)))
                  (bad
                   (let inner ((ks layout-indents))
                     (and (pair? ks)
                          (let* ((o (layout-options (car sets) (car ks)))
                                 (out (write-bytes v o)))
                            (or (case what
                                  ((reads)
                                   (let ((got (read-canonical out o)))
                                     (and (not (equal? got want))
                                          (list 'indent (car ks) 'wrote (bv->text out) 'got got))))
                                  ((strips)
                                   (let ((s (strip-layout out)))
                                     (and (not (bytevector=? s compact))
                                          (list 'indent (car ks) 'wrote (bv->text out)
                                                'stripped (bv->text s) 'compact (bv->text compact)))))
                                  (else
                                   (let ((l (lay-out compact (car ks))))
                                     (and (not (bytevector=? l out))
                                          (list 'indent (car ks) 'wrote (bv->text out)
                                                'laid-out (bv->text l))))))
                                (inner (cdr ks))))))))
             (or (and bad (cons (caar sets) bad)) (loop (cdr sets))))))))

(define layout-tally (make-tally))

(test-equal "layout: indents 1, 2 and 7 all read back to the tree the indent 0 output does"
  '()
  (property-failures run 'layout-reads 50 300 gen-trees (layout-check 'reads) tree-shrinks
                     layout-tally))

(test-equal "layout: the output with the whitespace outside strings removed is the compact output"
  '()
  (property-failures run 'layout-strips 51 300 gen-trees (layout-check 'strips) tree-shrinks
                     (make-tally)))

(test-equal "layout: the output is the compact output laid out again by the lexer here"
  '()
  (property-failures run 'layout-relaid 52 300 gen-trees (layout-check 'relaid) tree-shrinks
                     (make-tally)))

(test-end "writer-property")

(exit (suite-exit-status runner))
