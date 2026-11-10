# API reference

Every library jsonparse has, and every binding each one exports. The guides
explain how the pieces fit together; this page answers a smaller question:
what exactly is this binding, and where does it come from?

## Reading this page

Each entry starts with a signature, in the notation of the comments in the
source:

```scheme
;; json-ref : Any (U String Nonnegative-Integer) ... ['default Any] -> Any
(json-ref (string->json "{\"a\": [10, 20]}") "a" 1)
;; => 20
```

reads as "`json-ref` takes a value, then any number of strings or exact
nonnegative integers, then optionally `'default` and a value, and returns a
value". The names used:

| Name                        | Means                                              |
|:----------------------------|:---------------------------------------------------|
| `[x]`                       | an optional argument                               |
| `x ...`                     | any number of `x`, none included                   |
| `(U A B)`                   | an `A` or a `B`                                    |
| `(Option T)`                | a `T`, or `#f`                                     |
| `(Listof T)`                | a list of `T`                                      |
| `'name`                     | that symbol                                        |
| `a`                         | any type, the same one throughout the signature    |
| `Nonnegative-Fixnum`        | an exact integer, zero or more, that is a fixnum   |
| `json-options`              | an options record, from `make-json-options`        |
| `json-result`               | a result, from a feed or a finish                  |
| `json-stop`                 | a stop, from `make-json-stop`                      |
| `json-number`               | a number kept as its text, from `make-json-number` |
| `&json-error`               | a condition of that type                           |

A JSON value in Scheme is what [tree.md](tree.md#what-you-get) lists:
alists or hashtables, vectors, strings, numbers, `#t`, `#f` and the null.

**Available from** names every library that exports the binding. The test
suite checks this page against the source: every export has exactly one
entry, naming exactly the libraries that export it, and nothing else has an
entry.

## Libraries

| Library                | What it is for                                                 |
|:-----------------------|:---------------------------------------------------------------|
| `(jsonparse easy)`     | read and write whole documents and streams; look inside values |
| `(jsonparse options)`  | the options record every layer takes                           |
| `(jsonparse error)`    | `&json-error` and `&json-record-error`                         |
| `(jsonparse parser)`   | the push parser: bytes in, calls to your procedures out        |
| `(jsonparse string)`   | join a string's or a number's parts; convert numbers           |
| `(jsonparse tree)`     | build Scheme values from bytes fed in pieces                   |
| `(jsonparse writer)`   | write values as JSON to a binary port                          |
| `(jsonparse sequence)` | read a stream of many values, fed in pieces                    |

Most programs need only `(jsonparse easy)`, which also exports the options,
the errors and `json-number`. The others are the low layer, for input that
arrives in pieces or for building values of your own. `(generated
jsonparse)` is the machine the parser runs, and isn't for use on its own.

## Reading

### `string->json` (procedure)

`string->json : String [json-options] -> Any`

Reads one whole JSON document from a string. Bad input raises a
`&json-error` whose offset counts characters.

**Available from:** `(jsonparse easy)`\
**Details:** [Reading](easy.md#reading)

### `bytevector->json` (procedure)

`bytevector->json : Bytevector [json-options] -> Any`

Reads one whole JSON document from UTF-8 bytes. Bad input raises a
`&json-error` whose offset counts bytes.

**Available from:** `(jsonparse easy)`\
**Details:** [Reading](easy.md#reading)

### `read-json` (procedure)

`read-json : Binary-Input-Port [json-options] -> Any`

Reads one whole JSON document from a binary port, 16 KiB at a time, to the
port's end. Bad input raises a `&json-error` whose offset counts bytes from
where the port was. It is raised once the 16 KiB that hold the error have
come, or the port has ended. What the port itself raises passes through.

**Available from:** `(jsonparse easy)`\
**Details:** [Reading](easy.md#reading)

## Writing

### `json->string` (procedure)

`json->string : Any [json-options] -> String`

Writes a value as JSON text. A value JSON can't express raises a
`&json-error` before anything is written.

**Available from:** `(jsonparse easy)`\
**Details:** [Writing](easy.md#writing)

### `json->bytevector` (procedure)

`json->bytevector : Any [json-options] -> Bytevector`

Writes a value as JSON, in UTF-8 bytes. Raises as `json->string` does.

**Available from:** `(jsonparse easy)`\
**Details:** [Writing](easy.md#writing)

### `write-json` (procedure)

`write-json : Binary-Output-Port Any [json-options] -> Void`

Writes a value as JSON to a binary port. A refused value raises before a
byte is written. What the port itself raises passes through.

**Available from:** `(jsonparse easy)`\
**Details:** [Writing](easy.md#writing)

## Looking inside

### `json-ref` (procedure)

`json-ref : Any (U String Nonnegative-Integer) ... ['default Any] -> Any`

Follows a path into a value: a string steps into an object, to the last
member with that key, and an integer into an array. Where the path leads
nowhere, gives the value after a closing `'default`, or raises a
`&json-error` whose reason is `not-found`.

**Available from:** `(jsonparse easy)`\
**Details:** [Looking inside](easy.md#looking-inside)

### `json=?` (procedure)

`json=? : Any Any [json-options] -> Boolean`

Whether two values mean the same JSON. Objects compare as unordered members,
the last duplicate winning, and numbers by exact value. Raises what
`put-json` would for a value JSON can't express.

**Available from:** `(jsonparse easy)`\
**Details:** [Looking inside](easy.md#looking-inside)

### `json-null?` (predicate)

`json-null? : Any [json-options] -> Boolean`

Whether a value is the options' null: the symbol `null` by default.

**Available from:** `(jsonparse easy)`\
**Details:** [Looking inside](easy.md#looking-inside)

## Streams

### `read-json-sequence` (procedure)

`read-json-sequence : Binary-Input-Port [(U #f (&json-record-error -> Any))] [json-options] -> (Listof Any)`

Reads every value of a stream from a binary port, framed as the options'
`stream` says: `lines`, the default, `seq` or `values`. A bad record raises
a `&json-record-error`. Given a report procedure, bad records are skipped,
and it gets each one's error.

**Available from:** `(jsonparse easy)`\
**Details:** [Streams of values](easy.md#streams-of-values)

### `bytevector->json-sequence` (procedure)

`bytevector->json-sequence : Bytevector [(U #f (&json-record-error -> Any))] [json-options] -> (Listof Any)`

Reads every value of a stream from bytes, as `read-json-sequence` does.

**Available from:** `(jsonparse easy)`\
**Details:** [Streams of values](easy.md#streams-of-values)

### `fold-json-sequence` (procedure)

`fold-json-sequence : (Any a -> a) a Binary-Input-Port [(U #f (&json-record-error -> Any))] [json-options] -> a`

Calls `(kons value acc)` on each value of a stream as its record arrives,
so a long stream needn't fit in memory.

**Available from:** `(jsonparse easy)`\
**Details:** [Streams of values](easy.md#streams-of-values)

### `write-json-sequence` (procedure)

`write-json-sequence : Binary-Output-Port (Listof Any) [json-options] -> Void`

Writes each value as one record of the options' `stream`. A refused value
raises before any byte of its record; the records before it stay written.

**Available from:** `(jsonparse easy)`\
**Details:** [Streams of values](easy.md#streams-of-values)

### `json-sequence->bytevector` (procedure)

`json-sequence->bytevector : (Listof Any) [json-options] -> Bytevector`

Writes each value as one record of the options' `stream`, into bytes.

**Available from:** `(jsonparse easy)`\
**Details:** [Streams of values](easy.md#streams-of-values)

## Options: `(jsonparse options)`

### `make-json-options` (procedure)

`make-json-options : Symbol Any ... -> json-options`

Makes an options record from name and value pairs; a name left out takes
its default. A bad name or value raises an assertion violation.

| Name          | Values                                       | Default  |
|:--------------|:---------------------------------------------|:---------|
| `depth-limit` | 0 to 65535 arrays and objects open at once   | 512      |
| `number-mode` | `flonum`, `exact` or `text`                  | `flonum` |
| `digit-limit` | 1 to the greatest fixnum digits a number     | 1000     |
| `object-mode` | `alist` or `hashtable`                       | `alist`  |
| `null`        | a symbol, or a `record?` that isn't a hashtable | `null` |
| `indent`      | 0 to 10 spaces a level; 0 is compact         | 0        |
| `stream`      | `lines`, `seq` or `values`                   | `lines`  |
| `blank-lines` | `error` or `skip`, under `stream lines` only | `error`  |

**Available from:** `(jsonparse options)`, `(jsonparse easy)`\
**Details:** [Options](parser.md#options), [Numbers](string.md#options),
[Values](tree.md#options), [Layout](writer.md#options),
[Streams](sequence.md#the-three-formats)

### `json-options?` (predicate)

`json-options? : Any -> Boolean`

Whether a value is an options record.

**Available from:** `(jsonparse options)`, `(jsonparse easy)`

### `json-options-depth-limit` (accessor)

`json-options-depth-limit : json-options -> Nonnegative-Fixnum`

The options' `depth-limit`.

**Available from:** `(jsonparse options)`

### `json-options-number-mode` (accessor)

`json-options-number-mode : json-options -> (U 'flonum 'exact 'text)`

The options' `number-mode`.

**Available from:** `(jsonparse options)`

### `json-options-digit-limit` (accessor)

`json-options-digit-limit : json-options -> Positive-Fixnum`

The options' `digit-limit`.

**Available from:** `(jsonparse options)`

### `json-options-object-mode` (accessor)

`json-options-object-mode : json-options -> (U 'alist 'hashtable)`

The options' `object-mode`.

**Available from:** `(jsonparse options)`

### `json-options-null` (accessor)

`json-options-null : json-options -> (U Symbol Record)`

The options' `null`.

**Available from:** `(jsonparse options)`

### `json-options-indent` (accessor)

`json-options-indent : json-options -> Nonnegative-Fixnum`

The options' `indent`, at most 10.

**Available from:** `(jsonparse options)`

### `json-options-stream` (accessor)

`json-options-stream : json-options -> (U 'lines 'seq 'values)`

The options' `stream`.

**Available from:** `(jsonparse options)`

### `json-options-blank-lines` (accessor)

`json-options-blank-lines : json-options -> (U 'error 'skip)`

The options' `blank-lines`.

**Available from:** `(jsonparse options)`

## Errors: `(jsonparse error)`

### `&json-error` (condition type)

A `&error` for JSON that can't be read or written. Its fields are a reason
and an offset.

**Available from:** `(jsonparse error)`, `(jsonparse easy)`\
**Details:** [What it refuses](writer.md#what-it-refuses),
[Reading](easy.md#reading)

### `make-json-error` (procedure)

`make-json-error : Symbol (Option Nonnegative-Integer) -> &json-error`

Makes a `&json-error` from a reason and an offset, for code that raises
errors of its own.

**Available from:** `(jsonparse error)`

### `json-error?` (predicate)

`json-error? : Any -> Boolean`

Whether a value is a `&json-error`, a `&json-record-error` included.

**Available from:** `(jsonparse error)`, `(jsonparse easy)`

### `json-error-reason` (accessor)

`json-error-reason : &json-error -> Symbol`

Why: a code such as `unexpected-byte`, `not-found` or `unwritable-number`.

**Available from:** `(jsonparse error)`, `(jsonparse easy)`

### `json-error-offset` (accessor)

`json-error-offset : &json-error -> (Option Nonnegative-Integer)`

Where: in characters for a string read, in bytes otherwise. `#f` where
there was no input to point into: a value the writer refused, or a path
`json-ref` didn't find.

**Available from:** `(jsonparse error)`, `(jsonparse easy)`

### `&json-record-error` (condition type)

A `&json-error` for a bad record in a stream, with the record's number as a
third field. Its offset counts bytes from the stream's start.

**Available from:** `(jsonparse error)`, `(jsonparse easy)`\
**Details:** [Streams of values](easy.md#streams-of-values)

### `make-json-record-error` (procedure)

`make-json-record-error : Symbol Nonnegative-Integer Positive-Integer -> &json-record-error`

Makes a `&json-record-error` from a reason, an offset and a record number.

**Available from:** `(jsonparse error)`

### `json-record-error?` (predicate)

`json-record-error? : Any -> Boolean`

Whether a value is a `&json-record-error`.

**Available from:** `(jsonparse error)`, `(jsonparse easy)`

### `json-error-record` (accessor)

`json-error-record : &json-record-error -> Positive-Integer`

Which record was bad, counting from 1. Under `stream lines` it is the line
number.

**Available from:** `(jsonparse error)`, `(jsonparse easy)`

## The parser: `(jsonparse parser)`

### `make-json-handler` (procedure)

`make-json-handler : Symbol Procedure ... -> json-handler`

Makes a handler from name and procedure pairs. The names are `null`,
`boolean`, `number-chars`, `number-end`, `string-start`, `chars`, `escape`,
`string-end`, `object-start`, `key-start`, `key-end`, `object-end`,
`array-start` and `array-end`; give only the ones you need. An unknown name,
or a name given twice, raises.

**Available from:** `(jsonparse parser)`\
**Details:** [The handler](parser.md#the-handler)

### `json-handler?` (predicate)

`json-handler? : Any -> Boolean`

Whether a value is a handler.

**Available from:** `(jsonparse parser)`

### `make-json-stop` (procedure)

`make-json-stop : Symbol -> json-stop`

A value a handler procedure returns to end the parse with an error whose
code is the symbol, spelt `[a-z][a-z0-9-]*`.

**Available from:** `(jsonparse parser)`\
**Details:** [The handler](parser.md#the-handler)

### `json-stop?` (predicate)

`json-stop? : Any -> Boolean`

Whether a value is a stop, for a procedure that calls another and passes
its stop on.

**Available from:** `(jsonparse parser)`

### `make-json-parser` (procedure)

`make-json-parser : json-handler [Any [json-options]] -> json-parser`

Makes a parser that calls the handler's procedures, each with the context
first (default `#f`).

**Available from:** `(jsonparse parser)`\
**Details:** [Feeding and results](parser.md#feeding-and-results)

### `json-parser?` (predicate)

`json-parser? : Any -> Boolean`

Whether a value is a parser.

**Available from:** `(jsonparse parser)`

### `json-parser-feed!` (procedure)

`json-parser-feed! : json-parser Bytevector [Nonnegative-Fixnum Nonnegative-Fixnum] -> json-result`

Reads the bytes, all of them or those from start below end, calling the
handler as it goes. Bad input is an `error` result, never an exception.

**Available from:** `(jsonparse parser)`\
**Details:** [Feeding and results](parser.md#feeding-and-results)

### `json-parser-finish!` (procedure)

`json-parser-finish! : json-parser -> json-result`

Says the input has ended: `finished` if what was read is complete, or an
error.

**Available from:** `(jsonparse parser)`\
**Details:** [Feeding and results](parser.md#feeding-and-results)

### `json-parser-reset!` (procedure)

`json-parser-reset! : json-parser -> Void`

Makes the parser ready for a new document. It doesn't tell the handler.

**Available from:** `(jsonparse parser)`

### `json-parser-offset` (procedure)

`json-parser-offset : json-parser -> Nonnegative-Integer`

The bytes the parser has read since it was made or reset.

**Available from:** `(jsonparse parser)`

### `make-json-result` (procedure)

`make-json-result : (U 'need-input 'finished 'error) (Option Symbol) Nonnegative-Integer -> json-result`

Makes a result, for code that wraps parsers. The code is a symbol for an
error, and `#f` otherwise.

**Available from:** `(jsonparse parser)`

### `json-result?` (predicate)

`json-result? : Any -> Boolean`

Whether a value is a result.

**Available from:** `(jsonparse parser)`

### `json-result-status` (accessor)

`json-result-status : json-result -> (U 'need-input 'finished 'error)`

`need-input` when all was read and more may come, `finished` once the
input has ended complete, and `error` otherwise.

**Available from:** `(jsonparse parser)`\
**Details:** [Feeding and results](parser.md#feeding-and-results)

### `json-result-code` (accessor)

`json-result-code : json-result -> (Option Symbol)`

Why an error happened, such as `unexpected-byte`, and `#f` for any other
status.

**Available from:** `(jsonparse parser)`

### `json-result-offset` (accessor)

`json-result-offset : json-result -> Nonnegative-Integer`

Where an error is, in bytes; otherwise the bytes read so far.

**Available from:** `(jsonparse parser)`

## Strings and numbers: `(jsonparse string)`

### `make-json-assembler` (procedure)

`make-json-assembler : [json-options] -> json-assembler`

Makes an assembler, which joins the parts the parser hands a handler into
strings and numbers, under the options' number mode and digit limit.

**Available from:** `(jsonparse string)`\
**Details:** [The procedures](string.md#the-procedures)

### `json-assembler?` (predicate)

`json-assembler? : Any -> Boolean`

Whether a value is an assembler.

**Available from:** `(jsonparse string)`

### `json-assembler-chars!` (procedure)

`json-assembler-chars! : json-assembler Bytevector Nonnegative-Fixnum Nonnegative-Fixnum -> Void`

Adds a part of a string's or key's text, from `chars`.

**Available from:** `(jsonparse string)`

### `json-assembler-escape!` (procedure)

`json-assembler-escape! : json-assembler Nonnegative-Fixnum -> Void`

Adds a character given as a Unicode scalar value, from `escape`.

**Available from:** `(jsonparse string)`

### `json-assembler-string!` (procedure)

`json-assembler-string! : json-assembler -> String`

The string the parts make, from `string-end` or `key-end`. Empties the
assembler.

**Available from:** `(jsonparse string)`

### `json-assembler-number-chars!` (procedure)

`json-assembler-number-chars! : json-assembler Bytevector Nonnegative-Fixnum Nonnegative-Fixnum -> Void`

Adds a part of a number's text, from `number-chars`.

**Available from:** `(jsonparse string)`

### `json-assembler-number!` (procedure)

`json-assembler-number! : json-assembler -> (U Real json-number json-stop)`

The number the parts make, converted by the number mode, from
`number-end`. Empties the assembler. Gives a stop for `number-too-long` and
`number-out-of-range`.

**Available from:** `(jsonparse string)`\
**Details:** [Numbers](string.md#numbers)

### `json-assembler-reset!` (procedure)

`json-assembler-reset! : json-assembler -> Void`

Drops a half-built string or number. Reset it when you reset the parser.

**Available from:** `(jsonparse string)`

### `make-json-number` (procedure)

`make-json-number : String -> json-number`

Makes a `json-number` from a JSON number's text, such as `"-1.5e3"`. Text
that isn't one raises.

**Available from:** `(jsonparse string)`, `(jsonparse easy)`\
**Details:** [`json-number`](string.md#json-number)

### `json-number?` (predicate)

`json-number? : Any -> Boolean`

Whether a value is a `json-number`.

**Available from:** `(jsonparse string)`, `(jsonparse easy)`

### `json-number-text` (accessor)

`json-number-text : json-number -> String`

The number's text, exactly as it was read or made.

**Available from:** `(jsonparse string)`, `(jsonparse easy)`

## Values: `(jsonparse tree)`

### `make-json-builder` (procedure)

`make-json-builder : [json-options [(Any -> Any)]] -> json-builder`

Makes a builder, which turns bytes fed in pieces into a Scheme value. Given
a procedure, it hands it each top-level value and keeps none; `stream
values` needs one.

**Available from:** `(jsonparse tree)`\
**Details:** [The procedures](tree.md#the-procedures),
[A value at a time](tree.md#a-value-at-a-time)

### `json-builder?` (predicate)

`json-builder? : Any -> Boolean`

Whether a value is a builder.

**Available from:** `(jsonparse tree)`

### `json-builder-feed!` (procedure)

`json-builder-feed! : json-builder Bytevector [Nonnegative-Fixnum Nonnegative-Fixnum] -> json-result`

Reads the bytes, as the parser does. Bad input is an `error` result.

**Available from:** `(jsonparse tree)`

### `json-builder-finish!` (procedure)

`json-builder-finish! : json-builder -> json-result`

Says the input has ended. The value is ready once this says `finished`.

**Available from:** `(jsonparse tree)`

### `json-builder-value` (procedure)

`json-builder-value : json-builder -> Any`

The value built. Raises unless the last result was `finished`, and for a
builder that hands its values to a procedure.

**Available from:** `(jsonparse tree)`

### `json-builder-reset!` (procedure)

`json-builder-reset! : json-builder -> Void`

Makes the builder ready for the next document, and lets go of the value.

**Available from:** `(jsonparse tree)`

## Writing to a port: `(jsonparse writer)`

### `put-json` (procedure)

`put-json : Binary-Output-Port Any [json-options] -> Void`

Checks a value whole, then writes it as JSON in UTF-8. A value JSON can't
express raises a `&json-error` before a byte is written.

**Available from:** `(jsonparse writer)`\
**Details:** [What it writes](writer.md#what-it-writes),
[What it refuses](writer.md#what-it-refuses)

### `check-json` (procedure)

`check-json : Any [json-options] -> Void`

Raises what `put-json` would, and writes nothing.

**Available from:** `(jsonparse writer)`\
**Details:** [What it refuses](writer.md#what-it-refuses)

### `put-json-record` (procedure)

`put-json-record : Binary-Output-Port Any [json-options] -> Void`

Writes a value as one record of the options' `stream`: the value and `\n`,
with an RS byte first under `seq`. A `lines` record needs `indent` 0.

**Available from:** `(jsonparse writer)`\
**Details:** [Records of a stream](writer.md#records-of-a-stream)

## Streams in pieces: `(jsonparse sequence)`

### `make-json-reader` (procedure)

`make-json-reader : (Any -> Any) [(U #f (Symbol Positive-Integer Nonnegative-Integer -> Any))] [json-options] -> json-reader`

Makes a reader, which hands `on-value` each value of a stream fed in pieces.
Given `on-skip`, bad records are skipped, and `(on-skip code record
offset)` hears of each. `seq` needs `on-skip`, and `values` refuses it.

**Available from:** `(jsonparse sequence)`\
**Details:** [The procedures](sequence.md#the-procedures),
[Bad records](sequence.md#bad-records)

### `json-reader?` (predicate)

`json-reader? : Any -> Boolean`

Whether a value is a reader.

**Available from:** `(jsonparse sequence)`

### `json-reader-feed!` (procedure)

`json-reader-feed! : json-reader Bytevector [Nonnegative-Fixnum Nonnegative-Fixnum] -> json-result`

Reads the bytes, handing on each value whose record has ended. Offsets
count bytes from the stream's start.

**Available from:** `(jsonparse sequence)`

### `json-reader-finish!` (procedure)

`json-reader-finish! : json-reader -> json-result`

Says the stream has ended, and hands on its last value.

**Available from:** `(jsonparse sequence)`

### `json-reader-reset!` (procedure)

`json-reader-reset! : json-reader -> Void`

Makes the reader ready for a new stream, and lets go of any value it held.

**Available from:** `(jsonparse sequence)`

### `json-reader-record` (procedure)

`json-reader-record : json-reader -> Positive-Integer`

The record being read, counting from 1: inside `on-value` and `on-skip`,
the one handed over; after an error, the bad one.

**Available from:** `(jsonparse sequence)`
