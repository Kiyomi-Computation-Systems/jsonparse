# ADR-0002: byte-machine is a runtime dependency, through Akku

- **Status:** Accepted
- **Date:** 2026-10-30
- **Scope:** how jsonparse gets byte-machine, at run time and in its own tests
- **Related:** ADR-0001; chez-httparse's `Akku.manifest` and `vendor/byte-machine`

## Context

Every parser byte-machine generates imports `(rnrs)` and
`(byte-machine runtime)`, and nothing else. The runtime is about 1,800 lines.
The owner asked whether jsonparse could be standalone. There were two ways:

1. Ship a renamed private copy of the runtime inside jsonparse, and use
   byte-machine only to generate.
2. Depend on byte-machine at run time, as chez-httparse does.

## Decision

**Depend on byte-machine as chez-httparse does.**

- `Akku.manifest` declares `(depends ("byte-machine" "^0.8.0"))`. The range's
  floor is the vendored version.
- A git submodule at `vendor/byte-machine`, pinned at a release tag, is what
  the test suite and the offline container (ADR-0008) run against.
- The submodule's gitlink, the Akku floor and `Akku.lock` move together, and a
  check holds them to one version, as chez-http-server's `make check-pins`
  does.

Option 1 was rejected because it duplicates about 1,800 lines that must be
recopied on every byte-machine upgrade, and needs a byte-machine option to
rename the runtime a generated library imports.

## Consequences

- **One runtime serves every byte-machine consumer in an application.** A
  generated library is tied to the runtime's interface version (the ABI,
  9 in byte-machine 0.8.0). An application that loads jsonparse beside
  chez-httparse, uriparse or chez-http-server needs every generated parser at
  the runtime's ABI. Any jsonparse change that needs a new ABI (plan M2, M3)
  has to be released with the siblings' regenerated parsers.
- **jsonparse is not standalone.** Installing it through Akku brings
  byte-machine with it.
- **The prototype must be regenerated on 0.8.0**, whose digit-reading check
  changed. On 2026-10-30 it regenerated and passed the verifier (ADR-0004).
