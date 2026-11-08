# Streams of values: `(jsonparse sequence)`

A reader takes a stream of many JSON values, such as a log with one value
a line, and hands you each value as soon as its record has arrived. Feed
it the bytes in pieces of any size. For a whole stream in a bytevector or
a port, [easy.md](easy.md) is shorter.

## In one minute

```scheme
(import (rnrs) (jsonparse sequence) (jsonparse parser) (jsonparse options))

(define r (make-json-reader (lambda (v) (write v) (newline))))
(json-reader-feed! r (string->utf8 "{\"a\": 1}\n[2, 3]\n4"))   ; shows (("a" . 1)) and #(2 3)
(json-result-status (json-reader-finish! r))                  ; shows 4; => finished
```

## The three formats

The options' `stream` picks the format:

| `stream` | What it reads | Each record ends at |
|:--|:--|:--|
| `lines`, the default | JSON Lines and NDJSON: one value a line | a newline, `\n`. The last one may be left out |
| `seq` | RFC 7464: each value after an RS byte, `#x1E` | the next RS, or the end |
| `values` | values one after another | the end of the value |

- **`lines`:** spaces, tabs and a `\r` around the value are fine. A blank
  line is a bad record, `blank-line`, unless you make the options with
  `'blank-lines 'skip`.
- **`seq`:** several RS bytes in a row count as one. A number, `true`,
  `false` or `null` with no whitespace after it may have been cut short, so
  it is a bad record, `truncated`. Anything before the first RS is a bad
  record too.
- **`values`:** `[1]{}"a"` is three values. A number, `true`, `false` or
  `null` needs whitespace after it, so `1-2` is an error. An empty stream
  holds no values.

## The procedures

```scheme
(make-json-reader on-value)                    ; lines, a bad record ends the stream
(make-json-reader on-value options)
(make-json-reader on-value on-skip)            ; skip bad records, telling on-skip
(make-json-reader on-value on-skip options)

(json-reader-feed! r bv)                       ; all of bv
(json-reader-feed! r bv start end)             ; part of bv
(json-reader-finish! r)                        ; the stream has ended
(json-reader-record r)                         ; which record, counting from 1
(json-reader-reset! r)                         ; ready for a new stream
(json-reader? x)                               ; is x a reader?
```

- **`(on-value v)`** gets each value, in order.
- **Feed and finish return [parser.md](parser.md)'s results.** The offset
  counts bytes from the start of the stream.
- **Records count from 1:** in `lines` they are line numbers, blank lines
  included. Inside your procedures, `json-reader-record` is the record
  handed over; after an error, the bad one.
- **`depth-limit` and `digit-limit` apply to each value,** not to the
  whole stream.
- **Don't feed, finish or reset a reader from inside its own procedures,**
  or call a continuation captured inside them once they have returned or
  escaped. If one of them raises, reset the reader before using it again,
  which also lets go of the value it was handing over.
- **A reader keeps the largest string buffer it has needed,** even across
  a reset. After a 1 MB string, drop the reader to free the 1 MB.

## Bad records

Without `on-skip`, the first bad record ends the stream: feed or finish
returns an error, whose code says why and whose offset says where.

With `on-skip`, a bad record is skipped, and you hear of it:

```scheme
(define (on-skip code record offset)
  (display (list 'skipped code 'record record 'at offset)))
```

A record found bad partway is dropped up to its separator, and reading goes
on with the next. `seq` needs `on-skip`, since RFC 7464 says to skip.
`values` refuses it: nothing marks where the next value would begin.

The codes are the parser's, such as `unexpected-byte`, plus `blank-line`
and `truncated`.

## Writing a record

`put-json-record`, from [writer.md](writer.md), writes one value as a
record of the options' format:

```scheme
(put-json-record port '(("a" . 1)))                                  ; {"a":1} and \n
(put-json-record port '(("a" . 1)) (make-json-options 'stream 'seq))  ; RS, {"a":1}, \n
```

A `lines` record is always compact: with `indent` above 0 it raises.
