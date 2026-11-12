# ADR-0027: Short numbers convert from the assembler's buffer

- **Status:** Accepted. The owner chose this design on 2026-11-11.
- **Date:** 2026-11-11
- **Scope:** `(jsonparse string)`'s number conversion in `flonum` and
  `exact` modes; plan M3's lever 4
- **Related:** ADR-0011, ADR-0016, ADR-0023; plan M3

## Context

- **Numbers dominate `tree` on number files.** In the report of
  2026-11-09, `tree` ran at a third of `events`' rate on `ints-40k` (43
  against 128 MB/s) and a seventh on `canada` (33 against 229).
- **Every number takes one path today** (ADR-0016). The assembler copies
  the parts into its buffer, copies the buffer into a new bytevector,
  checks its shape, makes a string, and calls `string->number`.
- **The plan's lever 4** is different. The grammar would accumulate each
  integer into a 64-bit field beside the span, fall back to the text on
  overflow, and add an event saying which value to use. byte-machine 0.9.0
  can already do this: an `integer-accumulate` node's overflow edge may go
  to any node. But it would:
  - add a checked multiply-add per digit to every lane, `events` included,
    which is what the M3 targets measure;
  - change ADR-0015's handler of fourteen procedures;
  - do nothing for decimals.
- **What lever 4 could save over a fast path in the assembler** is the copy
  and the digit count: 22 ns of the 39 to 42 a short integer then costs
  (the measurement below).

## Decision

1. **The fast path lives in `(jsonparse string)`.** The grammar, the
   generated parser, the handler and the ABI don't change. Lever 4 is not
   built as the plan wrote it.
2. **`json-assembler-number!` reads a short number straight from its
   buffer,** with no copy and no string:
   - **An integer** of at most 18 digits, in `flonum` and `exact` modes: the
     exact integer, by fixnum arithmetic. 18 is the most digits whose every
     integer is a fixnum where `(greatest-fixnum)` is 2^60 − 1. Where it is
     smaller, the cap is the most digits that fit.
   - **A decimal in `flonum` mode** (with a fraction, an exponent or both)
     whose significand has at most 18 digits, leading zeros counted, and
     whose value is m × 10^e with −22 ≤ e ≤ 22:
     - **at most 15 digits:** one flonum multiply or divide of m by 10^|e|.
       Both are exact flonums, so the one rounding gives the nearest
       flonum (Clinger's fast path);
     - **16 to 18 digits:** `inexact` of the exact m × 10^e.
     - The sign goes on m before it converts, so the result is the only
       flonum made. A zero is the constant `0.0` or `-0.0`.
   - **The exponent is read up to 40** (22 + 18), so a long one never
     leaves the fixnums. Past that, no fraction brings e back to 22.
   - **Everything else** takes the path ADR-0016 describes: more digits, a
     larger power of ten, `exact` mode's decimals (which need its range
     check), and `text` mode.
3. **The fast path checks the text against JSON's number grammar as it
   reads.** On anything it can't read, it gives way to the general path,
   which checks and raises as before. So every text gives what it gave
   before, stops and raises included.
4. **The modes and the limit hold as ADR-0011 sets them.** The digit limit
   is checked first, as before: a number past it is `number-too-long`
   before either path runs. `-0` reads as `0`, and `-0.0` as `-0.0`.
   - **In `exact` mode, the fast path counts an integer's digits against
     the limit itself,** as the range check does. `json-assembler-chars!`
     and `json-assembler-escape!` add digits without counting them, so
     trusting the count would return an integer where main stops with
     `number-out-of-range`. The review found this.

## The measurement (2026-11-11)

On the NUC, pinned to CPU 7 (ADR-0023), Chez 10.4.1 from the Guix
container, compiled ahead of time. A probe built the fast path on a copy
of `src/` (scratch, under `build/`); main's `src/` was the baseline.

- **The probe agreed with main** on 152,701 number texts (every number in
  the benchmark files and `tests/corpus`, and edge cases at each bound), in
  `flonum` and `exact` modes: every result written the same. A mutant
  of it dropping the fast path's sign changed 13,084 results, from 7,730
  texts, so the path ran. 89,718 of the texts are on the 16-to-18-digit
  path.
- **The final code agreed with main too,** in a review's harness, on
  2.26 million more cases:
  - every string of up to 6 characters over the number bytes;
  - 400,000 random numbers split into parts, under limits of 1 to 44;
  - parts given by `json-assembler-chars!` and `json-assembler-escape!`.

  Every value, stop and raise matched, once decision 4's count was in.
- **The `inexact` path rounds right on Chez 10.4.1.** 424,564 texts near
  a halfway point at the 15-to-18-digit bounds matched Python's bits.
  55,404 of them are exact ties, and each went to even.
- **Each bound was checked against exact rounding** by a script:
  - none of 300,000 random 15-digit decimals rounds wrong with one
    operation;
  - with 16 to 18 digits, some do, such as `9639805562909595e-21`,
    `95509374722582052e6` and `811893743652448549e8`;
  - so do `3e23` and `1e-23`, past 10^±22;
  - `9999999999999999999`, 19 digits, overflows a 61-bit fixnum.
- **`tree`, main against the probe, taking turns twice** (`bench/run.sps`,
  9 rounds of 10 MB, medians):

  | File | Gain, run 1 | Gain, run 2 |
  |:--|--:|--:|
  | `ints-40k` | +38.0% | +32.5% |
  | `canada` | +33.7% | +31.8% |
  | `citm_catalog` | +11.5% | +10.2% |
  | `records-2k` | +8.5% | +7.4% |

  `events` moved −1.6% to +3.9% on the same runs: the noise, for code the
  lane never runs. Without the 16-to-18-digit path, `canada` was 4.7% to
  9.4% slower than main: 100,717 of its 111,080 decimals have 17 digits,
  so each was scanned and then taken the long way.
- **The final code against main,** after the review's fixes, timed the
  same way: `tree` took 21% to 30% less time on `ints-40k` and `canada`
  (rates +26.5% to +42.0%), 10% to 15% on `citm_catalog`, 9% to 10% on
  `records-2k` and 4% to 5% on `twitter`. `events`' rate moved −5.5% to
  +5.7%, in code it doesn't run.
- **The assembler alone, per number** (5 rounds, twice):

  | Numbers | main | probe | copy and count alone |
  |:--|--:|--:|--:|
  | `ints-40k`'s integers | 74–76 ns | 39–42 ns | 22–23 ns |
  | `canada`'s decimals | 452–474 ns | 323–332 ns | 47–52 ns |

## Consequences

- **`tree` gains most on number files,** and `events` doesn't change. The
  M3 targets count events, so neither moves (ADR-0023).
- **A 17-digit decimal still costs 271 to 285 ns** past its copy, in
  `inexact` of an exact rational (the probe's 323–332 ns less the copy's
  47–52). Eisel and Lemire's algorithm, which multiplies by a table of
  128-bit powers of ten, might go lower. It is unmeasured here, and not
  part of this decision.
- **Tests check the 16-to-18-digit path against bits from Python,** in
  `tests/fixtures/float64/fast-path-cases.txt`. Its 48 lines sit at each
  bound, and one flonum operation rounds 15 of them wrong. Each line is
  rechecked by exact rounding. The number suite's oracle also takes
  `inexact` of an exact value, so on that path it is not independent.
- **What a number allocates shows which path took it**
  (`tests/test-string-alloc.sps`):
  - a fast integer allocates nothing;
  - a decimal of up to 15 digits, one flonum;
  - a decimal of 16 to 18 digits, 208 to 240 bytes, against 288 for the
    copy alone.

  On main each cost 192 to 560 bytes.
- **Portability rests on IEEE rounding.**
  - R6RS says `fl*` and `fl/` should return the nearest flonum (§11.3).
  - It says `inexact` returns the nearest inexact number, with no rule
    for ties (§11.7.4.2).
  - Chez does all three. The float64 lane holds it to the bits, on amd64
    here and on arm64 in CI (ADR-0009).
  - Main's `string->number` was held to less: the "maximally precise"
    number (§11.7.4.4).
- **The plan's lever 4 is closed** unless a later measurement shows the
  copy matters, and then only with its `events` cost measured.
