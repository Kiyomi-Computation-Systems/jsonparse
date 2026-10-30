# ADR-0006: How JSON values are represented

- **Status:** Accepted
- **Date:** 2026-10-30
- **Scope:** the values the tree builder produces and the writer accepts
- **Related:** plan §7 question 3; ADR-0007, ADR-0010, ADR-0011

## Context

Objects could be alists or hashtables, and `null` could be a symbol or a
unique value. chez-json read both `[]` and `null` as `()`, a bug no caller can
work around.

**Alist versus hashtable:**

| | alist | hashtable |
|---|---|---|
| Key order | kept | lost (R6RS hashtables have no order) |
| Duplicate keys | all kept | needs a rule |
| Looking up a key | linear | constant |
| Cost to build | one pair per member | a table per object, costly when small |
| `equal?`, printing, round trip | work | don't |

**Symbol versus unique value for `null`:**

- **The symbol `null`** is readable, works with `equal?`, can be written in
  quoted test data, and is the same on every R6RS system.
- **A unique value** can't collide with anything, but it doesn't print or
  read back, and tests need quasiquote.

## Decision

- **Objects are alists in document order by default,** with duplicate keys
  kept. An option builds an R6RS hashtable keyed by string instead. With a
  hashtable, the last duplicate wins by default, as JavaScript's and Python's
  parsers do.
- **Keys are strings,** never symbols: keys from untrusted input would grow
  the symbol table.
- **Arrays are vectors, strings are strings, and `true` and `false` are `#t`
  and `#f`.**
- **`null` is the symbol `null` by default, and it is configurable.** A null
  value that collides with another representation is refused when the options
  are made. For example, `'()` is refused, because it is the empty object
  under alists.
- **Numbers convert by a mode set with the options** (ADR-0011). By default,
  integers are exact and other numbers are flonums.

## Consequences

- With the defaults, `{}` is `()`, `[]` is `#()` and `null` is `null`: all
  distinct.
- With hashtables, `equal?` can't compare trees, so jsonparse provides a
  structural equality.
- The writer must know the null value in force, so it takes the same options.
