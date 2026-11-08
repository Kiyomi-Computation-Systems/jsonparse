# Building values: `(jsonparse tree)`

A builder turns JSON bytes into Scheme values. Feed it the bytes in pieces
of any size, finish it when the input ends, and take the value. For a
whole document in a string, a bytevector or a port, [easy.md](easy.md) is
shorter.

## In one minute

```scheme
(import (rnrs) (jsonparse tree) (jsonparse parser) (jsonparse options))

(define b (make-json-builder))
(json-builder-feed! b (string->utf8 "{\"name\": \"Ada\", \"tags\": [\"x\", \"y\"], \"si"))
(json-builder-feed! b (string->utf8 "ze\": 1.5, \"ok\": true, \"no\": false, \"next\": null}"))
(json-result-status (json-builder-finish! b))   ; => finished
(json-builder-value b)
;; => (("name" . "Ada") ("tags" . #("x" "y")) ("size" . 1.5)
;;     ("ok" . #t) ("no" . #f) ("next" . null))
```

## The procedures

```scheme
(make-json-builder)                    ; default options
(make-json-builder options)

(json-builder-feed! b bv)              ; all of bv
(json-builder-feed! b bv start end)    ; part of bv
(json-builder-finish! b)               ; no more input
(json-builder-value b)                 ; the value
(json-builder-reset! b)                ; ready for the next document
(json-builder? x)                      ; is x a builder?
```

- **Feed and finish return the parser's results:** a status, a code and a
  byte offset. See [parser.md](parser.md). Bad input is a result, never an
  exception.
- **The value is ready once finish says `finished`.** Asking for it at any
  other time raises.
- **The builder keeps the value until you reset it.** Reset it before the
  next document: reusing a builder is cheaper than making a new one.
- **An error drops everything built so far,** so a bad document holds no
  memory.

## A value at a time

Give a procedure after the options, and the builder hands it each
top-level value as soon as it is complete, keeping none:

```scheme
(define b (make-json-builder (make-json-options 'stream 'values)
                             (lambda (v) (display v))))
(json-builder-feed! b (string->utf8 "1 [2] {}"))   ; shows 1, #(2) and ()
(json-builder-finish! b)
```

A number is complete once the byte after it arrives, or at the finish,
since `12` might go on as `123`. With `'stream 'values` the input may hold
any number of values, and the procedure is required. `json-builder-value` raises for such a builder. If
the procedure returns a stop, the parse ends as a handler's stop ends it.
[sequence.md](sequence.md) reads streams of lines and RFC 7464 records.

## What you get

| JSON           | Scheme                                              |
|:---------------|:----------------------------------------------------|
| object         | an alist, `(("key" . value) ...)`, or a hashtable   |
| array          | a vector                                            |
| string         | a string                                            |
| number         | by `number-mode`: see [string.md](string.md)        |
| `true` `false` | `#t` `#f`                                           |
| `null`         | the symbol `null`, or your own choice               |

With the defaults, `{}` is `()`, `[]` is `#()` and `null` is `null`, so none
of them can be taken for another.

## Options

```scheme
(make-json-options 'object-mode 'hashtable 'null 'nil)
```

- `object-mode`:
  - `alist`, the default: members in document order, duplicate keys kept.
  - `hashtable`: a new R6RS hashtable for each object, keyed by string.
    If a key appears twice, the last one wins.
- `null`: what `null` becomes. A symbol, or a record of your own, made by
  `define-record-type` without `opaque`. Anything else is refused, since
  most other values could be mistaken for another JSON value.
- `number-mode` and `digit-limit`: see [string.md](string.md). A number
  they refuse ends the parse with `number-too-long` or
  `number-out-of-range`.
- `depth-limit`: see [parser.md](parser.md).
- `stream`: see [parser.md](parser.md) and above.
- `indent` is for the writer, and the builder ignores it.

To write a value back out as JSON, see [writer.md](writer.md).
