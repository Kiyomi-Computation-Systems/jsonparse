# AGENTS.md

## Project guidelines

### Architecture & portability

* Use the functional core / imperative shell pattern
* Follow the 12 Factor Apps philosophy
* Project should be portable R6RS Scheme and be consumed as a library
* Project tooling and development should use Chez Scheme
* Project should be portable across macos (darwin) and linux; windows is not
  supported
* Project should be portable across amd64 and arm64
* **DO NOT** setup macos CI runners: linux only!
* Exported functions should have a comment with a Typed Racket style type signature

### Dependencies

* byte-machine https://github.com/Kiyomi-Computation-Systems/byte-machine

### Guix development container

* **On a Guix host, run every build and test through `scripts/guix-env`**,
  e.g. `scripts/guix-env make check-guix-inside`. Batch commands with
  `scripts/guix-env sh -c 'make a && make b'`: each call takes a second or
  more to start.
* Edit, commit and push on the host. The container has no git identity,
  agents or tokens, and no network but loopback (ADR-0008).
* Verify it with `make check-guix`, run on the host.
* The container exports `CHEZ` (the real `scheme` binary)

### Layout, process & libraries

* Plans live in `/.plans`, decision records in `/.plans/decisions`
* The ledger is `/.plans/progress.md`: where the project stands, the next
  slice, and a close-out for each merged slice. `/.plans/global-constraints.md`
  holds the decision records' hard rules and binds every task brief. Read both
  before starting slice work. `/.superpowers/` is git-ignored plugin scratch,
  not the ledger.
* Add entries to `CHANGELOG.md` for each release
* `/docs` is for user facing documentation only.
* Documentation should be very concise, focused, to the point, ELI5 style.
* `Makefile` should have a `help` command which lists all of its commands
* Libraries are R6RS `.sls`; libraries and programs contain their own code —
  no shared include bodies. R6RS forbids assigning an exported variable —
  reach mutable state through procedures.

### Testing & mutation discipline

* Use TDD / test-driven development
* A test that passes whether the code is right or wrong is worse than no test.
* A test is not finished when it passes. It is finished when you have watched
  it fail.
* Prefer a check to a comment.
* **Do not** write tests that rely on reading code comments

**Tests**

* `guard` returns the body's value when nothing raises, and `0` is truthy.
  Assert *what was raised* against an expected value, with a distinct sentinel
  for the no-raise case.
* SRFI-64 turns an exception in the *actual* expression into `#f`. Never
  expect `#f` from something that can raise.
* Every `tests/test-*.sps` must end with its own `(exit …)`: SRFI-64 sets no
  exit status. Anything after that line never runs.
* Chez evaluates arguments right to left in compiled library code, left to
  right when interpreted. No assertion may depend on argument order.
* An assertion passes whenever *another* rule can produce its expected value.
  Assert whole outputs, not substrings, and build a test's base from
  non-default values.

**Checks and environment**

* Deleting a subsystem disarms the checks built around it, and they stay
  green. On any deletion, ask of every surviving check "what would make this
  fail now?"; "nothing" is a defect.
* Point `CHEZ` at the real binary: a symlink breaks boot-file lookup, and a
  wrapper script hides Chez from Valgrind. `make check-guix` checks it.
* `guix shell --pure` does not stop a login shell from rebuilding `PATH`.
  `scripts/guix-env` uses `--container`, and `make check-guix` checks where a
  login shell finds each tool.

## Closing ritual

We run this when we're done and ready to merge the PR.

**Important**: ALWAYS ask before running this.

1. Squash merge the PR.
2. Catch up local `main`.
3. Clean up branches. Delete the merged branch locally and on the remote.
4. Reflect.
