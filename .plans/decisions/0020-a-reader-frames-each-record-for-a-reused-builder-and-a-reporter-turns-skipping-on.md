# ADR-0020: A reader frames each record for a reused builder, and a reporter turns skipping on

- **Status:** Accepted
- **Date:** 2026-11-07
- **Scope:** `(jsonparse sequence)`; the `stream` and `blank-lines`
  options; the grammar under the `mode` bit; the builder's EACH;
  `put-json-record`; `&json-record-error`; the easy layer's stream
  procedures
- **Related:** ADR-0005, ADR-0010, ADR-0011, ADR-0014, ADR-0015, ADR-0017,
  ADR-0018, ADR-0019; RFC 7464

## Context

- **ADR-0014 decides what streams M1 reads and writes:** `lines`, `seq` and
  `values`, set with the options. In `lines` a bad record is an error by
  default, with its code, record number and byte offset. `seq` skips bad
  records, and each skipped one goes to a procedure the caller gives. The
  low layer frames by byte, feeding a reused parser or builder, and never
  copies a record whole.
- **ADR-0014's revision** says what `values` accepts. Under the `mode` bit
  today, `1-2` is two numbers and an empty stream is `unexpected-eof`.
- **RFC 7464** (read 2026-11-07):
  - its parsing grammar is `*(1*RS possible-JSON)`, so bytes before the
    first RS belong to no element;
  - repeated RS bytes make no empty elements;
  - a parser SHOULD go on after an element that fails to parse;
  - a top-level number, or a text that might be `true`, `false` or `null`,
    needs whitespace after it, or it MUST be dropped.
- **The owner's answers, 2026-11-07:**
  - giving the reporting procedure is what turns skipping on, with no
    separate option;
  - the easy layer's procedures are named `*-json-sequence`.
- **byte-machine keeps a parser's field initials across a reset,** so a
  `mode` given when the parser is made lasts, as `depth-left` already does.

Measured on 2026-11-07 with the Guix container's Chez 10.4.1 (scratch
programs, not kept). The values are ADR-0018's kinds, about 1 MB of each,
read whole with one feed; each figure is the best of seven runs, in ms:

| Values | Records | One array | `lines` | `seq` | `values` | Scan for `\n` |
|---|---|---|---|---|---|---|
| Records of 6 members, 92 bytes | 10,895 | 17.2 | 19.0 | 19.3 | 16.0 | 1.5 |
| Integers to 6 digits | 145,153 | 21.5 | 45.8 | 45.8 | 21.1 | 1.8 |
| Strings of 16 letters | 52,632 | 7.5 | 17.1 | 17.3 | 7.4 | 2.0 |
| `true`s | 200,001 | 8.3 | 34.8 | 36.3 | 7.3 | 1.6 |

- **A record of `123456`** costs 944 bytes and 0.32 µs in `lines` or `seq`,
  most of it the builder's reset, feed and finish. In `values` it costs
  129 bytes and 0.14 µs.
- **Calling the caller's procedure inside `dynamic-wind`** costs 64 bytes
  and 8 ns a call.
- **`get-bytevector-some`** answers 8,192 bytes at a time from Chez's file
  and bytevector ports. Reading 1 MB of records through it took the same
  time as through a 16 KiB buffer, and allocated 5% more.

## Decision

1. **The grammar under the `mode` bit** (ADR-0014's revision):
   - **a top-level number or literal needs whitespace or the end of the
     input after it.** The next byte is otherwise `unexpected-byte`, so
     `1-2` and `truefalse` fail at 1 and 4. Without the bit nothing
     changes: the same byte is `trailing-garbage`;
   - **an empty or whitespace-only stream holds no values:** finish answers
     `finished`, with no events;
   - **a literal is announced at its last letter, and a number once the
     byte after it is read, or at the finish,** since `12` might go on.
     Either comes before that byte is checked. So `1-2` gives 1, then the
     error, which belongs to the record starting at the `-`.
2. **Two options join the record:**
   - **`stream`:** `lines`, the default, `seq` or `values`. The parser reads
     one value, unless `stream` is `values`, which sets the bit;
   - **`blank-lines`:** `error`, the default, or `skip`. It is read under
     `lines`, and giving it under another stream raises.
3. **A builder may hand on each top-level value:**
   - `(make-json-builder options each)` hands EACH every top-level value
     as soon as it is complete, and keeps none;
   - EACH's answer is ignored, unless it is a stop, which ends the parse as
     a handler procedure's does;
   - `json-builder-value` raises for such a builder;
   - `stream values` without EACH raises: a builder can't keep many values.

   A value is top-level when no container is open, which is when the mark
   is 0. So an error resets the mark, the line slice 4 removed as dead
   code.
4. **`(jsonparse sequence)` frames the records:**
   - `(make-json-reader on-value [on-skip] [options])` makes a reader.
     `json-reader-feed!`, `json-reader-finish!` and `json-reader-reset!`
     work as the builder's do, and answer the parser's results;
   - **in `lines` and `seq`,** it scans each chunk for the separator. It
     feeds the bytes between to one reused builder, and finishes the
     builder at the separator. The bytes are never copied;
   - **in `values`,** one builder with EACH reads the whole stream;
   - **each value goes to ON-VALUE** once its record ends;
   - **offsets count bytes from the start of the stream.** Records are
     numbered from 1 in the order they start:
     - `lines`: one per line, blank ones included, so the number is the
       line number;
     - `seq`: one per RS, repeated RSs making none; bytes before the first
       RS are a record;
     - `values`: one per value.

     `json-reader-record` gives the record being read: inside the
     procedures, the record handed over; after an error, the bad one.
5. **A bad record:**
   - **has the parser's code,** or one of the reader's own:
     - `blank-line`, under `lines` unless `blank-lines` is `skip`, at the
       line's end. Under `skip` a blank line isn't bad: it is dropped
       without a call to ON-SKIP;
     - `truncated`, under `seq`, for a record whose first byte other than
       whitespace starts a number or a literal, and whose last byte isn't
       whitespace. Its offset is the record's end. A record that fails to
       parse keeps its parser's code;
     - `unexpected-byte`, under `seq`, for bytes before the first RS, at
       the first of them, whitespace included.

     A `seq` record of whitespace alone fails to parse, as `unexpected-eof`
     at its end;
   - **with no ON-SKIP, ends the stream** with an error result;
   - **given ON-SKIP, is skipped,** and `(on-skip code record offset)` is
     called. A record found bad partway is dropped up to its separator.
     `seq` needs ON-SKIP, and `values` refuses it, since nothing marks where
     a value would begin. This revises ADR-0014's decision 3, which turned
     skipping on with an option: the owner chose this form on 2026-11-07.
6. **The reader's procedures run as a handler's do** (ADR-0015):
   - their answers are ignored;
   - a raise or an escape passes out of the feed or finish, and the reader
     then raises until it is reset;
   - feeding, finishing or resetting it from inside them raises.

   `dynamic-wind` tells an escape from a return.
7. **`(jsonparse parser)` exports `make-json-result`,** which checks its
   arguments, so the reader answers with the parser's own results.
8. **`(put-json-record port v [options])` joins `(jsonparse writer)`.** It
   checks V whole, then writes it as one record of the options' stream:
   - `lines`: the value, then `\n`. A newline inside would split the
     record, so `indent` must be 0, or it raises an assertion violation;
   - `seq`: RS, the value, then `\n`;
   - `values`: the value, then `\n`.
9. **`&json-record-error`** is a `&json-error` with the field `record`, in
   `(jsonparse error)`.
10. **The easy layer reads and writes streams:**
    - `(read-json-sequence port [report] [options])` and
      `(bytevector->json-sequence bv [report] [options])` give a list;
    - `(fold-json-sequence kons knil port [report] [options])` calls
      `(kons value acc)`, SRFI 1's order;
    - a port is read with `get-bytevector-some`, so a value goes on once
      its record has come, not once 16 KiB have;
    - **a bad record raises a `&json-record-error`,** shaped as ADR-0019's
      errors are. Its message reads `unexpected-byte at byte 12 in record
      3`;
    - **given REPORT, bad records are skipped,** and REPORT gets the
      `&json-record-error` that would have been raised. Raising it stops
      the stream;
    - `(write-json-sequence port values [options])` writes each value with
      `put-json-record`, relabelling only the check, as `write-json` does.
      A refused value raises before any byte of its record, and the
      records before it stay written;
    - `(json-sequence->bytevector values [options])` writes to a
      bytevector port of its own, which runs no caller code, so it
      relabels the whole write, as `json->bytevector` does;
    - `string->json`, `bytevector->json` and `read-json` refuse `stream
      values`, which holds many values.

**Choices not taken:**
- **An option to turn skipping on, beside the procedure,** as ADR-0014
  had it: two settings for one behaviour. The owner chose.
- **A name for each format,** such as `read-json-lines`: ADR-0014 sets the
  format with the options.
- **One parser with the bit across all of a `lines` stream,** checking
  that each line ends one value: it saves the cost per record, but needs
  a reset at every bad line, and a check at each newline of what ended
  there. ADR-0014 keeps it as the way out if that cost matters.
- **A record number in every `json-result`:** a parser's results would
  carry a field they never use.
- **Holding a top-level number or literal until the byte after it is
  checked,** so that `1-2` gives no value: that needs a grammar event for
  whitespace.
- **`trailing-garbage` for `1-2` under the bit:** under the bit more values
  may follow, and `1 x` was already `unexpected-byte`.
- **A 16 KiB buffer for ports,** as `read-json` has: a value would wait
  for 16 KiB or the end.
- **A fold over a bytevector:** `open-bytevector-input-port` gives one.

## Consequences

- **Each record of `lines` or `seq` costs a builder's reset, feed and
  finish:** 0.13 to 0.19 µs more than the same values in one array. On
  records of 92 bytes that is 10 to 12%. On values of 5 to 19 bytes,
  reading takes 2.1 to 4.4 times as long as one array.
- **The scan for separators is 4 to 12% of reading `lines`.**
- **`values` reads at the speed of one array,** 0.88 to 0.99 times as long.
- **The depth and digit limits apply to each value** (ADR-0005,
  ADR-0011). In `lines` and `seq` each record is a new parse. In `values`
  the depth is back to 0 between values, and each number's digits are
  counted on their own.
- **A reader keeps the largest string buffer it has needed** until it is
  dropped, across resets, as an assembler does (ADR-0016). After one
  record holding a 1 MB string, a reader holds about 1 MB more.
- **A reader whose ON-VALUE raised holds the value it was handed** until
  it is reset, under `lines` and `seq`, as a builder does (ADR-0017).
  Under `values` the builder has cleared its slot first.
- **Re-entering a continuation captured inside ON-VALUE or ON-SKIP isn't
  supported, and isn't detected.** The reader takes the re-entry for a new
  call. After a reset, it resumes the old feed on the new stream.
- **A raw newline or RS ends a record, even inside a string,** where JSON
  forbids it raw. Both halves are then bad records.
- **Under `values`, a corrupt stream can deliver values before its
  error,** as any streaming reader does: `1 2x` gives 1 and 2, then
  `unexpected-byte` at 3 in record 3.
- **The last line of a `lines` stream may lack its newline,** as JSON Lines
  allows, so a last record cut short after a number's digits reads as a
  shorter number. Only `seq` detects truncation.
- **`seq` is strict about what precedes the first RS:** a leading newline
  or byte order mark is a bad record, reported and skipped.
- **Reading a port allocates its bytes once more,** in the bytevectors
  `get-bytevector-some` returns.
- **`write-json-sequence` walks each value three times:** once for its
  relabelled check, and twice in `put-json-record`.
