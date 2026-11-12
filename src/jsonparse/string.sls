#!r6rs
;;; (jsonparse string): builds the strings and numbers a parser's handler
;;; hears in parts (ADR-0010, ADR-0011, ADR-0016).
;;;
;;; An assembler holds one growable buffer, reused for every text, so a
;;; parser needs one assembler, not a port per string. Give it a text's
;;; parts as the handler hears them, and take the whole when the text ends:
;;;
;;;   json-assembler-chars!         (a bv start end)  part of a string's or
;;;                                                   a key's text
;;;   json-assembler-escape!        (a scalar)        an escaped character
;;;   json-assembler-string!        (a)               the string, from
;;;                                                   string-end or key-end
;;;   json-assembler-number-chars!  (a bv start end)  part of a number's text
;;;   json-assembler-number!        (a)               the number, from
;;;                                                   number-end
;;;   json-assembler-reset!         (a)               drop a half-built text
;;;
;;; The three that take parts are called as the handler's chars, escape and
;;; number-chars are, so an assembler can be a parser's context and those
;;; three its procedures.
;;;
;;; A string's parts are joined as UTF-8 and decoded once, when it is
;;; taken, so a part may end inside a character.
;;;
;;; A number converts by the options' number-mode (ADR-0011):
;;;
;;;   flonum  the default. A number with no fraction and no exponent is an
;;;           exact integer, so -0 is 0. Any other is the nearest flonum,
;;;           so -0.0 stays -0.0 and 1e-400 is 0.0. One too large for a
;;;           flonum, such as 1e400, is number-out-of-range
;;;   exact   every number is exact: 1.5 is 3/2, 1e2 is 100. A number
;;;           whose significand's digits plus its exponent's absolute value
;;;           exceed the digit limit is number-out-of-range, zeros included:
;;;           0e1001 is out of range under the default limit
;;;   text    a json-number record holding the number's text, unconverted
;;;
;;; In flonum and exact modes, a number with more digits than the options'
;;; digit-limit is number-too-long, even where exact mode's range would
;;; also refuse it. Its integer part, fraction and exponent all count. The
;;; digits are counted as the parts arrive, and the buffer keeps none past
;;; the limit, so a long number costs no memory. text mode has no limit and
;;; keeps every byte.
;;;
;;; A short number converts straight from the buffer, with no copy and no
;;; string (ADR-0027): in flonum and exact modes an integer of up to 18
;;; digits, by fixnum arithmetic; in flonum mode a decimal of up to 18
;;; digits whose value is m x 10^e with e from -22 to 22, by one flonum
;;; operation up to 15 digits and by inexact of the exact value above. 18
;;; is fewer where fixnums are narrower. Any other number, and any text the
;;; fast path can't read, is copied out, checked and read by string->number.
;;; Both paths give the same value or stop. In exact mode the fast path
;;; counts an integer's digits against the limit itself, as the general
;;; path's range check does: digits given by json-assembler-chars! were not
;;; counted as they came.
;;;
;;; number-too-long and number-out-of-range are stops: json-assembler-number!
;;; returns one, and the handler's number-end passes it on to the parser by
;;; returning it, which ends the parse with that code. A stop from
;;; number-end lands at the same offset however the input is split
;;; (ADR-0015).
;;;
;;; Taking a string or a number empties the assembler, whatever it returns
;;; or raises. A parse that ends in an error or a stop can leave a text
;;; half-built, and a parser reset does not tell the handler: reset the
;;; assembler with the parser.
;;;
;;; The assembler trusts its parts to come from a parser, but never returns
;;; a wrong kind of value. A number's text is checked against JSON's number
;;; grammar before it converts, or by the fast path as it reads, and
;;; json-assembler-number! raises when it fails. Past the digit limit there is no text to check, so the answer is
;;; number-too-long whatever the parts were. An escape that is not a
;;; Unicode scalar value raises. A string's bytes that are not UTF-8 are
;;; left to utf8->string, which in Chez decodes them to U+FFFD; R6RS
;;; doesn't say. A parser never delivers such bytes in a completed string.
;;; Chez's utf8->string also drops a byte order mark, U+FEFF, at the start
;;; of its bytes; json-assembler-string! keeps it, since in JSON it is text.
;;;
;;; make-json-number checks its text against the same grammar and keeps a
;;; copy, and json-number-text returns a copy, so a record's text cannot be
;;; changed through either.
(library (jsonparse string)
  (export make-json-assembler json-assembler?
          json-assembler-chars! json-assembler-escape! json-assembler-string!
          json-assembler-number-chars! json-assembler-number!
          json-assembler-reset!
          make-json-number json-number? json-number-text)
  (import (rnrs)
          (jsonparse options)
          (jsonparse parser))

  ;; --- the number grammar -----------------------------------------------------

  (define (digit? b) (and (fx>=? b 48) (fx<=? b 57)))

  ;; The first position from I to END that holds no digit, or END.
  (define (skip-digits bv i end)
    (if (and (fx<? i end) (digit? (bytevector-u8-ref bv i)))
        (skip-digits bv (fx+ i 1) end)
        i))

  ;; number-shape : Bytevector Index Index -> (Values Boolean Index)
  ;; Whether the bytes of BV from START to END are a JSON number,
  ;;
  ;;   -?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?
  ;;
  ;; and where its exponent's e or E is, END if it has none.
  (define (number-shape bv start end)
    (define (at? i b) (and (fx<? i end) (fx=? (bytevector-u8-ref bv i) b)))
    (define (digit-at? i) (and (fx<? i end) (digit? (bytevector-u8-ref bv i))))
    (define (no) (values #f end))
    ;; I is just past the integer part.
    (define (fraction i)
      (cond ((not (at? i 46)) (exponent i))                          ; .
            ((digit-at? (fx+ i 1)) (exponent (skip-digits bv (fx+ i 1) end)))
            (else (no))))
    ;; I is just past the significand.
    (define (exponent i)
      (cond ((fx=? i end) (values #t end))
            ((or (at? i 101) (at? i 69))                             ; e E
             (let ((j (if (or (at? (fx+ i 1) 43) (at? (fx+ i 1) 45)) ; + -
                          (fx+ i 2)
                          (fx+ i 1))))
               (if (and (digit-at? j) (fx=? (skip-digits bv j end) end))
                   (values #t i)
                   (no))))
            (else (no))))
    (let ((i (if (at? start 45) (fx+ start 1) start)))               ; -
      (cond ((at? i 48) (fraction (fx+ i 1)))                        ; 0
            ((digit-at? i) (fraction (skip-digits bv i end)))
            (else (no)))))

  ;; --- json-number ------------------------------------------------------------

  ;; json-number? : Any -> Boolean
  (define-record-type (json-number new-json-number json-number?)
    (fields (immutable text number-text))
    (sealed #t)
    (opaque #t))

  ;; make-json-number : String -> json-number
  ;; A record of TEXT, which must be a JSON number such as "-1.5e3" with
  ;; nothing before or after it. Keeps a copy of TEXT. Raises for anything
  ;; else.
  (define (make-json-number text)
    (unless (string? text)
      (assertion-violation 'make-json-number "not a string" text))
    (let ((bv (string->utf8 text)))
      (let-values (((ok? e-at) (number-shape bv 0 (bytevector-length bv))))
        (unless ok?
          (assertion-violation 'make-json-number "not a JSON number" text))
        (new-json-number (string-copy text)))))

  ;; json-number-text : json-number -> String
  ;; The record's text, as a fresh string.
  (define (json-number-text n)
    (unless (json-number? n)
      (assertion-violation 'json-number-text "not a json-number" n))
    (string-copy (number-text n)))

  ;; --- the assembler ----------------------------------------------------------

  ;; json-assembler? : Any -> Boolean
  (define-record-type (json-assembler new-json-assembler json-assembler?)
    (fields (mutable buffer assembler-buffer assembler-buffer-set!)
            ;; How many of the buffer's bytes hold the text.
            (mutable fill assembler-fill assembler-fill-set!)
            ;; The number's digits so far, or #f once past the limit.
            (mutable digits assembler-digits assembler-digits-set!)
            (immutable mode assembler-mode)
            (immutable limit assembler-limit))
    (sealed #t)
    (opaque #t))

  (define initial-size 256)

  (define default-options (make-json-options))

  ;; make-json-assembler : [json-options] -> json-assembler
  ;; An empty assembler under OPTIONS (default (make-json-options)).
  (define make-json-assembler
    (case-lambda
      (() (make-json-assembler default-options))
      ((options)
       (unless (json-options? options)
         (assertion-violation 'make-json-assembler "not an options record" options))
       (new-json-assembler (make-bytevector initial-size 0) 0 0
                           (json-options-number-mode options)
                           (json-options-digit-limit options)))))

  (define (check-assembler who a)
    (unless (json-assembler? a)
      (assertion-violation who "not an assembler" a)))

  (define (check-part who a bv start end)
    (check-assembler who a)
    (unless (bytevector? bv)
      (assertion-violation who "not a bytevector" bv))
    (unless (and (fixnum? start) (fixnum? end)
                 (fx<=? 0 start end (bytevector-length bv)))
      (assertion-violation who "the range is not within the bytevector"
                           start end (bytevector-length bv))))

  (define (clear! a)
    (assembler-fill-set! a 0)
    (assembler-digits-set! a 0))

  ;; room! : json-assembler Nat -> Bytevector
  ;; The buffer, grown first if it cannot hold N more bytes.
  (define (room! a n)
    (let ((buf (assembler-buffer a))
          (need (fx+ (assembler-fill a) n)))
      (if (fx<=? need (bytevector-length buf))
          buf
          (let ((new (make-bytevector (fxmax need (fx* 2 (bytevector-length buf))))))
            (bytevector-copy! buf 0 new 0 (assembler-fill a))
            (assembler-buffer-set! a new)
            new))))

  ;; Adds the bytes of BV from START to END to the text.
  (define (append! a bv start end)
    (let* ((n (fx- end start))
           (buf (room! a n))
           (fill (assembler-fill a)))
      (bytevector-copy! bv start buf fill n)
      (assembler-fill-set! a (fx+ fill n))))

  ;; take! : json-assembler -> Bytevector
  ;; The text, copied, and the assembler emptied.
  (define (take! a)
    (let* ((n (assembler-fill a))
           (out (make-bytevector n)))
      (bytevector-copy! (assembler-buffer a) 0 out 0 n)
      (clear! a)
      out))

  ;; json-assembler-chars! : json-assembler Bytevector Nonnegative-Fixnum Nonnegative-Fixnum -> Void
  ;; Adds the bytes of BV from START to END to a string's text. Raises
  ;; unless 0 <= START <= END <= (bytevector-length BV).
  (define (json-assembler-chars! a bv start end)
    (check-part 'json-assembler-chars! a bv start end)
    (append! a bv start end))

  ;; json-assembler-escape! : json-assembler Nonnegative-Fixnum -> Void
  ;; Adds the character SCALAR to a string's text, as UTF-8. Raises unless
  ;; SCALAR is a Unicode scalar value: 0 to #x10FFFF, outside the
  ;; surrogates.
  (define (json-assembler-escape! a scalar)
    (check-assembler 'json-assembler-escape! a)
    (unless (and (fixnum? scalar) (fx<=? 0 scalar #x10FFFF)
                 (not (fx<=? #xD800 scalar #xDFFF)))
      (assertion-violation 'json-assembler-escape! "not a Unicode scalar value" scalar))
    (let* ((n (cond ((fx<? scalar #x80) 1)
                    ((fx<? scalar #x800) 2)
                    ((fx<? scalar #x10000) 3)
                    (else 4)))
           (buf (room! a n))
           (i (assembler-fill a)))
      (define (put! k byte) (bytevector-u8-set! buf (fx+ i k) byte))
      (define (tail shift) (fxior #x80 (fxand (fxarithmetic-shift-right scalar shift) #x3F)))
      (case n
        ((1) (put! 0 scalar))
        ((2) (put! 0 (fxior #xC0 (fxarithmetic-shift-right scalar 6)))
             (put! 1 (tail 0)))
        ((3) (put! 0 (fxior #xE0 (fxarithmetic-shift-right scalar 12)))
             (put! 1 (tail 6))
             (put! 2 (tail 0)))
        (else (put! 0 (fxior #xF0 (fxarithmetic-shift-right scalar 18)))
              (put! 1 (tail 12))
              (put! 2 (tail 6))
              (put! 3 (tail 0))))
      (assembler-fill-set! a (fx+ i n))))

  ;; Whether the text starts with EF BB BF, U+FEFF's UTF-8.
  (define (mark-first? a)
    (let ((buf (assembler-buffer a)))
      (and (fx>=? (assembler-fill a) 3)
           (fx=? (bytevector-u8-ref buf 0) #xEF)
           (fx=? (bytevector-u8-ref buf 1) #xBB)
           (fx=? (bytevector-u8-ref buf 2) #xBF))))

  ;; take-after-space! : json-assembler -> Bytevector
  ;; take!, with a space before the text.
  (define (take-after-space! a)
    (let* ((n (assembler-fill a))
           (out (make-bytevector (fx+ n 1) 32)))
      (bytevector-copy! (assembler-buffer a) 0 out 1 n)
      (clear! a)
      out))

  ;; json-assembler-string! : json-assembler -> String
  ;; The string the parts so far make, and the assembler emptied. With no
  ;; parts, the empty string.
  ;;
  ;; Chez's utf8->string drops a byte order mark, U+FEFF, that comes first,
  ;; and R6RS doesn't say whether it may. In JSON it is text, so a text that
  ;; starts with one is decoded after a space, and the space cut off.
  (define (json-assembler-string! a)
    (check-assembler 'json-assembler-string! a)
    (if (mark-first? a)
        (let ((s (utf8->string (take-after-space! a))))
          (substring s 1 (string-length s)))
        (utf8->string (take! a))))

  ;; json-assembler-number-chars! : json-assembler Bytevector Nonnegative-Fixnum Nonnegative-Fixnum -> Void
  ;; Adds the bytes of BV from START to END to a number's text. In flonum
  ;; and exact modes, keeps none past the digit limit's last digit. Raises
  ;; unless 0 <= START <= END <= (bytevector-length BV).
  (define (json-assembler-number-chars! a bv start end)
    (check-part 'json-assembler-number-chars! a bv start end)
    (if (eq? (assembler-mode a) 'text)
        (append! a bv start end)
        (let ((limit (assembler-limit a)) (d (assembler-digits a)))
          (when d
            (let loop ((i start) (d d))
              (cond ((fx=? i end)
                     (append! a bv start end)
                     (assembler-digits-set! a d))
                    ((not (digit? (bytevector-u8-ref bv i))) (loop (fx+ i 1) d))
                    ((fx<? d limit) (loop (fx+ i 1) (fx+ d 1)))
                    (else
                     (append! a bv start i)
                     (assembler-digits-set! a #f))))))))

  (define too-long (make-json-stop 'number-too-long))
  (define out-of-range (make-json-stop 'number-out-of-range))

  ;; How many digits BV holds from FROM to TO.
  (define (count-digits bv from to)
    (let loop ((i from) (n 0))
      (cond ((fx=? i to) n)
            ((digit? (bytevector-u8-ref bv i)) (loop (fx+ i 1) (fx+ n 1)))
            (else (loop (fx+ i 1) n)))))

  ;; The absolute value of the exponent whose e is at E-AT, 0 if E-AT is
  ;; END; or, once it passes LIMIT, any value past LIMIT.
  (define (exponent-size bv e-at end limit)
    (if (fx=? e-at end)
        0
        (let loop ((i (fx+ e-at 1)) (v 0))
          (cond ((or (fx=? i end) (> v limit)) v)
                ((digit? (bytevector-u8-ref bv i))
                 (loop (fx+ i 1) (+ (* v 10) (fx- (bytevector-u8-ref bv i) 48))))
                (else (loop (fx+ i 1) v))))))

  ;; --- the fast path (ADR-0027) ---------------------------------------------

  ;; fast-digits : Nat
  ;; The most digits a fast number's significand has: the most d, at most
  ;; 18, with 10^d - 1 <= (greatest-fixnum), so that every integer of d
  ;; digits, and each step of reading one, is a fixnum. 18 where the
  ;; greatest fixnum is 2^60 - 1.
  (define fast-digits
    (let loop ((d 0))
      (if (and (< d 18) (<= (- (expt 10 (+ d 1)) 1) (greatest-fixnum)))
          (loop (+ d 1))
          d)))

  ;; one-operation-digits : Nat
  ;; The most digits a decimal has for one flonum operation to convert it:
  ;; under 10^15, its significand is under 2^53, an exact flonum.
  (define one-operation-digits (min 15 fast-digits))

  ;; max-power : Nat
  ;; The largest power of ten that is an exact flonum: 10^22 is
  ;; 2^22 x 5^22, and 5^22 is under 2^53.
  (define max-power 22)

  ;; exponent-cap : Nat
  ;; Past this exponent, no fast number's e is within max-power, whatever
  ;; its fraction: e is the exponent less the fraction's digits, fewer than
  ;; fast-digits of them. An exponent is read no further past it, so a
  ;; long one never leaves the fixnums.
  (define exponent-cap (+ max-power fast-digits))

  ;; powers-of-ten : (Exact-Integer -> Real) -> (Vectorof Real)
  ;; CONVERT of each of 10^0 to 10^max-power.
  (define (powers-of-ten convert)
    (let ((v (make-vector (+ max-power 1))))
      (let loop ((i 0))
        (when (<= i max-power)
          (vector-set! v i (convert (expt 10 i)))
          (loop (+ i 1))))
      v))

  ;; flonum-powers : (Vectorof Flonum), 10^0 to 10^22, each exact
  (define flonum-powers (powers-of-ten inexact))

  ;; exact-powers : (Vectorof Exact-Integer), 10^0 to 10^22
  (define exact-powers (powers-of-ten (lambda (x) x)))

  ;; holds-byte? : Bytevector Index Index Byte -> Boolean
  ;; Whether BV holds B at I, before END.
  (define (holds-byte? bv i end b)
    (and (fx<? i end) (fx=? (bytevector-u8-ref bv i) b)))

  ;; holds-digit? : Bytevector Index Index -> Boolean
  ;; Whether BV holds a digit at I, before END.
  (define (holds-digit? bv i end)
    (and (fx<? i end) (digit? (bytevector-u8-ref bv i))))

  ;; digit-of : Bytevector Index -> Fixnum
  ;; The value of the digit BV holds at I.
  (define (digit-of bv i) (fx- (bytevector-u8-ref bv i) 48))

  ;; digit-run : Bytevector Index Index Fixnum Nat -> (Values (U Index #f) Fixnum Nat)
  ;; Reads the digits of BV from I, up to END or the first byte that isn't
  ;; one, onto M, a significand of N digits so far: where they stop, the
  ;; significand and its digits then. Where they stop is #f when the digits
  ;; would pass fast-digits.
  (define (digit-run bv i end m n)
    (cond ((not (holds-digit? bv i end)) (values i m n))
          ((fx=? n fast-digits) (values #f m n))
          (else (digit-run bv (fx+ i 1) end (fx+ (fx* m 10) (digit-of bv i)) (fx+ n 1)))))

  ;; exponent-value : Bytevector Index Index Nat -> (U Nat #f)
  ;; The value of digits V followed by the digits of BV from I to END; #f
  ;; if a byte is not a digit, or once the value passes exponent-cap.
  (define (exponent-value bv i end v)
    (cond ((fx=? i end) v)
          ((not (digit? (bytevector-u8-ref bv i))) #f)
          (else (let ((v (fx+ (fx* v 10) (digit-of bv i))))
                  (and (fx<=? v exponent-cap) (exponent-value bv (fx+ i 1) end v))))))

  ;; one-operation : Fixnum Fixnum -> Flonum
  ;; M x 10^E by one flonum multiply or divide. When M has at most
  ;; one-operation-digits digits and E is within max-power, both operands
  ;; are exact flonums, so its one rounding gives the nearest flonum
  ;; (Clinger's fast path).
  (define (one-operation m e)
    (if (fx>=? e 0)
        (fl* (fixnum->flonum m) (vector-ref flonum-powers e))
        (fl/ (fixnum->flonum m) (vector-ref flonum-powers (fx- 0 e)))))

  ;; exact-operation : Fixnum Fixnum -> Flonum
  ;; The flonum nearest M x 10^E, E within max-power: inexact of the exact
  ;; value, which R6RS makes the nearest.
  (define (exact-operation m e)
    (inexact (if (fx>=? e 0)
                 (* m (vector-ref exact-powers e))
                 (/ m (vector-ref exact-powers (fx- 0 e))))))

  ;; fast-flonum : Boolean Fixnum Nat Fixnum -> (U Flonum #f)
  ;; The flonum nearest M x 10^E, negated if NEG?, where M has N digits; #f
  ;; when E is past max-power either way. The sign goes on M before it
  ;; converts, so the result is the only flonum made; a zero has no sign
  ;; as a fixnum, and is 0.0 or -0.0 here.
  (define (fast-flonum neg? m n e)
    (cond ((not (fx<=? (fx- 0 max-power) e max-power)) #f)
          ((fx=? m 0) (if neg? -0.0 0.0))
          ((fx<=? n one-operation-digits) (one-operation (if neg? (fx- 0 m) m) e))
          (else (exact-operation (if neg? (fx- 0 m) m) e))))

  ;; fast-exponent : Bytevector Index Index Boolean Fixnum Nat Nat -> (U Flonum #f)
  ;; From I, just past a significand M of N digits, FD of them in its
  ;; fraction: the exponent, if one follows, then the flonum. #f unless
  ;; the rest is [eE][+-]?[0-9]+, or nothing.
  (define (fast-exponent bv i end neg? m n fd)
    (cond ((fx=? i end) (fast-flonum neg? m n (fx- 0 fd)))
          ((or (holds-byte? bv i end 101) (holds-byte? bv i end 69))      ; e E
           (let* ((minus? (holds-byte? bv (fx+ i 1) end 45))               ; -
                  (j (if (or minus? (holds-byte? bv (fx+ i 1) end 43))     ; +
                         (fx+ i 2)
                         (fx+ i 1)))
                  (v (and (fx<? j end) (exponent-value bv j end 0))))
             (and v (fast-flonum neg? m n (fx- (if minus? (fx- 0 v) v) fd)))))
          (else #f)))

  ;; fast-decimal : Bytevector Index Index Boolean Fixnum Nat -> (U Flonum #f)
  ;; From I, just past the integer part of a significand M of N digits:
  ;; the fraction, if one follows, then the exponent. #f unless a . has a
  ;; digit after it, and the digits stay within fast-digits.
  (define (fast-decimal bv i end neg? m n)
    (if (holds-byte? bv i end 46)                                          ; .
        (let-values (((j m* n*) (digit-run bv (fx+ i 1) end m n)))
          (and j (fx>? j (fx+ i 1))
               (fast-exponent bv j end neg? m* n* (fx- n* n))))
        (fast-exponent bv i end neg? m n 0)))

  ;; fast-number : json-assembler -> (U Real #f)
  ;; The number the assembler's text makes, read from its buffer where it
  ;; lies, or #f for the general path to take it. In flonum and exact
  ;; modes, an integer of at most fast-digits digits, and in exact mode
  ;; within the digit limit too; in flonum mode, a decimal whose
  ;; significand has as many, leading zeros counted, and whose value is
  ;; m x 10^e with e within max-power either way. #f in text mode, and for
  ;; any text that is not a JSON number, which the general path raises
  ;; for.
  (define (fast-number a)
    (let ((mode (assembler-mode a)) (bv (assembler-buffer a)) (end (assembler-fill a)))
      (and (not (eq? mode 'text))
           (let* ((neg? (holds-byte? bv 0 end 45))                         ; -
                  (i (if neg? 1 0)))
             (and (holds-digit? bv i end)
                  ;; A 0 is the whole integer part.
                  (not (and (holds-byte? bv i end 48) (holds-digit? bv (fx+ i 1) end)))
                  (let-values (((j m n) (digit-run bv i end 0 0)))
                    (cond ((not j) #f)
                          ;; exact mode's range check counts the text's own
                          ;; digits: json-assembler-chars! and -escape! add
                          ;; some without counting them.
                          ((fx=? j end)
                           (and (or (eq? mode 'flonum) (fx<=? n (assembler-limit a)))
                                (if neg? (fx- 0 m) m)))
                          ((eq? mode 'flonum) (fast-decimal bv j end neg? m n))
                          (else #f))))))))

  ;; json-assembler-number! : json-assembler -> (U Real json-number json-stop)
  ;; The number the parts so far make, converted by the number mode, and
  ;; the assembler emptied. Returns a stop for number-too-long and
  ;; number-out-of-range; number-too-long when both apply, since the text
  ;; past the limit was never kept. Raises if the parts are not a JSON
  ;; number.
  ;;
  ;; The digit limit is checked first. Then a short number is read where
  ;; it lies, by fast-number; any other is copied out, checked against
  ;; JSON's grammar and read by string->number.
  (define (json-assembler-number! a)
    (check-assembler 'json-assembler-number! a)
    (cond
      ((not (assembler-digits a)) (clear! a) too-long)
      ((fast-number a) => (lambda (x) (clear! a) x))
      (else
       (let* ((bv (take! a))
              (end (bytevector-length bv)))
         (let-values (((ok? e-at) (number-shape bv 0 end)))
           (unless ok?
             (assertion-violation 'json-assembler-number! "the parts are not a JSON number"
                                  (utf8->string bv)))
           (let ((text (utf8->string bv)))
             (case (assembler-mode a)
               ((flonum)
                ;; string->number reads a number with no fraction and no
                ;; exponent as an exact integer, never infinite.
                (let ((x (string->number text)))
                  (if (infinite? x) out-of-range x)))
               ((exact)
                (let ((limit (assembler-limit a)))
                  (if (> (+ (count-digits bv 0 e-at) (exponent-size bv e-at end limit)) limit)
                      out-of-range
                      (string->number (string-append "#e" text)))))
               (else (new-json-number text)))))))))

  ;; json-assembler-reset! : json-assembler -> Void
  ;; Drops any text the assembler holds, ready for a new document.
  (define (json-assembler-reset! a)
    (check-assembler 'json-assembler-reset! a)
    (clear! a)))
