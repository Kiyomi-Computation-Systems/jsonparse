#!/bin/sh
# scripts/ci/build-chez.sh PREFIX
#
# Builds threaded Chez Scheme 10.4.1, jsonparse's floor, from its
# release tarball and installs it into PREFIX, for .github/workflows/ci.yml:
# Ubuntu's Chez is below the floor. The tarball is checked against the
# sha256 pinned below before anything is unpacked, so a release asset that
# changed fails here; a tag can move, and a sum cannot. Afterwards it asks
# the installed scheme for its version and (threaded?), and fails unless
# they are 10.4.1 and yes: a build that came out other than it was
# configured is no build.
#
# PREFIX must be an absolute path. Nothing is installed outside it.
#
# Moving the floor is a reviewed change: fetch the new release tarball,
# compare its sha256 with the digest the GitHub releases API lists for the
# asset, and change version and sum below together, with manifest.scm, the
# workflow's CHEZ_FLOOR_VERSION and .plans/global-constraints.md (ADR-0008).
set -eu

version=10.4.1
sum=2e74952db7bc177f0c3602e2217a341ba677d733eec4cd7726418c3a4e1ef308

[ "$#" -eq 1 ] || { echo "usage: build-chez.sh PREFIX" >&2; exit 2; }
prefix=$1
case $prefix in
  /?*) ;;
  *) echo "build-chez.sh: PREFIX must be an absolute path, not '$prefix'" >&2; exit 2 ;;
esac

work=$(mktemp -d "${TMPDIR:-/tmp}/build-chez.XXXXXX")
trap 'rm -rf "$work"' EXIT

tarball=$work/csv$version.tar.gz
curl -fsSL --retry 3 -o "$tarball" \
  "https://github.com/cisco/ChezScheme/releases/download/v$version/csv$version.tar.gz"

got=$(sha256sum "$tarball" | awk '{ print $1 }')
if [ "$got" != "$sum" ]; then
  echo "build-chez.sh: csv$version.tar.gz has sha256 $got, but this script pins $sum" >&2
  exit 1
fi

tar xzf "$tarball" -C "$work"
cd "$work/csv$version"

# --disable-x11 --disable-curses: the expeditor, Chez's line editor, then
# needs no X11 or curses headers, and CI only runs Chez with --program and
# --script. The make is serial: a parallel make races the bootstrap.
./configure --threads --disable-x11 --disable-curses --installprefix="$prefix"
make
make install

# Ask what was built. scheme-version-number answers three values, major,
# minor and patch; a threaded build answers #t to (threaded?).
probe=$work/probe.ss
cat >"$probe" <<'EOF'
(let-values (((major minor patch) (scheme-version-number)))
  (display (list major minor patch (if (threaded?) 'yes 'no))))
EOF
asked=$("$prefix/bin/scheme" --script "$probe")
expected="($(printf '%s' "$version" | tr . ' ') yes)"
if [ "$asked" != "$expected" ]; then
  echo "build-chez.sh: the installed $prefix/bin/scheme answers $asked, but (scheme-version-number) and (threaded?) should answer $expected" >&2
  exit 1
fi
echo "build-chez.sh: Chez $version built --threads into $prefix: $asked"
