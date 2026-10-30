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
- **Three measurements were made the same day:**
  - the stack, on the prototype regenerated with byte-machine 0.8.0
    (`prototype/stack-*.sps`, ADR-0004);
  - number conversion and printing (ADR-0011);
  - how textual ports decode invalid UTF-8 (ADR-0010).
- **Nothing under `src/` exists yet.** Nothing is merged since the initial
  commit.

## Next

**Slice 0, scaffolding:**

- the Guix container (ADR-0008);
- the Makefile with `help` and `check-help`;
- `vendor/byte-machine`, `Akku.manifest` and `Akku.lock`, and the pin check
  (ADR-0002);
- the import check (ADR-0003);
- an SRFI-64 harness;
- CI on Linux amd64 (ADR-0009).

**Milestone 1, in order:**

1. **The grammar and generator.**
   - They move under `src/`, and the committed `(generated jsonparse)` gets
     its regeneration check.
   - Gates: JSONTestSuite `y_` and `n_`, the `i_` results pinned in a golden
     file, chunking invariance, and an interpreter-versus-generated
     differential.
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

## Close-outs

None yet.
