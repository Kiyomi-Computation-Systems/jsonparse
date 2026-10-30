# ADR-0008: Builds and tests run in a pinned Guix container with no network

- **Status:** Accepted
- **Date:** 2026-10-30
- **Scope:** the development environment on a Guix host
- **Related:** circuit ADR-0002, which this copies; chez-curl ADR-0006, its prior art

## Context

AGENTS.md describes a pinned Guix container (`scripts/guix-env`,
`make check-guix`, `make check-guix-inside`) and cites "ADR-0006". That is
chez-curl's record, carried over with the text; jsonparse had neither a record
nor the scripts. The host's own Chez is 10.4.0, below the 10.4.1 floor.

circuit's setup is the newest of the siblings', and the one AGENTS.md
describes: no network but loopback, and no git inside.

## Decision

**Copy circuit's setup, trimmed to what jsonparse needs.**

- **`channels.scm`** pins Guix at the siblings' commit (`b532aa7`).
- **`manifest.scm`** builds Chez 10.4.1 from the same recipe, so every
  sibling shares one store item, plus the shell tools the Makefile needs.
- **The scripts and tests:**
  - `scripts/guix-env`, `scripts/guix-env-enter` and
    `scripts/guix-env-selftest`;
  - `scripts/require-tools`;
  - `tests/guix-env-launcher.sh`.
- **Makefile targets:** `help`, `check-help`, `check-guix` and
  `check-guix-inside`.
- **What the container has:** only loopback, no git, and `CHEZ` set to the
  real `scheme` binary. Fetching the submodule and the Akku lock (ADR-0002)
  happens on the host.

## Consequences

- AGENTS.md cites this record.
- The first `scripts/guix-env` on a machine without the store item builds
  Chez, in about two minutes.
- macOS has no Guix. On the owner's M1 laptop, `make test` runs with
  Homebrew's Chez, and the Makefile finds it as `scheme` or `chez`.
