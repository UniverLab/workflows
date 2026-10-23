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

# Python quality gate

Decided 2026-10-19: Python packages get the same strict gate, on by default in
`python-ci.yml` (`run-quality: true`, coverage gate at 80 %). One definition,
two callers: the `quality` job in CI and `scripts/python-quality.sh` run
locally from the project root after `uv sync --all-extras --frozen`.

| Check | Default | Input to relax it |
|---|---|---|
| Source paths (must hold at least one `.py` file) | `src` | `quality-src-paths` |
| Test paths (plus `test_*.py`, `*_test.py`, `conftest.py` inside the source paths) | `tests` | `quality-test-paths` |
| Code lines per source file (blank and comment-only lines do not count) | 800 | `quality-max-file-lines` |
| Code lines per test file | 1 500 | `quality-max-test-file-lines` |
| Lines per function, source and tests | 100 | `quality-fn-lines` |
| ruff `C901` mccabe complexity, source and tests | 15 | `quality-complexity` |
| ruff `PLR0912` branches, source and tests | 15 | `quality-branches` |
| ruff `PLR1702` nested blocks, source and tests | 5 | `quality-nesting` |
| ruff `PLR0913` arguments, source only (pytest injects fixtures as arguments) | 7 | `quality-args` |
| deptry: unused, missing and transitive dependencies | on | — |
| pip-audit on the locked set (`uv export`) | on | — |
| Licences of every installed distribution against the lab allow-list | on | `quality-license-ignore` |

Notes:

- Tests are capped too (decided 2026-10-22). Agents load whole files, so a
  giant test module is a context problem even when the code beside it is
  small. Split long test files by topic instead of relaxing the cap.
- A layout without `src/` sets `quality-src-paths`, for example
  `packages scripts` in a registry of packages. Before 2026-10-23 the gate
  skipped its size and complexity checks in silence when `src/` was missing;
  now it fails and names the input.
- Keep development tools in `[dependency-groups] dev` (PEP 735), not in an
  `optional-dependencies` extra: deptry reads extras as runtime dependencies
  and reports pytest, ruff and mypy as unused.
- The licence allow-list is `config/deny.toml`'s, plus `PSF-2.0`, `MIT-CMU`,
  `HPND` and the LGPL family: a Python package imports an LGPL library and
  never links it statically, which is why `deny.toml` bans it for Rust only.
  A licence outside the list (for example "Free for non-commercial use")
  fails the gate on purpose; `quality-license-ignore` is only for metadata
  gaps verified by hand.
- Local version labels (`torch==2.x+cpu` from the PyTorch index) are audited
  as their upstream release.
