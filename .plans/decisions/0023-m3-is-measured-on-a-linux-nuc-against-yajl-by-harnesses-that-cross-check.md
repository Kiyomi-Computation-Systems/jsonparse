# ADR-0023: M3 is measured on a Linux NUC, against yajl, by harnesses that cross-check

- **Status:** Accepted
- **Date:** 2026-11-08
- **Scope:** `make bench` and `bench/`; the reference machine for M3's
  targets; the lanes and the target lane; the input files and their lock;
  `bench/manifest.scm` and `scripts/guix-env --bench`; the first
  measurement and what it says about M3's levers
- **Related:** ADR-0003, ADR-0004, ADR-0008, ADR-0013; the plan's M2 and M3

> **Revision (2026-11-11, slice 15).** The number fast path (lever 4) is
> built in the assembler, not the grammar (ADR-0027). As this record
> expected, it speeds `tree` on number files and leaves `events`, and so
> the M3 targets, where they were.

## Context

M3 starts by measuring (plan M3, lever 1). ADR-0013 chose the comparators,
the files and the method. The plan measured M3's targets on a `tarm64osx`
"reference cell", the owner's M1 laptop, where byte-machine's own
baseline was taken.

On 2026-11-08 the owner made a different choice. The reference machine is
the owner's Linux NUC, and the owner runs further tests on the M1 laptop.
The owner also chose to measure jsonparse and yajl first, and add ADR-0013's
other comparators in the next slice. yajl alone decides the targets.

The rest of the context is the method's open questions:

- **ADR-0013 gives the events lane a counting handler** "so no work can be
  skipped". M0 compared yajl with no callbacks against a parser answering
  only `context` (plan §2). These are different lanes, and the gaps differ:
  yajl decodes a string's escapes only for a string callback.
- **A timing proves nothing about work it skipped.** A harness that miscounts,
  times fewer passes than it reports, or times another handler than it
  counts with, still gives a rate.
- **The NUC's CPU is hybrid:** an Intel Core Ultra 5 125H, with performance
  cores at up to 4.5 GHz (CPUs 0 to 7), efficient cores at 3.6 GHz (8 to 15)
  and low-power ones at 2.5 GHz (16 and 17). yajl's `events` lane on
  `records-2k` ran at 547, 336 and 253 MB/s pinned to one of each.
- **Chez compiles a library the same way from source or ahead of time,** but
  compiling at load time puts the compiler inside the first round.

## Decision

1. **The reference machine is the owner's Linux NUC,** pinned to one
   performance core.
   - jsonparse runs on Chez 10.4.1 in the pinned container (ADR-0008).
   - yajl is Guix's 2.1.0, and its harness is built by gcc 14.3.0 at
     `-O2`. libyajl's own flags are Guix's, and the report names only the
     harness's.
   - Both harnesses run under `taskset` on the core `scripts/bench-cpu`
     picks: the highest-numbered of the fastest. That is CPU 7, under the
     `powersave` governor. `BENCH_CPU=` runs unpinned, as on macOS.
   - M3's exit is measured here. Runs on the M1 laptop add numbers, and
     decide nothing. This revises plan M3's reference cell.
2. **This slice measures jsonparse and yajl alone.** The next adds
   ADR-0013's other comparators, which need nothing below to change.
3. **Five lanes.** Each pass of a parsing lane makes a new parser, or yajl
   handle, as a caller would:
   - **`parse`:** jsonparse with a handler of no procedures; yajl with no
     callbacks. M0's comparison.
   - **`events`:** each value counted by kind, and the bytes of every
     number's text and every string's and key's decoded text. jsonparse uses
     a counting handler; yajl uses counting callbacks.
   - **`tree`:** `bytevector->json` under the default options.
   - **`tree+walk`:** `tree`, then a walk counting the value as `events`
     does.
   - **`scan`:** a Scheme loop that only sorts each byte into string, number,
     whitespace and other. It parses nothing, reads a byte at a time, and
     gives the report its file composition.
4. **M3's targets hold on `events`,** as ADR-0013 Decision 3 defines it: a gap
   is yajl's median rate over jsonparse's. `parse` is reported beside it.
5. **The report is written only when the results cross-check.** Otherwise
   `bench/report.sps` names each problem, exits 1, and leaves the last report
   in place. The checks:
   - both harnesses ran the same rounds of the same bytes;
   - the results name exactly the lock's files;
   - every lane of each parser is present once for every file, with its
     runtime's rounds, and every result reads the file's one size;
   - every lane ran `iterations-for`'s passes a round, and as many passes
     in all as a warm-up round and the timed rounds make. Each harness
     counts the passes that finished, not the passes it meant to run;
   - one pass's counts, taken outside the timing, cross-check: yajl's ten
     events counts equal jsonparse's, the walk's nine equal the events',
     and the scan covers every byte with as many number bytes as the
     events;
   - in each counting lane, what the timed passes counted is one pass's
     counts times the passes. A lane timed with another handler, or without
     its walk, fails this.
6. **The method is ADR-0013's, made exact:**
   - every file is read into memory;
   - a warm-up round, then 9 timed rounds by default;
   - each round makes the fewest passes that read 20,000,000 bytes, the same
     count on both sides;
   - the best round and the median, in MB/s, where 1 MB is 10^6 bytes;
   - a full collection before each Chez round, outside its time. Each
     round's allocation and collecting time are measured inside it;
   - jsonparse's libraries, byte-machine's runtime and the harness are
     compiled ahead of time into a fresh `build/bench/obj`, at Chez's
     default optimize level, which is what a consumer gets.
7. **The files are pinned by sha256 in `bench/files.lock`,** and none is
   committed:
   - five are fetched on the host by `scripts/fetch-bench-files`, from URLs
     pinned to upstream commits:
     - nativejson-benchmark's `canada.json`, `citm_catalog.json` and
       `twitter.json`;
     - yyjson_benchmark's `gsoc-2018.json` and `poet.json`;
   - M0's three synthetic files are written by `bench/synthetic.sps`;
   - the Makefile reads the lock only through that script. `--check` holds
     all eight in the directory that is timed before anything is timed, and
     `--list` names the files to time.
8. **The tools come from `bench/manifest.scm`:** yajl, `gcc-toolchain@14`,
   pkg-config and util-linux, for `taskset`.
   - `scripts/guix-env --bench` adds that manifest after `manifest.scm`.
   - `make check-guix` asserts each tool, by version where it has one.
   - `make bench` runs on the host. It fetches the files, then runs
     `bench-inside` in that container, or directly where there is no Guix.
   - The inner make is `$(SUBMAKE)`, so `make -n bench` starts nothing.
9. **The harness lives in `bench/`,** as `(jsonparse-bench)` and
   `(jsonparse-bench report)`, outside `(jsonparse …)`.
   - It is tooling (ADR-0003): it uses Chez's clock and collector.
   - `.akkuignore` lists `bench`, and `make check-akku` fails without that
     entry.
   - `tests/test-bench.sps` tests the harness in `make test`.
   - `tests/fetch-bench-files.sh` tests the fetch script offline, in
     `make check-bench-files`, which CI's linux job runs.

## The first measurement (2026-11-08)

**Conditions.** `make bench` was run twice on the reference machine, at the
defaults, pinned to CPU 7. This was the evening of 2026-11-08 locally, so
the reports' UTC date is 2026-11-09. Figures are medians, run 1 first, and
every ratio was computed by a script from the results files.

**The events lane, the targets:**

| File | yajl | jsonparse | Gap | Target |
|:--|--:|--:|--:|--:|
| `records-2k.json` | 550.9, 571.3 MB/s | 136.0, 133.7 MB/s | 4.1×, 4.3× | 2× |
| `escaped-string.json` | 802.8, 832.6 MB/s | 184.7, 179.1 MB/s | 4.3×, 4.6× | 4× |

- **Neither target is met.** `records-2k`'s `events` needs 2.0× to 2.1× its
  rate, and `escaped-string`'s 1.09× to 1.16×.
- **On `parse`, `escaped-string` is much further behind:** 8.5× and 8.1×,
  against 3.4× and 3.5× on `records-2k`. With no string callback, yajl reads
  `escaped-string` at 2,189 and 2,093 MB/s. With one, it decodes the escapes
  and copies the string, and slows to 803 and 833.
- **Across all eight files,** `events` is 2.6× to 5.6× behind yajl in run 1
  and 2.7× to 6.2× in run 2. `parse` is 2.4× to 8.8×, and 2.4× to 9.3×.
- **The lanes don't do quite equal work on escaped strings.** yajl copies a
  string with escapes into its buffer, decoded. jsonparse's counting handler
  only adds up the parts' lengths. Joining the parts, as yajl does, cost
  jsonparse 5% to 6% more on `escaped-string` in two pinned runs of the
  review's handler. So its gap there reads that much smaller.

**Run to run.** Between the two runs a rate moved by 1.1% at the median, by
4.4% or less in 9 of 10 cells, and by 5.8% at most. A gap is the ratio of
two rates, so it moved by up to 9.8%. Unpinned, two earlier runs moved rates
by up to 6.7%.

**Where jsonparse's time goes**, in nanoseconds per input byte, from both
runs:

- **The parser alone (`parse`)** costs 3.4 to 5.9 ns per byte. The scan
  costs 1.6 to 2.7, and yajl's `parse` 0.46 to 1.97. So the machine costs
  1.3× to 2.8× what the scan does, most on `records-2k`.
- **The scan is a floor only for a loop reading a byte at a time.** The
  review's loop over string bodies read 4 bytes a step, at 1.12 to 1.18 ns
  per byte on `gsoc-2018` and `poet`, against 1.54 to 1.55 for a byte at a time. It
  checked neither control characters nor UTF-8, which a string body must.
- **Callbacks** add 6 to 13 ns per counted value in jsonparse, against
  yajl's 1.8 ns or less. That is on the six files other than `gsoc-2018` and
  `escaped-string`, whose few values each carry long text.
  - Each figure is the difference of two medians. On `poet`, where it is a
    small share of the time, it moved from 6.1 to 11.6 between runs.
  - On `records-2k` callbacks are 21% of `events` time, and on `ints-40k`
    24%.
  - The difference includes the machine's work for the spans and escapes
    that `parse` never asks for, as well as jsonparse's handler path. The
    profile doesn't separate the two.
- **The `records-2k` budget.** Its 2× target means `events` at 3.5 to 3.6 ns
  per byte, 1.4 to 1.5 above the scan. Today it takes 7.4 to 7.5, 5.3 to 5.4
  above.
- **Building a tree** costs 6.0 to 32.0 ns per byte. Numbers dominate:
  `canada.json`, 90% number text, allocates 12.9 bytes per input byte.
  Collecting takes at most 13.5% of a tree round.
- **The finished parser is as fast as the prototype was.** `records-2k`'s
  `parse`, at 171 MB/s, is ADR-0004's 173 MB/s for the prototype with its
  callback stack.

## On the M1 laptop

**Conditions.** The owner ran `make bench` twice on the M1 laptop: Darwin
25.6.0, Chez 10.4.1 and yajl 2.1.0 from Homebrew, the harness built by Apple
clang 21 at `-O2`, unpinned. The reports' UTC date is 2026-11-09. These
runs decide nothing (Decision 1). Every ratio below was computed by a script
from the two reports and the NUC's.

- **The runs agreed closely.** Across the 32 rates of the yajl table, a
  rate moved by 0.2% at the median and 4.3% at most between them, and a gap
  by 4.0% at most.
- **The gaps are smaller.** `events` is 1.7× to 3.4× behind yajl, and
  `parse` 1.5× to 7.3×. `records-2k` is 3.0× and 3.1× behind, against 2×.
  `escaped-string` is 3.0× in both runs, under its 4×, so the report calls
  it met there.
- **That is yajl running slower, not jsonparse running faster.** Against the
  NUC's medians:
  - yajl's ran at 0.59 to 0.95 of them;
  - jsonparse's `parse` and `events` at 0.85 to 1.04;
  - its `tree`, `tree+walk` and `scan` at 0.87 to 1.13, in the second run.
- **Why isn't measured.** An M1 performance core runs at up to 3.2 GHz,
  against the NUC's 4.5, and Homebrew's flags for libyajl aren't known.
- **The Mac's build works:** Homebrew's yajl, through pkg-config and the
  prefix's `include/`, and Homebrew's Chez, named `chez`.

## Consequences

- **M3's targets can be checked by anyone with `make bench`.** A report
  can't show a rate for a counting lane that skipped work or ran fewer
  passes. `parse` and `tree` count nothing, so their passes are checked to
  finish and to be as many as the method says, but not what they did
  inside.
- **A gap within about 10% of its target needs several pinned runs** before
  it is called met or missed. A met target on `escaped-string` also needs
  the parts joined, as yajl does.
- **A target met on the M1 says nothing about the NUC.** The machines put
  yajl at different speeds: the M1's `events` gaps are 0.57 to 0.76 of the
  NUC's on seven files, and 0.98 on `poet`.
- **The levers, in the light of the profile:**
  - **The callback path** costs several times yajl's per value. The first
    step is to separate the machine's span delivery from jsonparse's
    handler path, then cut what is jsonparse's. That part needs no
    byte-machine change.
  - **The run node (plan M3, lever 2)** attacks the string-body cost:
    `escaped-string`, `gsoc-2018` and `poet`. Reading a byte at a time, the
    scan's 1.6 ns per byte bounds it. Reading words could go lower, if it
    can still check what a string body must.
  - **`records-2k`'s 2× needs both, and more:** its strings are short, so
    most of its cost is per token. If the run node and a cheaper callback
    path don't close it, the target is to be revisited with the owner, not
    quietly missed.
  - **The number fast path (lever 4)** matters most to `tree` on number-heavy
    files, which the targets don't measure.
- **M2 waits,** as ADR-0004 says. Its measured gain of 11% on `records-2k`
  can't close a 2× gap alone.
- **byte-machine's own baseline stays byte-machine's.** Its file names
  `tarm64osx`, and the plan's exit criterion of updating it is met there,
  by the owner on the M1 laptop, when the run node lands.
- **`make bench` needs the network once, on the host,** like the Akku tool,
  and a C compiler, pkg-config and yajl where there is no Guix.
