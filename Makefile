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

# --- the pins ----------------------------------------------------------------
BYTE_MACHINE_DIR := vendor/byte-machine
BYTE_MACHINE_PIN := c1f77911efb55030df0b2cd811903d74d2ba3d64
BYTE_MACHINE_TAG := v0.8.0
SRFI_DIR := vendor/chez-srfi
SRFI_PIN := 7879b527f267f067416552fb989135ad1b4ea436  # the pin chez-http-server uses

# --- the library paths --------------------------------------------------------
# LIBDIRS is the path `make run` and `make dev` use: jsonparse's src/, then
# byte-machine's runtime. build/scheme-libs carries (srfi :64).
#
# TEST_LIBDIRS is the suites' path: LIBDIRS; tests/, which holds
# (jsonparse-testing); grammar/, which holds (jsonparse-grammar) for the
# regeneration check and the interpreter; and byte-machine's test harness,
# for its feed schedules (ADR-0012). Test code and the grammar stay off
# LIBDIRS.
BUILD_DIR := build
SRFI_LIBS := $(BUILD_DIR)/scheme-libs
LIBDIRS := src:$(BYTE_MACHINE_DIR)/src:$(SRFI_LIBS)
TEST_LIBDIRS := $(LIBDIRS):tests:grammar:$(BYTE_MACHINE_DIR)/test/support/harness

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
.PHONY: help check-help check-guix check-guix-inside submodules check-pins check-chez deps dev run generate test check-suites check-imports check-versions check-corpora clean

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

check-guix: ## Test scripts/guix-env on the host, then the toolchain inside the container
	@scripts/require-tools "$(GOAL)" guix
	@sh tests/guix-env-launcher.sh
	@scripts/guix-env make check-guix-inside

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
test: deps check-help check-chez check-suites check-versions check-corpora $(if $(wildcard src),check-imports) ## Run every tests/test-*.sps under timeout; fail if one fails or hangs, or none exists
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

# Fails unless every directory under tests/corpus/ carries its upstream
# LICENSE and a SOURCE with the six keys, and no JSON_checker file sits below
# it (tests/check-corpora.sps, ADR-0012). Needs no git.
check-corpora: deps ## Fail unless each corpus under tests/corpus has a LICENSE and a SOURCE, and none holds JSON_checker files
	@scripts/require-tools "$(GOAL)" $(CHEZ)
	@$(CHEZ) --libdirs $(TEST_LIBDIRS) --program tests/check-corpora.sps tests/corpus

clean: ## Remove build/
	rm -rf build
