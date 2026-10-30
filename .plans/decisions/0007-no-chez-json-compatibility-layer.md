# ADR-0007: No chez-json compatibility layer

- **Status:** Accepted
- **Date:** 2026-10-30
- **Scope:** jsonparse's read and write API
- **Related:** plan §7 question 4, §2 and Appendix B; ADR-0006, ADR-0010,
  ADR-0011

## Context

chez-json accepts 43 inputs RFC 8259 rejects and rejects 4 it accepts
(plan §2). Its data model can't tell `[]` from `null` (Appendix B). A shim
with its names would invite its callers to expect its behaviour.

## Decision

- **jsonparse has no shim** with chez-json's names or data model.
- **jsonparse has its own conversion layer, built to enforce correctness:**
  - **Reading** is strict RFC 8259 by default. An error carries a code and an
    offset.
  - **Writing** checks its input. It refuses what JSON can't express: NaN, the
    infinities, exact fractions with no finite decimal (ADR-0011), symbols
    other than the null value in force, non-string keys, and improper lists.
    Its escaping is correct by construction.
  - **Property tests** check that writing a valid tree and reading it back
    gives the same tree.
- **Callers moving from chez-json get a migration note** (plan M5).

## Consequences

- The writer belongs beside the reader, and lands with it in M1 (ADR-0010).
  How it writes numbers is in ADR-0011.
