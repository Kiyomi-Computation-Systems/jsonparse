# ADR-0022: The first release is 0.1.0, packaged with Akku 1.2.0

- **Status:** Accepted, revised on 2026-11-08 and 2026-11-13
- **Date:** 2026-11-08
- **Scope:** the version and how it moves; the Akku package and what it
  ships; Akku itself; `make check-akku`, `make check-release` and
  `scripts/akku-publish`; `CHANGELOG.md`, `README.org` and
  `docs/installing.md`
- **Related:** ADR-0002, ADR-0003, ADR-0008, ADR-0012, ADR-0021, ADR-0023,
  ADR-0026; the plan's M5

> **Revision (2026-11-08, slice 11).** `.akkuignore` lists `bench` too
> (ADR-0023), and it matters as `site` and `grammar` do: without it the
> benchmark harness's two libraries land on every consumer's path, and
> `make check-akku` fails. The benchmarks ship in the archive, as the
> suites do.

> **Revision (2026-11-13, slice 18).** 0.2.0 follows Decision 7, but
> differs from these records in two ways.
>
> - **Its minor version comes from byte-machine's range, not its ABI.**
>   Decision 1 had M3's run node bump the ABI and so bring 0.2.0. The run
>   loop came at ABI 9 instead (ADR-0026, Decisions 2 and 3). 0.2.0 declares
>   byte-machine `^0.9.0`, which Akku reads as `>=0.9.0 <0.10.0`, so it
>   shares no version with 0.1.0's `^0.8.0` (ADR-0026, Decision 5). Akku
>   installs one byte-machine per project, so no project can hold 0.2.0 and
>   a library on `^0.8.0` at once. Its API is 0.1.0's.
>
>   I asked the owner whether the version rule should also say that moving
>   to a new byte-machine 0.x means a new minor version. On 2026-11-13 they
>   said "yes update the version rule". Decision 1's rule now reads: a new
>   minor version comes with a new byte-machine runtime ABI or a move to a
>   new byte-machine 0.x, such as from `^0.8.0` to `^0.9.0`. The
>   CHANGELOG's header, `Akku.manifest`'s comment and the global
>   constraints say so.
> - **Publishing to Akku waits again, so step 4 is skipped.** On 2026-11-12
>   the owner chose "Tag now, Akku later": "Release 0.2.0 on GitHub and the
>   docs site now; write the akku-publish test, then publish to Akku once
>   the siblings are on byte-machine 0.9."
>   - The test is Decision 8's.
>   - Of the siblings, chez-httparse 0.6.0 and chez-uri 0.9.0 declare
>     `^0.9.0`. chez-http-server 0.10.0 still declares `^0.8.0`, on its
>     `main` of 2026-11-13.
>   - Until then the docs lead with a checkout, as Decision 8 says.
>
> The archive is now 0.6 MB gzipped, 602,584 bytes against 504,349 at
> `v0.1.0`. `bench/`, which ships too, is 48,839 of them. macOS has no CI,
> so the owner runs `make test` on the M1 laptop before the merge.

## Context

M1 is done: every lane and exit criterion is met, the API has a guide and a
reference, and the site renders (ADR-0021). The plan put the release in M5,
after M2 to M4. The owner chose on 2026-11-08 to release now.

The plan's M5 asks for versioning tied to byte-machine's ABI, an Akku
package checked by installing it as a consumer would, a Guix package, and a
note on migrating from chez-json. chez-httparse, the sibling the plan
names, released 0.5.0 on Akku with a `make check-akku` and a docs site.

Akku 1.2.0 came out on 2026-10-25, the first release since 1.1.0 in 2021.
Guix has 1.1.0, at the siblings' pin and in this host's current Guix, and
no sibling uses 1.2.0 yet. 1.2.0:

- **has a new archive signing key.** The archive signs with the old and the
  new key "during a transition period", so 1.1.0, which knows only the old
  one, stops verifying the index when it ends;
- **submits the public key with a package,** so no key server is needed;
- **downloads its index on first use,** as its release has none.

Akku serves a package as `git archive` of its tag: byte-machine 0.8.0's
archive and `git archive v0.8.0` hold the same 210 files.

## Decision

1. **The first release is 0.1.0, from M1, before M2 to M4.**
   - Semantic versioning: before 1.0 any release may change the API.
   - A new byte-machine runtime ABI means a new minor version. M3's run node
     bumps the ABI, and M2, if it is taken, shares that bump, so that
     byte-machine release brings jsonparse 0.2.0. This is how M5's
     "versioning tied to the byte-machine ABI" reads.
   - `make check-release` holds three places to one version:
     `Akku.manifest`'s, the newest release in `CHANGELOG.md`, and the home
     page's Status. `make test` runs it.
2. **M5's Guix package and chez-json note wait** for a later release.
3. **What the package ships:**
   - `.gitattributes` marks `.plans` and `AGENTS.md` `export-ignore`, as
     circuit's and chez-httparse's do. The suites, corpora and the site
     generator ship, as theirs do: the archive is 0.5 MB gzipped.
   - `.akkuignore` lists `.claude`, `.plans`, `.superpowers`, `AGENTS.md`,
     `build`, `grammar`, `site`, `tests` and `vendor`, in circuit's form.
     `site` and `grammar` matter: without either, its libraries land on
     every consumer's path. The rest change nothing today. Akku skips
     dot-directories and test paths itself, `AGENTS.md` is no library,
     `build` is not in the archive, and `vendor` holds only empty
     directories there. They stay in case Akku changes.
4. **Akku is 1.2.0,** its release for Chez Scheme.
   - `scripts/akku-tool.lock` pins its tarball by sha256, in Akku.lock's
     form.
   - `make akku-deps` fetches it on the host with
     `scripts/fetch-akku-lock`.
   - `scripts/akku` runs it from source on `$CHEZ`, with its data and cache
     under `build/`.
   - The tarball's signature was checked on 2026-11-08: Gwen Weinholt's key
     `35C5 2CA4 9767 2B40 0D46 1793 DD83 9B74 8F10 AD4D`, the same at
     keys.openpgp.org and keyring.debian.org.
5. **`make check-akku` installs the package as a consumer would.**
   - It is chez-httparse's check in two phases, since the archives need git
     and the container has none (ADR-0008).
   - On the host or in CI, git writes the archives Akku would serve, of
     this tree and of byte-machine at its pin, and the list of `src/`'s
     libraries.
   - The install needs neither git nor the network. On a Guix host it runs
     in the container, at the floor Chez. It checks that the archive is the
     working tree's and holds no `.plans` or `AGENTS.md`, that exactly
     `src/`'s libraries and the `LICENSE` land, that byte-machine installs,
     and that a consumer reads, builds and writes JSON with Akku's library
     path alone, with `R6RS_PATH` and `R7RS_PATH` cleared.
   - CI's `linux` job runs it on both architectures.
6. **`scripts/akku-publish` publishes,** run by the owner on the host once
   the tag is pushed.
   - It clones the repository fresh at the tag: `akku publish` refuses a
     worktree.
   - `akku publish` signs with a bare `gpg --sign`, and this host holds two
     secret keys. A `gpg` first on `PATH` adds `--local-user` with the Kiyomi
     Computation Systems release key,
     `CC29 23E5 0902 E936 049B 696B 9EBA 259B 8EAC 5130`.
   - The script signs a scratch file through that `gpg` first, and stops
     unless the release key made the signature. It stops too unless the
     tag's `Akku.manifest` gives the version it publishes. After publishing,
     it checks the submitted signature the same way.
   - Akku uploads with curl and doesn't fail on an HTTP error, so the owner
     reads the archive's replies, and checks `akku install jsonparse` in an
     empty directory once the index lists the version.
7. **Cutting a release:**
   1. The release PR merges with `make test`, `make check-akku` and the site
      green. `make check-release` holds `Akku.manifest`, `CHANGELOG.md` and
      the Status to one version, and the `CHANGELOG.md` heading carries the
      date the tag is made.
   2. `main` is tagged `v` and `Akku.manifest`'s version, and the tag pushed.
      `pages.yml` deploys the site.
   3. The repository's About link is set to the site once it is live.
   4. The owner runs `scripts/akku-publish`, then checks the install as in
      Decision 6.
8. **Publishing 0.1.0 to Akku waits,** by the owner's choice on 2026-11-08.
   - Until then, `docs/installing.md`, the home page and `README.org` lead
     with a checkout and say the Akku package is coming.
   - Before publishing, `scripts/akku-publish` gets a committed test: a
     scratch GnuPG home with a default key and a release key, and an
     archive that takes nothing. The slice 10 review ran exactly that by
     hand.
   - After publishing, the docs say `akku install jsonparse` on `main`, and
     the Pages workflow is run by hand from `main`, with no new tag.

## Consequences

- **`akku install jsonparse` works once the archive takes the submission**
  (Decision 8). Until then, a checkout works (`docs/installing.md`).
- **Akku 1.2.0 runs from `build/`,** so `make clean` means `make akku-deps`
  again, on the host.
- **The release's suites ship,** with their corpora and licenses, in every
  copy Akku serves and in GitHub's source archives.
- **Moving to a newer Akku** is a new tarball, sha256 and signature check in
  `scripts/akku-tool.lock`.
