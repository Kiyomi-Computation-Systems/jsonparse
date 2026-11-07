# ADR-0018: The writer checks a value whole, then writes it to a binary port

- **Status:** Accepted
- **Date:** 2026-11-06
- **Scope:** what `(jsonparse writer)` writes and refuses; `&json-error`
  and `(jsonparse error)`; the `indent` option
- **Related:** ADR-0006, ADR-0007, ADR-0010, ADR-0011, ADR-0014, ADR-0017;
  plan M1

## Context

- **ADR-0007** has the writer refuse what JSON can't express: NaN, the
  infinities, exact fractions with no finite decimal, symbols other than
  the null in force, non-string keys and improper lists. Its escaping is to
  be correct by construction.
- **ADR-0010** puts the writer in the low layer: values to UTF-8 on a binary
  port. It defines `&json-error` below the easy layer, so the writer can
  raise it.
- **ADR-0011** sets how numbers are written. **ADR-0014** writes `lines`
  records compact.
- **ADR-0017** keeps `null` a symbol or a non-opaque record, never `'()`,
  so one writer can take alists and hashtables under any options.
- **A Chez string holds only Unicode scalar values,** so every string has a
  UTF-8 encoding.

Measured on 2026-11-06 with the Guix container's Chez 10.4.1 (scratch
programs, not kept).

**Chez's `number->string` on flonums:** of 299,859 finite flonums from
random bit patterns, plus the edge cases:
- every one is JSON once a `|` suffix is cut;
- each reads back `eqv?`;
- 152 had the suffix, all of them subnormals, such as `5e-324|1`.

**Writing against reading,** the same documents of about 1 MB as
ADR-0017's, each figure the best of seven runs, in ms:

| Document | Read to a tree | Write: check | Write: emit | Write: both | Emit to a buffer, then copy |
|---|---|---|---|---|---|
| Records of 6 members | 16.5 | 0.7 | 7.5 | 8.2 | 7.5 |
| Integers to 6 digits | 21.0 | 0.7 | 6.3 | 7.0 | 6.3 |
| Flonums in [0, 1) | 30.0 | 0.4 | 35.6 | 37.7 | 37.3 |
| Strings of 16 letters | 7.3 | 0.2 | 3.7 | 3.9 | 3.8 |
| Strings with escapes | 10.9 | 0.2 | 4.9 | 5.2 | 5.2 |
| `true`s | 8.2 | 0.9 | 2.2 | 3.1 | 2.3 |

- **Check** walks the value and touches no port. **Emit** writes it.
- **Emit to a buffer, then copy** is the other way not to leave half a
  value on the port: write into memory, then put it on the port at once.
- **Integers went through `number->string` at first,** at 28.0 ms. Writing
  a fixnum's digits directly takes 6.3.

## Decision

1. **The low layer's writer is `(put-json port value [options])`,** named
   after R6RS's `put-u8` and `put-bytevector`. The port is a binary output
   port, and the bytes are UTF-8.
2. **It writes what `(jsonparse tree)` builds, under any options:**
   - **objects:** alists, every duplicate written in order, and hashtables,
     whatever `object-mode` is. `'()` is `{}`. A hashtable's members go in
     the order of their keys by `string<?`. That is code point order, so
     the output doesn't depend on how the table was filled.
   - **arrays:** vectors.
   - **strings:**
     - `"` and `\` are escaped;
     - so is each control character below U+0020: as `\b \f \n \r \t`, or
       as `\u00XX` in lowercase hex;
     - every other character is written as itself, in UTF-8: U+007F, U+2028
       and U+2029 included.
   - **numbers,** as ADR-0011 says:
     - an exact integer in decimal. A fixnum's digits are written
       directly, through a buffer sized from `(greatest-fixnum)`'s digits,
       since R6RS sets only a least width for fixnums;
     - a finite flonum by `number->string`, less any `|` suffix;
     - an exact non-integer as its exact decimal, when its denominator has
       no prime factor but 2 and 5;
     - a `json-number` as its text.
   - **`#t`, `#f`,** and **the options' null,** recognised by `eq?`.
3. **It refuses anything else with a `&json-error`.** The error's offset is
   `#f`. A who, a message and one irritant come with it. The irritant is
   the part refused: the number, the key, the member that isn't a pair, the
   list, the value, or the container that went too deep. The reasons:
   - **`unwritable-number`:** NaN, an infinity, a complex number, or a
     fraction with no finite decimal;
   - **`unwritable-key`:** an object member whose key isn't a string, or a
     hashtable holding two keys with the same text. Only a table not keyed
     by `string=?` can, and it has no order for them but its own;
   - **`unwritable-value`:** anything else. That includes a symbol other
     than the null in force, a list that isn't an alist (improper, circular,
     or with a member that isn't a pair), and a record that is neither a
     `json-number` nor the null;
   - **`nesting-too-deep`:** more containers open at once than the options'
     `depth-limit`, as the reader would refuse. A value that contains
     itself ends here too.
4. **A value is checked whole before a byte is written,** so a refusal
   leaves the port as it was.
   - The check is the same walk as the writing, with output off.
   - Its cost is measured above, 0.2 to 0.9 ms per MB.
   - Writing to a buffer first would skip the check, saving that much
     time, but would hold the whole output in memory. A low-layer caller
     writing a large value to a socket shouldn't pay that.
5. **`&json-error` lives in `(jsonparse error)`.**
   - It is an `&error`, not a `&violation`: the value was wrong, not the
     program.
   - It has a `reason` and an `offset`. The offset is `#f` for the writer;
     for the easy layer's reading it will count characters or bytes
     (ADR-0010).
   - **This settles ADR-0010's two rules.** "Never raises on bad input" is
     about reading: bad bytes are a result. A value that JSON can't express
     comes from the program, and the writer raises.
6. **`indent` joins the options.** It is an exact integer from 0, the
   default, to 10, the most JavaScript's `JSON.stringify` indents by. A
   larger cap would let one option ask for billions of spaces a level.
   - **0 is compact,** with no spaces at all, as `lines` records need
     (ADR-0014).
   - **More than 0 puts each member on its own line,** indented that many
     spaces a level, with a space after each key's colon.
   - An empty container stays `[]` or `{}`, and there is no newline at the
     end.
7. **The writer reads `null`, `depth-limit` and `indent`,** and ignores the
   reader's options. It doesn't apply `digit-limit` or the reader's range.
   A number past either is written, and a reader in `flonum` or `exact`
   mode refuses it. Examples:
   - more digits than the limit;
   - a `json-number` such as `1e400`, out of a flonum's range;
   - `1e1000` in `exact` mode.

   In `text` mode there is no limit.

## Consequences

- **Writing is faster than reading, but for flonums.** Chez's flonum
  printer takes about 36 ms per MB.
- **What the writer writes, a reader with the same options reads back,**
  within the digit limit and the range:
  - exact numbers in `exact` mode and flonums in `flonum` mode are
    `eqv?`;
  - a `json-number` keeps its text in `text` mode;
  - under `hashtable` the last duplicate wins, as on any reading.
- **Reading, writing and reading again isn't always a fixed point at a
  small digit limit.** Under `digit-limit 4`, `123e5` reads as the flonum
  `12300000.0`, which writes back as 9 digits.
- **Output is deterministic:** the same value gives the same bytes, a
  hashtable included.
- **A laid-out value grows with the square of its depth:** each level adds
  its indent to every line below it.
- **A circular list costs one `list?` walk per alist,** in both passes.
- **The check pass doubles some work:** a hashtable is sorted twice, and a
  fraction's denominator factored twice.
- **Some of this leans on Chez:** `number->string`'s flonum text and its
  `|` suffix. Guile and Racket are checked by hand (ADR-0003).
- **Measured on 2026-11-06, the check pass alone takes 0.2 to 0.7 ms per
  MB** in the review's run, against 0.2 to 0.9 above.
- **M3:** a faster flonum printer would speed up the slowest case.
