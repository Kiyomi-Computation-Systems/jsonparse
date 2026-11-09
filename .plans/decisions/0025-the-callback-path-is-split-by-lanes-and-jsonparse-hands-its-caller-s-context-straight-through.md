# ADR-0025: The callback path is split by lanes, and jsonparse hands its caller's context straight through

- **Status:** Accepted
- **Date:** 2026-11-09
- **Scope:** `make bench-callbacks` and `(jsonparse-bench callbacks)`; how
  `(jsonparse parser)` binds byte-machine's callbacks; what the callback
  path costs, and whose cost it is
- **Related:** ADR-0002, ADR-0004, ADR-0010, ADR-0015, ADR-0023

## Context

ADR-0023 found that callbacks add 6 to 13 ns per counted value in
jsonparse, against yajl's 1.8 or less. That figure is `events` less
`parse`, so it mixes three costs:

- **byte-machine's:** at every callback site the emitted code calls the
  runtime's callback step, bound or not. The step commits the state and
  offset. For a bound callback it then calls the procedure with the parser
  and its user context, and classifies what it returns. A text part also
  moves the span's mark.
- **jsonparse's:** its bound procedure read the caller's context out of
  its own state record, the user context it gave byte-machine. It then
  called the handler's procedure, and checked the result for a stop.
- **the handler's own work,** counting.

ADR-0023 set the next step: separate them, then cut what is jsonparse's,
which needs no byte-machine change.

A probe on 2026-11-09 did the first, in two pinned runs on canada, citm,
ints-40k, records-2k and twitter:
- of the 8.7 to 13.2 ns a value, byte-machine's delivery to bound
  procedures was 4.4 to 6.8, the counting 2.6 to 3.3, and jsonparse's
  binding 0.9 to 3.4;
- poet put counting at 1.7, outside those ranges;
- its no-op lane bound two callbacks the counting lane doesn't, which moved
  about 1.1 to 2.4 ns a value from counting into byte-machine's share. The
  committed lanes fix that.

Free callbacks would still leave `records-2k`'s `parse` at 5.9 ns a byte,
less the unbound callback steps it pays too. Those are about 0.5 ns a byte,
by an unpinned estimate. The 2× target allows `events` 3.6.

The owner chose on 2026-11-09 to cut jsonparse's part alone in this slice,
and to leave byte-machine's to a slice of its own beside the run node.

## Decision

1. **`make bench-callbacks` splits the path,** with eight lanes of
   `(jsonparse-bench callbacks)`, each a new parser a pass:
   - `parse`: jsonparse with a handler of no procedures;
   - `m-events`, `m-spans` and `m-noop`: byte-machine's own parser on
     `jsonparse-machine`, with the stack's callbacks, and the counted
     callbacks bound to procedures that do nothing. `m-events` binds those
     that carry no bytes, `m-spans` the two that do, and `m-noop` both;
   - `m-count`: the same callbacks, counting as the events lane does;
   - `m-all`: `m-noop` with `string-start` and `key-start` too;
   - `j-noop`: jsonparse with all fourteen procedures doing nothing;
   - `events`: the events lane.

   About the lanes:
   - The counted callbacks are the ones `(jsonparse parser)` binds for the
     events lane's counting handler. `make test` holds `m-noop` and
     `m-count` to that list, but the list is kept in step with
     `parser.sls` by hand.
   - The m- lanes keep their stack as jsonparse does, and hand callbacks
     the caller's context as it does.
   - A no-op `escape` reads the escaped code unit, as any procedure bound
     to it must.
   - A pass's set-up differs between the two lanes of a split by a
     constant, at most 0.42 µs, measured on `[]`. That is under 0.02 ns a
     value on every file that gets a split, the fewest values being
     twitter's 27,259.

2. **A split is per value, keys included:**
   - `byte-machine` is `m-noop` less `parse`: delivering the counted
     callbacks to procedures. `parse` already pays the callback step at
     every site, so this column doesn't include it.
   - Its events and spans are `m-events` and `m-spans` less `parse`.
   - `counting` is `m-count` less `m-noop`.
   - `jsonparse` is `events` less `m-count`. Over all fourteen procedures,
     it is `j-noop` less `m-all`.
   - `calls` is the counted callbacks delivered a value. On text-heavy
     files most of the cost is per part and per escape, not per value.
   - A file of fewer than 1,000 values gets no split.

3. **The lanes take turns.** Each lane has a warm-up round, then 9 turns in
   which each lane has one timed round. Each turn starts one lane later.
   Otherwise this is ADR-0023's method, on the files `bench/files.lock`
   names, pinned, with the libraries compiled ahead of time into objects of
   its own.
   - A split is the median of the turns' paired differences, shown with
     the least and most of their middle half.
   - `m-count`'s one pass must count what the events lane counts before a
     file is timed. Each lane's tally must then show the method's passes,
     and `m-count`'s and `events`' must show those passes' counts.
   - Anything wrong, MACHINE first, stops it with exit 1 before
     `build/bench/callbacks.md` is replaced.
   - It times no comparator, so it fetches only the files. It still runs in
     `scripts/guix-env --bench`'s container, for `taskset`.

4. **jsonparse gives byte-machine the caller's context as its user
   context.** A handler's procedure gets the context byte-machine hands
   over, with no lookup. The stack's callbacks and `escape` close over the
   parser's own state instead.
   - Nothing a caller sees changes: the handler, the context, the stops,
     the results and the allocation per feed are as before.
   - A stop is still checked on every return, as ADR-0015 says. A stop
     from `escape` on a surrogate pair, the one path no test stopped on,
     now has its case.

## The measurement (2026-11-09)

**Conditions.** On the reference machine, pinned to CPU 7, the parser on
`main` (A) and this one (B) ran in turn: A, B, A, B. Each time,
`bench/run.sps` came first, then `bench/callbacks.sps`. Then `make bench`
ran twice with `BENCH_PARSERS=` empty. Every figure was computed by a
script from the results files, first pair first.

**The cut is small.**
- In `events`, B reads `ints-40k` 4.5% and 3.5% faster than A, and
  `records-2k` 0.8% and 2.9% faster. The other six files moved −3.0% to
  +2.7%, which is noise.
- `parse` moved about as much on `ints-40k` (+5.0%, +3.8%) and
  `records-2k` (+1.3%, +2.8%). The stack's callbacks changed too.
- On the five files dense in values (canada, citm, ints-40k, records-2k and
  twitter), jsonparse's share went from 0.9–3.0 ns a value to 1.0–2.4.

**The split, in B's two runs, on those five files, in ns a value:**

| Part | Its range |
|:--|:--|
| byte-machine's delivery | 4.1 to 7.4 |
| its events alone | 1.5 to 3.0 |
| its spans alone | 2.5 to 4.9 |
| counting | 1.0 to 3.4 |
| jsonparse | 1.0 to 2.4 |
| jsonparse, all fourteen | 1.4 to 4.9 |
| all | 8.0 to 12.7 |

**Run to run, the splits move by more than their middle half shows.** In
B's two runs, canada's `byte-machine` read 4.3 [4.1, 4.7] and then 6.6
[6.4, 7.0]. On the five files, a split moved by up to 2.3 ns between B's
runs, so a smaller difference between two runs means nothing. On
`gsoc-2018`, which has few values for its size, it moved by up to 4.8 ns.
A third run of B, by `make bench-callbacks` itself, put canada's
`jsonparse` at 3.2 [3.1, 3.4] and its `all` at 11.3, against 8.0 and 8.7
before: a whole run can shift too.

**Against yajl, in `make bench`:** `records-2k`'s `events` gap is 4.00×
and 3.95×, and `escaped-string`'s 4.65× and 4.30×, against 2× and 4×.
Neither target is met, as in ADR-0023.

## Consequences

- **jsonparse's binding still costs about 1 to 3 ns a value.** What is left
  is the call to the handler's procedure, the stop check, the filter that
  keeps empty parts from the handler, and joining surrogate pairs. None of
  that can go without changing the handler's contract (ADR-0015).
- **The rest is byte-machine's,** and the handler's own work:
  - delivery to bound procedures costs 4 to 7 ns a value;
  - the callback step `parse` pays at every unbound site is beside it.

  The next cut is in byte-machine's callback step and span delivery, a
  byte-machine change beside the run node, under one ABI bump (ADR-0002).
- **`records-2k`'s 2× target can't be met by callbacks alone.** That
  needs the machine's own cost a byte cut too, as ADR-0023 said.
- **`make test` checks the lanes, not their times:** m-count's counts, by
  hand and against the events lane; the bindings of every m- lane and both
  jsonparse lanes; the calls; the tallies; the turns; the split; and the
  report.
