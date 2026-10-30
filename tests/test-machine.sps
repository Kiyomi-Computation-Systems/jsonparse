#!r6rs
;;; The machine's in-house cases (ADR-0012 Decision 4), each naming the clause
;;; it tests: RFC 8259 §n, RFC 3629 §n or ADR-000n.
;;;
;;; Every expected value was derived by hand, from the clause, from the
;;; grammar in grammar/jsonparse-grammar.sls read as byte-machine's docs
;;; describe it, and from counting bytes; none was copied from a run. The
;;; rules the derivations lean on:
;;;
;;;   - an error reached over a reexecute edge is at the offending byte's
;;;     offset; one after an advance, such as an open's failed decrement or
;;;     a surrogate check after the fourth hex digit, is at the offset after
;;;     the byte; one at end of input is at the stream's length;
;;;   - a reading node with no end-of-input target of its own ends the parse
;;;     with the machine's default, unexpected-eof;
;;;   - a span that ends having delivered nothing gets one empty fragment,
;;;     so an escape sits between two (chars #vu8()) when no text flanks it;
;;;   - an error inside a span keeps the bytes the span took since its last
;;;     fragment, and trace-content joins them on, so a broken UTF-8
;;;     sequence's good bytes show as the string's last fragment.
;;;
;;; Each case runs on both machines, the generated parser and byte-machine's
;;; interpreter running grammar/, and both must give the expected content.
;;; Group 7 runs every case shorter than 64 bytes under every schedule
;;; (byte-machine test property-driver)'s schedules-for returns, from a fixed
;;; prng state: the content must equal the one-feed content, and the two
;;; machines' raw traces must be equal (ADR-0012 Decision 5).
(import (rnrs)
        (srfi :64)
        (jsonparse-testing)
        (jsonparse-testing machine)
        (only (byte-machine test property-driver) schedules-for)
        (only (byte-machine test prng) make-prng)
        (only (byte-machine private conditions)
              byte-machine-contract-condition?
              byte-machine-contract-condition-who
              byte-machine-contract-condition-code
              byte-machine-contract-condition-detail))

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

;; --- building inputs and traces -------------------------------------------

;; bytes : (U String Byte Bytevector) ... -> Bytevector
;; The parts in order: a string as its UTF-8, an integer as one byte.
(define (bytes . parts)
  (let ((bvs (map (lambda (p)
                    (cond ((string? p) (string->utf8 p))
                          ((integer? p) (let ((b (make-bytevector 1))) (bytevector-u8-set! b 0 p) b))
                          (else p)))
                  parts)))
    (let ((out (make-bytevector (fold-left + 0 (map bytevector-length bvs)))))
      (fold-left (lambda (at bv)
                   (bytevector-copy! bv 0 out at (bytevector-length bv))
                   (+ at (bytevector-length bv)))
                 0 bvs)
      out)))

;; repeated : Nat (U String Byte) -> Bytevector
(define (repeated n part)
  (apply bytes (copies n part)))

;; copies : Nat a -> (Listof a)
(define (copies n x)
  (let loop ((n n) (acc '())) (if (= n 0) acc (loop (- n 1) (cons x acc)))))

;; copies* : Nat (Listof a) -> (Listof a)
;; N copies of XS, appended.
(define (copies* n xs)
  (apply append (copies n xs)))

(define AS 'array-start) (define AE 'array-end)
(define OS 'object-start) (define OE 'object-end)
(define KS 'key-start) (define KE 'key-end)
(define SS 'string-start) (define SE 'string-end)
(define NE 'number-end)
(define ctx-a '(context array))
(define ctx-o '(context object))
(define acc '(accepted))
(define (ch . parts) (list 'chars (apply bytes parts)))
(define (nm text) (list 'number (string->utf8 text)))
(define (esc cp) (list 'escape cp))
(define (rej code at) (list 'rejected code at))

(define (iota n) (let loop ((i (- n 1)) (acc '())) (if (< i 0) acc (loop (- i 1) (cons i acc)))))

;; --- the cases ------------------------------------------------------------

;; A case: its group, its name (which starts with its clause), its input,
;; the settable fields it starts with, and its whole expected trace-content.
(define cases '())
(define (case! group name bv fields expected)
  (set! cases (cons (list group name bv fields expected) cases)))
(define (case-group c) (list-ref c 0))
(define (case-name c) (list-ref c 1))
(define (case-bytes c) (list-ref c 2))
(define (case-fields c) (list-ref c 3))
(define (case-expected c) (list-ref c 4))

(define (limit n) (list (cons 'depth-left n)))
(define mode-1 '((mode . 1)))

;; ============ 1. Depth (ADR-0005) =========================================
;; An open spends one of depth-left after its byte is consumed, so the open
;; past the limit fails at the offset after its `[` or `{`. A close gives one
;; back. The default limit is 512.

;; N nested arrays, closed: N starts, the innermost end, then each outer
;; close asks context (the stack's top is an array) and ends.
(define (nested-accepted n)
  (append (copies n AS) (list AE) (copies* (- n 1) (list ctx-a AE)) (list acc)))

(case! 'depth "ADR-0005: the default limit: 512 nested arrays are accepted"
       (bytes (repeated 512 "[") (repeated 512 "]")) '()
       (nested-accepted 512))
(case! 'depth "ADR-0005: the default limit: the 513th open is nesting-too-deep at offset 513, after its `[` at 512"
       (bytes (repeated 513 "[") (repeated 513 "]")) '()
       (append (copies 512 AS) (list (rej 'nesting-too-deep 513))))

(case! 'depth "ADR-0005: limit 1: an array at depth 1 is accepted"
       (bytes "[]") (limit 1) (list AS AE acc))
(case! 'depth "ADR-0005: limit 1: an object at depth 1 is accepted"
       (bytes "{}") (limit 1) (list OS OE acc))
(case! 'depth "ADR-0005: limit 1: an object in an array fails at offset 2"
       (bytes "[{}]") (limit 1) (list AS (rej 'nesting-too-deep 2)))
(case! 'depth "ADR-0005: limit 1: an object as a member's value fails after its `{` at 5"
       (bytes "{\"a\":{}}") (limit 1)
       (list OS KS (ch "a") KE (rej 'nesting-too-deep 6)))
(case! 'depth "ADR-0005: limit 1, with mode bit 0: closes give the room back, so three top-level containers are accepted"
       (bytes "[]{}[]") '((depth-left . 1) (mode . 1))
       (list AS AE OS OE AS AE acc))

(case! 'depth "ADR-0005: limit 3: array, object, array is accepted"
       (bytes "[{\"a\":[]}]") (limit 3)
       (list AS OS KS (ch "a") KE AS AE ctx-o OE ctx-a AE acc))
(case! 'depth "ADR-0005: limit 3: a fourth open, an object at 7, fails at 8"
       (bytes "[{\"a\":[{}]}]") (limit 3)
       (list AS OS KS (ch "a") KE AS (rej 'nesting-too-deep 8)))
(case! 'depth "ADR-0005: limit 3: four nested arrays fail at 4"
       (bytes "[[[[]]]]") (limit 3)
       (list AS AS AS (rej 'nesting-too-deep 4)))
(case! 'depth "ADR-0005: limit 3: sibling arrays each reach depth 3, so closes give the room back"
       (bytes "[[[]],[[]],[[]]]") (limit 3)
       (append (list AS AS AS AE ctx-a AE ctx-a)
               (list AS AS AE ctx-a AE ctx-a)
               (list AS AS AE ctx-a AE ctx-a)
               (list AE acc)))
(case! 'depth "ADR-0005: limit 3: sibling objects each reach depth 3"
       (bytes "[{\"a\":[]},{\"b\":[]}]") (limit 3)
       (list AS OS KS (ch "a") KE AS AE ctx-o OE ctx-a
             OS KS (ch "b") KE AS AE ctx-o OE ctx-a AE acc))

;; A close gives back exactly one, not more: after closes, reopening past
;; the limit still fails, and one limit higher the same input is accepted.
(case! 'depth "ADR-0005: limit 3: after two closes, three reopens pass the limit at 9"
       (bytes "[[[]],[[[]]]]") (limit 3)
       (list AS AS AS AE ctx-a AE ctx-a AS AS (rej 'nesting-too-deep 9)))
(case! 'depth "ADR-0005: limit 4: the same closes and reopens are accepted"
       (bytes "[[[]],[[[]]]]") (limit 4)
       (list AS AS AS AE ctx-a AE ctx-a AS AS AS AE ctx-a AE ctx-a AE ctx-a AE acc))
(case! 'depth "ADR-0005: limit 2: after a close, two reopens pass the limit at 6"
       (bytes "[[],[[]]]") (limit 2)
       (list AS AS AE ctx-a AS (rej 'nesting-too-deep 6)))
(case! 'depth "ADR-0005: limit 3: the same close and reopens are accepted"
       (bytes "[[],[[]]]") (limit 3)
       (list AS AS AE ctx-a AS AS AE ctx-a AE ctx-a AE acc))
(case! 'depth "ADR-0005: limit 2: in an object, after a close, two reopens pass the limit at 14"
       (bytes "{\"a\":[],\"b\":[[]]}") (limit 2)
       (list OS KS (ch "a") KE AS AE ctx-o KS (ch "b") KE AS (rej 'nesting-too-deep 14)))
(case! 'depth "ADR-0005: limit 3: the same object is accepted"
       (bytes "{\"a\":[],\"b\":[[]]}") (limit 3)
       (list OS KS (ch "a") KE AS AE ctx-o KS (ch "b") KE AS AS AE ctx-a AE ctx-o OE acc))

(case! 'depth "ADR-0005: limit 7: arrays and objects alternating 7 deep are accepted"
       (bytes "[{\"k\":[{\"k\":[{\"k\":[]}]}]}]") (limit 7)
       (append (list AS)
               (copies* 3 (list OS KS (ch "k") KE AS))
               (list AE)
               (copies* 3 (list ctx-o OE ctx-a AE))
               (list acc)))
(case! 'depth "ADR-0005: limit 7: an eighth open, an object at 19, fails at 20"
       (bytes "[{\"k\":[{\"k\":[{\"k\":[{}]}]}]}]") (limit 7)
       (append (list AS)
               (copies* 3 (list OS KS (ch "k") KE AS))
               (list (rej 'nesting-too-deep 20))))

(case! 'depth "ADR-0005: limit 0: an array fails at 1"
       (bytes "[]") (limit 0) (list (rej 'nesting-too-deep 1)))
(case! 'depth "ADR-0005: limit 0: an object after whitespace fails at 2"
       (bytes " {}") (limit 0) (list (rej 'nesting-too-deep 2)))
(case! 'depth "ADR-0005: limit 0: a number is accepted"
       (bytes "7") (limit 0) (list (nm "7") NE acc))
(case! 'depth "ADR-0005: limit 0: a string is accepted"
       (bytes "\"a\"") (limit 0) (list SS (ch "a") SE acc))
(case! 'depth "ADR-0005: limit 0: null is accepted"
       (bytes "null") (limit 0) (list 'null acc))

(case! 'depth "ADR-0005: limit 65535, the uint16 top: 65535 nested arrays are accepted"
       (bytes (repeated 65535 "[") (repeated 65535 "]")) (limit 65535)
       (nested-accepted 65535))
(case! 'depth "ADR-0005: limit 65535: the 65536th open fails at 65536"
       (repeated 65536 "[") (limit 65535)
       (append (copies 65535 AS) (list (rej 'nesting-too-deep 65536))))

;; ============ 2. Mode bit 0 (ADR-0014 `values`; RFC 8259 §2) ===============
;; After a top-level value, top-done takes whitespace, finishes at end of
;; input, and sends any other byte to top-more. top-more goes on to a new
;; value when bit 0 of mode is set, and is trailing-garbage otherwise. So
;; under the bit, values that need no separator follow each other with none.

(define many-values (bytes "1 \t\r\n\"a\"\n[true]\r{}\tnull"))

(case! 'mode "mode bit 0: values separated by spaces, tabs, CR and LF are accepted"
       many-values mode-1
       (list (nm "1") NE SS (ch "a") SE AS 'true ctx-a AE OS OE 'null acc))
(case! 'mode "RFC 8259 §2: without the bit, the second value, at 5, is trailing-garbage"
       many-values '()
       (list (nm "1") NE (rej 'trailing-garbage 5)))
(case! 'mode "RFC 8259 §2: `1 2` without the bit is trailing-garbage at 2"
       (bytes "1 2") '() (list (nm "1") NE (rej 'trailing-garbage 2)))
(case! 'mode "mode bit 0: `1 2` is two numbers"
       (bytes "1 2") mode-1 (list (nm "1") NE (nm "2") NE acc))
(case! 'mode "mode bit 0: mode 2 does not set bit 0, so `1 2` is trailing-garbage"
       (bytes "1 2") '((mode . 2)) (list (nm "1") NE (rej 'trailing-garbage 2)))
(case! 'mode "mode bit 0: mode 254 does not set bit 0, so `1 2` is trailing-garbage"
       (bytes "1 2") '((mode . 254)) (list (nm "1") NE (rej 'trailing-garbage 2)))
(case! 'mode "mode bit 0: mode 255 sets bit 0, so `1 2` is two numbers"
       (bytes "1 2") '((mode . 255)) (list (nm "1") NE (nm "2") NE acc))

(case! 'mode "mode bit 0: `[]{}` needs no separator"
       (bytes "[]{}") mode-1 (list AS AE OS OE acc))
(case! 'mode "RFC 8259 §2: `[]{}` without the bit is trailing-garbage at 2"
       (bytes "[]{}") '() (list AS AE (rej 'trailing-garbage 2)))
(case! 'mode "mode bit 0: `\"a\"\"b\"` needs no separator"
       (bytes "\"a\"\"b\"") mode-1 (list SS (ch "a") SE SS (ch "b") SE acc))
(case! 'mode "RFC 8259 §2: `\"a\"\"b\"` without the bit is trailing-garbage at 3"
       (bytes "\"a\"\"b\"") '() (list SS (ch "a") SE (rej 'trailing-garbage 3)))
(case! 'mode "mode bit 0: `truefalse` is two literals"
       (bytes "truefalse") mode-1 (list 'true 'false acc))
(case! 'mode "RFC 8259 §2: `truefalse` without the bit is trailing-garbage at 4"
       (bytes "truefalse") '() (list 'true (rej 'trailing-garbage 4)))
(case! 'mode "mode bit 0: `-1-2` is two numbers: a `-` ends a number and starts the next"
       (bytes "-1-2") mode-1 (list (nm "-1") NE (nm "-2") NE acc))
(case! 'mode "RFC 8259 §2: `-1-2` without the bit is trailing-garbage at 2"
       (bytes "-1-2") '() (list (nm "-1") NE (rej 'trailing-garbage 2)))
(case! 'mode "mode bit 0: `1.5.5` is 1.5, then a value cannot start with `.` at 3"
       (bytes "1.5.5") mode-1 (list (nm "1.5") NE (rej 'unexpected-byte 3)))

(case! 'mode "RFC 8259 §6: a top-level number may end the input, without the bit"
       (bytes "7") '() (list (nm "7") NE acc))
(case! 'mode "mode bit 0: a top-level number may end the input, with the bit"
       (bytes "7") mode-1 (list (nm "7") NE acc))
(case! 'mode "mode bit 0: a last number followed by whitespace"
       (bytes "7 8\n") mode-1 (list (nm "7") NE (nm "8") NE acc))
(case! 'mode "mode bit 0: a number at the end inside an array is still unexpected-eof"
       (bytes "[7") mode-1 (list AS (nm "7") NE (rej 'unexpected-eof 2)))
(case! 'mode "mode bit 0: a byte that starts no value, after a value, is unexpected-byte, not trailing-garbage"
       (bytes "1 x") mode-1 (list (nm "1") NE (rej 'unexpected-byte 2)))
(case! 'mode "RFC 8259 §2: the same byte without the bit is trailing-garbage"
       (bytes "1 x") '() (list (nm "1") NE (rej 'trailing-garbage 2)))
(case! 'mode "mode bit 0: a second value cut short is unexpected-eof"
       (bytes "1 tr") mode-1 (list (nm "1") NE (rej 'unexpected-eof 4)))
(case! 'mode "mode bit 0: empty input still needs a first value"
       (bytes) mode-1 (list (rej 'unexpected-eof 0)))
(case! 'mode "mode bit 0: whitespace alone still needs a first value"
       (bytes " \n") mode-1 (list (rej 'unexpected-eof 2)))

;; ============ 3. UTF-8 inside strings (RFC 3629 §3, §4; ADR-0012 §4) ======
;; Each input is a quote, the sequence, and a quote, so the sequence starts
;; at offset 1. A rejection is invalid-utf8 at the first byte the table of
;; RFC 3629 §4 refuses, and the string's last fragment holds the sequence's
;; bytes before it.

(define (utf8-accepted name . seq)
  (case! 'utf8 name (apply bytes "\"" (append seq (list "\""))) '()
         (list SS (apply ch seq) SE acc)))

;; utf8-rejected NAME GOOD BAD: the sequence GOOD (bytes RFC 3629 allows so
;; far) then BAD, then a quote. The error is at 1 + (length GOOD).
(define (utf8-rejected name good bad)
  (case! 'utf8 name (apply bytes "\"" (append good bad (list "\""))) '()
         (list SS (apply ch good) (rej 'invalid-utf8 (+ 1 (length good))))))

;; Every lead byte RFC 3629 §4 allows, C2..DF, E0..EF and F0..F4, with its
;; smallest sequence: each continuation at 80, except the second byte the
;; table raises for E0 (A0) and F0 (90).
(define (byte-range lo hi) (if (> lo hi) '() (cons lo (byte-range (+ lo 1) hi))))
(define (smallest-sequence lead)
  (cond ((<= #xC2 lead #xDF) (list lead #x80))
        ((= lead #xE0) (list lead #xA0 #x80))
        ((<= #xE1 lead #xEF) (list lead #x80 #x80))
        ((= lead #xF0) (list lead #x90 #x80 #x80))
        (else (list lead #x80 #x80 #x80))))
(define (hex-bytes bs)
  (fold-left (lambda (s b) (string-append s (if (string=? s "") "" " ")
                                          (string-upcase (number->string b 16))))
             "" bs))
(for-each
 (lambda (lead)
   (let ((seq (smallest-sequence lead)))
     (apply utf8-accepted
            (string-append "RFC 3629 §4: lead " (hex-bytes (list lead))
                           ", its smallest sequence " (hex-bytes seq))
            seq)))
 (append (byte-range #xC2 #xDF) (byte-range #xE0 #xEF) (byte-range #xF0 #xF4)))

;; the largest sequences at each range's top
(utf8-accepted "RFC 3629 §4: DF BF, U+07FF, the last two-byte form" #xDF #xBF)
(utf8-accepted "RFC 3629 §4: E0 BF BF, U+0FFF" #xE0 #xBF #xBF)
(utf8-accepted "RFC 3629 §4: EC BF BF, U+CFFF" #xEC #xBF #xBF)
(utf8-accepted "RFC 3629 §4: ED 9F BF, U+D7FF, the last before the surrogates" #xED #x9F #xBF)
(utf8-accepted "RFC 3629 §4: EF BF BF, U+FFFF" #xEF #xBF #xBF)
(utf8-accepted "RFC 3629 §4: F0 BF BF BF, U+3FFFF" #xF0 #xBF #xBF #xBF)
(utf8-accepted "RFC 3629 §4: F3 BF BF BF, U+FFFFF" #xF3 #xBF #xBF #xBF)
(utf8-accepted "RFC 3629 §4: F4 8F BF BF, U+10FFFF, the last scalar value" #xF4 #x8F #xBF #xBF)
(utf8-accepted "RFC 3629 §4: text around a three-byte form, U+20AC" "a" #xE2 #x82 #xAC "b")

;; the bounds around each range
(utf8-rejected "RFC 3629 §4: lead C1, below C2" '() '(#xC1 #x80))
(utf8-rejected "RFC 3629 §4: C2 then 7F, below the continuations" '(#xC2) '(#x7F))
(utf8-rejected "RFC 3629 §4: C2 then C0, above the continuations" '(#xC2) '(#xC0))
(utf8-rejected "RFC 3629 §4: DF then C0" '(#xDF) '(#xC0))
(utf8-rejected "RFC 3629 §4: E0 then 9F, below E0's A0" '(#xE0) '(#x9F #x80))
(utf8-rejected "RFC 3629 §4: E0 then C0, above E0's BF" '(#xE0) '(#xC0 #x80))
(utf8-rejected "RFC 3629 §4: E0 A0 then 7F" '(#xE0 #xA0) '(#x7F))
(utf8-rejected "RFC 3629 §4: E0 BF then C0" '(#xE0 #xBF) '(#xC0))
(utf8-rejected "RFC 3629 §4: E1 then 7F" '(#xE1) '(#x7F #x80))
(utf8-rejected "RFC 3629 §4: EC then C0" '(#xEC) '(#xC0 #x80))
(utf8-rejected "RFC 3629 §4: E1 80 then 7F" '(#xE1 #x80) '(#x7F))
(utf8-rejected "RFC 3629 §4: EC BF then C0" '(#xEC #xBF) '(#xC0))
(utf8-rejected "RFC 3629 §4: ED then 7F" '(#xED) '(#x7F #x80))
(utf8-rejected "RFC 3629 §4: ED 9F then C0" '(#xED #x9F) '(#xC0))
(utf8-rejected "RFC 3629 §4: EE then 7F" '(#xEE) '(#x7F #x80))
(utf8-rejected "RFC 3629 §4: EF then C0" '(#xEF) '(#xC0 #x80))
(utf8-rejected "RFC 3629 §4: EF BF then C0" '(#xEF #xBF) '(#xC0))
(utf8-rejected "RFC 3629 §4: F0 then C0, above F0's BF" '(#xF0) '(#xC0 #x80 #x80))
(utf8-rejected "RFC 3629 §4: F0 90 then 7F" '(#xF0 #x90) '(#x7F #x80))
(utf8-rejected "RFC 3629 §4: F0 90 80 then C0" '(#xF0 #x90 #x80) '(#xC0))
(utf8-rejected "RFC 3629 §4: F1 then 7F" '(#xF1) '(#x7F #x80 #x80))
(utf8-rejected "RFC 3629 §4: F3 then C0" '(#xF3) '(#xC0 #x80 #x80))
(utf8-rejected "RFC 3629 §4: F1 80 then 7F" '(#xF1 #x80) '(#x7F #x80))
(utf8-rejected "RFC 3629 §4: F3 BF BF then C0" '(#xF3 #xBF #xBF) '(#xC0))
(utf8-rejected "RFC 3629 §4: F4 then 7F" '(#xF4) '(#x7F #x80 #x80))
(utf8-rejected "RFC 3629 §4: F4 8F BF then C0" '(#xF4 #x8F #xBF) '(#xC0))

;; overlong forms
(utf8-rejected "RFC 3629 §3: overlong C0 80, U+0000 in two bytes" '() '(#xC0 #x80))
(utf8-rejected "RFC 3629 §3: overlong C1 BF, U+007F in two bytes" '() '(#xC1 #xBF))
(utf8-rejected "RFC 3629 §3: overlong E0 80 80, U+0000 in three bytes" '(#xE0) '(#x80 #x80))
(utf8-rejected "RFC 3629 §3: overlong E0 9F BF, U+07FF in three bytes" '(#xE0) '(#x9F #xBF))
(utf8-rejected "RFC 3629 §3: overlong F0 80 80 80, U+0000 in four bytes" '(#xF0) '(#x80 #x80 #x80))
(utf8-rejected "RFC 3629 §3: overlong F0 8F BF BF, U+FFFF in four bytes" '(#xF0) '(#x8F #xBF #xBF))

;; encoded surrogates
(utf8-rejected "RFC 3629 §3: ED A0 80, the surrogate U+D800" '(#xED) '(#xA0 #x80))
(utf8-rejected "RFC 3629 §3: ED AF BF, the surrogate U+DBFF" '(#xED) '(#xAF #xBF))
(utf8-rejected "RFC 3629 §3: ED B0 80, the surrogate U+DC00" '(#xED) '(#xB0 #x80))
(utf8-rejected "RFC 3629 §3: ED BF BF, the surrogate U+DFFF" '(#xED) '(#xBF #xBF))

;; above U+10FFFF
(utf8-rejected "RFC 3629 §3: F4 90 80 80, U+110000" '(#xF4) '(#x90 #x80 #x80))
(utf8-rejected "RFC 3629 §3: F4 BF BF BF, U+13FFFF" '(#xF4) '(#xBF #xBF #xBF))
(utf8-rejected "RFC 3629 §3: lead F5" '() '(#xF5 #x80 #x80 #x80))
(utf8-rejected "RFC 3629 §3: lead F6" '() '(#xF6 #x80 #x80 #x80))
(utf8-rejected "RFC 3629 §3: lead F7" '() '(#xF7 #xBF #xBF #xBF))

;; five- and six-byte leads, FE, FF, lone continuations
(utf8-rejected "RFC 3629 §3: five-byte lead F8" '() '(#xF8 #x88 #x80 #x80 #x80))
(utf8-rejected "RFC 3629 §3: five-byte lead F9" '() '(#xF9 #x80 #x80 #x80 #x80))
(utf8-rejected "RFC 3629 §3: five-byte lead FA" '() '(#xFA #x80 #x80 #x80 #x80))
(utf8-rejected "RFC 3629 §3: five-byte lead FB" '() '(#xFB #xBF #xBF #xBF #xBF))
(utf8-rejected "RFC 3629 §3: six-byte lead FC" '() '(#xFC #x84 #x80 #x80 #x80 #x80))
(utf8-rejected "RFC 3629 §3: six-byte lead FD" '() '(#xFD #xBF #xBF #xBF #xBF #xBF))
(utf8-rejected "RFC 3629 §3: FE never appears" '() '(#xFE))
(utf8-rejected "RFC 3629 §3: FF never appears" '() '(#xFF))
(utf8-rejected "RFC 3629 §3: a lone continuation byte 80" '() '(#x80))
(utf8-rejected "RFC 3629 §3: a lone continuation byte BF after text" '(#x61) '(#xBF))

;; truncated at the closing quote: the quote is the first bad byte
(utf8-rejected "RFC 3629 §3: C2 cut short by the closing quote" '(#xC2) '())
(utf8-rejected "RFC 3629 §3: E0 cut short by the closing quote" '(#xE0) '())
(utf8-rejected "RFC 3629 §3: E0 A0 cut short by the closing quote" '(#xE0 #xA0) '())
(utf8-rejected "RFC 3629 §3: ED 9F cut short by the closing quote" '(#xED #x9F) '())
(utf8-rejected "RFC 3629 §3: F0 90 80 cut short by the closing quote" '(#xF0 #x90 #x80) '())
(utf8-rejected "RFC 3629 §3: F4 8F cut short by the closing quote" '(#xF4 #x8F) '())

;; truncated at end of input: unexpected-eof at the input's length
(define (utf8-eof name . seq)
  (case! 'utf8 name (apply bytes "\"" seq) '()
         (list SS (apply ch seq) (rej 'unexpected-eof (+ 1 (length seq))))))
(utf8-eof "RFC 3629 §3: C2 cut short by the end of input" #xC2)
(utf8-eof "RFC 3629 §3: ED cut short by the end of input" #xED)
(utf8-eof "RFC 3629 §3: E0 A0 cut short by the end of input" #xE0 #xA0)
(utf8-eof "RFC 3629 §3: F0 90 80 cut short by the end of input" #xF0 #x90 #x80)
(utf8-eof "RFC 3629 §3: F4 cut short by the end of input" #xF4)

(case! 'utf8 "RFC 3629 §4: a key's UTF-8 is accepted the same way"
       (bytes "{\"" #xC3 #xA9 "\":0}") '()
       (list OS KS (ch #xC3 #xA9) KE (nm "0") NE ctx-o OE acc))
(case! 'utf8 "RFC 3629 §3: a key's overlong lead is refused the same way, at 2"
       (bytes "{\"" #xC0 #x80 "\":0}") '()
       (list OS KS (ch) (rej 'invalid-utf8 2)))

;; ============ 4. Escapes and surrogates (RFC 8259 §7) =====================
;; A backslash ends the text run; the escape's code unit is the cp field;
;; the run starts again after it. A high surrogate's escape is announced
;; before its low half is read.

(for-each
 (lambda (e)
   (case! 'escape (string-append "RFC 8259 §7: the escape \\" (car e) " is U+"
                                 (number->string (cadr e) 16))
          (bytes "\"a\\" (car e) "b\"") '()
          (list SS (ch "a") (esc (cadr e)) (ch "b") SE acc)))
 '(("\"" #x22) ("\\" #x5C) ("/" #x2F) ("b" #x08) ("f" #x0C) ("n" #x0A) ("r" #x0D) ("t" #x09)))

(case! 'escape "RFC 8259 §7: two escapes in a row, each run between them empty"
       (bytes "\"\\n\\t\"") '()
       (list SS (ch) (esc #x0A) (ch) (esc #x09) (ch) SE acc))
(case! 'escape "RFC 8259 §7: `\\x` is no escape, at 2"
       (bytes "\"\\x\"") '() (list SS (ch) (rej 'invalid-escape 2)))
(case! 'escape "RFC 8259 §7: `\\U` is no escape: the u is lower case only"
       (bytes "\"\\U0041\"") '() (list SS (ch) (rej 'invalid-escape 2)))
(case! 'escape "RFC 8259 §7: `\\'` is no escape"
       (bytes "\"\\'\"") '() (list SS (ch) (rej 'invalid-escape 2)))
(case! 'escape "RFC 8259 §7: a backslash at the end of input"
       (bytes "\"a\\") '() (list SS (ch "a") (rej 'unexpected-eof 3)))

(case! 'escape "RFC 8259 §7: \\u with lower-case hex"
       (bytes "\"\\u00e9\"") '() (list SS (ch) (esc #xE9) (ch) SE acc))
(case! 'escape "RFC 8259 §7: \\u with upper-case hex"
       (bytes "\"\\u00E9\"") '() (list SS (ch) (esc #xE9) (ch) SE acc))
(case! 'escape "RFC 8259 §7: \\u with mixed-case hex"
       (bytes "\"\\uaBcD\"") '() (list SS (ch) (esc #xABCD) (ch) SE acc))
(case! 'escape "RFC 8259 §7: \\u0000 is allowed escaped"
       (bytes "\"\\u0000\"") '() (list SS (ch) (esc 0) (ch) SE acc))
(case! 'escape "RFC 8259 §7: \\uD7FF, just below the surrogates"
       (bytes "\"\\uD7FF\"") '() (list SS (ch) (esc #xD7FF) (ch) SE acc))
(case! 'escape "RFC 8259 §7: \\uE000, just above the surrogates"
       (bytes "\"\\uE000\"") '() (list SS (ch) (esc #xE000) (ch) SE acc))
(case! 'escape "RFC 8259 §7: \\uFFFF"
       (bytes "\"\\uFFFF\"") '() (list SS (ch) (esc #xFFFF) (ch) SE acc))

(case! 'escape "RFC 8259 §7: a pair, U+1D11E as \\uD834\\uDD1E"
       (bytes "\"\\uD834\\uDD1E\"") '()
       (list SS (ch) (esc #xD834) (esc #xDD1E) (ch) SE acc))
(case! 'escape "RFC 8259 §7: the lowest pair, \\uD800\\uDC00"
       (bytes "\"\\uD800\\uDC00\"") '()
       (list SS (ch) (esc #xD800) (esc #xDC00) (ch) SE acc))
(case! 'escape "RFC 8259 §7: the highest pair, \\udbff\\udfff, in lower case"
       (bytes "\"\\udbff\\udfff\"") '()
       (list SS (ch) (esc #xDBFF) (esc #xDFFF) (ch) SE acc))

(case! 'escape "RFC 8259 §7: a lone high surrogate then text, at 7"
       (bytes "\"\\uD800a\"") '()
       (list SS (ch) (esc #xD800) (rej 'invalid-surrogate 7)))
(case! 'escape "RFC 8259 §7: a lone high surrogate then the closing quote, at 7"
       (bytes "\"\\uD800\"") '()
       (list SS (ch) (esc #xD800) (rej 'invalid-surrogate 7)))
(case! 'escape "RFC 8259 §7: a lone high surrogate then the end of input"
       (bytes "\"\\uD800") '()
       (list SS (ch) (esc #xD800) (rej 'unexpected-eof 7)))
(case! 'escape "RFC 8259 §7: a lone high surrogate then \\n: the n, at 8"
       (bytes "\"\\uD800\\n\"") '()
       (list SS (ch) (esc #xD800) (rej 'invalid-surrogate 8)))
(case! 'escape "RFC 8259 §7: a high surrogate then \\u0041, refused after its fourth digit"
       (bytes "\"\\uD800\\u0041\"") '()
       (list SS (ch) (esc #xD800) (rej 'invalid-surrogate 13)))
(case! 'escape "RFC 8259 §7: a high surrogate then a second high one"
       (bytes "\"\\uD800\\uDBFF\"") '()
       (list SS (ch) (esc #xD800) (rej 'invalid-surrogate 13)))
(case! 'escape "RFC 8259 §7: a lone low surrogate \\uDC00, refused after its fourth digit"
       (bytes "\"\\uDC00\"") '()
       (list SS (ch) (rej 'invalid-surrogate 7)))
(case! 'escape "RFC 8259 §7: a lone low surrogate \\uDFFF"
       (bytes "\"\\uDFFF\"") '()
       (list SS (ch) (rej 'invalid-surrogate 7)))

(case! 'escape "RFC 8259 §7: a bad hex digit first: `/`, below 0"
       (bytes "\"\\u/000\"") '() (list SS (ch) (rej 'invalid-escape 3)))
(case! 'escape "RFC 8259 §7: a bad hex digit second: `:`, above 9"
       (bytes "\"\\u0:00\"") '() (list SS (ch) (rej 'invalid-escape 4)))
(case! 'escape "RFC 8259 §7: a bad hex digit third: `@`, below A"
       (bytes "\"\\u00@0\"") '() (list SS (ch) (rej 'invalid-escape 5)))
(case! 'escape "RFC 8259 §7: a bad hex digit fourth: `G`, above F"
       (bytes "\"\\u000G\"") '() (list SS (ch) (rej 'invalid-escape 6)))
(case! 'escape "RFC 8259 §7: a bad hex digit fourth: a backquote, below a"
       (bytes "\"\\u000`\"") '() (list SS (ch) (rej 'invalid-escape 6)))
(case! 'escape "RFC 8259 §7: a bad hex digit fourth: `g`, above f"
       (bytes "\"\\u000g\"") '() (list SS (ch) (rej 'invalid-escape 6)))
(case! 'escape "RFC 8259 §7: a bad hex digit in a low half"
       (bytes "\"\\uD800\\uDC0G\"") '()
       (list SS (ch) (esc #xD800) (rej 'invalid-escape 12)))

(for-each
 (lambda (b)
   (case! 'escape (string-append "RFC 8259 §7: the control character U+00"
                                 (if (< b 16) "0" "") (number->string b 16)
                                 " raw is refused at 1")
          (bytes "\"" b "\"") '()
          (list SS (ch) (rej 'control-character 1))))
 (iota 32))
(case! 'escape "RFC 8259 §7: a control character after text, at 3"
       (bytes "\"ab" #x1F "\"") '() (list SS (ch "ab") (rej 'control-character 3)))
(case! 'escape "RFC 8259 §7: a control character in a key, at 2"
       (bytes "{\"" #x01 "\":1}") '() (list OS KS (ch) (rej 'control-character 2)))
(case! 'escape "RFC 8259 §7: U+0020, the first byte past the controls, is text"
       (bytes "\" \"") '() (list SS (ch " ") SE acc))
(case! 'escape "RFC 8259 §7: U+007F raw is text"
       (bytes "\"" #x7F "\"") '() (list SS (ch #x7F) SE acc))

;; ============ 5. Numbers (RFC 8259 §6) ====================================
;; The span carries the number's text. At a byte that cannot extend it, an
;; accepting state ends the span and announces number-end; any other state
;; is invalid-number at that byte, keeping the text so far. At end of input
;; an accepting state finishes when the number is the top-level value, and
;; is unexpected-eof inside a container; any other state is unexpected-eof.

(for-each
 (lambda (text)
   (case! 'number (string-append "RFC 8259 §6: `" text "` alone is a number")
          (bytes text) '() (list (nm text) NE acc)))
 '("-0" "0e0" "0E+1" "1.5e-3" "0" "-0.0e-0" "123"))
(case! 'number "RFC 8259 §6: the edges as array members"
       (bytes "[-0,0e0,0E+1,1.5e-3]") '()
       (list AS (nm "-0") NE ctx-a (nm "0e0") NE ctx-a (nm "0E+1") NE ctx-a
             (nm "1.5e-3") NE ctx-a AE acc))
(case! 'number "RFC 8259 §6: a number as a member's value"
       (bytes "{\"n\":1.5e-3}") '()
       (list OS KS (ch "n") KE (nm "1.5e-3") NE ctx-o OE acc))

(case! 'number "RFC 8259 §6: `01`: no digit after a leading zero, at 1"
       (bytes "01") '() (list (nm "0") (rej 'invalid-number 1)))
(case! 'number "RFC 8259 §6: `-` alone ends early"
       (bytes "-") '() (list (nm "-") (rej 'unexpected-eof 1)))
(case! 'number "RFC 8259 §6: `1.` ends early"
       (bytes "1.") '() (list (nm "1.") (rej 'unexpected-eof 2)))
(case! 'number "RFC 8259 §6: `.5`: no value starts with `.`"
       (bytes ".5") '() (list (rej 'unexpected-byte 0)))
(case! 'number "RFC 8259 §6: `1e` ends early"
       (bytes "1e") '() (list (nm "1e") (rej 'unexpected-eof 2)))
(case! 'number "RFC 8259 §6: `1e+` ends early"
       (bytes "1e+") '() (list (nm "1e+") (rej 'unexpected-eof 3)))
(case! 'number "RFC 8259 §6: `+1`: no value starts with `+`"
       (bytes "+1") '() (list (rej 'unexpected-byte 0)))
(case! 'number "RFC 8259 §6: `0x1` is 0 then trailing-garbage at 1"
       (bytes "0x1") '() (list (nm "0") NE (rej 'trailing-garbage 1)))

(case! 'number "RFC 8259 §6: `[01]`, at 2"
       (bytes "[01]") '() (list AS (nm "0") (rej 'invalid-number 2)))
(case! 'number "RFC 8259 §6: `[-01]`, at 3"
       (bytes "[-01]") '() (list AS (nm "-0") (rej 'invalid-number 3)))
(case! 'number "RFC 8259 §6: `[-]`: the `]` at 2"
       (bytes "[-]") '() (list AS (nm "-") (rej 'invalid-number 2)))
(case! 'number "RFC 8259 §6: `[-a]`: the `a` at 2"
       (bytes "[-a]") '() (list AS (nm "-") (rej 'invalid-number 2)))
(case! 'number "RFC 8259 §6: `[1.]`: the `]` at 3"
       (bytes "[1.]") '() (list AS (nm "1.") (rej 'invalid-number 3)))
(case! 'number "RFC 8259 §6: `[1.e1]`: the `e` at 3"
       (bytes "[1.e1]") '() (list AS (nm "1.") (rej 'invalid-number 3)))
(case! 'number "RFC 8259 §6: `[.5]`: the `.` at 1"
       (bytes "[.5]") '() (list AS (rej 'unexpected-byte 1)))
(case! 'number "RFC 8259 §6: `[1e]`: the `]` at 3"
       (bytes "[1e]") '() (list AS (nm "1e") (rej 'invalid-number 3)))
(case! 'number "RFC 8259 §6: `[1e+]`: the `]` at 4"
       (bytes "[1e+]") '() (list AS (nm "1e+") (rej 'invalid-number 4)))
(case! 'number "RFC 8259 §6: `[+1]`: the `+` at 1"
       (bytes "[+1]") '() (list AS (rej 'unexpected-byte 1)))
(case! 'number "RFC 8259 §6: `[0x1]`: 0, then the `x` at 2"
       (bytes "[0x1]") '() (list AS (nm "0") NE ctx-a (rej 'unexpected-byte 2)))

(case! 'number "RFC 8259 §6: a top-level number may end the input"
       (bytes "12") '() (list (nm "12") NE acc))
(case! 'number "RFC 8259 §6: a number ending the input inside an array is unexpected-eof"
       (bytes "[12") '() (list AS (nm "12") NE (rej 'unexpected-eof 3)))
(case! 'number "RFC 8259 §6: an exponent ending the input inside an array"
       (bytes "[1.5e3") '() (list AS (nm "1.5e3") NE (rej 'unexpected-eof 6)))
(case! 'number "RFC 8259 §6: a number ending the input inside an object"
       (bytes "{\"a\":0") '() (list OS KS (ch "a") KE (nm "0") NE (rej 'unexpected-eof 6)))

;; ============ 6. Literals and structure (RFC 8259 §2, §3, §4, §5) =========

(case! 'structure "RFC 8259 §3: true" (bytes "true") '() (list 'true acc))
(case! 'structure "RFC 8259 §3: false" (bytes "false") '() (list 'false acc))
(case! 'structure "RFC 8259 §3: null" (bytes "null") '() (list 'null acc))
(for-each
 (lambda (word)
   (for-each
    (lambda (n)
      (let ((cut (substring word 0 n)))
        (case! 'structure (string-append "RFC 8259 §3: `" cut "`, " word " cut short, ends early at "
                                         (number->string n))
               (bytes cut) '() (list (rej 'unexpected-eof n)))))
    (cdr (iota (string-length word)))))
 '("true" "false" "null"))
(case! 'structure "RFC 8259 §3: `[tru]`: the `]` at 4"
       (bytes "[tru]") '() (list AS (rej 'unexpected-byte 4)))
(case! 'structure "RFC 8259 §3: `[fals]`: the `]` at 5"
       (bytes "[fals]") '() (list AS (rej 'unexpected-byte 5)))
(case! 'structure "RFC 8259 §3: `[nul]`: the `]` at 4"
       (bytes "[nul]") '() (list AS (rej 'unexpected-byte 4)))
(case! 'structure "RFC 8259 §3: literals are lower case: `trUe` at 2"
       (bytes "trUe") '() (list (rej 'unexpected-byte 2)))
(case! 'structure "RFC 8259 §3: literals are lower case: `True` at 0"
       (bytes "True") '() (list (rej 'unexpected-byte 0)))

;; Every kind of byte that may not follow a value: the wrong close, a colon,
;; the start of each kind of value, a letter, a NUL, a vertical tab and a
;; form feed (not JSON whitespace), DEL, and a byte no UTF-8 holds.
(define bad-after-value
  (list "}" "]" ":" "\"" "0" "-" "t" "[" "{" "x" 0 #x0B #x0C #x7F #xFF))
(define (byte-name b) (if (string? b) (string-append "`" b "`") (string-append "#x" (number->string b 16))))
(for-each
 (lambda (b)
   (unless (equal? b "]")
     (case! 'structure (string-append "RFC 8259 §5: " (byte-name b) " after an array member, at 5")
            (bytes "[null" b "]") '()
            (list AS 'null ctx-a (rej 'unexpected-byte 5))))
   (unless (equal? b "}")
     (case! 'structure (string-append "RFC 8259 §4: " (byte-name b) " after a member's value, at 9")
            (bytes "{\"k\":null" b "}") '()
            (list OS KS (ch "k") KE 'null ctx-o (rej 'unexpected-byte 9)))))
 bad-after-value)
(case! 'structure "RFC 8259 §5: a colon after whitespace after an array member, at 6"
       (bytes "[null :]") '() (list AS 'null ctx-a (rej 'unexpected-byte 6)))
(case! 'structure "ADR-0004: `[1}`: the wrong close, at 2"
       (bytes "[1}") '() (list AS (nm "1") NE ctx-a (rej 'unexpected-byte 2)))
(case! 'structure "ADR-0004: `{\"a\":1]`: the wrong close, at 6"
       (bytes "{\"a\":1]") '() (list OS KS (ch "a") KE (nm "1") NE ctx-o (rej 'unexpected-byte 6)))
(case! 'structure "RFC 8259 §5: `[,1]`: no value before a comma"
       (bytes "[,1]") '() (list AS (rej 'unexpected-byte 1)))
(case! 'structure "RFC 8259 §5: `[1,]`: a value after a comma"
       (bytes "[1,]") '() (list AS (nm "1") NE ctx-a (rej 'unexpected-byte 3)))
(case! 'structure "RFC 8259 §4: `{,}`: no member before a comma"
       (bytes "{,}") '() (list OS (rej 'unexpected-byte 1)))
(case! 'structure "RFC 8259 §4: `{1:1}`: a name is a string"
       (bytes "{1:1}") '() (list OS (rej 'unexpected-byte 1)))
(case! 'structure "RFC 8259 §4: `{\"a\"}`: a colon after a name"
       (bytes "{\"a\"}") '() (list OS KS (ch "a") KE (rej 'unexpected-byte 4)))
(case! 'structure "RFC 8259 §4: `{\"a\" 1}`: a colon after a name"
       (bytes "{\"a\" 1}") '() (list OS KS (ch "a") KE (rej 'unexpected-byte 5)))
(case! 'structure "RFC 8259 §4: `{\"a\":}`: a value after the colon"
       (bytes "{\"a\":}") '() (list OS KS (ch "a") KE (rej 'unexpected-byte 5)))
(case! 'structure "RFC 8259 §4: `{\"a\":1,}`: a member after a comma"
       (bytes "{\"a\":1,}") '() (list OS KS (ch "a") KE (nm "1") NE ctx-o (rej 'unexpected-byte 7)))
(case! 'structure "RFC 8259 §4: `{\"a\":1 \"b\":2}`: a comma between members"
       (bytes "{\"a\":1 \"b\":2}") '() (list OS KS (ch "a") KE (nm "1") NE ctx-o (rej 'unexpected-byte 7)))
(case! 'structure "RFC 8259 §2: a close is no value" (bytes "]") '() (list (rej 'unexpected-byte 0)))
(case! 'structure "RFC 8259 §2: a colon is no value" (bytes ":") '() (list (rej 'unexpected-byte 0)))
(case! 'structure "RFC 8259 §5: `[` alone ends early"
       (bytes "[") '() (list AS (rej 'unexpected-eof 1)))
(case! 'structure "RFC 8259 §4: `{` alone ends early"
       (bytes "{") '() (list OS (rej 'unexpected-eof 1)))
(case! 'structure "RFC 8259 §4: a name with no colon ends early"
       (bytes "{\"a\"") '() (list OS KS (ch "a") KE (rej 'unexpected-eof 4)))
(case! 'structure "RFC 8259 §4: a colon with no value ends early"
       (bytes "{\"a\":") '() (list OS KS (ch "a") KE (rej 'unexpected-eof 5)))
(case! 'structure "RFC 8259 §5: a member with no close ends early"
       (bytes "[true") '() (list AS 'true ctx-a (rej 'unexpected-eof 5)))
(case! 'structure "RFC 8259 §7: a string with no closing quote ends early"
       (bytes "\"abc") '() (list SS (ch "abc") (rej 'unexpected-eof 4)))
(case! 'structure "RFC 8259 §2: `[]x` is trailing-garbage at 2"
       (bytes "[]x") '() (list AS AE (rej 'trailing-garbage 2)))
(case! 'structure "RFC 8259 §2: `{} ]` is trailing-garbage at 3"
       (bytes "{} ]") '() (list OS OE (rej 'trailing-garbage 3)))
(case! 'structure "RFC 8259 §2: `\"a\"x` is trailing-garbage at 3"
       (bytes "\"a\"x") '() (list SS (ch "a") SE (rej 'trailing-garbage 3)))
(case! 'structure "RFC 8259 §2: `null null` is trailing-garbage at 5"
       (bytes "null null") '() (list 'null (rej 'trailing-garbage 5)))
(case! 'structure "RFC 8259 §2: the four whitespace bytes around and inside an array"
       (bytes " \t\r\n[ \t\r\n1 \t\r\n] \t\r\n") '()
       (list AS (nm "1") NE ctx-a AE acc))
(case! 'structure "RFC 8259 §2: a form feed is not whitespace"
       (bytes #x0C "1") '() (list (rej 'unexpected-byte 0)))
(case! 'structure "RFC 8259 §2: a vertical tab before a member is not whitespace, at 1"
       (bytes "[" #x0B "1]") '() (list AS (rej 'unexpected-byte 1)))
(case! 'structure "RFC 8259 §2: a no-break space, C2 A0, is not whitespace"
       (bytes #xC2 #xA0 "1") '() (list (rej 'unexpected-byte 0)))
(case! 'structure "RFC 8259 §8.1: a byte order mark is refused at 0"
       (bytes #xEF #xBB #xBF "{}") '() (list (rej 'unexpected-byte 0)))
(case! 'structure "RFC 8259 §2: empty input has no value"
       (bytes) '() (list (rej 'unexpected-eof 0)))
(case! 'structure "RFC 8259 §2: whitespace alone has no value"
       (bytes " \t\r\n") '() (list (rej 'unexpected-eof 4)))

(set! cases (reverse cases))

;; --- running a case -------------------------------------------------------

;; content : Compiled-Machine Schedule Fields -> Any
;; The run's trace-content, or (raised TEXT).
(define (content machine schedule fields)
  (guard (e (#t (list 'raised (describe e))))
    (trace-content (run-machine machine schedule fields))))

;; first-difference : List List -> (U 'same List)
;; 'same, or where EXPECTED and ACTUAL first part, for traces too long to
;; print whole.
(define (first-difference expected actual)
  (if (not (list? actual))
      (list 'not-a-trace actual)
      (let loop ((i 0) (e expected) (a actual))
        (cond ((and (null? e) (null? a)) 'same)
              ((or (null? e) (null? a) (not (equal? (car e) (car a))))
               (list 'differs-at i
                     'expected (if (null? e) 'end (car e))
                     'actual (if (null? a) 'end (car a))
                     'lengths (length expected) (length actual)))
              (else (loop (+ i 1) (cdr e) (cdr a)))))))

;; A case whose expected content is short is compared whole, and printed
;; whole when it fails; a long one by its first difference.
(define (check-case c)
  (let* ((bv (case-bytes c)) (fields (case-fields c)) (expected (case-expected c))
         (g (content generated-machine (whole-schedule bv) fields))
         (i (content interpreted-machine (whole-schedule bv) fields)))
    (if (> (length expected) 40)
        (test-equal (case-name c)
          '(generated same interpreted same)
          (list 'generated (first-difference expected g)
                'interpreted (first-difference expected i)))
        (test-equal (case-name c)
          expected
          (if (equal? g i) g (list 'machines-differ 'generated g 'interpreted i))))))

;; raised : (-> Any) -> Any
;; What THUNK raised: (contract WHO CODE DETAIL) for byte-machine's contract
;; condition, (other-raise TEXT) for anything else, and the symbol no-raise
;; if THUNK returned.
(define (raised thunk)
  (guard (e ((byte-machine-contract-condition? e)
             (list 'contract (byte-machine-contract-condition-who e)
                   (byte-machine-contract-condition-code e)
                   (byte-machine-contract-condition-detail e)))
            (#t (list 'other-raise (describe e))))
    (thunk)
    'no-raise))

(define (make-parser-with machine fields)
  (raised (lambda () (run-machine machine (whole-schedule (bytes "0")) fields))))

(define groups '(depth mode utf8 escape number structure))

(test-begin "machine")

(for-each (lambda (group)
            (for-each (lambda (c) (when (eq? (case-group c) group) (check-case c)))
                      cases)
            (when (eq? group 'depth)
              ;; ADR-0005: a limit out of range raises when the parser is made.
              ;; byte-machine refuses a settable field's value past its width,
              ;; and a field the machine does not declare.
              (for-each
               (lambda (machine label)
                 (test-equal (string-append "ADR-0005: make-parser on the " label
                                            " machine refuses depth-left 65536 and an unknown field, and takes 65535")
                   '((contract make-parser invalid-argument field-initial-out-of-range)
                     (contract make-parser invalid-argument unknown-field)
                     (contract make-parser invalid-argument non-settable-field)
                     no-raise)
                   (list (make-parser-with machine '((depth-left . 65536)))
                         (make-parser-with machine '((depth-limit . 3)))
                         (make-parser-with machine '((depth . 3)))
                         (make-parser-with machine '((depth-left . 65535))))))
               (list generated-machine interpreted-machine)
               '("generated" "interpreted"))))
          groups)

;; ============ 7. Schedules (ADR-0012 Decision 5) ==========================
;; Every case shorter than 64 bytes runs under every schedule schedules-for
;; returns: every split, every pair of splits, the whole, three with an empty
;; feed, a sub-slice, a padded buffer and four random multi-splits, drawn
;; from one prng threaded through the cases in order. The count is checked
;; against that list, so a schedule alphabet that went empty would fail.

(define schedule-limit 64)

;; schedules-expected : Nat -> Nat
;; L+1 splits, (L+1)(L+2)/2 pairs, and 1 + 3 + 1 + 1 + 4 others.
(define (schedules-expected len)
  (+ (+ len 1) (div (* (+ len 1) (+ len 2)) 2) 10))

(define (feeds-of schedule)
  (map (lambda (f) (list (cadr f) (caddr f) (bytevector-length (car f)))) schedule))

;; schedule-run : Case State -> (values Nat (Listof Failure) State)
;; How many schedules ran, the failures, and the prng state after.
(define (schedule-run c state)
  (let* ((bv (case-bytes c)) (fields (case-fields c))
         (one (content generated-machine (whole-schedule bv) fields)))
    (let-values (((schedules state) (schedules-for bv state)))
      (let loop ((ss schedules) (n 0) (failures '()))
        (if (null? ss)
            (values n (reverse failures) state)
            (let* ((s (car ss))
                   (g (guard (e (#t (list 'raised (describe e)))) (run-machine generated-machine s fields)))
                   (i (guard (e (#t (list 'raised (describe e)))) (run-machine interpreted-machine s fields)))
                   (gc (guard (e (#t (list 'raised (describe e)))) (trace-content g)))
                   (f1 (if (equal? gc one) '()
                           (list (list (case-name c) 'content-differs (feeds-of s) 'one-feed one 'this gc))))
                   (f2 (if (equal? g i) '()
                           (list (list (case-name c) 'machines-differ (feeds-of s))))))
              (loop (cdr ss) (+ n 1) (append (reverse f2) (reverse f1) failures))))))))

(define (take-up-to xs n)
  (if (or (null? xs) (= n 0)) '() (cons (car xs) (take-up-to (cdr xs) (- n 1)))))

(let loop ((gs groups) (state (make-prng 20261030)))
  (unless (null? gs)
    (let ((group (car gs)))
      (let case-loop ((cs (filter (lambda (c) (and (eq? (case-group c) group)
                                                    (< (bytevector-length (case-bytes c)) schedule-limit)))
                                  cases))
                      (state state) (ran 0) (expected 0) (failures '()))
        (if (null? cs)
            (begin
              (test-equal (string-append "ADR-0012: every " (symbol->string group)
                                         " case under 64 bytes, under every schedule: one-feed content, and the machines agree")
                (list 'schedules expected 'failures 0 '())
                (list 'schedules ran 'failures (length failures) (take-up-to failures 3)))
              (loop (cdr gs) state))
            (let-values (((n fs state) (schedule-run (car cs) state)))
              (case-loop (cdr cs) state (+ ran n)
                         (+ expected (schedules-expected (bytevector-length (case-bytes (car cs)))))
                         (append failures fs))))))))

(test-end "machine")

(exit (suite-exit-status runner))
