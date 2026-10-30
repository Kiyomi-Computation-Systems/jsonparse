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
- **Slice 0, the scaffolding, is done** (close-out below). Nothing under
  `src/` exists yet. Slice 1 of M1, the grammar and the generator, is next.

## Next

**Slice 0, scaffolding:**

- the Guix container (ADR-0008);
- the Makefile with `help` and `check-help`;
- `vendor/byte-machine`, `Akku.manifest` and `Akku.lock`, and the pin check
  (ADR-0002);
- the import check (ADR-0003);
- an SRFI-64 harness;
- the test-only property library, modelled on circuit's (ADR-0012);
- CI on Linux amd64 and arm64, each job checking its architecture
  (ADR-0009).

**Milestone 1, in order:**

1. **The grammar and generator.**
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
   - The stack's mutation tests are watched fail.
3. **`(jsonparse string)`.**
   - It assembles strings and numbers.
   - It covers the three number modes and the digit limit, whose boundary
     tests are watched fail (ADR-0011).
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

## Close-outs

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
