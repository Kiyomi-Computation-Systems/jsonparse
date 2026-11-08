#!r6rs
;;; tests/test-easy-property.sps: (jsonparse easy) checked against the low
;;; layer and against oracles written here (ADR-0019, ADR-0010).
;;;
;;; Usage: test-easy-property.sps [SEED [MULTIPLIER]]
;;;
;;; 1. Conformance through both layers. Every file of the JSONTestSuite, of
;;;    yajl's cases and of nativejson-benchmark's round-trip files, under six
;;;    option sets (the defaults among them),
;;;    read by bytevector->json, by read-json on a port (from its start,
;;;    and after a 3-byte prefix was taken), and by string->json when the
;;;    bytes are valid UTF-8. The answer to match is a builder's from
;;;    (jsonparse tree) fed the same bytes: the same value as canonical
;;;    makes it, or a &json-error with the builder's code and offset. For a
;;;    string the offset is counted here: the characters before that byte,
;;;    walking the string and adding each character's UTF-8 size. The
;;;    totals are asserted: files accepted and rejected, strings read, and
;;;    the set of reasons seen. This is also the "both layers return the
;;;    same values" check.
;;; 2. Character offsets under mutation. Corpus texts that are valid UTF-8
;;;    with 1 or 2 edits (insert, delete, replace 1 to 4 characters from a
;;;    pool of 1- to 4-byte characters, U+FEFF, U+2028, quotes, backslashes,
;;;    digits, structure). On an error: string->json's offset is the
;;;    independent count of the byte offset, the reasons agree, and the byte
;;;    offset is a character's first byte or the end.
;;; 3. json=? against oracles written here, on generated values: reflexive
;;;    and on copies (hashtables into fresh tables); symmetric and equal to
;;;    the oracle on every pair; member order (shuffled objects equal; one
;;;    changed leaf, or one added member, not); duplicate keys against the
;;;    last-wins alist and against the hashtable as-hashtables describes;
;;;    numbers by exact value across spellings, near misses, flonums
;;;    against their printed decimals; and a table of known answers.
;;; 4. Alists and hashtables agree: every corpus file read both ways gives
;;;    json=? values, json-ref gives json=? answers along every path to a
;;;    member, under alists it gives the last member's value (an oracle
;;;    here), and a missing step raises not-found with the steps. With a
;;;    default, a path to a member gives the same, and a missing step gives
;;;    the default.
;;; 5. Round trips under six option sets: json->string then string->json,
;;;    json->bytevector then bytevector->json, and read-json, are json=? to
;;;    the value; the string's UTF-8 is the bytevector; write-json writes
;;;    the same bytes.
;;;
;;; A gtree is plain data so a failing case prints whole: NULL-MARK is the
;;; options' null; (%jn TEXT) a json-number; (%ht (KEY . V) ...) a
;;; hashtable; a list of pairs an alist; a vector an array.
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
        (jsonparse easy))

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

(define default-seed 20261107)
(define parsed (parse-property-arguments (cdr (command-line)) default-seed))
(unless parsed
  (put-string (current-error-port)
              "usage: test-easy-property.sps [SEED [MULTIPLIER]]  (decimal digits)\n")
  (exit 1))
(define run (make-property-run "easy-property" (car parsed) (cadr parsed)))

;; --- small helpers --------------------------------------------------------------

(define (iota n) (let loop ((i (- n 1)) (acc '())) (if (< i 0) acc (loop (- i 1) (cons i acc)))))
(define (opts . args) (apply make-json-options args))
(define (no-shrinks k) '())

(define-record-type nothing (fields tag))
(define nil-record (make-nothing 'same))

;; outcome : (-> Any) -> (U (List 'ok Any) (List 'error Symbol Offset) (List 'raised String))
;; Only a &json-error is an answer; any other raise is tagged too, so a raise
;; never equals #f or any expected value.
(define (outcome thunk)
  (guard (e ((json-error? e) (list 'error (json-error-reason e) (json-error-offset e)))
            (#t (list 'raised (describe e))))
    (list 'ok (thunk))))

(define (outcome-c thunk) (outcome (lambda () (canonical (thunk)))))

(define (jeq a b . o) (outcome (lambda () (apply json=? a b o))))

;; The answer of a builder from (jsonparse tree) fed BV whole.
(define (builder-outcome bv o)
  (let* ((b (make-json-builder o))
         (r (json-builder-feed! b bv))
         (r (if (eq? (json-result-status r) 'error) r (json-builder-finish! b))))
    (if (eq? (json-result-status r) 'finished)
        (list 'ok (canonical (json-builder-value b)))
        (list 'error (json-result-code r) (json-result-offset r)))))

(define (bv-append a b)
  (let ((r (make-bytevector (+ (bytevector-length a) (bytevector-length b)))))
    (bytevector-copy! a 0 r 0 (bytevector-length a))
    (bytevector-copy! b 0 r (bytevector-length a) (bytevector-length b))
    r))

(define (sub-bv bv from)
  (let ((r (make-bytevector (- (bytevector-length bv) from))))
    (bytevector-copy! bv from r 0 (bytevector-length r))
    r))

;; decode : Bytevector -> (U String #f)
;; The string BV is the UTF-8 of, or #f. Chez's utf8->string drops a leading
;; U+FEFF (ADR-0016), so the leading marks are counted and put back; validity
;; is whether the string encodes back to BV.
(define (decode bv)
  (let loop ((start 0) (marks 0))
    (if (and (<= (+ start 3) (bytevector-length bv))
             (= (bytevector-u8-ref bv start) #xEF)
             (= (bytevector-u8-ref bv (+ start 1)) #xBB)
             (= (bytevector-u8-ref bv (+ start 2)) #xBF))
        (loop (+ start 3) (+ marks 1))
        (let ((s (string-append (make-string marks #\xFEFF) (utf8->string (sub-bv bv start)))))
          (and (bytevector=? (string->utf8 s) bv) s)))))

(define (utf8-size c)
  (let ((n (char->integer c)))
    (cond ((< n #x80) 1) ((< n #x800) 2) ((< n #x10000) 3) (else 4))))

;; chars-before : String Nat -> (U Nat 'not-boundary)
;; How many characters of S come before byte OFF of its UTF-8: found by adding
;; up the characters' sizes, and 'not-boundary if OFF falls inside one.
(define (chars-before s off)
  (let loop ((i 0) (bytes 0))
    (cond ((= bytes off) i)
          ((or (> bytes off) (= i (string-length s))) 'not-boundary)
          (else (loop (+ i 1) (+ bytes (utf8-size (string-ref s i))))))))

;; What reading S must give, given the builder's answer on its bytes.
(define (string-expected ref s)
  (if (eq? (car ref) 'ok)
      ref
      (list 'error (cadr ref) (chars-before s (caddr ref)))))

(define (read-port bv o)
  (outcome-c (lambda () (read-json (open-bytevector-input-port bv) o))))

(define (read-port-after-prefix bv o)
  (let ((p (open-bytevector-input-port (bv-append (make-bytevector 3 120) bv))))
    (get-bytevector-n p 3)
    (outcome-c (lambda () (read-json p o)))))

(define (distinct xs)
  (let loop ((xs xs) (seen '()))
    (cond ((null? xs) (reverse seen))
          ((memq (car xs) seen) (loop (cdr xs) seen))
          (else (loop (cdr xs) (cons (car xs) seen))))))

(define (symbols-sorted xs)
  (list-sort (lambda (a b) (string<? (symbol->string a) (symbol->string b))) xs))

(define (tally-count tally k)
  (let ((p (assq k (tally-counts tally)))) (if p (cdr p) 0)))

(test-begin "easy-property")

;; The oracles of section 1 and 2, on cases worked out by hand.
(test-equal "oracle: chars-before counts characters, refuses an offset inside one, and accepts the end"
  '(0 1 not-boundary 2 not-boundary not-boundary 3 4 5)
  (let ((s "a\xe9;\x20ac;\x1F600;b"))
    (map (lambda (off) (chars-before s off)) '(0 1 2 3 4 5 6 10 11))))

(define (bv . xs) (u8-list->bytevector xs))

(test-equal "oracle: decode keeps every leading U+FEFF, and refuses bytes that are not UTF-8"
  (list "\xFEFF;a" "\xFEFF;\xFEFF;" "" #f #f #f "\x10FFFF;")
  (map decode (list (bv 239 187 191 97) (bv 239 187 191 239 187 191) (bv)
                    (bv 192 128) (bv 237 160 128) (bv 255)
                    (bv 244 143 191 191))))

;; --- 1. conformance through both layers ------------------------------------------

(define suite-dir "tests/corpus/jsontestsuite/test_parsing")
(define yajl-dir "tests/corpus/yajl/cases")
(define nj-dir "tests/corpus/nativejson-benchmark/files")

(define corpus
  (append (map (lambda (n) (cons (string-append "j:" n) (file-bytes (string-append suite-dir "/" n))))
               (corpus-files suite-dir ".json"))
          (map (lambda (n) (cons (string-append "y:" n) (file-bytes (string-append yajl-dir "/" n))))
               (corpus-files yajl-dir ".json"))
          (map (lambda (n) (cons (string-append "n:" n) (file-bytes (string-append nj-dir "/" n))))
               (corpus-files nj-dir ".json"))))

(define option-sets
  (list (cons 'defaults (opts))
        (cons 'hashtable-text (opts 'object-mode 'hashtable 'number-mode 'text))
        (cons 'exact-digits-30 (opts 'number-mode 'exact 'digit-limit 30))
        (cons 'depth-3-nil (opts 'depth-limit 3 'null 'nil))
        (cons 'hashtable-record-digits-5
              (opts 'object-mode 'hashtable 'null nil-record 'digit-limit 5))
        (cons 'text-depth-600 (opts 'number-mode 'text 'depth-limit 600))))

(define corpus-reasons '())          ; every reason a builder gave on the corpus
(define corpus-strings '())          ; the files that decode, with their strings

(define (section-1 set-name o)
  (let ((bad-bytes '()) (bad-port '()) (bad-prefix '()) (bad-string '())
        (accepted 0) (rejected 0) (strings 0) (reads 0) (string-offsets-moved 0))
    (for-each
     (lambda (file)
       (let* ((name (car file)) (bv (cdr file))
              (ref (builder-outcome bv o))
              (s (decode bv)))
         (if (eq? (car ref) 'ok)
             (set! accepted (+ accepted 1))
             (begin (set! rejected (+ rejected 1))
                    (set! corpus-reasons (cons (cadr ref) corpus-reasons))))
         (let ((got (outcome-c (lambda () (bytevector->json bv o)))))
           (set! reads (+ reads 1))
           (unless (equal? got ref) (set! bad-bytes (cons (list name got ref) bad-bytes))))
         (let ((got (read-port bv o)))
           (set! reads (+ reads 1))
           (unless (equal? got ref) (set! bad-port (cons (list name got ref) bad-port))))
         (let ((got (read-port-after-prefix bv o)))
           (set! reads (+ reads 1))
           (unless (equal? got ref) (set! bad-prefix (cons (list name got ref) bad-prefix))))
         (when s
           (set! strings (+ strings 1))
           (set! reads (+ reads 1))
           (let ((want (string-expected ref s))
                 (got (outcome-c (lambda () (string->json s o)))))
             (when (and (eq? (car ref) 'error) (not (= (caddr ref) (caddr want))))
               (set! string-offsets-moved (+ string-offsets-moved 1)))
             (unless (equal? got want) (set! bad-string (cons (list name got want) bad-string)))))))
     corpus)
    (let ((label (symbol->string set-name)))
      (test-equal (string-append "conformance " label ": bytevector->json is the builder's answer")
        '() (reverse bad-bytes))
      (test-equal (string-append "conformance " label ": read-json on a port is the builder's answer")
        '() (reverse bad-port))
      (test-equal (string-append "conformance " label ": read-json after a prefix is the builder's")
        '() (reverse bad-prefix))
      (test-equal (string-append "conformance " label ": string->json is the builder's, offset in characters")
        '() (reverse bad-string)))
    (list accepted rejected strings reads)))

(define section-1-totals
  (map (lambda (p) (cons (car p) (section-1 (car p) (cdr p)))) option-sets))

(test-equal "conformance: the corpus has 318 JSONTestSuite files, 58 yajl cases and 27 round-trip files"
  '(403 318 58 27)
  (list (length corpus)
        (length (filter (lambda (f) (char=? (string-ref (car f) 0) #\j)) corpus))
        (length (filter (lambda (f) (char=? (string-ref (car f) 0) #\y)) corpus))
        (length (filter (lambda (f) (char=? (string-ref (car f) 0) #\n)) corpus))))

(test-equal "conformance: files accepted and rejected, strings read, and reads made, per option set"
  '((defaults 152 251 376 1585)
    (hashtable-text 157 246 376 1585)
    (exact-digits-30 141 262 376 1585)
    (depth-3-nil 150 253 376 1585)
    (hashtable-record-digits-5 127 276 376 1585)
    (text-depth-600 157 246 376 1585))
  section-1-totals)

(test-equal "conformance: the reasons the builder gave on the corpus"
  '(control-character invalid-escape invalid-number invalid-surrogate invalid-utf8
    nesting-too-deep number-out-of-range number-too-long trailing-garbage unexpected-byte
    unexpected-eof)
  (symbols-sorted (distinct corpus-reasons)))

;; --- 2. character offsets under mutation --------------------------------------------

(define texts
  (list->vector
   (filter (lambda (s) (and s (<= (string-length s) 2500)))
           (map (lambda (f) (decode (cdr f))) corpus))))

(define pool
  (list->vector
   (map (lambda (n) (integer->char n))
        '(#x61 #x30 #x39 #x22 #x5c #x7b #x7d #x5b #x5d #x2c #x3a #x2d #x2e #x65 #x45 #x2b
          #x20 #x0a #x09 #x00 #x1f #x74 #x6e #xe9 #x7ff #x800 #x20ac #xfffd #xffff #xfeff #x2028
          #x2029 #x10000 #x1f600 #x10ffff #x75))))

(define (g-pool-char s) (draw* s ((i (g-int (vector-length pool)))) (cons (vector-ref pool i) s)))

;; An edit: (KIND R CHARS), KIND insert, delete or replace; R places it.
(define g-edit
  (lambda (s)
    (draw* s ((kind (g-pick '(insert delete replace))) (r (g-int 30000))
              (n (g-range 1 4)) (cs (g-list n g-pool-char)))
      (cons (list kind r cs) s))))

(define (apply-edit str edit)
  (let* ((kind (car edit)) (r (cadr edit)) (cs (caddr edit)) (n (string-length str)))
    (case kind
      ((insert)
       (let ((at (mod r (+ n 1))))
         (string-append (substring str 0 at) (list->string cs) (substring str at n))))
      (else
       (if (= n 0)
           str
           (let* ((at (mod r n))
                  (len (min (length cs) (- n at))))
             (string-append (substring str 0 at)
                            (if (eq? kind 'replace) (list->string (list-head cs len)) "")
                            (substring str (+ at len) n))))))))

(define (list-head xs k) (if (= k 0) '() (cons (car xs) (list-head (cdr xs) (- k 1)))))

(define g-mutation-case
  (lambda (s)
    (draw* s ((i (g-int (vector-length texts))) (k (g-range 1 2)) (edits (g-list k g-edit))
              (o (g-int (length option-sets))))
      (cons (list i edits o) s))))

(define (gen-mutations s) (car ((g-list 10 g-mutation-case) s)))

(define mutation-tally (make-tally))
(define mutation-reasons '())

(define (mutation-check kase)
  (let* ((str (fold-left apply-edit (vector-ref texts (car kase)) (cadr kase)))
         (o (cdr (list-ref option-sets (caddr kase))))
         (bv (string->utf8 str))
         (ref (builder-outcome bv o))
         (b (outcome-c (lambda () (bytevector->json bv o))))
         (got (outcome-c (lambda () (string->json str o)))))
    (cond
      ((not (equal? b ref)) (list 'bytevector b 'wanted ref))
      ((eq? (car ref) 'ok)
       (tally! mutation-tally 'accepted)
       (and (not (equal? got ref)) (list 'string got 'wanted ref)))
      (else
       (let ((n (chars-before str (caddr ref))))
         (tally! mutation-tally 'rejected)
         (set! mutation-reasons (cons (cadr ref) mutation-reasons))
         (when (and (integer? n) (not (= n (caddr ref)))) (tally! mutation-tally 'offset-moved))
         (when (= (caddr ref) (bytevector-length bv)) (tally! mutation-tally 'at-end))
         (cond ((eq? n 'not-boundary) (list 'offset-inside-a-character ref))
               ((not (equal? got (list 'error (cadr ref) n))) (list 'string got 'wanted (list 'error (cadr ref) n)))
               (else #f)))))))

(test-equal "mutation: string->json's offset is the character count of the byte offset, the reasons agree, and the byte offset is a character boundary"
  '()
  (property-failures run 'mutation 20 300 gen-mutations mutation-check no-shrinks mutation-tally))

(define mutation-total
  (+ (tally-count mutation-tally 'accepted) (tally-count mutation-tally 'rejected)))

(test-equal "mutation: 3000 cases ran, with errors at character offsets that are not byte offsets and at the end"
  (list #t #t #t #t)
  (let ((m (cadr parsed)))
    (list (= mutation-total (* 3000 m))
          (> (tally-count mutation-tally 'offset-moved) (* 100 m))
          (> (tally-count mutation-tally 'at-end) (* 20 m))
          (> (tally-count mutation-tally 'accepted) (* 20 m)))))

(test-equal "mutation: every reason the corpus gave but invalid-utf8, which valid text cannot give, occurs"
  (symbols-sorted (filter (lambda (r) (not (eq? r 'invalid-utf8))) (distinct corpus-reasons)))
  (symbols-sorted (distinct mutation-reasons)))

(test-equal "mutation: the reasons the mutants gave"
  '(control-character invalid-escape invalid-number invalid-surrogate nesting-too-deep
    number-out-of-range number-too-long trailing-garbage unexpected-byte unexpected-eof)
  (symbols-sorted (distinct mutation-reasons)))

;; --- generators, shared by 3 and 5 -----------------------------------------------------

(define (g-bits k)
  (lambda (s)
    (let loop ((acc 0) (have 0) (s s))
      (if (>= have k)
          (cons (mod acc (expt 2 k)) s)
          (draw* s ((c (g-int 32768)))
            (loop (+ (* acc 32768) c) (+ have 15) s))))))

(define (g-sign x)
  (lambda (s) (draw* s ((neg (g-chance 1 2))) (cons (if neg (- x) x) s))))

(define fixnum-edges
  (list 0 1 -1 9 -9 10 -10 99 100 999999999 -999999999 1000000000 4294967295 4294967296
        (- (expt 2 31) 1) (expt 2 31) (- (expt 2 53) 1) (expt 2 53) (+ (expt 2 53) 1)
        (- (expt 2 59) 1) (expt 2 60) (- (expt 2 63) 1) (expt 2 64) (- (expt 2 63))
        123456789012 -123456789012))

(define g-fixnum-edge (g-pick fixnum-edges))

(define (g-int-bits lo hi)
  (lambda (s) (draw* s ((k (g-range lo hi)) (x (g-bits k)) (y (g-sign x))) (cons y s))))

(define g-bignum (g-int-bits 62 400))
(define g-small-int (g-int-bits 1 52))

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
  (list -0.0 0.0 5e-324 -5e-324 2.2250738585072014e-308 1.7976931348623157e308
        -1.7976931348623157e308 1e21 1e22 1e23 1e-7 0.1 0.5 100.0 3.0 -3.0 0.3 1.5 -2.5
        9007199254740993.0 4.35 1e300 12345.678 0.2 0.7 1e-300))

(define g-flonum
  (g-choose (list (cons 6 g-flonum-random-bits) (cons 3 g-flonum-subnormal)
                  (cons 5 (g-pick flonum-specials)))))

;; Exact rationals whose denominators have only 2s and 5s, scaled by a power
;; of ten: exponents of about -45 to +60 once written out.
(define g-q
  (lambda (s)
    (draw* s ((k (g-range 0 64)) (n0 (g-bits k)) (n (g-sign n0))
              (a (g-range 0 25)) (b (g-range 0 25)) (j (g-range -20 20)) (zero (g-chance 1 20)))
      (cons (if zero 0 (* n (expt 10 j) (/ 1 (* (expt 2 a) (expt 5 b))))) s))))

;; Dyadic rationals a flonum holds exactly and writes in few digits.
(define g-dyadic
  (lambda (s)
    (draw* s ((k (g-range -1048576 1048576)) (a (g-range 0 8))) (cons (/ k (expt 2 a)) s))))

(define (integer-text n)
  (if (zero? n)
      "0"
      (let loop ((m (abs n)) (ds '()))
        (if (zero? m)
            (list->string (if (negative? n) (cons #\- ds) ds))
            (loop (div m 10) (cons (integer->char (+ 48 (mod m 10))) ds))))))

(define (decimal-text q)
  (let* ((a (abs q)) (ip (truncate a)))
    (let loop ((f (- a ip)) (ds '()))
      (if (zero? f)
          (string-append (if (negative? q) "-" "") (integer-text ip)
                         (if (null? ds) "" ".") (list->string (reverse ds)))
          (let* ((g (* f 10)) (d (truncate g)))
            (loop (- g d) (cons (integer->char (+ 48 d)) ds)))))))

;; How many digits after the point Q needs: the least K with Q 10^K whole.
(define (frac-digits q)
  (let loop ((k 0) (x q)) (if (integer? x) k (loop (+ k 1) (* x 10)))))

;; spell-text : Exact ... -> String
;; JSON number text worth Q, spelled by the draws: zeros appended, the point
;; placed, an exponent to make up for it, in either case and sign.
(define (spell-text q z fsel esty up plus)
  (let* ((k (frac-digits q))
         (zero (= q 0))
         (n (abs (* q (expt 10 k))))
         (z (if zero 0 z))
         (digits (string-append (integer-text n) (make-string z #\0)))
         (len (string-length digits))
         (f (mod fsel (+ len 1)))
         (e (- f (+ k z)))
         (ip (substring digits 0 (- len f)))
         (fp (substring digits (- len f) len)))
    (string-append
     (if (or (< q 0) (and zero plus up)) "-" "")
     (if (string=? ip "") "0" ip)
     (if (string=? fp "") "" (string-append "." fp))
     (if (and (= e 0) (< esty 2))
         ""
         (string-append (if up "E" "e") (cond ((< e 0) "-") (plus "+") (else ""))
                        (number->string (abs e)))))))

(define (g-spell q)
  (lambda (s)
    (draw* s ((z (g-pick '(0 0 1 2 5))) (fsel (g-int 100)) (esty (g-range 0 3))
              (up (g-chance 1 2)) (plus (g-chance 1 2)))
      (cons (spell-text q z fsel esty up plus) s))))

(define (g-jn-of q) (lambda (s) (draw* s ((t (g-spell q))) (cons (list '%jn t) s))))

;; The text of a flonum, less Chez's |width suffix on subnormals.
(define (flonum-text x)
  (let* ((s (number->string x)) (n (string-length s)))
    (let loop ((i 0))
      (cond ((= i n) s)
            ((char=? (string-ref s i) #\|) (substring s 0 i))
            (else (loop (+ i 1)))))))

(define g-number-any
  (g-choose (list (cons 3 g-fixnum-edge) (cons 3 g-small-int) (cons 2 g-bignum)
                  (cons 6 g-flonum) (cons 5 g-q)
                  (cons 6 (lambda (s) (draw* s ((q g-q) (j (g-jn-of q))) (cons j s)))))))

;; Numbers that read back as themselves, by json=?, under each number mode.
(define g-number-flonum-safe
  (g-choose (list (cons 3 g-small-int) (cons 6 g-flonum) (cons 3 g-dyadic)
                  (cons 3 (lambda (s) (draw* s ((q g-dyadic)) (cons (inexact q) s))))
                  (cons 4 (lambda (s) (draw* s ((q g-dyadic) (j (g-jn-of q))) (cons j s)))))))

(define g-number-exact-safe
  (g-choose (list (cons 3 g-fixnum-edge) (cons 3 g-small-int) (cons 2 g-bignum) (cons 5 g-q)
                  (cons 3 (lambda (s) (draw* s ((q g-dyadic)) (cons (inexact q) s))))
                  (cons 5 (lambda (s) (draw* s ((q g-q) (j (g-jn-of q))) (cons j s)))))))

;; --- strings, keys, trees

(define (g-char-range lo hi)
  (lambda (s) (draw* s ((c (g-range lo hi))) (cons (integer->char c) s))))

(define g-char
  (g-choose
   (list (cons 10 (g-char-range 32 126))
         (cons 4 (g-pick (list #\" #\\ #\/ #\space)))
         (cons 5 (g-char-range 0 31))
         (cons 3 (g-char-range #x80 #x7ff))
         (cons 2 (g-char-range #x800 #xd7ff))
         (cons 2 (g-char-range #xe000 #xffff))
         (cons 3 (g-char-range #x10000 #x10ffff))
         (cons 4 (g-pick (map integer->char '(#x7f #x80 #x7ff #x800 #xfffd #x2028 #x2029 #xfeff #x10000)))))))

(define g-string
  (g-choose
   (list (cons 30 (lambda (s)
                    (draw* s ((n (g-pick '(0 0 1 2 3 5 8 16))) (cs (g-list n g-char)) (feff (g-chance 1 8)))
                      (cons (string-append (if feff "\xFEFF;" "") (list->string cs)) s))))
         (cons 1 (g-pick (list "" "\x2028;\x2029;" "\x10000;"))))))

(define key-pool '("" "a" "b" "key" "a b" "\"" "\x2028;" "\x10000;" "\n"))
(define g-key (g-choose (list (cons 5 (g-pick key-pool)) (cons 4 g-string))))

(define (g-scalar gnum)
  (g-choose (list (cons 4 g-string) (cons 8 gnum) (cons 1 (g-const #t))
                  (cons 1 (g-const #f)) (cons 2 (g-const 'NULL-MARK)))))

(define (unique-keys ms)
  (let loop ((ms (reverse ms)) (seen '()) (kept '()))
    (cond ((null? ms) kept)
          ((member (caar ms) seen) (loop (cdr ms) seen kept))
          (else (loop (cdr ms) (cons (caar ms) seen) (cons (car ms) kept))))))

(define (g-tree gnum d)
  (define (g-member d)
    (lambda (s) (draw* s ((k g-key) (v (g-tree gnum d))) (cons (cons k v) s))))
  (if (= d 0)
      (g-scalar gnum)
      (g-choose
       (list (cons 6 (g-scalar gnum))
             (cons 3 (lambda (s)
                       (draw* s ((n (g-pick '(0 0 1 2 3 4 6))) (xs (g-list n (g-tree gnum (- d 1)))))
                         (cons (list->vector xs) s))))
             (cons 3 (lambda (s)
                       (draw* s ((n (g-pick '(0 0 1 2 3 4 6))) (ms (g-list n (g-member (- d 1)))))
                         (cons ms s))))
             (cons 2 (lambda (s)
                       (draw* s ((n (g-pick '(0 0 1 2 3 4 6))) (ms (g-list n (g-member (- d 1)))))
                         (cons (cons '%ht (unique-keys ms)) s))))))))

;; --- gtrees: kinds, children, realizing

(define (gkind t)
  (cond ((string? t) 'string) ((number? t) 'number) ((boolean? t) 'boolean)
        ((eq? t 'NULL-MARK) 'null) ((vector? t) 'vector) ((null? t) 'alist)
        ((eq? (car t) '%jn) 'jn) ((eq? (car t) '%ht) 'ht) (else 'alist)))

(define (leaf? t) (memq (gkind t) '(string number boolean null jn)))
(define (object-node? t) (memq (gkind t) '(alist ht)))

(define (members-of t) (if (eq? (gkind t) 'ht) (cdr t) t))

;; children : GTree -> (Listof GTree)
(define (children t)
  (case (gkind t)
    ((vector) (vector->list t))
    ((alist ht) (map cdr (members-of t)))
    (else '())))

;; map-children : (GTree -> GTree) GTree -> GTree
(define (map-children f t)
  (case (gkind t)
    ((vector) (vector-map f t))
    ((alist) (map (lambda (m) (cons (car m) (f (cdr m)))) t))
    ((ht) (cons '%ht (map (lambda (m) (cons (car m) (f (cdr m)))) (cdr t))))
    (else t)))

;; update-at : GTree (Listof Nat) (GTree -> GTree) -> GTree
(define (update-at t path f)
  (if (null? path)
      (f t)
      (let ((i (car path)))
        (define (index-map g xs)
          (let loop ((xs xs) (k 0) (acc '()))
            (if (null? xs)
                (reverse acc)
                (loop (cdr xs) (+ k 1) (cons (g k (car xs)) acc)))))
        (define (step k c) (if (= k i) (update-at c (cdr path) f) c))
        (case (gkind t)
          ((vector) (list->vector (index-map step (vector->list t))))
          ((alist) (index-map (lambda (k m) (cons (car m) (step k (cdr m)))) t))
          ((ht) (cons '%ht (index-map (lambda (k m) (cons (car m) (step k (cdr m)))) (cdr t))))
          (else t)))))

;; paths-where : (GTree -> Boolean) GTree -> (Listof (Listof Nat))
(define (paths-where pred t)
  (let walk ((t t) (path '()))
    (append (if (pred t) (list (reverse path)) '())
            (let loop ((cs (children t)) (i 0) (acc '()))
              (if (null? cs)
                  acc
                  (loop (cdr cs) (+ i 1) (append acc (walk (car cs) (cons i path)))))))))

;; normalize : GTree -> GTree
;; Every alist's duplicate keys removed, the last member's value kept.
(define (normalize t)
  (case (gkind t)
    ((vector) (vector-map normalize t))
    ((alist) (map (lambda (m) (cons (car m) (normalize (cdr m)))) (unique-keys t)))
    ((ht) (cons '%ht (map (lambda (m) (cons (car m) (normalize (cdr m)))) (cdr t))))
    (else t)))

;; first-wins : GTree -> GTree
(define (first-wins t)
  (case (gkind t)
    ((vector) (vector-map first-wins t))
    ((alist) (map (lambda (m) (cons (car m) (first-wins (cdr m))))
                  (reverse (unique-keys (reverse t)))))
    ((ht) (cons '%ht (map (lambda (m) (cons (car m) (first-wins (cdr m)))) (cdr t))))
    (else t)))

(define (make-table kind)
  (case kind
    ((0) (make-hashtable string-hash string=?))
    ((1) (make-hashtable equal-hash equal?))
    (else (make-hashtable string-hash (lambda (a b) (string=? a b))))))

;; realize : GTree Null Mode -> Any
;; MODE: mixed (as the gtree says), alist (every object an alist) or hash
;; (every object a hashtable, the last duplicate winning).
(define (realize t null mode)
  (define (rec x) (realize x null mode))
  (define (table-of ms)
    (let ((h (make-table (mod (length ms) 3))))
      (for-each (lambda (m) (hashtable-set! h (car m) (rec (cdr m)))) ms)
      h))
  (define (alist-of ms) (map (lambda (m) (cons (car m) (rec (cdr m)))) ms))
  (case (gkind t)
    ((string number boolean) t)
    ((null) null)
    ((vector) (vector-map rec t))
    ((jn) (make-json-number (cadr t)))
    ((alist) (if (eq? mode 'hash) (table-of t) (alist-of t)))
    (else (if (eq? mode 'alist) (alist-of (cdr t)) (table-of (cdr t))))))

(define (deep-copy v)
  (cond ((string? v) (string-copy v))
        ((vector? v) (vector-map deep-copy v))
        ((hashtable? v)
         (let ((h (make-hashtable string-hash string=?)))
           (let-values (((ks vs) (hashtable-entries v)))
             (vector-for-each (lambda (k x) (hashtable-set! h (string-copy k) (deep-copy x))) ks vs))
           h))
        ((json-number? v) (make-json-number (string-copy (json-number-text v))))
        ((pair? v) (map (lambda (m) (cons (string-copy (car m)) (deep-copy (cdr m)))) v))
        (else v)))

;; --- the oracle: JSON equality, written here from ADR-0019 Decision 5 ------------------

(define (o-object? x) (or (hashtable? x) (pair? x) (null? x)))
(define (o-number? x) (or (number? x) (json-number? x)))

(define (o-members x)
  (let ((all (if (hashtable? x)
                 (let-values (((ks vs) (hashtable-entries x)))
                   (map cons (vector->list ks) (vector->list vs)))
                 x)))
    (let loop ((ms (reverse all)) (seen '()) (kept '()))
      (cond ((null? ms) kept)
            ((member (caar ms) seen) (loop (cdr ms) seen kept))
            (else (loop (cdr ms) (cons (caar ms) seen) (cons (car ms) kept)))))))

(define (o-value x)
  (cond ((json-number? x) (string->number (string-append "#e" (json-number-text x))))
        ((flonum? x) (exact x))
        (else x)))

(define (o-equal? a b)
  (cond ((string? a) (and (string? b) (string=? a b)))
        ((vector? a) (and (vector? b)
                          (= (vector-length a) (vector-length b))
                          (for-all o-equal? (vector->list a) (vector->list b))))
        ((o-object? a)
         (and (o-object? b)
              (let ((ma (o-members a)) (mb (o-members b)))
                (and (= (length ma) (length mb))
                     (for-all (lambda (m)
                                (let ((p (assoc (car m) mb)))
                                  (and p (o-equal? (cdr m) (cdr p)))))
                              ma)))))
        ((o-number? a) (and (o-number? b) (= (o-value a) (o-value b))))
        (else (eqv? a b))))

;; --- 3. json=? against the oracle ----------------------------------------------------------

(define g-any-number g-number-any)
(define (g-sample d) (g-tree g-any-number d))

(define reflexive-tally (make-tally))

(define (reflexive-check t)
  (let* ((a (realize t 'null 'mixed))
         (b (realize t 'null 'mixed))
         (c (deep-copy a))
         (as-alist (realize t 'null 'alist))
         (as-hash (realize t 'null 'hash))
         (checks (list (cons 'self (jeq a a)) (cons 'fresh (jeq a b)) (cons 'copy (jeq a c))
                       (cons 'alist-hash (jeq as-alist as-hash)) (cons 'hash-alist (jeq as-hash as-alist))
                       (cons 'mixed-alist (jeq a as-alist)) (cons 'hash-mixed (jeq as-hash a)))))
    (tally! reflexive-tally 'trees)
    (let ((bad (filter (lambda (p) (not (equal? (cdr p) '(ok #t)))) checks)))
      (and (pair? bad) (list 'not-equal bad)))))

(test-equal "json=?: a value is json=? to itself, to a fresh realization, to a deep copy, and in any mix of alists and hashtables"
  '()
  (property-failures run 'reflexive 30 200 (lambda (s) (car ((g-list 5 (g-sample 4)) s)))
                     reflexive-check no-shrinks reflexive-tally))

;; Pairs: independent, the same tree with its numbers re-spelled, and the same
;; tree with a leaf changed or a member dropped. Every one is judged by the
;; oracle, in both orders.
(define (respell t)
  (cond ((eq? (gkind t) 'number)
         (let* ((q (exact t))
                (variant (mod (string-length (integer-text (numerator q))) 3)))
           (cond ((= variant 0) t)
                 ((= variant 1) (if (flonum? t) q (list '%jn (if (integer? q) (integer-text q) (decimal-text q)))))
                 (else (if (= (exact (inexact q)) q) (inexact q) t)))))
        ((eq? (gkind t) 'jn)
         (let ((q (string->number (string-append "#e" (cadr t)))))
           (if (even? (string-length (cadr t))) q t)))
        (else (map-children respell t))))

(define (drop-first-member t)
  (case (gkind t)
    ((alist) (if (null? t) t (cdr t)))
    ((ht) (if (null? (cdr t)) t (cons '%ht (cddr t))))
    (else t)))

(define (nudge-leaf t)
  (case (gkind t)
    ((string) (string-append t "x"))
    ((number jn) (let ((q (o-value (if (number? t) t (make-json-number (cadr t))))))
                   (list '%jn (decimal-text (+ q (expt 10 (- (frac-digits q))))))))
    ((boolean) (not t))
    (else #t)))

(define (g-pair-case s)
  (draw* s ((kind (g-range 0 3)) (a (g-sample 3)) (b (g-sample 3)) (r (g-int 1000)))
    (cons (case kind
            ((0) (list a b))
            ((1) (list a (respell a)))
            ((2) (let ((ls (paths-where leaf? a)))
                   (list a (if (null? ls) b (update-at a (list-ref ls (mod r (length ls))) nudge-leaf)))))
            (else (let ((os (paths-where object-node? a)))
                    (list a (if (null? os) b (update-at a (list-ref os (mod r (length os))) drop-first-member))))))
          s)))

(define pair-tally (make-tally))

(define (pair-check pr)
  (let* ((a (realize (car pr) 'null 'mixed))
         (b (realize (cadr pr) 'null (if (even? (length (paths-where leaf? (cadr pr)))) 'alist 'hash)))
         (want (list 'ok (o-equal? a b))))
    (tally! pair-tally (if (cadr want) 'equal 'unequal))
    (let ((ab (jeq a b)) (ba (jeq b a)))
      (and (not (and (equal? ab want) (equal? ba want)))
           (list 'ab ab 'ba ba 'oracle want)))))

(test-equal "json=?: 1000 trees were checked for reflexivity"
  (* 1000 (cadr parsed))
  (tally-count reflexive-tally 'trees))

(test-equal "json=?: it is symmetric and equals the oracle on every pair"
  '()
  (property-failures run 'pairs 31 300 (lambda (s) (car ((g-list 5 g-pair-case) s)))
                     pair-check no-shrinks pair-tally))

(test-equal "json=?: the pairs include many equal and many unequal ones"
  '(#t #t #t)
  (let ((m (cadr parsed)))
    (list (= (+ (tally-count pair-tally 'equal) (tally-count pair-tally 'unequal)) (* 1500 m))
          (> (tally-count pair-tally 'equal) (* 300 m))
          (> (tally-count pair-tally 'unequal) (* 400 m)))))

;; --- member order, a changed leaf, an added member

(define (g-shuffled t)
  (lambda (s)
    (case (gkind t)
      ((vector)
       (draw* s ((xs (g-each g-shuffled (vector->list t)))) (cons (list->vector xs) s)))
      ((alist ht)
       (draw* s ((ms (g-shuffle (members-of t)))
                 (vs (g-each g-shuffled (map cdr ms))))
         (let ((new (map (lambda (m v) (cons (car m) v)) ms vs)))
           (cons (if (eq? (gkind t) 'ht) (cons '%ht new) new) s))))
      (else (cons t s)))))

(define (g-each g xs)
  (lambda (s)
    (let loop ((xs xs) (acc '()) (s s))
      (if (null? xs)
          (cons (reverse acc) s)
          (draw* s ((x (g (car xs)))) (loop (cdr xs) (cons x acc) s))))))

(define (changed-leaf t)
  (case (gkind t)
    ((string) (if (string=? t (string-upcase t)) (string-append t "x") (string-upcase t)))
    ((number) (if (flonum? t) (if (= t 7.0) 8 7) (let ((q t)) (+ q (expt 10 (- (frac-digits q)))))))
    ((jn) (let ((q (o-value (make-json-number (cadr t)))))
            (list '%jn (decimal-text (+ q (expt 10 (- (frac-digits q))))))))
    ((boolean) (not t))
    (else #t)))

(define added-member (cons "\x2603;new" 1))

(define (add-member t)
  (case (gkind t)
    ((alist) (append t (list added-member)))
    (else (cons '%ht (append (cdr t) (list added-member))))))

(define (g-order-case s)
  (draw* s ((t (g-sample 4)) (r1 (g-int 30000)) (r2 (g-int 30000)))
    (let ((n (normalize t)))
      (draw* s ((sh (g-shuffled n)))
        (cons (list n sh r1 r2) s)))))

(define order-tally (make-tally))

(define (order-check kase)
  (let* ((n (car kase)) (sh (cadr kase))
         (a (realize n 'null 'mixed))
         (bad '()))
    (define (expect! what b want)
      (let ((ab (jeq a b)) (ba (jeq b a)))
        (unless (and (equal? ab (list 'ok want)) (equal? ba (list 'ok want)))
          (set! bad (cons (list what ab ba) bad)))))
    (tally! order-tally 'trees)
    (expect! 'shuffled-mixed (realize sh 'null 'mixed) #t)
    (expect! 'shuffled-alist (realize sh 'null 'alist) #t)
    (expect! 'shuffled-hash (realize sh 'null 'hash) #t)
    (let ((ls (paths-where leaf? sh)) (os (paths-where object-node? sh)))
      (unless (null? ls)
        (let* ((p (list-ref ls (mod (caddr kase) (length ls))))
               (changed (update-at sh p changed-leaf)))
          (tally! order-tally 'leaf-changed)
          (expect! 'leaf-changed (realize changed 'null 'mixed) #f)
          (expect! 'leaf-changed-hash (realize changed 'null 'hash) #f)))
      (unless (null? os)
        (let* ((p (list-ref os (mod (cadddr kase) (length os))))
               (added (update-at sh p add-member)))
          (tally! order-tally 'member-added)
          (expect! 'member-added (realize added 'null 'mixed) #f)
          (expect! 'member-added-alist (realize added 'null 'alist) #f))))
    (and (pair? bad) (list 'wrong (reverse bad)))))

(test-equal "json=?: shuffled members are equal; one changed leaf or one added member is not"
  '()
  (property-failures run 'order 32 200 (lambda (s) (car ((g-list 5 g-order-case) s)))
                     order-check no-shrinks order-tally))

(test-equal "json=?: the order cases include changed leaves and added members"
  '(#t #t #t)
  (let ((m (cadr parsed)))
    (list (= (tally-count order-tally 'trees) (* 1000 m))
          (> (tally-count order-tally 'leaf-changed) (* 700 m))
          (> (tally-count order-tally 'member-added) (* 300 m)))))

;; --- duplicate keys

(define (uncanon v)
  (cond ((vector? v) (vector-map uncanon v))
        ((and (pair? v) (eq? (car v) 'hashtable))
         (let ((h (make-hashtable string-hash string=?)))
           (for-each (lambda (m) (hashtable-set! h (car m) (uncanon (cdr m)))) (cdr v))
           h))
        ((and (pair? v) (eq? (car v) 'json-number)) (make-json-number (cadr v)))
        (else v)))

(define dup-pool '("a" "b" "c"))

(define g-dup-case
  (lambda (s)
    (draw* s ((n (g-range 2 7))
              (ms (g-list n (lambda (s) (draw* s ((k (g-pick dup-pool)) (v (g-sample 2))) (cons (cons k v) s))))))
      (cons ms s))))

(define dup-tally (make-tally))

(define (dup-check ms)
  (let* ((a (realize ms 'null 'mixed))
         (last-wins (realize (normalize ms) 'null 'mixed))
         (first (realize (first-wins ms) 'null 'mixed))
         (h (uncanon (as-hashtables (canonical (realize ms 'null 'alist)))))
         (hash-mode (realize ms 'null 'hash))
         (bad '()))
    (define (expect! what x y want)
      (let ((xy (jeq x y)) (yx (jeq y x)))
        (unless (and (equal? xy (list 'ok want)) (equal? yx (list 'ok want)))
          (set! bad (cons (list what xy yx) bad)))))
    (tally! dup-tally 'cases)
    (expect! 'last-wins-alist a last-wins #t)
    (expect! 'as-hashtables a h #t)
    (expect! 'hash-mode a hash-mode #t)
    (expect! 'alist-hashtable last-wins h #t)
    ;; the first-wins form is a different JSON object when a first value differs
    (let ((differs (not (o-equal? last-wins first))))
      (when differs (tally! dup-tally 'first-differs))
      (expect! 'first-wins a first (not differs)))
    (and (pair? bad) (list 'wrong (reverse bad)))))

(test-equal "json=?: an alist with duplicate keys is its last-wins alist, and the hashtable as-hashtables describes"
  '()
  (property-failures run 'duplicates 33 200 (lambda (s) (car ((g-list 5 g-dup-case) s)))
                     dup-check no-shrinks dup-tally))

(test-equal "json=?: the duplicate cases include many whose first value differs from the last"
  '(#t #t)
  (list (= (tally-count dup-tally 'cases) (* 1000 (cadr parsed)))
        (> (tally-count dup-tally 'first-differs) (* 500 (cadr parsed)))))

;; --- numbers

(define (exact-spellings q)
  (list q (if (= (exact (inexact q)) q) (inexact q) q)))

(define number-tally (make-tally))

(define g-number-case
  (lambda (s)
    (draw* s ((kind (g-range 0 6)) (q g-q) (a (g-spell q)) (b (g-spell q))
              (up (g-chance 1 2)) (x g-flonum) (y g-number-any) (z g-number-any) (pick (g-int 4))
              (sh (g-int 9)) (p2 (g-int 3)))
      (cons (list kind q a b up x y z pick sh p2) s))))

(define (jn t) (make-json-number t))

(define (number-check kase)
  (let* ((kind (car kase)) (q (cadr kase)) (a (jn (caddr kase))) (b (jn (cadddr kase)))
         (up (list-ref kase 4)) (x (list-ref kase 5)) (y (list-ref kase 6)) (z (list-ref kase 7))
         (pick (list-ref kase 8))
         (sh (list-ref kase 9)) (p2 (list-ref kase 10))
         (real (lambda (g) (if (and (pair? g) (eq? (car g) '%jn)) (jn (cadr g)) g)))
         (all (list q (if (= (exact (inexact q)) q) (inexact q) q) a b))
         (unit (expt 10 (- (frac-digits q)))))
    (define (both x y want)
      (let ((xy (jeq x y)) (yx (jeq y x)))
        (and (not (and (equal? xy (list 'ok want)) (equal? yx (list 'ok want))))
             (list x y 'want want 'got xy yx))))
    (case kind
      ((0 1)
       ;; the same value in different spellings: exact, flonum if exact, two texts
       (tally! number-tally 'same-spelling)
       (let ((x (list-ref all pick)) (y (list-ref all (mod (+ pick 1) 4))))
         (both x y #t)))
      ((2)
       ;; one unit in the last digit, either way, against every spelling
       (tally! number-tally 'near-miss)
       (let* ((q2 (if up (+ q unit) (- q unit)))
              (near (list q2 (jn (spell-text q2 0 0 2 #f #f)) (jn (decimal-text q2))))
              (bad (filter values
                           (map (lambda (n) (both (list-ref all pick) n #f)) near))))
         (and (pair? bad) (car bad))))
      ((6)
       ;; the same sign and digits, a power of ten apart: never equal
       (tally! number-tally 'exponent-only)
       (let* ((q0 (if (= q 0) 3/2 q))
              (q1 (* q0 (expt 10 (list-ref '(1 -1 2 -2 5 -5 40 -40 400) sh))))
              (forms (lambda (v)
                       (list v (if (and (< 1/10000000000 (abs v) 10000000000) (= (exact (inexact v)) v)) (inexact v) v)
                             (jn (spell-text v 0 0 2 #f #f)) (jn (spell-text v 1 3 0 #t #t)))))
              (x1 (list-ref (forms q0) pick)) (y1 (list-ref (forms q1) (mod (+ pick p2) 4))))
         (both x1 y1 #f)))
      ((3)
       ;; a flonum against the decimal it prints as: equal only if exact
       (let* ((t (jn (flonum-text x))) (want (= (exact x) (o-value t))))
         (tally! number-tally (if want 'flonum-text-equal 'flonum-text-unequal))
         (both x t want)))
      (else
       ;; any two numbers: the exact values decide
       (let* ((y (real y)) (z (real z)) (want (= (o-value y) (o-value z))))
         (tally! number-tally (if want 'random-equal 'random-unequal))
         (both y z want))))))

(test-equal "json=?: numbers are equal exactly when their exact values are, across spellings, near misses and printed flonums"
  '()
  (property-failures run 'numbers 34 500 (lambda (s) (car ((g-list 5 g-number-case) s)))
                     number-check no-shrinks number-tally))

(test-equal "json=?: the number cases include equal spellings, near misses, and flonums that equal and that differ from their text"
  '(#t #t #t #t #t #t)
  (let ((m (cadr parsed)))
    (list (= (apply + (map cdr (tally-counts number-tally))) (* 2500 m))
          (> (tally-count number-tally 'exponent-only) (* 250 m))
          (> (tally-count number-tally 'same-spelling) (* 600 m))
          (> (tally-count number-tally 'near-miss) (* 300 m))
          (> (tally-count number-tally 'flonum-text-equal) (* 30 m))
          (> (tally-count number-tally 'flonum-text-unequal) (* 200 m)))))

;; A table of known answers, written by hand.
(define known
  (list
   (list (jn "15e-1") (jn "15e-2") #f) (list (jn "1") 10 #f) (list (jn "1e400") (expt 10 401) #f)
   (list (jn "1e400") (expt 10 400) #t) (list (jn "0.5") 5 #f) (list (jn "0.5") 0.05 #f) (list 1 1.0 #t) (list 1 (jn "1e0") #t) (list 1.0 (jn "1e0") #t) (list (jn "1.50") (jn "15e-1") #t)
   (list (jn "1.50") 3/2 #t) (list 3/2 1.5 #t) (list (jn "15e-1") 1.5 #t) (list (jn "0.15E1") 1.5 #t)
   (list 0.1 (jn "0.1") #f) (list 1/10 (jn "0.1") #t) (list 0.1 1/10 #f) (list 0.5 (jn "5e-1") #t)
   (list 0 -0.0 #t) (list (jn "-0") 0 #t) (list (jn "0.000") (jn "0e99") #t) (list (jn "-0.0") 0.0 #t)
   (list (jn "1e40") (expt 10 40) #t) (list (jn "1e-40") 1/10000000000000000000000000000000000000000 #t)
   (list (jn "1e-40") 0.0 #f) (list (jn "1.0000000000000000000001") 1 #f) (list (jn "0.1") (jn "0.10000000000000000001") #f)
   (list 5e-324 (jn "5e-324") #f) (list 5e-324 (exact 5e-324) #t) (list 1e21 (jn "1e21") #t)
   (list 100000000000000000000.0 (expt 10 20) #t) (list (jn "12e-1") (jn "1.2") #t)
   (list (jn "12e-1") (jn "1.21") #f) (list (jn "-1") 1 #f) (list "1" 1 #f) (list #t 1 #f)
   (list 'null 0 #f) (list #t #t #t) (list #f #t #f) (list 'null 'null #t) (list "a" "a" #t)
   (list "a" "b" #f) (list "a" "A" #f) (list "\xe9;" "\xc9;" #f) (list (vector 1 2) (vector 1.0 (jn "2e0")) #t) (list (vector 1 2) (vector 2 1) #f)
   (list (vector) (vector 1) #f) (list '() '() #t) (list '() (make-hashtable string-hash string=?) #t)
   (list '(("a" . 1) ("b" . 2)) '(("b" . 2) ("a" . 1)) #t) (list '(("a" . 1)) '(("a" . 2) ("a" . 1)) #t)
   (list '(("a" . 1) ("a" . 2)) '(("a" . 1)) #f) (list '(("a" . 1)) '(("a" . 1) ("b" . 2)) #f)
   (list '(("a" . 1) ("b" . 2)) '(("a" . 1) ("c" . 2)) #f) (list '(("a" . 1)) '() #f)
   (list '() '(("a" . 1)) #f) (list '(("a" . 1)) (vector 1) #f)))

(test-equal "json=?: the known answers, in both orders"
  '()
  (filter (lambda (r) r)
          (map (lambda (k)
                 (let ((ab (jeq (car k) (cadr k))) (ba (jeq (cadr k) (car k))))
                   (and (not (and (equal? ab (list 'ok (caddr k))) (equal? ba (list 'ok (caddr k)))))
                        (list (car k) (cadr k) 'want (caddr k) 'got ab ba))))
               known)))

;; --- 4. alists and hashtables agree -----------------------------------------------------

(define (oracle-ref v path)
  ;; The value at PATH, or 'missing: the last member with the key, in an alist.
  (if (null? path)
      v
      (let ((step (car path)))
        (cond ((and (string? step) (or (pair? v) (null? v)))
               (let loop ((ms v) (found 'missing))
                 (if (null? ms)
                     (if (eq? found 'missing) 'missing (oracle-ref found (cdr path)))
                     (loop (cdr ms) (if (string=? (caar ms) step) (cdar ms) found)))))
              ((and (integer? step) (vector? v) (< step (vector-length v)))
               (oracle-ref (vector-ref v step) (cdr path)))
              (else 'missing)))))

;; walk-members : alist-value -> (Listof (Pair Path Boolean))
;; Every member and element, as the path to it and whether a later member of
;; its object has the same key; objects, and their paths, in order.
(define (all-paths v)
  (let walk ((v v) (path '()))
    (cond ((vector? v)
           (let loop ((i 0) (acc '()))
             (if (= i (vector-length v))
                 (reverse acc)
                 (loop (+ i 1)
                       (append (reverse (walk (vector-ref v i) (append path (list i))))
                               (cons (cons (append path (list i)) #f) acc))))))
          ((or (pair? v) (null? v))
           (let loop ((ms v) (acc '()))
             (if (null? ms)
                 (reverse acc)
                 (loop (cdr ms)
                       (let ((p (append path (list (caar ms)))))
                         (append (reverse (walk (cdar ms) p))
                                 (cons (cons p (and (assoc (caar ms) (cdr ms)) #t)) acc)))))))
          (else '()))))

(define (ref-outcome v path)
  (guard (e ((json-error? e)
             (list 'error (json-error-reason e) (json-error-offset e) (condition-irritants e)))
            (#t (list 'raised (describe e))))
    (list 'ok (apply json-ref v path))))

(define (containers v)
  (let walk ((v v) (path '()))
    (cond ((vector? v)
           (cons (cons path v)
                 (let loop ((i 0) (acc '()))
                   (if (= i (vector-length v)) acc
                       (loop (+ i 1) (append acc (walk (vector-ref v i) (append path (list i)))))))))
          ((or (pair? v) (null? v))
           (cons (cons path v)
                 (let loop ((ms v) (acc '()))
                   (if (null? ms) acc
                       (loop (cdr ms) (append acc (walk (cdar ms) (append path (list (caar ms))))))))))
          (else '()))))

(define ht-options (opts 'object-mode 'hashtable))

;; A default no document holds.
(define sentinel (list 'sentinel))

(define (section-4)
  (let ((read-bad '()) (equal-bad '()) (ref-bad '()) (oracle-bad '()) (missing-bad '())
        (found-default-bad '()) (missing-default-bad '())
        (files 0) (paths 0) (shadowed 0) (misses 0))
    (for-each
     (lambda (file)
       (let ((ref (builder-outcome (cdr file) (opts))))
         (when (eq? (car ref) 'ok)
           (set! files (+ files 1))
           (let ((a (bytevector->json (cdr file)))
                 (h (bytevector->json (cdr file) ht-options)))
             (let ((eq (jeq a h)))
               (unless (equal? eq '(ok #t)) (set! equal-bad (cons (list (car file) eq) equal-bad))))
             (for-each
              (lambda (pp)
                (let* ((path (car pp))
                       (ra (ref-outcome a path))
                       (rh (ref-outcome h path))
                       (want (oracle-ref a path)))
                  (set! paths (+ paths 1))
                  (when (cdr pp) (set! shadowed (+ shadowed 1)))
                  (unless (and (eq? (car ra) 'ok) (eqv? (cadr ra) want))
                    (set! oracle-bad (cons (list (car file) path ra 'oracle want) oracle-bad)))
                  (unless (and (eq? (car ra) 'ok) (eq? (car rh) 'ok)
                               (equal? (jeq (cadr ra) (cadr rh)) '(ok #t)))
                    (set! ref-bad (cons (list (car file) path ra rh) ref-bad)))
                  (let ((da (ref-outcome a (append path (list 'default sentinel))))
                        (dh (ref-outcome h (append path (list 'default sentinel)))))
                    (unless (and (equal? da ra) (equal? dh rh))
                      (set! found-default-bad (cons (list (car file) path da dh) found-default-bad))))))
              (all-paths a))
             (for-each
              (lambda (c)
                (let* ((path (car c)) (node (cdr c))
                       (miss (append path (list (if (vector? node) (vector-length node) "\x2603;nope")))))
                  (set! misses (+ misses 1))
                  (let ((want (list 'error 'not-found #f (list miss))))
                    (unless (and (equal? (ref-outcome a miss) want) (equal? (ref-outcome h miss) want))
                      (set! missing-bad (cons (list (car file) miss (ref-outcome a miss) (ref-outcome h miss))
                                              missing-bad))))
                  (let ((da (ref-outcome a (append miss (list 'default sentinel))))
                        (dh (ref-outcome h (append miss (list 'default sentinel)))))
                    (unless (and (eq? (car da) 'ok) (eq? (cadr da) sentinel)
                                 (eq? (car dh) 'ok) (eq? (cadr dh) sentinel))
                      (set! missing-default-bad (cons (list (car file) miss da dh) missing-default-bad))))))
              (containers a))))))
     corpus)
    (test-equal "agree: every file the builder accepts reads under alists and under hashtables to json=? values"
      '() (reverse equal-bad))
    (test-equal "agree: json-ref along every path gives json=? answers on both"
      '() (reverse ref-bad))
    (test-equal "agree: under alists json-ref gives the last member with the key, as the oracle does"
      '() (reverse oracle-bad))
    (test-equal "agree: a key or an index that is missing raises not-found at #f with the steps taken"
      '() (reverse missing-bad))
    (test-equal "agree: with a default, a path to a member gives what it gives without one"
      '() (reverse found-default-bad))
    (test-equal "agree: with a default, a missing key or index gives the default itself"
      '() (reverse missing-default-bad))
    (list files paths shadowed misses)))

(define section-4-totals (section-4))

(test-equal "agree: files read, paths followed, paths to a shadowed duplicate, and missing steps tried"
  '(152 698 2 646)
  section-4-totals)


;; Generated trees: json-ref through hashtables of three kinds (string=?,
;; equal?, and a procedure that is neither) gives what the alist does.
(define ref-tally (make-tally))

(define (ref-tables-check t)
  (let* ((n (begin (tally! ref-tally 'trees) (normalize t)))
         (a (realize n 'null 'alist))
         (h (realize n 'null 'hash))
         (m (realize n 'null 'mixed))
         (bad '()))
    (for-each
     (lambda (pp)
       (let* ((path (car pp)) (want (oracle-ref a path)))
         (tally! ref-tally 'paths)
         (for-each
          (lambda (what v)
            (let ((got (ref-outcome v path)))
              (unless (and (eq? (car got) 'ok) (equal? (jeq (cadr got) want) '(ok #t)))
                (set! bad (cons (list what path got) bad)))))
          '(hash mixed) (list h m))))
     (all-paths a))
    (and (pair? bad) (list 'wrong (list-head (reverse bad) (min 3 (length bad)))))))

(test-equal "agree: json-ref through hashtables of any kind finds what the oracle finds in the alist"
  '()
  (property-failures run 'ref-tables 36 200 (lambda (s) (car ((g-list 5 (g-sample 4)) s)))
                     ref-tables-check no-shrinks ref-tally))

(test-equal "agree: those trees had many paths"
  '(#t #t)
  (list (= (tally-count ref-tally 'trees) (* 1000 (cadr parsed)))
        (> (tally-count ref-tally 'paths) (* 3000 (cadr parsed)))))

;; Hand-made tables and wrong steps.
(define ci-table
  (let ((h (make-hashtable string-ci-hash string-ci=?)))
    (hashtable-set! h "a" 1)
    h))
(define eq-table
  (let ((h (make-eq-hashtable)))
    (hashtable-set! h (string-copy "k") 1)
    (hashtable-set! h (string-copy "k") 2)
    (hashtable-set! h "j" 3)
    h))

(define (ref v . steps) (ref-outcome v steps))

(test-equal "json-ref: a table keyed another way is searched by key text; two keys with one text are refused; wrong steps are not-found"
  '((ok 1) (error not-found #f (("A"))) (ok 3) (error unwritable-key #f ("k"))
    (error not-found #f (("x"))) (error not-found #f ((0 "x")))
    (error not-found #f ((1))) (error not-found #f (("a" "b")))
    (ok 2) (ok ()) (ok #t))
  (list (ref ci-table "a")
        (ref ci-table "A")
        (ref eq-table "j")
        (ref eq-table "k")
        (ref '(("a" . 1)) "x")
        (ref (vector 1) 0 "x")
        (ref (vector 1) 1)
        (ref '(("a" . 1)) "a" "b")
        (ref '(("a" . 1) ("a" . 2)) "a")
        (ref '(("a" . ())) "a")
        (ref (vector #t) 0)))

;; --- 5. round trips -------------------------------------------------------------------

(define rt-sets
  (list (cons 'defaults (cons (opts) g-number-flonum-safe))
        (cons 'indent-2-hashtable-nil
              (cons (opts 'indent 2 'object-mode 'hashtable 'null 'nil) g-number-flonum-safe))
        (cons 'exact-indent-1 (cons (opts 'number-mode 'exact 'indent 1) g-number-exact-safe))
        (cons 'text-hashtable-record
              (cons (opts 'number-mode 'text 'object-mode 'hashtable 'null nil-record) g-number-exact-safe))
        (cons 'text-indent-10 (cons (opts 'number-mode 'text 'indent 10 'depth-limit 600) g-number-exact-safe))
        (cons 'exact-hashtable-record-indent-3
              (cons (opts 'number-mode 'exact 'object-mode 'hashtable 'null nil-record 'indent 3)
                    g-number-exact-safe))))

(define (g-rt-case s)
  (draw* s ((i (g-int (length rt-sets))))
    (draw* s ((t (g-tree (cddr (list-ref rt-sets i)) 4)))
      (cons (list i (normalize t)) s))))

(define rt-tally (make-tally))

(define (bytes-written v o)
  (let-values (((p get) (open-bytevector-output-port)))
    (write-json p v o)
    (get)))

(define (rt-check kase)
  (let* ((entry (list-ref rt-sets (car kase)))
         (o (cadr entry))
         (v (realize (cadr kase) (json-options-null o) 'mixed))
         (bv (outcome (lambda () (json->bytevector v o))))
         (str (outcome (lambda () (json->string v o))))
         (port (outcome (lambda () (bytes-written v o)))))
    (tally! rt-tally (car entry))
    (cond
      ((not (and (eq? (car bv) 'ok) (eq? (car str) 'ok) (eq? (car port) 'ok)))
       (list 'write bv str port))
      ((not (bytevector=? (string->utf8 (cadr str)) (cadr bv)))
       (list 'string-is-not-the-bytes (cadr str) (cadr bv)))
      ((not (bytevector=? (cadr port) (cadr bv)))
       (list 'port-is-not-the-bytes (cadr port) (cadr bv)))
      (else
       (let ((from-string (outcome (lambda () (string->json (cadr str) o))))
             (from-bytes (outcome (lambda () (bytevector->json (cadr bv) o))))
             (from-port (outcome (lambda () (read-json (open-bytevector-input-port (cadr bv)) o)))))
         (let ((checks (list (cons 'string from-string) (cons 'bytes from-bytes) (cons 'port from-port))))
           (or (let ((bad (filter (lambda (c) (not (eq? (cadr c) 'ok))) checks)))
                 (and (pair? bad) (list 'read-failed bad)))
               (let ((bad (filter (lambda (c)
                                    (not (equal? (jeq v (caddr c) o) '(ok #t))))
                                  checks)))
                 (and (pair? bad) (list 'not-json=? (map car bad) (bytevector->u8-list (cadr bv)))))
               (let ((bad (filter (lambda (c) (not (o-equal? v (caddr c)))) checks)))
                 (and (pair? bad) (list 'oracle-says-different (map car bad))))
               (and (not (equal? (outcome-c (lambda () (string->json (cadr str) o)))
                                 (outcome-c (lambda () (bytevector->json (cadr bv) o)))))
                    (list 'string-and-bytes-differ)))))))))

(test-equal "round trip: writing and reading back is json=? to the value, in a string, a bytevector and a port"
  '()
  (property-failures run 'round-trip 35 400 (lambda (s) (car ((g-list 5 g-rt-case) s)))
                     rt-check no-shrinks rt-tally))

(test-equal "round trip: 2000 cases ran, each option set at least 250 times"
  #t
  (let ((m (cadr parsed)))
    (and (= (apply + (map cdr (tally-counts rt-tally))) (* 2000 m))
         (for-all (lambda (e) (> (tally-count rt-tally (car e)) (* 250 m))) rt-sets))))

;; json-null? is eq? to the options' null.
(test-equal "json-null?: the options' null is null, and nothing else is"
  '((#t #f #f #f) (#t #f #f #f) (#t #f #f #f) (#t #f #f #f) (#t #f #f #f) (#t #f #f #f)
    (#f #t #f #f))
  (append
   (map (lambda (e)
          (let ((o (cadr e)))
            (list (json-null? (json-options-null o) o)
                  (json-null? (if (eq? (json-options-null o) 'zzz) 'yyy 'zzz) o)
                  (json-null? #f o) (json-null? '() o))))
        rt-sets)
   (list (list (json-null? 'null (opts 'null 'nil)) (json-null? 'nil (opts 'null 'nil))
               (json-null? 'null (opts 'null nil-record)) (json-null? nil-record (opts)))))) 

(test-end "easy-property")

(exit (suite-exit-status runner))
