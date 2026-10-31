# ADR-0011: Numbers convert by mode, with a digit limit

- **Status:** Accepted
- **Date:** 2026-10-30
- **Scope:** how the tree, the assembler and the writer handle numbers
- **Related:** plan §7 question 7; ADR-0006, ADR-0007, ADR-0010

## Context

JSON numbers have no fixed size, and Scheme has exact integers, exact
rationals and flonums. Measured with Chez 10.4.0 on x86_64, 2026-10-30
(scratch programs, not kept):

- **`string->number`:**
  - reads `1e400` as `+inf.0`, `1e-400` as `0.0`, `-0` as `0` and `-0.0` as
    `-0.0`;
  - rounds correctly on two known hard cases, `9007199254740993.0` and
    `2.2250738585072011e-308`.
- **Conversion time grows with the square of the digit count:**
  - an integer of 10,000 digits takes 10 ms, 100,000 take 0.77 s, and
    1,000,000 take 78 s;
  - a fraction of 400,000 digits takes 12 s;
  - a 100,000-digit exponent takes 0.74 s;
  - an exact `1e1000000` takes 76 ms and builds a million-digit integer from 9
    bytes of input.
- **One megabyte made of numbers at a given length converts in:**

  | Digits per number | Time per MB |
  |---|---|
  | 17 | 4–9 ms |
  | 100 | 34 ms |
  | 1,000 | 116 ms |
  | 4,300 (Python's integer limit) | 353 ms |

  A tree parse runs at 47–65 MB/s, which is 15–21 ms per MB (ADR-0004).
- **`number->string`:**
  - Chez writes subnormals with R6RS's mantissa width, as `5e-324|1`, which
    isn't JSON.
  - Guile writes `5.0e-324` and `1.0e21`.
  - Racket writes `5e-324` and `1e+21`.
  - All of these are JSON once the `|` suffix is gone.

## Decision

1. **Numbers convert by one of three modes, set with the options:**
   - **`flonum`, the default.**
     - A number with no fraction and no exponent is an exact integer, so `-0`
       reads as `0`.
     - Any other number is the nearest flonum, so `-0.0` stays `-0.0`.
     - A number too large for a flonum, such as `1e400`, is
       `number-out-of-range`.
     - A number too small reads as the nearest flonum, which may be `0.0`.
   - **`exact`:** every number is exact. `1.5` reads as `3/2`, `1e2` as `100`,
     and `1.0` as `1`.
   - **`text`:** a `json-number` record holding the number's text, never
     converted. It can't be confused with a string. Its constructor checks the
     text against JSON's number grammar.
2. **A digit limit, set with the options, default 1,000.**
   - In `flonum` and `exact` modes, a number with more digits than the limit is
     `number-too-long`. The integer part, the fraction and the exponent all
     count.
   - In `exact` mode, a number whose significand digits plus the absolute value
     of its exponent exceed the limit is `number-out-of-range`. That bounds an
     exact value to about the limit in digits.
   - `text` mode converts nothing, so it has no limit.
3. **Conversion lives in `(jsonparse string)`,** so event handlers get the same
   modes and limit as the tree.
4. **The writer writes numbers as follows:**
   - exact integers in decimal;
   - finite flonums through `number->string`, with any `|` suffix removed;
   - exact non-integers as decimals when the denominator has no prime factor
     but 2 and 5. Others, such as `1/3`, are refused.
   - `json-number` records exactly as their text.

## Consequences

- **The worst case per byte has a bound.** At the default limit, a megabyte of
  the longest integers allowed converts in about 116 ms, about 6 times a tree
  parse. Without a limit, one number can take minutes.
  - **Measured again on Chez 10.4.1 (ADR-0016):** integers take 122 ms per
    MB, as before. Long fractions take 354 ms, and the slowest shape found
    takes 389 ms, about 20 times a tree parse. The owner kept the default
    of 1,000 (2026-10-31).
- **Tests pin the limit's boundary:** 1,000 digits are accepted and 1,001 are
  refused, each watched fail.
- **What each mode gives back:**
  - `text` gives back every number's exact text;
  - `exact` gives back every value;
  - `flonum` rounds to the nearest flonum and drops the sign of `-0`.
- **A property test reads back every number the writer writes:**
  - exact numbers are read in `exact` mode, and flonums in `flonum` mode, and
    compared with `eqv?`;
  - `json-number` records are compared by text.
- **M3's integer fast path** must keep these modes and the limit.
