# ADR-0012: Tests use licensed, vendored corpora and generated cases

- **Status:** Accepted, revised the same day and on 2026-11-08
- **Date:** 2026-10-30
- **Scope:** the test corpora and the test methods
- **Related:** plan M1 test lanes; ADR-0002, ADR-0004, ADR-0005, ADR-0008,
  ADR-0011

> **Revision (2026-11-08, slice 8).** The last two corpora arrived.
> Measuring them, and the slice's review, changed these:
> - **parse-number-fxx-test-data has no `NOTICE` file,** so Apache-2.0
>   asks for none (§4(d)). Its `LICENSE` and `AUTHORS` go into the corpus's
>   `LICENSE`. Its README says `lemire-fast-float.txt` was extracted from
>   lemire/fast_float, which is licensed under Apache-2.0, MIT or BSL-1.0.
> - **The filter is `tests/test-float64.sps`'s own,** in Scheme, and the
>   two files are vendored unchanged. It drops 6 of `lemire-fast-float.txt`'s
>   3,299 texts, such as `.5` and `1.e2`.
> - **The two files can't catch every wrong conversion.** A reader that kept
>   20 significant digits, or rounded twice below the least normal, passed
>   them. Our own `tests/fixtures/float64/hard-cases.txt` adds 24 texts
>   that catch both: digits that decide the rounding, out to the 800th, and
>   ties at the subnormal and overflow edges. Their bits come from Python's
>   `float()` on the host, each checked by rounding the text's exact value.
> - **The float64 lane also reads every text other ways:**
>   - flonum mode reads an integer text as an exact integer (ADR-0011), so
>     2,693 texts would skip the check. Each is also read with `e0` after
>     it, the same number, which must give its bits;
>   - every text is also read with `-` before it, which must give the same
>     bits with the sign set, and inside an array, ended by `]`;
>   - the lane raises the digit limit past the longest text, 1,023 digits.
>     At the default limit, the two texts over 1,000 digits must be
>     `number-too-long`.
> - **Every round-trip file comes back in `flonum` mode,** so the list of
>   exceptions is empty.
> - **A suite whose flonum expectations come from Chez says so in its
>   header,** since they share the converter the library uses.
> - **The plan's exit criterion of a documented API is checked:**
>   `tests/test-docs.sps` fails unless every name a `(jsonparse ...)`
>   library exports is named in `docs/`.
>
> Decision 5's methods reach the new files:
> - nativejson-benchmark's files join the parser, number, tree and easy
>   suites' corpus, so they are cut at every split and pair of splits, and
>   the round-trip suite reads them in chunks of 1 to 31 bytes;
> - SRFI 180's files are read in chunks of 1 to 31 bytes, and the three of
>   40 bytes or less at every split and pair, by the sequence suite;
> - fuzzing seeds from every corpus's files of JSON text of at most 4 KB:
>   JSONTestSuite's `i_` files, yajl's, SRFI 180's and
>   nativejson-benchmark's, beside the `y_` and `n_` files.
>
> parse-number-fxx's files are tables of numbers, not JSON text: each number
> is fed whole and a byte at a time. The interpreter is compared with the
> generated parser on JSONTestSuite's files directly, and on the others
> only through fuzzing's mutants. Fuzzing drives the parser, not the reader:
> SRFI 180's RS-framed files mostly fail at their first byte, and the
> reader's own mutation lane is `tests/test-sequence-property.sps`.

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
     `lemire-fast-float.txt`. `tests/test-float64.sps` filters them to JSON
     numbers. In `flonum` mode, each must read as exactly its float64 bits.
     This is the check of ADR-0011's "nearest flonum" that doesn't trust the
     Scheme reader. Apache-2.0 requires its license; the repository has no
     `NOTICE` to carry. Our own hard cases join them (revision above).
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
       splits, using byte-machine's schedules (`schedules-for`), or the
       sequence suite's own for streams. That covers the in-house cases, 311
       of JSONTestSuite's 318 files, nativejson-benchmark's 27, and SRFI
       180's three `.jsonl` files.
     - Every corpus file of JSON text of at most 4 KB is read with chunks of
       1 to 31 bytes, as yajl's runner does.
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
- **The vendored data is small:** the largest file is a JSONTestSuite nest
  of 250,001 bytes. The next are `lemire-fast-float.txt`, 127,450 bytes, and
  a nest of 100,000.
