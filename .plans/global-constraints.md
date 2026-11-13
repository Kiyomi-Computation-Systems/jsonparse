# Global constraints

These rules bind every task brief. Each one cites the decision record in
[decisions/](decisions/) it comes from, or AGENTS.md. If a rule here and its
record disagree, the record wins and this file gets fixed.

## Platforms and versions

- **Platforms:** Linux and macOS, on amd64 and arm64. No Windows code paths or
  CI (AGENTS.md).
- **Chez:** 10.4.1 or later (ADR-0008).
- **CI:** Linux amd64 and arm64 (`ubuntu-24.04` and `ubuntu-24.04-arm`).
  Each job that runs Chez checks `uname -m` and Chez's machine type. Never a
  macOS runner: macOS is covered by `make test` on the owner's M1 laptop
  (ADR-0009, ADR-0021, AGENTS.md).

## Portability

- **Every library under `src/` starts with `#!r6rs`.** It imports only
  `(rnrs …)` but `(rnrs eval)`, `(jsonparse …)`, `(generated jsonparse)` and
  `(byte-machine runtime)`, and `tests/check-imports.sps` holds that
  (ADR-0003).
- **Tooling may use Chez freely.** Guile and Racket are checked by hand
  (ADR-0003).
- **The grammar and the generator live in `grammar/`,** outside `src/`: they
  import byte-machine's graph and compiler (ADR-0003). The grammar is
  `(jsonparse-grammar)`, a name outside `(jsonparse …)`, so no `src/`
  library can import it.

## Names and the dependency

- **Names:** the repository and package are `jsonparse`, every library is
  `(jsonparse …)`, and the generated parser is `(generated jsonparse)`
  (ADR-0001).
- **The generated parser is committed,** and a check regenerates it and
  compares the two byte for byte (ADR-0001). `make generate` is the only
  thing that writes it, `#!r6rs` line included.
- **byte-machine:**
  - `Akku.manifest` declares `^0.9.0` (ADR-0026).
  - `vendor/byte-machine` is a submodule pinned at a release tag, and the
    Akku floor equals it.
  - The gitlink, the floor and `Akku.lock` move together (ADR-0002).
- **A change that needs a new byte-machine ABI** ships with the sibling
  consumers' regenerated parsers (ADR-0002).
- **byte-machine's ABI stays 9 for now** (ADR-0028). The owner chose on
  2026-11-12 not to change it. Work that needs ABI 10 waits as issues:
  byte-machine #184 and #185.
- **A byte-machine release that changes only the emitted text,** with the
  ABI the same, is taken by moving the gitlink, tag, floor and lock together
  and regenerating. Every other consumer keeps working without regenerating.
  But Akku reads `^0.y.z` as `<0.(y+1).0`, so consumers share an application
  only on one minor. A jsonparse release to Akku waits until the siblings
  admit the same minor (ADR-0026).
- **chez-srfi**, for SRFI-64 in tests only, is pinned at a commit, since
  upstream has no tags (ADR-0012).
- **Only `src/`'s libraries reach a consumer's library path.** `.akkuignore`
  lists the rest, `.gitattributes` keeps `.plans` and `AGENTS.md` out of the
  archive, and `make check-akku` installs the package as a consumer would
  (ADR-0003, ADR-0022, ADR-0023).

## Layers

- **The low layer** is `(jsonparse parser)`, `(jsonparse string)`,
  `(jsonparse tree)`, `(jsonparse writer)`, `(jsonparse sequence)` and their
  supporting libraries. It takes bytes, counts offsets in bytes, and never
  raises on bad input (ADR-0010, ADR-0014). The writer takes values, not
  bytes: it raises `&json-error` on a value that JSON can't express
  (ADR-0018).
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
- **A handler is fourteen named procedures, all optional** (ADR-0015):
  - `escape` receives a scalar value, a surrogate pair joined;
  - no text part is empty;
  - a return value is ignored unless it is a stop, which ends the parse
    with its code.
- **Options are one record,** checked when it is made. A bad one raises an
  R6RS assertion violation (ADR-0015). So does `blank-lines` under a
  `stream` other than `lines` (ADR-0020).
- **A parser reads one value, unless `stream` is `values`.** Then it reads
  any number, none included, and a top-level number or literal needs
  whitespace or the end of the input after it, else `unexpected-byte`
  (ADR-0014, ADR-0020).

## The assembler

- **One assembler per parser,** with one growable buffer reused for every
  key, string and number (ADR-0010, ADR-0016).
- **A string's parts are decoded once, after they are joined** (ADR-0015,
  ADR-0016).
- **The digit limit and the range checks stop from `number-end`:**
  `number-too-long`, and `number-out-of-range` for a flonum too large or an
  `exact` value past the limit (ADR-0011, ADR-0015, ADR-0016).
- **A number's text is checked against JSON's grammar before it converts,**
  or as the fast path reads it. A `json-number` record keeps a copy of its
  text and gives out copies (ADR-0016, ADR-0027).
- **A short number converts from the buffer, after the digit-limit check:**
  an integer of at most 18 digits in `flonum` and `exact` modes, and in
  `flonum` mode a decimal of at most 18 digits whose m × 10^e has e within
  ±22. The cap comes from `(greatest-fixnum)`. Every other number takes the
  general path. Every text reads as it would there, digits given by
  `json-assembler-chars!` included (ADR-0027).
- **Taking a value empties the assembler.** A parser reset doesn't reach
  it (ADR-0015, ADR-0016).

## The tree builder

- **One builder holds one parser, one assembler and one stack,** made from
  one options record. Its feed and finish return the parser's results
  (ADR-0017).
- **Each container is built once, at its end,** from the stack's slots, and
  a slot is cleared as its value moves into a container (ADR-0017).
- **The value is ready once finish answers `finished`,** and the builder
  keeps it until a reset. An error drops what was built at once, and a
  reset resets the parser and the assembler too (ADR-0015, ADR-0017).
- **A builder given EACH hands it every top-level value once complete,**
  and keeps none. `stream values` needs EACH (ADR-0020).

## Values

- **Objects** are alists in document order by default. The hashtable option
  keys by string, and the last duplicate wins (ADR-0006). M1 has no other
  rule for duplicates (ADR-0017).
- **Other values:** arrays are vectors, keys and strings are strings, `true`
  and `false` are `#t` and `#f` (ADR-0006).
- **`null`** is the symbol `null` by default, and configurable. A value that
  collides with another representation is refused (ADR-0006): `null` is a
  symbol, or a record that is not a hashtable. `record?` decides what is a
  record, so an opaque one is refused (ADR-0017).
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

## The writer

- **`put-json` writes UTF-8 to a binary port,** and takes alists and
  hashtables under any options. It reads `null`, `depth-limit` and `indent`
  only (ADR-0018).
- **A value is checked whole before a byte is written.** A refusal raises a
  `&json-error` whose offset is `#f`, and leaves the port as it was
  (ADR-0018).
- **The same value always gives the same bytes:** a hashtable's members go
  in key order, and a table holding two keys with the same text is refused
  (ADR-0018).
- **`&json-error` is an `&error` with a reason and an offset,** defined in
  `(jsonparse error)` below the easy layer (ADR-0010, ADR-0018).
- **`check-json` is the check `put-json` runs before writing,** on its own
  (ADR-0019).
- **`put-json-record` writes one record of the options' `stream`,** the
  value checked whole first. A `lines` record needs `indent` 0 (ADR-0020).

## The easy layer

- **`string->json`, `bytevector->json` and `read-json` take one whole
  document, with a new builder each call;** the stream readers, a new
  reader each call (ADR-0020). Bad input raises `&json-error`, its reason the parser's code. Its offset
  counts the characters before the byte offset for a string, and bytes for
  a bytevector or a port (ADR-0010, ADR-0019).
- **`read-json` reads 16 KiB at a time,** so on a port whose bytes are
  still coming, a refusal waits for the 16 KiB that hold the error or the
  port's end. What the port raises passes through it as it was raised
  (ADR-0019).
- **Writing is `put-json`'s.** A refusal is raised again with the easy
  procedure as its who. What a caller's port raises passes through as it
  was raised (ADR-0019).
- **`json=?` checks both values as `put-json` would,** then compares objects
  as unordered members, the last duplicate winning, and numbers by exact
  value, in time linear in a `json-number`'s text. `json-ref` lets the last
  duplicate win too. Its `'default` replaces `not-found` only (ADR-0019).
- **Every `&json-error` this layer raises has a who, a message and
  irritants,** and is raised non-continuable (ADR-0019).
- **A bad record in a stream raises a `&json-record-error`,** a
  `&json-error` with the record's number. Given a REPORT procedure, a
  reader skips bad records and gives REPORT each error instead. The
  one-document readers refuse `stream values` (ADR-0020).
- **Never decode bytes that may start with U+FEFF with `utf8->string`:**
  Chez drops the mark (ADR-0016).

## Streams of values

- **Records are framed by byte:** `\n` for `lines` and RS for `seq`. A
  record split across chunks is never copied into one buffer (ADR-0014).
- **`lines` by default:** a bad record or a blank line is an error, with a
  record number and a byte offset (ADR-0014). Offsets count from the
  stream's start, and records from 1 (ADR-0020).
- **Giving the reporting procedure turns skipping on,** and every bad
  record skipped goes to it. A blank line under `'blank-lines 'skip` isn't
  bad, and goes to no procedure. `seq` needs one, and `values` refuses one. `seq` drops
  a possibly cut-off top-level number or literal as `truncated` (ADR-0014,
  ADR-0020).
- **Each `lines` or `seq` record is a new parse by one reused builder,** so
  the depth and digit limits apply to each record (ADR-0014, ADR-0020).
- **A reader keeps its largest string buffer across resets** (ADR-0016,
  ADR-0020). Re-entering a continuation captured inside its procedures is
  unsupported (ADR-0020).
- **A reader's procedures run as a handler's do:** a raise passes out of the
  feed, and the reader raises until it is reset. Feeding, finishing or
  resetting it from inside them raises (ADR-0015, ADR-0020).
- **Records written as `lines` are compact** (ADR-0014).

## Tests and benchmarks

- **Every vendored corpus sits in `tests/corpus/<name>/`** with its upstream
  license and a `SOURCE` file, and `make check-corpora` holds that
  (ADR-0012). Git keeps corpus bytes exactly as upstream has them
  (`.gitattributes`).
- **Never vendor:**
  - JSON_checker files, in any copy (the JSON license);
  - data without a license (ADR-0012).
- **Every corpus file of JSON text of at most 4 KB seeds the fuzzer,** and
  is read in chunks of 1 to 31 bytes. A table of numbers, such as
  parse-number-fxx's, isn't JSON text: its numbers are fed whole and a byte
  at a time (ADR-0012).
- **The float64 lane checks flonums against their bits,** from the files
  and from our own hard cases, not against the Scheme reader or `inexact`,
  which the library converts with. A suite whose flonum expectations come
  from Chez says so in its header (ADR-0011, ADR-0012, ADR-0027).
- **Every name a `(jsonparse ...)` library exports has one entry in
  `docs/reference.md`,** naming the libraries that export it, and is named
  in a guide, which the reference, the home page and `installing.md` are
  not. Nothing else has an entry. `tests/test-docs.sps` holds that (ADR-0012,
  ADR-0021).
- **`make test` needs no network and no comparator.** Benchmark files are
  fetched on the host, checked by SHA-256, and never committed (ADR-0012,
  ADR-0013).
- **`make bench` measures M3 on the owner's Linux NUC (amd64),** jsonparse
  against yajl, with every harness pinned to one performance core. It
  times exactly the files `bench/files.lock` names: five fetched on the
  host, and M0's three written by `bench/synthetic.sps`. Every file's
  sha256 is checked, in the directory timed, before anything is timed
  (ADR-0023).
- **M3's targets hold on the `events` lane,** which counts every value by
  kind, and compare medians (ADR-0013, ADR-0023).
- **The report is written only when the harnesses cross-check:** yajl's and
  jsonparse's events counts agree, the walk's and the scan's agree with
  them, and every lane's timed passes are as many as the method says and
  counted what one pass counts, times the passes (ADR-0023).
- **ADR-0024's eleven comparators run beside them,** each runtime in a
  harness of its own that keeps ADR-0023's method and output. `BENCH_PARSERS` names
  the ones to run; jsonparse and yajl always run. Each is used as its
  documentation tells a caller to, at its defaults, and its runtime form
  says how (ADR-0024).
- **Only a lane that cross-checks gets a rate.** A comparator's lane that
  rejects a file, or whose counts disagree with jsonparse's `events`, reads
  "fails" or "disagrees", and the report says why. A `tree` or `parse` lane,
  which counts nothing, follows its `tree+walk` or `events`. Anything else
  wrong stops the report, as does any failure or disagreement of
  jsonparse's or yajl's (ADR-0024).
- **A slow comparator reads smaller rounds,** by a divisor the Makefile gives
  it. The plan names every parser's round bytes, and the report holds each
  harness to it. jsonparse and yajl always read the method's (ADR-0024).
- **A lane too slow to time gets no rate.** The Chez peers' harness times no
  lane whose first pass takes over 10 s, the method's limit, which the
  report holds it to. It reads "too slow", its counts are still
  cross-checked, and the report gives that pass's time and rate. A target's
  lane too slow to time stops the report (ADR-0024).
- **`make bench-callbacks` splits the callback path's cost a value** between
  byte-machine, the handler's own work and jsonparse, with lanes of
  `(jsonparse-bench callbacks)` taking turns, by ADR-0023's method on the
  same files. A split is the median of the turns' paired differences, with
  their middle half. It writes its report only when `m-count` counts what
  the events lane counts, and every lane's tally holds (ADR-0025).
- **jsonparse is timed on compiled objects** (ADR-0023, jsonparse #22).
  - `scripts/bench-chez` compiles a bench program's libraries in a Chez
    process of their own, then times the program in one that only loads
    them. Both `make bench` and `make bench-callbacks` run through it.
  - Both processes start with the same options. So the timed process keeps
    `--compile-imported-libraries`, and a library it still compiled is
    named on its stdout. That stdout must be empty, or the run fails.
  - `tests/test-bench-chez.sps` holds the script and both recipes in `make
    test`.
  - A timing outside these targets follows the same method: compile
    first, then check stdout or the objects' times (ADR-0023).
- **Comparators not in Guix are fetched on the host,** pinned by sha256 in
  `bench/comparators.lock`, never committed, and on a Guix host run only in
  the container (ADR-0024).
- **The benchmark harness lives in `bench/`, as `(jsonparse-bench …)`,**
  outside `(jsonparse …)`. `.akkuignore` keeps it out of the package, and
  `make check-akku` holds that. `tests/test-bench.sps` tests it in
  `make test`, and `make check-bench-files` tests the fetch script in CI
  (ADR-0023).

## The docs site

- **`make site` renders `docs/` with the generator under `site/`,** copied
  from circuit. `docs/README.md` is the home page, and its "Read next" list
  is the nav. `make check-site` holds the nav, every link and anchor, and
  that list (ADR-0021).
- **chez-cmark-gfm is a development dependency** in `Akku.lock`, fetched on
  the host by `make site-deps`. Nothing under `src/` and no
  `tests/test-*.sps` imports it (ADR-0021).
- **Pages deploys from `pages.yml` on a `v*` tag, or by hand from `main`.**
  The `github-pages` environment takes `main` and `v*` tags only (ADR-0021).

## Releases

- **The version follows semantic versioning.** Before 1.0 any release may
  change the API, and a new minor version comes with a new byte-machine
  runtime ABI or a move to a new byte-machine 0.x, such as from `^0.8.0` to
  `^0.9.0`. `Akku.manifest`, `CHANGELOG.md`'s newest release and the home
  page's Status name one version, and `make check-release` holds that
  (ADR-0022).
- **Akku is 1.2.0,** pinned by sha256 in `scripts/akku-tool.lock` and run by
  `scripts/akku` (ADR-0022).
- **A release to Akku is published with `scripts/akku-publish`,** from a
  fresh clone at the tag, signed with the Kiyomi Computation Systems release
  key, and checked (ADR-0022).

## Environment

- **On a Guix host, build and test through `scripts/guix-env`.** It has no
  network but loopback and no git; fetching runs on the host (ADR-0008).
- **`scripts/guix-env --bench` adds `bench/manifest.scm`'s tools:** yajl,
  gcc 14, pkg-config, taskset, and every comparator Guix packages, with its
  runtime. Only `make bench` and `make bench-callbacks` use it, and `make
  check-guix` asserts each tool, by version where it states one (ADR-0013,
  ADR-0023, ADR-0024, ADR-0025).
- **A recipe that starts another make names it `$(SUBMAKE)`, never
  `$(MAKE)`:** make runs a line naming `$(MAKE)` even under `-n`.
  `tests/guix-env-launcher.sh` holds that for `bench` and `check-akku`.
