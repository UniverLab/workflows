# Rust quality gate

Decided 2026-09-29: every UniverLab Rust crate runs the same strict gate, on by
default in `rust-ci.yml`, even where it fails today — the failure is the to-do
list for the next version. One definition, two callers: the `quality` and
`mutants` jobs in CI, and canopy's quality graph running
`scripts/rust-quality.sh` locally.

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
| cargo-mutants on the PR's Rust diff — any missed or timed-out mutant fails | on (PRs only) | `run-mutants`, `mutants-jobs` |

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

## Hardening applied to rust-ci.yml

Every third-party action is pinned to a commit SHA (release tag in the
comment; Dependabot keeps them current), checkouts do not persist the token
(`persist-credentials: false`), every job has a `timeout-minutes`, and the
workflow keeps `permissions: contents: read`.
