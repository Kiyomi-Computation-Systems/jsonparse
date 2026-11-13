#!/bin/sh
# tests/check-akku-publish.sh [SCRIPT]: what scripts/akku-publish promises,
# checked with nothing leaving the machine (ADR-0022, Decision 8). `make
# check-akku-publish` runs it on the host. It needs git, gpg and Akku 1.2.0
# under build/akku-tool (make akku-deps), but no network. SCRIPT, a path
# from the repository root, is scripts/akku-publish unless given.
#
# Each case copies SCRIPT into a scratch tree of its own, beside a copy of
# scripts/akku and a link to build/akku-tool, so the real Akku 1.2.0 runs.
# Around it are:
#
#   - a scratch GnuPG home with two secret keys: a default key, which a bare
#     `gpg --sign` picks, as on the owner's host, and a release key with a
#     signing subkey, named to the script by AKKU_PUBLISH_RELEASE_KEY;
#   - a git config of its own, for every git command here, whose insteadOf
#     sends the manifest's location to a scratch repository, tagged as each
#     case needs;
#   - a curl first on PATH that keeps each upload and sends nothing: the
#     archive that takes nothing. A proxy that leads nowhere backs it up.
#
# The cases:
#
#   1. a release is published: the .key, .sig and .akku go to the archive in
#      that order, the signature is the release key's, the key file holds
#      that key alone, and the index entry is locked to the tag's commit at
#      the manifest's location. The script says the key isn't Kiyomi's;
#   2. answering n at Akku's prompt, once Akku has written the entry, signs
#      and sends nothing, and a run after it, over its work, publishes;
#   3. a probe signature that isn't the release key's alone stops the script
#      before it clones;
#   4. a tag the repository lacks stops it before anything is signed;
#   5. a tag whose Akku.manifest gives another version stops it before Akku
#      runs;
#   6. a manifest with no jsonparse version, or no location, is refused;
#   7. with no Akku 1.2.0, it says to run make akku-deps;
#   8. if Akku signs with another key, or with two, or signs nothing, the
#      script fails;
#   9. with no AKKU_PUBLISH_RELEASE_KEY, gpg is asked for the Kiyomi
#      Computation Systems release key, and the script stops where gpg fails;
#      and with the real Akku.manifest the script names the repository on
#      GitHub.
set -u
cd "$(dirname "$0")/.."
root=$PWD
script=$root/${1:-scripts/akku-publish}

kiyomi=CC2923E50902E936049B696B9EBA259B8EAC5130
github=https://github.com/Kiyomi-Computation-Systems/jsonparse.git
archive=https://akkuscm.org/packages/
url=https://example.invalid/jsonparse.git
version=7.8.9
record=jsonparse_$version.akku

if [ ! -f "$root/build/akku-tool/akku/akku-1.2.0.src/lib/akku/bin/akku.sps" ]; then
  echo "check-akku-publish: no Akku 1.2.0 under build/akku-tool: run 'make akku-deps' first" >&2
  exit 1
fi
real_gpg=$(command -v gpg) || { echo "check-akku-publish: gpg not found" >&2; exit 1; }

# Under /tmp, not TMPDIR: gpg-agent's sockets live in the GnuPG home, and
# macOS's TMPDIR is long enough to pass the socket path limit.
s=$(mktemp -d /tmp/akku-publish.XXXXXX) || exit 1
gh=$s/gnupg
work=$s/tree/build/akku-publish
trap 'GNUPGHOME="$gh" gpgconf --kill all 2>/dev/null; rm -rf "$s"' EXIT
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1" >&2; fails=$((fails + 1)); }

# key NAME: makes a signing key with no passphrase, and prints its
# fingerprint.
key() {
  GNUPGHOME=$gh "$real_gpg" --batch --quiet --pinentry-mode loopback --passphrase '' \
    --quick-gen-key "$1 <$1@example.invalid>" ed25519 sign never 2>/dev/null
  GNUPGHOME=$gh "$real_gpg" --batch --with-colons --list-secret-keys "$1@example.invalid" 2>/dev/null |
    awk -F: '$1 == "fpr" { print $10; exit }'
}

# signer FILE SIG: the primary key fingerprint that made SIG over FILE, one
# line for each signature.
signer() {
  GNUPGHOME=$gh "$real_gpg" --status-fd 1 --verify "$2" "$1" 2>/dev/null |
    awk '$2 == "VALIDSIG" { print $NF }'
}

# signing_key FILE SIG: the fingerprint of the key, or subkey, that made SIG.
signing_key() {
  GNUPGHOME=$gh "$real_gpg" --status-fd 1 --verify "$2" "$1" 2>/dev/null |
    awk '$2 == "VALIDSIG" { print $3 }'
}

mkdir -m 700 "$gh"
default=$(key default)
release=$(key release)
GNUPGHOME=$gh "$real_gpg" --batch --quiet --pinentry-mode loopback --passphrase '' \
  --quick-add-key "$release" ed25519 sign never 2>/dev/null

# The fixture's traps. A bare gpg --sign takes the default key: without
# that, case 1 would pass with no wrapper at all. And the release key signs
# with its subkey, whose fingerprint isn't the key's.
echo probe > "$s/probe"
GNUPGHOME=$gh "$real_gpg" --batch --sign --detach --no-armor -o "$s/probe.sig" "$s/probe" 2>/dev/null
GNUPGHOME=$gh "$real_gpg" --batch --sign --detach --no-armor --local-user "$release" \
  -o "$s/probe.release.sig" "$s/probe" 2>/dev/null
subkey=$(signing_key "$s/probe" "$s/probe.release.sig")
if [ -n "$default" ] && [ -n "$release" ] && [ "$default" != "$release" ] \
   && [ "$(signer "$s/probe" "$s/probe.sig")" = "$default" ] \
   && [ "$(signer "$s/probe" "$s/probe.release.sig")" = "$release" ] \
   && [ -n "$subkey" ] && [ "$subkey" != "$release" ]; then
  pass "the fixture: a bare gpg --sign takes the default key, and the release key signs with its subkey"
else
  fail "the fixture: a bare gpg --sign takes the default key, and the release key signs with its subkey"
  exit 1
fi

cat > "$s/gitconfig" <<EOF
[user]
	name = check-akku-publish
	email = check-akku-publish@example.invalid
[init]
	defaultBranch = main
[url "file://$s/origin.git"]
	insteadOf = $url
[url "file://$s/empty.git"]
	insteadOf = $github
EOF
# Every git command here, the fixture's and the script's, reads this config
# alone, not the caller's: no identity or commit signing from it.
GIT_CONFIG_GLOBAL=$s/gitconfig
GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM
git init -q --bare "$s/empty.git"

# The archive that takes nothing.
mkdir "$s/bin"
cat > "$s/bin/curl" <<EOF
#!/bin/sh
# Akku uploads with curl -sS --upload-file FILE URL. This keeps FILE, in
# order, and the URL, and sends nothing.
args=\$*
file= url=
while [ \$# -gt 0 ]; do
  case \$1 in
    --upload-file) file=\$2; shift 2 ;;
    -*) shift ;;
    *) url=\$1; shift ;;
  esac
done
[ -n "\$file" ] || { echo "curl stub: not an upload: \$args" >&2; exit 1; }
n=\$(wc -l < "$s/uploads.log" | tr -d ' ')
cp "\$file" "$s/uploads/\$n-\${file##*/}"
echo "\$url \${file##*/}" >> "$s/uploads.log"
echo "curl stub: kept \${file##*/}"
EOF
chmod 755 "$s/bin/curl"

# manifest VERSION LOCATION: an Akku.manifest for jsonparse VERSION, with
# the line LOCATION, which may be empty. A location in a comment comes
# first, and isn't the location.
manifest() {
  cat <<EOF
#!r6rs ; -*- scheme -*-
(import (akku format manifest))
;; (location (git "https://example.invalid/not-this.git"))
(akku-package ("jsonparse" "$1")
  (synopsis "A synopsis")
  (description "A description.")
  (authors "An Author")
  (homepage "https://example.invalid/home")
$2
  (license "BSD-3-Clause")
  (depends ("byte-machine" "^0.9.0")))
EOF
}
location="  (location (git \"$url\"))"

# origin TAG VERSION: the scratch repository. Its release commit's
# Akku.manifest gives VERSION, and is tagged TAG, annotated, unless TAG is
# empty. main has moved on since, to 7.9.0, so only a clone at the tag
# publishes the release.
origin() {
  rm -rf "$s/origin.git" "$s/src"
  git init -q "$s/src"
  manifest "$2" "$location" > "$s/src/Akku.manifest"
  git -C "$s/src" add Akku.manifest
  git -C "$s/src" commit -q -m release
  if [ -n "$1" ]; then git -C "$s/src" tag -a "$1" -m "$1"; fi
  manifest 7.9.0 "$location" > "$s/src/Akku.manifest"
  git -C "$s/src" commit -q -a -m "after the release"
  git clone -q --bare "$s/src" "$s/origin.git"
}

# tree: a scratch tree with SCRIPT, scripts/akku, a link to build/akku-tool,
# and stdin as its Akku.manifest.
tree() {
  rm -rf "$s/tree"
  mkdir -p "$s/tree/scripts" "$s/tree/build"
  cp "$script" "$s/tree/scripts/akku-publish"
  cp "$root/scripts/akku" "$s/tree/scripts/akku"
  ln -s "$root/build/akku-tool" "$s/tree/build/akku-tool"
  cat > "$s/tree/Akku.manifest"
}

# run ANSWER KEY: the script in the scratch tree, with ANSWER at Akku's
# prompt, and AKKU_PUBLISH_RELEASE_KEY set to KEY, or unset if KEY is
# empty. Its output goes to $s/out, its exit status to $status. The script's
# work directory is gone before each run, so what a case finds there, this
# run made, unless keep_work is 1.
keep_work=0
run() {
  answer=$1
  if [ -n "$2" ]; then
    set -- env AKKU_PUBLISH_RELEASE_KEY="$2"
  else
    set -- env -u AKKU_PUBLISH_RELEASE_KEY
  fi
  rm -rf "$s/uploads"
  if [ "$keep_work" -ne 1 ]; then rm -rf "$work"; fi
  mkdir "$s/uploads"
  : > "$s/uploads.log"
  printf '%s\n' "$answer" |
    "$@" GNUPGHOME="$gh" PATH="$s/bin:$PATH" LC_ALL=C \
      https_proxy=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9 \
      all_proxy=http://127.0.0.1:9 ALL_PROXY=http://127.0.0.1:9 \
      sh "$s/tree/scripts/akku-publish" > "$s/out" 2>&1
  status=$?
}

has() { grep -Fxq -- "$1" "$s/out"; }
sent_nothing() { [ ! -s "$s/uploads.log" ]; }
show() { echo "  exit $status; output:" >&2; sed 's/^/    /' "$s/out" >&2; }

# 1. A release is published.
origin "v$version" "$version"
manifest "$version" "$location" | tree
run y "$release"
rev=$(git --git-dir="$s/origin.git" rev-parse "v$version^{commit}")
want_uploads="$archive $record.key
$archive $record.sig
$archive $record"
want_record="#!r6rs
;; Submit-To: $archive
(package
  (name \"jsonparse\")
  (versions
    ((version \"$version\") (synopsis \"A synopsis\") (description \"A description.\")
      (authors \"An Author\")
      (homepage \"https://example.invalid/home\")
      (license \"BSD-3-Clause\")
      (lock
        (location (git \"$url\"))
        (tag \"v$version\")
        (revision \"$rev\"))
      (depends (\"byte-machine\" \"^0.9.0\")) (depends/dev)
      (conflicts))))"
key_fprs=$(GNUPGHOME=$gh "$real_gpg" --with-colons --show-keys "$s/uploads/0-$record.key" 2>/dev/null |
  awk -F: '$1 == "pub" { primary = 1; next } primary && $1 == "fpr" { print $10; primary = 0 }')
if [ "$status" -eq 0 ] \
   && [ "$(cat "$s/uploads.log")" = "$want_uploads" ] \
   && [ "$(signer "$s/uploads/2-$record" "$s/uploads/1-$record.sig")" = "$release" ] \
   && [ "$key_fprs" = "$release" ] \
   && [ "$(cat "$s/uploads/2-$record")" = "$want_record" ] \
   && has "akku-publish: AKKU_PUBLISH_RELEASE_KEY names $release, not the Kiyomi Computation Systems release key" \
   && has "akku-publish: sent jsonparse $version from v$version, signed by $release."; then
  pass "a release is published: its key, signature and entry, signed by the release key and locked to the tag"
else
  fail "a release is published: its key, signature and entry, signed by the release key and locked to the tag"
  show
  echo "  uploads:" >&2; sed 's/^/    /' "$s/uploads.log" >&2
  for f in "$s"/uploads/*.akku; do
    [ -f "$f" ] && { echo "  $f:" >&2; sed 's/^/    /' "$f" >&2; }
  done
fi

# 2. Answering n sends nothing, and Akku signs nothing. Akku writes the
#    entry just before it asks.
run n "$release"
if [ "$status" -ne 0 ] && sent_nothing && [ -f "$work/jsonparse/$record" ] \
   && [ ! -e "$work/jsonparse/$record.sig" ]; then
  pass "answering n at Akku's prompt signs and sends nothing"
else
  fail "answering n at Akku's prompt signs and sends nothing"; show
fi
keep_work=1
run y "$release"
keep_work=0
if [ "$status" -eq 0 ] && [ "$(cat "$s/uploads.log")" = "$want_uploads" ] \
   && [ "$(signer "$s/uploads/2-$record" "$s/uploads/1-$record.sig")" = "$release" ]; then
  pass "answering y after n, over the first run's work, publishes"
else
  fail "answering y after n, over the first run's work, publishes"; show
fi

# 3. A probe signature that isn't the release key's: the long key ID names
#    the release key to gpg, but its signature names the fingerprint.
id=$(printf '%s\n' "$release" | cut -c25-40)
run y "$id"
if [ "$status" -eq 1 ] && sent_nothing && [ ! -e "$work/jsonparse" ] \
   && has "akku-publish: the probe was not signed by $id; nothing was published"; then
  pass "a probe signature that isn't the release key's stops the script before it clones"
else
  fail "a probe signature that isn't the release key's stops the script before it clones"; show
fi
# A gpg.conf whose local-user adds a second signature to every one.
echo "local-user $default" > "$gh/gpg.conf"
run y "$release"
rm "$gh/gpg.conf"
if [ "$status" -eq 1 ] && sent_nothing && [ ! -e "$work/jsonparse" ] \
   && has "akku-publish: the probe was not signed by $release; nothing was published"; then
  pass "a probe signed by the release key and another stops the script before it clones"
else
  fail "a probe signed by the release key and another stops the script before it clones"; show
fi

# 4. A tag the repository lacks.
origin "" "$version"
run y "$release"
if [ "$status" -eq 1 ] && sent_nothing && [ ! -e "$work" ] \
   && has "akku-publish: $url has no tag v$version: tag the release and push the tag first"; then
  pass "a tag the repository lacks stops the script before anything is signed"
else
  fail "a tag the repository lacks stops the script before anything is signed"; show
fi

# 5. A tag whose Akku.manifest gives another version.
origin "v$version" 7.8.8
run y "$release"
if [ "$status" -eq 1 ] && sent_nothing && [ ! -e "$work/jsonparse/$record" ] \
   && has "akku-publish: v$version's Akku.manifest gives jsonparse '7.8.8', not $version; nothing was published"; then
  pass "a tag whose Akku.manifest gives another version stops the script before Akku runs"
else
  fail "a tag whose Akku.manifest gives another version stops the script before Akku runs"; show
fi

# 6. A manifest with no jsonparse version, or no location.
origin "v$version" "$version"
manifest "$version" "$location" | sed 's/("jsonparse" /("other" /' | tree
run y "$release"
if [ "$status" -eq 1 ] && sent_nothing && has "akku-publish: Akku.manifest gives jsonparse no version"; then
  pass "a manifest with no jsonparse version is refused"
else
  fail "a manifest with no jsonparse version is refused"; show
fi
manifest "$version" "" | tree
run y "$release"
if [ "$status" -eq 1 ] && sent_nothing \
   && has "akku-publish: Akku.manifest gives no (location (git URL)), the repository to publish"; then
  pass "a manifest with no location is refused"
else
  fail "a manifest with no location is refused"; show
fi

# 7. No Akku 1.2.0.
manifest "$version" "$location" | tree
rm "$s/tree/build/akku-tool"
run y "$release"
if [ "$status" -eq 1 ] && sent_nothing \
   && has "akku-publish: no Akku 1.2.0 under build/akku-tool: run 'make akku-deps' first"; then
  pass "with no Akku 1.2.0, the script says to run make akku-deps"
else
  fail "with no Akku 1.2.0, the script says to run make akku-deps"; show
fi

# 8. An Akku that signs with gpg's default key, then one that signs nothing.
#    Each stands in for scripts/akku, in the clone.
manifest "$version" "$location" | tree
cat > "$s/tree/scripts/akku" <<EOF
#!/bin/sh
echo record > $record
"$real_gpg" --batch --sign --detach --no-armor $record
EOF
run y "$release"
if [ "$status" -eq 1 ] \
   && has "akku-publish: $record.sig was not made by $release: tell the archive's maintainer"; then
  pass "an Akku that signs with another key fails the script"
else
  fail "an Akku that signs with another key fails the script"; show
fi
printf '#!/bin/sh\necho record > %s\n"%s" --batch --sign --detach --no-armor --local-user %s --local-user %s %s\n' \
  "$record" "$real_gpg" "$release" "$default" "$record" > "$s/tree/scripts/akku"
run y "$release"
if [ "$status" -eq 1 ] \
   && has "akku-publish: $record.sig was not made by $release: tell the archive's maintainer"; then
  pass "an Akku that signs with the release key and another fails the script"
else
  fail "an Akku that signs with the release key and another fails the script"; show
fi
printf '#!/bin/sh\nexit 0\n' > "$s/tree/scripts/akku"
run y "$release"
if [ "$status" -eq 1 ] && has "akku-publish: no $record.sig: akku published nothing"; then
  pass "an Akku that signs nothing fails the script"
else
  fail "an Akku that signs nothing fails the script"; show
fi

# 9. With no AKKU_PUBLISH_RELEASE_KEY, gpg is asked for the Kiyomi key,
#    which the scratch GnuPG home lacks, so gpg fails and the script stops
#    with gpg's status, 2. Then the real Akku.manifest, whose location the
#    git config sends to a repository with no tags.
manifest "$version" "$location" | tree
run y ""
if [ "$status" -eq 2 ] && sent_nothing && [ ! -e "$work/jsonparse" ] \
   && [ "$(sed -n 1p "$s/out")" = "akku-publish: checking that the gpg akku will run signs with $kiyomi" ] \
   && has "gpg: skipped \"$kiyomi\": No secret key"; then
  pass "with no AKKU_PUBLISH_RELEASE_KEY, gpg is asked for the Kiyomi Computation Systems key"
else
  fail "with no AKKU_PUBLISH_RELEASE_KEY, gpg is asked for the Kiyomi Computation Systems key"; show
fi
real_version=$(sed -n 's/^(akku-package ("jsonparse" "\([^"]*\)").*/\1/p' "$root/Akku.manifest")
tree < "$root/Akku.manifest"
run y "$release"
if [ -n "$real_version" ] && [ "$status" -eq 1 ] && sent_nothing \
   && has "akku-publish: $github has no tag v$real_version: tag the release and push the tag first"; then
  pass "with the real Akku.manifest, the script names the repository on GitHub"
else
  fail "with the real Akku.manifest, the script names the repository on GitHub"; show
fi

if [ "$fails" -eq 0 ]; then
  echo "check-akku-publish: all checks passed"
else
  echo "check-akku-publish: $fails check(s) failed" >&2
  exit 1
fi
