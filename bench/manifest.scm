;;; The benchmarks' tools (ADR-0013, ADR-0023): yajl; a C compiler and
;;; pkg-config to build its harness, bench/yajl-bench.c; and util-linux's
;;; taskset, which pins both harnesses to one core. `scripts/guix-env
;;; --bench` adds them to manifest.scm's toolchain, `make bench` enters the
;;; container that way, and `make check-guix` asserts each one
;;; (check-bench-env-inside). Only `make bench` needs them: `make test` and
;;; CI never do.
;;;
;;; gcc 14 is the pin's default compiler, which the substitute servers
;;; build; the report names the version.
(specifications->manifest
 '("yajl" "gcc-toolchain@14" "pkg-config" "util-linux"))
