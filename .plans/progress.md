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
- **Slice 3, the assembler, is done** (close-out below). Slice 4,
  `(jsonparse tree)`, is next.

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
4. **`(jsonparse tree)`,** with the value options (ADR-0006).
   - **Where its procedures call slice 3's,** they pass a stop on: test the
     returned value with `json-stop?` (ADR-0015).
   - **One assembler per parser,** made from the same options record. Keys
     come from `json-assembler-string!` in `key-end`, strings in
     `string-end`, numbers from `json-assembler-number!` in `number-end`
     (ADR-0016).
   - **Its reset resets the assembler too.** A parser reset doesn't reach
     the handler (ADR-0015).
   - **`equal?` compares `json-number` records by identity.** Tree tests in
     `text` mode compare numbers by `json-number-text`, until slice 6's
     `json=?`.
5. **`(jsonparse writer)`.**
   - It covers the refusals, number formatting and pretty printing (ADR-0007,
     ADR-0011).
   - Round-trip property tests check it.
   - **A `json-number`'s text is valid JSON:** `make-json-number` checks it
     and keeps a copy, and `json-number-text` returns a copy (ADR-0016).
6. **`(jsonparse easy)`.**
   - It covers `&json-error` with character offsets.
   - The conformance vectors run through it.
   - The import check refuses any `src/` library that imports it (ADR-0010).
7. **`(jsonparse sequence)`** and its easy-layer procedures (ADR-0014).
   - It covers JSON Lines and NDJSON, RFC 7464, and whitespace-separated
     values.
   - It reports bad records, and skips them when asked.
   - Its chunking tests split before, on and after every separator.
   - It measures the separator scan.
   - **`values` follows ADR-0014's revision.** Objects, arrays and strings
     need no separator after them. A top-level number or literal needs
     whitespace or the end of the input after it, so `1-2` and `truefalse`
     are errors. An empty stream holds no values.
     - That is a grammar change under the `mode` bit.
     - The `machine` suite's mode cases, which pin today's behaviour, change
       with it.
     - **The `mode` bit isn't in the options yet.** Slice 7 adds it, and
       `make-json-parser` passes it to the machine.
   - **A parser allocates a fixed amount per feed,** mostly byte-machine's
     own result (ADR-0015). A reader that feeds and resets once per record
     pays that per record: measure it.

## Close-outs

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
