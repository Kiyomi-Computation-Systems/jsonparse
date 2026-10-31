# Strings and numbers: `(jsonparse string)`

The parser hands you a string's or a number's text in pieces. An assembler
glues the pieces back together and gives you a Scheme string or number.
Use one assembler per parser: it reuses one buffer for every value.

## In one minute

```scheme
(import (rnrs) (jsonparse parser) (jsonparse string) (jsonparse options))

;; Print every key, string and number in a document.
(define (print-string a) (write (json-assembler-string! a)) (newline))
(define a (make-json-assembler))
(define handler
  (make-json-handler
   'chars json-assembler-chars!
   'escape json-assembler-escape!
   'key-end print-string
   'string-end print-string
   'number-chars json-assembler-number-chars!
   'number-end (lambda (a)
                 (let ((n (json-assembler-number! a)))
                   (if (json-stop? n)
                       n                      ; hand a stop back to the parser
                       (begin (write n) (newline)))))))

(define parser (make-json-parser handler a))   ; the assembler is the context
(json-parser-feed! parser (string->utf8 "{\"caf\\u00e9\": [1.5, 42]}"))
(json-parser-finish! parser)
;; prints "cafe" with an accent, then 1.5, then 42
```

`chars`, `escape` and `number-chars` take the same arguments as the
assembler's procedures, so when the assembler is the parser's context you
can hand those three over as they are.

## The procedures

```scheme
(make-json-assembler)                          ; default options
(make-json-assembler options)

(json-assembler-chars! a bv start end)         ; from chars
(json-assembler-escape! a scalar)              ; from escape
(json-assembler-string! a)                     ; from string-end or key-end
(json-assembler-number-chars! a bv start end)  ; from number-chars
(json-assembler-number! a)                     ; from number-end
(json-assembler-reset! a)                      ; drop a half-built value
```

- **Keys and strings work the same way.** Take a key in `key-end` and a
  string in `string-end`. Take every one you give parts for: a key you
  never take is still in the assembler when the next text begins.
- **Taking empties the assembler,** ready for the next value.
- **Reset the assembler when you reset the parser.** A parse that ends in
  an error can leave half a value inside it.

## Numbers

Choose how numbers come back with `number-mode`:

| `number-mode`      | `42` | `1.5` | `-0`  | `-0.0` | `1e2`   |
|:-------------------|:-----|:------|:------|:-------|:--------|
| `flonum` (default) | `42` | `1.5` | `0`   | `-0.0` | `100.0` |
| `exact`            | `42` | `3/2` | `0`   | `0`    | `100`   |
| `text`             | the text, in a `json-number` record |

- **`flonum`:** whole numbers written without a point or exponent are exact
  integers. The rest are flonums.
- **`exact`:** every number is exact.
- **`text`:** nothing is converted. `(json-number-text n)` gives back the
  text exactly as written, such as `"1.50"`.

`json-assembler-number!` returns a stop instead of a number when:

| Code                  | When |
|:----------------------|:-----|
| `number-too-long`     | `flonum` or `exact` mode, and more digits than `digit-limit` |
| `number-out-of-range` | `flonum` mode, and too big for a flonum, such as `1e400` |
| `number-out-of-range` | `exact` mode, and the significand's digits plus the exponent's size, sign ignored, are more than `digit-limit`, such as `1e1000` or `1e-1000` |

If both codes apply, you get `number-too-long`. Return the stop from
`number-end`, and the parse ends with that code.

Long numbers are slow to convert, so the limit keeps a hostile document
from taking minutes. In `text` mode there is no limit.

## Options

```scheme
(make-json-options 'number-mode 'exact 'digit-limit 50)
```

- `number-mode`: `flonum` (the default), `exact` or `text`.
- `digit-limit`: how many digits a number may have, counting its fraction
  and exponent, from 1 to the greatest fixnum. The default is 1000.

## `json-number`

```scheme
(make-json-number "1.50")      ; a record; raises unless the text is a JSON number
(json-number? x)
(json-number-text n)           ; => "1.50"
```

The record keeps its own copy of the text, so it always holds a valid JSON
number.
