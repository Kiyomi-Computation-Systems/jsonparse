# Global constraints

These rules bind every task brief. Each one cites the decision record in
[decisions/](decisions/) it comes from, or AGENTS.md. If a rule here and its
record disagree, the record wins and this file gets fixed.

## Platforms and versions

- **Platforms:** Linux and macOS, on amd64 and arm64. No Windows code paths or
  CI (AGENTS.md).
- **Chez:** 10.4.1 or later (ADR-0008).
- **CI:** Linux amd64 and arm64 (`ubuntu-24.04` and `ubuntu-24.04-arm`).
  Each job checks `uname -m` and Chez's machine type. Never a macOS runner:
  macOS is covered by `make test` on the owner's M1 laptop (ADR-0009,
  AGENTS.md).

## Portability

- **Every library under `src/` starts with `#!r6rs`.** It imports only
  `(rnrs …)` but `(rnrs eval)`, `(jsonparse …)`, `(generated jsonparse)` and
  `(byte-machine runtime)`, and `tests/check-imports.sps` holds that
  (ADR-0003).
- **Tooling may use Chez freely.** Guile and Racket are checked by hand
  (ADR-0003).
- **The grammar and the generator live in `grammar/`,** outside `src/`: they
  import byte-machine's graph and compiler (ADR-0003).

## Names and the dependency

- **Names:** the repository and package are `jsonparse`, every library is
  `(jsonparse …)`, and the generated parser is `(generated jsonparse)`
  (ADR-0001).
- **The generated parser is committed,** and a check regenerates it and
  compares the two byte for byte (ADR-0001).
- **byte-machine:**
  - `Akku.manifest` declares `^0.8.0`.
  - `vendor/byte-machine` is a submodule pinned at a release tag, and the
    Akku floor equals it.
  - The gitlink, the floor and `Akku.lock` move together (ADR-0002).
- **A change that needs a new byte-machine ABI** ships with the sibling
  consumers' regenerated parsers (ADR-0002).
- **chez-srfi**, for SRFI-64 in tests only, is pinned at a commit, since
  upstream has no tags (ADR-0012).
- **Only `src/` reaches the Akku package.** `.akkuignore` and
  `.gitattributes` keep the rest out (ADR-0003).

## Layers

- **The low layer** is `(jsonparse parser)`, `(jsonparse string)`,
  `(jsonparse tree)`, `(jsonparse writer)`, `(jsonparse sequence)` and their
  supporting libraries. It takes bytes, counts offsets in bytes, and never
  raises on bad input (ADR-0010, ADR-0014).
- **`(jsonparse easy)` composes low-layer exports only:** it imports only
  `(rnrs …)` and `(jsonparse …)` libraries, and `tests/check-imports.sps`
  holds that. It raises
  `&json-error`, whose offset counts characters for a string and bytes
  otherwise (ADR-0010).
- **No library under `src/` imports `(jsonparse easy)`,** and the import check
  holds that (ADR-0010).
- **Ports are binary in both layers** (ADR-0010).
- **No export names a `(byte-machine runtime)` type** (ADR-0010).
- **Both layers return the same values,** and the conformance vectors run
  through both (ADR-0010).

## The parser

- **The nesting stack lives in jsonparse.** `context` is never exported
  (ADR-0004).
- **Mutation tests must be watched fail:** a wrong `context` answer, a skipped
  push and a skipped pop (ADR-0004).
- **Events-only parsing allocates nothing per byte, per value or per
  container** (ADR-0004, plan M1).
- **The depth limit is set per parser, default 512.** Going past it is
  `nesting-too-deep` (ADR-0005).

## Values

- **Objects** are alists in document order by default. The hashtable option
  keys by string, and the last duplicate wins by default (ADR-0006).
- **Other values:** arrays are vectors, keys and strings are strings, `true`
  and `false` are `#t` and `#f` (ADR-0006).
- **`null`** is the symbol `null` by default, and configurable. A value that
  collides with another representation is refused (ADR-0006).
- **Numbers:**
  - they convert by mode: `flonum` by default, `exact`, or `text`;
  - in `flonum` mode, integers are exact, and `1e400` is
    `number-out-of-range`;
  - a digit limit, default 1,000, applies to `flonum` and `exact`, and going
    past it is `number-too-long` (ADR-0011).
- **No chez-json compatibility layer** (ADR-0007).
- **The writer refuses what JSON can't express** (ADR-0007). It strips the
  `|` mantissa width from flonums, and refuses exact fractions with no finite
  decimal (ADR-0011).

## Streams of values

- **Records are framed by byte:** `\n` for `lines` and RS for `seq`. A
  record split across chunks is never copied into one buffer (ADR-0014).
- **`lines` by default:** a bad record or a blank line is an error, with a
  record number and a byte offset (ADR-0014).
- **A skipped record is always reported** to the caller's procedure. `seq`
  always skips bad records, and drops a possibly cut-off top-level number or
  literal as `truncated` (ADR-0014).
- **Records written as `lines` are compact** (ADR-0014).

## Tests and benchmarks

- **Every vendored corpus sits in `tests/corpus/<name>/`** with its upstream
  license and a `SOURCE` file, and a check holds that (ADR-0012).
- **Never vendor:**
  - JSON_checker files, in any copy (the JSON license);
  - data without a license (ADR-0012).
- **`make test` needs no network and no comparator.** Benchmark files are
  fetched on the host, checked by SHA-256, and never committed (ADR-0012,
  ADR-0013).

## Environment

- **On a Guix host, build and test through `scripts/guix-env`.** It has no
  network but loopback and no git; fetching runs on the host (ADR-0008).
