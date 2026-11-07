# ADR-0017: The tree builder keeps a stack of values and builds each container at its end

- **Status:** Accepted
- **Date:** 2026-11-06
- **Scope:** what `(jsonparse tree)` exports, keeps and drops; the
  `object-mode` and `null` options
- **Related:** ADR-0004, ADR-0006, ADR-0010, ADR-0011, ADR-0015, ADR-0016;
  plan M1

## Context

- **ADR-0006** sets the values a tree is made of. It refuses a `null` that
  collides with another representation when the options are made.
- **ADR-0010** puts `(jsonparse tree)` in the low layer: bytes in, byte
  offsets, and no exception on bad input.
- **ADR-0015** says a parser reset doesn't reach the handler, so whatever
  holds a half-built value resets it too.
- **ADR-0016** gives each parser one assembler, and returns its refusals as
  stops.
- **`(jsonparse options)` sits below `(jsonparse string)`,** which defines
  `json-number`, so the options can't name that type.
- **R6RS `record?` is false of an opaque record.** Every record jsonparse
  exports is opaque: `json-number`, options, stops, results, parsers,
  assemblers and builders. In Chez, `record?` is also true of hashtables,
  conditions, enum-sets, record-type descriptors and time objects.

Measured on 2026-11-06 with the Guix container's Chez 10.4.1 (scratch
programs, not kept). Each document is about 1 MB, and each figure is the
best of seven runs, in ms:

| Document | Events only | Assembled | Tree | Tree, hashtables | Lists design |
|---|---|---|---|---|---|
| Records of 6 members | 6.3 | 14.0 | 16.7 | 18.2 | 16.3 |
| Integers to 6 digits | 5.2 | 20.1 | 21.8 | 22.3 | 22.3 |
| Strings of 16 letters | 4.2 | 6.2 | 7.2 | 7.1 | 7.4 |
| Pairs, `[3,7]` | 14.8 | 35.9 | 45.6 | 45.4 | 47.3 |
| `true`s | 5.2 | 5.2 | 8.2 | 8.3 | 7.2 |
| One object of `"kN":d` members | 5.3 | 14.5 | 18.7 | 20.5 | 16.5 |

- **Assembled** builds every key, string and number, and no tree.
- **Tree** is this ADR's design, with a fresh builder each run.
- **Lists design** keeps each open container's members in a list, newest
  first, and reverses it at the container's end.

**What a builder allocates,** reset and reused, for an array of n `true`s:

| n | This design | Lists design |
|---|---|---|
| 10 | 912 bytes | 4,160 bytes |
| 1,000 | 8,832 bytes | 43,760 bytes |
| 100,000 | 800,832 bytes | 4,017,040 bytes |

This design allocates the vector, 8n + 8 bytes, and 824 bytes more. The
lists design allocates about 40 bytes per member. An object of 1,000
members allocates 80,640 bytes as an alist and 88,928 as a hashtable.

## Decision

1. **A builder is one record, with six procedures:**
   - `make-json-builder`, with an optional options record;
   - `json-builder?`;
   - `json-builder-feed!`, on a bytevector or a range of one, and
     `json-builder-finish!`, each returning the parser's own result;
   - `json-builder-value`;
   - `json-builder-reset!`.

   The builder checks its own arguments and names its own procedures when it
   refuses them.
2. **A builder holds one parser, one assembler and one stack,** all made
   from the same options record. The parser and the stack aren't exported:
   only the builder's procedures reach them (ADR-0004).
3. **The stack is one vector of slots.**
   - A value waits in a slot until its container ends.
   - An open container takes one slot, which holds its parent's mark: the
     slot where the parent's members begin.
   - Each container is built once, at its end, from its members' slots:
     - an array is one vector;
     - an alist is consed from its last member to its first;
     - a hashtable is made with room for its members, then filled in
       document order, so the last duplicate wins.
   - A slot is cleared as soon as its value moves into a container.
   - The stack starts at 64 slots, doubles when it is full, and never
     shrinks.
4. **The value is ready once finish answers `finished`.**
   `json-builder-value` raises at any other time. The builder keeps the
   value until it is reset.
5. **A parse that ends in an error drops what it built at once:** the stack
   and the assembler. That includes a stop from the assembler.
6. **`json-builder-reset!` resets the parser, the assembler and the
   stack.**
7. **`object-mode` and `null` join the options record.**
   - **`object-mode`** is `alist` (the default) or `hashtable`. A hashtable
     is fresh for each object, mutable, and keyed by string with
     `string-hash` and `string=?`.
   - **`null`** is a symbol, default `null`, or a record that is not a
     hashtable. Anything else is refused, an opaque record of the caller's
     own included, since `record?` is false of it.
     - **The rule is a list of what is allowed,** since the options can't
       name `json-number` to refuse it. A `json-number` is opaque, so
       `record?` refuses it anyway, and the rule refuses any later
       representation too.
     - **It refuses some values that collide with nothing,** such as
       characters and the end-of-file object. Allowing them later breaks
       no caller.
     - **It doesn't depend on `object-mode`:** `'()` is refused under
       hashtables too. So a `null` stays good under any options, and the
       writer can take either kind of object.
     - **Hashtables are refused by name,** because Chez's `record?` is true
       of them.
     - **The owner kept this rule (2026-11-06),** over refusing only the
       values that collide, and over letting `'()` through under
       hashtables.
8. **Under hashtables, the last duplicate always wins.** ADR-0006's "by
   default" leaves room for another rule, such as refusing duplicates, and
   M1 has none.

## Consequences

- **A tree costs 1 to 10 ms per MB more than assembling its strings and
  numbers,** measured above. The assembler's numbers dominate.
- **An array of literals costs only its vector,** a fifth of what the
  lists design allocates.
- **The stack keeps its largest size for the builder's life,** like the
  assembler's buffer. An array of a million members leaves a stack of a
  million slots, 8 MB.
- **The builder keeps the value alive until it is reset.** A caller that
  reuses a builder resets it once it has taken the value. Slice 7's readers
  reset it once per record.
- **A bad document holds no memory,** since an error drops what was built.
- **`equal?` can't compare hashtables,** and compares `json-number`
  records by identity. The tests compare canonical forms, until slice 6's
  `json=?` (ADR-0006).
- **Hashtables cost little more than alists:** up to 2 ms per MB above.
- **Building is a loop, not a recursion,** so the depth limit's maximum
  of 65,535 levels builds like any other depth.
- **Which values `null` accepts leans on the implementation's `record?`.**
  Chez's is true of hashtables, which the rule refuses by name, and of
  conditions, enum-sets, record-type descriptors and time objects, which it
  accepts. None of these collides with a JSON value, but another
  implementation may refuse some of them. Guile and Racket are checked by
  hand (ADR-0003).
