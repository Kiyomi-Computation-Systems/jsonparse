# ADR-0021: The docs site is rendered from docs/ by circuit's generator

- **Status:** Accepted
- **Date:** 2026-11-08
- **Scope:** `site/`, `build-site.sps`, `docs/README.md`, the site's
  Makefile targets, chez-cmark-gfm, the `site` CI job and the Pages
  workflow
- **Related:** ADR-0003, ADR-0008, ADR-0009, ADR-0012

## Context

`docs/` holds the user documentation (AGENTS.md). Five siblings publish
theirs to GitHub Pages with one generator: circuit, chez-http-server,
chez-websocket, byte-machine and chez-httparse. Circuit's copy is the newest
(2026-11-06). Its `io`, `render`, `serializer` and `transform` libraries are
byte for byte chez-http-server's and chez-websocket's. byte-machine and
chez-httparse carry older forks.

The generator renders Markdown through chez-cmark-gfm, which is on Akku at
2.0.0 and loads the system's cmark-gfm C library. `docs/` had no home page.

## Decision

1. **The generator is circuit's, copied:** the eight libraries under
   `site/`, `site/style.css` and `build-site.sps`. Only three libraries
   change:
   - `pages.sls`: jsonparse's nav;
   - `links.sls`: the repository URL that `../` links out to;
   - `template.sls`: the name, the description and keywords, and the source
     link.

   Its suites come too, `site-unit`, `site-render-unit` and `site-check`, as
   do `scripts/fetch-akku-lock` and its offline test.
2. **The home page is `docs/README.md`,** written as `index.html`. Its
   "Read next" list is the nav: every other page once, in `(site pages)`'s
   order, under its nav label. `site-check` holds that, beside circuit's six
   checks: the nav names exactly `docs/*.md`; every link and anchor
   resolves; no relative `.md` link is left; every relative link names a
   written file; every link out names a file in the checkout; `<pre>` keeps
   its text.
3. **Neither the home page nor the reference is a guide** for
   `test-docs`: both name exports without explaining them.
4. **chez-cmark-gfm is a development dependency,** `depends/dev` at
   `^2.0.0`, and `Akku.lock` locks it beside byte-machine.
   - `make site-deps` fetches the locked archive on the host, checks its
     sha256 and unpacks it under `build/akku/`. After that the container
     finds it there, with no network.
   - Nothing under `src/` and no `tests/test-*.sps` imports it, so `make
     test` needs neither it nor the network.
   - `.akkuignore` lists `site`, whose libraries Akku would otherwise
     install (ADR-0003).
5. **The C library comes from the system:** apt's `cmark-gfm` in CI, and
   `manifest.scm` in the container, with `tar`, `xz` and `curl` for the
   fetch script and its test. `scripts/guix-env-enter` exports
   `CHEZ_CMARK_GFM_LIBS`, the profile's two libraries by absolute path, and
   refuses a profile without them.
   `make check-guix` holds the rest: login shells find the profile's `tar`,
   `xz` and `curl`, Chez loads both libraries by those paths, and
   `check-site-deps` passes in the container.
6. **CI's `site` job runs the site's checks and build on every pull
   request,** with apt's Chez, which is below the floor: nothing the site
   runs loads jsonparse or byte-machine.
   - It checks its architecture twice, as ADR-0009 asks: `uname -m` is
     `x86_64` and Chez's machine type is `ta6le`. That type also says the
     build is threaded, which `(jsonparse-testing)`'s mutexes need.
   - The Pages workflow's build job checks the same. Its deploy job runs one
     action and no Chez, so it checks neither.
   - It runs on amd64 alone: Ubuntu 24.04 publishes `chezscheme` for amd64
     and not arm64 (Launchpad, 2026-11-08).
7. **`.github/workflows/pages.yml` deploys on a `v*` tag, or by hand from
   `main`,** as the siblings do. `SITE_REF` is the tag, so links out of the site pin to
   the release.
   - Pages builds from Actions.
   - The `github-pages` environment takes `main` and `v*` tags only.
   - Both settings were made on 2026-11-08. The site is
     <https://kiyomi-computation-systems.github.io/jsonparse/>.

## Consequences

- **The site goes live at the first release tag,** or at a run by hand from
  `main`.
- **The site's anchors are GitHub's.** On 2026-11-08 every one of the 125
  headings on the seven committed pages slugged as GitHub's rendering of
  `main` anchors it, in order. `site-unit` pins four of them.
- **A fix to the generator** in one sibling is copied to the others by
  hand. No package shares it.
- **`build-site.sps` sits at the root,** outside `.akkuignore`, as circuit's
  does. Plan M5's `make check-akku` installs the package as a consumer
  would, and should confirm that no program or library outside `src/`
  reaches it.
