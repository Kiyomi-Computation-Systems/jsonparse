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
  below). `src/` holds only the generated parser. Slice 2, `(jsonparse
  parser)`, is next.

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
2. **`(jsonparse parser)`.**
   - It covers the internal stack, the options record and the depth limit
     (ADR-0004, ADR-0005).
   - Its results use jsonparse's own types (ADR-0010).
   - The stack's mutation tests are watched fail. The list stack in
     `(jsonparse-testing machine)` is the reference to check it against.
   - **It checks the depth limit itself, and raises its own condition** for
     one out of range. byte-machine's refusal of a field value is a private
     condition type that callers can't name.
3. **`(jsonparse string)`.**
   - It assembles strings and numbers.
   - It covers the three number modes and the digit limit, whose boundary
     tests are watched fail (ADR-0011).
   - **A high surrogate's `escape` event comes before its low half is
     read.** Nothing is committed until the pair completes.
4. **`(jsonparse tree)`,** with the value options (ADR-0006).
5. **`(jsonparse writer)`.**
   - It covers the refusals, number formatting and pretty printing (ADR-0007,
     ADR-0011).
   - Round-trip property tests check it.
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
   - **Decide whether `values` needs whitespace between values.** The
     machine's `mode` bit needs none: it accepts `[]{}` and `"a""b"`, and
     reads `1-2` as 1 and −2. ADR-0014 says "whitespace-separated". Decide
     too what an empty stream is; the machine rejects it.

## Close-outs

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
