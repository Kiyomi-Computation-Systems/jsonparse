# ADR-0019: The easy layer reads and writes whole documents, and compares values as JSON

- **Status:** Accepted
- **Date:** 2026-11-07
- **Scope:** `(jsonparse easy)`: its procedures, errors and offsets;
  `check-json` in `(jsonparse writer)`
- **Related:** ADR-0006, ADR-0010, ADR-0016, ADR-0017, ADR-0018; uriparse's
  `(uri easy)`

## Context

- **ADR-0010 names the easy layer's procedures:**
  - reading: `string->json`, `bytevector->json` and `read-json`;
  - writing: `json->string`, `json->bytevector` and `write-json`;
  - conveniences: `json-ref`, `json=?` and `json-null?`.

  Errors raise `&json-error`, its offset in characters for a string and in
  bytes otherwise. Options are an optional last argument.
- **ADR-0006 asks for an equality that works on hashtables,** which
  `equal?` can't compare. Under hashtables the last duplicate key wins
  (ADR-0017).
- **ADR-0018:** `put-json` checks a value whole before writing it, and its
  refusals have the offset `#f`.
- **ADR-0016:** Chez's `utf8->string` drops a leading U+FEFF.
- **uriparse's easy layer** counts a character offset as the bytes before
  it that begin a character.

Measured on 2026-11-07 with the Guix container's Chez 10.4.1 (scratch
programs, not kept).

**Costs,** on ADR-0018's documents of about 1 MB and one of kana strings,
each figure the best of seven runs, in ms:

| Document | Read bytes to a tree | `string->utf8` | Count characters | Read a port: 4 KiB at a time | 16 KiB | 64 KiB | Write | `utf8->string` |
|---|---|---|---|---|---|---|---|---|
| Records of 6 members | 16.7 | 2.0 | 1.7 | 16.8 | 16.2 | 16.1 | 8.3 | 1.6 |
| Integers to 6 digits | 20.6 | 1.9 | 1.6 | 20.8 | 20.7 | 20.8 | 7.1 | 1.6 |
| Strings of 16 letters | 7.2 | 2.0 | 1.7 | 7.5 | 7.3 | 7.2 | 4.0 | 1.7 |
| Strings of 8 kana | 5.8 | 1.1 | 1.9 | 5.8 | 5.8 | 5.8 | 2.1 | 1.8 |
| `true`s | 8.2 | 2.0 | 1.6 | 8.3 | 8.2 | 8.2 | 3.1 | 1.7 |

- **Count characters** counts the bytes that begin a character, up to the
  end of the document.
- **A new builder per document** of 19 bytes costs 4,448 bytes and 1.5 µs.
  A reused one costs 944 bytes and 0.5 µs.

**Where errors land on valid UTF-8:**
- the inputs were 346 corpus files that are valid UTF-8, and 40,000
  mutations of them, each of 1 to 4 characters inserted, deleted or
  replaced;
- under five option sets, they gave 185,179 errors, of every code but
  `invalid-utf8`;
- every offset was a character's first byte, or the end of the input.

## Decision

1. **Reading takes one whole document** and returns what `(jsonparse
   tree)` builds from it, with a new builder each call:
   - `(string->json s [options])` encodes S with `string->utf8` and reads
     the bytes;
   - `(bytevector->json bv [options])` reads BV;
   - `(read-json port [options])` reads a binary input port to its end,
     16 KiB at a time. It stops reading at the first error, so the port
     has been read to the end of the 16 KiB that hold it.
2. **Bad input raises `&json-error`:**
   - its reason is the parser's code, such as `unexpected-byte` or
     `number-too-long`;
   - its offset counts characters for a string: the characters before the
     byte offset. It counts bytes for a bytevector, and for a port from
     where the port was;
   - its who is the procedure called, and its message reads
     `unexpected-byte at character 12`, or `at byte 12`. Its irritants are
     an empty list, as R6RS's `error` gives with none, so a handler can
     always ask for them.
   - It is raised non-continuable, as every raise in this layer is.
3. **Writing is `put-json`'s:**
   - `(json->bytevector v [options])` and `(json->string v [options])`
     write to a bytevector port. `json->string` decodes the bytes with
     `utf8->string`, which is safe: a JSON text starts with `"`, `{`, `[`,
     `-`, a digit or a letter, never U+FEFF;
   - `(write-json port v [options])` writes to a binary output port;
   - a refusal raises `put-json`'s `&json-error` again, with the same
     reason, offset, message and irritants, and the easy procedure as its
     who;
   - **only the writer's own refusals are relabelled.** `write-json` runs
     `check-json` under the new who, then `put-json` outside it, so what
     the caller's port raises from its `write!` passes through as it was
     raised. The other two write to a port of their own, which runs no
     caller code.
4. **`(json-ref v step ... ['default d])` follows a path:**
   - a string steps into an object, alist or hashtable, to the member with
     that key. In an alist that is the last such member, as `object-mode
     hashtable` would keep;
   - a hashtable keyed by `string=?` or `equal?` is looked up with
     `hashtable-ref`. Any other is searched by key text;
   - an exact nonnegative integer steps into an array;
   - **a step that finds no value raises `&json-error`:**
     - the reason is `not-found` and the offset `#f`;
     - the irritant is the steps taken, the failing one last.

     The step may name a missing key or an index past the end, or step
     into a value of the wrong kind;
   - **a call that ends with the symbol `default` and a value gives that
     value instead of `not-found`,** as it is, uncopied:
     `(json-ref v "users" 0 "name" 'default "anon")`. Nothing else changes:
     - a value that is found is returned, even `#f` or the null;
     - with no steps, `v` is returned;
     - a malformed list or a duplicate key text still raises;
     - a bad step is still an assertion violation;
     - so is a `default` with no value after it.

     A symbol is never a step, so the marker can't be mistaken for one.
     It follows the name-and-value style of `make-json-options`. The
     owner chose this form on 2026-11-07;
   - **it looks only for the step's key,** and passes over members with
     other keys, strings or not. It raises `put-json`'s reasons only where
     it can't answer:
     - a list it searches that isn't a proper list of pairs is
       `unwritable-value`;
     - a hashtable it searches that holds two keys with the step's text is
       `unwritable-key`;
   - **every step is checked before the walk starts.** One that is neither
     a string nor an exact nonnegative integer raises an assertion
     violation, even after a step that would find no value.
5. **`(json=? a b [options])` asks whether two values mean the same
   JSON:**
   - **it first checks both values as `put-json` would,** and raises its
     `&json-error`, with `json=?` as the who. So `json=?` is defined on
     the values `put-json` writes, as `string=?` is on strings;
   - **objects,** alists or hashtables in any mix, are equal when they hold
     the same keys, by text, and each key's values are `json=?`. Member
     order doesn't matter: RFC 8259 calls an object unordered. An alist's
     value for a key is its last member's, as for `json-ref`;
   - **arrays** are equal when they have the same length and their
     elements are `json=?` in order;
   - **strings** are compared by `string=?`;
   - **numbers** are equal when their exact values are:
     - a `json-number`'s value is its text's, and a flonum's is its exact
       binary value;
     - so `1`, `1.0` and the `json-number` `"1e0"` are all equal;
     - but the flonum `0.1` isn't equal to the `json-number` `"0.1"`;
     - a `json-number` is compared as a sign, digits and an exponent, in
       time linear in its text. An exponent may have any number of digits
       in `text` mode, and converting one with `string->number` takes time
       quadratic in them. So an exponent of more than 19 digits is added
       to as text;
   - **anything else,** `#t`, `#f` and the null, is compared by `eqv?`;
   - **give it the options the values were read with.** Its check uses
     their null and depth limit, so a value read with a deeper limit or
     another null is refused under the defaults.
6. **`(json-null? v [options])`** is `eq?` to the options' null.
7. **`(check-json v [options])` joins `(jsonparse writer)`'s exports.** It
   raises what `put-json` would for V under the options, with `check-json`
   as the who, and writes nothing. It is the walk `put-json` already runs
   before writing.
8. **One import does for whole documents.** `(jsonparse easy)` re-exports:
   - `&json-error`, `json-error?`, `json-error-reason` and
     `json-error-offset`;
   - `make-json-options` and `json-options?`;
   - `make-json-number`, `json-number?` and `json-number-text`.
9. **An argument of the wrong type raises an assertion violation** whose
   who is the easy procedure: easy checks types before it calls the low
   layer. R6RS has no test for a closed port, so a closed port fails later,
   in the R6RS procedure that reads or writes it.

**Choices not taken:**
- **Numbers by text, as slice 4's notes had it.** `"1.0"` and `"1"` would
  differ, and so would a document and its own `exact` reading.
- **Numbers by `eqv?`.** `1` and `1.0` would differ, though both write
  JSON numbers of one value.
- **Members in order, every duplicate counted.** That is `equal?` on
  alists, and it makes `json=?` disagree with `object-mode hashtable`.
- **For `json-ref`'s default:**
  - a default as the last argument can't be told from a step when it is
    a string or an integer;
  - a second procedure, such as `json-ref/default`, is one more name to
    learn for the same walk;
  - a path given as one list would change every existing call.

## Consequences

- **`string->json` costs a copy of its input in UTF-8,** 1 to 2 ms per MB,
  9 to 28% of reading. An error then costs a count of characters up to its
  offset, under 2 ms per MB.
- **`json->string` costs a decoding,** 1.6 to 1.8 ms per MB, on top of
  writing's 2 to 8.
- **`read-json`'s chunk size matters little:** 4 KiB is within 5% of
  64 KiB, and 16 KiB within 1.5%.
- **A builder per call** costs about 1 µs and 3.5 KB more than reusing
  one. For many small documents, reuse a builder from `(jsonparse tree)`,
  or read them as a stream with `(jsonparse sequence)` (slice 7).
- **`read-json` also makes a 16 KiB buffer per call.** Measured in the
  review, on a 19-byte document, it costs 4 µs and 21,216 bytes. That
  compares with 2 µs and about 4,600 bytes for `string->json` and
  `bytevector->json`.
- **`write-json` checks a value twice,** once for its own refusal and once
  in `put-json`. That costs one more check pass, 0.2 to 0.9 ms per MB
  (ADR-0018).
- **`read-json` reads a port to its end.** A port of many values is
  `(jsonparse sequence)`'s (ADR-0014).
- **A string starting with U+FEFF is read as the bytes `EF BB BF`,** which
  JSON doesn't allow before a value: `unexpected-byte` at character 0, as
  `bytevector->json` gives at byte 0. JSONTestSuite's
  `i_structure_UTF-8_BOM_empty_object.json` is rejected either way.
- **The character offset relies on the parser's errors landing on a
  character's first byte** for valid UTF-8, as measured above. The tests
  check it on every error they raise.
- **`json=?` and `json-ref` agree with `object-mode hashtable`.** A document
  read with alists and with hashtables gives two values that are `json=?`,
  and `json-ref` gives the same answers on both.
- **Across number modes:**
  - a document read in `text` mode and in `exact` mode gives values that
    are `json=?`, within the digit limit;
  - in `flonum` mode, a number whose decimal isn't exactly a flonum, such
    as `0.1`, isn't `json=?` to its `exact` or `text` reading.
- **`json=?` walks each value twice,** once to check and once to compare.
  For each pair of objects it compares, it builds a table of members, but
  not for a hashtable keyed by `string=?`.
  - On the documents above, it takes 2.3 ms for the integers, 11% of
    reading them. The records take 5.9 to 7.2 ms, alists, hashtables or
    one of each: 35 to 43% of reading them.
  - In the review, on ADR-0017's single object of 90,000 members, it took
    24 ms for two alists against 21 to read one. Two hashtables took
    56 ms, since the check sorts each table's keys, as `put-json`'s does.
- **`json=?` can't see duplicate keys.** `{"a":1,"a":2}` is `json=?` to
  `{"a":2}`, though `put-json` writes both members. To test that a writer
  emits no duplicates, compare alists with `equal?`.
- **A `json-number`'s exponent costs `json=?` time linear in its digits.**
  An exponent of 200,000 digits took 6 s through `string->number`; added
  to as text, it takes 1 ms.
