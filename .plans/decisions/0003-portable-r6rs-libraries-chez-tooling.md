# ADR-0003: Portable R6RS libraries, Chez tooling

- **Status:** Accepted
- **Date:** 2026-10-30
- **Scope:** everything under `src/`, and the build, test and benchmark tooling
- **Related:** byte-machine's README, *Portability*; AGENTS.md, *Architecture & portability*

## Context

The plan said "for Chez Scheme"; AGENTS.md says the project is portable R6RS.
byte-machine settles the same tension this way: its libraries import only
`(rnrs)`, only its build and test layer is Chez-specific, and Guile 3.0.11 and
Racket 9.3 are checked by hand, not in CI.

## Decision

**jsonparse uses byte-machine's strategy.**

- Every library under `src/` starts with `#!r6rs` and imports only
  `(rnrs …)`, `(jsonparse …)`, `(generated jsonparse)` and
  `(byte-machine runtime)`.
- The build, test and benchmark tooling may use Chez Scheme (10.4.1 or later)
  freely.
- Guile and Racket are checked by hand, not in CI.

## Consequences

- **`tests/check-imports.sps` fails if a library under `src/` imports
  anything outside that set.**
  - `(rnrs eval)` is outside it, because `environment` reaches any library
    from code the check never reads.
  - The check also holds that:
    - each file is one `.sls` library at its name's path;
    - each name is `(jsonparse …)` or exactly `(generated jsonparse)`
      (ADR-0001);
    - `#!r6rs` is the first line, and `#!` appears nowhere else;
    - an imported `(jsonparse …)` library exists under `src/`;
    - a directory symlink is named, not followed.
- **The grammar and the generator are tooling, so they live in `grammar/`, not
  `src/`.** The grammar imports `(byte-machine graph)` and the generator
  `(byte-machine compile)`. A consumer gets the committed generated parser
  and never needs either.
- **Akku installs any library it finds,** not only those under `src/`.
  - Its scanner skips dot-directories and what `.akkuignore` lists.
  - Its installer skips test paths.
  - So `.akkuignore` lists `build`, `grammar`, `tests` and `vendor`.
  - `.gitattributes` keeps `.plans/` and `AGENTS.md` out of the archive Akku
    publishes.
  - Plan M5's `make check-akku` installs the package as a consumer would and
    checks what lands.
- Plan M3's third lever, Chez-only unsafe access in emitted code, can't reach
  `src/`. The generated parser must stay `(rnrs)`-only.
- Racket loads a generated library only once `#!r6rs` is its first line, and
  byte-machine's emitted text doesn't carry it. The generation step adds it,
  as uriparse's does; the byte-for-byte check (ADR-0001) compares the file
  with the line added.
