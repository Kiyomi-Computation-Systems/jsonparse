;;; tests/test-writer.sps: (jsonparse writer) and (jsonparse error), held to
;;; their header comments (ADR-0018) and the indent option of (jsonparse
;;; options).
;;;
;;; Every expected output is a string written by hand. An output is read back
;;; as a string with one character per byte, so a non-ASCII expectation is
;;; written as its UTF-8 bytes, one \x..; escape each. Exceptions, named where
;;; they occur: the digit-boundary table in section 3 was generated as source
;;; text; a few expectations are built with string-append, make-string and
;;; list joins from hand-written pieces.
;;;
;;; 1. Each kind of value. 2. Strings. 3. Numbers. 4. Hashtables. 5. Layout.
;;; 6. Refusals. 7. Nothing is written on a refusal. 8. The arguments.
;;; 9. The indent option. 10. &json-error on its own.
(import (rnrs)
        (rnrs mutable-pairs)
        (only (chezscheme) iota real-time)
        (srfi :64)
        (jsonparse-testing)
        (jsonparse error)
        (jsonparse options)
        (jsonparse string)
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
        (newline)
        ;; A runaway writer can abort the process: keep what is printed.
        (flush-output-port (current-output-port))))))

(define started (real-time))

(define-syntax chk
  (syntax-rules ()
    ((_ name expected expr) (test-equal name expected expr))))

;; --- helpers -----------------------------------------------------------------

;; bv->str : Bytevector -> String
;; One character per byte.
(define (bv->str bv) (list->string (map integer->char (bytevector->u8-list bv))))

;; w : Any Any ... -> String
;; The bytes (put-json port v (make-json-options opt ...)) writes.
(define (w v . opts)
  (let-values (((p extract) (open-bytevector-output-port)))
    (put-json p v (apply make-json-options opts))
    (bv->str (extract))))

;; w2 : Any -> String
;; The bytes the two-argument (put-json port v) writes.
(define (w2 v)
  (let-values (((p extract) (open-bytevector-output-port)))
    (put-json p v)
    (bv->str (extract))))

;; lines : String ... -> String
;; The lines joined by newlines, no newline at the end.
(define (lines . ls)
  (let loop ((ls (cdr ls)) (acc (car ls)))
    (if (null? ls) acc (loop (cdr ls) (string-append acc "\n" (car ls))))))

(define-record-type (thing make-thing thing?) (fields a))
(define-record-type (nothing make-nothing nothing?))

(define (make-table) (make-hashtable string-hash string=?))

;; table : (Listof (Pair String Any)) -> Hashtable
(define (table . entries)
  (let ((h (make-table)))
    (for-each (lambda (e) (hashtable-set! h (car e) (cdr e))) entries)
    h))

;; same? : Any Any -> Boolean
;; eqv?, or equal text for two strings (a key's text is not its identity).
(define (same? a b) (or (eqv? a b) (and (string? a) (string? b) (string=? a b))))

;; refusal : Any Any Any ... -> (List (U 'no-raise (List ...)) String)
;; Writes V under the options OPT ... to a port that already holds "pre".
;; Catches only a &json-error (and tags any other condition); answers what
;; it carried, with IRRITANT compared by eqv?, and what the port then holds.
(define (refusal irritant v . opts)
  (let ((options (apply make-json-options opts)))
    (let-values (((p extract) (open-bytevector-output-port)))
      (put-bytevector p (string->utf8 "pre"))
      (let ((r (guard (e ((json-error? e)
                          (let ((irr (if (irritants-condition? e) (condition-irritants e) '())))
                            (list 'refused
                                  (json-error-reason e)
                                  (json-error-offset e)
                                  (and (who-condition? e) (condition-who e))
                                  (and (message-condition? e) (condition-message e))
                                  (length irr)
                                  (and (pair? irr) (same? (car irr) irritant))
                                  (error? e)
                                  (violation? e))))
                         ((condition? e) (list 'other-raise)))
                 (put-json p v options)
                 'no-raise)))
        (list r (bv->str (extract)))))))

;; refused : Symbol String -> (List ...)
;; What `refusal` answers for a refusal with this reason and message.
(define (refused reason message)
  (list (list 'refused reason #f 'put-json message 1 #t #t #f) "pre"))

(define m-num "a number JSON can't express")
(define m-key "an object's key is not a string")
(define m-val "a value JSON can't express")
(define m-list "a list that is not an alist: it is improper or circular")
(define m-member "a list that is not an alist: a member is not a pair")
(define m-deep "more arrays and objects open at once than depth-limit")

;; violation-of : (-> Any) -> (U 'no-raise (List ...))
;; What an assertion violation carried; catches only that.
(define (violation-of thunk irritant)
  (guard (e ((assertion-violation? e)
             (let ((irr (if (irritants-condition? e) (condition-irritants e) '())))
               (list 'violation
                     (json-error? e)
                     (and (who-condition? e) (condition-who e))
                     (and (message-condition? e) (condition-message e))
                     (length irr)
                     (and (pair? irr) (eqv? (car irr) irritant)))))
            ((condition? e) (list 'other-raise)))
    (thunk)
    'no-raise))

;; Nested containers: WRAP-x K INNER is INNER inside K containers.
(define (wrap-vec k inner) (if (= k 0) inner (vector (wrap-vec (- k 1) inner))))
(define (wrap-alist k inner)
  (if (= k 0) inner (list (cons "k" (wrap-alist (- k 1) inner)))))
(define (wrap-table k inner)
  (if (= k 0) inner (table (cons "k" (wrap-table (- k 1) inner)))))
;; wrap-mix : (Listof (U 'vec 'alist 'table)) Any -> Any   outermost first
(define (wrap-mix kinds inner)
  (if (null? kinds)
      inner
      (let ((x (wrap-mix (cdr kinds) inner)))
        (case (car kinds)
          ((vec) (vector x))
          ((alist) (list (cons "k" x)))
          (else (table (cons "k" x)))))))

(define (fresh-vec) (vector))
(define (fresh-alist) (list (cons "z" 1)))
(define (fresh-table) (table (cons "z" 1)))

;; options-row : json-options -> (List ...)
(define (options-row o)
  (list (json-options-depth-limit o) (json-options-number-mode o)
        (json-options-digit-limit o) (json-options-object-mode o)
        (json-options-null o) (json-options-indent o)))

;; ============================================================================
(test-begin "writer")

;; --- 1. Each kind of value ---------------------------------------------------

(chk "empty alist" "{}" (w '()))
(chk "empty vector" "[]" (w (vector)))
(chk "null" "null" (w 'null))
(chk "true" "true" (w #t))
(chk "false" "false" (w #f))
(chk "alist" "{\"a\":1,\"b\":\"x\"}" (w '(("a" . 1) ("b" . "x"))))
(chk "alist duplicates in order" "{\"b\":1,\"a\":2,\"b\":3,\"a\":4,\"b\":5}"
  (w '(("b" . 1) ("a" . 2) ("b" . 3) ("a" . 4) ("b" . 5))))
(chk "vector" "[1,true,false,null,\"s\"]" (w (vector 1 #t #f 'null "s")))
(chk "nested containers"
  "{\"a\":[1,{\"b\":[[],{}]},[null]],\"c\":{\"d\":{\"e\":[]}}}"
  (w (list (cons "a" (vector 1 (list (cons "b" (vector (vector) '()))) (vector 'null)))
           (cons "c" (list (cons "d" (list (cons "e" (vector)))))))))
(chk "vector of scalars and empties" "[[],{},0,\"\"]" (w (vector (vector) '() 0 "")))
(chk "json-number exact text" "1.50e+3" (w (make-json-number "1.50e+3")))
(chk "json-number negative zero" "-0" (w (make-json-number "-0")))
(chk "json-number long" "123456789012345678901234567890.5E-7"
  (w (make-json-number "123456789012345678901234567890.5E-7")))
(chk "json-numbers in a vector" "[1e5,-0.0,7]"
  (w (vector (make-json-number "1e5") (make-json-number "-0.0") (make-json-number "7"))))
(chk "json-number as a member" "{\"n\":10.00}" (w (list (cons "n" (make-json-number "10.00")))))

(chk "null symbol nil" "null" (w 'nil 'null 'nil))
(chk "null symbol nil in a vector" "[null,null]" (w (vector 'nil 'nil) 'null 'nil))
(chk "null symbol nil as a member" "{\"a\":null}" (w (list (cons "a" 'nil)) 'null 'nil))
(let ((nul (make-nothing)))
  (chk "null record" "null" (w nul 'null nul))
  (chk "null record in a vector" "[null,1]" (w (vector nul 1) 'null nul))
  (chk "null record as a member" "{\"a\":null}" (w (list (cons "a" nul)) 'null nul))
  (chk "default null refused as a record" (refused 'unwritable-value m-val)
    (refusal nul nul))
  (chk "symbol null refused when the null is a record"
    (refused 'unwritable-value m-val) (refusal 'null 'null 'null nul))
  (chk "another record refused when the null is a record"
    (refused 'unwritable-value m-val)
    (let ((t (make-thing 1))) (refusal t t 'null nul))))
(chk "symbol null refused when the null is nil" (refused 'unwritable-value m-val)
  (refusal 'null 'null 'null 'nil))
(chk "symbol null refused inside a vector when the null is nil"
  (refused 'unwritable-value m-val) (refusal 'null (vector 1 'null) 'null 'nil))
(chk "nil refused under the default null" (refused 'unwritable-value m-val)
  (refusal 'nil 'nil))

;; The reader's options do not change what is written.
(chk "number-mode text ignored" "[12345,1.5]" (w (vector 12345 1.5) 'number-mode 'text))
(chk "digit-limit ignored" "12345" (w 12345 'digit-limit 1))
(chk "object-mode hashtable on an alist" "{\"a\":1}" (w '(("a" . 1)) 'object-mode 'hashtable))
(chk "object-mode alist on a hashtable" "{\"a\":1}"
  (w (table (cons "a" 1)) 'object-mode 'alist))

;; --- 2. Strings --------------------------------------------------------------

(define control-escapes
  (vector "\\u0000" "\\u0001" "\\u0002" "\\u0003" "\\u0004" "\\u0005" "\\u0006" "\\u0007"
          "\\b" "\\t" "\\n" "\\u000b" "\\f" "\\r" "\\u000e" "\\u000f"
          "\\u0010" "\\u0011" "\\u0012" "\\u0013" "\\u0014" "\\u0015" "\\u0016" "\\u0017"
          "\\u0018" "\\u0019" "\\u001a" "\\u001b" "\\u001c" "\\u001d" "\\u001e" "\\u001f"))

(let loop ((i 0))
  (when (< i 32)
    (chk (string-append "control character " (number->string i))
      (string-append "\"" (vector-ref control-escapes i) "\"")
      (w (string (integer->char i))))
    (chk (string-append "control character " (number->string i) " as a key")
      (string-append "{\"" (vector-ref control-escapes i) "\":0}")
      (w (list (cons (string (integer->char i)) 0))))
    (loop (+ i 1))))

(chk "quote" "\"\\\"\"" (w "\""))
(chk "backslash" "\"\\\\\"" (w "\\"))
(chk "empty string" "\"\"" (w ""))
(chk "space as itself" "\" \"" (w " "))
(chk "slash as itself" "\"/\"" (w "/"))
(chk "U+007F as itself" "\"\x7F;\"" (w (string (integer->char #x7F))))
(chk "U+0080" "\"\xC2;\x80;\"" (w (string (integer->char #x80))))
(chk "U+07FF" "\"\xDF;\xBF;\"" (w (string (integer->char #x7FF))))
(chk "U+0800" "\"\xE0;\xA0;\x80;\"" (w (string (integer->char #x800))))
(chk "U+FFFF" "\"\xEF;\xBF;\xBF;\"" (w (string (integer->char #xFFFF))))
(chk "U+10000" "\"\xF0;\x90;\x80;\x80;\"" (w (string (integer->char #x10000))))
(chk "U+10FFFF" "\"\xF4;\x8F;\xBF;\xBF;\"" (w (string (integer->char #x10FFFF))))
(chk "U+2028 as itself" "\"\xE2;\x80;\xA8;\"" (w (string (integer->char #x2028))))
(chk "U+2029 as itself" "\"\xE2;\x80;\xA9;\"" (w (string (integer->char #x2029))))
(chk "all escapes" "\"\\\"\\\\\\n\\t\\u0000\\\\\\\"\"" (w "\"\\\n\t\x0;\\\""))
(chk "escape at the start" "\"\\\"abc\"" (w "\"abc"))
(chk "escape in the middle" "\"ab\\ncd\"" (w "ab\ncd"))
(chk "escape at the end" "\"abc\\\\\"" (w "abc\\"))
(chk "escapes at both ends" "\"\\tab\\u0001\"" (w "\tab\x1;"))
(chk "two escapes in a row between runs" "\"a\\\"\\\"b\"" (w "a\"\"b"))
(chk "non-ASCII around escapes" "\"\xC3;\xA9;\\\"\xC3;\xA9;\\n\"" (w "\xE9;\"\xE9;\n"))
(chk "plain text with a mix of widths"
  "\"a\xC3;\xA9;\xE4;\xB8;\xAD;\xF0;\x90;\x80;\x80;z\""
  (w "a\xE9;\x4E2D;\x10000;z"))
(chk "keys escaped" "{\"a\\\"b\\\\c\\n\":1,\"\\u0001\":2,\"\xC3;\xA9;\":3}"
  (w (list (cons "a\"b\\c\n" 1) (cons "\x1;" 2) (cons "\xE9;" 3))))
(chk "empty key" "{\"\":1}" (w (list (cons "" 1))))
(chk "string values escaped in an object" "{\"k\":\"\\\"v\\\"\"}"
  (w (list (cons "k" "\"v\""))))

;; --- 3. Numbers --------------------------------------------------------------

(chk "zero" "0" (w 0))
(chk "one" "1" (w 1))
(chk "minus one" "-1" (w -1))
(chk "greatest fixnum" "1152921504606846975" (w (greatest-fixnum)))
(chk "least fixnum" "-1152921504606846976" (w (least-fixnum)))
(chk "greatest fixnum plus one" "1152921504606846976" (w (+ (greatest-fixnum) 1)))
(chk "least fixnum minus one" "-1152921504606846977" (w (- (least-fixnum) 1)))
(chk "least fixnum plus one" "-1152921504606846975" (w (+ (least-fixnum) 1)))
(chk "greatest fixnum minus one" "1152921504606846974" (w (- (greatest-fixnum) 1)))
(chk "bignum" "123456789012345678901234567890" (w 123456789012345678901234567890))
(chk "negative bignum" "-123456789012345678901234567890" (w -123456789012345678901234567890))
(chk "two to the 64" "18446744073709551616" (w 18446744073709551616))
(chk "digits at every position" "1234567890" (w 1234567890))
(chk "digits at every position, negative" "-9876543210" (w -9876543210))
(chk "a fixnum in a vector" "[-5,0,5]" (w (vector -5 0 5)))
(chk "a fixnum as a member" "{\"n\":-70}" (w (list (cons "n" -70))))

(for-each
 (lambda (p)
   (chk (string-append "integer " (cdr p)) (cdr p) (w (car p))))
 '(
    (10 . "10") (-10 . "-10")
    (9 . "9") (-9 . "-9")
    (100 . "100") (-100 . "-100")
    (99 . "99") (-99 . "-99")
    (1000 . "1000") (-1000 . "-1000")
    (999 . "999") (-999 . "-999")
    (10000 . "10000") (-10000 . "-10000")
    (9999 . "9999") (-9999 . "-9999")
    (100000 . "100000") (-100000 . "-100000")
    (99999 . "99999") (-99999 . "-99999")
    (1000000 . "1000000") (-1000000 . "-1000000")
    (999999 . "999999") (-999999 . "-999999")
    (10000000 . "10000000") (-10000000 . "-10000000")
    (9999999 . "9999999") (-9999999 . "-9999999")
    (100000000 . "100000000") (-100000000 . "-100000000")
    (99999999 . "99999999") (-99999999 . "-99999999")
    (1000000000 . "1000000000") (-1000000000 . "-1000000000")
    (999999999 . "999999999") (-999999999 . "-999999999")
    (10000000000 . "10000000000") (-10000000000 . "-10000000000")
    (9999999999 . "9999999999") (-9999999999 . "-9999999999")
    (100000000000 . "100000000000") (-100000000000 . "-100000000000")
    (99999999999 . "99999999999") (-99999999999 . "-99999999999")
    (1000000000000 . "1000000000000") (-1000000000000 . "-1000000000000")
    (999999999999 . "999999999999") (-999999999999 . "-999999999999")
    (10000000000000 . "10000000000000") (-10000000000000 . "-10000000000000")
    (9999999999999 . "9999999999999") (-9999999999999 . "-9999999999999")
    (100000000000000 . "100000000000000") (-100000000000000 . "-100000000000000")
    (99999999999999 . "99999999999999") (-99999999999999 . "-99999999999999")
    (1000000000000000 . "1000000000000000") (-1000000000000000 . "-1000000000000000")
    (999999999999999 . "999999999999999") (-999999999999999 . "-999999999999999")
    (10000000000000000 . "10000000000000000") (-10000000000000000 . "-10000000000000000")
    (9999999999999999 . "9999999999999999") (-9999999999999999 . "-9999999999999999")
    (100000000000000000 . "100000000000000000") (-100000000000000000 . "-100000000000000000")
    (99999999999999999 . "99999999999999999") (-99999999999999999 . "-99999999999999999")
    (1000000000000000000 . "1000000000000000000") (-1000000000000000000 . "-1000000000000000000")
    (999999999999999999 . "999999999999999999") (-999999999999999999 . "-999999999999999999")
    (10000000000000000000 . "10000000000000000000") (-10000000000000000000 . "-10000000000000000000")
    (9999999999999999999 . "9999999999999999999") (-9999999999999999999 . "-9999999999999999999")
    (100000000000000000000 . "100000000000000000000") (-100000000000000000000 . "-100000000000000000000")
    (99999999999999999999 . "99999999999999999999") (-99999999999999999999 . "-99999999999999999999")
    (1000000000000000000000 . "1000000000000000000000") (-1000000000000000000000 . "-1000000000000000000000")
    (999999999999999999999 . "999999999999999999999") (-999999999999999999999 . "-999999999999999999999")
    (10000000000000000000000 . "10000000000000000000000") (-10000000000000000000000 . "-10000000000000000000000")
    (9999999999999999999999 . "9999999999999999999999") (-9999999999999999999999 . "-9999999999999999999999")
   ))

;; 10^22 and 10^22 - 1 are past the fixnum range.
(chk "two fixnums back to back" "[1000,-1000]" (w (vector 1000 -1000)))

(chk "0.0" "0.0" (w 0.0))
(chk "-0.0" "-0.0" (w -0.0))
(chk "1.5" "1.5" (w 1.5))
(chk "-1.5" "-1.5" (w -1.5))
(chk "100.0" "100.0" (w 100.0))
(chk "1e21" "1e21" (w 1e21))
(chk "1e-7" "1e-7" (w 1e-7))
(chk "1e22" "1e22" (w 1e22))
(chk "largest flonum" "1.7976931348623157e308" (w 1.7976931348623157e308))
(chk "most negative flonum" "-1.7976931348623157e308" (w -1.7976931348623157e308))
(chk "smallest subnormal" "5e-324" (w 5e-324))
(chk "another subnormal" "1e-310" (w 1e-310))
(chk "negative subnormal" "-5e-324" (w -5e-324))
(chk "flonums in a vector" "[5e-324,1.5]" (w (vector 5e-324 1.5)))
(chk "a flonum member" "{\"x\":1e-310}" (w (list (cons "x" 1e-310))))

(chk "1/2" "0.5" (w 1/2))
(chk "-1/2" "-0.5" (w -1/2))
(chk "-1/8" "-0.125" (w -1/8))
(chk "1/1024" "0.0009765625" (w 1/1024))
(chk "-1/1024" "-0.0009765625" (w -1/1024))
(chk "3/1250" "0.0024" (w 3/1250))
(chk "1/2^40" "0.0000000000009094947017729282379150390625" (w (/ 1 (expt 2 40))))
(chk "-1/2^40" "-0.0000000000009094947017729282379150390625" (w (/ -1 (expt 2 40))))
(chk "1/5" "0.2" (w 1/5))
(chk "1/25" "0.04" (w 1/25))
(chk "1/125" "0.008" (w 1/125))
(chk "1/625" "0.0016" (w 1/625))
(chk "-1/5^20" "-0.00000000000001048576" (w (/ -1 (expt 5 20))))
(chk "1/10" "0.1" (w 1/10))
(chk "1/100" "0.01" (w 1/100))
(chk "7/1000" "0.007" (w 7/1000))
(chk "-3/100000" "-0.00003" (w -3/100000))
(chk "123/1000" "0.123" (w 123/1000))
(chk "5/4" "1.25" (w 5/4))
(chk "-7/2" "-3.5" (w -7/2))
(chk "7/40" "0.175" (w 7/40))
(chk "12345/100" "123.45" (w 12345/100))
(chk "-12345/100" "-123.45" (w -12345/100))
(chk "1/20" "0.05" (w 1/20))
(chk "1/10^12" "0.000000000001" (w (/ 1 (expt 10 12))))
(chk "-1/10^12" "-0.000000000001" (w (/ -1 (expt 10 12))))
(chk "10^12 + 1 over 10^12" "1.000000000001" (w (/ (+ (expt 10 12) 1) (expt 10 12))))
(chk "1/5^7" "0.0000128" (w (/ 1 (* 625 125))))
(chk "fractions in a vector" "[0.5,-0.25]" (w (vector 1/2 -1/4)))
(chk "a fraction as a member" "{\"f\":-0.001}" (w (list (cons "f" -1/1000))))

;; --- 4. Hashtables -----------------------------------------------------------

(chk "empty hashtable" "{}" (w (make-table)))
(chk "empty hashtable under object-mode hashtable" "{}"
  (w (make-table) 'object-mode 'hashtable))
(chk "hashtable one member" "{\"a\":1}" (w (table (cons "a" 1))))
(chk "hashtable sorted, capitals first" "{\"A\":1,\"B\":2,\"a\":3,\"b\":4}"
  (w (table (cons "b" 4) (cons "a" 3) (cons "B" 2) (cons "A" 1))))
(chk "B before a" "{\"B\":1,\"a\":2}" (w (table (cons "a" 2) (cons "B" 1))))
(chk "B before a, other insertion order" "{\"B\":1,\"a\":2}"
  (w (table (cons "B" 1) (cons "a" 2))))
(chk "eight keys" "{\"A\":0,\"B\":1,\"C\":2,\"a\":3,\"b\":4,\"c\":5,\"d\":6,\"e\":7}"
  (w (table (cons "e" 7) (cons "c" 5) (cons "A" 0) (cons "d" 6)
            (cons "a" 3) (cons "C" 2) (cons "b" 4) (cons "B" 1))))
(chk "keys by code point, not by length or case"
  "{\"\":0,\"Z\":1,\"a\":2,\"aa\":3,\"b\":4}"
  (w (table (cons "b" 4) (cons "aa" 3) (cons "" 0) (cons "a" 2) (cons "Z" 1))))
(chk "non-ASCII keys by code point"
  (string-append "{\"z\":1,\"\xC3;\xA9;\":2,\"\xE4;\xB8;\xAD;\":3,"
                 "\"\xEF;\xBD;\x9E;\":4,\"\xF0;\x90;\x80;\x80;\":5}")
  (w (table (cons "\x10000;" 5) (cons "\xFF5E;" 4) (cons "\xE9;" 2)
            (cons "z" 1) (cons "\x4E2D;" 3))))
(chk "hashtable under object-mode alist" "{\"a\":1,\"b\":2}"
  (w (table (cons "b" 2) (cons "a" 1)) 'object-mode 'alist))
(chk "hashtable under object-mode hashtable" "{\"a\":1,\"b\":2}"
  (w (table (cons "b" 2) (cons "a" 1)) 'object-mode 'hashtable))
(chk "hashtable keys escaped" "{\"\\n\":1,\"\\\"\":2}"
  (w (table (cons "\"" 2) (cons "\n" 1))))
(chk "hashtable nested in a vector and an alist"
  "[{\"a\":{\"x\":1,\"y\":2}}]"
  (w (vector (list (cons "a" (table (cons "y" 2) (cons "x" 1)))))))
(chk "hashtable with a vector value" "{\"a\":[1,{\"b\":2}]}"
  (w (table (cons "a" (vector 1 (table (cons "b" 2)))))))
(chk "immutable hashtable" "{\"a\":1,\"b\":2}"
  (w (hashtable-copy (table (cons "b" 2) (cons "a" 1)) #f)))
(chk "equal-hashtable" "{\"a\":1,\"b\":2}"
  (let ((h (make-hashtable equal-hash equal?))) (hashtable-set! h "b" 2) (hashtable-set! h "a" 1) (w h)))

;; --- 5. Layout ---------------------------------------------------------------

(define layout-value
  (list (cons "a" (vector 1 2 (list (cons "b" (vector)))))
        (cons "c" '())
        (cons "d" "x")))

(chk "compact three levels" "{\"a\":[1,2,{\"b\":[]}],\"c\":{},\"d\":\"x\"}"
  (w layout-value 'indent 0))
(chk "indent 1"
  (lines "{"
         " \"a\": ["
         "  1,"
         "  2,"
         "  {"
         "   \"b\": []"
         "  }"
         " ],"
         " \"c\": {},"
         " \"d\": \"x\""
         "}")
  (w layout-value 'indent 1))
(chk "indent 2"
  (lines "{"
         "  \"a\": ["
         "    1,"
         "    2,"
         "    {"
         "      \"b\": []"
         "    }"
         "  ],"
         "  \"c\": {},"
         "  \"d\": \"x\""
         "}")
  (w layout-value 'indent 2))
(chk "indent 4"
  (lines "{"
         "    \"a\": ["
         "        1,"
         "        2,"
         "        {"
         "            \"b\": []"
         "        }"
         "    ],"
         "    \"c\": {},"
         "    \"d\": \"x\""
         "}")
  (w layout-value 'indent 4))
(chk "indent 3 with a vector at the top"
  (lines "["
         "   [],"
         "   {},"
         "   {"
         "      \"k\": ["
         "         null"
         "      ]"
         "   }"
         "]")
  (w (vector (vector) '() (list (cons "k" (vector 'null)))) 'indent 3))
(chk "compact vector at the top" "[[],{},{\"k\":[null]}]"
  (w (vector (vector) '() (list (cons "k" (vector 'null))))))
(chk "indent 2, a hashtable" (lines "{" "  \"a\": 1," "  \"b\": {" "    \"c\": 2" "  }" "}")
  (w (table (cons "b" (table (cons "c" 2))) (cons "a" 1)) 'indent 2))
(chk "indent 2, empty containers stay" "[]" (w (vector) 'indent 2))
(chk "indent 2, empty alist stays" "{}" (w '() 'indent 2))
(chk "indent 2, empty hashtable stays" "{}" (w (make-table) 'indent 2))
(chk "indent 2, empty containers as members"
  (lines "[" "  []," "  {}," "  {}" "]")
  (w (vector (vector) '() (make-table)) 'indent 2))
(chk "indent 2, one member" (lines "{" "  \"a\": 1" "}") (w '(("a" . 1)) 'indent 2))
(chk "indent 2, one element" (lines "[" "  1" "]") (w (vector 1) 'indent 2))
(chk "indent 2, a colon followed by a space inside a nested member"
  (lines "{" "  \"a\": {" "    \"b\": 1" "  }" "}")
  (w '(("a" . (("b" . 1)))) 'indent 2))
(chk "compact object, no space after the colon" "{\"a\":1,\"b\":[2,3]}"
  (w '(("a" . 1) ("b" . #(2 3)))))
(chk "indent 0 given, no spaces" "{\"a\":1,\"b\":[2,3]}"
  (w '(("a" . 1) ("b" . #(2 3))) 'indent 0))
(chk "indent 2, no trailing newline" "[\n  1\n]" (w (vector 1) 'indent 2))
(chk "indent 10"
  (string-append "[\n" (make-string 10 #\space) "1\n]")
  (w (vector 1) 'indent 10))
(chk "indent 2, spaces inside strings are not touched"
  (lines "[" "  \"a  b\"" "]") (w (vector "a  b") 'indent 2))
(chk "indent 2, key then string value"
  (lines "{" "  \"k\": \"v\"" "}") (w '(("k" . "v")) 'indent 2))

(for-each
 (lambda (indent)
   (let ((n (number->string indent)))
     (chk (string-append "scalar string at indent " n) "\"s\"" (w "s" 'indent indent))
     (chk (string-append "scalar number at indent " n) "-12" (w -12 'indent indent))
     (chk (string-append "scalar flonum at indent " n) "1.5" (w 1.5 'indent indent))
     (chk (string-append "scalar true at indent " n) "true" (w #t 'indent indent))
     (chk (string-append "scalar false at indent " n) "false" (w #f 'indent indent))
     (chk (string-append "scalar null at indent " n) "null" (w 'null 'indent indent))
     (chk (string-append "scalar json-number at indent " n) "1e5"
       (w (make-json-number "1e5") 'indent indent))))
 '(0 1 2 4 7))

;; --- 6. Refusals -------------------------------------------------------------

(for-each
 (lambda (x)
   (chk (string-append "unwritable number " (number->string x))
     (refused 'unwritable-number m-num) (refusal x x))
   (chk (string-append "unwritable number " (number->string x) " in a vector")
     (refused 'unwritable-number m-num) (refusal x (vector 1 x 2)))
   (chk (string-append "unwritable number " (number->string x) " as a member")
     (refused 'unwritable-number m-num) (refusal x (list (cons "a" x)))))
 (list +nan.0 +inf.0 -inf.0 1/3 -1/3 1/6 2/7 1/15 1/12 1/7 (/ 1 (* 5 7))
       (/ 1 (+ (expt 2 40) 1)) 1+2i 1.0+2.0i))

(chk "unwritable key, symbol" (refused 'unwritable-key m-key)
  (refusal 'a '((a . 1))))
(chk "unwritable key, symbol after a good member" (refused 'unwritable-key m-key)
  (refusal 'b '(("a" . 1) (b . 2))))
(chk "unwritable key, number" (refused 'unwritable-key m-key) (refusal 1 '((1 . 2))))
(chk "unwritable key, #f" (refused 'unwritable-key m-key) (refusal #f '((#f . 2))))
(chk "unwritable key, in a nested alist" (refused 'unwritable-key m-key)
  (refusal 'k (vector (list (cons "a" (list (cons 'k 1)))))))
(chk "unwritable key, hashtable with a symbol key" (refused 'unwritable-key m-key)
  (let ((h (make-eqv-hashtable))) (hashtable-set! h 'a 1) (refusal 'a h)))
(chk "unwritable key, hashtable with a number key" (refused 'unwritable-key m-key)
  (let ((h (make-eqv-hashtable))) (hashtable-set! h 7 1) (refusal 7 h)))
(chk "unwritable key, hashtable with a #f key" (refused 'unwritable-key m-key)
  (let ((h (make-eqv-hashtable))) (hashtable-set! h #f 1) (refusal #f h)))
(chk "unwritable key, hashtable with a non-string key under object-mode hashtable"
  (refused 'unwritable-key m-key)
  (let ((h (make-eqv-hashtable))) (hashtable-set! h 'a 1) (refusal 'a h 'object-mode 'hashtable)))

(chk "unwritable value, a symbol" (refused 'unwritable-value m-val) (refusal 'foo 'foo))
(chk "unwritable value, a symbol in a vector" (refused 'unwritable-value m-val)
  (refusal 'foo (vector 1 'foo)))
(chk "unwritable value, a symbol as a member" (refused 'unwritable-value m-val)
  (refusal 'foo (list (cons "a" 'foo))))
(chk "unwritable value, a character" (refused 'unwritable-value m-val) (refusal #\a #\a))
(chk "unwritable value, a bytevector" (refused 'unwritable-value m-val)
  (let ((b (u8-list->bytevector (list 1 2)))) (refusal b b)))
(chk "unwritable value, a procedure" (refused 'unwritable-value m-val) (refusal car car))
(chk "unwritable value, a record" (refused 'unwritable-value m-val)
  (let ((t (make-thing 1))) (refusal t t)))
(chk "unwritable value, a record in a vector" (refused 'unwritable-value m-val)
  (let ((t (make-thing 1))) (refusal t (vector t))))
(chk "unwritable value, an eof object" (refused 'unwritable-value m-val)
  (let ((e (eof-object))) (refusal e e)))
(chk "unwritable value, a record other than the null" (refused 'unwritable-value m-val)
  (let ((t (make-thing 1)) (nul (make-nothing))) (refusal t (vector nul t) 'null nul)))
(chk "unwritable value, a list of numbers" (refused 'unwritable-value m-member)
  (refusal 1 '(1 2)))
(chk "unwritable value, a member that is not a pair, after a good one"
  (refused 'unwritable-value m-member) (refusal 5 '(("a" . 1) 5)))
(chk "unwritable value, a member that is a vector" (refused 'unwritable-value m-member)
  (let ((m (vector 1))) (refusal m (list m))))
(chk "unwritable value, an improper alist" (refused 'unwritable-value m-list)
  (let ((l (cons (cons "a" 1) 5))) (refusal l l)))
(chk "unwritable value, an improper alist in a vector" (refused 'unwritable-value m-list)
  (let ((l (cons (cons "a" 1) 'x))) (refusal l (vector l))))
(chk "unwritable value, a circular alist" (refused 'unwritable-value m-list)
  (let ((l (list (cons "a" 1)))) (set-cdr! l l) (refusal l l)))
(chk "unwritable value, a circular alist of two" (refused 'unwritable-value m-list)
  (let ((l (list (cons "a" 1) (cons "b" 2)))) (set-cdr! (cdr l) l) (refusal l (vector l))))

(define m-dup "a hashtable holds two keys with the same text")
(define (dup-table make . keys)
  (let ((h (make)))
    (let loop ((ks keys) (i 1))
      (unless (null? ks)
        (hashtable-set! h (string-copy (car ks)) i)
        (loop (cdr ks) (+ i 1))))
    h))

(chk "duplicate text, eq table" (refused 'unwritable-key m-dup)
  (refusal "a" (dup-table make-eq-hashtable "a" "a")))
(chk "duplicate text, eqv table" (refused 'unwritable-key m-dup)
  (refusal "a" (dup-table make-eqv-hashtable "a" "a")))
(chk "duplicate text, eq table under object-mode hashtable" (refused 'unwritable-key m-dup)
  (refusal "a" (dup-table make-eq-hashtable "a" "a") 'object-mode 'hashtable))
(chk "duplicate text, at the end of several keys" (refused 'unwritable-key m-dup)
  (refusal "c" (dup-table make-eq-hashtable "a" "b" "c" "c")))
(chk "duplicate text, at the start of several keys" (refused 'unwritable-key m-dup)
  (refusal "a" (dup-table make-eq-hashtable "a" "a" "b" "c")))
(chk "duplicate text in the middle of four keys" (refused 'unwritable-key m-dup)
  (refusal "b" (dup-table make-eq-hashtable "a" "b" "b" "c")))
(chk "three keys with the same text among others" (refused 'unwritable-key m-dup)
  (refusal "b" (dup-table make-eq-hashtable "a" "b" "b" "b" "c")))
(chk "duplicate text nested in a vector and an alist" (refused 'unwritable-key m-dup)
  (refusal "x" (vector 1 (list (cons "k" (dup-table make-eq-hashtable "x" "y" "x"))))))
(chk "duplicate text in a laid-out value" (refused 'unwritable-key m-dup)
  (refusal "x" (vector (dup-table make-eqv-hashtable "x" "x")) 'indent 2))
(chk "eq table, distinct texts, written in key order" "{\"a\":2,\"b\":1,\"c\":3}"
  (w (dup-table make-eq-hashtable "b" "a" "c")))
(chk "eq table, texts differing only in case, written" "{\"A\":2,\"a\":1}"
  (w (dup-table make-eq-hashtable "a" "A")))
(chk "eqv table, distinct texts, written in key order" "{\"x\":3,\"y\":1,\"z\":2}"
  (w (dup-table make-eqv-hashtable "y" "z" "x")))

;; Depth. Limit 3: nesting 2 and 3 are written, 4 is refused.
(define (depth-cases name wrap leaf ok2 ok3 fresh)
  (chk (string-append name " depth 2, limit minus 1") ok2
    (w (wrap 1 (leaf)) 'depth-limit 3))
  (chk (string-append name " depth 3, at the limit") ok3
    (w (wrap 2 (leaf)) 'depth-limit 3))
  (chk (string-append name " depth 4, one past the limit") (refused 'nesting-too-deep m-deep)
    (let ((bad (fresh))) (refusal bad (wrap 3 bad) 'depth-limit 3))))

(depth-cases "vector" wrap-vec (lambda () (vector)) "[[]]" "[[[]]]" fresh-vec)
(depth-cases "alist" wrap-alist (lambda () '()) "{\"k\":{}}" "{\"k\":{\"k\":{}}}" fresh-alist)
(depth-cases "hashtable" wrap-table make-table "{\"k\":{}}" "{\"k\":{\"k\":{}}}" fresh-table)

(chk "mix depth 3 of 4" "[{\"k\":{}}]"
  (w (wrap-mix '(vec alist) (make-table)) 'depth-limit 4))
(chk "mix depth 4 of 4" "[{\"k\":{\"k\":[]}}]"
  (w (wrap-mix '(vec alist table) (vector)) 'depth-limit 4))
(chk "mix depth 5 of 4, hashtable innermost" (refused 'nesting-too-deep m-deep)
  (let ((bad (fresh-table))) (refusal bad (wrap-mix '(vec alist table vec) bad) 'depth-limit 4)))
(chk "mix depth 5 of 4, vector innermost" (refused 'nesting-too-deep m-deep)
  (let ((bad (fresh-vec))) (refusal bad (wrap-mix '(table vec alist table) bad) 'depth-limit 4)))
(chk "mix depth 5 of 4, alist innermost" (refused 'nesting-too-deep m-deep)
  (let ((bad (fresh-alist))) (refusal bad (wrap-mix '(alist table vec alist) bad) 'depth-limit 4)))
(chk "mix depth 4 of 4, hashtable innermost" "{\"k\":[{\"k\":{}}]}"
  (w (wrap-mix '(alist vec alist) (make-table)) 'depth-limit 4))
(chk "mix depth 4 of 4, written as a table first" "{\"k\":[{\"k\":[]}]}"
  (w (wrap-mix '(table vec alist) (vector)) 'depth-limit 4))

(chk "depth-limit 0 writes a string" "\"s\"" (w "s" 'depth-limit 0))
(chk "depth-limit 0 writes a number" "12" (w 12 'depth-limit 0))
(chk "depth-limit 0 writes a flonum" "1.5" (w 1.5 'depth-limit 0))
(chk "depth-limit 0 writes true" "true" (w #t 'depth-limit 0))
(chk "depth-limit 0 writes null" "null" (w 'null 'depth-limit 0))
(chk "depth-limit 0 refuses an empty vector" (refused 'nesting-too-deep m-deep)
  (let ((v (vector))) (refusal v v 'depth-limit 0)))
(chk "depth-limit 0 refuses an empty alist" (refused 'nesting-too-deep m-deep)
  (refusal '() '() 'depth-limit 0))
(chk "depth-limit 0 refuses an empty hashtable" (refused 'nesting-too-deep m-deep)
  (let ((h (make-table))) (refusal h h 'depth-limit 0)))
(chk "depth-limit 0 refuses a vector of scalars" (refused 'nesting-too-deep m-deep)
  (let ((v (vector 1))) (refusal v v 'depth-limit 0)))
(chk "depth-limit 1 writes a flat vector" "[1,2]" (w (vector 1 2) 'depth-limit 1))
(chk "depth-limit 1 writes a flat alist" "{\"a\":1}" (w '(("a" . 1)) 'depth-limit 1))
(chk "depth-limit 1 refuses a vector in a vector" (refused 'nesting-too-deep m-deep)
  (let ((inner (vector))) (refusal inner (vector 1 inner) 'depth-limit 1)))
(chk "depth-limit 1 refuses a hashtable in an alist" (refused 'nesting-too-deep m-deep)
  (let ((inner (fresh-table))) (refusal inner (list (cons "a" inner)) 'depth-limit 1)))

(chk "default depth-limit 512 writes 512 deep"
  (string-append (make-string 512 #\[) (make-string 512 #\]))
  (w (wrap-vec 511 (vector))))
(chk "default depth-limit refuses 513 deep" (refused 'nesting-too-deep m-deep)
  (let ((bad (fresh-vec))) (refusal bad (wrap-vec 512 bad))))

(chk "a vector that contains itself" (refused 'nesting-too-deep m-deep)
  (let ((v (make-vector 1 #f))) (vector-set! v 0 v) (refusal v v)))
(chk "a vector that contains itself, small limit" (refused 'nesting-too-deep m-deep)
  (let ((v (make-vector 2 0))) (vector-set! v 1 v) (refusal v v 'depth-limit 3)))
(chk "a hashtable whose value is itself" (refused 'nesting-too-deep m-deep)
  (let ((h (make-table))) (hashtable-set! h "k" h) (refusal h h)))
(chk "a hashtable whose value is itself, small limit" (refused 'nesting-too-deep m-deep)
  (let ((h (make-table))) (hashtable-set! h "k" h) (refusal h h 'depth-limit 2)))
(chk "an alist whose value is itself" (refused 'nesting-too-deep m-deep)
  (let ((a (list (cons "k" #f)))) (set-cdr! (car a) a) (refusal a a)))
(chk "an alist whose value is itself, small limit" (refused 'nesting-too-deep m-deep)
  (let ((a (list (cons "k" #f)))) (set-cdr! (car a) a) (refusal a a 'depth-limit 2)))

;; --- 7. Nothing is written on a refusal --------------------------------------

(define big-good (list->vector (map (lambda (i) (list (cons "key" (vector i "text" 1.5)))) (iota 300))))

(chk "bad value first in a vector: nothing written"
  (refused 'unwritable-value m-val)
  (refusal 'foo (vector 'foo 1 2 3)))
(chk "bad value in the middle of a vector: nothing written"
  (refused 'unwritable-number m-num)
  (refusal +nan.0 (vector "a" 1 2 +nan.0 "b" 3)))
(chk "bad value last in a vector: nothing written"
  (refused 'unwritable-number m-num)
  (refusal 1/3 (vector "a" 1 2 3 4 1/3)))
(chk "bad value first in an alist: nothing written"
  (refused 'unwritable-key m-key)
  (refusal 'k '((k . 1) ("a" . 2) ("b" . 3))))
(chk "bad value in the middle of an alist: nothing written"
  (refused 'unwritable-value m-val)
  (refusal 'bad (list (cons "a" 1) (cons "b" 'bad) (cons "c" 3))))
(chk "bad value last in an alist: nothing written"
  (refused 'unwritable-number m-num)
  (refusal +inf.0 (list (cons "a" 1) (cons "b" 2) (cons "c" +inf.0))))
(chk "bad value last in a hashtable: nothing written"
  (refused 'unwritable-value m-val)
  (refusal #\z (table (cons "a" 1) (cons "b" 2) (cons "z" #\z))))
(chk "bad value first in a hashtable: nothing written"
  (refused 'unwritable-value m-val)
  (refusal #\a (table (cons "a" #\a) (cons "b" 2) (cons "z" 3))))
(chk "bad value deepest in a large value: nothing written"
  (refused 'unwritable-number m-num)
  (refusal -inf.0 (vector big-good (vector (list (cons "x" (vector 1 2 -inf.0)))))))
(chk "bad value after a large value: nothing written"
  (refused 'unwritable-value m-val)
  (refusal 'zz (vector big-good big-good 'zz)))
(chk "too deep after a large value: nothing written"
  (refused 'nesting-too-deep m-deep)
  (let ((bad (fresh-vec))) (refusal bad (vector big-good (wrap-vec 3 bad)) 'depth-limit 4)))
(chk "bad value in a laid-out value: nothing written"
  (refused 'unwritable-number m-num)
  (refusal +nan.0 (list (cons "a" (vector 1 +nan.0))) 'indent 2))
(chk "bad key in a laid-out value: nothing written"
  (refused 'unwritable-key m-key)
  (refusal 'q (vector (vector 1) (list (cons 'q 1))) 'indent 2))
(chk "a good value after the same port was refused" "pre[1]"
  (let-values (((p extract) (open-bytevector-output-port)))
    (put-bytevector p (string->utf8 "pre"))
    (guard (e ((json-error? e) 'ignore)) (put-json p (vector 'bad)))
    (put-json p (vector 1))
    (bv->str (extract))))
(chk "a good write appends to the bytes already there" "pre[1,2]"
  (let-values (((p extract) (open-bytevector-output-port)))
    (put-bytevector p (string->utf8 "pre"))
    (put-json p (vector 1 2))
    (bv->str (extract))))

;; --- 8. The arguments --------------------------------------------------------

(define (arg-refusal bad port v . opt)
  (violation-of (lambda () (apply put-json port v opt)) bad))

(let-values (((tp textract) (open-string-output-port))
             ((bp bextract) (open-bytevector-output-port)))
  (let ((ip (open-bytevector-input-port (u8-list->bytevector (list 1 2 3))))
        (xp (transcoded-port bp (native-transcoder)))
        (opts (make-json-options)))
    (chk "a textual port" '(violation #f put-json "not a binary output port" 1 #t)
      (arg-refusal tp tp 1))
    (chk "a textual port, three arguments" '(violation #f put-json "not a binary output port" 1 #t)
      (arg-refusal tp tp 1 opts))
    (chk "a textual port made from a binary one"
      '(violation #f put-json "not a binary output port" 1 #t)
      (arg-refusal xp xp (vector 1)))
    (chk "an input port" '(violation #f put-json "not a binary output port" 1 #t)
      (arg-refusal ip ip 1))
    (chk "an input port, three arguments" '(violation #f put-json "not a binary output port" 1 #t)
      (arg-refusal ip ip 1 opts))
    (chk "a non-port" '(violation #f put-json "not a binary output port" 1 #t)
      (arg-refusal 42 42 1))
    (chk "a string as a port" '(violation #f put-json "not a binary output port" 1 #t)
      (let ((s "port")) (arg-refusal s s 1)))
    (chk "a #f port" '(violation #f put-json "not a binary output port" 1 #t)
      (arg-refusal #f #f 1 opts))
    (chk "the textual port holds nothing" "" (textract))
    (chk "the binary port holds nothing" #vu8() (bextract))
    (chk "no raise on a good port and options" 'no-raise
      (let-values (((p e) (open-bytevector-output-port)))
        (arg-refusal 0 p 1 opts)))))

(let-values (((p extract) (open-bytevector-output-port)))
  (chk "options: a symbol" '(violation #f put-json "not an options record" 1 #t)
    (arg-refusal 'opts p 1 'opts))
  (chk "options: an alist" '(violation #f put-json "not an options record" 1 #t)
    (let ((o '((indent . 2)))) (arg-refusal o p 1 o)))
  (chk "options: #f" '(violation #f put-json "not an options record" 1 #t)
    (arg-refusal #f p 1 #f))
  (chk "options: a number" '(violation #f put-json "not an options record" 1 #t)
    (arg-refusal 3 p 1 3))
  (chk "options: a record of another type" '(violation #f put-json "not an options record" 1 #t)
    (let ((t (make-thing 1))) (arg-refusal t p 1 t)))
  (chk "options: the empty list" '(violation #f put-json "not an options record" 1 #t)
    (arg-refusal '() p 1 '()))
  (chk "the port holds nothing after an options refusal" #vu8() (extract)))

;; The two-argument form reads the same defaults as (make-json-options).
(chk "default null, two arguments" "null" (w2 'null))
(chk "default null, explicit defaults" "null" (w 'null))
(chk "a non-default null reads differently" (refused 'unwritable-value m-val)
  (refusal 'null 'null 'null 'nil))
(chk "default indent, two arguments" "[1,{\"a\":2}]" (w2 (vector 1 '(("a" . 2)))))
(chk "default indent, explicit defaults" "[1,{\"a\":2}]" (w (vector 1 '(("a" . 2)))))
(chk "a non-default indent reads differently"
  (lines "[" "  1," "  {" "    \"a\": 2" "  }" "]")
  (w (vector 1 '(("a" . 2))) 'indent 2))
(chk "default depth-limit, two arguments: 512 written"
  (string-append (make-string 512 #\[) (make-string 512 #\]))
  (w2 (wrap-vec 511 (vector))))
(chk "default depth-limit, two arguments: 513 refused"
  (list 'refused 'nesting-too-deep #f 'put-json m-deep 1 #t #t #f)
  (let ((bad (fresh-vec)))
    (let-values (((p extract) (open-bytevector-output-port)))
      (guard (e ((json-error? e)
                 (list 'refused (json-error-reason e) (json-error-offset e)
                       (condition-who e) (condition-message e)
                       (length (condition-irritants e))
                       (eqv? bad (car (condition-irritants e)))
                       (error? e) (violation? e))))
        (put-json p (wrap-vec 512 bad))
        'no-raise))))
(chk "default depth-limit, explicit defaults: 513 refused" (refused 'nesting-too-deep m-deep)
  (let ((bad (fresh-vec))) (refusal bad (wrap-vec 512 bad))))
(chk "a non-default depth-limit reads differently: 513 written"
  (string-append (make-string 513 #\[) (make-string 513 #\]))
  (w (wrap-vec 512 (vector)) 'depth-limit 513))
(chk "a non-default depth-limit reads differently: 3 refused"
  (refused 'nesting-too-deep m-deep)
  (let ((bad (fresh-vec))) (refusal bad (wrap-vec 3 bad) 'depth-limit 3)))

;; --- 9. The indent option ----------------------------------------------------

(chk "indent default" 0 (json-options-indent (make-json-options)))
(chk "indent 0 read back" 0 (json-options-indent (make-json-options 'indent 0)))
(chk "indent 1 read back" 1 (json-options-indent (make-json-options 'indent 1)))
(chk "indent 2 read back" 2 (json-options-indent (make-json-options 'indent 2)))
(chk "indent 4 read back" 4 (json-options-indent (make-json-options 'indent 4)))
(chk "indent 9 read back" 9 (json-options-indent (make-json-options 'indent 9)))
(chk "indent 10 read back" 10 (json-options-indent (make-json-options 'indent 10)))

(define m-indent "indent is not an exact integer from 0 to 10")

(define (indent-refusal bad)
  (guard (e ((assertion-violation? e)
             (list 'violation (condition-who e) (condition-message e)
                   (length (condition-irritants e))
                   (eqv? bad (car (condition-irritants e)))))
            ((condition? e) (list 'other-raise)))
    (make-json-options 'indent bad)
    'no-raise))

(for-each
 (lambda (bad)
   (chk (string-append "indent refused: " (call-with-string-output-port (lambda (o) (write bad o))))
     (list 'violation 'make-json-options m-indent 1 #t)
     (indent-refusal bad)))
 (list -1 -1000 11 12 64 255 (greatest-fixnum) 1.5 2.0 #t #f 'two "2" '() 1/2 (+ (greatest-fixnum) 1) (- (least-fixnum) 1)
       (expt 10 30) (least-fixnum)))

(chk "indent given twice"
  '(violation make-json-options "an option is given twice" 1 #t)
  (guard (e ((assertion-violation? e)
             (list 'violation (condition-who e) (condition-message e)
                   (length (condition-irritants e))
                   (eq? 'indent (car (condition-irritants e)))))
            ((condition? e) (list 'other-raise)))
    (make-json-options 'indent 1 'indent 2)
    'no-raise))
(chk "indent given twice, apart"
  '(violation make-json-options "an option is given twice" 1 #t)
  (guard (e ((assertion-violation? e)
             (list 'violation (condition-who e) (condition-message e)
                   (length (condition-irritants e))
                   (eq? 'indent (car (condition-irritants e)))))
            ((condition? e) (list 'other-raise)))
    (make-json-options 'indent 1 'depth-limit 5 'indent 2)
    'no-raise))
(chk "indent given with no value"
  '(violation make-json-options "an option has no value" 1 #t)
  (guard (e ((assertion-violation? e)
             (list 'violation (condition-who e) (condition-message e)
                   (length (condition-irritants e))
                   (eq? 'indent (car (condition-irritants e)))))
            ((condition? e) (list 'other-raise)))
    (make-json-options 'indent)
    'no-raise))
(chk "indent with no value after another option"
  '(violation make-json-options "an option has no value" 1 #t)
  (guard (e ((assertion-violation? e)
             (list 'violation (condition-who e) (condition-message e)
                   (length (condition-irritants e))
                   (eq? 'indent (car (condition-irritants e)))))
            ((condition? e) (list 'other-raise)))
    (make-json-options 'depth-limit 5 'indent)
    'no-raise))

(chk "all defaults" '(512 flonum 1000 alist null 0) (options-row (make-json-options)))
(chk "all six non-default" '(7 exact 33 hashtable nil 3)
  (options-row (make-json-options 'depth-limit 7 'number-mode 'exact 'digit-limit 33
                                  'object-mode 'hashtable 'null 'nil 'indent 3)))
(chk "all six non-default, indent first" '(7 exact 33 hashtable nil 3)
  (options-row (make-json-options 'indent 3 'null 'nil 'object-mode 'hashtable
                                  'digit-limit 33 'number-mode 'exact 'depth-limit 7)))
(chk "all six non-default, indent in the middle" '(7 exact 33 hashtable nil 3)
  (options-row (make-json-options 'depth-limit 7 'number-mode 'exact 'indent 3
                                  'digit-limit 33 'object-mode 'hashtable 'null 'nil)))

;; Every ordered pair of indent with another option: all six fields.
(chk "indent then depth-limit" '(7 flonum 1000 alist null 3)
  (options-row (make-json-options 'indent 3 'depth-limit 7)))
(chk "depth-limit then indent" '(7 flonum 1000 alist null 3)
  (options-row (make-json-options 'depth-limit 7 'indent 3)))
(chk "indent then number-mode" '(512 exact 1000 alist null 3)
  (options-row (make-json-options 'indent 3 'number-mode 'exact)))
(chk "number-mode then indent" '(512 exact 1000 alist null 3)
  (options-row (make-json-options 'number-mode 'exact 'indent 3)))
(chk "indent then digit-limit" '(512 flonum 33 alist null 3)
  (options-row (make-json-options 'indent 3 'digit-limit 33)))
(chk "digit-limit then indent" '(512 flonum 33 alist null 3)
  (options-row (make-json-options 'digit-limit 33 'indent 3)))
(chk "indent then object-mode" '(512 flonum 1000 hashtable null 3)
  (options-row (make-json-options 'indent 3 'object-mode 'hashtable)))
(chk "object-mode then indent" '(512 flonum 1000 hashtable null 3)
  (options-row (make-json-options 'object-mode 'hashtable 'indent 3)))
(chk "indent then null" '(512 flonum 1000 alist nil 3)
  (options-row (make-json-options 'indent 3 'null 'nil)))
(chk "null then indent" '(512 flonum 1000 alist nil 3)
  (options-row (make-json-options 'null 'nil 'indent 3)))
(chk "an options value for indent only" '(512 flonum 1000 alist null 3)
  (options-row (make-json-options 'indent 3)))

;; --- 10. &json-error on its own ----------------------------------------------

(chk "json-error? of a json-error" #t (json-error? (make-json-error 'unexpected-byte 5)))
(chk "json-error? of a json-error, no offset" #t (json-error? (make-json-error 'x #f)))
(chk "json-error-reason" 'unexpected-byte
  (json-error-reason (make-json-error 'unexpected-byte 5)))
(chk "json-error-reason, another" 'unwritable-key
  (json-error-reason (make-json-error 'unwritable-key #f)))
(chk "json-error-offset" 5 (json-error-offset (make-json-error 'unexpected-byte 5)))
(chk "json-error-offset, zero" 0 (json-error-offset (make-json-error 'x 0)))
(chk "json-error-offset, #f" '(v #f) (list 'v (json-error-offset (make-json-error 'x #f))))
(chk "json-error is an error" #t (error? (make-json-error 'x 1)))
(chk "json-error is not a violation" '(v #f) (list 'v (violation? (make-json-error 'x 1))))
(chk "json-error is not an assertion violation" '(v #f)
  (list 'v (assertion-violation? (make-json-error 'x 1))))
(chk "json-error is a condition" #t (condition? (make-json-error 'x 1)))
(chk "json-error? of an assertion violation" '(v #f)
  (list 'v (json-error? (make-assertion-violation))))
(chk "json-error? of a plain error" '(v #f) (list 'v (json-error? (make-error))))
(chk "json-error? of a violation" '(v #f) (list 'v (json-error? (make-violation))))
(chk "json-error? of a raised assertion violation" '(v #f)
  (list 'v (guard (e ((assertion-violation? e) (json-error? e)))
             (assertion-violation 'f "m"))))
(chk "json-error? of a raised plain error" '(v #f)
  (list 'v (guard (e ((error? e) (json-error? e)))
             (error 'f "m"))))
(chk "json-error? of a symbol" '(v #f) (list 'v (json-error? 'x)))
(chk "json-error? of #f" '(v #f) (list 'v (json-error? #f)))
(chk "reason in a compound condition" 'r
  (json-error-reason (condition (make-json-error 'r 3) (make-who-condition 'f))))
(chk "offset in a compound condition" 3
  (json-error-offset (condition (make-who-condition 'f) (make-json-error 'r 3))))
(chk "a raised json-error is caught as json-error and error, not violation"
  '(#t #t #f)
  (guard (e (#t (list (json-error? e) (error? e) (violation? e))))
    (raise (make-json-error 'x #f))))

(test-end "writer")

(display "elapsed ms: ")
(display (- (real-time) started))
(newline)
(display "pass ")
(display (test-runner-pass-count runner))
(display " fail ")
(display (test-runner-fail-count runner))
(newline)

(exit (suite-exit-status runner))
