# Writing JSON: `(jsonparse writer)`

`put-json` writes a Scheme value as JSON, in UTF-8, to a binary port. It
writes what [tree.md](tree.md)'s builder gives you, and refuses anything
JSON can't express. To get a string or a bytevector instead, see
[easy.md](easy.md).

## In one minute

```scheme
(import (rnrs) (jsonparse writer) (jsonparse options) (jsonparse error))

(define value '(("name" . "Ada") ("tags" . #("x" "y")) ("size" . 3/2) ("next" . null)))

(let-values (((port get) (open-bytevector-output-port)))
  (put-json port value)
  (utf8->string (get)))
;; => "{\"name\":\"Ada\",\"tags\":[\"x\",\"y\"],\"size\":1.5,\"next\":null}"

(let-values (((port get) (open-bytevector-output-port)))
  (put-json port value (make-json-options 'indent 2))
  (display (utf8->string (get))))
;; {
;;   "name": "Ada",
;;   "tags": [
;;     "x",
;;     "y"
;;   ],
;;   "size": 1.5,
;;   "next": null
;; }
```

## What it writes

| Scheme                          | JSON                                    |
|:--------------------------------|:----------------------------------------|
| an alist, `(("key" . value) ...)` | an object, members in order, duplicates too |
| a hashtable with string keys    | an object, members in key order         |
| `'()`                           | `{}`                                    |
| a vector                        | an array                                |
| a string                        | a string                                |
| `#t` `#f`                       | `true` `false`                          |
| the options' `null`             | `null`                                  |
| an exact integer                | `42`                                    |
| a flonum                        | `1.5`, `-0.0`, `1e21`                   |
| an exact fraction like `3/2`    | `1.5`, its exact decimal                |
| a `json-number`                 | its text, as it is                      |

- **Strings:** `"` and `\` are escaped, and so are control characters, as
  `\n` or `\u001f`. Everything else is written as itself.
- **The output is always the same for the same value,** hashtables
  included.

## What it refuses

`put-json` raises a `&json-error` before writing a single byte, so a refused
value leaves your port untouched:

```scheme
(let-values (((port get) (open-bytevector-output-port)))
  (guard (e ((json-error? e) (list (json-error-reason e) (get))))
    (put-json port (vector 1 2 1/3))))
;; => (unwritable-number #vu8())
```

| `json-error-reason` | For                                                   |
|:--------------------|:------------------------------------------------------|
| `unwritable-number` | NaN, the infinities, complex numbers, and fractions with no exact decimal, such as `1/3` |
| `unwritable-key`    | an object key that isn't a string, or two keys with the same text in one hashtable |
| `unwritable-value`  | anything else: other symbols, characters, lists that aren't alists, and so on |
| `nesting-too-deep`  | more than `depth-limit` arrays and objects open at once, or a value that contains itself |

The part that was refused, such as the number or the key, is the
condition's irritant, and `json-error-offset` is `#f`.

`(check-json value)` raises what `put-json` would, and writes nothing. Use
it to check a value before you start a response.

## Options

```scheme
(make-json-options 'indent 2 'null 'nil)
```

- `indent`: 0, the default, writes everything on one line with no spaces.
  1 to 10 puts each member on its own line, indented that many spaces a
  level.
- `null`: the value written as `null`, as for reading.
- `depth-limit`: the most arrays and objects open at once, as for reading.

The writer ignores the other options. It writes any number JSON can
express, even one that a reader in `flonum` or `exact` mode refuses: more
digits than `digit-limit`, or a `json-number` such as `1e400`, too big for
a flonum.
