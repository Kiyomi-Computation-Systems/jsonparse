# ADR-0015: The parser calls a handler of named procedures

- **Status:** Accepted
- **Date:** 2026-10-30
- **Scope:** what `(jsonparse parser)` calls, returns and refuses; the
  options record
- **Related:** ADR-0004, ADR-0005, ADR-0010, ADR-0011; plan M1

## Context

ADR-0010 sets the push parser's shape:

- it takes byte chunks and calls a handler;
- strings and numbers arrive as ranges of the caller's chunk;
- every result has a code and a byte offset;
- it exports only jsonparse's own names.

The plan asks for a record of procedures in YAJL's order. Slice 2 had to
settle what that record holds, and what the machine's events become on the
way to it:

- **The machine has one span for both keys and strings.** It also has one
  `escape` event, which carries a UTF-16 code unit.
- **A high surrogate's event comes before its low half is read,** and the
  machine rejects a broken pair only after that event.
- **byte-machine delivers an empty fragment for `""`,** and between two
  adjacent escapes.
- **Slice 3's assembler must be able to end a parse** with its own code,
  such as `number-too-long` (ADR-0011).
- **byte-machine refuses an out-of-range field** with a private condition
  type, which callers can't name.

## Decision

1. **A handler is made from names and procedures:**
   `(make-json-handler 'null p 'boolean q ...)`.
   - There are fourteen names, in YAJL's order: `null`, `boolean`,
     `number-chars`, `number-end`, `string-start`, `chars`, `escape`,
     `string-end`, `object-start`, `key-start`, `key-end`, `object-end`,
     `array-start` and `array-end`.
   - Every procedure is optional. One left out has no callback in the
     machine. The four container procedures are the exception: the stack's
     callbacks run whether or not they are given.
   - An unknown name, a name given twice, or a value that isn't a procedure
     raises, so a misspelt name can't switch a procedure off silently.
2. **Keys and strings share `chars` and `escape`.** `key-start` and
   `key-end`, or `string-start` and `string-end`, bracket them. The machine
   has one span for both, and every consumer already knows which one it is
   in.
3. **`escape` receives a Unicode scalar value.** The parser joins a
   surrogate pair and calls once, when the low half is read. The machine
   rejects a broken pair before that call, so no handler sees half a pair.
   This replaces the old note for slice 3, that its assembler must hold a
   high surrogate back.
4. **No text part is empty.** The parser drops byte-machine's empty
   fragments: `""` calls only `string-start` and `string-end`.
   - **A part may end inside a character.** Its other bytes arrive in the
     next part. The machine checks a part's bytes only as far as they go,
     so a consumer decodes text after joining its parts.
   - **A character that is never completed** ends the parse in an error,
     after the part holding its first bytes was delivered.
5. **A procedure's return value is ignored, except a stop.** Returning
   `(make-json-stop CODE)` ends the parse with the error CODE, at the stream
   offset where the procedure ran.
   - **Where a stop lands.** A stop from a procedure that receives parts
     lands wherever the feeds split the text. A stop from `number-end`,
     `string-end` or `key-end` lands at the same offset under every split.
   - **CODE** is spelt `[a-z][a-z0-9-]*`, byte-machine's rule.
   - **`json-stop?`** is exported, so a procedure that calls another can
     pass its stop on.
   - **A raise or a continuation escape** passes out of the feed. The
     parser refuses to be fed or finished until it is reset.
   - **A reset doesn't tell the handler.** Its caller resets whatever the
     context holds.
   - There is no pause in M1.
6. **A result has a status, a code and an offset.**
   - The status is `need-input`, `finished` or `error`.
   - The code is `#f` unless the status is `error`.
   - The offset is the error's offset, or else the bytes read so far.
   - A result is one record per feed.
7. **Options are one record, made by name and checked when made:**
   `(make-json-options 'depth-limit 64)`.
   - A bad option raises an R6RS assertion violation, which callers can
     name. The parser never reaches byte-machine's private refusal.
   - The depth limit runs from 0 to 65535 (ADR-0005). Later slices add their
     options to the same record (ADR-0006, ADR-0011, ADR-0014).
8. **Each procedure is called with the caller's context, not the parser.**
   `json-parser-offset` may be called from inside one, by a handler whose
   context holds its parser.

## Consequences

- **Slice 3's assembler gets scalar values,** and reports its limits with
  stops.
  - To give the same offset under every split, the digit limit counts
    digits in `number-chars`, copies at most the limit plus one, and stops
    from `number-end`.
  - It decodes text only after joining a text's parts.
- **Stop codes share a namespace with the grammar's codes.** A handler can
  choose any code, `unexpected-byte` included.
- **Events-only parsing allocates a fixed amount per feed and per
  finish,** none per byte, value or container. Measured on 2026-10-30 with
  `(sstats-bytes (statistics))` and all fourteen procedures bound:
  - **One feed plus a finish allocated 928 bytes,** at 5 KB of input and at
    5 MB. That figure includes the 160-byte statistics record the
    measurement itself makes.
  - **Most of a feed's cost is byte-machine's own result.** jsonparse's
    result record is a small part of it.
- **The other costs:**
  - an escape costs one or two range tests and a field lookup by name;
  - dropping empty fragments costs one comparison per text part;
  - each feed checks the parser's lifecycle once.
