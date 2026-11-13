# ADR-0028: byte-machine's ABI stays 9; M2 and the callback cut wait as issues

- **Status:** Accepted. The owner chose this on 2026-11-12.
- **Date:** 2026-11-12
- **Scope:** plan M2; byte-machine's callback step and span delivery, the
  callback cut ADR-0025 left upstream; byte-machine's ABI; the M3 targets'
  revisit
- **Related:** ADR-0002, ADR-0004, ADR-0005, ADR-0023, ADR-0025, ADR-0026;
  plan M2 and M3; jsonparse #20, #21 and #22; byte-machine #184 and #185

## Context

- **M2 was conditional** (ADR-0004): the nesting stack moves into
  byte-machine only if its gain justifies an ABI bump.
- **The callback cut needs ABI 10.** Inlining byte-machine's callback step
  and span delivery in the emitted code reaches into the runtime's parser
  (ADR-0025, ADR-0026).
- **The order:** the owner chose on 2026-11-09 to decide M2 first, so that
  one bump could carry both. The ledger had M2's decision as slice 16 and
  the cut as slice 17.

## The measurement (2026-11-12)

A probe built both changes on `main` (`e833b7e`, byte-machine 0.9.0):

- **A:** `main`.
- **M:** the stack in the machine. The generated parser was edited by hand:
  - one bytevector per parser, sized from `depth-left`;
  - an open writes its kind at `depth`;
  - after a value, the next state comes from the top entry, with no
    callback.

  Standing in for a parser slot, `parser.sls` made the bytevector and
  handed it in through `context`'s callback slot. `exec` read it from there
  on each entry. `parser.sls` lost its push, pop and `context` answer.
- **P:** the callback cut. A script rendered the callback step, span
  delivery, span open and span close inline. The runtime copy exported its
  unbound sentinel and its classifier.
- **MP:** both.

**Method:**

- the four variants took turns, pinned to CPU 7;
- `bench/run.sps`: 9 rounds of 10 MB per file, every lane;
- every variant compiled in a process of its own, so each timed process
  only loaded. No object file is newer than its compile step;
- the figures are rotations 5 to 12, two full cycles. The probe set
  rotations 1 to 3 aside, reporting that they partly ran beside a busy
  core;
- each variant was also compiled into three more object sets, and each set
  was timed once.

Time saved against A, median [least, most]:

| File | Lane | M | P | MP |
|:--|:--|--:|--:|--:|
| `records-2k` | `events` | 11.8% [8.3, 15.8] | 8.5% [8.2, 12.4] | 19.5% [16.2, 22.3] |
| `records-2k` | `parse` | 15.0% [11.1, 19.1] | 12.5% [12.2, 15.8] | 26.5% [22.9, 28.6] |
| `ints-40k` | `events` | 20.8% [19.6, 24.1] | 10.7% [9.1, 13.1] | 27.3% [26.0, 28.1] |
| `canada` | `events` | 9.8% [9.4, 17.2] | 6.8% [6.4, 8.5] | 24.3% [23.3, 26.8] |
| `citm_catalog` | `events` | 8.8% [7.3, 12.4] | 5.2% [4.7, 9.6] | 12.6% [12.2, 16.0] |
| `twitter` | `events` | 8.1% [5.0, 11.7] | 5.6% [2.3, 9.9] | 11.6% [10.9, 15.5] |
| `escaped-string`* | `events` | −2.3% [−4.2, 7.0] | 4.6% [−4.4, 9.4] | −0.4% [−4.7, 5.9] |

\* Over the four object sets. In rotations 5 to 12, A's object set ran
this file's `events` lane 6% to 8% slower than its other three. That made
M look 7% faster on a file with one value inside a container.

- **Per value inside a container,** M saved 8 to 10 ns on `ints-40k` and
  `records-2k`, in `parse`, `events` and `tree`. ADR-0004 measured 8 ns.
  Other files scattered from 2 to 18 ns.
- **The two mostly add up.**
  - On `records-2k`, MP saves about what M and P save apart, and on
    `canada` more.
  - On `ints-40k`, `twitter` and `citm_catalog`, M saves less on top of P
    than alone. On `ints-40k`, for example, it saves about three quarters
    as much.
  - On `escaped-string`, MP ran 2% to 4% slower than P, in every rotation
    and every object set. Why isn't known.
- **A compile is a layout draw.** On `records-2k` and `ints-40k`, the four
  object sets gave medians within about 2 points of these. On
  `escaped-string`, M's figure spread over 11 points.
- **The M3 targets aren't met by either change, or by both.** This is
  `events`' gap to yajl, with yajl's rate from the report of 2026-11-09:

  | File | A | M | P | MP | Target |
  |:--|--:|--:|--:|--:|--:|
  | `records-2k` | 4.15× | 3.65× | 3.73× | 3.34× | 2× |
  | `escaped-string`* | 4.42× | 4.52× | 4.28× | 4.44× | 4× |

  \* Over the four object sets. yajl's rate is from one run. ADR-0023 saw a
  gap move by up to 9.8% between runs, so the second decimal is not
  significant.

- **Correctness:**
  - **The suites ran on a harness the probe adapted for M:**
    - its copy of `(jsonparse-testing machine)` expects no `context`
      calls;
    - its bench callbacks lane binds no `context`;
    - its `test-parser-alloc` is its own.
  - **On that harness,** every suite passed for M, P and MP except these:
    - `test-generated`, which pins the file to its render;
    - for M and MP, the stack's mutants;
    - for M, `test-bench-callbacks`, which ran before the adapted lane
      existed;
    - `test-machine` and `test-machine-driver`, which fail for A too, in
      the nesting and depth-limit cases M changes. The hand-written cases
      stand in for them.
  - **On the plain harness,** M failed 14 suites, as dropping `context`
    must. P wasn't run on it.
  - **Hand-written cases:** each variant's outcomes matched A's exactly.
    The cases covered mismatched closers, depth limits of 1, 512 and
    65,535, 1-byte feeds, pause and resume, a reset mid-document, and two
    parsers interleaved.
  - **Mutants:** three mutants of M's stack failed 12 to 23 suites each,
    beyond M's own five.
- **byte-machine's side,** set out for the owner before the choice:
  - **M2** widens the model from "regular plus counters" to bounded
    pushdown. It needs a stack declaration and two node kinds through the
    IR, the verifier, the normalizer, the interpreter, the emitter and the
    runtime. My estimate is that it's about the size of decision 0059.
  - **The cut** makes the parser's slot layout part of the ABI.
  - **Consumers:** chez-httparse, uriparse and jsonparse regenerate for
    either change.

## Decision

- **byte-machine's ABI stays 9 for now.** Neither M2 nor the callback cut
  is built. The owner chose this on 2026-11-12, after the impact on
  byte-machine was set out.
- **Both wait as issues** that hold the probe's code, figures and work
  lists:
  - byte-machine #184, the cut, with jsonparse #20 to adopt it;
  - byte-machine #185, the stack primitive, with jsonparse #21 for M2.
- **If both are taken,** they ship in one byte-machine release under one
  bump, so the consumers regenerate once (ADR-0002).
- **The stack stays in jsonparse,** and ADR-0004 stands.

## Consequences

- **Neither M3 target is met.** ADR-0023 has them revisited with the
  owner, not quietly missed. The owner chose on 2026-11-12 to revisit them
  once #20 is taken. Until then M3 stays open, and M4 and the 0.2.0 release
  go ahead.
- **No consumer regenerates.** jsonparse stays on byte-machine `^0.9.0`.
- **Nesting stays outside byte-machine's verifier.** ADR-0004's mutation
  tests keep standing in for it.
- **`make bench` and `make bench-callbacks` compile jsonparse in the
  process they time,** despite ADR-0023's "compiled ahead of time". This
  probe and slice 15 found it. It skews a figure by 1% to 4% at the median,
  and by up to 22% for one file and lane. It is jsonparse #22.
  - These figures avoid it.
  - Slices 13 and 14's figures carry it (ADR-0025, ADR-0026).

  Slice 17 fixed it. Both targets now time through `scripts/bench-chez`,
  and ADR-0023 to ADR-0026 carry the retaken figures.
