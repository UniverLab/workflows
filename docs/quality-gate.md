# Rust quality gate

Decided 2026-09-29: every UniverLab Rust crate runs the same strict gate, on by
default in `rust-ci.yml`, even where it fails today — the failure is the to-do
list for the next version. One definition, two callers: the `quality` job in
CI, and canopy's quality graph running `scripts/rust-quality.sh` locally.

Mutation testing is **not** part of the PR gate (decided 2026-09-30): it re-runs
the whole suite once per mutant, too slow to block every PR and too heavy for
the workstation. It lives in `rust-mutants.yml`, run on demand — see below.

## What it checks

| Check | Default | Input to relax it |
|---|---|---|
| Code lines per `src/**/*.rs` file — inline `#[cfg(test)]` modules and separate test files do not count | 800 | `quality-max-file-lines` |
| clippy `too_many_lines` (per function) | 100 | `quality-fn-lines` |
| clippy `cognitive_complexity` | 25 | `quality-cognitive` |
| clippy `excessive_nesting` | 5 | `quality-nesting` |
| clippy `too_many_arguments` | 7 | `quality-args` |
| clippy `type_complexity` | 250 | `quality-type-complexity` |
| cargo-deny: advisories (vulnerable, unmaintained, yanked), licenses, sources | on | `run-deny` |
| cargo-machete: unused dependencies | on | `run-machete` |

clippy's strict lints run on the default targets (lib + bins); tests are not
held to the size limits. cargo-deny uses the crate's own `deny.toml` when
present, otherwise `config/deny.toml` from this repo.

Turning the whole gate off (`run-quality: false`) exists but should not be the
answer: relax the one threshold that is too hard for that crate, in that
crate's `ci.yml`, where the exception is visible.

## Running it locally

```bash
cd <crate>
bash ~/Projects/UniverLab/workflows/scripts/rust-quality.sh            # file size, clippy, deny, machete
QUALITY_MUTANTS_BASE=origin/develop bash …/rust-quality.sh              # + mutants on the diff
QUALITY_MAX_FILE_LINES=1200 bash …/rust-quality.sh                      # a relaxed threshold
```

Needs `cargo-deny`, `cargo-machete` and `cargo-mutants` installed
(`cargo install --locked cargo-deny cargo-machete cargo-mutants`).

## Mutation testing on demand (`rust-mutants.yml`)

Dispatched on this repository with the crate as an input, so no crate needs a
workflow file for it; the branch under test must be pushed:

```bash
gh workflow run rust-mutants.yml -R UniverLab/workflows \
  -f repository=UniverLab/gitkit -f ref=feature/sv-update -f base=develop \
  -f shards=4 -f request-id=$(date +%s)
```

It covers the Rust diff from the merge-base with `base`, split across `shards`
runners (`cargo mutants --shard k/N`); the crate's `.cargo/mutants.toml`
exclusions apply. The `mutants-report` artifact holds `missed.txt`,
`timeout.txt` and `summary.txt`, and the run fails on any missed or timed-out
mutant. Canopy's spec-less quality graph dispatches it once per large block of
specs and polls it; nothing runs it on a PR or a schedule.

## Hardening applied to rust-ci.yml

Every third-party action is pinned to a commit SHA (release tag in the
comment; pins are bumped by hand, and Dependabot security updates open a PR
only when an advisory hits a pinned action), checkouts do not persist the token
(`persist-credentials: false`), every job has a `timeout-minutes`, and the
workflow keeps `permissions: contents: read`.

Tests run once, inside the required `Format, Lint & Test` job (coverage included); release binaries are built in the release PR — see `release-build.md`.
