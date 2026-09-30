# Release binaries are built in the release PR

Decided 2026-09-30. A release used to compile its binaries only after the PR
into `main` had merged, so a target that failed to build (a macOS-only
dependency, a Windows path) broke the release when the code was already on
`main`. Now:

1. **Pull request into `main`** — `rust-ci.yml` calls `rust-release-build.yml`,
   which builds every release target from the PR's merge commit and uploads:
   - `release-pkg-<target>`: `<bin>-<tag>-<target>.tar.gz|.zip`
   - `release-meta`: `meta.json` with `{bin, tag, tree, sha}`

   The `rust-ci / Release Build` check turns red if any target fails. Add it
   to `main`'s branch protection next to `rust-ci / Format, Lint & Test`.
2. **Merge** — `rust-release.yml` tags the version, then its `resolve` job looks
   up the PR's last successful CI run for the PR head commit and reuses its
   packages **only if** the tag in `meta.json` matches and the git tree hash
   the PR built equals the tree of the tag. Anything else — no run, expired
   artifacts, `main` moved, missing permission — rebuilds with the same
   reusable workflow. A binary of different code is never published.
3. **crates.io** — publishes right after the GitHub release; there is no manual
   approval step any more.

## What a caller needs

- `release.yml` grants `actions: read` besides `contents: write` (the reuse
  downloads artifacts from another run; without it the release rebuilds).
- `ci.yml` needs nothing new: the release build derives the binary name from
  `cargo metadata`. Pass `release-binary-name`, `release-include-windows` or
  `release-system-packages-brew` only when they differ from the defaults, and
  keep them equal to the values `release.yml` passes to `rust-release.yml`.

## Tests run once

`rust-ci.yml`'s required job (`Format, Lint & Test`) runs the suite once: with
`run-coverage` on (the default) the instrumented `cargo llvm-cov` run is the
test run and enforces `coverage-threshold`; with it off, plain `cargo test` /
`cargo nextest`. There is no separate coverage job re-running the suite.
