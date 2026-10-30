# ADR-0014: Streams of values are read and written in M1

- **Status:** Accepted, revised the same day
- **Date:** 2026-10-30
- **Scope:** reading and writing many JSON values from one stream
- **Related:** ADR-0005, ADR-0010, ADR-0011, ADR-0012; plan M1 and M4

> **Revision (2026-10-30, after slice 1).** Slice 1 found that the
> multiple-values bit needs no separator at all: it accepts `[]{}` and
> `"a""b"`, and reads `1-2` as 1 and −2. The owner chose what `values`
> accepts; Decision 2 now says it.

## Context

The owner wants JSON Lines and streaming JSON supported and tested. "Streaming"
covers three cases:

1. **One document arriving in chunks.** The push parser is built for this, and
   ADR-0012's chunking tests cover it.
2. **A stream of many documents:**
   - JSON Lines and NDJSON, one value per line;
   - RFC 7464 sequences, with each value after an RS byte (`#x1E`);
   - values separated by whitespace, which the prototype's settable `mode`
     bit already parses (plan §2).
3. **One huge document taken apart as it arrives,** such as each element of a
   large top-level array.

**What the specs say** (read 2026-10-30):

| | JSON Lines | NDJSON | RFC 7464 |
|---|---|---|---|
| Separator | `\n`; `\r\n` works because whitespace around a value is ignored | `\n`, and the parser MUST accept `\r\n` | each value starts with RS. The encoder writes `RS text LF`. Repeated RS bytes are ignored. |
| Blank line | invalid | the parser MAY ignore one. That MUST be documented and SHOULD be configurable. | not addressed |
| Final newline | recommended, not required. If present, it is the last byte. | the writer must write it | LF after each text |
| BOM | MUST NOT be included | not addressed | not addressed |
| Bad record | not addressed | the parser SHOULD raise an error | the parser SHOULD continue with the rest. A top-level number or `true`, `false` or `null` with no whitespace after it may have been cut off, and MUST be dropped. |

**Framing by byte is exact.** Neither `#x0A` nor `#x1E` can appear raw in a
JSON string, since control characters must be escaped. Neither can appear
inside a UTF-8 sequence, whose bytes are all `#x80` or above. So a newline or an
RS outside a value always ends a record.

## Decision

1. **M1 reads and writes cases 1 and 2.** Case 3 goes to M4 (item 6).
2. **There are three stream formats,** set with the options:
   - **`lines`** (JSON Lines and NDJSON):
     - Records end at `\n`.
     - Whitespace around a value is allowed, so a `\r` before the `\n` is
       too.
     - The final `\n` is optional.
     - A BOM is an error.
     - A blank or whitespace-only line is an error by default. An option skips
       blank lines.
   - **`seq`** (RFC 7464):
     - Records start at RS, and repeated RS bytes are ignored.
     - Bytes before the first RS form a bad record.
   - **`values`:** a run of values, with the machine's multiple-values bit.
     A stream with no framing can't be resynchronized, so the first error
     ends it.
     - **An object, array or string needs no separator after it:** its
       closing byte already ends it, so `{}{}`, `[][]` and `"a""b"` are
       three streams of two values.
     - **A top-level number or literal must be followed by whitespace or by
       the end of the input.** `1 -2` is two values, and `1-2` and
       `truefalse` are errors. A missing separator after a number is almost
       always a corrupted stream, and reading it as two values would hide
       that.
     - **An empty or whitespace-only stream holds no values.** It is not an
       error: an empty log is normal.
3. **Bad records:**
   - In `lines`, a bad record is an error by default. It carries:
     - the error's code;
     - its record number, counting from 1;
     - its byte offset in the stream.
   - In `lines`, an option skips bad records instead.
   - `seq` always skips bad records, as RFC 7464 asks.
   - **A skipped record is never silent.** Each one goes, with the same code,
     record number and offset, to a procedure the caller gives. That
     procedure may raise to stop the stream.
   - In `seq`, a possibly cut-off top-level number or literal is dropped and
     reported as `truncated`.
4. **The low layer frames without copying.**
   - `(jsonparse sequence)` takes chunks like the parser does.
   - It scans each chunk for the separator. It feeds the bytes before the
     separator to a reused parser or tree builder, and finishes the record at
     the separator.
   - A record split across chunks is never assembled into one buffer.
   - After a bad record in skip mode, the bytes up to the next separator are
     dropped.
   - The depth and digit limits apply to each record (ADR-0005, ADR-0011).
5. **The easy layer** (ADR-0010):
   - reads `lines` and `seq` streams from a binary port or a bytevector, as a
     fold over the values or as a list;
   - writes them:
     - `lines` as one compact value and `\n` per record. A writer can't
       pretty-print a record, since a newline would split it.
     - `seq` as RS, the value and LF;
   - raises `&json-error` with the record number added.
6. **M4 adds case 3** as a tree-builder option. It hands each value found at a
   chosen depth to a procedure, then drops it. Memory then stays bounded by one
   element, not the document.

## Consequences

- **M1 gains a seventh slice,** `(jsonparse sequence)`, with its easy-layer
  procedures. The multiple-values bit moves from M4's option list into M1.
- **Slice 7 changes the grammar.** Under the multiple-values bit, a
  top-level number or literal must then be followed by whitespace or the end
  of the input. Slice 1's `machine` suite pins today's behaviour, so those
  cases change with it. Slice 7 also makes an empty stream give no values,
  in the grammar or in `(jsonparse sequence)`.
- **The scan for separators costs a loop over every byte in Scheme.** The
  slice measures it. If the cost matters, the grammar can learn the separator
  through a `mode` bit instead.
- **The tests come mostly from ADR-0012's in-house cases.** Each case cites its
  spec row above. SRFI 180's five files are read as given, and its broken
  record is reported and skipped.
- **Chunking tests cover the separators:** a split before, on and after every
  `\n`, `\r` and RS.
