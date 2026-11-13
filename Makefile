# jsonparse
#
# On a Guix host, run targets through the container:
#   scripts/guix-env make <target>
#
# Two dependencies, each pinned by gitlink under vendor/: byte-machine, the
# runtime the generated parser imports, at a release tag; and chez-srfi, for
# SRFI-64 in the tests, which has no upstream tags, at the commit
# chez-http-server pins. `make submodules` clones them; `make check-pins`
# holds them where the pins say. Both need git and the network, so they run
# on the host: the container has neither. `make deps` links SRFI-64 and
# never fetches.

# The Chez binary. In the container, scripts/guix-env-enter exports the
# profile's real `scheme` binary. Elsewhere it is `scheme` on PATH, or else
# `chez`, the name Homebrew installs it under on macOS.
CHEZ ?= $(or $(if $(shell command -v scheme 2>/dev/null),scheme),$(if $(shell command -v chez 2>/dev/null),chez),scheme)
export CHEZ

# The make target to name in a missing-tool hint (scripts/require-tools):
# what the user typed, $(MAKECMDGOALS), or, when that is empty, the
# recipe's own target, $@. Recursively expanded (=, not :=), so each
# reference picks up whichever recipe is running it.
GOAL = $(strip $(if $(MAKECMDGOALS),$(MAKECMDGOALS),$@))

# A recipe that starts another make names it $(SUBMAKE). make runs any recipe
# line naming $(MAKE) itself even under -n, so `make -n check-akku` or
# `make -n bench` would install a package or run the benchmarks.
SUBMAKE = $(MAKE)

# --- the pins ----------------------------------------------------------------
BYTE_MACHINE_DIR := vendor/byte-machine
BYTE_MACHINE_PIN := fdd4da0b4d150fac80251b012120d760e4b5016a
BYTE_MACHINE_TAG := v0.9.0
SRFI_DIR := vendor/chez-srfi
SRFI_PIN := 7879b527f267f067416552fb989135ad1b4ea436  # the pin chez-http-server uses

# --- the library paths --------------------------------------------------------
# LIBDIRS is the path `make run` and `make dev` use: jsonparse's src/, then
# byte-machine's runtime. build/scheme-libs carries (srfi :64).
#
# TEST_LIBDIRS is the suites' path: LIBDIRS; tests/, which holds
# (jsonparse-testing); grammar/, which holds (jsonparse-grammar) for the
# regeneration check and the interpreter; byte-machine's test harness, for
# its feed schedules (ADR-0012); and bench/, which holds the benchmarks'
# (jsonparse-bench) for tests/test-bench.sps (ADR-0023). Test code, the
# grammar and the benchmarks stay off LIBDIRS.
BUILD_DIR := build
SRFI_LIBS := $(BUILD_DIR)/scheme-libs
LIBDIRS := src:$(BYTE_MACHINE_DIR)/src:$(SRFI_LIBS)
TEST_LIBDIRS := $(LIBDIRS):tests:grammar:$(BYTE_MACHINE_DIR)/test/support/harness:bench

# The generated parser and the program that writes it (ADR-0001).
GENERATED := src/generated/jsonparse.sls

# Every suite, in one order everywhere: make 3.82 to 4.2 leave $(wildcard)
# unsorted.
SUITES := $(sort $(wildcard tests/test-*.sps))

# Seconds a suite may run before timeout kills it and make test names it
# HUNG.
TEST_TIMEOUT ?= 300

# GNU timeout. Homebrew's coreutils installs it as gtimeout on macOS.
TIMEOUT ?= $(or $(shell command -v timeout 2>/dev/null),$(shell command -v gtimeout 2>/dev/null),timeout)

# One physical line: check-help reads it with awk, and fails if it ends in
# a backslash.
.PHONY: help check-help check-guix check-guix-inside submodules check-pins check-chez deps dev run generate test check-suites check-imports check-versions check-release check-corpora site-deps site check-site check-site-deps akku-deps check-akku check-akku-inside bench-files check-bench-files bench bench-inside bench-callbacks bench-callbacks-inside check-bench-env-inside clean

.DEFAULT_GOAL := help

# The name column is as wide as the longest target's name.
help: ## Show this help message
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z0-9_.-]+:.*?## / \
	  { n++; name[n] = $$1; text[n] = $$2; if (length($$1) > width) width = length($$1) } \
	  END { format = "  \033[36m%-" width "s\033[0m %s\n"; \
	        for (i = 1; i <= n; i++) printf format, name[i], text[i] }' $(MAKEFILE_LIST)

# Reads what `make help` prints, colour codes stripped, so it checks the
# listing itself. Both directions: every .PHONY target is listed, and every
# listed target is in .PHONY. A listed target left out of .PHONY silently
# stops running once a file of its name exists.
check-help: ## Fail unless `make help` lists exactly the .PHONY targets
	@status=0; \
	if grep -qE '^\.PHONY:.*\\$$' Makefile; then \
	  echo "check-help: the .PHONY line ends in a backslash; keep it on one line" >&2; \
	  status=1; \
	fi; \
	help=$$($(MAKE) --no-print-directory help) || { \
	  echo "check-help: make help failed" >&2; \
	  exit 1; \
	}; \
	esc=$$(printf '\033'); \
	listed=$$(printf '%s\n' "$$help" | sed "s/$$esc\[[0-9;]*m//g" | awk '{ print $$1 }'); \
	phony=$$(awk '/^\.PHONY:/ { $$1 = ""; print }' Makefile); \
	for t in $$phony; do \
	  printf '%s\n' $$listed | grep -qxF "$$t" || { \
	    echo "check-help: make help does not list .PHONY target '$$t'; give it a '## ' description on its target line" >&2; \
	    status=1; \
	  }; \
	done; \
	for t in $$listed; do \
	  printf '%s\n' $$phony | grep -qxF "$$t" || { \
	    echo "check-help: make help lists '$$t', which is not in .PHONY" >&2; \
	    status=1; \
	  }; \
	done; \
	exit $$status

check-guix: ## Test scripts/guix-env on the host, then the toolchain inside the container and the benchmarks' one
	@scripts/require-tools "$(GOAL)" guix
	@sh tests/guix-env-launcher.sh
	@scripts/guix-env make check-guix-inside
	@scripts/guix-env --bench make --no-print-directory check-bench-env-inside

check-guix-inside: ## (inside the container) Assert the pinned toolchain, isolation and loopback-only network
	@CHEZ='$(CHEZ)' sh scripts/guix-env-selftest

submodules: ## (host) Clone the pinned byte-machine and chez-srfi
	@scripts/require-tools "$(GOAL)" git
	git submodule update --init $(BYTE_MACHINE_DIR) $(SRFI_DIR)

# Each checkout is asked for its own .git first: in a submodule that was
# never cloned, `git -C` would climb to the repository around it and answer
# that one's commit. Read-only. The gitlink is read from HEAD's tree, not the
# index, so a staged bump can't pass. byte-machine's checkout must also carry
# BYTE_MACHINE_TAG (ADR-0002: pinned at a release tag). Git only: make test
# runs check-versions.
check-pins: ## (host) Fail unless byte-machine and chez-srfi sit at their pins and byte-machine carries its release tag
	@scripts/require-tools "$(GOAL)" git
	@fail=0; \
	check_pin() { \
	  got=; [ -e "$$1/.git" ] && got=$$(git -C "$$1" rev-parse HEAD 2>/dev/null); \
	  if [ "$$got" != "$$2" ]; then \
	    echo "PIN MISMATCH: $$1 at $${got:-<absent>}, expected $$2" >&2; fail=1; \
	  else echo "pin ok: $$1 $$2"; fi; }; \
	gitlink() { \
	  rec=$$(git ls-tree HEAD -- "$$1" | awk '$$1 == "160000" { print $$3 }'); \
	  if [ "$$rec" != "$$3" ]; then \
	    echo "PIN MISMATCH: HEAD records $$1 at $${rec:-<none>}, $$2 says $$3" >&2; fail=1; \
	  fi; }; \
	gitlink $(BYTE_MACHINE_DIR) BYTE_MACHINE_PIN $(strip $(BYTE_MACHINE_PIN)); \
	check_pin $(BYTE_MACHINE_DIR) $(strip $(BYTE_MACHINE_PIN)); \
	if [ -e "$(BYTE_MACHINE_DIR)/.git" ] && git -C $(BYTE_MACHINE_DIR) tag --points-at HEAD | grep -qxF "$(strip $(BYTE_MACHINE_TAG))"; then \
	  echo "tag ok: $(BYTE_MACHINE_DIR) carries $(strip $(BYTE_MACHINE_TAG))"; \
	else \
	  echo "TAG MISSING: $(BYTE_MACHINE_DIR) at HEAD carries no tag $(strip $(BYTE_MACHINE_TAG))" >&2; fail=1; \
	fi; \
	gitlink $(SRFI_DIR) SRFI_PIN $(strip $(SRFI_PIN)); \
	check_pin $(SRFI_DIR) $(strip $(SRFI_PIN)); \
	exit $$fail

# Never fetches: the container has no network, so an empty submodule is
# filled on the host. chez-srfi ships Akku's percent-encoded filenames
# (%3a64.sls) and Chez resolves (srfi :64) only from the decoded spelling
# (:64.sls), so every entry is linked under both and the submodule's own
# tree is left alone. `ln -sfn` replaces a link in place, and the -n is what
# stops it following an existing link to a directory into the submodule. deps runs it.
define link-srfi
	@mkdir -p $(SRFI_LIBS)/srfi
	@set -e; \
	src="$(abspath $(SRFI_DIR))"; dst="$(abspath $(SRFI_LIBS))/srfi"; \
	for f in "$$src"/*; do \
	  b=$$(basename "$$f"); \
	  ln -sfn "$$f" "$$dst/$$b"; \
	  d=$$(printf '%s' "$$b" | sed 's/%3a/:/g'); \
	  [ "$$d" = "$$b" ] || ln -sfn "$$f" "$$dst/$$d"; \
	done
endef

# Fails unless $(CHEZ) prints a version of at least the floor, 10.4.1
# (ADR-0008). On a Guix host the bare `scheme` can be older, and MIT Scheme
# also installs one; the container's CHEZ is right.
CHEZ_FLOOR := 10.4.1
check-chez: ## Fail unless the Chez binary is Chez Scheme 10.4.1 or later
	@scripts/require-tools "$(GOAL)" $(CHEZ)
	@raw=$$($(CHEZ) --version 2>&1 </dev/null | head -n 1); \
	ver=$$(printf '%s\n' "$$raw" | grep -xE '[0-9]+\.[0-9]+(\.[0-9]+)?' || true); \
	if [ -n "$$ver" ] && [ "$$(printf '%s\n%s\n' "$$ver" "$(CHEZ_FLOOR)" | sort -V | head -n 1)" = "$(CHEZ_FLOOR)" ]; then \
	  echo "check-chez: $(CHEZ) is Chez $$ver"; \
	else \
	  echo "check-chez: '$(CHEZ)' printed '$$raw' for --version, not Chez $(CHEZ_FLOOR) or later." >&2; \
	  echo "check-chez: on Guix use scripts/guix-env make $(GOAL); with Homebrew use CHEZ=chez." >&2; \
	  exit 1; \
	fi

deps: ## Link SRFI-64 into build/scheme-libs; never fetches
	@scripts/require-tools "$(GOAL)" $(CHEZ)
	@for f in $(BYTE_MACHINE_DIR)/src $(SRFI_DIR)/%3a64.sls; do \
	  if [ ! -e "$$f" ]; then \
	    echo "deps: $$f not found, so a submodule is empty or missing. Run 'make submodules' on the host: make deps never fetches, and the container has no network." >&2; \
	    exit 1; \
	  fi; \
	done
	$(link-srfi)
	@echo "deps: $(SRFI_DIR) linked into $(SRFI_LIBS)/srfi"

dev: deps ## Start a REPL with jsonparse and byte-machine on the library path
	$(CHEZ) --libdirs $(LIBDIRS)

run: deps ## Run a program on the library path: make run PROGRAM=examples/hello.sps
	@test -n "$(PROGRAM)" || { echo "run: set PROGRAM=path/to/program.sps" >&2; exit 2; }
	$(CHEZ) --libdirs $(LIBDIRS) --program $(PROGRAM)

# The only way $(GENERATED) is written. It needs byte-machine's compiler, not
# just its runtime, so the path is grammar/ and byte-machine's src/.
# tests/test-generated.sps renders the machine again and fails unless the
# committed file matches it byte for byte.
generate: ## Regenerate src/generated/jsonparse.sls from grammar/
	@scripts/require-tools "$(GOAL)" $(CHEZ)
	@mkdir -p $(dir $(GENERATED))
	$(CHEZ) --libdirs grammar:$(BYTE_MACHINE_DIR)/src --program grammar/emit.sps $(GENERATED)

# Runs each suite as its own process under GNU timeout and reports its exit
# status, or HUNG when timeout killed it (exit 124). It fails if any suite
# failed or hung, or if none matched. At a terminal, --foreground keeps a
# suite in make's process group, so Ctrl-C reaches it at once; but then
# timeout kills the suite alone, and a child it started (curl, a server)
# lives on, holding its port. Anywhere else, CI and pipes included, timeout
# kills the suite's whole process group. The checks come first:
# check-help, check-suites and, once src/ exists, check-imports each stop
# it, so the first library under src/ is audited without anyone
# remembering to.
test: deps check-help check-chez check-suites check-versions check-release check-corpora $(if $(wildcard src),check-imports) ## Run every tests/test-*.sps under timeout; fail if one fails or hangs, or none exists
	@scripts/require-tools "$(GOAL)" $(TIMEOUT) $(CHEZ)
	@if [ -z "$(SUITES)" ]; then \
	  echo "test: no suites: nothing matches tests/test-*.sps" >&2; \
	  exit 1; \
	fi; \
	passed=0; failed=0; hung=0; fg=; \
	if [ -t 0 ]; then fg=--foreground; fi; \
	for t in $(SUITES); do \
	  echo "=== $$t"; \
	  $(TIMEOUT) $$fg $(TEST_TIMEOUT) $(CHEZ) --libdirs $(TEST_LIBDIRS) --program $$t; \
	  rc=$$?; \
	  if [ $$rc -eq 0 ]; then \
	    echo "test: pass $$t"; passed=$$((passed + 1)); \
	  elif [ $$rc -eq 124 ]; then \
	    echo "test: HUNG $$t (no exit within $(TEST_TIMEOUT)s)"; hung=$$((hung + 1)); \
	  else \
	    echo "test: FAIL $$t (exit $$rc)"; failed=$$((failed + 1)); \
	  fi; \
	done; \
	echo "test: ran $$((passed + failed + hung)), passed $$passed, failed $$failed, hung $$hung"; \
	[ $$failed -eq 0 ] && [ $$hung -eq 0 ]

# Reads every suite as data and fails unless each one's last datum is the
# shared exit form and no datum before it holds an exit form but (exit 1),
# naming each suite that breaks either rule (tests/check-suites.sps). With no
# suite it passes: make test fails that case itself.
check-suites: deps ## Fail unless every tests/test-*.sps ends with the shared exit form
	@scripts/require-tools "$(GOAL)" $(CHEZ)
	@$(CHEZ) --libdirs $(TEST_LIBDIRS) --program tests/check-suites.sps $(SUITES)

# Reads every file under src as data and fails unless each is a .sls library
# at its name's path that imports only (rnrs ...), (jsonparse ...),
# (generated jsonparse) and (byte-machine runtime), and none imports
# (jsonparse easy) (tests/check-imports.sps). make test runs it once src/
# exists.
check-imports: deps ## Fail unless every library under src/ imports only what the layers allow
	@scripts/require-tools "$(GOAL)" $(CHEZ)
	@$(CHEZ) --libdirs $(TEST_LIBDIRS) --program tests/check-imports.sps src

# Fails unless the floor in Akku.manifest, Akku.lock and the vendored
# byte-machine's version agree (tests/check-versions.sps). Needs no git.
check-versions: deps ## Fail unless the Akku floor, Akku.lock and the vendored byte-machine's version agree
	@scripts/require-tools "$(GOAL)" $(CHEZ)
	@$(CHEZ) --libdirs $(TEST_LIBDIRS) --program tests/check-versions.sps

# Fails unless Akku.manifest's version for jsonparse, CHANGELOG.md's newest
# release and the home page's Status name one version
# (tests/check-release.sps, ADR-0022).
check-release: deps ## Fail unless Akku.manifest, CHANGELOG.md's newest release and the home page's Status name one version
	@scripts/require-tools "$(GOAL)" $(CHEZ)
	@$(CHEZ) --libdirs $(TEST_LIBDIRS) --program tests/check-release.sps

# Fails unless every directory under tests/corpus/ carries its upstream
# LICENSE and a SOURCE with the six keys, and no JSON_checker file sits below
# it (tests/check-corpora.sps, ADR-0012). Needs no git.
check-corpora: deps ## Fail unless each corpus under tests/corpus has a LICENSE and a SOURCE, and none holds JSON_checker files
	@scripts/require-tools "$(GOAL)" $(CHEZ)
	@$(CHEZ) --libdirs $(TEST_LIBDIRS) --program tests/check-corpora.sps tests/corpus

# --- the docs site ------------------------------------------------------------
# docs/*.md rendered to build/site/ through chez-cmark-gfm, by the generator
# under site/, copied from circuit (ADR-0021). Akku.lock pins chez-cmark-gfm
# for the site alone: nothing under src/ and no tests/test-*.sps imports it,
# so `make test` needs none of this. The site needs the system cmark-gfm
# library (`cmark-gfm` from Homebrew or apt). In the container,
# scripts/guix-env-enter hands chez-cmark-gfm the profile's by absolute path
# (CHEZ_CMARK_GFM_LIBS).
#
# chez-cmark-gfm comes from an `akku install` tree when there is one, and
# otherwise from the archive Akku.lock pins, downloaded and checked against
# the lock's sha256 by scripts/fetch-akku-lock. Run `make site-deps` on the
# host, where the network is, once and again after `make clean`; in between it
# needs none, and the container finds the tree under build/.
SITE_CMARK   := $(if $(wildcard .akku/lib/cmark/gfm.sls),.akku/lib,$(BUILD_DIR)/akku/chez-cmark-gfm/src)
SITE_LIBDIRS := .:$(SITE_CMARK)
SITE_REF     ?= main

site-deps: ## (host, and after make clean) Get chez-cmark-gfm as Akku.lock pins it: an `akku install` tree, else the locked archive
	@if [ -f .akku/lib/cmark/gfm.sls ]; then \
	  echo "site-deps: using .akku/lib (akku install)"; \
	else \
	  AKKU_DEST=$(BUILD_DIR)/akku sh scripts/fetch-akku-lock chez-cmark-gfm; \
	fi

# The site's targets take any Chez, not only one at the floor: nothing they
# run loads jsonparse or byte-machine, and CI's site job and the Pages
# workflow run them on apt's Chez, which is below it. It must be threaded,
# as for every suite: (jsonparse-testing) takes Chez's mutexes.
site: site-deps ## Render docs/ into build/site/ (open build/site/index.html); SITE_REF=<tag> pins links to repository files
	@scripts/require-tools "$(GOAL)" $(CHEZ)
	@mkdir -p $(BUILD_DIR)/site
	@SITE_REF="$(SITE_REF)" SITE_OUT=$(BUILD_DIR)/site \
	  $(CHEZ) --libdirs $(SITE_LIBDIRS) --program build-site.sps
	@cp site/style.css $(BUILD_DIR)/site/style.css
	@echo "site: $(BUILD_DIR)/site ready (open $(BUILD_DIR)/site/index.html)"

# The generator's own suites (SRFI-64, so `deps` too), then the real site,
# rendered in memory and checked. site-unit runs with no chez-cmark-gfm on its
# path, so a site library it tests that starts importing (cmark gfm) fails
# there at import.
check-site: site-deps deps ## Test the site generator, then render docs/ in memory and check its nav, links, anchors and Read next list
	@scripts/require-tools "$(GOAL)" $(CHEZ)
	@$(CHEZ) --libdirs .:tests:$(SRFI_LIBS) --program tests/site-unit.sps
	@$(CHEZ) --libdirs $(SITE_LIBDIRS):tests:$(SRFI_LIBS) --program tests/site-render-unit.sps
	@SITE_REF="$(SITE_REF)" $(CHEZ) --libdirs $(SITE_LIBDIRS) --program tests/site-check.sps

check-site-deps: ## Test scripts/fetch-akku-lock offline, against a local archive and lock of its own
	@sh tests/fetch-akku-lock.sh

# --- the Akku package ----------------------------------------------------------
# Akku 1.2.0, the release for Chez Scheme, pinned by sha256 in
# scripts/akku-tool.lock and run by scripts/akku (ADR-0022). Guix has 1.1.0,
# which knows only the archive's old signing key. `make akku-deps` fetches it
# on the host, where the network is, once and again after `make clean`.
akku-deps: ## (host, and after make clean) Get Akku 1.2.0 as scripts/akku-tool.lock pins it
	@AKKU_LOCK=scripts/akku-tool.lock AKKU_DEST=$(BUILD_DIR)/akku-tool sh scripts/fetch-akku-lock akku

# Installs the package with Akku as a consumer would, and checks what lands
# (tests/check-akku.sh). The archives Akku would serve need git, so they are
# made here, on the host or in CI; the install needs neither git nor the
# network, so on a Guix host it runs in the container, at the floor Chez.
check-akku: ## (host) Install the package with Akku 1.2.0 as a consumer would, and check what lands
	@scripts/require-tools "$(GOAL)" git
	@sh tests/check-akku.sh archive $(BUILD_DIR)/check-akku
	@if [ -z "$${GUIX_ENVIRONMENT:-}" ] && command -v guix >/dev/null 2>&1; then \
	  scripts/guix-env make --no-print-directory check-akku-inside; \
	else \
	  $(SUBMAKE) --no-print-directory check-akku-inside; \
	fi

check-akku-inside: check-chez ## Install the archives make check-akku wrote, offline, and run a consumer on Akku's library path
	@CHEZ=$(CHEZ) sh tests/check-akku.sh install $(BUILD_DIR)/check-akku

# --- the benchmarks ------------------------------------------------------------
# M3's measurements (ADR-0013, ADR-0023, ADR-0024): jsonparse against yajl
# and the comparators BENCH_PARSERS names, on the files bench/files.lock
# pins, five fetched and M0's three written by bench/synthetic.sps. `make
# test` and CI never run them. `make bench` runs on the host: it fetches the
# public files and the comparators bench/comparators.lock pins there, where
# the network is, then runs bench-inside in the container with
# bench/manifest.scm's tools (`scripts/guix-env --bench`) on a Guix host, or
# directly elsewhere, where cc, pkg-config, yajl and the comparators come
# from Homebrew or the like.
#
# bench-inside checks every file's and comparator's sha256 before it times
# anything, and times exactly the files the lock names, in the directory it
# checked: scripts/fetch-bench-files reads the lock, every time, with
# BENCH_LOCK and BENCH_DEST set here. It builds yajl's harness,
# bench/yajl-bench.c, with BENCH_CFLAGS, then each comparator's.
# jsonparse's libraries, byte-machine's runtime and the harness are compiled
# ahead of time into a fresh $(BENCH_OBJ), at Chez's default optimize level,
# in a Chez process of their own. scripts/bench-chez does that, then times
# bench/run.sps in a process that only loads them. It fails the run if that
# process compiled a library after all: a process that compiled its
# libraries times differently (jsonparse #22).
# Every harness runs pinned by taskset to BENCH_CPU, scripts/bench-cpu's
# fastest core, unless it is empty, as on macOS. The report,
# build/bench/report.md, replaces the last one only if the harnesses'
# results cross-check (bench/report.sps).
#
# The container lets no variable in, so `make bench` hands BENCH_ROUNDS,
# BENCH_ROUND_BYTES, BENCH_CFLAGS, BENCH_CPU, BENCH_PARSERS and GOAL to
# bench-inside on its command line, and BENCH_DIVISORS, BENCH_CC and
# BENCH_CXX only if you set them: the host's compilers may not exist inside.
# It runs the inner make as $(SUBMAKE): under -n, a line naming $(MAKE) would
# run the whole benchmark.
#
# yajl.pc's Cflags name include/yajl, but the harness includes <yajl/...>,
# so the prefix's include/ goes on the path first.
BENCH_DIR         := $(BUILD_DIR)/bench
BENCH_LOCK        := bench/files.lock
BENCH_FILES_DIR   := $(BENCH_DIR)/files
BENCH_OBJ         := $(BENCH_DIR)/obj
BENCH_ROUNDS      ?= 9
BENCH_ROUND_BYTES ?= 20000000
# The C compiler: cc, or gcc where there is no cc, as in the container.
BENCH_CC          ?= $(or $(if $(shell command -v cc 2>/dev/null),cc),$(if $(shell command -v gcc 2>/dev/null),gcc),cc)
BENCH_CFLAGS      ?= -O2
# The core to pin to; BENCH_CPU= runs unpinned. Read only by the benchmark
# recipes, so no other target runs scripts/bench-cpu.
BENCH_CPU         ?= $(shell $(SHELL) scripts/bench-cpu 2>/dev/null)
BENCH_PIN      = $(if $(strip $(BENCH_CPU)),taskset -c $(strip $(BENCH_CPU)))
BENCH_FETCH   := BENCH_LOCK=$(BENCH_LOCK) BENCH_DEST=$(BENCH_FILES_DIR) sh scripts/fetch-bench-files
# The files to time, the lock's names under BENCH_FILES_DIR, in a recipe.
BENCH_FILES    = $$($(BENCH_FETCH) --list | sed 's|^|$(BENCH_FILES_DIR)/|')
BENCH_LIBDIRS := src::$(BENCH_OBJ)/src:$(BYTE_MACHINE_DIR)/src::$(BENCH_OBJ)/byte-machine:bench::$(BENCH_OBJ)/bench

# The comparators (ADR-0024). BENCH_PARSERS names the ones to run, all eleven
# by default; jsonparse and yajl always run. Each has the tools it needs, a
# build step and a command, which takes ROUNDS ROUND-BYTES FILE... and writes
# its results on stdout. A slow one reads smaller rounds: BENCH_DIVISORS gives
# PARSER=N, and it reads BENCH_ROUND_BYTES / N a round, never less than a
# byte. SRFI 180 and chez-json read a hundredth: one pass a round of
# ints-40k.json, the slowest file each times, as bench/chez-peers.sps times no
# lane whose first pass takes over 10 s (ADR-0024). SRFI 180, chez-json and
# Jackson are fetched on the host, as bench/comparators.lock pins them; the
# rest come from bench/manifest.scm, or Homebrew on the Mac, where
# BENCH_PARSERS names the ones installed.
BENCH_COMPARATORS := rapidjson jackson srfi-180 racket guile-json gambit gerbil chibi chez-json simdjson yyjson
BENCH_PARSERS     ?= $(BENCH_COMPARATORS)
BENCH_DIVISORS    ?= srfi-180=100 chez-json=100
# The C++ compiler: c++, or g++ where there is no c++.
BENCH_CXX         ?= $(or $(if $(shell command -v c++ 2>/dev/null),c++),$(if $(shell command -v g++ 2>/dev/null),g++),c++)
BENCH_CMP_DIR     := $(BENCH_DIR)/comparators
BENCH_CMP_FETCH   := BENCH_LOCK=bench/comparators.lock BENCH_DEST=$(BENCH_CMP_DIR) sh scripts/fetch-bench-files
BENCH_JACKSON_JAR := $(BENCH_CMP_DIR)/jackson-core-2.23.0.jar
# A parser's round bytes, in a recipe.
bench-round-bytes = $$(( $(BENCH_ROUND_BYTES) / $(call bench-divisor,$(1)) > 0 ? $(BENCH_ROUND_BYTES) / $(call bench-divisor,$(1)) : 1 ))
bench-divisor     = $(or $(patsubst $(1)=%,%,$(filter $(1)=%,$(BENCH_DIVISORS))),1)
# A native harness: compiler, pkg-config name, source; built as bench/NAME-bench.
bench-native      = $(1) $(BENCH_CFLAGS) -DBENCH_CFLAGS='"$(BENCH_CFLAGS)"' -Ibench $$(pkg-config --cflags $(2)) \
                    -o $(BENCH_DIR)/$(basename $(notdir $(3))) $(3) $$(pkg-config --libs $(2))

BENCH_TOOLS_rapidjson   = $(BENCH_CXX) pkg-config
BENCH_PKG_rapidjson     = RapidJSON
BENCH_BUILD_rapidjson   = $(call bench-native,$(BENCH_CXX),RapidJSON,bench/rapidjson-bench.cc)
BENCH_RUN_rapidjson     = $(BENCH_DIR)/rapidjson-bench
BENCH_TOOLS_simdjson    = $(BENCH_CXX) pkg-config
BENCH_PKG_simdjson      = simdjson
BENCH_BUILD_simdjson    = $(call bench-native,$(BENCH_CXX),simdjson,bench/simdjson-bench.cc)
BENCH_RUN_simdjson      = $(BENCH_DIR)/simdjson-bench
BENCH_TOOLS_yyjson      = $(BENCH_CC) pkg-config
BENCH_PKG_yyjson        = yyjson
BENCH_BUILD_yyjson      = $(call bench-native,$(BENCH_CC),yyjson,bench/yyjson-bench.c)
BENCH_RUN_yyjson        = $(BENCH_DIR)/yyjson-bench
BENCH_TOOLS_jackson     = java javac
BENCH_BUILD_jackson     = javac -d $(BENCH_DIR)/jackson -cp $(BENCH_JACKSON_JAR) bench/JacksonBench.java
BENCH_RUN_jackson       = java -cp $(BENCH_JACKSON_JAR):$(BENCH_DIR)/jackson JacksonBench
# racket-minimal has no `raco make`: compiler/cm is the library it runs.
# Compiled files go under build/, by an absolute root.
BENCH_TOOLS_racket      = racket
BENCH_RACKET_ROOTS      = PLTCOMPILEDROOTS=$(CURDIR)/$(BENCH_DIR)/racket:.
BENCH_BUILD_racket      = env $(BENCH_RACKET_ROOTS) racket -l racket/base -l compiler/cm -e '(managed-compile-zo "bench/racket-bench.rkt")'
BENCH_RUN_racket        = env $(BENCH_RACKET_ROOTS) racket bench/racket-bench.rkt
BENCH_TOOLS_guile-json  = guile guild
BENCH_BUILD_guile-json  = mkdir -p $(BENCH_DIR)/guile && GUILE_AUTO_COMPILE=0 guild compile -o $(BENCH_DIR)/guile/guile-bench.go bench/guile-bench.scm >/dev/null
BENCH_RUN_guile-json    = env GUILE_AUTO_COMPILE=0 guile --no-auto-compile -c '(load-compiled "$(BENCH_DIR)/guile/guile-bench.go")'
# gsc -exe can't link (import (_json)), so the installed _json.scm is
# compiled into the program, unchanged; everything compiles from build/,
# where gsc writes its C.
BENCH_TOOLS_gambit      = gsc
BENCH_BUILD_gambit      = mkdir -p $(BENCH_DIR)/gambit && lib=$$(gsc -e '(display (path-expand "~~lib"))') && \
                          cp -f "$$lib"/_json/_json*.scm bench/gambit-bench.scm $(BENCH_DIR)/gambit/ && chmod u+w $(BENCH_DIR)/gambit/*.scm && \
                          gsc -exe -o $(BENCH_DIR)/gambit/gambit-bench $(BENCH_DIR)/gambit/_json.scm $(BENCH_DIR)/gambit/gambit-bench.scm
BENCH_RUN_gambit        = $(BENCH_DIR)/gambit/gambit-bench
BENCH_TOOLS_gerbil      = gxc
BENCH_BUILD_gerbil      = mkdir -p $(BENCH_DIR)/gerbil/lib && GERBIL_PATH=$(CURDIR)/$(BENCH_DIR)/gerbil/lib gxc -exe -o $(BENCH_DIR)/gerbil/gerbil-bench bench/gerbil-bench.ss
BENCH_RUN_gerbil        = $(BENCH_DIR)/gerbil/gerbil-bench
# Chibi interprets; at its default heap the collector thrashes in tree+walk.
BENCH_TOOLS_chibi       = chibi-scheme
BENCH_BUILD_chibi       = true
BENCH_RUN_chibi         = chibi-scheme -h 1G bench/chibi-bench.scm
# SRFI 180 and chez-json run on Chez in bench/chez-peers.sps, compiled ahead
# of time into a fresh directory of their own, once when both run. chez-json's
# file is copied to json/parser.scm, its library's path. The compile is a step
# of its own: Chez names what it compiles on stdout, where the results go. Its
# reset handler makes a failed compile exit 1; piped Chez would exit 0.
BENCH_PEERS_DIR         = $(BENCH_DIR)/chez-peers
BENCH_PEERS_LIBDIRS     = src::$(BENCH_PEERS_DIR)/obj/src:$(BYTE_MACHINE_DIR)/src::$(BENCH_PEERS_DIR)/obj/byte-machine:bench::$(BENCH_PEERS_DIR)/obj/bench:$(BENCH_PEERS_DIR)/lib::$(BENCH_PEERS_DIR)/obj/lib
BENCH_BUILD_PEERS       = rm -rf $(BENCH_PEERS_DIR)/obj && mkdir -p $(BENCH_PEERS_DIR)/lib/json && \
                          cp -f $(BENCH_CMP_DIR)/chez-json-parser.scm $(BENCH_PEERS_DIR)/lib/json/parser.scm && \
                          printf '(reset-handler (lambda () (exit 1)))\n(import (jsonparse-bench) (jsonparse-bench walks) (jsonparse-bench srfi-180) (json parser))\n' | \
                          $(CHEZ) -q --libdirs '$(BENCH_PEERS_LIBDIRS)' --compile-imported-libraries >/dev/null
BENCH_BUILD_srfi-180    = $(BENCH_BUILD_PEERS)
BENCH_RUN_srfi-180      = $(CHEZ) --libdirs '$(BENCH_PEERS_LIBDIRS)' --program bench/chez-peers.sps srfi-180
BENCH_BUILD_chez-json   = $(if $(filter srfi-180,$(BENCH_PARSERS)),true,$(BENCH_BUILD_PEERS))
BENCH_RUN_chez-json     = $(CHEZ) --libdirs '$(BENCH_PEERS_LIBDIRS)' --program bench/chez-peers.sps chez-json

bench-files: ## (host) Download the benchmarks' public input files and fetched comparators, as bench/files.lock and bench/comparators.lock pin them
	@$(BENCH_FETCH)
	@$(BENCH_CMP_FETCH)

check-bench-files: ## Test scripts/fetch-bench-files offline, against a lock of its own
	@sh tests/fetch-bench-files.sh

bench: bench-files ## (host) Time jsonparse against yajl and the comparators BENCH_PARSERS names, and write build/bench/report.md
	@if [ -z "$${GUIX_ENVIRONMENT:-}" ] && command -v guix >/dev/null 2>&1; then \
	  scripts/guix-env --bench make --no-print-directory bench-inside \
	    BENCH_ROUNDS='$(BENCH_ROUNDS)' BENCH_ROUND_BYTES='$(BENCH_ROUND_BYTES)' \
	    BENCH_CFLAGS='$(BENCH_CFLAGS)' BENCH_CPU='$(BENCH_CPU)' GOAL='$(GOAL)' \
	    BENCH_PARSERS='$(BENCH_PARSERS)' \
	    $(if $(filter command line environment,$(origin BENCH_DIVISORS)),BENCH_DIVISORS='$(BENCH_DIVISORS)') \
	    $(if $(filter command line environment,$(origin BENCH_CC)),BENCH_CC='$(BENCH_CC)') \
	    $(if $(filter command line environment,$(origin BENCH_CXX)),BENCH_CXX='$(BENCH_CXX)'); \
	else \
	  $(SUBMAKE) --no-print-directory bench-inside GOAL='$(GOAL)'; \
	fi

bench-inside: check-chez ## Write M0's files, check every file's and comparator's sha256, build every harness, then run them and write the report
	@seen=" "; for p in $(BENCH_PARSERS); do \
	  case " $(BENCH_COMPARATORS) " in *" $$p "*) ;; \
	    *) echo "bench: $$p is not a comparator; BENCH_PARSERS takes: $(BENCH_COMPARATORS)" >&2; exit 2 ;; esac; \
	  case "$$seen" in *" $$p "*) echo "bench: BENCH_PARSERS names $$p twice" >&2; exit 2 ;; esac; \
	  seen="$$seen$$p "; \
	done
	@scripts/require-tools "$(GOAL)" $(CHEZ) $(BENCH_CC) pkg-config $(if $(BENCH_PIN),taskset) \
	  $(sort $(foreach p,$(BENCH_PARSERS),$(BENCH_TOOLS_$(p))))
	@mkdir -p $(BENCH_FILES_DIR)
	@$(CHEZ) --libdirs src:$(BYTE_MACHINE_DIR)/src:bench --program bench/synthetic.sps $(BENCH_FILES_DIR)
	@$(BENCH_FETCH) --check
	@$(BENCH_CMP_FETCH) --check
	@for m in yajl $(foreach p,$(BENCH_PARSERS),$(BENCH_PKG_$(p))); do \
	  pkg-config --exists $$m || { \
	    echo "bench: pkg-config finds no $$m. On a Guix host, make bench adds bench/manifest.scm; with Homebrew, install it, or leave its comparator out of BENCH_PARSERS." >&2; \
	    exit 1; }; \
	done
	@$(BENCH_CC) $(BENCH_CFLAGS) -DBENCH_CFLAGS='"$(BENCH_CFLAGS)"' \
	  -I"$$(pkg-config --variable=prefix yajl)/include" $$(pkg-config --cflags yajl) \
	  -o $(BENCH_DIR)/yajl-bench bench/yajl-bench.c $$(pkg-config --libs yajl)
	@$(foreach p,$(BENCH_PARSERS),echo "bench: building $(p)'s harness" >&2 && $(BENCH_BUILD_$(p)) && ) true
	@sh scripts/bench-machine $(BENCH_CPU) > $(BENCH_DIR)/machine.txt
	@$(BENCH_FETCH) --list > $(BENCH_DIR)/files.txt
	@{ printf '(plan (rounds %s) (round-bytes %s) (parsers (jsonparse %s) (yajl %s)' \
	    $(BENCH_ROUNDS) $(BENCH_ROUND_BYTES) $(BENCH_ROUND_BYTES) $(BENCH_ROUND_BYTES); \
	  $(foreach p,$(BENCH_PARSERS),printf ' (%s %s)' $(p) $(call bench-round-bytes,$(p));) \
	  printf '))\n'; } > $(BENCH_DIR)/plan.scm
	@$(BENCH_PIN) $(BENCH_DIR)/yajl-bench $(BENCH_ROUNDS) $(BENCH_ROUND_BYTES) $(BENCH_FILES) > $(BENCH_DIR)/yajl.scm
	@rm -rf $(BENCH_OBJ)
	@BENCH_PIN='$(BENCH_PIN)' sh scripts/bench-chez $(BENCH_DIR)/jsonparse-stdout.txt "$(BENCH_LIBDIRS)" bench/run.sps \
	  $(BENCH_DIR)/jsonparse.scm $(BENCH_ROUNDS) $(BENCH_ROUND_BYTES) $(BENCH_FILES)
	@$(foreach p,$(BENCH_PARSERS),echo "bench: timing $(p)" >&2 && \
	  $(BENCH_PIN) $(BENCH_RUN_$(p)) $(BENCH_ROUNDS) $(call bench-round-bytes,$(p)) $(BENCH_FILES) > $(BENCH_DIR)/$(p).scm && ) true
	@$(CHEZ) --libdirs src:$(BYTE_MACHINE_DIR)/src:bench --program bench/report.sps \
	  $(BENCH_DIR)/machine.txt $(BENCH_DIR)/files.txt $(BENCH_DIR)/plan.scm $(BENCH_DIR)/yajl.scm $(BENCH_DIR)/jsonparse.scm \
	  $(foreach p,$(BENCH_PARSERS),$(BENCH_DIR)/$(p).scm) \
	  > $(BENCH_DIR)/report.md.part
	@mv $(BENCH_DIR)/report.md.part $(BENCH_DIR)/report.md
	@cat $(BENCH_DIR)/report.md

# Where the callback path's time goes (ADR-0025): (jsonparse-bench
# callbacks)'s eight lanes on the same files, by the same method, the lanes
# taking turns, pinned, and compiled ahead of time by scripts/bench-chez,
# as bench-inside compiles jsonparse, into objects of its own. It times no
# comparator, so it fetches only the files, but it enters the same
# container, for taskset.
# bench/callbacks.sps checks m-count's counts against the events lane's, and
# every lane's tally, before it writes build/bench/callbacks.md.
BENCH_CALLBACKS_OBJ     := $(BENCH_DIR)/callbacks-obj
BENCH_CALLBACKS_LIBDIRS := src::$(BENCH_CALLBACKS_OBJ)/src:$(BYTE_MACHINE_DIR)/src::$(BENCH_CALLBACKS_OBJ)/byte-machine:bench::$(BENCH_CALLBACKS_OBJ)/bench
bench-callbacks: ## (host) Split jsonparse's callback path's cost a value, and write build/bench/callbacks.md
	@$(BENCH_FETCH)
	@if [ -z "$${GUIX_ENVIRONMENT:-}" ] && command -v guix >/dev/null 2>&1; then \
	  scripts/guix-env --bench make --no-print-directory bench-callbacks-inside \
	    BENCH_ROUNDS='$(BENCH_ROUNDS)' BENCH_ROUND_BYTES='$(BENCH_ROUND_BYTES)' \
	    BENCH_CPU='$(BENCH_CPU)' GOAL='$(GOAL)'; \
	else \
	  $(SUBMAKE) --no-print-directory bench-callbacks-inside GOAL='$(GOAL)'; \
	fi

bench-callbacks-inside: check-chez ## Write M0's files, check every file's sha256, then time the callback path's lanes and write build/bench/callbacks.md
	@scripts/require-tools "$(GOAL)" $(CHEZ) $(if $(BENCH_PIN),taskset)
	@mkdir -p $(BENCH_FILES_DIR)
	@$(CHEZ) --libdirs src:$(BYTE_MACHINE_DIR)/src:bench --program bench/synthetic.sps $(BENCH_FILES_DIR)
	@$(BENCH_FETCH) --check
	@sh scripts/bench-machine $(BENCH_CPU) > $(BENCH_DIR)/callbacks-machine.txt
	@rm -rf $(BENCH_CALLBACKS_OBJ)
	@BENCH_PIN='$(BENCH_PIN)' sh scripts/bench-chez $(BENCH_DIR)/callbacks-stdout.txt "$(BENCH_CALLBACKS_LIBDIRS)" bench/callbacks.sps \
	  $(BENCH_DIR)/callbacks.md $(BENCH_DIR)/callbacks-machine.txt $(BENCH_ROUNDS) $(BENCH_ROUND_BYTES) $(BENCH_FILES)
	@cat $(BENCH_DIR)/callbacks.md

# What bench/manifest.scm must give `make bench`, asserted in the container
# it makes: gcc and g++ 14, taskset, yajl and the native comparators through
# pkg-config, and each comparator's runtime at the version ADR-0024 names.
# A version matches exactly, or as a prefix up to a dot: 14 takes 14.3.0.
# `make check-guix` runs it.
check-bench-env-inside: ## (inside scripts/guix-env --bench) Assert the benchmarks' tools: gcc 14, taskset, yajl and every comparator at its version
	@scripts/require-tools "$(GOAL)" gcc g++ pkg-config taskset java javac racket guile guild gsc gxc chibi-scheme
	@bad=0; \
	expect() { case $$2 in "$$3"|"$$3".*) ;; *) echo "check-bench-env: $$1 is $$2, not $$3" >&2; bad=1 ;; esac; }; \
	expect gcc "$$(gcc -dumpversion)" 14; \
	expect g++ "$$(g++ -dumpversion)" 14; \
	for m in yajl:2.1.0 RapidJSON:1.1.0 simdjson:4.6.3 yyjson:0.12.0; do \
	  expect "pkg-config's $${m%%:*}" "$$(pkg-config --modversion $${m%%:*} 2>/dev/null || echo none)" "$${m#*:}"; \
	done; \
	expect java "$$(java -version 2>&1 | sed -n '1s/.*version "\([^"]*\)".*/\1/p')" 25; \
	expect javac "$$(javac -version 2>&1 | sed -n '1s/^javac //p')" 25; \
	expect racket "$$(racket -e '(display (version))' 2>&1)" 9.3; \
	expect "racket's json" "$$(racket -l racket/base -l json -e '(display (jsexpr->string (list 1)))' 2>&1)" '[1]'; \
	expect "racket's compiler/cm" "$$(racket -l racket/base -l compiler/cm -e '(display (procedure? managed-compile-zo))' 2>&1)" '#t'; \
	expect guile "$$(guile -c '(display (version))' 2>/dev/null)" 3.0; \
	expect guile-json "$$(guile -c '(use-modules (json)) (display (scm->json-string (vector 1)))' 2>/dev/null)" '[1]'; \
	expect gsc "$$(gsc -v 2>&1 | sed -n '1s/^v\([^ ]*\) .*/\1/p')" 4.9.7; \
	expect gerbil "$$(gxi --version 2>&1 | sed -n '1s/^Gerbil v\([^ ]*\) .*/\1/p')" 0.18.1; \
	expect chibi "$$(chibi-scheme -V 2>&1 | sed -n '1s/^chibi-scheme \([^ ]*\) .*/\1/p')" 0.12.0; \
	[ $$bad = 0 ]
	@echo "check-bench-env: gcc and g++ $$(gcc -dumpversion), taskset, yajl, RapidJSON, simdjson, yyjson, OpenJDK, Racket, Guile and guile-json, Gambit, Gerbil, Chibi"

clean: ## Remove build/
	rm -rf build
