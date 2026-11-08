#!/bin/sh
# tests/check-akku.sh archive DIR
# tests/check-akku.sh install DIR
#
# Installs this package with Akku 1.2.0 the way a consumer would, and checks
# what lands on the consumer's library path (ADR-0022). `make check-akku`
# runs both phases; it is chez-httparse's check, split in two, because the
# archives need git and the container has none (ADR-0008).
#
# archive DIR, on the host or in CI, with git: writes DIR/jsonparse.tar and
# DIR/<dep>.tar for each dependency Akku.manifest's depends clause names,
# from its submodule at vendor/<dep>, and DIR/src-libraries.txt, the .sls
# files git tracks under src/. Each is `git archive` of a working
# tree's tracked files as they are on disk, which is what Akku's archive
# serves for a tag (byte-machine 0.8.0's archive and `git archive v0.8.0`
# hold the same 210 files): .gitattributes' export-ignore rules apply, and
# `git stash create` snapshots uncommitted edits to tracked files, and new
# files once `git add`ed.
#
# install DIR, in the container or anywhere, with no git and no network:
#
#   0. the archive is the working tree: its Akku.manifest and src/ are the
#      tree's, so an archive of another commit cannot pass. It leaves out
#      the design records and agent instructions (.plans, AGENTS.md) and
#      holds the generated parser. The suites ship;
#   1. `akku install`, from a consumer project whose Akku.lock points at
#      the unpacked archives, puts on the library path exactly the libraries
#      git tracks under src/, and the LICENSE as a notice: no test, site or
#      grammar library, and no program. A library the archive leaves out
#      fails here too;
#   2. every dependency installs a library;
#   3. tests/akku-consumer.sps, run with only the library path that
#      .akku/bin/activate sets, reads, builds and writes JSON.
#
# It runs Akku through scripts/akku, and Chez as $CHEZ.
set -eu

fail() { echo "check-akku: $*" >&2; exit 1; }

[ "$#" -eq 2 ] || { echo "usage: check-akku.sh archive|install DIR" >&2; exit 2; }
phase=$1
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$2"
dest=$(cd "$2" && pwd)
CHEZ=${CHEZ:-scheme}

# archive_of SRC DEST: `git archive` of SRC's tracked files as they are on
# disk, written to DEST. `git stash create` commits the working tree
# without touching it, and prints nothing when the tree is clean. A
# pipeline's status is its last command's, so the archive goes to a file.
archive_of() {
  ref=$(git -C "$1" stash create)
  git -C "$1" archive --format=tar "${ref:-HEAD}" > "$2"
}

case $phase in
archive)
  command -v git >/dev/null 2>&1 || fail "the archive phase needs git, so it runs on the host or in CI"
  archive_of "$root" "$dest/jsonparse.tar"
  git -C "$root" ls-files -- 'src/*.sls' > "$dest/src-libraries.txt"
  deps=$(sed -n 's/^ *(depends ("\([^"]*\)".*/\1/p' "$root/Akku.manifest")
  for dep in $deps; do
    [ -e "$root/vendor/$dep/.git" ] ||
      fail "dependency $dep is not checked out at vendor/$dep: run 'make submodules' on the host"
    archive_of "$root/vendor/$dep" "$dest/$dep.tar"
  done
  echo "check-akku: wrote the archives Akku would serve for jsonparse and $deps to $dest"
  ;;
install)
  [ -f "$dest/jsonparse.tar" ] || fail "no $dest/jsonparse.tar: the archive phase runs first (make check-akku)"
  [ -s "$dest/src-libraries.txt" ] || fail "no $dest/src-libraries.txt: the archive phase runs first (make check-akku)"
  work=$dest/run
  rm -rf "$work"
  mkdir -p "$work/pkg/jsonparse" "$work/consumer"
  tar -xf "$dest/jsonparse.tar" -C "$work/pkg/jsonparse"

  # 0. What the archive ships.
  tar -tf "$dest/jsonparse.tar" > "$work/archive.txt"
  awk -F/ '!seen[$1]++ { print $1 }' "$work/archive.txt" > "$work/archive-top.txt"
  for record in .plans AGENTS.md; do
    ! grep -qxF "$record" "$work/archive-top.txt" ||
      fail "the package would ship $record; .gitattributes must mark it export-ignore"
  done
  grep -qxF src/generated/jsonparse.sls "$work/archive.txt" ||
    fail "the archive holds no src/generated/jsonparse.sls, so it cannot be what the package is built from"
  cmp -s "$work/pkg/jsonparse/Akku.manifest" "$root/Akku.manifest" ||
    fail "the archive's Akku.manifest is not the working tree's, so the archive is of another tree"
  diff -r "$work/pkg/jsonparse/src" "$root/src" > "$work/src.diff" ||
    { cat "$work/src.diff" >&2; fail "the archive's src/ is not the working tree's, so the archive is of another tree"; }

  # The package's name and version, then one dependency per line, read from
  # the archive's own Akku.manifest as data.
  cat > "$work/manifest.ss" <<'EOF'
(with-input-from-file "Akku.manifest"
  (lambda ()
    (let loop ()
      (let ((d (read)))
        (cond ((eof-object? d) (error 'check-akku "no akku-package form"))
              ((and (pair? d) (eq? (car d) 'akku-package))
               (display (car (cadr d))) (display " ")
               (display (cadr (cadr d))) (newline)
               (for-each (lambda (dep) (display (car dep)) (newline))
                         (cond ((assq 'depends (cddr d)) => cdr)
                               (else '()))))
              (else (loop)))))))
EOF
  manifest=$(cd "$work/pkg/jsonparse" && "$CHEZ" -q --script "$work/manifest.ss")
  package=$(echo "$manifest" | sed -n '1s/ .*//p')
  version=$(echo "$manifest" | sed -n '1s/.* //p')
  depends=$(echo "$manifest" | sed '1d')
  [ "$package" = jsonparse ] || fail "the archive's Akku.manifest names the package '$package', not jsonparse"

  lock="((name \"$package\") (location (directory \"$work/pkg/$package\")))"
  for dep in $depends; do
    [ -f "$dest/$dep.tar" ] ||
      fail "no $dest/$dep.tar for the dependency $dep: the archive phase runs first (make check-akku)"
    sub=$work/pkg/$package/vendor/$dep
    [ -d "$sub" ] && [ -z "$(ls -A "$sub")" ] ||
      fail "vendor/$dep in the archive is not an empty directory, as git archives a submodule"
    mkdir -p "$work/pkg/$dep"
    tar -xf "$dest/$dep.tar" -C "$work/pkg/$dep"
    lock="$lock ((name \"$dep\") (location (directory \"$work/pkg/$dep\")))"
  done

  cd "$work/consumer"
  cat > Akku.manifest <<EOF
#!r6rs
(import (akku format manifest))
(akku-package ("check-akku-consumer" "0.0.0")
  (synopsis "check-akku's consumer") (authors "check-akku") (license "MIT")
  (depends ("$package" "^$version")))
EOF
  cat > Akku.lock <<EOF
#!r6rs
(import (akku format lockfile))
(projects $lock)
EOF

  echo "check-akku: installing $package $version and its dependencies: $depends"
  "$root/scripts/akku" install > install.log 2>&1 || { cat install.log >&2; fail "akku install failed"; }

  # 1. What this package installs: exactly the libraries git tracks under
  # src/, and its LICENSE.
  awk -F '\t' -v p="$package" '$2 == p { print $1 "\t" $3 }' .akku/list | sort > installed.txt
  { awk '/^src\/.*\.sls$/ { sub(/^src\//, ""); print ".akku/lib/" $0 "\tr6rs-library" }' "$dest/src-libraries.txt"
    printf '.akku/notices/%s/LICENSE\tlegal-notice-file\n' "$package"; } | sort > expected.txt
  diff -u expected.txt installed.txt > installed.diff ||
    { cat installed.diff >&2; fail "$package installs other files than src/'s libraries and its LICENSE (- missing, + extra)"; }

  # 2. Each dependency installed a library.
  for dep in $depends; do
    awk -F '\t' -v p="$dep" '$2 == p && $3 == "r6rs-library"' .akku/list | grep -q . ||
      fail "the dependency $dep installed no library"
  done

  # 3. A consumer reads, builds and writes JSON with only Akku's library
  # path. activate starts from R6RS_PATH, so that and R7RS_PATH are cleared
  # too. The single quotes are deliberate: $0 is expanded by the inner
  # shell.
  cp "$root/tests/akku-consumer.sps" akku-consumer.sps
  # shellcheck disable=SC2016
  out=$(env -u CHEZSCHEMELIBDIRS -u CHEZSCHEMELIBEXTS -u R6RS_PATH -u R7RS_PATH \
          sh -c '. .akku/bin/activate && exec "$0" --program akku-consumer.sps' "$CHEZ") ||
    fail "akku-consumer.sps failed with Akku's library path"
  want='{"name":"Ada","langs":["en","fr"]} fr'
  [ "$out" = "$want" ] || fail "akku-consumer.sps printed '$out', not '$want'"

  echo "check-akku: no design records in the archive, $(grep -c 'r6rs-library' installed.txt) libraries from src/ and the LICENSE installed, and a consumer read and wrote JSON"
  ;;
*)
  echo "usage: check-akku.sh archive|install DIR" >&2
  exit 2
  ;;
esac
