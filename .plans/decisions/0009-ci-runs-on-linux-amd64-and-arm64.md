# ADR-0009: CI runs on Linux amd64 and arm64

- **Status:** Accepted, revised the same day
- **Date:** 2026-10-30
- **Scope:** continuous integration
- **Related:** AGENTS.md, *Architecture & portability*; circuit's `ci.yml`;
  ADR-0013

> **Revision (2026-10-30).** The first version ran amd64 only and deferred
> arm64 for lack of billing minutes. The owner then made the repository
> public, which removes that limit, and asked for the arm64 runner.

## Context

jsonparse targets amd64 and arm64, on Linux and macOS. AGENTS.md rules out
macOS CI runners. The repository is public, and GitHub's standard runners,
`ubuntu-24.04-arm` included, cost no minutes for a public repository.

circuit runs a Linux matrix of `ubuntu-24.04` and `ubuntu-24.04-arm`. Before
building, each job checks that `uname -m` is the machine its label names. After
building Chez, it checks that Chez's `(machine-type)` is `ta6le` or
`tarm64le`. So a label that lands on another architecture fails by name. It
can't pass as a second amd64 run.

## Decision

- **CI runs a matrix of `ubuntu-24.04` (amd64) and `ubuntu-24.04-arm`
  (arm64),** as circuit's does:
  - explicit images, not `ubuntu-latest`;
  - `fail-fast: false`, so one architecture failing doesn't cancel the other.
- **Each job checks its architecture twice,** as circuit's does:
  - `uname -m` is `x86_64` or `aarch64`;
  - Chez's machine type is `ta6le` or `tarm64le`.
- **macOS has no runner.** The owner runs `make test` on an M1 laptop from time
  to time.
- **CI runs no benchmarks** (ADR-0013).

## Consequences

- **An arm64 Linux regression shows up on the pull request.** A macOS one shows
  up at the next laptop run.
- **Slice 0's CI has both jobs from the start.**
- **If the repository goes private again,** the arm64 job costs billed
  minutes.
