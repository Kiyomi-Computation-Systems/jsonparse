# ADR-0004: The nesting stack lives in jsonparse

- **Status:** Accepted
- **Date:** 2026-10-30
- **Scope:** where the parser keeps track of open objects and arrays; plan M1 and M2
- **Related:** plan §4.3 and M2; ADR-0002; ADR-0005

## Context

After a value inside a container, the next legal byte depends on whether the
container is an object or an array, so JSON needs a stack. byte-machine has
none: its docs name arbitrarily deep JSON as a grammar it doesn't cover. The
prototype asks a `context` decision callback after each such value, and the
consumer answers from its own stack.

The owner wants a self-contained parser, with nesting enforced by the parser
and not by the user's code, that performs well. The stack could live in
jsonparse's own driver, or be a new byte-machine primitive (plan M2).

**Measured on 2026-10-30.** Both parsers below were generated with
byte-machine 0.8.0 and run on x86_64 with Chez 10.4.0, which is below the
10.4.1 floor. The libraries were compiled at load time, at Chez's default
optimize level. Each figure is the median of 9 rounds of 100 parses, and
three runs agreed.

- **Callback:** the prototype parser, answering `context` from a bytevector
  stack.
- **In-machine:** `(bmjson grammar-fs)`, which keeps the container kind in
  fields and has no callback.

| Input | `context` calls | Callback | In-machine | Time saved |
|---|---|---|---|---|
| `ints-40k` | 40,000 | 169 MB/s | 224 MB/s | 24% |
| `records-2k` | 28,000 | 173 MB/s | 195 MB/s | 11% |
| `escaped-string` | 1 | 264 MB/s | 255 MB/s | none |

- **Per value:** the callback costs about 8 ns for each value inside a
  container.
- **Building a tree:** the prototype's tree builder runs at 47–65 MB/s, so the
  callback is 4–7% of a tree parse. The builder allocates about 14 MB per
  parse, and that costs more than the callback.
- **Allocation:** both events-only variants allocate a fixed amount per
  parse, not per value.
- **Correctness:** both accept all three inputs and reject `[1}`, `{"a":1]`
  and two deeper mismatches.
- **Reproducing:** run `prototype/stack-gen.sps`, then
  `prototype/stack-bench.sps`, with the paths of plan §8.

## Decision

- **Milestone 1 keeps the stack in jsonparse.** A bytevector holds one entry
  per open container. It is sized from the depth limit (ADR-0005) when the
  parser is made, and it answers `context` internally. `context` is never
  exported: users see the same API wherever the stack lives.
- **Plan M2 is conditional.** The stack moves into byte-machine only if the
  measured gain still justifies a runtime ABI bump once M3 is done. If it is
  taken, it ships in the same byte-machine release as M3's run node, so
  byte-machine's consumers regenerate once (ADR-0002).
- **If M2 is taken, its stack is sized per parser.** A bit-stack in one 64-bit
  field holds 63 levels and can't honour a configurable limit.

## Consequences

- **byte-machine's verifier can't see the nesting logic.** It lives in
  jsonparse code. Mutation tests must show that each of these fails the
  suite, and each must be watched fail:
  - a wrong `context` answer;
  - a skipped push;
  - a skipped pop.
- **Events-only parsing allocates nothing per value or per container.**
- **It works on byte-machine `^0.8.0` (ABI 9),** with no change upstream.
- **Moving the stack later breaks no user,** because the API is the same
  either way.
