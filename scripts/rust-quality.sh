#!/usr/bin/env bash
# rust-quality.sh — the UniverLab quality gate for Rust crates.
#
# One definition, two callers: the `quality` and `mutants` jobs of
# .github/workflows/rust-ci.yml, and canopy's quality graph running locally.
# Whatever passes here passes CI, and the other way round.
#
# Checks, in order (all run; the exit code is non-zero if any failed):
#   1. file-size  — no .rs file under src/ with more CODE lines than
#                   QUALITY_MAX_FILE_LINES; inline #[cfg(test)] modules do not count
#                   (files named tests.rs / *_test.rs / under a tests/ dir are
#                   exempt: test tables are allowed to be long).
#   2. clippy     — strict size/complexity lints on the default targets
#                   (lib + bins; tests, benches and examples are not linted):
#                   too_many_lines, cognitive_complexity, excessive_nesting,
#                   too_many_arguments, type_complexity, with the thresholds
#                   below written into a temporary clippy.toml merged over the
#                   crate's own.
#   3. deny       — cargo-deny: advisories, bans, licenses, sources. Uses the
#                   crate's deny.toml, or config/deny.toml from this repo.
#   4. machete    — cargo-machete: unused dependencies.
#   5. mutants    — only when QUALITY_MUTANTS_BASE is set: cargo-mutants on the
#                   diff against that git ref. Any missed or timed-out mutant
#                   fails the gate.
#
# Every threshold is an env var so a crate can relax one in its own ci.yml
# (rust-ci.yml exposes them as inputs). Defaults are the strict lab-wide ones
# decided 2026-09-29.
set -uo pipefail

MAX_FILE_LINES="${QUALITY_MAX_FILE_LINES:-800}"
FN_LINES="${QUALITY_FN_LINES:-100}"
COGNITIVE="${QUALITY_COGNITIVE:-25}"
NESTING="${QUALITY_NESTING:-5}"
ARGS="${QUALITY_ARGS:-7}"
TYPE_COMPLEXITY="${QUALITY_TYPE_COMPLEXITY:-250}"
RUN_FILE_SIZE="${QUALITY_FILE_SIZE:-1}"
RUN_CLIPPY="${QUALITY_CLIPPY:-1}"
RUN_DENY="${QUALITY_DENY:-1}"
RUN_MACHETE="${QUALITY_MACHETE:-1}"
FEATURES="${QUALITY_FEATURES:---all-features}"
MUTANTS_BASE="${QUALITY_MUTANTS_BASE:-}"
MUTANTS_TEST_TOOL="${QUALITY_MUTANTS_TEST_TOOL:-cargo}"
MUTANTS_JOBS="${QUALITY_MUTANTS_JOBS:-2}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_DENY="${HERE}/../config/deny.toml"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

failed=()
section() { printf '\n==> %s\n' "$1"; }
fail() { failed+=("$1"); printf '✗ %s\n' "$1"; }
pass() { printf '✓ %s\n' "$1"; }

if [ ! -f Cargo.toml ]; then
  echo "rust-quality: run from the crate root (no Cargo.toml here)" >&2
  exit 2
fi

# 1 ─ file size ──────────────────────────────────────────────────────────────
# Counts CODE lines only: inline unit-test modules (`#[cfg(test)] mod x { … }`)
# are Rust's convention for tests and must not push a well-tested file over
# the limit. Separate test files (tests.rs, *_test.rs, anything under tests/)
# are exempt entirely.
if [ "${RUN_FILE_SIZE}" = "1" ] && [ -d src ]; then
  section "file size (max ${MAX_FILE_LINES} code lines per src/**/*.rs; #[cfg(test)] modules excluded)"
  if python3 - "${MAX_FILE_LINES}" <<'PY'
import pathlib, re, sys

limit = int(sys.argv[1])
exempt = re.compile(r"(^|/)tests(/|\.rs$)|_tests?\.rs$")
cfg_test = re.compile(r"^\s*#\[cfg\(test\)\]\s*$")
mod_open = re.compile(r"^\s*(pub(\([^)]*\))?\s+)?mod\s+\w+\s*\{")

def code_lines(text):
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    count, i, n = 0, 0, len(lines)
    while i < n:
        if cfg_test.match(lines[i]):
            j = i + 1
            while j < n and (not lines[j].strip() or lines[j].lstrip().startswith("#[")):
                j += 1
            if j < n and mod_open.match(lines[j]):
                depth = 0
                k = j
                while k < n:
                    # braces inside strings/comments are rare in test modules;
                    # an imbalance only makes the count stricter, never looser
                    depth += lines[k].count("{") - lines[k].count("}")
                    if depth <= 0:
                        break
                    k += 1
                i = k + 1
                continue
        count += 1
        i += 1
    return count

over = []
for f in sorted(pathlib.Path("src").rglob("*.rs")):
    if exempt.search(f.as_posix()):
        continue
    text = f.read_text(encoding="utf-8", errors="replace")
    code = code_lines(text)
    if code > limit:
        total = text.count("\n")
        over.append((code, total, f.as_posix()))
for code, total, f in over:
    print(f"  {code:6d} code lines ({total} total)  {f}")
sys.exit(1 if over else 0)
PY
  then
    pass "file-size"
  else
    fail "file-size: code over ${MAX_FILE_LINES} lines (listed above)"
  fi
fi

# 2 ─ clippy, strict size and complexity lints ───────────────────────────────
if [ "${RUN_CLIPPY}" = "1" ]; then
  section "clippy strict (fn ${FN_LINES} lines, cognitive ${COGNITIVE}, nesting ${NESTING}, args ${ARGS}, type ${TYPE_COMPLEXITY})"
  conf="${WORK}/clippy"
  mkdir -p "${conf}"
  for c in clippy.toml .clippy.toml; do
    if [ -f "$c" ]; then
      grep -vE '^\s*(too-many-lines-threshold|cognitive-complexity-threshold|excessive-nesting-threshold|too-many-arguments-threshold|type-complexity-threshold)\s*=' "$c" >"${conf}/clippy.toml"
      break
    fi
  done
  cat >>"${conf}/clippy.toml" <<EOF
too-many-lines-threshold = ${FN_LINES}
cognitive-complexity-threshold = ${COGNITIVE}
excessive-nesting-threshold = ${NESTING}
too-many-arguments-threshold = ${ARGS}
type-complexity-threshold = ${TYPE_COMPLEXITY}
EOF
  # shellcheck disable=SC2086
  if CLIPPY_CONF_DIR="${conf}" cargo clippy --locked ${FEATURES} -- \
      -D warnings \
      -D clippy::too_many_lines \
      -D clippy::cognitive_complexity \
      -D clippy::excessive_nesting \
      -D clippy::too_many_arguments \
      -D clippy::type_complexity; then
    pass "clippy strict"
  else
    fail "clippy strict"
  fi
fi

# 3 ─ cargo-deny ─────────────────────────────────────────────────────────────
if [ "${RUN_DENY}" = "1" ]; then
  section "cargo-deny (advisories, bans, licenses, sources)"
  cfg=()
  if [ ! -f deny.toml ]; then cfg=(--config "${DEFAULT_DENY}"); fi
  if cargo deny --locked "${cfg[@]}" check advisories bans licenses sources; then
    pass "cargo-deny"
  else
    fail "cargo-deny"
  fi
fi

# 4 ─ cargo-machete ──────────────────────────────────────────────────────────
if [ "${RUN_MACHETE}" = "1" ]; then
  section "cargo-machete (unused dependencies)"
  if cargo machete; then pass "cargo-machete"; else fail "cargo-machete"; fi
fi

# 5 ─ cargo-mutants on the diff ──────────────────────────────────────────────
if [ -n "${MUTANTS_BASE}" ]; then
  section "cargo-mutants on the diff against ${MUTANTS_BASE}"
  git diff "${MUTANTS_BASE}...HEAD" -- '*.rs' >"${WORK}/diff.patch"
  if [ ! -s "${WORK}/diff.patch" ]; then
    pass "cargo-mutants (no Rust changes in the diff)"
  elif cargo mutants --in-diff "${WORK}/diff.patch" --test-tool "${MUTANTS_TEST_TOOL}" \
      --jobs "${MUTANTS_JOBS}" --no-shuffle ${FEATURES}; then
    pass "cargo-mutants"
  else
    fail "cargo-mutants: missed or timed-out mutants (see mutants.out/)"
  fi
fi

# ─ summary ──────────────────────────────────────────────────────────────────
echo
if [ "${#failed[@]}" -gt 0 ]; then
  echo "QUALITY GATE FAILED:"
  printf '  - %s\n' "${failed[@]}"
  exit 1
fi
echo "QUALITY GATE PASSED"
