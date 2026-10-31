# The push parser: `(jsonparse parser)`

Give it bytes, in pieces of any size. It tells you what it sees as it goes.
It never builds a value and never copies your bytes, so a huge document costs
no more memory than a small one.

## In one minute

```scheme
(import (rnrs) (jsonparse parser) (jsonparse options))

;; Count the numbers in a document.
(define count 0)
(define handler
  (make-json-handler 'number-end (lambda (context) (set! count (+ count 1)))))

(define parser (make-json-parser handler))
(json-parser-feed! parser (string->utf8 "[1, 2, {\"a\": 3}]"))
(json-result-status (json-parser-finish! parser))   ; => finished
count                                               ; => 3
```

## The handler

A handler is a set of procedures, each named for what it hears. Give only
the ones you need:

| Name           | Called with              | When                              |
|:---------------|:-------------------------|:----------------------------------|
| `null`         | `context`                | `null`                            |
| `boolean`      | `context b`              | `true` or `false`; `b` is `#t` or `#f` |
| `number-chars` | `context bv start end`   | part of a number's text           |
| `number-end`   | `context`                | the number is complete            |
| `string-start` | `context`                | a string begins                   |
| `chars`        | `context bv start end`   | part of a string's or key's text  |
| `escape`       | `context scalar`         | an escape, such as `\n` or `\u00e9` |
| `string-end`   | `context`                | the string is complete            |
| `object-start` | `context`                | `{`                               |
| `key-start`    | `context`                | a key begins                      |
| `key-end`      | `context`                | the key is complete               |
| `object-end`   | `context`                | `}`                               |
| `array-start`  | `context`                | `[`                               |
| `array-end`    | `context`                | `]`                               |

- **Text comes in parts.** The text of a string, a key or a number may come in
  several calls, split wherever your pieces of input or the escapes fall. Join
  the parts yourself if you need the whole. No part is empty.
- **A part may end in the middle of a character.** The rest of the character
  comes in the next part. Decode text only after joining its parts.
- **The bytes are yours only during the call.** `bv` from `start` to `end`
  is your own input, not a copy. Copy what you need before returning.
- **`escape` gives a whole character.** `scalar` is a Unicode scalar value:
  `\uD834\uDD1E` arrives as one call with `#x1D11E`. A character written
  as itself, unescaped, arrives through `chars` as UTF-8.
- **Return anything to carry on.** To stop the parse with an error of your
  own, return `(make-json-stop 'my-code)`.
  - The error's offset is where your procedure ran. From `chars` or
    `number-chars`, that depends on how the input was split. From
    `number-end`, `string-end` or `key-end`, it never does.
  - `json-stop?` tells you whether a value is a stop, if your procedure
    calls another.
- **If a procedure raises,** or escapes through a continuation, it comes out
  of the feed. Reset the parser before using it again.
- **Don't feed, finish or reset a parser** from inside its own procedures.

## Feeding and results

```scheme
(make-json-parser handler)                  ; context #f, default options
(make-json-parser handler context)
(make-json-parser handler context options)

(json-parser-feed! parser bv)               ; all of bv
(json-parser-feed! parser bv start end)     ; part of bv
(json-parser-finish! parser)                ; no more input
(json-parser-reset! parser)                 ; ready for a new document
```

Every feed and finish returns a result:

| `json-result-status` | Meaning                                   | `json-result-code` | `json-result-offset` |
|:---------------------|:------------------------------------------|:-------------------|:---------------------|
| `need-input`         | all read; feed more, or finish            | `#f`               | bytes read so far    |
| `finished`           | one whole JSON value, then the end        | `#f`               | bytes read           |
| `error`              | not JSON, or a handler stopped it         | why, such as `unexpected-byte` | where, in bytes |

Bad input is a result, never an exception. Once a parser has finished or hit
an error, it keeps answering the same until you reset it. A reset doesn't
tell your handler: if your context holds a half-built value, reset it too.

The error codes are `unexpected-byte`, `unexpected-eof`, `invalid-number`,
`invalid-escape`, `invalid-surrogate`, `invalid-utf8`, `control-character`,
`nesting-too-deep` and `trailing-garbage`, plus any code a handler stops
with.

## Options

```scheme
(make-json-options 'depth-limit 64)
```

- `depth-limit`: how many objects and arrays may be open at once, from 0 to
  65535. The default is 512. Going deeper is the error `nesting-too-deep`.

A bad option raises an assertion violation when the options are made.
