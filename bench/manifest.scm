;;; The benchmarks' tools (ADR-0013, ADR-0023, ADR-0024): yajl; a C and C++
;;; compiler and pkg-config to build the native harnesses; util-linux's
;;; taskset, which pins every harness to one core; and the comparators, each
;;; with the runtime it runs on. `scripts/guix-env --bench` adds them to
;;; manifest.scm's toolchain, `make bench` enters the container that way,
;;; and `make check-guix` asserts each one (check-bench-env-inside). Only
;;; `make bench` needs them: `make test` and CI never do.
;;;
;;; gcc 14 is the pin's default compiler, which the substitute servers
;;; build; the report names the version. SRFI 180's reference
;;; implementation, chez-json and Jackson aren't here: they are fetched on
;;; the host, pinned by bench/comparators.lock.
(specifications->manifest
 '("yajl" "gcc-toolchain@14" "pkg-config" "util-linux"
   "rapidjson" "simdjson" "yyjson"
   "openjdk@25:jdk"
   "racket-minimal"
   "guile" "guile-json"
   "gambit-c" "gerbil"
   "chibi-scheme"))
