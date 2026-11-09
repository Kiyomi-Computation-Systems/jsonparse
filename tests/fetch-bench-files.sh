#!/bin/sh
# tests/fetch-bench-files.sh: what scripts/fetch-bench-files promises,
# checked offline against a lock of its own whose URLs are file:// ones in a
# scratch directory. It needs curl, which reads file:// URLs, and a sha256
# tool, but no network. `make check-bench-files` runs it.
set -u
cd "$(dirname "$0")/.."
script=$PWD/scripts/fetch-bench-files

scratch=$(mktemp -d "${TMPDIR:-/tmp}/fetch-bench-files.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1" >&2; fails=$((fails + 1)); }

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

srv=$scratch/srv
dest=$scratch/dest
mkdir -p "$srv"
printf '[1, 2, 3]\n' > "$srv/a.json"
printf '{"b": true}\n' > "$srv/b.json"
printf '"generated"\n' > "$scratch/gen.json"
a=$(sha256 "$srv/a.json")
b=$(sha256 "$srv/b.json")
g=$(sha256 "$scratch/gen.json")

# A lock with comments, a blank line, two downloads and a generated file.
good_lock() {
  cat > "$scratch/files.lock" <<EOF
# a comment

a.json $a file://$srv/a.json
  # an indented comment
b.json $b file://$srv/b.json
gen.json $g generated
EOF
}

run() {
  BENCH_LOCK=$scratch/files.lock BENCH_DEST=$dest "$script" "$@" \
    > "$scratch/out" 2>&1
}

# 1. Each pinned file is downloaded and checked, and nothing is made for a
#    generated one.
good_lock
if run && [ "$(sha256 "$dest/a.json")" = "$a" ] \
   && [ "$(sha256 "$dest/b.json")" = "$b" ] \
   && [ ! -e "$dest/gen.json" ] \
   && grep -q '^fetch-bench-files: a.json fetched$' "$scratch/out" \
   && grep -q '^fetch-bench-files: gen.json is generated, by make bench$' "$scratch/out"; then
  pass "each pinned file is fetched and checked; a generated one is left alone"
else
  fail "each pinned file is fetched and checked; a generated one is left alone"; cat "$scratch/out" >&2
fi

# 2. A file already there with the lock's sha256 is not downloaded again:
#    with the server's copy gone, the run still passes.
mv "$srv/a.json" "$scratch/a.saved"
if run && [ "$(sha256 "$dest/a.json")" = "$a" ] \
   && grep -q '^fetch-bench-files: a.json ok$' "$scratch/out"; then
  pass "a file that already checks out is not downloaded again"
else
  fail "a file that already checks out is not downloaded again"; cat "$scratch/out" >&2
fi
mv "$scratch/a.saved" "$srv/a.json"

# 3. A file there with other bytes is downloaded again, and ends with the
#    lock's sha256.
printf 'edited\n' > "$dest/a.json"
if run && [ "$(sha256 "$dest/a.json")" = "$a" ] \
   && grep -q '^fetch-bench-files: a.json fetched$' "$scratch/out"; then
  pass "a file whose bytes changed is downloaded again"
else
  fail "a file whose bytes changed is downloaded again"; cat "$scratch/out" >&2
fi

# 4. A download whose sha256 differs from the lock's fails, naming the file
#    and both sums, and leaves neither the file nor a partial download. The
#    other file is still fetched.
rm -f "$dest/a.json" "$dest/b.json"
printf '[1, 2, 4]\n' > "$srv/a.json"
wrong=$(sha256 "$srv/a.json")
if ! run && [ ! -e "$dest/a.json" ] && [ -z "$(ls "$dest" | grep -v '^b.json$')" ] \
   && [ "$(sha256 "$dest/b.json")" = "$b" ] \
   && grep -q "^fetch-bench-files: a.json has sha256 $wrong, not the lock's $a$" "$scratch/out"; then
  pass "a download with the wrong sha256 fails, and leaves nothing behind"
else
  fail "a download with the wrong sha256 fails, and leaves nothing behind"; cat "$scratch/out" >&2; ls -a "$dest" >&2
fi

# 5. A file there with the wrong bytes, whose download then fails its
#    check, is removed: no file with the wrong sha256 stays.
mkdir -p "$dest"
printf 'stale\n' > "$dest/a.json"
if [ -f "$dest/a.json" ] && ! run && [ ! -e "$dest/a.json" ] \
   && grep -q "^fetch-bench-files: a.json has sha256 $wrong, not the lock's $a$" "$scratch/out"; then
  pass "a wrong file is removed when its new download fails"
else
  fail "a wrong file is removed when its new download fails"; cat "$scratch/out" >&2
fi
printf '[1, 2, 3]\n' > "$srv/a.json"

# 6. A download that fails names the file and its URL, and the run goes on to
#    the next file.
mv "$srv/a.json" "$scratch/a.saved"
rm -f "$dest/b.json"
if ! run && [ ! -e "$dest/a.json" ] && [ "$(sha256 "$dest/b.json")" = "$b" ] \
   && grep -q "^fetch-bench-files: a.json could not be downloaded from file://$srv/a.json$" "$scratch/out"; then
  pass "a failed download is named, and the run goes on"
else
  fail "a failed download is named, and the run goes on"; cat "$scratch/out" >&2
fi
mv "$scratch/a.saved" "$srv/a.json"

# 7. --check downloads nothing: with a.json missing it fails, naming it, even
#    though the server has it.
rm -f "$dest/a.json"
cp "$scratch/gen.json" "$dest/gen.json"
if ! run --check && [ ! -e "$dest/a.json" ] \
   && grep -q '^fetch-bench-files: a.json is missing: run make bench-files on the host$' "$scratch/out"; then
  pass "--check downloads nothing, and names a missing file"
else
  fail "--check downloads nothing, and names a missing file"; cat "$scratch/out" >&2
fi

# 8. --check passes once every file, the generated one included, has the
#    lock's sha256.
run >/dev/null
if run --check && grep -q '^fetch-bench-files: gen.json ok$' "$scratch/out"; then
  pass "--check passes when every file checks out"
else
  fail "--check passes when every file checks out"; cat "$scratch/out" >&2
fi

# 9. --check names a generated file that is missing, and one whose bytes
#    changed, and changes neither.
rm -f "$dest/gen.json"
printf 'edited\n' > "$dest/b.json"
edited=$(sha256 "$dest/b.json")
if ! run --check && [ "$(sha256 "$dest/b.json")" = "$edited" ] \
   && grep -q '^fetch-bench-files: gen.json is missing: bench/synthetic.sps writes it$' "$scratch/out" \
   && grep -q "^fetch-bench-files: b.json has sha256 $edited, not the lock's $b$" "$scratch/out"; then
  pass "--check names a missing generated file and a changed one, and changes neither"
else
  fail "--check names a missing generated file and a changed one, and changes neither"; cat "$scratch/out" >&2
fi

# 10. A malformed lock fails before anything is fetched, naming its line.
#     Each case's bad line is line 2, after a good one.
bad_lock() {
  rm -f "$dest/a.json"
  printf 'a.json %s file://%s/a.json\n%s\n' "$a" "$srv" "$1" > "$scratch/files.lock"
  if ! run && [ ! -e "$dest/a.json" ] \
     && grep -q "^fetch-bench-files: $scratch/files.lock line 2: $3$" "$scratch/out"; then
    pass "a lock with $2 is refused"
  else
    fail "a lock with $2 is refused"; cat "$scratch/out" >&2
  fi
}
shape='not NAME SHA256 SOURCE'
bad_lock "b.json $b" "two fields" "$shape"
bad_lock "b.json $b file://$srv/b.json extra" "four fields" "$shape"
bad_lock "b.json ${b%?} file://$srv/b.json" "a 63-digit sha256" "$shape"
bad_lock "b.json $(printf '%s' "$b" | tr a-f A-F) file://$srv/b.json" "an upper-case sha256" "$shape"
bad_lock "b.json g${b#?} file://$srv/b.json" "a sha256 that is not hex" "$shape"
bad_lock "sub/b.json $b file://$srv/b.json" "a name with a slash" "$shape"
bad_lock ".. $b file://$srv/b.json" "the name .." "$shape"
bad_lock "b.json $b http://example.com/b.json" "a plain http URL" "$shape"
bad_lock "b.json $b ftp://example.com/b.json" "an ftp URL" "$shape"
bad_lock "a.json $a file://$srv/a.json" "a name twice" "a.json is named twice"
bad_lock "a.json.part $b file://$srv/b.json" "a name ending in .part" "$shape"

# 11. A lock that names no file is refused.
printf '# nothing\n\n' > "$scratch/files.lock"
if ! run && grep -q "^fetch-bench-files: $scratch/files.lock names no file$" "$scratch/out"; then
  pass "a lock that names no file is refused"
else
  fail "a lock that names no file is refused"; cat "$scratch/out" >&2
fi

# 12. --list prints the lock's names in its order, and fetches, writes and
#     checks nothing. On a malformed lock it prints no name and fails.
good_lock
rm -rf "$dest"
if run --list && [ "$(cat "$scratch/out")" = "$(printf 'a.json\nb.json\ngen.json')" ] \
   && [ ! -e "$dest" ]; then
  pass "--list prints the names, in order, and touches nothing"
else
  fail "--list prints the names, in order, and touches nothing"; cat "$scratch/out" >&2
fi
printf 'a.json %s file://%s/a.json\nb.json\n' "$a" "$srv" > "$scratch/files.lock"
if ! BENCH_LOCK=$scratch/files.lock BENCH_DEST=$dest "$script" --list > "$scratch/out" 2>/dev/null \
   && [ ! -s "$scratch/out" ]; then
  pass "--list on a malformed lock prints no name, and fails"
else
  fail "--list on a malformed lock prints no name, and fails"; cat "$scratch/out" >&2
fi
printf '# nothing\n' > "$scratch/files.lock"
if ! run --list && grep -q "^fetch-bench-files: $scratch/files.lock names no file$" "$scratch/out"; then
  pass "--list on a lock that names no file fails"
else
  fail "--list on a lock that names no file fails"; cat "$scratch/out" >&2
fi

# 13. --check creates nothing: with no destination directory, it fails, and
#     there is still none.
good_lock
rm -rf "$dest"
if ! run --check && [ ! -e "$dest" ]; then
  pass "--check creates no directory"
else
  fail "--check creates no directory"; cat "$scratch/out" >&2
fi

# 14. An argument other than --check or --list, or a second argument, is a
#     usage error, exit 2.
good_lock
for args in "--fetch" "--check --check" "--list --check"; do
  # shellcheck disable=SC2086
  run $args; rc=$?
  if [ "$rc" -eq 2 ] && grep -q '^usage: fetch-bench-files \[--check | --list\]$' "$scratch/out"; then
    pass "'$args' is a usage error"
  else
    fail "'$args' is a usage error (exit $rc)"; cat "$scratch/out" >&2
  fi
done

if [ "$fails" -eq 0 ]; then
  echo "fetch-bench-files: all checks passed"
else
  echo "fetch-bench-files: $fails check(s) failed" >&2
  exit 1
fi
