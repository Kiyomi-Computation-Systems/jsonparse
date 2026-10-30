# ADR-0012: Tests use licensed, vendored corpora and generated cases

- **Status:** Accepted, revised the same day
- **Date:** 2026-10-30
- **Scope:** the test corpora and the test methods
- **Related:** plan M1 test lanes; ADR-0002, ADR-0004, ADR-0005, ADR-0008,
  ADR-0011

> **Revision (2026-10-30, slice 1).** The yajl row named `fg_` as an option
> prefix. yajl's runner turns options on for `ac_`, `ag_`, `am_` and `ap_`
> only, so `fg_` and `np_` are plain cases. Decision 1 now spells out what
> `check-corpora` holds, Decision 2 lists yajl's divergences and adds pinned
> `n_` reasons, and Decision 5 says how the differential and the schedules
> are run.

## Context

Correctness is the owner's first priority. jsonparse is BSD-3-Clause, so
vendored test data must allow redistribution. `make test` runs in a container
with no network (ADR-0008), so test data must be in the repository.

**The corpora surveyed on 2026-10-30.** Each license was read at its source.

| Corpus | What it has | License |
|---|---|---|
| nst/JSONTestSuite `test_parsing` | 95 `y_`, 188 `n_`, 35 `i_` | MIT |
| yajl `test/parsing/cases` | 58 inputs, each with a `.gold` event stream. Filename prefixes turn on yajl's options: `ac_` 2, `ag_` 3, `am_` 4, `ap_` 4. The other 45, `fg_` and `np_` included, run with none. Its runner parses every case with read buffers of 1 to 31 bytes and demands the same output. | ISC |
| SRFI 180 `srfi/files` | 3 JSON Lines files from python-jsonlines, of 2 records each, and 2 RFC 7464 logs from json-text-sequence, one with a broken record | MIT, BSD-3-Clause, MIT |
| nativejson-benchmark `data/roundtrip` | 27 files that must write back byte for byte | MIT |
| parse-number-fxx-test-data | lines of a number's text and its float16, float32 and float64 bits; not every text is a JSON number | Apache-2.0 |
| json.org JSON_checker `pass*`, `fail*`, and its copies in RapidJSON, nativejson-benchmark, yyjson and CPython | 36 files | the JSON license, which adds "The Software shall be used for Good, not Evil." RapidJSON's license tells users to exclude its copy. |
| simdjson-data, nlohmann/json_test_data | aggregates | none |
| Markus Kuhn's UTF-8-test.txt | a document of byte sequences, with no pass or fail | CC BY 4.0 |

No real corpus exists for JSON Lines or RFC 7464. SRFI 180's five files are the
only licensed ones found.

**The test machinery within reach:**

- **SRFI-64 comes from chez-srfi,** a submodule at `vendor/chez-srfi`. It is
  pinned at the commit chez-http-server pins, `7879b52`. chez-srfi has no
  release tags upstream.

- **circuit's property suite** (`tests/test-router-properties.sps`) has:
  - seeded generators whose cases depend only on the seed and the case
    number;
  - greedy shrinking;
  - failures printed as data, with the seed and the case number.

  It lives inside one suite, not in a library.
- **byte-machine's property driver** (`test/support/harness`, reached through
  `vendor/byte-machine`, ADR-0002) has:
  - chunk schedules: every split, every pair of splits, empty chunks, padded
    buffers and sub-slices;
  - a differential between the interpreter and the generated parser;
  - a minimizer.

## Decision

1. **Each vendored corpus lives in `tests/corpus/<name>/`,** with its upstream
   license file and a `SOURCE` file giving the URL, the commit and what was
   taken. `make check-corpora`, which `make test` runs, fails unless:
   - every entry in `tests/corpus/` is a directory;
   - each holds a non-empty `LICENSE` and a `SOURCE` with the keys name,
     url, commit, fetched, taken and license, once each;
   - nothing under it is named or marked like a JSON_checker file.

   A symlink anywhere counts as missing, and links are never followed. Each
   corpus arrives with the slice whose gate uses it: JSONTestSuite and yajl
   in slice 1.
2. **Vendored corpora, and what each one gates:**
   - **JSONTestSuite:**
     - every `y_` is accepted and every `n_` rejected;
     - the `i_` results, and the code and offset of every `n_` rejection,
       are pinned in `tests/golden/jsontestsuite.txt`.
       `tests/write-golden.sps` rewrites it, by hand only.
   - **yajl's 58 cases.** A committed script translates each `.gold` into
     jsonparse's events, and reduces its error text to "rejected".
     - Strict mode must give those events. yajl prints a double to six
       significant digits (`3.141569` as `3.14157`), so doubles are compared
       at that precision.
     - An option-prefixed case expects rejection in strict mode, after a
       prefix of the gold's events, and yajl's outcome under the matching
       option (M4). The `am_` cases already give the gold's events with the
       `mode` bit that allows several values.
     - **Five plain cases diverge,** each listed in `tests/test-yajl.sps`
       with jsonparse's own events and a reason. The suite fails if a listed
       case starts to match the gold:
       - `deep_arrays` nests 1,024 arrays, past the default limit
         (ADR-0005). It matches the gold with the limit raised.
       - `high_overflow` and `low_overflow`: integers are exact (ADR-0011).
       - `isolated_surrogate_marker`: the machine enforces surrogate pairing.
       - `leading_zero_in_number`: `01` is one malformed number, where yajl
         prints `integer: 0` first (RFC 8259 §6).
   - **nativejson-benchmark's 27 round-trip files.** Reading then writing
     gives back the file's bytes:
     - in `text` mode, every file;
     - in `flonum` mode, every file not listed, each listed one with its
       reason.
   - **SRFI 180's five files,** with all three upstream notices.
   - **Two files of parse-number-fxx-test-data,** `more-test-cases.txt` and
     `lemire-fast-float.txt`. A committed script filters them to JSON numbers.
     In `flonum` mode, each must read as exactly its float64 bits. This is the
     check of ADR-0011's "nearest flonum" that doesn't trust the Scheme reader.
     Apache-2.0 requires its license and a `NOTICE`.
3. **Not vendored:**
   - the JSON_checker files, in any copy, because of the JSON license.
     JSONTestSuite covers the same ground.
   - simdjson-data and nlohmann/json_test_data, which have no license.
   - Kuhn's file, whose byte sequences are written as our own cases.
4. **Written in-house, each case citing the clause it tests:**
   - UTF-8: overlong forms, encoded surrogates, truncated sequences,
     five- and six-byte forms, `#xFE` and `#xFF`;
   - numbers: the digit limit and the ranges (ADR-0011);
   - depth (ADR-0005);
   - JSON Lines, NDJSON and RFC 7464, from the specs' text.
5. **Methods:**
   - **Chunking.**
     - Inputs of at most 64 bytes are cut at every split and every pair of
       splits, using byte-machine's schedules (`schedules-for`). That covers
       the in-house cases and 311 of JSONTestSuite's 318 files.
     - Every corpus file of at most 4 KB is read with chunks of 1 to 31
       bytes, as yajl's runner does.
     - Larger files are read with chunks of 1, 7 and 31 bytes and with
       random schedules.
   - **Differentials:**
     - the interpreter against the generated parser. byte-machine's
       property driver answers decisions from a fixed script, which a stack
       can't be, so `(jsonparse-testing machine)` runs both lanes with a
       list stack and compares whole traces under the same schedules. A
       trace holds every callback with its bytes, and after each feed the
       status, cursors, error, state name, open span and every field;
     - the tree builder against a tree folded from the events;
     - the easy layer against the low layer (ADR-0010).
   - **Property tests** use `(jsonparse-testing property)`, a test-only
     library modelled on circuit's: seeded, shrinking, failures printed as
     data. The writer slice adds a JSON value generator for the round trip and
     the writer (ADR-0007, ADR-0011).
     - **The seed travels in a run record,** since R6RS forbids assigning an
       exported variable.
     - **A case's first state comes from mixing,** not from circuit's formula.
       It applies murmur3's 32-bit finalizer to the seed, then the property,
       then the case index. Circuit's formula is affine in the index, as is
       the sequence that follows it. Measured on 2026-10-30, neighbouring
       cases drew the same first `(g-int 100)` 1,300 times in 3,999, where
       chance is about 40. Mixing gives 47. A suite row fails under circuit's
       formula.
     - **`g-int` draws uniformly, by rejection.** Circuit's takes 15 bits
       modulo n, which is biased. For n = 20,000, values below 12,768 drew
       78% of the time, where uniform is 64%. A suite row fails on the
       biased version.
   - **Mutation fuzzing.** Seeded byte mutations of the corpus files must keep
     these invariants:
     - the low layer never raises;
     - an error's offset lies inside the input;
     - chunking doesn't change the answer;
     - the interpreter and the generated parser agree.

     Each case also draws a depth limit and the `mode` bit. Feeds scale with
     the input, so most cases are split. `make test` runs a fixed seed. A seed and a multiplier given by hand run
     longer, as circuit's suite allows.

## Consequences

- **Correctness rests on independent sources:** JSONTestSuite, yajl's event
  streams, cases written from the specs, and float bits computed outside
  Scheme.
- **The JSON Lines and RFC 7464 cases are mostly ours,** so each one cites its
  spec clause.
- **Adding a corpus without its license or `SOURCE` file fails the check.**
- **The vendored data is small:** the largest file is about 127 KB.
