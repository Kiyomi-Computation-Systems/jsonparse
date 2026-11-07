# Whole documents: `(jsonparse easy)`

One import reads a JSON document into a Scheme value, writes a value back
out, and looks inside it. Bad input raises an exception that says what went
wrong and where.

## In one minute

```scheme
(import (rnrs) (jsonparse easy))

(define v (string->json "{\"users\": [{\"name\": \"Ada\", \"age\": 36}]}"))
v                               ; => (("users" . #((("name" . "Ada") ("age" . 36)))))
(json-ref v "users" 0 "name")   ; => "Ada"
(json->string v)                ; => "{\"users\":[{\"name\":\"Ada\",\"age\":36}]}"

(guard (e ((json-error? e) (list (json-error-reason e) (json-error-offset e))))
  (string->json "[1, 2,]"))
;; => (unexpected-byte 6)
```

## Reading

```scheme
(string->json "[1, 2]")                       ; from a string
(bytevector->json (string->utf8 "[1, 2]"))    ; from UTF-8 bytes
(read-json port)                              ; from a binary input port
```

- **One document each,** with nothing after it but whitespace.
  `read-json` reads the port to its end.
- **The value** is what [tree.md](tree.md)'s builder gives: objects as
  alists, arrays as vectors, `null` as the symbol `null`.
- **Bad input raises a `&json-error`:**
  - `json-error-reason` says why, such as `unexpected-byte` or
    `number-too-long`. [parser.md](parser.md) lists them;
  - `json-error-offset` says where: in characters for a string, in bytes
    for a bytevector or a port.

## Writing

```scheme
(json->string '(("a" . #(1 null))))       ; => "{\"a\":[1,null]}"
(json->bytevector '(("a" . #(1 null))))   ; the same, as UTF-8 bytes
(write-json port '(("a" . #(1 null))))    ; to a binary output port
```

A value JSON can't express, such as `1/3`, raises a `&json-error` before
anything is written. See [writer.md](writer.md).

## Looking inside

```scheme
(json-ref v "users" 0 "name")                   ; a key steps into an object, a number into an array
(json-ref v "users" 0 "name" 'default "anon")   ; "anon" if there is no such value
(json-null? x)                                  ; is x null?
(json=? a b)                                    ; do a and b mean the same JSON?
```

- **`json-ref`** raises a `&json-error` whose reason is `not-found` when
  the path leads nowhere, unless you end the call with `'default` and a
  value. If a key appears twice, the last one counts. A list that isn't an
  alist raises the writer's `unwritable-value`, default or not.
- **`json=?`** ignores the order of an object's members, lets the last
  duplicate key win, and compares numbers by exact value:
  - `1` and `1.0` are the same;
  - the flonum `0.1` is not the `json-number` `"0.1"`, since a flonum is
    binary.

  It works across alists and hashtables. It raises the writer's
  `&json-error` for a value JSON can't express. Give it the options you
  read with, so it knows your `null` and `depth-limit`.

## Options

Every procedure but `json-ref` takes an options record last, as the lower
layers do:

```scheme
(string->json text (make-json-options 'object-mode 'hashtable 'number-mode 'exact))
(json->string v (make-json-options 'indent 2))
(json-null? x (make-json-options 'null 'nil))
```

Read and write a value with the same `null`.
[tree.md](tree.md) and [writer.md](writer.md) list the options.

## When to use the lower layers

Each call makes a new parser. For many small documents, reuse a builder
from [tree.md](tree.md). For input that arrives in pieces, feed a builder
or a parser as the pieces come.
