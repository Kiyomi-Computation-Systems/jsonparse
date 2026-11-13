# ADR-0026: The generated parser reads a run in a loop, from byte-machine 0.9.0

- **Status:** Accepted. The Akku archive listed byte-machine 0.9.0 on
  2026-11-10, and `Akku.lock` moved on 2026-11-11.
- **Date:** 2026-11-09
- **Scope:** jsonparse's byte-machine pin, floor and lock;
  `(generated jsonparse)`; plan M3's lever 2
- **Related:** ADR-0002, ADR-0003, ADR-0004, ADR-0023, ADR-0025;
  byte-machine's decision 0059; the brief
  [2026-11-09-upstream-run-loop-brief.md](../2026-11-09-upstream-run-loop-brief.md)

> **Revision (2026-11-12, slice 16).** The callback step, which the
> consequences below name as the next lever, isn't inlined for now
> (ADR-0028). It waits as byte-machine #184 and jsonparse #20.
>
> Every run below compiled its libraries in the process it then timed,
> which skews a figure by 1% to 4% at the median (jsonparse #22). That
> includes the prototype's "12% to 13%". Slice 16's probe loaded compiled
> objects and put it at 8.5% off `records-2k`'s `events` time, and 12.5%
> off `parse`.

> **Revision (2026-11-12, slice 17).** The run loop, re-timed on compiled
> objects:
> - **A and B:** A is the code just before this record (`7e9a653`,
>   byte-machine 0.8.0); B is this record's (`46fca90`).
> - **Method:**
>   - three object sets per variant, each compiled in a process of its own;
>   - two runs per variant per set, taking turns, through
>     `scripts/bench-chez`;
>   - `bench/run.sps` at 9 rounds of 10 MB, where `make bench` reads 20.
>
>   Each figure is B's time saved against the A run beside it, median
>   [least, most] over six pairs.
>
> | File | `events` | `parse` | `tree` |
> |:--|--:|--:|--:|
> | gsoc-2018 | 41.6% [41.0, 43.4] | 44.4% [43.2, 45.8] | 27.9% [27.1, 29.1] |
> | poet | 7.0% [4.0, 10.9] | 8.0% [4.1, 10.0] | 4.3% [−2.7, 10.0] |
> | twitter | 4.5% [3.2, 5.2] | 6.2% [5.7, 7.0] | 2.7% [1.0, 4.6] |
> | canada | 2.1% [0.6, 6.5] | 1.9% [0.3, 2.9] | 0.2% [−0.8, 0.7] |
> | escaped-string | 1.7% [−0.8, 6.6] | 8.0% [4.7, 8.6] | 0.0% [−2.0, 3.4] |
> | ints-40k | −0.1% [−1.1, 2.8] | 1.4% [−0.5, 5.1] | −0.6% [−1.9, 2.0] |
> | records-2k | −2.5% [−3.4, −2.1] | −0.9% [−5.5, −0.3] | −1.7% [−3.1, 0.4] |
> | citm | −5.6% [−6.0, −5.2] | −7.5% [−7.8, −5.7] | −1.8% [−2.4, −1.3] |
>
> - **`gsoc-2018`'s 40% stands.**
> - **The other files' moves can't be put on the loop.**
>   - **The control:** `scan` runs the harness's own code, the same in A
>     and B. Yet on `canada` it took 5.9% [4.1, 21.2] more time in B, in
>     every pair and every object set.
>   - **Why the object sets don't settle it:** they vary what each
>     compile lays out. They don't vary the shift that B's larger generated
>     parser, about 9 KB more, gives everything loaded after it.
>   - **So these are layout-sized:** `citm`'s 5.6% more time in `events`,
>     `records-2k`'s 2.5% more, and `poet`'s 7.0% less. They may be the
>     loop's own work, or the shift. The bar below for settling `citm`
>     still stands: Vr over more turns, or a way to measure layout's
>     part.

## Context

**Plan M3's lever 2 was a run node:** a new node kind, so a decision record
in byte-machine and an ABI bump. ADR-0025 put byte-machine's callback cut
beside it, under the same bump.

**Prototypes on jsonparse's generated parser (the brief) changed that.**
A state that advances back to itself on a class of bytes can read the run
in a tight loop, with only `(rnrs)` operations. So it needs no new node kind
and no new runtime name, and the ABI can stay 9. Inlining the callback step
reaches into the runtime's parser, so it does need ABI 10.

**The owner chose on 2026-11-09** to build the run loop at ABI 9, under
byte-machine's own process, and to leave the callback step to a later slice
with ABI 10, with M2 decided first.

**byte-machine 0.9.0 has it,** as decision 0059: PR #180 (`4268a84`), then
the release, #181 (`fdd4da0`, tag `v0.9.0`). Two adversarial reviews found
one defect and several gaps, all fixed before it merged:
- `render-machine` raised on a state whose fallback looped but could never
  be taken;
- a number of test gaps.

They also found 8 mutation pins that match their twin mutants. byte-machine
inherited that from 0.8.0, and it is recorded there, not fixed.

It doesn't meet byte-machine's own improvement rule (0048 rule 2) on
byte-machine's benchmark. The owner, told so, admitted it on jsonparse's
evidence.

## Decision

1. **jsonparse moves to byte-machine 0.9.0.**
   - `vendor/byte-machine` is at `v0.9.0` (`fdd4da0`), and the Makefile's
     pin and tag move with it.
   - `Akku.manifest` declares `^0.9.0`.
   - `Akku.lock` moves to 0.9.0's archive entry once the archive lists it,
     up to a week after the 2026-11-09 submission. Until then the PR stays
     a draft, since `make check-versions` holds all three together
     (ADR-0002).
2. **`(generated jsonparse)` is regenerated.**
   - 14 states loop: the two string bodies, nine whitespace states and
     three digit states.
   - Two classes need a table, the string body's and whitespace; the
     digits test one range.
   - It grows from 92,635 bytes to 102,006.
   - Its fingerprint, `8628246217050196640`, and the ABI, 9, are unchanged.
   - Nothing a caller sees changes: every suite passes as before.
3. **Lever 2 is done as a lowering, not a node kind.** This amends three
   earlier statements:
   - the plan's "needs a decision record, because it is a new node kind and
     an ABI bump";
   - ADR-0025's "under one ABI bump": byte-machine's callback cut takes
     ABI 10 without the run loop;
   - ADR-0004's "ships in the same byte-machine release as M3's run node".
     The owner chose on 2026-11-09 to decide M2 before the callback cut.
     M2, if taken, ships with the ABI-10 change, so the consumers still
     regenerate once for the bump.

   Each of the three records has a revision note.
4. **A byte-machine release that changes only the emitted text, with the
   ABI the same, leaves every other consumer working without regenerating.**
   chez-httparse's and uriparse's parsers, regenerated in scratch clones,
   pass their suites with their fingerprints unchanged.
5. **But Akku installs one byte-machine per application, and reads `^0.y.z`
   as `>=0.y.z <0.(y+1).0`.**
   - chez-httparse, chez-http-server and uriparse declare `^0.8.0`, which
     shares no version with `^0.9.0`.
   - So no application can install a jsonparse that declares `^0.9.0`
     beside any of them until it admits 0.9.
   - jsonparse isn't on Akku yet, so nothing breaks today. The owner chose on
     2026-11-09 to keep `^0.9.0`. A jsonparse release to Akku waits until
     the siblings admit 0.9, by regenerating and releasing on it.

## The measurement (2026-11-09)

**Conditions.**
- On the reference machine, pinned to CPU 7, `bench/run.sps` took turns
  between `main`'s parser (A) and the regenerated one (B), in three
  rotations:
  - A B A B;
  - A B B A A B;
  - A B Vc Vr Vr Vc B A, where Vc and Vr are the variants below.
- B was the same file in all three.
- In the A B A B rotation, `bench/callbacks.sps` ran after each run.
- `make bench` then ran twice with `BENCH_PARSERS=` empty.
- Every figure below was computed by a script from the results files. A
  figure is B's change in time a byte against its own rotation's A.
- A's own runs moved within a rotation by up to 5.8% in `events`, 9.6% in
  `parse` and 7.5% in `tree`, all on `ints-40k`.

**B's change, seven runs:**

| File | `events` | `parse` | `tree` |
|:--|:--|:--|:--|
| gsoc-2018 | −42% to −40% | −44% to −42% | −28% to −27% |
| twitter | −11% to −5% | −13% to −7% | −5% to −2% |
| poet | −6% to +1% | −7% to +2% | −5% to +1% |
| escaped-string | −4% to −2% | −9% to −4% | −2% to +1% |
| records-2k | −5% to 0% | −6% to +1% | −3% to +1% |
| canada | −8% to +1% | −4% to 0% | −4% to +1% |
| citm | 0% to +7% | −2% to +8% | −1% to +4% |
| ints-40k | −1% to +3% | −5% to +2% | −1% to +2% |

**The loop pays on long runs of ASCII.**
- `gsoc-2018`'s ASCII stretches average 67 bytes, and it takes about 40%
  less time.
- `twitter`'s average 14 bytes.
- `records-2k`'s average 5 bytes, so it hardly moves.
- `escaped-string`'s average 29 bytes, but between clusters of four escapes
  (`\n`, `\u00e9` and a surrogate pair). Each escape costs far more than a
  byte of text, so the file moves little.
- `poet`'s strings are long too, but 87% of their bytes are multibyte. The
  loop's class is ASCII, so `poet` moves little.

**A change of several percent on one file can't yet be pinned on the
loop's own work.**
- Two variants changed only the whitespace loops:
  - Vc: whitespace states call themselves a byte at a time again;
  - Vr: whitespace loops test ranges, not the table.
- Vr took 10% more time in `events` on `ints-40k`, which has no whitespace,
  in both of its runs, and the same time in `parse`. Vc took 3% to 5% less
  on `records-2k`, which has none either. What moves those files isn't
  known. One candidate is code layout: every state is a procedure inside
  one `exec` closure.
- `citm` is 71% whitespace, in runs averaging 16 bytes. Against A it took
  0% to 7% more time with B, 0% to 1% less with Vc, and 5% to 9% less with
  Vr. So range tests may suit a class as small as whitespace's four bytes,
  but that isn't established.

**Against yajl, in `make bench`:**
- `records-2k`'s `events` gap is 4.02× and 4.17×, against the 2× target.
- `escaped-string`'s is 4.26× and 4.47×, against 4×.

Neither target is met. ADR-0025 had 4.00× and 3.95×, and 4.65× and 4.30×.

## Consequences

- **Long runs of ASCII in strings take about 40% less time,** in `events`
  and `parse`, and trees of them 27% less. Long multibyte text, as in `poet`,
  changes little.
- **Neither M3 target moves.** Their files are short strings and escapes.
  ADR-0023 said the targets are revisited with the owner if the run node
  and a cheaper callback path don't close them. The callback step, inlined
  under ABI 10, is the next lever. Its prototype took 12% to 13% off
  `records-2k` (the brief, P3), so the revisit comes after it.
- **`citm`'s 0% to 7% isn't established either way.** It would be settled by:
  - a byte-machine variant whose small classes test ranges, measured over
    more turns;
  - or a way to measure how much of a move is code layout's.
- **The lock waited for Akku,** and with it this slice's merge.
  - **CI meanwhile ran nothing:** `make test` needs `check-versions`, so
    the draft's jobs stopped before any suite, on amd64 and arm64.
    byte-machine's own CI is amd64 only, so the regenerated parser had no
    Linux arm64 run until the lock moved.
  - **Moving the lock:** `scripts/akku lock` writes it. Keep only
    byte-machine's entry's change, since the run may move chez-cmark-gfm's
    too. Then check by hand the archive file's sha256 against the lock:
    `check-versions` reads only the URL's version.
  - **It moved on 2026-11-11:**
    - the archive file's sha256 is the index's and the lock's;
    - its 215 files are `git archive v0.9.0`'s, byte for byte;
    - Akku 1.2.0's `lock` also reformatted the file and swapped its two
      entries. chez-cmark-gfm's entry was the same, so the commit changes
      only byte-machine's URL and sha256.
- **A jsonparse release to Akku waits for the siblings,** which must admit
  byte-machine 0.9 first (Decision 5).
- **M3's other exit criterion, byte-machine's own baseline, is met.** The
  owner retook it on the M1 laptop at v0.9.0 (byte-machine #183,
  `e86d1bd`).
  - Against the baseline it replaces, from the 0.6.0 cycle, header names
    and values take 7.8% less time and byte-at-a-time 6.2% more.
  - Those figures mix every byte-machine change since that baseline, so
    they don't isolate the loop.
