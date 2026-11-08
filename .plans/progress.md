# Progress ledger

Where jsonparse stands. Read it with
[global-constraints.md](global-constraints.md) before starting slice work.
When a slice merges, update **Now** and add a close-out under **Close-outs**,
newest first.

## Now

- **Milestone 0, the prototype and its measurements, is done** (2026-10-03).
  The plan is
  [project-plan/2026-10-03-byte-machine-json-plan.md](project-plan/2026-10-03-byte-machine-json-plan.md);
  the prototype is beside it.
- **The plan was revised on 2026-10-30 with the owner's answers to its §7.**
  ADR-0001 to ADR-0011 record them, and none of its questions is open.
  ADR-0012 to ADR-0014 add the test corpora, the benchmark comparators and
  streams of values.
- **Three measurements were made the same day:**
  - the stack, on the prototype regenerated with byte-machine 0.8.0
    (`prototype/stack-*.sps`, ADR-0004);
  - number conversion and printing (ADR-0011);
  - how textual ports decode invalid UTF-8 (ADR-0010).
- **The planning merged on 2026-10-30** as #1.
- **Slice 0, the scaffolding, is done** (close-out below).
- **Slice 1 of M1, the grammar and the generator, is done** (close-out
  below).
- **Slice 2, the push parser, is done** (close-out below).
- **Slice 3, the assembler, is done** (close-out below).
- **Slice 4, the tree builder, is done** (close-out below).
- **Slice 5, the writer, is done** (close-out below).
- **Slice 6, the easy layer, is done** (close-out below).
- **Slice 7, streams of values, is done** (close-out below). Every library
  the plan's M1 lists now exists. Nothing is planned after it yet.

## Next

**Milestone 1, in order:**

1. **The grammar and generator** (done, close-out below).
   - They move from the prototype into `grammar/`, outside `src/`
     (ADR-0003). The committed `(generated jsonparse)` gets its regeneration
     check.
   - The corpora are vendored, with the license and `SOURCE` check
     (ADR-0012).
   - Gates: JSONTestSuite `y_` and `n_`, the `i_` results pinned in a golden
     file, yajl's event streams, chunking invariance, an
     interpreter-versus-generated differential, and mutation fuzzing.
2. **`(jsonparse parser)`** (done, close-out below).
   - It covers the internal stack, the options record and the depth limit
     (ADR-0004, ADR-0005), behind a handler of named procedures (ADR-0015).
   - Its results use jsonparse's own types (ADR-0010).
3. **`(jsonparse string)`** (done, close-out below): the assembler, the
   number modes and the digit limit (ADR-0011, ADR-0016).
4. **`(jsonparse tree)`** (done, close-out below): the builder and the
   `object-mode` and `null` options (ADR-0006, ADR-0017).
5. **`(jsonparse writer)`** (done, close-out below): `put-json`,
   `&json-error` and the `indent` option (ADR-0018).
6. **`(jsonparse easy)`** (done, close-out below): reading, writing,
   `json-ref`, `json=?` and `json-null?`, and `check-json` in the writer
   (ADR-0019).
7. **`(jsonparse sequence)`** (done, close-out below): JSON Lines and
   NDJSON, RFC 7464 and whitespace-separated values, and the easy layer's
   stream procedures (ADR-0014, ADR-0020).

## Close-outs

### Slice 7: streams of values (2026-11-08)

- **Landed:**
  - **The grammar under the `mode` bit** (ADR-0014's revision, ADR-0020):
    a top-level number or literal needs whitespace or the end after it, so
    `1-2` and `truefalse` fail, and an empty stream holds no values.
    Without the bit nothing changes.
  - **Options:** `stream` (`lines`, `seq` or `values`) and `blank-lines`
    (`error` or `skip`). `stream values` sets the bit.
  - **`(jsonparse sequence)`** (ADR-0020):
    - a reader frames `lines` and `seq` records by byte, for one reused
      builder, and never copies a record. Under `values` one builder reads
      the whole stream;
    - offsets count the stream's bytes, and records count from 1;
    - a bad record ends the stream, or is skipped and reported when
      ON-SKIP is given. Giving the procedure turns skipping on: the owner's
      choice, which revises ADR-0014;
    - its own codes are `blank-line`, `truncated`, and `unexpected-byte`
      before the first RS.
  - **Beside it:** the builder's EACH, `make-json-result`,
    `put-json-record` and `&json-record-error`.
  - **The easy layer:** `read-json-sequence`, `bytevector->json-sequence`,
    `fold-json-sequence`, `write-json-sequence` and
    `json-sequence->bytevector`, the owner's choice of names. The
    one-document readers refuse `stream values`.
  - **Suites:** `sequence` (442), `stream-api` (711), `sequence-alloc`
    (678), `easy-sequence` (460) and `sequence-property` (62). The
    `machine` suite's mode cases were rewritten (575).
  - **Corpus:** SRFI 180's JSON Lines and RFC 7464 files, read by the
    `sequence` suite.
  - **Records:** ADR-0020, revision notes on ADR-0014 and ADR-0019,
    `docs/sequence.md`, and additions to the other docs and the global
    constraints.
- **Results** (ADR-0020):
  - **`lines` and `seq` pay a builder's reset, feed and finish a record:**
    0.13 to 0.19 µs more than one array. That is 10 to 12% on records of
    92 bytes, and 2.1 to 4.4 times on values of 5 to 19 bytes.
  - **`values` reads at one array's speed,** 0.88 to 0.99 times as long.
  - **The separator scan** is 4 to 12% of reading `lines`.
  - **A record of `123456` costs 944 bytes** in `lines` or `seq`, and 129
    in `values`, where the reader adds 80 to an EACH builder.
- **Evidence:**
  - `scripts/guix-env make test` runs 32 suites in about 65 s.
  - **Every assertion was watched fail,** or reported as covering an
    equivalent change. About 450 mutants of the library and the grammar
    were run, by four builders, the review and me, and 43 of the property
    suite.
  - **The `sequence` suite reads 26,494 chunkings** of its streams: every
    split, every pair of splits, and chunks of 1, 2, 3 and 7 bytes.
- **Review:** an adversarial review found no library bug in normal use.
  - **Its one gap:** a reset that kept the record's first byte passed every
    suite. A stale byte turns an array into a `truncated` number, or a
    blank line into content. Three cases after a reset now fail on it.
    Checking every other field a reset clears found one more, `last`,
    which nothing reads before it is set again: removed as dead.
  - **Four claims were false or too broad:**
    - when a number is announced;
    - that every skipped record reaches ON-SKIP;
    - that the easy layer reads one document;
    - that each `values` record is a new parse.

    All are corrected, in ADR-0020, the constraints, the docs, and a
    revision note on ADR-0019.
  - **Its notes:** a reader keeps its largest string buffer, and re-entry
    into a continuation isn't detected. Both are now in ADR-0020 and
    `docs/sequence.md`.
  - **Before it,** a mutant of mine making enter and leave thunks on every
    call passed the allocation suite's bound of 128 bytes a record. A bound
    of 96 a value under `values` now fails it.
- **Known:**
  - **Under `values`, a corrupt stream can deliver values before its
    error:** `1 2x` gives 1 and 2, then `unexpected-byte` in record 3.
  - **A raw newline or RS ends a record,** even inside a string.
  - **Only `seq` detects a cut-off last record.** A `lines` stream's last
    line may lack its newline.
  - **Re-entering a continuation captured inside a reader's procedures**
    isn't detected (ADR-0020).

### Slice 6: the easy layer (2026-11-07)

- **Landed:**
  - **`(jsonparse easy)`** (ADR-0019):
    - **reading:** `string->json`, `bytevector->json` and `read-json`
      read one whole document with a new builder. Bad input raises
      `&json-error`, with the parser's code as its reason. Its offset is
      in characters for a string and in bytes otherwise;
    - **writing:** `json->string`, `json->bytevector` and `write-json`
      compose `put-json`. A refusal is raised again with the easy
      procedure as its who, and what a caller's port raises passes
      through;
    - **`json-ref`** follows a path, the last duplicate winning. Where it
      leads nowhere, it raises `not-found`, or gives the value after a
      closing `'default`, the owner's choice of form;
    - **`json=?`** checks both values as `put-json` would, then compares
      objects as unordered members, the last duplicate winning, and
      numbers by exact value. A `json-number` costs time linear in its
      text, however long its exponent;
    - **`json-null?`**, and re-exports of `&json-error`, the options and
      `json-number`.
  - **`(jsonparse writer)`:** `check-json`, the check `put-json` runs
    before writing, on its own, with its own who.
  - **Suites:**
    - `easy`: hand-written cases for every procedure, every error code
      through each reader, ports across chunk boundaries and re-entrant
      ports, every hashtable equivalence, numbers in every spelling,
      exponents past 10^19, and the arguments;
    - `easy-property`: the corpus through both layers under six option
      sets; character offsets under 3,000 mutations; `json=?` against an
      oracle of its own; alists against hashtables; round trips.
  - **Records:** ADR-0019, `docs/easy.md`, the global constraints, and
    notes in `docs/writer.md` and `docs/tree.md`.
- **Results:**
  - **Both layers return the same values:** on all 376 corpus files, under
    six option sets, through each reader, easy's value or error matches a
    builder's.
  - **Character offsets:** every one of 185,179 errors on valid UTF-8
    landed on a character's first byte or the end, so a character offset
    is the count of characters before the byte offset.
  - **Measurements** (ADR-0019):
    - `string->json` costs 9 to 28% more than reading bytes;
    - `json=?` takes 11 to 43% of reading on ADR-0018's documents, and up
      to 2.5 times on one object of 90,000 members held in hashtables;
    - `read-json` costs 21 KB per call, mostly its 16 KiB buffer.
- **Evidence:**
  - `scripts/guix-env make test` runs 27 suites in about 44 s. The new
    ones pass 1,460 and 57.
  - **Every assertion was watched fail.** The builders ran about 240
    mutants of the library and 14 of the property suite. Of the review's
    and the fixes' 22, and 9 of `json-ref`'s default, all now fail the
    hand-written suite.
  - **A reference in Python** that shares no code with the library agreed
    with `json=?` on 4,000 number pairs, 1,353 of them with exponents of
    20 digits or more.
- **Review:** an adversarial review found two defects:
  - `json=?` took time quadratic in a `json-number`'s exponent digits:
    6 s for 200,000 digits, which `text` mode reads in 1 ms. A server
    comparing untrusted values was open to denial of service;
  - `write-json` relabelled or lost a `&json-error` raised by the
    caller's own port.

  Its other findings:
  - nine mutants both suites survived: `check-json`'s who at three
    refusals, continuable raises, read errors without irritants, and `#f`
    members;
  - figures in ADR-0019 its own table contradicted;
  - claims about wrong arguments and irritants that overstated the code;
  - gaps in `docs/easy.md`.

  All are fixed, each fix watched fail:
  - an exponent past 19 digits is added to as text: 1 ms at 200,000
    digits;
  - `write-json` relabels only its check;
  - read errors carry empty irritants.
- **Known:**
  - **`json=?` can't see duplicate keys,** and needs the options the
    values were read with.
  - **`json=?` on hashtables pays for sorting each table's keys** in its
    check, as `put-json` does.
  - **A closed port** fails in the R6RS procedure that reads or writes
    it, not in easy's check.

### Slice 5: the writer (2026-11-06)

- **Landed:**
  - **`(jsonparse writer)`:** `put-json`, which writes a value as UTF-8 to
    a binary port (ADR-0018):
    - it writes what the builder builds, under any options: alists and
      hashtables, a hashtable's members in key order;
    - numbers follow ADR-0011, a fixnum's digits written directly;
    - a value is checked whole before a byte is written, so a refusal
      leaves the port as it was;
    - refusals raise `&json-error` with a reason: `unwritable-number`,
      `unwritable-key`, `unwritable-value` or `nesting-too-deep`.
  - **`(jsonparse error)`:** `&json-error`, an `&error` with a reason and
    an offset, below the easy layer.
  - **`(jsonparse options)`:** `indent`, from 0 (compact, the default) to
    10.
  - **A fix in `(jsonparse string)`:** Chez's `utf8->string` drops a
    leading U+FEFF, so a string or key starting with one, raw or escaped,
    read back without it. `json-assembler-string!` now keeps it
    (ADR-0016).
  - **Suites:**
    - `writer`: hand-written outputs for every kind of value, every
      control character, numbers at every digit boundary, hashtable order,
      layout, every refusal with nothing left on the port, the arguments
      and the `indent` option;
    - `writer-property`: round trips through the builder under seven
      option sets, ADR-0011's number property, the corpus as a fixed
      point, and layouts that change nothing;
    - `string` and `string-alloc` gain the U+FEFF cases.
  - **Records:** ADR-0018, a note in ADR-0016, and `docs/writer.md`.
- **Results:**
  - **Round trips:** 3,000 generated trees under each of seven option
    sets read back as expected, worked out from the tree alone. ADR-0011's
    property holds:
    - 12,000 exact numbers in `exact` mode;
    - 20,000 flonums in `flonum` mode, subnormals and `-0.0` included;
    - 12,000 `json-number` texts in `text` mode.
  - **The corpus is a fixed point:** every file the builder accepts reads,
    writes and reads back to the same tree, and writes the same bytes
    again, under four option sets.
  - **Chez's flonum printer** gives JSON for every finite flonum once its
    `|` suffix is cut. Every one reads back `eqv?`, over a million random
    bit patterns in the review's run.
  - **Measurements** (ADR-0018):
    - writing is 2 to 3 times faster than reading, but for flonums, at
      about 36 ms per MB;
    - the check pass costs 0.2 to 0.9 ms per MB.
- **Evidence:**
  - `scripts/guix-env make test` runs 25 suites in about 45 s. The new ones
    pass 568 and 27, and `string` and `string-alloc` now pass 207 and 27.
  - Every assertion was watched fail. The builders ran about 500 mutants,
    and the reviewer 106. Of the reviewer's, 97 failed a suite at once.
    Its findings added a test for one more. The other eight can't change
    the output.
- **Review:** an adversarial review found no wrong output. It found:
  - the global constraints saying both that the low layer never raises on
    bad input and that the writer raises;
  - a hashtable not keyed by `string=?` writing two keys with the same
    text in an order that changed from run to run;
  - `indent` unbounded, so one option could ask for 2^60 spaces;
  - `put-fixnum`'s buffer assuming 64-bit fixnums;
  - the round-trip claim missing the reader's range, as for a
    `json-number` `1e400`;
  - tests expecting `#f` from something that can raise;
  - a string-allocation claim made false by the U+FEFF fix, with a
    mutant changing only allocation;
  - a reason in ADR-0018 its own table contradicted, dates a day ahead,
    and a test header overstating its independence.

  All are fixed, each fix watched fail:
  - a table holding two keys with the same text is refused;
  - `indent` is capped at 10;
  - the buffer is sized from `(greatest-fixnum)`.
- **Known:**
  - **The writer doesn't apply the reader's digit limit or range.** A
    number past either is written, and a reader in `flonum` or `exact`
    mode refuses it. At a small digit limit, reading, writing and reading
    again may not be a fixed point (ADR-0018).
  - **A flonum's text comes from Chez's `number->string`,** in the writer
    and in the tests' expectations alike. Only the `eqv?` round trip
    checks it.
  - **A laid-out value grows with the square of its depth.**
  - **Chez's `utf8->string` drops a leading U+FEFF.** The assembler works
    around it; any new caller of `utf8->string` must too.

### Slice 4: the tree builder (2026-11-06)

- **Landed:**
  - **`(jsonparse tree)`:** the builder, one record holding a parser, an
    assembler and a stack of values (ADR-0017):
    - feed and finish return the parser's own results;
    - each container is built once, at its end, from the stack's slots,
      and each slot is cleared as its value moves into a container;
    - the value is ready once finish answers `finished`, and the builder
      keeps it until a reset;
    - an error drops what was built at once, and a reset resets the
      parser and the assembler too.
  - **`(jsonparse options)`:**
    - `object-mode`, `alist` or `hashtable`;
    - `null`, a symbol or a record that isn't a hashtable, default the
      symbol `null`.
  - **`(jsonparse-testing tree)`:**
    - `run-builder`;
    - `reference-run`, which folds `run-assembler`'s trace by recursive
      descent;
    - `canonical` and `as-hashtables`, for comparing hashtables and
      `json-number` records.
  - **Suites:**
    - `tree`: a differential against the reference, pinned values, the
      stack's growth points, depth to 65,535, stops, and chunking;
    - `tree-api`: the options, the lifecycle, independent builders,
      defaults, refusals, results and sub-ranges;
    - `tree-alloc`: what a parse allocates, the stack's growth, and what a
      builder keeps alive.
  - **Records:** ADR-0017 and `docs/tree.md`.
- **Results:**
  - **The builder builds what the reference does** on all 376 corpus
    files, under five sets of options:
    - whole, in chunks, under every split into two feeds of the files of
      at most 64 bytes, and random schedules for the rest;
    - 27,985 runs of 5,597 schedules, ending in values and in every
      error and stop.
  - **Containers at the stack's growth points:**
    - arrays and objects whose slot counts land on 64, 128 and 256, and
      one either side, at the top and nested;
    - nesting to 65,535 levels.
  - **Measurements** (ADR-0017):
    - a tree costs 1 to 10 ms per MB more than assembling its strings and
      numbers;
    - a reused builder allocates for an array of literals only its
      vector, plus a fixed amount, a fifth of a design that keeps members
      in lists.
- **Evidence:**
  - `scripts/guix-env make test` runs 23 suites in about 40 s. The new
    ones pass 150, 1,036 and 275.
  - Every assertion was watched fail. The builders ran about 150 mutants,
    and the reviewer 80. Of the reviewer's, 74 fail a suite. The other six
    are equivalent to the library: each changes something no later step
    reads.
- **Review:** an adversarial review found no wrong value. It found:
  - an option reset by a later `depth-limit` or `digit-limit` unseen,
    since the differential gives both sides the same options record;
  - keys that differ only in case never tested under hashtables, so a
    case-blind table passed;
  - a slot left uncleared by a container's close unseen, since the
    retention baseline was taken after the same document;
  - an error after a complete root, such as trailing garbage, never
    checked for memory held;
  - hashtable allocation bounded only from below, "doubling" not held by
    its bounds, and the initial 64 slots untested;
  - tests that expected `#f` from something that can raise, and helpers
    that swallowed any raise;
  - an opaque record of the caller's own refused as `null` without the doc
    saying so, and the other kinds Chez's `record?` accepts unrecorded.

  All are fixed, each watched fail. The resetting of the mark on an error
  was dead code, found by a builder's equivalent mutant, and is gone.
- **Known:**
  - **Under hashtables the last duplicate always wins.** M1 has no other
    rule (ADR-0017).
  - **`null` is a symbol or a non-opaque record,** a list of what is
    allowed. The owner kept it (2026-11-06), over refusing only what
    collides. Which values it accepts depends on the implementation's
    `record?`: Chez accepts conditions, enum-sets, record-type descriptors
    and time objects.
  - **The stack keeps its largest size** for the builder's life, like the
    assembler's buffer.
  - **The differential can't see a wrong options record,** since the
    builder and the reference read the same one. The `tree-api` suite's
    hand-written tables hold the options.

### Slice 3: the assembler (2026-10-30)

- **Landed:**
  - **`(jsonparse string)`:** the assembler, with one growable buffer
    reused for every key, string and number (ADR-0016):
    - a string's parts and escapes are joined as UTF-8 and decoded once, by
      `utf8->string`;
    - a number's digits are counted as its parts arrive, and nothing past
      the limit is kept;
    - numbers convert by mode at `number-end`, and `number-too-long` and
      `number-out-of-range` come back as stops;
    - the `json-number` record, checked against JSON's number grammar.
  - **`(jsonparse options)`:** `number-mode` (`flonum`, `exact` or `text`)
    and `digit-limit` (default 1,000).
  - **`(jsonparse-testing string)`:** `run-assembler`, which records each
    value the assembler builds through a parser.
  - **Suites:**
    - `string`: a differential against the reference's trace and against
      yajl's gold, plus pinned cases, the API, buffer growth and refusals;
    - `string-alloc`: no slope, a string's cost, growth, long numbers and
      retention;
    - `number`: an oracle built from the digits in all three modes,
      ADR-0011's pinned values, the limit's boundary in every position,
      `exact` mode's range, stops under every schedule, a grammar
      differential, and the options.
  - **Records:** ADR-0016, ADR-0011's worst case corrected, and
    `docs/string.md`.
- **Results:**
  - **Strings:** the assembled strings and keys equal the reference's on
    all 376 corpus files: whole, in chunks, under every split into two
    feeds of the 353 files of at most 64 bytes, and random schedules for
    the rest. They also equal yajl's own decoding, on all its cases but the
    five where slice 1 found our parser differs.
  - **Numbers:**
    - every number in the corpus, and seeded generated ones, equals the
      digits oracle in all three modes;
    - 1,000 digits are accepted and 1,001 refused, in every position;
    - a stop lands at the same offset under every schedule;
    - `make-json-number` accepts exactly what the parser accepts, over
      every string of up to 4 characters from `-+.eE019/:`.
  - **Measurements:**
    - joining and decoding once with `utf8->string` builds strings at
      300–900 MB/s, 2–4 times faster than decoding in Scheme;
    - at the default limit, numbers of 1,000 digits convert at 122 ms per
      MB as integers, and 354–389 ms as fractions.
- **Evidence:**
  - `scripts/guix-env make test` runs 20 suites in about 34 s. The new ones
    pass 203, 25 and 77.
  - Every assertion was watched fail. The builders ran about 140 mutants,
    and the reviewer 49 more.
- **Review:** an adversarial review found no wrong value. It found:
  - the doc's example broken by any document with a key;
  - an allocation assertion that failed for about 6% of heap phases, since
    a collection inside a measured region adds 656 bytes;
  - a 1-byte escape at a buffer growth point untested;
  - the assembler's default options untested;
  - two live assemblers never interleaved;
  - `/` and `:`, the bytes either side of the digits, untested in the
    grammar;
  - retention invisible to the allocation suite, and a start-size assertion
    that couldn't fail;
  - smaller gaps in wording.

  All are fixed, each watched fail. The allocation suites, `parser-alloc`
  too, now measure with collection off, and pass under 121 heap shifts.
  My own check then found a leak of each string's copied bytes that the
  first retention fix missed. A memory-in-use check now catches it.
- **Known:**
  - **ADR-0011's worst case was three times too low.** At the default
    limit, long fractions convert at 354–389 ms per MB, about 20 times a
    tree parse. The limit still bounds it, and the owner kept it at 1,000
    (2026-10-31).
  - **The buffer keeps its largest size** for the assembler's life.
  - **Some behaviour leans on Chez, where R6RS leaves it open:**
    `string->number`'s infinities, `-0.0` and rounding, and `utf8->string`'s
    U+FFFD (ADR-0016).
  - **No suite runs the docs' examples.** They were run by hand.
  - **The allocation suites allow for heap-position noise:**
    - `parser-alloc` counts a slope gap of 320 bytes or less as 0;
    - `string-alloc` allows 512 bytes plus 1% over its baseline.

### Slice 2: the push parser (2026-10-30)

- **Landed:**
  - **`(jsonparse options)`:** the options record. Its one option so far is
    `depth-limit`, from 0 to 65535, default 512. A bad option raises an
    R6RS assertion violation.
  - **`(jsonparse parser)`,** behind a handler of fourteen named procedures
    in YAJL's order (ADR-0015):
    - the stack is one byte per open container, sized from the limit;
    - escapes arrive as scalar values, surrogate pairs joined;
    - no text part is empty;
    - a stop ends the parse with its own code;
    - misuse raises jsonparse's own conditions, never byte-machine's.
  - **`(jsonparse-testing parser)`:** the recording handler, `run-parser`,
    and `machine->parser`, which turns the slice-1 reference's trace into
    the parser's terms.
  - **Suites:**
    - `parser`: the differential against the reference;
    - `parser-api`: the contract;
    - `parser-alloc`: allocation;
    - `parser-stack`: hand-pinned stack cases;
    - `parser-mutants`: runs `parser-stack` against 16 mutated copies of
      the parser and requires each to fail. They include ADR-0004's three:
      a wrong `context` answer, a skipped push and a skipped pop.
  - **Records:** ADR-0015 and `docs/parser.md`.
- **Results:**
  - **The parser records what the reference does** on every corpus file:
    - 381 inputs, under five depth limits;
    - about 244,000 runs: whole, in chunks, every split and every pair of
      splits up to 64 bytes, and random schedules;
    - 5,000 seeded mutants of the inputs.
  - **Allocation:** a feed plus a finish allocates the same at any size:
    928 bytes, 64 above byte-machine's own parser (two result records).
    That covers values, string bytes, number bytes and nesting.
- **Evidence:**
  - `scripts/guix-env make test` runs 17 suites in about 34 s. The new ones
    pass 86, 194, 29, 123 and 34.
  - Every assertion was watched fail. The builders ran about 100 mutants
    by hand.
- **Review:** an adversarial review found:
  - the stack checked only about 8 deep: a ring buffer of 8 entries passed
    every suite;
  - nothing checking that two parsers are independent;
  - a stop's offset moving with the chunking, under the digit-limit example
    ADR-0015 itself gave;
  - text parts that can end inside a UTF-8 character, which the contract
    denied;
  - the doc's escape examples written as raw characters;
  - an allocation ceiling a 400-byte leak per feed passed;
  - smaller gaps in tests and wording.

  All are fixed or recorded, each fix watched fail.
- **Known:**
  - **A stop from `chars` or `number-chars` lands where the feeds split
    the text.** A stop from an `-end` procedure doesn't, so slice 3's digit
    limit stops from `number-end`.
  - **Leaving out a container procedure saves less.** The stack's
    callbacks still run.
  - **`parser-mutants` adds about 10 s to `make test`.**
  - **`parser-api` and `parser-alloc` import `(byte-machine runtime)`,**
    to show byte-machine's values are ignored, and for the allocation
    baseline.

### Slice 1: the grammar and the generator (2026-10-30)

- **Landed:**
  - **The grammar:** `(jsonparse-grammar)` in `grammar/`, moved from the
    prototype. The machine is named `jsonparse`, and the depth limit is set
    per parser with a settable 16-bit field, `depth-left`, defaulting to 512
    (ADR-0005).
  - **The generated parser:** `make generate` (`grammar/emit.sps`) writes
    the committed `src/generated/jsonparse.sls`, and `test-generated` holds
    the two byte for byte.
  - **Corpora:** JSONTestSuite (MIT) and yajl's cases (ISC) in
    `tests/corpus/`, with `make check-corpora`, and git told to keep their
    bytes.
  - **Test libraries:**
    - `(jsonparse-testing machine)` runs either machine under any schedule
      and records whole traces. Its list stack is the reference for slice
      2's stack.
    - `(jsonparse-testing yajl)` reads yajl's gold files.
  - **Suites:**
    - `conformance`, with every `n_` and `i_` answer pinned in
      `tests/golden/jsontestsuite.txt`, which only `tests/write-golden.sps`
      writes;
    - `yajl`;
    - `machine`, the in-house cases;
    - `fuzz`;
    - `machine-driver`;
    - `generated`;
    - `check-corpora`.
- **Results:**
  - Every `y_` is accepted and every `n_` rejected. Of the `i_` files, 11
    are accepted (the number files and 500 nested arrays) and 24 rejected.
  - Of yajl's 45 plain cases, all match the gold but five divergences,
    listed with reasons (ADR-0012). Its four `am_` cases match with the
    `mode` bit.
  - The interpreter and the generated parser agree on whole traces
    everywhere they run.
- **Evidence:**
  - `scripts/guix-env make test` runs 12 suites in about 30 s. The new ones
    pass 9, 160, 367, 4, 50, 5 and 38.
  - Every assertion was watched fail, and every mutant the review found
    now fails a suite.
- **Review:** an adversarial review found:
  - the depth limit never reached after a close, so a close that reset it
    to 512 passed every gate;
  - five three-byte UTF-8 leads untested;
  - fuzz inputs rarely split, and fuzz never setting the depth limit or the
    `mode` bit;
  - a differential blind to fields and state;
  - yajl's option cases accepting an early rejection;
  - symlinks allowed in a corpus;
  - two records overstating the schedules.

  All are fixed, each watched fail.
- **Known:**
  - **A truncated UTF-8 sequence is reported as `unexpected-eof`,** and so
    are a dangling `\` or `\u` and a lone high surrogate at the end of
    input.
  - **Fuzz compares the driver with itself.** A bug in the driver's stack
    is caught only by `machine-driver`'s hand-written traces.
  - **The suites reach into byte-machine:**
    - `machine` imports `(byte-machine private conditions)` to name a
      refused field;
    - the schedules come from byte-machine's test harness.

    A byte-machine bump can move either.

### Slice 0: scaffolding (2026-10-30)

- **Landed:**
  - **The pinned Guix container:** `channels.scm`, `manifest.scm`,
    `scripts/guix-env*` and `make check-guix` (ADR-0008).
  - **The Makefile:** `help`, `check-help`, `check-chez` (the 10.4.1
    floor), `submodules`, `check-pins` (gitlinks and the `v0.8.0` tag),
    `deps`, `test`, `check-suites`, `check-imports` and `check-versions`.
  - **Dependencies:** `vendor/byte-machine` at `v0.8.0` and `vendor/chez-srfi`
    at `7879b52`.
  - **Akku:** `Akku.manifest` (`^0.8.0`), `Akku.lock`, `.akkuignore` and
    `.gitattributes` (ADR-0002, ADR-0003).
  - **Test libraries:** `(jsonparse-testing)` and
    `(jsonparse-testing property)` (ADR-0012).
  - **CI:** on `ubuntu-24.04` and `ubuntu-24.04-arm`, with architecture
    checks (ADR-0009).
- **Evidence:**
  - `scripts/guix-env make test` runs 5 suites: 38, 16, 29, 45 and 52
    passes.
  - `make check-guix` passes, including 88 launcher cases.
  - The builders watched every rule fail: 87 mutants, then the reviewer's.
    One survivor is left: dropping `make-capture-directory`'s mutex, which
    `mkdir`'s own refusal makes harmless.
- **Review:** an adversarial review found:
  - checks that couldn't fail: `make test`'s verdict, `check-help`, the
    generators' edges, a bare `(exit)`;
  - a false packaging claim in ADR-0003;
  - a silent run below the Chez floor.

  All are fixed, each with a case watched fail.
- **Known:** `make check-pins` reads gitlinks from HEAD, so a staged bump
  fails it until committed. Nothing checks the `.gitattributes`
  export-ignore yet; plan M5's `check-akku` will.
