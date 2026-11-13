# ADR-0024: The comparators run in harnesses of their own, and only a lane that cross-checks gets a rate

- **Status:** Accepted
- **Date:** 2026-11-08; the pass limit of Decision 5, 2026-11-09
- **Scope:** `make bench`'s eleven comparators, ADR-0013's: their lanes, how
  each is used, their harnesses, the fetched ones and their lock, the
  smaller rounds of slow ones, the lanes too slow to time, `BENCH_PARSERS`,
  and what the report does with a comparator that fails or disagrees
- **Related:** ADR-0003, ADR-0007, ADR-0008, ADR-0013, ADR-0023

> **Revision (2026-11-12, slice 16).** SRFI 180 and chez-json are compiled
> ahead of time in a step of their own, but jsonparse isn't, as decision 2
> says it is. `make bench` compiles jsonparse in the process it times
> (jsonparse #22), so jsonparse's figures carry a skew of 1% to 4% at the
> median, and the comparators' don't.

> **Revision (2026-11-12, slice 17).** jsonparse is now compiled ahead of
> time too, by `scripts/bench-chez` (ADR-0023). The report retaken on
> `main` (`20ba63b`), one run, mostly reads as this record did:
> - **events:** every event parser but SRFI 180 is ahead of jsonparse.
> - **tree:** Chibi is faster on every file. Gambit is faster on
>   `ints-40k` (1.24×), `poet` (1.11×) and `records-2k` (1.07×), and
>   within 3% on `escaped-string`.
> - **tree+walk:** Chibi is ahead on `canada`, `escaped-string` and
>   `gsoc-2018`. It isn't ahead on `ints-40k` any more, where slice 15's
>   number fast path moved jsonparse ahead (ADR-0027). Gambit is ahead
>   only on `ints-40k`.

## Context

ADR-0013 chose the comparators, and ADR-0023 built `make bench` for
jsonparse and yajl alone, with harnesses whose counts cross-check. On
2026-11-08 the owner chose:

- **all eleven comparators in one slice;**
- **a slow comparator may run smaller rounds,** declared and named in the
  report. M0 timed chez-json at 0.06 MB/s on `ints-40k`, about 4 s a pass, so
  ADR-0023's 20 MB rounds would take about an hour on that file alone;
- **Jackson 2.23.0 from Maven Central,** pinned by sha256, instead of Guix's
  2.9.4 from 2018;
- **on the M1 laptop, whatever is installed:** `BENCH_PARSERS` names the
  comparators to run.

Every comparator but SRFI 180's reference implementation, chez-json and
Jackson is a Guix package at the pin, with substitutes: about 1.9 GB.
Reading chez-json and SRFI 180's code before the slice showed:

- **chez-json reads `null` and `[]` both as `()`** (ADR-0006), so a walk of
  its value can't count them apart. It builds each array with `append`, so it
  is quadratic in an array's length. It decodes each `\u` escape alone, so a
  surrogate pair becomes two replacement characters.
- **SRFI 180's `json-fold` hands its procedure converted numbers,** so it
  can't count number text. Its reference implementation is R7RS for Chibi: it
  needs `(chibi regexp)` and R7RS's `define-record-type`.

Running them in the slice showed more:

- **SRFI 180's reference implementation slows with the square of the
  numbers it has read.** After each number it wraps its character
  generator in one more `gcons`, and never unwraps it, so every later
  character passes through one wrapper per number so far. Arrays of 5,000,
  10,000 and 20,000 integers took 0.14, 0.45 and 1.57 s a pass, where arrays
  of strings stayed linear. A pass over `canada.json`, 111,126 numbers, takes
  225 s: ADR-0023's method runs 11 passes a lane, 2 hours for its three
  lanes on that file. Smaller rounds can't help, as a round is at least a
  pass.
- **chez-json is also quadratic in the escapes of one string:** each escape
  copies the string so far with `string-append`.

On 2026-11-09 the owner chose to give such a lane no rate rather than run
it: the pass limit of Decision 5.

## Decision

1. **Eleven comparators, in ADR-0013's lanes,** each named by a symbol:

   | Parser | Lanes | What is timed |
   |---|---|---|
   | `rapidjson` | `parse`, `events` | the SAX `Reader` |
   | `jackson` | `parse`, `events` | `JsonParser.nextToken` |
   | `srfi-180` | `events`, `tree`, `tree+walk` | `json-fold`; `json-read` |
   | `racket` | `tree`, `tree+walk` | `read-json` |
   | `guile-json` | `tree`, `tree+walk` | `json->scm` |
   | `gambit` | `tree`, `tree+walk` | Gambit's `_json` reader |
   | `gerbil` | `tree`, `tree+walk` | `:std/text/json`'s reader |
   | `chibi` | `tree`, `tree+walk` | `(chibi json)`'s reader |
   | `chez-json` | `tree`, `tree+walk` | `json->scm` |
   | `simdjson` | `tree`, `tree+walk` | the DOM parser |
   | `yyjson` | `tree`, `tree+walk` | `yyjson_read` |

   The lanes are ADR-0023's. `parse` listens to nothing; `events` counts
   every value by kind and the bytes of its text; `tree` builds the value;
   `tree+walk` builds it, then walks it counting as `events` does.
   `simdjson` and `yyjson` are ceilings, not targets.

2. **Each comparator is used as its documentation tells a caller to,** at its
   defaults:
   - **A pass starts from the file's bytes in memory.** A library that reads
     bytes gets them. One that reads characters gets a UTF-8 port over
     them, made inside the pass, so decoding is part of the pass.
   - **A new parser per pass, as ADR-0023 says,** except where the library's
     documentation says to reuse one. simdjson's `dom::parser` is reused,
     and its `padded_string` is made once, outside the timing. Jackson's
     `JsonFactory` is reused, with a new `JsonParser` per pass.
   - **Compiled where the implementation compiles:**
     - the C and C++ harnesses at `-O2`;
     - Jackson on the JVM's defaults;
     - Racket by `compiler/cm`, the library `raco make` runs, since
       `racket-minimal` has no `raco make`; Guile by `guild compile`;
     - Gambit by `gsc -exe`, and Gerbil by `gxc -exe`;
     - SRFI 180 and chez-json on Chez, compiled ahead of time as jsonparse
       is.

     Chibi's harness is interpreted, as Chibi always is.
   - **Two runtimes leave their defaults:**
     - Chibi runs with a 1 GB heap (`-h 1G`). At its default heap,
       collection thrashes while a large value stays live during a walk: a
       `tree+walk` pass over `canada.json` took 17 to 21 s, against 37 ms.
     - Pinned to one core, the JVM picks the serial collector and runs its
       two JIT threads on the timed core. Jackson takes the JVM's defaults
       for that machine; its runtime form doesn't say.
   - **The events lane asks every parser for each number's text.** RapidJSON
     parses with `kParseNumbersAsStringsFlag`, which hands the text over
     unconverted, as yajl and jsonparse do. Its defaults otherwise stand: it
     doesn't check UTF-8.
   - **Each runtime form says how its parser ran,** and the report prints
     it.

3. **One harness per runtime, in `bench/`.** Each is its own program and
   keeps ADR-0023's method and output:
   - it reads each file into memory, and takes a lane's first pass outside
     the timing;
   - it runs a warm-up round, then the timed rounds, each of
     `iterations-for`'s passes;
   - it collects fully before each round, where the runtime can, outside
     the timing;
   - it reads a monotonic clock, but Chibi's: Chibi has only gettimeofday.
     Guile's own clocks aren't monotonic, so its harness calls
     `clock_gettime(CLOCK_MONOTONIC)` through Guile's foreign function
     interface;
   - it counts passes as they finish, and sums what the timed passes
     counted;
   - it writes ADR-0023's `runtime` and `result` forms. A runtime form
     carries `version` and `how`;
   - a pass fails unless only whitespace follows the value.

   The harnesses:
   - `rapidjson-bench.cc`, `simdjson-bench.cc` and `yyjson-bench.c`;
   - `JacksonBench.java`;
   - `racket-bench.rkt` and `guile-bench.scm`;
   - `gambit-bench.scm`, `gerbil-bench.ss` and `chibi-bench.scm`;
   - `chez-peers.sps`, for SRFI 180 and chez-json.

   SRFI 180's R6RS wrapper is `(jsonparse-bench srfi-180)`. It `include`s
   the fetched body from `build/bench/comparators/`, by a path from the
   repository's root, where make runs. That is the one include in the
   project: the body is upstream's code, which isn't committed and can't be
   a library as it stands. The walks and SRFI 180's counting fold are
   `(jsonparse-bench walks)`, which imports no comparator, so `make test`
   can test them.

4. **Each counting lane counts the names its parser can tell apart.** The
   cross-check compares each one with jsonparse's `events`:
   - `rapidjson`'s and `jackson`'s `events` count all ten, as yajl's do;
   - `srfi-180`'s `events` counts the nine without `number-bytes`, as every
     `tree+walk` does;
   - `chez-json`'s `tree+walk` counts `null+array` where the others count
     `null` and `array`. That is every list it built, empty or not.

5. **A comparator's lane that rejects a file, or whose counts disagree, gets
   no rate.**
   - When a lane's first pass raises, its harness writes
     `(failure (file F) (parser P) (lane L) (reason "…"))` instead of
     timing it.
   - The report's cell reads "fails" or "disagrees", and a list under the
     tables says why. Neither stops the report.
   - **A lane that counts nothing follows the lane that checks it.** `tree`
     and `parse` count nothing, as in ADR-0023. The walk is the only check
     of the value a tree builder built, and `events` of what `parse` read.
     So when a comparator's `tree+walk` or `events` fails or disagrees on a
     file, its `tree` or `parse` there gets no rate either.
   - **What a rate proves:** the lane ran the method's passes, and a
     counting lane counted the file's values in every pass. A `tree` or
     `parse` lane that skipped its work in the timed passes would still get
     a rate, and so would a `tree+walk` that parsed once and walked a cached
     value. ADR-0023 has the same limit for jsonparse and yajl; the
     harnesses were read for it.
   - **A lane too slow to time gets no rate.** `chez-peers.sps` times no
     lane whose first pass takes over 10 s, the method's limit. It writes
     `(too-slow (file F) (bytes N) (parser P) (lane L) (pass-ns NS)
     (limit-ns NS) (counts …))` instead, and the cell reads "too slow".
     - The report holds the form to the method's limit, and its pass past
       it. The list gives that pass's time and rate.
     - Its counts are still cross-checked, and a disagreement reads
       "disagrees".
     - A walk too slow to time still checked the value, so its tree keeps
       its own cell.
     - The other harnesses have no lane near the limit, so they have no
       limit.
   - **The comparators' tables give the median alone.** The table of
     jsonparse against yajl keeps the best round and the median, as ADR-0013
     says.
   - **Anything else stops the report,** as in ADR-0023: rounds, round bytes,
     files, lanes, sizes, iterations, passes, or timed counts that aren't
     one pass's times the passes. So do a failure or disagreement of
     jsonparse's or yajl's, which hold the targets.

6. **A slow comparator reads smaller rounds:** the method's round bytes
   divided by a divisor the Makefile gives it.
   - The Makefile writes the plan, `build/bench/plan.scm`: the rounds, the
     round bytes, and each parser named with its round bytes.
   - The report holds every runtime to the plan, and jsonparse and yajl to
     the method's round bytes.
   - The method line names each comparator with smaller rounds.
   - **A divisor gives a comparator's slowest timed file one pass a round.**
     SRFI 180's and chez-json's are 100: rounds of 200,000 bytes, less than
     `ints-40k.json`'s 228,891, which they read at 8.3 to 8.5 s and 2.8 s a
     pass. No other comparator needs one: at the method's rounds, each
     takes 2.6 minutes or less for all eight files.

7. **`BENCH_PARSERS` names the comparators to run,** all eleven by default.
   jsonparse and yajl always run. A comparator named whose tools are
   missing stops `make bench` before anything is timed. The plan names
   exactly the parsers run, and the report shows only their columns.

8. **Three comparators are fetched on the host,** pinned by sha256 in
   `bench/comparators.lock` and checked by `scripts/fetch-bench-files`
   before use. None is committed:
   - SRFI 180's `body.scm`, MIT, at upstream commit `e45cb7da`;
   - chez-json's `json/parser.scm`, LGPL-3.0, at `a9d6a302`, its last
     commit (2017);
   - `jackson-core-2.23.0.jar`, Apache-2.0, from Maven Central. Its sha256
     was taken when the Maven-published SHA-1 matched.

   On a Guix host they run only inside the container, which has no network
   (ADR-0008). Elsewhere, as on the Mac, `make bench` runs them on the host.

9. **The tools come from `bench/manifest.scm`:** RapidJSON 1.1.0, simdjson
   4.6.3, yyjson 0.12.0, OpenJDK 25, Racket 9.3 (`racket-minimal`), Guile
   3.0 with guile-json 4.7.3, Gambit 4.9.7, Gerbil 0.18.1 and Chibi 0.12.
   `make check-guix` asserts each one: by version, or by use for guile-json
   and Racket's `json` and `compiler/cm`, which state none. On the M1 laptop
   they come from Homebrew, where it has them.

## The first measurement (2026-11-09)

**Conditions.** `make bench` was run twice on the reference machine, at the
defaults, pinned to CPU 7. The runs took 29.3 and 29.4 minutes. SRFI 180
took 18.4 of them, 12.4 on the six first passes that the limit stopped.
Figures are medians, run 1 first, and every ratio was computed by a script
from the results files.

**Every comparator cross-checked, and the same 14 cells had no rate in both
runs:**

- **SRFI 180 is too slow on `canada.json`,** at 222 to 228 s a pass, and on
  `citm_catalog.json`, at 22 s, in all three lanes.
- **Gerbil disagrees on `escaped-string`, `poet` and `twitter`,** on
  text-bytes:
  - `bytes->json-object` decodes 4-byte UTF-8 wrongly;
  - every path turns an escaped surrogate pair into two U+FFFD.
- **chez-json disagrees on `escaped-string`:** it decodes each half of a
  surrogate pair alone, as two U+FFFD.

**Where jsonparse stands.** Each figure is a comparator's median rate over
jsonparse's in the same lane, from the least to the most over the files it
was rated on, in both runs:

| Lane | Comparator | Its rate over jsonparse's |
|:--|:--|:--|
| `events` | yajl | 2.5 to 6.1 |
| | RapidJSON | 2.6 to 5.4 |
| | Jackson | 2.0 to 4.8 |
| | SRFI 180, on six files | 0.0002 to 0.13 |
| `tree` | Chibi | 0.84 to 10 |
| | Gambit | 0.65 to 1.8 |
| | Gerbil, on five files | 0.45 to 0.97 |
| | Racket | 0.094 to 0.70 |
| | guile-json | 0.20 to 0.41 |
| | chez-json, on seven files | 0.0018 to 0.66 |
| | SRFI 180, on six files | 0.0006 to 0.22 |
| | simdjson | 19 to 43 |
| | yyjson | 19 to 41 |

- **The event parsers are all ahead but SRFI 180,** in C, C++ and Java.
- **Chibi, whose reader is C, builds trees faster than jsonparse on every
  file but `poet` in run 2,** where its median landed on its slow rounds
  (below). Its interpreted walk takes most of that back: in `tree+walk` it
  reads 0.11 to 4.9 of jsonparse's rate, ahead in both runs on `canada`,
  `escaped-string` and `gsoc-2018`, and by 6% on `ints-40k`.
- **Gambit builds trees faster than jsonparse on `ints-40k` (about 1.7×),
  `records-2k` (1.2×) and `poet` (1.1×)** in both runs. On `gsoc-2018` and
  `escaped-string` it is within 4% of jsonparse, inside the 5.2% that
  jsonparse's own rates moved between runs. In `tree+walk`, it is ahead
  only on `ints-40k`.
- **Gerbil comes closest on `ints-40k`,** at 0.94 to 0.97 of jsonparse's
  rate. jsonparse is ahead of Racket, guile-json, chez-json and SRFI 180 on
  every file.
- **simdjson and yyjson, the ceilings,** build trees 19 to 43 times faster.

**Run to run.** A median rate moved by 1.2% at the median of the 226 rated
cells. It moved 5.2% at most for jsonparse and 4.9% for yajl. Two
comparators moved far more, and a median of nine rounds doesn't hide it:

- **Chibi's `tree` rounds fall in two modes on some files.** On
  `poet.json` a round takes about 33 ms or 160 to 460 ms. Five of nine were
  fast in run 1 and four in run 2, so the median fell 77%, and Chibi's rate
  over jsonparse's from 3.7 to 0.84. On `gsoc-2018` a round takes about
  35 ms or 140 ms, and the median moved 66%; on `canada` it moved 31%. A
  full GC precedes each round; the cause wasn't sought.
- **Jackson's JIT settles at different speeds in different runs.** On
  `gsoc-2018` in `events`, run 1's rounds settled at 22.6 ms and run 2's at
  36.7 ms, a 38% move. Nor has the warm-up round always settled it: the
  first timed round took 1.6 to 2.4 times the median, on 5 of its 16 lanes
  and files in run 1 and on 2 in run 2.

## Consequences

- **The report places jsonparse among its peers,** on the same files, under
  the same method and checks. yajl alone still decides M3's targets.
- **A comparator that rejects a file or counts it wrongly can't stop a
  measurement of the targets,** and gets no rate there. A broken harness
  does stop it, as a broken jsonparse harness would: leave it out of
  `BENCH_PARSERS`.
- **The harnesses outside Chez have no suite in `make test`,** which runs
  no comparator. The cross-check checks them at every `make bench`. In
  each, a pass short, timed counts off, and keys counted as strings were
  watched fail against the report. None of those touches a lane that
  counts nothing (Decision 5).
- **A full `make bench` takes about 30 minutes,** against 72 s for
  jsonparse and yajl alone, which `BENCH_PARSERS=` gives. SRFI 180 takes 18
  of them.
- **ADR-0013's Jackson row is superseded:** 2.23.0 from Maven Central, not
  Guix's 2.9.4.
