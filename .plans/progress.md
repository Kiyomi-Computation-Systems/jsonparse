# Progress ledger

Where jsonparse stands. Read it with
[global-constraints.md](global-constraints.md) before starting slice work.
When a slice merges, update **Now** and add a close-out under **Close-outs**,
newest first.

## Now

- **Milestone 0, the prototype and its measurements, is done** (2026-10-03).
  The plan is
  [project-plan/2026-10-03-byte-machine-json-plan.md](project-plan/2026-10-03-byte-machine-json-plan.md);
  the prototype is beside it.
- **The plan was revised on 2026-10-30 with the owner's answers to its §7.**
  ADR-0001 to ADR-0011 record them, and none of its questions is open.
  ADR-0012 to ADR-0014 add the test corpora, the benchmark comparators and
  streams of values.
- **Three measurements were made the same day:**
  - the stack, on the prototype regenerated with byte-machine 0.8.0
    (`prototype/stack-*.sps`, ADR-0004);
  - number conversion and printing (ADR-0011);
  - how textual ports decode invalid UTF-8 (ADR-0010).
- **The planning merged on 2026-10-30** as #1.
- **Slice 0, the scaffolding, is done** (close-out below).
- **Slice 1 of M1, the grammar and the generator, is done** (close-out
  below).
- **Slice 2, the push parser, is done** (close-out below).
- **Slice 3, the assembler, is done** (close-out below).
- **Slice 4, the tree builder, is done** (close-out below).
- **Slice 5, the writer, is done** (close-out below).
- **Slice 6, the easy layer, is done** (close-out below).
- **Slice 7, streams of values, is done** (close-out below). Every library
  the plan's M1 lists now exists.
- **An audit of M1's exit criteria and test lanes** (2026-11-08) found
  three of four criteria met; the docs left 19 exported names out. Two
  lanes lacked their corpora, and fuzzing covered one corpus.
- **Slice 8, closing M1, is done** (close-out below). The slice's review
  re-audited M1 from scratch, and every lane and exit criterion is met.
- **Slice 9, the docs site, is done** (close-out below). `docs/` renders to
  a site as the siblings' do, and Pages publishes it at the first release
  tag.
- **Slice 10, the first release, is done** (close-out below). The owner chose
  on 2026-11-08 to release 0.1.0 after M1, ahead of the plan's M5
  (ADR-0022). The tag follows the merge, and the Akku submission waits
  for the owner.
- **M3 began on 2026-11-08, before M2,** as ADR-0004 orders. The owner made
  this Linux NUC the reference machine, and chose to measure jsonparse and yajl
  first, with the other comparators next (ADR-0023).
- **Slice 11, the benchmarks, is done** (close-out below). `make bench`
  measures jsonparse against yajl, pinned to one performance core. Neither
  M3 target is met: `records-2k` is 4.1× to 4.3× behind yajl and
  `escaped-string` 4.3× to 4.6×, against 2× and 4×.

## Next

**Milestone 1, in order:**

1. **The grammar and generator** (done, close-out below).
   - They move from the prototype into `grammar/`, outside `src/`
     (ADR-0003). The committed `(generated jsonparse)` gets its regeneration
     check.
   - The corpora are vendored, with the license and `SOURCE` check
     (ADR-0012).
   - Gates: JSONTestSuite `y_` and `n_`, the `i_` results pinned in a golden
     file, yajl's event streams, chunking invariance, an
     interpreter-versus-generated differential, and mutation fuzzing.
2. **`(jsonparse parser)`** (done, close-out below).
   - It covers the internal stack, the options record and the depth limit
     (ADR-0004, ADR-0005), behind a handler of named procedures (ADR-0015).
   - Its results use jsonparse's own types (ADR-0010).
3. **`(jsonparse string)`** (done, close-out below): the assembler, the
   number modes and the digit limit (ADR-0011, ADR-0016).
4. **`(jsonparse tree)`** (done, close-out below): the builder and the
   `object-mode` and `null` options (ADR-0006, ADR-0017).
5. **`(jsonparse writer)`** (done, close-out below): `put-json`,
   `&json-error` and the `indent` option (ADR-0018).
6. **`(jsonparse easy)`** (done, close-out below): reading, writing,
   `json-ref`, `json=?` and `json-null?`, and `check-json` in the writer
   (ADR-0019).
7. **`(jsonparse sequence)`** (done, close-out below): JSON Lines and
   NDJSON, RFC 7464 and whitespace-separated values, and the easy layer's
   stream procedures (ADR-0014, ADR-0020).
8. **Closing M1** (done, close-out below): the corpora, lanes and docs
   check that the audit of 2026-11-08 found missing (ADR-0012).

**After M1:**

9. **The docs site** (done, close-out below): `docs/` rendered by circuit's
   generator, checked on every pull request, and published to GitHub Pages
   on a release tag (ADR-0021).
10. **The first release** (done, close-out below): 0.1.0, packaged for Akku
    with Akku 1.2.0 and checked by installing it as a consumer would
    (ADR-0022). Publishing to Akku, M5's Guix package and its chez-json note
    wait.

**Milestone 3, performance (ADR-0013, ADR-0023):**

11. **The benchmarks** (done, close-out below): `make bench` times jsonparse against
    yajl on eight pinned files, and the report cross-checks both harnesses'
    counts. The first measurement and its profile are in ADR-0023.
12. **The other comparators** (ADR-0013): RapidJSON, Jackson, SRFI 180,
    Racket, guile-json, Gambit, Gerbil, Chibi, chez-json, simdjson and
    yyjson.
13. **The callback path,** which costs 6 to 13 ns per value against yajl's
    1.8 or less. First separate the machine's span delivery from
    jsonparse's handler path, then cut what is jsonparse's, which needs no
    byte-machine change.
14. **The run node** in byte-machine (plan M3, lever 2): a decision record
    there, ABI 9 to 10, a byte-machine release, and the sibling consumers'
    parsers regenerated.
15. **The number fast path** (lever 4).
16. **M2's decision,** measured (ADR-0004).

**Then:** M4, YAJL's options; and the rest of M5.

## Close-outs

### Slice 11: the benchmarks (2026-11-08)

- **Landed:**
  - **`make bench`** (ADR-0023): jsonparse against yajl on the eight files
    `bench/files.lock` pins, five fetched on the host and M0's three
    written by `bench/synthetic.sps`. Five lanes: `parse`, `events`, which
    holds M3's targets, `tree`, `tree+walk` and `scan`.
  - **The harnesses:**
    - `(jsonparse-bench)` and `bench/run.sps` time jsonparse's lanes, with
      the libraries compiled ahead of time;
    - `bench/yajl-bench.c` times yajl's;
    - both run pinned by `taskset` to the core `scripts/bench-cpu` picks.
  - **The report** (`(jsonparse-bench report)`) is written only when the
    results cross-check:
    - one pass's counts agree across yajl, jsonparse's events, the walk
      and the scan;
    - every lane ran the passes the method says;
    - the timed passes counted one pass's counts times the passes;
    - the results name exactly the lock's files.
  - **`scripts/fetch-bench-files`** fetches on the host and checks every
    sha256. `--check` holds the timed directory, and `--list` gives the
    Makefile its files.
  - **Tools:** `bench/manifest.scm` (yajl, gcc 14, pkg-config, util-linux)
    behind `scripts/guix-env --bench`, asserted by `make check-guix`.
  - **`$(SUBMAKE)`** for recipes that start another make, so `make -n bench`
    and `make -n check-akku` start nothing.
  - **CI:** the linux job runs `make check-bench-files`.
  - **Records:** ADR-0023; revision notes on ADR-0003, ADR-0013, ADR-0022
    and the plan's M3; the global constraints; this ledger's M3 list.
- **Evidence:**
  - `scripts/guix-env make test` runs 37 suites; `test-bench` passes 74.
    The fetch script's test passes, on the host and in Ubuntu 24.04, and
    the launcher's passes 104. `make check-guix`, `make check-akku` and
    `make check-help` are green.
  - **Every new check was watched fail:**
    - 78 of 80 mutants of the benchmark library, 23 of 23 of the fetch
      script, 3 of 3 of the launcher, and 7 of 7 of yajl's harness, refused
      by the report;
    - `make check-akku` without `bench` in `.akkuignore`;
    - `check-bench-env-inside` without util-linux;
    - the `make -n` test with `$(MAKE)` put back.
  - **The two surviving mutants:**
    - a `parse` lane that also counts, which can only make jsonparse look
      slower in a lane that holds no target;
    - collecting time read from CPU time, which equals wall time in one
      thread.
  - **The measurement:** two pinned runs, in ADR-0023.
    - Neither target is met.
    - Rates moved up to 5.8% between runs, and gaps up to 9.8%.
- **Review:** an adversarial review (Opus) found:
  - **three defects:**
    - the cross-check never saw the timed passes, so a harness timing
      other work, or fewer passes, still reported cleanly;
    - Homebrew's yajl include path would break the build on the M1
      laptop;
    - `make -n bench` ran the benchmark;
  - **six gaps:**
    - 11 surviving mutants;
    - the Makefile and the fetch script read the lock differently;
    - no core pinning on a hybrid CPU, where yajl ran 547, 336 or 253 MB/s
      by core;
    - `--check` not tied to the timed directory;
    - no `check-guix` assertion for the bench tools;
    - the events lane's unequal work on escaped strings;
  - **six false or unsupported claims:** a rounding; the scan as the floor
    for any Scheme parser; per-value callback costs stated without their
    noise, and called jsonparse's own; yajl's flags; the run-to-run bound;
    and byte-machine's baseline left unplaced;
  - **eight nits.**

  All are fixed but three, which are recorded:
  - the events lane's asymmetry on escaped strings, measured at 5% to 6%,
    is kept;
  - the fetch test needs curl, since wget reads no `file://`;
  - the report's date is UTC.
- **Known:**
  - **The owner ran `make bench` twice on the M1 laptop,** unpinned, and
    ADR-0023 records the runs. They decide nothing. Their gaps are
    smaller, because yajl runs slower there while jsonparse runs about as
    fast as on the NUC, and `escaped-string` reads as met there.
  - **Next is slice 12, the other comparators.** The callback path follows,
    then the run node.

### Slice 10: the first release (2026-11-08)

- **Landed:**
  - **0.1.0** (ADR-0022): `Akku.manifest`, a Keep a Changelog
    `CHANGELOG.md`, the home page's Status, `README.org`'s install steps
    and taste, and `docs/installing.md` in the nav. Semantic versioning,
    with a new byte-machine runtime ABI meaning a new minor version.
  - **`make check-release`,** in `make test`: `Akku.manifest`, the newest
    `CHANGELOG.md` release and the home page's Status name one version.
  - **Akku 1.2.0,** pinned by sha256 in `scripts/akku-tool.lock`, fetched by
    `make akku-deps` and run by `scripts/akku` with its data and cache
    under `build/`. Its signature is Gwen Weinholt's key, the same at
    keys.openpgp.org and keyring.debian.org.
  - **`make check-akku`:** git writes the archives Akku would serve, on the
    host or in CI; the install runs offline, in the container on a Guix
    host. It checks the archive is the working tree's and ships no design
    records, that exactly `src/`'s 9 libraries and the `LICENSE` land, and
    that a consumer reads, builds and writes JSON on Akku's path alone. CI's
    `linux` job runs it on both arches.
  - **`.akkuignore` in circuit's form.** Only `site` and `grammar` change
    what lands; the rest are recorded as guards.
  - **`scripts/akku-publish`,** for the owner: a fresh clone at the tag,
    the version checked, signing forced to the release key and checked on a
    probe before and on the submission after.
  - **Records:** ADR-0022, revision notes on ADR-0003 and ADR-0021, and the
    global constraints' Releases section.
- **Evidence:**
  - `scripts/guix-env make test` runs 36 suites; `test-check-release`
    passes 23. `make check-site` passes 81 and 19, and `make check-akku`,
    `make site` and `make check-release` are green.
  - **Every new check was watched fail:** 9 mutants of `check-akku`, 14 of
    `check-release`, and `json->string` and `string->json` dropped from
    `easy.md` for `test-docs`. Without `tests` or `vendor`, `.akkuignore`
    installs the same.
  - `check-release` caught its own crash on the empty `CHANGELOG.md`, and
    the suite gained the case before the fix.
  - Akku 1.2.0 installed a real package from the live index on the host,
    making `Akku.manifest` in an empty directory.
- **Review:** an adversarial review (Opus) found:
  - **a defect:** `akku-publish` never checked that the tag's
    `Akku.manifest` gives the version it publishes. Akku publishes the
    version the tag's manifest gives, as an "untagged release";
  - **six gaps:**
    - `test-docs` counted `installing.md` as a guide;
    - seven `check-release` mutants passed its suite;
    - `check-akku` never checked the archive was the working tree;
    - `R6RS_PATH` reached the consumer;
    - `akku-publish` called a submission the archive refused a success;
    - `akku-publish` has no committed test;
  - **three false claims:** M2 and M3 each bumping the ABI (they share one);
    a guide for each library; and the changelog's number claims without
    their conditions;
  - **nits:**
    - CI's comments missed `check-release`;
    - Akku's index landed in the pinned tree;
    - BSD sed reads no `\t`;
    - macOS names Chez `chez`;
    - the publish script found a missing Akku late;
    - the release procedure lacked its version and install checks.

  All are fixed but two. The publish script's test comes before
  publishing (ADR-0022 Decision 8), and CI's Akku download stays uncached.
- **Known:**
  - **Publishing to Akku waits for the owner.** The docs say the package is
    coming; after publishing, they say `akku install jsonparse`, and Pages
    runs by hand from `main`.
  - **The `CHANGELOG.md` date is the tag's by hand.** Nothing checks it.
  - **CI downloads Akku from gitlab.com on every run,** so GitLab down is a
    red `linux` job.
  - **M5's Guix package and chez-json note wait.**

### Slice 9: the docs site (2026-11-08)

- **Landed:**
  - **The generator,** copied from circuit (ADR-0021): the eight libraries
    under `site/`, the stylesheet, `build-site.sps`, the lock fetcher and
    the three suites. Five libraries and the fetcher are byte for byte
    circuit's; `pages`, `links` and `template` carry jsonparse's nav, URL
    and name.
  - **`docs/README.md`,** the home page: a taste, the ideas to keep in mind,
    the libraries, and a "Read next" list that is the nav.
  - **`make site`, `site-deps`, `check-site` and `check-site-deps`.**
    chez-cmark-gfm 2.0.0 is a `depends/dev`, locked beside byte-machine and
    fetched on the host. `make test` still needs neither it nor the network.
  - **The container** gains cmark-gfm, `tar`, `xz` and `curl`.
    `guix-env-enter` exports `CHEZ_CMARK_GFM_LIBS` and refuses a profile
    without both libraries. `check-guix` holds the tools, the export, the
    loads and `check-site-deps`.
  - **CI's `site` job** checks and builds the site on every pull request,
    and `pages.yml` deploys it on a `v*` tag or by hand from `main`. Pages
    builds from Actions, and the `github-pages` environment takes `main` and
    `v*` tags only, as the siblings' do.
  - **Checks beyond circuit's:**
    - `site-check`'s seventh: every link in the home page's Read next
      section is the nav, in order, under its labels;
    - `site-unit` pins jsonparse's description and keywords, and four
      reference anchors as GitHub renders them;
    - `test-docs` pins the guides, which leave out the home page as they
      leave out the reference.
  - **Records:** ADR-0021 and the global constraints, whose CI rule now
    binds each job that runs Chez.
- **Evidence:**
  - `scripts/guix-env make test` runs 35 suites. `make check-site`:
    `site-unit` passes 81, `site-render-unit` 19, and `site-check` all seven
    invariants. `make site` writes 8 pages. `make check-guix` passes its 94
    launcher cases and the container's self-test.
  - **The site's anchors are GitHub's:** all 125 on the seven pages on
    `main`, in order.
  - **CI's `site` job, run in Docker on `ubuntu:24.04`** with apt's Chez
    9.5.8: the machine type, `check-site-deps`, `site-deps`, `check-site`
    and `site` all pass.
  - **Every new check was watched fail:** 18 mutants of the site, its docs
    and its suites; 4 of `guix-env-enter`; 1 of the lock fetcher; 2 of
    `test-docs`; and the self-test given wrong library paths. A broken
    template makes `make check-site` exit 2.
- **Review:** an adversarial review (Opus) found:
  - **a defect:** `--script /dev/stdin` can't seek a pipe on apt's Chez
    9.5.8, so the machine-type step would have failed the `site` job and
    every Pages build. Both use the REPL form now;
  - **four gaps:**
    - nothing held `test-docs`' exclusion of the home page;
    - check 7 read only lines starting `- [`;
    - `check-guix` held none of the container's new tools;
    - the head's description and keywords were unpinned;
  - **two false claims:** that the site needs only chez-srfi's checkout,
    and an amd64-only job with no reason given;
  - **nits:**
    - the home page's `make run` printed nothing;
    - "raises" was true of the easy layer only;
    - a run by hand deploys only from `main`;
    - `make clean` deletes the fetched tree.

  All are fixed.
- **Known:**
  - **The home page says "Not released yet."** The release commit updates
    its Status before the tag, or the live site says it of a release.
  - **`build-site.sps` sits outside `.akkuignore`,** as circuit's does.
    M5's `make check-akku` should confirm nothing outside `src/` reaches
    the package.
  - **The generator is copied, not shared:** a fix in one sibling reaches
    the others by hand.
  - **Nothing is published yet.** The site goes live at the first `v*` tag,
    or a run by hand from `main`.

### Slice 8: closing M1 (2026-11-08)

- **Landed:**
  - **Two corpora** (ADR-0012), vendored unchanged:
    - nativejson-benchmark's 27 round-trip files, MIT;
    - parse-number-fxx-test-data's `more-test-cases.txt` and
      `lemire-fast-float.txt`, Apache-2.0. The repository has no `NOTICE`,
      so none is owed; its `AUTHORS` and fast_float's provenance are in the
      corpus's `LICENSE`.
  - **`roundtrip`:** reading then writing gives back every file's bytes,
    in `text` mode, `flonum` mode and the defaults, in one feed and in
    chunks of 1 to 31 bytes. No file needs an exception.
  - **`float64`:** 3,353 corpus texts and 24 hard cases of our own read in
    `flonum` mode as exactly their float64 bits, or `number-out-of-range`
    where those are infinite.
    - Integer texts are also read with `e0` after them, so they meet the
      flonum path too.
    - Every text is also read with `-` before it, inside an array, a byte at
      a time, and at the default digit limit.
    - The hard cases need digits out to the 800th, or sit on ties at the
      subnormal and overflow edges. Their bits came from Python's `float()`
      on the host, and the suite checks each against its text's exact value,
      rounded by hand.
  - **`docs/reference.md`:** an entry for each of the 74 bindings, with
    its signature and the libraries that export it, in the siblings' form.
  - **`docs`:** the reference has exactly one entry for each exported name,
    naming exactly the libraries that export it, and none for anything
    else. Each name is also in a guide, and each library's count of exports
    is pinned. The guides now name the 19 that were missing.
  - **Wider lanes:**
    - fuzzing seeds from every corpus of JSON text, 406 files;
    - SRFI 180's files are read in chunks of 1 to 31 bytes, and the small
      ones at every split and pair;
    - nativejson-benchmark's files join the parser, number, tree and easy
      suites' corpus.
  - **Records:** ADR-0012's revision, which also corrects its decisions,
    and the global constraints.
- **Evidence:**
  - `scripts/guix-env make test` runs 35 suites in about 70 s. The new
    ones pass 6, 14 and 7.
  - **Every new assertion was watched fail:** 16 mutants of the library
    and 21 of the suites, the fixture and the docs.
  - **The float64 lane catches a reader that is one ulp off,** even only
    past 17 digits; one that keeps 20 significant digits; and one that
    rounds twice below the least normal.
- **Review:** an adversarial review re-audited M1 and found:
  - **two gaps:**
    - the corpus files passed a reader keeping 20 significant digits and
      one rounding twice in the subnormal range. Both suites that caught
      them took their expectations from Chez. The hard cases now catch
      both;
    - `docs` passed a reader that skipped each export clause's first name.
      The pinned counts catch it.
  - **five false claims:**
    - that Decision 5's methods reached every corpus;
    - a `NOTICE` required;
    - two counts in this ledger;
    - the largest file's size;
    - two constraints without their record.

    All are fixed. The new files now get every split and pair, and the
    parser, number, tree and easy differentials.
- **Known:**
  - **The interpreter meets the generated parser** on JSONTestSuite's files
    directly, and on the other corpora only through fuzzing's mutants.
  - **Fuzzing drives the parser, not the reader.** SRFI 180's RS-framed
    files mostly fail at their first byte. The reader's mutation lane is
    `sequence-property`.
  - **`parser-alloc` doesn't record the interpreter's allocation,** which
    byte-machine's decision 0040 records but doesn't gate.
  - **The round-trip files hold no escapes, whitespace or nesting,** so that
    lane checks numbers, signs and structure. The writer's and easy suites
    check the rest.

### Slice 7: streams of values (2026-11-08)

- **Landed:**
  - **The grammar under the `mode` bit** (ADR-0014's revision, ADR-0020):
    a top-level number or literal needs whitespace or the end after it, so
    `1-2` and `truefalse` fail, and an empty stream holds no values.
    Without the bit nothing changes.
  - **Options:** `stream` (`lines`, `seq` or `values`) and `blank-lines`
    (`error` or `skip`). `stream values` sets the bit.
  - **`(jsonparse sequence)`** (ADR-0020):
    - a reader frames `lines` and `seq` records by byte, for one reused
      builder, and never copies a record. Under `values` one builder reads
      the whole stream;
    - offsets count the stream's bytes, and records count from 1;
    - a bad record ends the stream, or is skipped and reported when
      ON-SKIP is given. Giving the procedure turns skipping on: the owner's
      choice, which revises ADR-0014;
    - its own codes are `blank-line`, `truncated`, and `unexpected-byte`
      before the first RS.
  - **Beside it:** the builder's EACH, `make-json-result`,
    `put-json-record` and `&json-record-error`.
  - **The easy layer:** `read-json-sequence`, `bytevector->json-sequence`,
    `fold-json-sequence`, `write-json-sequence` and
    `json-sequence->bytevector`, the owner's choice of names. The
    one-document readers refuse `stream values`.
  - **Suites:** `sequence` (442), `stream-api` (711), `sequence-alloc`
    (678), `easy-sequence` (460) and `sequence-property` (62). The
    `machine` suite's mode cases were rewritten (575).
  - **Corpus:** SRFI 180's JSON Lines and RFC 7464 files, read by the
    `sequence` suite.
  - **Records:** ADR-0020, revision notes on ADR-0014 and ADR-0019,
    `docs/sequence.md`, and additions to the other docs and the global
    constraints.
- **Results** (ADR-0020):
  - **`lines` and `seq` pay a builder's reset, feed and finish a record:**
    0.13 to 0.19 µs more than one array. That is 10 to 12% on records of
    92 bytes, and 2.1 to 4.4 times on values of 5 to 19 bytes.
  - **`values` reads at one array's speed,** 0.88 to 0.99 times as long.
  - **The separator scan** is 4 to 12% of reading `lines`.
  - **A record of `123456` costs 944 bytes** in `lines` or `seq`, and 129
    in `values`, where the reader adds 80 to an EACH builder.
- **Evidence:**
  - `scripts/guix-env make test` runs 32 suites in about 65 s.
  - **Every assertion was watched fail,** or reported as covering an
    equivalent change. About 450 mutants of the library and the grammar
    were run, by four builders, the review and me, and 43 of the property
    suite.
  - **The `sequence` suite reads 26,494 chunkings** of its streams: every
    split, every pair of splits, and chunks of 1, 2, 3 and 7 bytes.
- **Review:** an adversarial review found no library bug in normal use.
  - **Its one gap:** a reset that kept the record's first byte passed every
    suite. A stale byte turns an array into a `truncated` number, or a
    blank line into content. Three cases after a reset now fail on it.
    Checking every other field a reset clears found one more, `last`,
    which nothing reads before it is set again: removed as dead.
  - **Four claims were false or too broad:**
    - when a number is announced;
    - that every skipped record reaches ON-SKIP;
    - that the easy layer reads one document;
    - that each `values` record is a new parse.

    All are corrected, in ADR-0020, the constraints, the docs, and a
    revision note on ADR-0019.
  - **Its notes:** a reader keeps its largest string buffer, and re-entry
    into a continuation isn't detected. Both are now in ADR-0020 and
    `docs/sequence.md`.
  - **Before it,** a mutant of mine making enter and leave thunks on every
    call passed the allocation suite's bound of 128 bytes a record. A bound
    of 96 a value under `values` now fails it.
- **Known:**
  - **Under `values`, a corrupt stream can deliver values before its
    error:** `1 2x` gives 1 and 2, then `unexpected-byte` in record 3.
  - **A raw newline or RS ends a record,** even inside a string.
  - **Only `seq` detects a cut-off last record.** A `lines` stream's last
    line may lack its newline.
  - **Re-entering a continuation captured inside a reader's procedures**
    isn't detected (ADR-0020).

### Slice 6: the easy layer (2026-11-07)

- **Landed:**
  - **`(jsonparse easy)`** (ADR-0019):
    - **reading:** `string->json`, `bytevector->json` and `read-json`
      read one whole document with a new builder. Bad input raises
      `&json-error`, with the parser's code as its reason. Its offset is
      in characters for a string and in bytes otherwise;
    - **writing:** `json->string`, `json->bytevector` and `write-json`
      compose `put-json`. A refusal is raised again with the easy
      procedure as its who, and what a caller's port raises passes
      through;
    - **`json-ref`** follows a path, the last duplicate winning. Where it
      leads nowhere, it raises `not-found`, or gives the value after a
      closing `'default`, the owner's choice of form;
    - **`json=?`** checks both values as `put-json` would, then compares
      objects as unordered members, the last duplicate winning, and
      numbers by exact value. A `json-number` costs time linear in its
      text, however long its exponent;
    - **`json-null?`**, and re-exports of `&json-error`, the options and
      `json-number`.
  - **`(jsonparse writer)`:** `check-json`, the check `put-json` runs
    before writing, on its own, with its own who.
  - **Suites:**
    - `easy`: hand-written cases for every procedure, every error code
      through each reader, ports across chunk boundaries and re-entrant
      ports, every hashtable equivalence, numbers in every spelling,
      exponents past 10^19, and the arguments;
    - `easy-property`: the corpus through both layers under six option
      sets; character offsets under 3,000 mutations; `json=?` against an
      oracle of its own; alists against hashtables; round trips.
  - **Records:** ADR-0019, `docs/easy.md`, the global constraints, and
    notes in `docs/writer.md` and `docs/tree.md`.
- **Results:**
  - **Both layers return the same values:** on all 376 corpus files, under
    six option sets, through each reader, easy's value or error matches a
    builder's.
  - **Character offsets:** every one of 185,179 errors on valid UTF-8
    landed on a character's first byte or the end, so a character offset
    is the count of characters before the byte offset.
  - **Measurements** (ADR-0019):
    - `string->json` costs 9 to 28% more than reading bytes;
    - `json=?` takes 11 to 43% of reading on ADR-0018's documents, and up
      to 2.5 times on one object of 90,000 members held in hashtables;
    - `read-json` costs 21 KB per call, mostly its 16 KiB buffer.
- **Evidence:**
  - `scripts/guix-env make test` runs 27 suites in about 44 s. The new
    ones pass 1,460 and 57.
  - **Every assertion was watched fail.** The builders ran about 240
    mutants of the library and 14 of the property suite. Of the review's
    and the fixes' 22, and 9 of `json-ref`'s default, all now fail the
    hand-written suite.
  - **A reference in Python** that shares no code with the library agreed
    with `json=?` on 4,000 number pairs, 1,353 of them with exponents of
    20 digits or more.
- **Review:** an adversarial review found two defects:
  - `json=?` took time quadratic in a `json-number`'s exponent digits:
    6 s for 200,000 digits, which `text` mode reads in 1 ms. A server
    comparing untrusted values was open to denial of service;
  - `write-json` relabelled or lost a `&json-error` raised by the
    caller's own port.

  Its other findings:
  - nine mutants both suites survived: `check-json`'s who at three
    refusals, continuable raises, read errors without irritants, and `#f`
    members;
  - figures in ADR-0019 its own table contradicted;
  - claims about wrong arguments and irritants that overstated the code;
  - gaps in `docs/easy.md`.

  All are fixed, each fix watched fail:
  - an exponent past 19 digits is added to as text: 1 ms at 200,000
    digits;
  - `write-json` relabels only its check;
  - read errors carry empty irritants.
- **Known:**
  - **`json=?` can't see duplicate keys,** and needs the options the
    values were read with.
  - **`json=?` on hashtables pays for sorting each table's keys** in its
    check, as `put-json` does.
  - **A closed port** fails in the R6RS procedure that reads or writes
    it, not in easy's check.

### Slice 5: the writer (2026-11-06)

- **Landed:**
  - **`(jsonparse writer)`:** `put-json`, which writes a value as UTF-8 to
    a binary port (ADR-0018):
    - it writes what the builder builds, under any options: alists and
      hashtables, a hashtable's members in key order;
    - numbers follow ADR-0011, a fixnum's digits written directly;
    - a value is checked whole before a byte is written, so a refusal
      leaves the port as it was;
    - refusals raise `&json-error` with a reason: `unwritable-number`,
      `unwritable-key`, `unwritable-value` or `nesting-too-deep`.
  - **`(jsonparse error)`:** `&json-error`, an `&error` with a reason and
    an offset, below the easy layer.
  - **`(jsonparse options)`:** `indent`, from 0 (compact, the default) to
    10.
  - **A fix in `(jsonparse string)`:** Chez's `utf8->string` drops a
    leading U+FEFF, so a string or key starting with one, raw or escaped,
    read back without it. `json-assembler-string!` now keeps it
    (ADR-0016).
  - **Suites:**
    - `writer`: hand-written outputs for every kind of value, every
      control character, numbers at every digit boundary, hashtable order,
      layout, every refusal with nothing left on the port, the arguments
      and the `indent` option;
    - `writer-property`: round trips through the builder under seven
      option sets, ADR-0011's number property, the corpus as a fixed
      point, and layouts that change nothing;
    - `string` and `string-alloc` gain the U+FEFF cases.
  - **Records:** ADR-0018, a note in ADR-0016, and `docs/writer.md`.
- **Results:**
  - **Round trips:** 3,000 generated trees under each of seven option
    sets read back as expected, worked out from the tree alone. ADR-0011's
    property holds:
    - 12,000 exact numbers in `exact` mode;
    - 20,000 flonums in `flonum` mode, subnormals and `-0.0` included;
    - 12,000 `json-number` texts in `text` mode.
  - **The corpus is a fixed point:** every file the builder accepts reads,
    writes and reads back to the same tree, and writes the same bytes
    again, under four option sets.
  - **Chez's flonum printer** gives JSON for every finite flonum once its
    `|` suffix is cut. Every one reads back `eqv?`, over a million random
    bit patterns in the review's run.
  - **Measurements** (ADR-0018):
    - writing is 2 to 3 times faster than reading, but for flonums, at
      about 36 ms per MB;
    - the check pass costs 0.2 to 0.9 ms per MB.
- **Evidence:**
  - `scripts/guix-env make test` runs 25 suites in about 45 s. The new ones
    pass 568 and 27, and `string` and `string-alloc` now pass 207 and 27.
  - Every assertion was watched fail. The builders ran about 500 mutants,
    and the reviewer 106. Of the reviewer's, 97 failed a suite at once.
    Its findings added a test for one more. The other eight can't change
    the output.
- **Review:** an adversarial review found no wrong output. It found:
  - the global constraints saying both that the low layer never raises on
    bad input and that the writer raises;
  - a hashtable not keyed by `string=?` writing two keys with the same
    text in an order that changed from run to run;
  - `indent` unbounded, so one option could ask for 2^60 spaces;
  - `put-fixnum`'s buffer assuming 64-bit fixnums;
  - the round-trip claim missing the reader's range, as for a
    `json-number` `1e400`;
  - tests expecting `#f` from something that can raise;
  - a string-allocation claim made false by the U+FEFF fix, with a
    mutant changing only allocation;
  - a reason in ADR-0018 its own table contradicted, dates a day ahead,
    and a test header overstating its independence.

  All are fixed, each fix watched fail:
  - a table holding two keys with the same text is refused;
  - `indent` is capped at 10;
  - the buffer is sized from `(greatest-fixnum)`.
- **Known:**
  - **The writer doesn't apply the reader's digit limit or range.** A
    number past either is written, and a reader in `flonum` or `exact`
    mode refuses it. At a small digit limit, reading, writing and reading
    again may not be a fixed point (ADR-0018).
  - **A flonum's text comes from Chez's `number->string`,** in the writer
    and in the tests' expectations alike. Only the `eqv?` round trip
    checks it.
  - **A laid-out value grows with the square of its depth.**
  - **Chez's `utf8->string` drops a leading U+FEFF.** The assembler works
    around it; any new caller of `utf8->string` must too.

### Slice 4: the tree builder (2026-11-06)

- **Landed:**
  - **`(jsonparse tree)`:** the builder, one record holding a parser, an
    assembler and a stack of values (ADR-0017):
    - feed and finish return the parser's own results;
    - each container is built once, at its end, from the stack's slots,
      and each slot is cleared as its value moves into a container;
    - the value is ready once finish answers `finished`, and the builder
      keeps it until a reset;
    - an error drops what was built at once, and a reset resets the
      parser and the assembler too.
  - **`(jsonparse options)`:**
    - `object-mode`, `alist` or `hashtable`;
    - `null`, a symbol or a record that isn't a hashtable, default the
      symbol `null`.
  - **`(jsonparse-testing tree)`:**
    - `run-builder`;
    - `reference-run`, which folds `run-assembler`'s trace by recursive
      descent;
    - `canonical` and `as-hashtables`, for comparing hashtables and
      `json-number` records.
  - **Suites:**
    - `tree`: a differential against the reference, pinned values, the
      stack's growth points, depth to 65,535, stops, and chunking;
    - `tree-api`: the options, the lifecycle, independent builders,
      defaults, refusals, results and sub-ranges;
    - `tree-alloc`: what a parse allocates, the stack's growth, and what a
      builder keeps alive.
  - **Records:** ADR-0017 and `docs/tree.md`.
- **Results:**
  - **The builder builds what the reference does** on all 376 corpus
    files, under five sets of options:
    - whole, in chunks, under every split into two feeds of the files of
      at most 64 bytes, and random schedules for the rest;
    - 27,985 runs of 5,597 schedules, ending in values and in every
      error and stop.
  - **Containers at the stack's growth points:**
    - arrays and objects whose slot counts land on 64, 128 and 256, and
      one either side, at the top and nested;
    - nesting to 65,535 levels.
  - **Measurements** (ADR-0017):
    - a tree costs 1 to 10 ms per MB more than assembling its strings and
      numbers;
    - a reused builder allocates for an array of literals only its
      vector, plus a fixed amount, a fifth of a design that keeps members
      in lists.
- **Evidence:**
  - `scripts/guix-env make test` runs 23 suites in about 40 s. The new
    ones pass 150, 1,036 and 275.
  - Every assertion was watched fail. The builders ran about 150 mutants,
    and the reviewer 80. Of the reviewer's, 74 fail a suite. The other six
    are equivalent to the library: each changes something no later step
    reads.
- **Review:** an adversarial review found no wrong value. It found:
  - an option reset by a later `depth-limit` or `digit-limit` unseen,
    since the differential gives both sides the same options record;
  - keys that differ only in case never tested under hashtables, so a
    case-blind table passed;
  - a slot left uncleared by a container's close unseen, since the
    retention baseline was taken after the same document;
  - an error after a complete root, such as trailing garbage, never
    checked for memory held;
  - hashtable allocation bounded only from below, "doubling" not held by
    its bounds, and the initial 64 slots untested;
  - tests that expected `#f` from something that can raise, and helpers
    that swallowed any raise;
  - an opaque record of the caller's own refused as `null` without the doc
    saying so, and the other kinds Chez's `record?` accepts unrecorded.

  All are fixed, each watched fail. The resetting of the mark on an error
  was dead code, found by a builder's equivalent mutant, and is gone.
- **Known:**
  - **Under hashtables the last duplicate always wins.** M1 has no other
    rule (ADR-0017).
  - **`null` is a symbol or a non-opaque record,** a list of what is
    allowed. The owner kept it (2026-11-06), over refusing only what
    collides. Which values it accepts depends on the implementation's
    `record?`: Chez accepts conditions, enum-sets, record-type descriptors
    and time objects.
  - **The stack keeps its largest size** for the builder's life, like the
    assembler's buffer.
  - **The differential can't see a wrong options record,** since the
    builder and the reference read the same one. The `tree-api` suite's
    hand-written tables hold the options.

### Slice 3: the assembler (2026-10-30)

- **Landed:**
  - **`(jsonparse string)`:** the assembler, with one growable buffer
    reused for every key, string and number (ADR-0016):
    - a string's parts and escapes are joined as UTF-8 and decoded once, by
      `utf8->string`;
    - a number's digits are counted as its parts arrive, and nothing past
      the limit is kept;
    - numbers convert by mode at `number-end`, and `number-too-long` and
      `number-out-of-range` come back as stops;
    - the `json-number` record, checked against JSON's number grammar.
  - **`(jsonparse options)`:** `number-mode` (`flonum`, `exact` or `text`)
    and `digit-limit` (default 1,000).
  - **`(jsonparse-testing string)`:** `run-assembler`, which records each
    value the assembler builds through a parser.
  - **Suites:**
    - `string`: a differential against the reference's trace and against
      yajl's gold, plus pinned cases, the API, buffer growth and refusals;
    - `string-alloc`: no slope, a string's cost, growth, long numbers and
      retention;
    - `number`: an oracle built from the digits in all three modes,
      ADR-0011's pinned values, the limit's boundary in every position,
      `exact` mode's range, stops under every schedule, a grammar
      differential, and the options.
  - **Records:** ADR-0016, ADR-0011's worst case corrected, and
    `docs/string.md`.
- **Results:**
  - **Strings:** the assembled strings and keys equal the reference's on
    all 376 corpus files: whole, in chunks, under every split into two
    feeds of the 353 files of at most 64 bytes, and random schedules for
    the rest. They also equal yajl's own decoding, on all its cases but the
    five where slice 1 found our parser differs.
  - **Numbers:**
    - every number in the corpus, and seeded generated ones, equals the
      digits oracle in all three modes;
    - 1,000 digits are accepted and 1,001 refused, in every position;
    - a stop lands at the same offset under every schedule;
    - `make-json-number` accepts exactly what the parser accepts, over
      every string of up to 4 characters from `-+.eE019/:`.
  - **Measurements:**
    - joining and decoding once with `utf8->string` builds strings at
      300–900 MB/s, 2–4 times faster than decoding in Scheme;
    - at the default limit, numbers of 1,000 digits convert at 122 ms per
      MB as integers, and 354–389 ms as fractions.
- **Evidence:**
  - `scripts/guix-env make test` runs 20 suites in about 34 s. The new ones
    pass 203, 25 and 77.
  - Every assertion was watched fail. The builders ran about 140 mutants,
    and the reviewer 49 more.
- **Review:** an adversarial review found no wrong value. It found:
  - the doc's example broken by any document with a key;
  - an allocation assertion that failed for about 6% of heap phases, since
    a collection inside a measured region adds 656 bytes;
  - a 1-byte escape at a buffer growth point untested;
  - the assembler's default options untested;
  - two live assemblers never interleaved;
  - `/` and `:`, the bytes either side of the digits, untested in the
    grammar;
  - retention invisible to the allocation suite, and a start-size assertion
    that couldn't fail;
  - smaller gaps in wording.

  All are fixed, each watched fail. The allocation suites, `parser-alloc`
  too, now measure with collection off, and pass under 121 heap shifts.
  My own check then found a leak of each string's copied bytes that the
  first retention fix missed. A memory-in-use check now catches it.
- **Known:**
  - **ADR-0011's worst case was three times too low.** At the default
    limit, long fractions convert at 354–389 ms per MB, about 20 times a
    tree parse. The limit still bounds it, and the owner kept it at 1,000
    (2026-10-31).
  - **The buffer keeps its largest size** for the assembler's life.
  - **Some behaviour leans on Chez, where R6RS leaves it open:**
    `string->number`'s infinities, `-0.0` and rounding, and `utf8->string`'s
    U+FFFD (ADR-0016).
  - **No suite runs the docs' examples.** They were run by hand.
  - **The allocation suites allow for heap-position noise:**
    - `parser-alloc` counts a slope gap of 320 bytes or less as 0;
    - `string-alloc` allows 512 bytes plus 1% over its baseline.

### Slice 2: the push parser (2026-10-30)

- **Landed:**
  - **`(jsonparse options)`:** the options record. Its one option so far is
    `depth-limit`, from 0 to 65535, default 512. A bad option raises an
    R6RS assertion violation.
  - **`(jsonparse parser)`,** behind a handler of fourteen named procedures
    in YAJL's order (ADR-0015):
    - the stack is one byte per open container, sized from the limit;
    - escapes arrive as scalar values, surrogate pairs joined;
    - no text part is empty;
    - a stop ends the parse with its own code;
    - misuse raises jsonparse's own conditions, never byte-machine's.
  - **`(jsonparse-testing parser)`:** the recording handler, `run-parser`,
    and `machine->parser`, which turns the slice-1 reference's trace into
    the parser's terms.
  - **Suites:**
    - `parser`: the differential against the reference;
    - `parser-api`: the contract;
    - `parser-alloc`: allocation;
    - `parser-stack`: hand-pinned stack cases;
    - `parser-mutants`: runs `parser-stack` against 16 mutated copies of
      the parser and requires each to fail. They include ADR-0004's three:
      a wrong `context` answer, a skipped push and a skipped pop.
  - **Records:** ADR-0015 and `docs/parser.md`.
- **Results:**
  - **The parser records what the reference does** on every corpus file:
    - 381 inputs, under five depth limits;
    - about 244,000 runs: whole, in chunks, every split and every pair of
      splits up to 64 bytes, and random schedules;
    - 5,000 seeded mutants of the inputs.
  - **Allocation:** a feed plus a finish allocates the same at any size:
    928 bytes, 64 above byte-machine's own parser (two result records).
    That covers values, string bytes, number bytes and nesting.
- **Evidence:**
  - `scripts/guix-env make test` runs 17 suites in about 34 s. The new ones
    pass 86, 194, 29, 123 and 34.
  - Every assertion was watched fail. The builders ran about 100 mutants
    by hand.
- **Review:** an adversarial review found:
  - the stack checked only about 8 deep: a ring buffer of 8 entries passed
    every suite;
  - nothing checking that two parsers are independent;
  - a stop's offset moving with the chunking, under the digit-limit example
    ADR-0015 itself gave;
  - text parts that can end inside a UTF-8 character, which the contract
    denied;
  - the doc's escape examples written as raw characters;
  - an allocation ceiling a 400-byte leak per feed passed;
  - smaller gaps in tests and wording.

  All are fixed or recorded, each fix watched fail.
- **Known:**
  - **A stop from `chars` or `number-chars` lands where the feeds split
    the text.** A stop from an `-end` procedure doesn't, so slice 3's digit
    limit stops from `number-end`.
  - **Leaving out a container procedure saves less.** The stack's
    callbacks still run.
  - **`parser-mutants` adds about 10 s to `make test`.**
  - **`parser-api` and `parser-alloc` import `(byte-machine runtime)`,**
    to show byte-machine's values are ignored, and for the allocation
    baseline.

### Slice 1: the grammar and the generator (2026-10-30)

- **Landed:**
  - **The grammar:** `(jsonparse-grammar)` in `grammar/`, moved from the
    prototype. The machine is named `jsonparse`, and the depth limit is set
    per parser with a settable 16-bit field, `depth-left`, defaulting to 512
    (ADR-0005).
  - **The generated parser:** `make generate` (`grammar/emit.sps`) writes
    the committed `src/generated/jsonparse.sls`, and `test-generated` holds
    the two byte for byte.
  - **Corpora:** JSONTestSuite (MIT) and yajl's cases (ISC) in
    `tests/corpus/`, with `make check-corpora`, and git told to keep their
    bytes.
  - **Test libraries:**
    - `(jsonparse-testing machine)` runs either machine under any schedule
      and records whole traces. Its list stack is the reference for slice
      2's stack.
    - `(jsonparse-testing yajl)` reads yajl's gold files.
  - **Suites:**
    - `conformance`, with every `n_` and `i_` answer pinned in
      `tests/golden/jsontestsuite.txt`, which only `tests/write-golden.sps`
      writes;
    - `yajl`;
    - `machine`, the in-house cases;
    - `fuzz`;
    - `machine-driver`;
    - `generated`;
    - `check-corpora`.
- **Results:**
  - Every `y_` is accepted and every `n_` rejected. Of the `i_` files, 11
    are accepted (the number files and 500 nested arrays) and 24 rejected.
  - Of yajl's 45 plain cases, all match the gold but five divergences,
    listed with reasons (ADR-0012). Its four `am_` cases match with the
    `mode` bit.
  - The interpreter and the generated parser agree on whole traces
    everywhere they run.
- **Evidence:**
  - `scripts/guix-env make test` runs 12 suites in about 30 s. The new ones
    pass 9, 160, 367, 4, 50, 5 and 38.
  - Every assertion was watched fail, and every mutant the review found
    now fails a suite.
- **Review:** an adversarial review found:
  - the depth limit never reached after a close, so a close that reset it
    to 512 passed every gate;
  - five three-byte UTF-8 leads untested;
  - fuzz inputs rarely split, and fuzz never setting the depth limit or the
    `mode` bit;
  - a differential blind to fields and state;
  - yajl's option cases accepting an early rejection;
  - symlinks allowed in a corpus;
  - two records overstating the schedules.

  All are fixed, each watched fail.
- **Known:**
  - **A truncated UTF-8 sequence is reported as `unexpected-eof`,** and so
    are a dangling `\` or `\u` and a lone high surrogate at the end of
    input.
  - **Fuzz compares the driver with itself.** A bug in the driver's stack
    is caught only by `machine-driver`'s hand-written traces.
  - **The suites reach into byte-machine:**
    - `machine` imports `(byte-machine private conditions)` to name a
      refused field;
    - the schedules come from byte-machine's test harness.

    A byte-machine bump can move either.

### Slice 0: scaffolding (2026-10-30)

- **Landed:**
  - **The pinned Guix container:** `channels.scm`, `manifest.scm`,
    `scripts/guix-env*` and `make check-guix` (ADR-0008).
  - **The Makefile:** `help`, `check-help`, `check-chez` (the 10.4.1
    floor), `submodules`, `check-pins` (gitlinks and the `v0.8.0` tag),
    `deps`, `test`, `check-suites`, `check-imports` and `check-versions`.
  - **Dependencies:** `vendor/byte-machine` at `v0.8.0` and `vendor/chez-srfi`
    at `7879b52`.
  - **Akku:** `Akku.manifest` (`^0.8.0`), `Akku.lock`, `.akkuignore` and
    `.gitattributes` (ADR-0002, ADR-0003).
  - **Test libraries:** `(jsonparse-testing)` and
    `(jsonparse-testing property)` (ADR-0012).
  - **CI:** on `ubuntu-24.04` and `ubuntu-24.04-arm`, with architecture
    checks (ADR-0009).
- **Evidence:**
  - `scripts/guix-env make test` runs 5 suites: 38, 16, 29, 45 and 52
    passes.
  - `make check-guix` passes, including 88 launcher cases.
  - The builders watched every rule fail: 87 mutants, then the reviewer's.
    One survivor is left: dropping `make-capture-directory`'s mutex, which
    `mkdir`'s own refusal makes harmless.
- **Review:** an adversarial review found:
  - checks that couldn't fail: `make test`'s verdict, `check-help`, the
    generators' edges, a bare `(exit)`;
  - a false packaging claim in ADR-0003;
  - a silent run below the Chez floor.

  All are fixed, each with a case watched fail.
- **Known:** `make check-pins` reads gitlinks from HEAD, so a staged bump
  fails it until committed. Nothing checks the `.gitattributes`
  export-ignore yet; plan M5's `check-akku` will.
