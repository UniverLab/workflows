#!/usr/bin/env bash
# python-quality.sh — the UniverLab quality gate for Python packages.
#
# The Python twin of rust-quality.sh. One definition, two callers: the
# `quality` job of .github/workflows/python-ci.yml, and canopy's graphs
# running locally. Whatever passes here passes CI, and the other way round.
#
# Run from the project root (where pyproject.toml and uv.lock live), after
# `uv sync --frozen`. Checks, in order (all run; the exit code is non-zero if
# any failed):
#   0. files      — QUALITY_SRC_PATHS (default `src`) must hold at least one
#                   .py file. A gate that found nothing to check fails instead
#                   of passing in silence. Test files are those under
#                   QUALITY_TEST_PATHS (default `tests`) plus any test_*.py,
#                   *_test.py or conftest.py inside the source paths.
#   1. file-size  — no source file with more CODE lines than
#                   QUALITY_MAX_FILE_LINES, and no test file with more than
#                   QUALITY_MAX_TEST_FILE_LINES (blank and comment-only lines do
#                   not count). Tests are capped too (decision of 2026-10-22):
#                   agents load whole files, and a giant test module is a
#                   context problem even when the code beside it is small.
#   2. fn-size    — no function or method, in source or tests, longer than
#                   QUALITY_FN_LINES lines (ruff has no length rule).
#   3. ruff       — strict complexity lints: C901 (mccabe), PLR0912 branches,
#                   PLR1702 nesting on source and tests, PLR0913 arguments on
#                   source only (pytest injects fixtures as arguments), with the
#                   thresholds below passed on the command line over the
#                   project's own ruff config.
#   4. deptry     — unused, missing and transitive dependencies.
#   5. audit      — pip-audit on the locked dependency set (uv export).
#   6. licenses   — every installed distribution carries a licence from the
#                   lab-wide allow-list (the same list as config/deny.toml).
#
# QUALITY_SRC_PATHS and QUALITY_TEST_PATHS are space-separated directories or
# files relative to the project root, for layouts without src/ (for example
# `packages scripts` in a registry of packages).
#
# Every threshold is an env var so a package can relax one in its own ci.yml
# (python-ci.yml exposes them as inputs). Defaults mirror the strict Rust
# ones decided 2026-09-29; complexity uses mccabe, so its number differs.
set -uo pipefail

SRC_PATHS="${QUALITY_SRC_PATHS:-src}"
TEST_PATHS="${QUALITY_TEST_PATHS:-tests}"
MAX_FILE_LINES="${QUALITY_MAX_FILE_LINES:-800}"
MAX_TEST_FILE_LINES="${QUALITY_MAX_TEST_FILE_LINES:-1500}"
FN_LINES="${QUALITY_FN_LINES:-100}"
COMPLEXITY="${QUALITY_COMPLEXITY:-15}"
BRANCHES="${QUALITY_BRANCHES:-15}"
NESTING="${QUALITY_NESTING:-5}"
ARGS="${QUALITY_ARGS:-7}"
RUN_FILE_SIZE="${QUALITY_FILE_SIZE:-1}"
RUN_FN_SIZE="${QUALITY_FN_SIZE:-1}"
RUN_RUFF="${QUALITY_RUFF:-1}"
RUN_DEPTRY="${QUALITY_DEPTRY:-1}"
RUN_AUDIT="${QUALITY_AUDIT:-1}"
RUN_LICENSES="${QUALITY_LICENSES:-1}"
# Space-separated distribution names whose licence metadata is known-good but
# unreadable (e.g. a wheel that ships no licence field). Keep it short.
LICENSE_IGNORE="${QUALITY_LICENSE_IGNORE:-}"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

failed=()
section() { printf '\n==> %s\n' "$1"; }
fail() { failed+=("$1"); printf '✗ %s\n' "$1"; }
pass() { printf '✓ %s\n' "$1"; }

if [ ! -f pyproject.toml ]; then
  echo "python-quality: run from the project root (no pyproject.toml here)" >&2
  exit 2
fi

# 0 ─ files ──────────────────────────────────────────────────────────────────
# One walk decides which files are source and which are tests; checks 1–3 read
# the two lists instead of each globbing src/ on its own.
SRC_LIST="${WORK}/src.txt"
TEST_LIST="${WORK}/tests.txt"
section "files (source: ${SRC_PATHS}; tests: ${TEST_PATHS})"
if python3 - "${SRC_PATHS}" "${TEST_PATHS}" "${SRC_LIST}" "${TEST_LIST}" <<'PY'
import pathlib, sys

src_paths, test_paths, src_out, test_out = sys.argv[1:5]
SKIP = {".venv", "venv", ".git", "__pycache__", "node_modules", "build", "dist", ".tox"}

def walk(spec):
    files = set()
    for entry in spec.split():
        root = pathlib.Path(entry)
        if root.is_file() and root.suffix == ".py":
            files.add(root)
        elif root.is_dir():
            files.update(f for f in root.rglob("*.py")
                         if not SKIP.intersection(f.parts))
    return files

def is_test_name(f):
    return f.name == "conftest.py" or f.name.startswith("test_") or f.stem.endswith("_test")

tests = walk(test_paths)
source = set()
for f in walk(src_paths):
    (tests if f in tests or is_test_name(f) else source).add(f)
pathlib.Path(src_out).write_text("".join(f"{f.as_posix()}\n" for f in sorted(source)))
pathlib.Path(test_out).write_text("".join(f"{f.as_posix()}\n" for f in sorted(tests)))
print(f"  {len(source)} source files, {len(tests)} test files")
sys.exit(0 if source else 1)
PY
then
  pass "files"
else
  fail "files: no .py file under QUALITY_SRC_PATHS='${SRC_PATHS}' (set quality-src-paths for this layout)"
fi
have_src() { [ -s "${SRC_LIST}" ]; }
have_tests() { [ -s "${TEST_LIST}" ]; }

# 1 ─ file size ──────────────────────────────────────────────────────────────
if [ "${RUN_FILE_SIZE}" = "1" ] && have_src; then
  section "file size (max ${MAX_FILE_LINES} code lines per source file, ${MAX_TEST_FILE_LINES} per test file)"
  if python3 - "${MAX_FILE_LINES}" "${SRC_LIST}" "${MAX_TEST_FILE_LINES}" "${TEST_LIST}" <<'PY'
import pathlib, sys

over = []
for limit, listing, kind in ((sys.argv[1], sys.argv[2], "source"), (sys.argv[3], sys.argv[4], "test")):
    for name in pathlib.Path(listing).read_text().split():
        lines = pathlib.Path(name).read_text(encoding="utf-8", errors="replace").splitlines()
        code = sum(1 for l in lines if l.strip() and not l.lstrip().startswith("#"))
        if code > int(limit):
            over.append((code, len(lines), kind, limit, name))
for code, total, kind, limit, name in over:
    print(f"  {code:6d} code lines ({total} total, {kind} max {limit})  {name}")
sys.exit(1 if over else 0)
PY
  then
    pass "file-size"
  else
    fail "file-size: files over their cap (listed above)"
  fi
fi

# 2 ─ function size ──────────────────────────────────────────────────────────
if [ "${RUN_FN_SIZE}" = "1" ] && have_src; then
  section "function size (max ${FN_LINES} lines per function, source and tests)"
  if python3 - "${FN_LINES}" "${SRC_LIST}" "${TEST_LIST}" <<'PY'
import ast, pathlib, sys

limit = int(sys.argv[1])
names = pathlib.Path(sys.argv[2]).read_text().split() + pathlib.Path(sys.argv[3]).read_text().split()
over = []
for name in names:
    tree = ast.parse(pathlib.Path(name).read_text(encoding="utf-8", errors="replace"), name)
    for node in ast.walk(tree):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            # Decorators belong to the function; the docstring counts too.
            start = min([node.lineno] + [d.lineno for d in node.decorator_list])
            length = node.end_lineno - start + 1
            if length > limit:
                over.append((length, f"{name}:{node.lineno}", node.name))
for length, where, name in sorted(over, reverse=True):
    print(f"  {length:6d} lines  {where}  {name}")
sys.exit(1 if over else 0)
PY
  then
    pass "fn-size"
  else
    fail "fn-size: functions over ${FN_LINES} lines (listed above)"
  fi
fi

# 3 ─ ruff, strict complexity lints ──────────────────────────────────────────
# PLR1702 is a preview rule; --preview is scoped to this explicit selection.
ruff_strict() {
  local rules="$1" list="$2"
  xargs -a "${list}" uv run --no-sync ruff check \
      --preview \
      --select "${rules}" \
      --config "lint.mccabe.max-complexity = ${COMPLEXITY}" \
      --config "lint.pylint.max-branches = ${BRANCHES}" \
      --config "lint.pylint.max-nested-blocks = ${NESTING}" \
      --config "lint.pylint.max-args = ${ARGS}"
}
if [ "${RUN_RUFF}" = "1" ] && have_src; then
  section "ruff strict (complexity ${COMPLEXITY}, branches ${BRANCHES}, nesting ${NESTING}, args ${ARGS} on source)"
  ruff_ok=1
  ruff_strict C901,PLR0912,PLR0913,PLR1702 "${SRC_LIST}" || ruff_ok=0
  if have_tests; then ruff_strict C901,PLR0912,PLR1702 "${TEST_LIST}" || ruff_ok=0; fi
  if [ "${ruff_ok}" = "1" ]; then
    pass "ruff strict"
  else
    fail "ruff strict"
  fi
fi

# 4 ─ deptry ─────────────────────────────────────────────────────────────────
if [ "${RUN_DEPTRY}" = "1" ]; then
  section "deptry (unused, missing and transitive dependencies)"
  # Scanning src/ (not the root) makes deptry read src/<pkg> as first-party in a
  # src layout instead of reporting the package itself as transitive.
  scan="."
  if [ -d src ]; then scan="src"; fi
  if uv run --no-sync --with deptry deptry "${scan}"; then pass "deptry"; else fail "deptry"; fi
fi

# 5 ─ pip-audit ──────────────────────────────────────────────────────────────
if [ "${RUN_AUDIT}" = "1" ]; then
  section "pip-audit (known vulnerabilities in the locked set)"
  # Local version labels (torch 2.x+cpu from the PyTorch index) are not on
  # PyPI; audit the upstream release they are built from.
  if uv export --frozen --all-extras --all-groups --no-emit-project --no-hashes \
        --format requirements-txt | sed -E 's/^([^ ;]+==[^+ ;]+)\+[^ ;]+/\1/' \
        >"${WORK}/requirements.txt" \
      && uvx pip-audit --disable-pip --no-deps --strict -r "${WORK}/requirements.txt"; then
    pass "pip-audit"
  else
    fail "pip-audit"
  fi
fi

# 6 ─ licences ───────────────────────────────────────────────────────────────
if [ "${RUN_LICENSES}" = "1" ]; then
  section "licences (lab-wide allow-list)"
  if uv run --no-sync python - "${LICENSE_IGNORE}" <<'PY'
import importlib.metadata as md, re, sys

# Same list as config/deny.toml: permissive licences compatible with shipping
# MIT/Apache software. Matched against the SPDX expression, the licence field
# and the trove classifiers, whichever the distribution declares.
ALLOW = {
    "MIT", "Apache-2.0", "BSD-2-Clause", "BSD-3-Clause", "ISC", "Zlib", "0BSD",
    "Unicode-3.0", "Unicode-DFS-2016", "CC0-1.0", "MPL-2.0", "BSL-1.0",
    "CDLA-Permissive-2.0", "PSF-2.0", "Python-2.0", "MIT-CMU", "HPND",
    # Python only: an LGPL library is imported, never statically linked into
    # what we ship, so its terms do not reach our code (deny.toml bans it for
    # Rust, where linking is static).
    "LGPL-2.1-only", "LGPL-2.1-or-later", "LGPL-3.0-only", "LGPL-3.0-or-later",
}
CLASSIFIERS = {
    "MIT License": "MIT",
    "Apache Software License": "Apache-2.0",
    "BSD License": "BSD-3-Clause",
    "ISC License (ISCL)": "ISC",
    "zlib/libpng License": "Zlib",
    "Mozilla Public License 2.0 (MPL 2.0)": "MPL-2.0",
    "Python Software Foundation License": "PSF-2.0",
    "Boost Software License 1.0 (BSL-1.0)": "BSL-1.0",
    "CC0 1.0 Universal (CC0 1.0) Public Domain Dedication": "CC0-1.0",
    "GNU Lesser General Public License v2 or later (LGPLv2+)": "LGPL-2.1-or-later",
    "GNU Lesser General Public License v3 (LGPLv3)": "LGPL-3.0-only",
    "GNU Lesser General Public License v3 or later (LGPLv3+)": "LGPL-3.0-or-later",
    "Historical Permission Notice and Disclaimer (HPND)": "HPND",
}
ALIASES = {
    "mit license": "MIT", "apache 2.0": "Apache-2.0", "apache-2": "Apache-2.0",
    "apache license 2.0": "Apache-2.0", "apache software license": "Apache-2.0",
    "bsd": "BSD-3-Clause", "bsd license": "BSD-3-Clause", "new bsd": "BSD-3-Clause",
    "3-clause bsd": "BSD-3-Clause", "bsd-3": "BSD-3-Clause", "psf": "PSF-2.0",
    "lgplv3+": "LGPL-3.0-or-later", "lgpl-3.0": "LGPL-3.0-only",
}

import tomllib

ignore = set(sys.argv[1].split()) if len(sys.argv) > 1 else set()
# The project itself is checked by its own pyproject, not by installed metadata.
with open("pyproject.toml", "rb") as fh:
    ignore.add(tomllib.load(fh).get("project", {}).get("name", ""))

def norm(name):
    return re.sub(r"[-_.]+", "-", name).lower()

ignore = {norm(n) for n in ignore if n}

def spdx_terms(expr):
    return [t for t in re.split(r"\s+(?:OR|AND|WITH)\s+|[()]", expr) if t.strip()]

def declared(dist):
    meta = dist.metadata
    found = []
    expr = meta.get("License-Expression")
    if expr:
        found.append(("expr", spdx_terms(expr)))
    for c in meta.get_all("Classifier") or []:
        if c.startswith("License :: "):
            name = c.rsplit(" :: ", 1)[-1]
            found.append(("classifier", [CLASSIFIERS.get(name, name)]))
    field = (meta.get("License") or "").strip()
    if field and "\n" not in field and len(field) < 80:
        terms = [ALIASES.get(t.strip().lower(), t.strip()) for t in spdx_terms(field)]
        found.append(("field", terms))
    return found

bad = []
seen = set()
for dist in sorted(md.distributions(), key=lambda d: d.metadata["Name"].lower()):
    name = dist.metadata["Name"]
    if norm(name) in ignore or norm(name) in seen:
        continue
    seen.add(norm(name))
    sources = declared(dist)
    # An "OR" expression passes if any alternative is allowed; any declared
    # source that is fully allowed is enough (classifiers often add detail).
    if any(all(t.strip() in ALLOW for t in terms) or
           (kind == "expr" and any(t.strip() in ALLOW for t in terms))
           for kind, terms in sources):
        continue
    shown = "; ".join(" ".join(t) for _, t in sources) or "no licence metadata"
    bad.append(f"  {name} {dist.version}: {shown}")
print("\n".join(bad))
sys.exit(1 if bad else 0)
PY
  then
    pass "licences"
  else
    fail "licences: outside the allow-list (listed above); set QUALITY_LICENSE_IGNORE only for verified metadata gaps"
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
