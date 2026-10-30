#!/bin/sh
# Host-side tests for the container's scripts. Nothing here runs
# Guix:
#
#   - scripts/guix-env: every case sets GUIX_ENV_DRY_RUN=1, under which the
#     launcher prints `cd <dir>` and then the guix command it would exec,
#     one argument per line;
#   - scripts/guix-env-enter: run directly, against a fake profile;
#   - scripts/require-tools, and the Makefile's use of it: run with PATH
#     set to a directory of stub executables, and, for M2, in a copy of the
#     tree with the real PATH.
#
# `make check-guix` runs this before entering the container. Checks name
# themselves, and the exit status is non-zero if any failed.
#
# Single-quoted dollar signs here are literal on purpose: they check that
# `$HOME` and the like pass through unexpanded.
# shellcheck disable=SC2016
set -u

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
launcher=$root/scripts/guix-env
enter=$root/scripts/guix-env-enter
require=$root/scripts/require-tools
make_bin=$(command -v make) || { echo "guix-env-launcher: no make on PATH" >&2; exit 2; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

pass=0
fail=0

ok()    { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad()   { fail=$((fail + 1)); printf 'FAIL %s\n' "$1" >&2; }
check() { name=$1; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }
has()   { grep -Fxq -- "$1" "$tmp/out"; }
lacks() { ! grep -Fq -- "$1" "$tmp/out"; }
lines() { sed -n "$1" "$tmp/out" | tr '\n' '|'; }
tail_lines() { tail -n "$1" "$tmp/out" | tr '\n' '|'; }
err_lines() { tr '\n' '|' <"$tmp/err"; }

# The fake HOME has a space and a non-ASCII letter in it, and holds the
# kinds of credential a developer's HOME does. The container must receive
# none of them.
home="$tmp/fake hôme"
mkdir -p "$home/.ssh" "$home/.config/gh"
: >"$home/.ssh/id_ed25519"
: >"$home/.gitconfig"

# run [VAR=value...] LAUNCHER [ARG...]
# Runs from $cwd in a scrubbed environment. stdout -> $tmp/out,
# stderr -> $tmp/err, exit -> $status.
cwd=$root
run() {
  status=999
  ( cd "$cwd" && env -i HOME="$home" PATH="$PATH" GUIX_ENV_DRY_RUN=1 \
      SSH_AUTH_SOCK="$home/ssh-agent.sock" "$@" ) >"$tmp/out" 2>"$tmp/err"
  status=$?
}

# ---- scripts/guix-env ----

# T1: no arguments means an interactive bash, behind the pinned prefix, in
# a container with no network and only three variables let in.
run "$launcher"
check "T1 no-args exits 0" [ "$status" -eq 0 ]
check "T1 no-args runs from the repo root" [ "$(lines 1p)" = "cd $root|" ]
check "T1 pins guix via channels.scm" \
  [ "$(lines 2,8p)" = "guix|time-machine|-C|channels.scm|--|shell|-m|" ]
check "T1 uses manifest.scm" [ "$(lines 9p)" = "manifest.scm|" ]
check "T1 container flag" has --container
check "T1 no network flag" lacks --network
check "T1 no emulate-fhs flag" lacks --emulate-fhs
preserves_three() {
  [ "$(grep -c -- '^--preserve' "$tmp/out")" -eq 1 ] \
    && has '--preserve=^(TERM|COLORTERM|LANG)$'
}
check "T1 preserves only TERM, COLORTERM and LANG" preserves_three
check "T1 enters through guix-env-enter" \
  [ "$(tail_lines 4)" = "--|sh|scripts/guix-env-enter|bash|" ]
want="cd $root|guix|time-machine|-C|channels.scm|--|shell|-m|manifest.scm|--container|"
want=$want'--preserve=^(TERM|COLORTERM|LANG)$|--|sh|scripts/guix-env-enter|bash|'
check "T1 the whole command" [ "$(lines '1,$p')" = "$want" ]

# T2: arguments pass through verbatim, spaces and dollars included.
run "$launcher" make "a b" '$HOME'
check "T2 args pass through verbatim" \
  [ "$(tail_lines 6)" = '--|sh|scripts/guix-env-enter|make|a b|$HOME|' ]

# T3: nothing from HOME, and no agent socket, enters the container.
for args in "make check-guix-inside" ""; do
  # shellcheck disable=SC2086
  run "$launcher" $args
  label=${args:-no-args}
  check "T3 [$label] no --share" lacks "--share"
  check "T3 [$label] no --expose" lacks "--expose"
  check "T3 [$label] nothing from HOME" lacks "$home"
  check "T3 [$label] no agent socket" lacks "SSH_AUTH_SOCK"
done

# T4: refuse to nest.
run GUIX_ENVIRONMENT=/gnu/store/fake-profile "$launcher" make help
check "T4 nested: exit 2" [ "$status" -eq 2 ]
check "T4 nested: names GUIX_ENVIRONMENT" grep -Fq "/gnu/store/fake-profile" "$tmp/err"
check "T4 nested: prints no command" [ ! -s "$tmp/out" ]

# T5: launched by relative path from a subdirectory, the container still
# gets the repo root.
cwd=$root/.plans
run ../scripts/guix-env make help
cwd=$root
check "T5 subdirectory: exits 0" [ "$status" -eq 0 ]
check "T5 subdirectory: runs from the repo root" [ "$(lines 1p)" = "cd $root|" ]

# ---- scripts/guix-env-enter ----

# T6: the in-container entry refuses to run on the host, and runs nothing.
( cd "$tmp" && env -i PATH="$PATH" sh "$enter" sh -c ': >ran' ) \
  >"$tmp/out" 2>"$tmp/err"
status=$?
check "T6 enter on host: exit 2" [ "$status" -eq 2 ]
check "T6 enter on host: says why, and what to use" \
  [ "$(err_lines)" = "guix-env-enter: not inside a Guix environment; use scripts/guix-env|" ]
check "T6 enter on host: runs nothing" [ ! -e "$tmp/ran" ]

# T7: what scripts/guix-env-enter exports, against a fake profile shaped
# like a real one: each entry is a symlink into a fake store.
profile=$tmp/fake-profile
store=$tmp/fake-store
enter_cwd=$tmp/enter-cwd

reset_profile() {
  rm -rf "$profile" "$store" "$enter_cwd"
  mkdir -p "$profile/bin" "$profile/lib" "$store" "$enter_cwd"
  : >"$store/scheme"
  ln -s "$store/scheme" "$profile/bin/scheme"
}

# run_enter: prints CHEZ, then CC, LD_LIBRARY_PATH (or "unset") and
# CHEZ_CMARK_GFM_LIBS as the command sees them, separated by |. Only CHEZ
# is exported; the other three must come out empty, empty, "unset".
run_enter() {
  status=999
  ( cd "$enter_cwd" && env -i PATH="$PATH" GUIX_ENVIRONMENT="$profile" \
      sh "$enter" sh -c \
      'printf "%s|%s|%s|%s\n" "${CHEZ-}" "${CC-}" "${LD_LIBRARY_PATH-unset}" "${CHEZ_CMARK_GFM_LIBS-}"' ) \
    >"$tmp/out" 2>"$tmp/err"
  status=$?
}
field() { cut -d '|' -f "$1" "$tmp/out"; }

# T7a: a complete profile. Every export names the profile's own entry,
# never the store file it resolves to.
reset_profile
run_enter
check "T7a complete profile: exit 0" [ "$status" -eq 0 ]
check "T7a CHEZ is the profile's scheme" [ "$(field 1)" = "$profile/bin/scheme" ]
check "T7a no CC" [ -z "$(field 2)" ]
check "T7a no LD_LIBRARY_PATH" [ "$(field 3)" = "unset" ]
check "T7a no CHEZ_CMARK_GFM_LIBS" [ -z "$(field 4)" ]
check "T7a no state directory" [ ! -e "$enter_cwd/.guix-env" ]

# T7b-c: a profile missing one entry is refused, naming the entry, and the
# command never runs.
refused() {  # LABEL PATH
  check "$1: exit 2" [ "$status" -eq 2 ]
  check "$1: names $2" grep -Fq "$2" "$tmp/err"
  check "$1: runs nothing" [ ! -s "$tmp/out" ]
}
reset_profile
rm "$store/scheme"
run_enter
refused "T7b dangling scheme" "$profile/bin/scheme"

reset_profile
rm "$profile/bin/scheme"
run_enter
refused "T7c no scheme" "$profile/bin/scheme"

# T8: the command's arguments pass through verbatim.
reset_profile
( cd "$enter_cwd" && env -i PATH="$PATH" GUIX_ENVIRONMENT="$profile" \
    sh "$enter" printf '%s|' "a b" '$HOME' ) >"$tmp/out" 2>"$tmp/err"
check "T8 enter passes args verbatim" [ "$(cat "$tmp/out")" = 'a b|$HOME|' ]

# ---- scripts/require-tools ----

# Each case runs it with PATH holding only the stubs it names. It needs
# nothing but shell builtins, so /bin/sh runs it with no PATH of its own.
# A stub, when run, appends its own name to $started and exits 0.
stubs=$tmp/stubs
started=$tmp/started
reset_stubs() {
  rm -rf "$stubs"
  mkdir -p "$stubs"
  : >"$started"
  for name in "$@"; do
    printf '#!/bin/sh\necho %s >>"%s"\nexit 0\n' "$name" "$started" >"$stubs/$name"
    chmod +x "$stubs/$name"
  done
}

# run_require [VAR=value...] -- GOAL TOOL...
run_require() {
  status=999
  vars=
  while [ "$1" != "--" ]; do vars="$vars $1"; shift; done
  shift
  # shellcheck disable=SC2086
  env -i PATH="$stubs" $vars /bin/sh "$require" "$@" >"$tmp/out" 2>"$tmp/err"
  status=$?
}
guix_hint="On this Guix host, run it in the project's container: scripts/guix-env make test"
install_hint="Install the missing tools, then run make test again."

# R1: every tool found: silent, exit 0.
reset_stubs alpha beta
run_require -- test alpha beta
check "R1 all found: exit 0" [ "$status" -eq 0 ]
silent() { [ ! -s "$tmp/out" ] && [ ! -s "$tmp/err" ]; }
check "R1 all found: silent" silent

# R2: on a Guix host, outside any environment, a missing tool points at
# the container, naming the goal.
reset_stubs guix
run_require -- test nosuch
check "R2 guix host: exit 2" [ "$status" -eq 2 ]
check "R2 guix host: names the tool, then the container" \
  [ "$(err_lines)" = "make test: nosuch not found.|$guix_hint|" ]

# R3: every missing tool is named, in order, before the one hint.
reset_stubs guix
run_require -- test one two
check "R3 two missing: both named, then one hint" \
  [ "$(err_lines)" = "make test: one not found.|make test: two not found.|$guix_hint|" ]

# R4: inside a Guix environment, the container is not the answer.
reset_stubs guix
run_require GUIX_ENVIRONMENT=/gnu/store/fake-profile -- test nosuch
check "R4 inside an environment: exit 2" [ "$status" -eq 2 ]
check "R4 inside an environment: install hint" \
  [ "$(err_lines)" = "make test: nosuch not found.|$install_hint|" ]

# R5: no guix at all.
reset_stubs
run_require -- test nosuch
check "R5 no guix: exit 2" [ "$status" -eq 2 ]
check "R5 no guix: install hint" \
  [ "$(err_lines)" = "make test: nosuch not found.|$install_hint|" ]

# R6: a goal with no tools is a usage error, not a pass.
reset_stubs
run_require -- test
check "R6 no tools: exit 2" [ "$status" -eq 2 ]
check "R6 no tools: usage" [ "$(err_lines)" = "usage: require-tools GOAL TOOL...|" ]

# R7: inside a Guix environment, a missing git means a host-only target:
# the container has no git, so installing it there is not the answer.
host_hint="make test needs git, which this container doesn't have: run it on the host."
reset_stubs guix
run_require GUIX_ENVIRONMENT=/gnu/store/fake-profile -- test git
check "R7 git inside an environment: exit 2" [ "$status" -eq 2 ]
check "R7 git inside an environment: run it on the host" \
  [ "$(err_lines)" = "make test: git not found.|$host_hint|" ]

# R8: on a host with no git, the answer is still to install it.
reset_stubs
run_require -- test git
check "R8 git on a host without it: install hint" \
  [ "$(err_lines)" = "make test: git not found.|$install_hint|" ]

# M1: `make check-guix` without guix stops at require-tools, naming the
# goal the user typed, before any test or container runs. The recipe's
# next line runs `sh tests/guix-env-launcher.sh`, which would find the
# stub sh.
reset_stubs sh
( env -i PATH="$stubs" "$make_bin" --no-print-directory -C "$root" check-guix ) \
  >"$tmp/out" 2>"$tmp/err"
status=$?
check "M1 make check-guix without guix: fails" [ "$status" -ne 0 ]
check "M1 make check-guix without guix: names the goal" \
  grep -Fxq "make check-guix: guix not found." "$tmp/err"
check "M1 make check-guix without guix: runs no test" [ ! -s "$started" ]

# M2: `make test` with no Chez stops at its first prerequisite, deps, whose
# require-tools hint names `test`, the goal the user typed, not `deps`:
# GOAL's $(MAKECMDGOALS) branch, reached through a prerequisite. It runs in
# a copy of the tree, with the real PATH, so deps' require-tools is what
# stops it, before any suite runs. The copy has no
# .git, no build/ and no vendor/: deps stops before it looks for the
# submodules, and in a worktree .git points outside the one directory the
# container shares. Only the hint's first line is compared: the line after
# it depends on whether the host has guix. make's own "***" line carries a
# Makefile line number.
copy=$tmp/tree
mkdir "$copy"
for entry in "$root"/* "$root"/.[!.]* "$root"/..?*; do
  [ -e "$entry" ] || [ -L "$entry" ] || continue
  case "$entry" in "$root/.git" | "$root/build" | "$root/vendor" | "$root/.claude") continue ;; esac
  cp -a "$entry" "$copy/" || { echo "guix-env-launcher: could not copy $entry" >&2; exit 2; }
done
( env -i PATH="$PATH" "$make_bin" --no-print-directory -C "$copy" test CHEZ=no-such-chez ) \
  >"$tmp/out" 2>"$tmp/err"
status=$?
check "M2 make test without Chez: fails" [ "$status" -ne 0 ]
check "M2 make test without Chez: the prerequisite's hint names test" \
  grep -Fxq "make test: no-such-chez not found." "$tmp/err"
check "M2 make test without Chez: runs no suite" lacks "=== "
check "M2 make test without Chez: names no suite's outcome" lacks "test: "

# T9: the TIMEOUT fallback. GNU timeout is `timeout`, else `gtimeout` (where
# Homebrew's coreutils installs it, on macOS), else the bare name `timeout`,
# which require-tools then reports missing. Each case asks make which TIMEOUT it
# would use, with PATH holding only the stubs. The first holds both names, so
# `timeout` must win. The quotes in the recipe make make run it through the
# shell, whose echo is built in: with no quote or other shell character in the
# line, make would exec echo itself, and PATH has no echo.
print_timeout() {
  status=999
  env -i PATH="$stubs" "$make_bin" --no-print-directory -C "$root" \
    --eval 'print-timeout: ; @echo "$(TIMEOUT)"' print-timeout >"$tmp/out" 2>"$tmp/err"
  status=$?
}
printed() { [ "$status" -eq 0 ] && [ "$(cat "$tmp/out")" = "$1" ]; }

reset_stubs timeout gtimeout
print_timeout
check "T9a timeout and gtimeout: timeout, by its path" printed "$stubs/timeout"

reset_stubs gtimeout
print_timeout
check "T9b only gtimeout: gtimeout, by its path" printed "$stubs/gtimeout"

reset_stubs
print_timeout
check "T9c neither: the bare name timeout" printed timeout

# ---- the Makefile ----

# C1: check-help fails on a .PHONY target with no description, and on a
# described target missing from .PHONY. Each runs in a directory holding a
# Makefile of its own, the real one plus one more target.
help_dir=$tmp/help
mkdir "$help_dir"
run_check_help() {  # appends $1 to the Makefile, and $2 to the .PHONY line
  cp "$root/Makefile" "$help_dir/Makefile"
  printf '%s\n' "$1" >>"$help_dir/Makefile"
  [ -z "$2" ] || sed -i "s/^\.PHONY:/.PHONY: $2/" "$help_dir/Makefile"
  status=999
  ( cd "$help_dir" && "$make_bin" --no-print-directory check-help ) >"$tmp/out" 2>"$tmp/err"
  status=$?
}
run_check_help "" ""
check "C1a check-help passes on the real Makefile" [ "$status" -eq 0 ]
run_check_help "$(printf 'bare:\n\t@true')" bare
check "C1b undescribed .PHONY target: fails" [ "$status" -ne 0 ]
check "C1b undescribed .PHONY target: names it" \
  grep -Fxq "check-help: make help does not list .PHONY target 'bare'; give it a '## ' description on its target line" "$tmp/err"
run_check_help "$(printf 'extra: ## An extra\n\t@true')" ""
check "C1c described target outside .PHONY: fails" [ "$status" -ne 0 ]
check "C1c described target outside .PHONY: names it" \
  grep -Fxq "check-help: make help lists 'extra', which is not in .PHONY" "$tmp/err"

# C2: the Chez lookup. A Homebrew host has `chez`; `scheme` wins when both
# exist (MIT Scheme installs one), and check-chez then rejects it.
print_chez() {
  status=999
  env -i PATH="$stubs" "$make_bin" --no-print-directory -C "$root" \
    --eval 'print-chez: ; @echo "$(CHEZ)"' print-chez >"$tmp/out" 2>"$tmp/err"
  status=$?
}
reset_stubs chez
print_chez
check "C2a only chez on PATH: chez" printed chez
reset_stubs scheme chez
print_chez
check "C2b scheme and chez: scheme" printed scheme
reset_stubs
print_chez
check "C2c neither: scheme, which require-tools then reports" printed scheme

# C3: check-chez accepts Chez at the floor or above, and refuses below it or
# a binary that is not Chez, naming the binary and what it printed.
fake_chez() {  # FILE TEXT: a binary whose --version prints TEXT
  printf '#!/bin/sh\necho "%s" >&2\n' "$2" >"$1"
  chmod +x "$1"
}
run_check_chez() {
  status=999
  ( cd "$root" && env -i PATH="$PATH" "$make_bin" --no-print-directory check-chez CHEZ="$1" ) \
    >"$tmp/out" 2>"$tmp/err"
  status=$?
}
reset_stubs
fake_chez "$stubs/scheme" 10.4.1
run_check_chez "$stubs/scheme"
check "C3a 10.4.1: passes" [ "$status" -eq 0 ]
fake_chez "$stubs/scheme" 10.10.0
run_check_chez "$stubs/scheme"
check "C3b 10.10.0: passes (version order, not text order)" [ "$status" -eq 0 ]
fake_chez "$stubs/scheme" 10.4.0
run_check_chez "$stubs/scheme"
check "C3c 10.4.0: fails" [ "$status" -ne 0 ]
check "C3c 10.4.0: names the binary and what it printed" \
  grep -Fxq "check-chez: '$stubs/scheme' printed '10.4.0' for --version, not Chez 10.4.1 or later." "$tmp/err"
check "C3c 10.4.0: gives both hints" \
  grep -Fxq "check-chez: on Guix use scripts/guix-env make check-chez; with Homebrew use CHEZ=chez." "$tmp/err"
fake_chez "$stubs/scheme" "MIT/GNU Scheme running under GNU/Linux"
run_check_chez "$stubs/scheme"
check "C3d not Chez: fails" [ "$status" -ne 0 ]
check "C3d not Chez: names what it printed" \
  grep -Fq "printed 'MIT/GNU Scheme running under GNU/Linux'" "$tmp/err"

# C4: make test's verdict, in a tree of its own with stub vendor files and a
# stub CHEZ that answers --version 10.4.1 and keys on the --program file's
# name: test-fail* exits 3, test-hang* sleeps past TEST_TIMEOUT, and every
# other program, the checks included, exits 0.
tree4=$tmp/tree4
stubchez=$tmp/stubchez
cat >"$stubchez" <<'STUB'
#!/bin/sh
if [ "$1" = --version ]; then echo 10.4.1 >&2; exit 0; fi
while [ $# -gt 0 ]; do
  if [ "$1" = --program ]; then prog=$2; fi
  shift
done
case "$prog" in
  */test-fail*) exit 3 ;;
  */test-hang*) exec sleep 30 ;;
esac
exit 0
STUB
chmod +x "$stubchez"
make4() {  # SUITE...: make test in a fresh tree holding just those suites
  rm -rf "$tree4"
  mkdir -p "$tree4/tests" "$tree4/scripts" "$tree4/vendor/byte-machine/src" "$tree4/vendor/chez-srfi"
  cp "$root/Makefile" "$tree4/"
  cp "$root/scripts/require-tools" "$tree4/scripts/"
  : >"$tree4/vendor/chez-srfi/%3a64.sls"
  for t in "$@"; do : >"$tree4/tests/$t.sps"; done
  status=999
  ( cd "$tree4" && env -i PATH="$PATH" "$make_bin" --no-print-directory test \
      CHEZ="$stubchez" TEST_TIMEOUT=1 ) >"$tmp/out" 2>"$tmp/err"
  status=$?
}
make4 test-a test-b
check "C4a all pass: exit 0" [ "$status" -eq 0 ]
check "C4a all pass: counts" has "test: ran 2, passed 2, failed 0, hung 0"
make4 test-a test-fail
check "C4b a failing suite: non-zero" [ "$status" -ne 0 ]
check "C4b a failing suite: FAIL line" has "test: FAIL tests/test-fail.sps (exit 3)"
check "C4b a failing suite: counts" has "test: ran 2, passed 1, failed 1, hung 0"
make4 test-a test-hang
check "C4c a hung suite: non-zero" [ "$status" -ne 0 ]
check "C4c a hung suite: HUNG line" has "test: HUNG tests/test-hang.sps (no exit within 1s)"
make4
check "C4d no suites: non-zero" [ "$status" -ne 0 ]
check "C4d no suites: says so" grep -Fxq "test: no suites: nothing matches tests/test-*.sps" "$tmp/err"

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
