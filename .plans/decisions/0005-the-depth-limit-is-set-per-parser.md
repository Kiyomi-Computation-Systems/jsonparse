# ADR-0005: The depth limit is set per parser

- **Status:** Accepted
- **Date:** 2026-10-30
- **Scope:** the nesting limit
- **Related:** plan §7 question 5; ADR-0004

## Context

The depth is how many objects and arrays are open at once: `[[[1]]]` is depth
3. A limit stops input such as a megabyte of `[` from exhausting memory. The
prototype fixed it at 512 when the parser was generated.

## Decision

- **The limit is set per parser, when it is made. The default is 512.** A
  limit out of range raises when the parser is made.
- **Going past it is the error `nesting-too-deep`,** with the byte offset where
  it happened. The prototype reports 513 nested `[` at offset 513; a test pins
  the exact offset.
- **The machine enforces it with today's field operations.** A settable field
  starts at the limit, an open decrements it, and a close increments it.
  byte-machine checks the decrement and routes its failure to the error. This
  needs no byte-machine change: settable fields and checked decrement exist
  in 0.8.0.

## Consequences

- The stack (ADR-0004) is sized from the same setting.
- **The field's width bounds the largest limit.** Slice 1 of M1 picked 16
  bits, so the limit runs from 0 to 65535:
  - the field is `depth-left`, settable, declared at 512;
  - `make-parser` raises for 65536 or more;
  - at 0 only a top-level scalar parses.

  The grammar keeps `depth`, counting up, beside it. A field branch tests a
  field against a constant only, and the limit is not one, so only `depth`
  can say when the parser is back at the top level.
