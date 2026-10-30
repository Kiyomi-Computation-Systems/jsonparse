# ADR-0001: The library is jsonparse, a byte-machine consumer

- **Status:** Accepted
- **Date:** 2026-10-30
- **Scope:** the repository, the package and every library name
- **Related:** plan §7 question 1; chez-httparse, which set the consumer pattern

## Context

The plan called the library `chez-json-bm` and offered it two homes: its own
consumer repository, as chez-httparse is, or a `contrib/` folder inside
byte-machine.

## Decision

- **The library is `jsonparse`**, in its own repository. byte-machine stays a
  generator, and jsonparse consumes it as chez-httparse does.
- **Library names start with `(jsonparse …)`.** `(json …)` is taken in
  practice: chez-json ships `(json parser)`.
- **The machine is named `jsonparse`**, so its generated library is
  `(generated jsonparse)`. byte-machine names a generated library after its
  machine, so the name is global; `(generated json)` could collide with
  another package's parser. chez-httparse names its machines
  `httparse-message` and `httparse-url` for the same reason.
- **The generated parser is committed**, and a check regenerates it and
  compares the two byte for byte, as chez-httparse does.

## Consequences

- The plan's `chez-json-bm` and `(… events)` placeholders read `jsonparse` and
  `(jsonparse …)`.
- A grammar change shows up in review as a diff of the generated parser.
