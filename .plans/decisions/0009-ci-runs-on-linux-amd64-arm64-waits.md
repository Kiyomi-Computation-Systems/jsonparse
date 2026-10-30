# ADR-0009: CI runs on Linux amd64; arm64 waits

- **Status:** Accepted
- **Date:** 2026-10-30
- **Scope:** continuous integration
- **Related:** AGENTS.md, *Architecture & portability*; circuit's `ci.yml`

## Context

jsonparse targets amd64 and arm64, on Linux and macOS. AGENTS.md rules out
macOS CI runners. circuit runs a Linux matrix of `ubuntu-24.04` and
`ubuntu-24.04-arm`. There are no billing minutes for the arm64 runner yet.

## Decision

- **CI runs on `ubuntu-24.04` (amd64) only.**
- **The arm64 runner is added later,** when minutes allow, following circuit's
  matrix.
- **Meanwhile, arm64 is covered by hand:** the owner runs `make test` on an M1
  laptop from time to time.

## Consequences

- An arm64 or macOS regression shows up at the next laptop run, not on the
  pull request.
