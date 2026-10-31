# ADR-0016: The assembler joins text as UTF-8 and converts numbers at their end

- **Status:** Accepted
- **Date:** 2026-10-30
- **Scope:** what `(jsonparse string)` keeps, returns and refuses; the
  `number-mode` and `digit-limit` options
- **Related:** ADR-0006, ADR-0010, ADR-0011, ADR-0015; plan M1

## Context

- **ADR-0010** gives the low layer one growable buffer per parser for
  strings and numbers, in place of the prototype's port per token.
- **ADR-0011** sets the number modes and the digit limit, and puts
  conversion here.
- **ADR-0015** sets what the assembler hears:
  - escapes arrive as scalar values;
  - a text part may end inside a character;
  - a handler procedure ends a parse by returning a stop;
  - a parser reset doesn't reach the handler.

Measured on 2026-10-30 with the Guix container's Chez 10.4.1 (scratch
programs, not kept).

**Three ways to build a string from UTF-8 parts,** in MB/s of input:

| Way | 8-byte keys | 1 KB ASCII | 1 KB mixed |
|---|---|---|---|
| Join the bytes, then decode in Scheme | 135–139 | 208–209 | 209–213 |
| Decode in Scheme as the parts arrive | 162–166 | 240–260 | 282–293 |
| Join the bytes, copy them out, `utf8->string` | 303–306 | 884–911 | 817–838 |

The copy allocates 1 to 3 bytes more per input byte than decoding in
Scheme.

**`string->number`:**

- **It gets every edge right, in under a millisecond each:**
  - `1e999999999` is `+inf.0`;
  - `-1e-999999999` is `-0.0`;
  - `-0e999999999` is `-0.0`.
- **It agrees with `inexact` of the exact value on 200,000 random numbers,**
  and on the known hard cases. That exact value is built from the digits
  alone.

**Converting a megabyte of numbers through the assembler:**

| Numbers in the megabyte | `flonum` | `exact` | `text` |
|---|---|---|---|
| Integers of 3 digits | 25 ms | 31 ms | 18 ms |
| Integers of 17 digits | 14 ms | 17 ms | 7 ms |
| Integers of 1,000 digits | 122 ms | 123 ms | 4 ms |
| `0.` and 999 digits | 354 ms | 354 ms | 4 ms |
| `1.`, 995 digits and `e-330` | 389 ms | out of range | not measured |

The parser alone takes 2 to 6 ms per MB of the same input.

## Decision

1. **One assembler, one growable bytevector,** reused for every key, string
   and number. A valid parse never builds two texts at once.
   - The buffer doubles when it is full and never shrinks.
   - **Taking a string or a number empties the assembler,** whatever it
     returns or raises.
2. **The procedures that take parts are called as the handler's are.**
   `json-assembler-chars!`, `json-assembler-escape!` and
   `json-assembler-number-chars!` take the assembler first, then the
   handler procedure's own arguments. So an assembler can be a parser's
   context, and those three its procedures.
3. **A string's parts are joined as UTF-8 and decoded once,** when it is
   taken.
   - An escape is written into the buffer as UTF-8.
   - `json-assembler-string!` copies the bytes out and calls `utf8->string`
     on the copy. That is the fastest of the three ways measured.
4. **A number's digits are counted as its parts arrive.**
   - In `flonum` and `exact` modes the buffer keeps nothing past the
     limit's last digit, so a long number costs no memory.
   - Conversion waits for `json-assembler-number!`, called from
     `number-end`. Its stops land at the same offset however the input is
     split (ADR-0015).
5. **The modes follow ADR-0011:**
   - **`flonum`:** `string->number` reads it.
     - A plain number, with no fraction and no exponent, comes back an exact
       integer.
     - Any other comes back as the nearest flonum.
     - An infinite result is `number-out-of-range`.
   - **`exact`:**
     - every number is exact, by `string->number` with `#e`;
     - a number whose significand digits plus the absolute value of its
       exponent exceed the limit is `number-out-of-range`.
     - Every digit of the significand counts, leading zeros too, so `0e1001`
       is out of range under the default limit.
   - **`text`:** a `json-number` record holding the text. It has no limit.
   - **`number-too-long` wins** when both codes apply, as for `1e00009`
     under a limit of 5. The text past the limit was never kept.
   - **`json-assembler-number!` returns the stop.** The handler's
     `number-end` returns it to the parser, which ends the parse with its
     code.
6. **`json-number` lives in `(jsonparse string)`.**
   - **`make-json-number`** checks its text against JSON's number grammar,
     and keeps a copy.
   - **`json-number-text`** returns a copy.

   A record's text can't be changed through either, so the writer can write
   it as it is.
7. **Bad parts can't make a wrong kind of value:**
   - **A number's text is checked against JSON's number grammar** before it
     converts, and `json-assembler-number!` raises if it fails.
     `string->number` would read `1/2` or `#x10`. Past the digit limit no
     text is kept to check, so the answer is `number-too-long` whatever the
     parts were.
   - **An escape that isn't a scalar value raises.**
   - **A part's range is checked** as the parser checks a feed's.
   - **Bytes that aren't UTF-8 are left to `utf8->string`.** A parser never
     delivers them in a completed string.

   Each refusal is an R6RS assertion violation.
8. **`json-assembler-reset!` drops a half-built text.**
   - There is no start procedure, because a number has no start event.
   - A caller who resets a parser resets its assembler too (ADR-0015).
9. **`number-mode` and `digit-limit` join the options record.**
   - **`number-mode`** is `flonum` (the default), `exact` or `text`.
   - **`digit-limit`** is an exact integer from 1 to the greatest fixnum,
     default 1,000.
   - The parser ignores both.

## Consequences

- **A string allocates its result and one copy of its bytes.** The buffer
  grows only past the largest text seen so far.
- **The buffer keeps its largest size for the assembler's life.** One huge
  string keeps that much memory alive until the assembler is dropped.
- **`text` mode keeps every byte of a number,** so a huge number costs its
  length there.
- **ADR-0011's worst case was three times too low.** It said a megabyte of
  the longest numbers allowed converts in about 116 ms, measured on
  integers. Long fractions take 354 ms per MB, and the slowest shape found
  takes 389 ms.
- **The stop codes `number-too-long` and `number-out-of-range`** share the
  grammar's namespace (ADR-0015).
- **Some of this leans on Chez, which R6RS leaves open:**
  - **`string->number` gives `+inf.0` for `1e400`,** keeps `-0.0`, and
    rounds to the nearest flonum. `flonum` mode's results and its
    `number-out-of-range` rely on these. Guile and Racket are checked by
    hand (ADR-0003).
  - **Chez's `utf8->string` turns bytes that aren't UTF-8 into U+FFFD.**
    R6RS doesn't say what it does with them. Only an assembler fed by hand
    can hold such bytes.
- **M3:**
  - **An integer fast path** could convert plain numbers without a string.
  - **Most of the per-number cost** is the copy, the string and
    `string->number`.
