# ADR-0013: Benchmarks compare with yajl and Scheme peers on public files

- **Status:** Accepted
- **Date:** 2026-10-30
- **Scope:** what jsonparse is measured against, on what input, and how
- **Related:** plan M3; ADR-0008, ADR-0009

## Context

The owner names yajl as best in class. jsonparse can't be expected to beat it,
but performance is still a goal. The owner also wants Racket and Guile, Gambit
if it is fast, and is open to others such as Jackson.

**Comparators surveyed on 2026-10-30.** All are packaged at the Guix commit
the siblings pin (ADR-0008).

| Comparator | Kind | Guix |
|---|---|---|
| yajl | C, callback events, incremental; `master` last changed 2015-09-24 | `yajl` 2.1.0 |
| RapidJSON | C++, SAX and DOM | `rapidjson` 1.1.0 |
| Jackson `JsonParser` | Java, pull events | `java-fasterxml-jackson-core` 2.9.4 (2018) |
| Racket `json` | built in, tree only, pure Racket | `racket` 9.3 |
| guile-json | Guile, tree; GPL-3.0 | `guile-json` 4.7.3 |
| Gambit `_json` | in Gambit since 4.9.7 | `gambit-c` 4.9.7 |
| Gerbil `:std/text/json` | tree, on Gambit | `gerbil` 0.18.1 |
| Chibi `(chibi json)` | tree, reader in C | `chibi-scheme` 0.12 |
| SRFI 180 reference | portable Scheme, MIT, with `json-fold` and `json-generator` events | not packaged |
| chez-json | Chez, tree; M0's baseline | not packaged |
| simdjson, yyjson | C++ and C, tree only, the fastest published | `simdjson` 4.6.3, `yyjson` 0.12.0 |

Only Chez, Racket and g++ are on this host now.

**Files used by others.** nativejson-benchmark's `canada.json` (2.25 MB,
mostly numbers), `citm_catalog.json` (1.73 MB, indented, repeated keys) and
`twitter.json` (632 KB, strings, CJK and escapes) appear in most published
results. The repository is MIT, but it states no terms for these files, and
`twitter.json` is real tweets.

**How others measure:**

- the input is read into memory before timing;
- runs are repeated, and the minimum is reported: yyjson takes the best of 16,
  simdjson the best time;
- results are given as throughput. yyjson's GB/s divides by 2^30 and
  simdjson's by 10^9.

## Decision

1. **Three lanes, each with its comparators:**
   - **Events only:** yajl, the reference; RapidJSON's SAX; Jackson's
     `JsonParser`; SRFI 180's `json-fold`, run on Chez.
   - **Tree:** Racket, guile-json, Gambit, Gerbil, Chibi, SRFI 180's
     `json-read` on Chez, and chez-json.
   - **Ceilings, not targets:** simdjson and yyjson.
2. **The input files:**
   - `canada.json`, `citm_catalog.json` and `twitter.json`;
   - two long-string files from yyjson_benchmark, `gsoc-2018.json` (ASCII)
     and `poet.json` (CJK);
   - M0's synthetic files.

   A script fetches them on the host and checks each file's SHA-256. They are
   never committed.
3. **The method:**
   - the input is read into memory first, and one warm-up run comes before
     timing;
   - at least 9 timed rounds, reporting the minimum and the median in MB/s,
     where 1 MB is 10^6 bytes;
   - parsing alone and parsing with a traversal are reported apart;
   - the events lane counts events by kind, so no work can be skipped, as
     nativejson-benchmark's "Sax Statistics" does;
   - each report names the machine, the OS, every runtime's version, and what
     each file is mostly made of.
4. **Comparators come from a benchmark manifest beside `manifest.scm`.** On the
   owner's Mac they come from Homebrew. A comparator is measured, never
   vendored.
5. **Only `make bench` needs them.** `make test` and CI never do.
6. **M3's targets are unchanged:** within 2× of yajl on `records-2k` events
   only, and within 4× on `escaped-string`.

## Consequences

- **jsonparse's numbers can be read beside published ones:** the same files,
  the same units.
- **Benchmarks need the network once, on the host,** like the Akku lock
  (ADR-0008).
- **arm64 numbers come from the owner's M1 laptop** (ADR-0009).
- **SRFI 180 and chez-json need a small R6RS wrapper each** to run on Chez.
  The wrapper lives with the benchmarks.
- **Jackson at the pin is from 2018.** A newer one would come from Maven on
  the host.
