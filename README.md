# Workflows — Centralized CI/CD

Reusable GitHub Actions workflows for UniverLab projects.

---

## Overview

This repository centralizes CI/CD logic, reducing duplication across projects. Each workflow is designed as a reusable GitHub Actions workflow (`workflow_call`) — import it once, maintain it in one place.

**Benefits:**
- ✅ Single source of truth for CI/CD
- ✅ Consistent behavior across projects
- ✅ Update once, apply everywhere
- ✅ Less boilerplate per project (12-line consumer files)

---

## Available Workflows

### Rust

**Files:**
- `.github/workflows/rust-ci.yml` — Continuous integration (format, lint, test, publish checks)
- `.github/workflows/rust-release-manual.yml` — Trunk-based release, run by hand on main: version-bump check, build, crates.io publish behind the `production` environment's approval with Trusted Publishing (no token), then tag and GitHub release
- `.github/workflows/rust-release.yml` — Legacy release on merge of a version-bump PR into main (develop/main flow); repos move off it as they migrate to trunk-based

**Consumer usage:** See [Integration Guide](#integration-guide) below.

### Python

**Files:**
- `.github/workflows/python-ci.yml` — Continuous integration (format, lint, typecheck, test, main-PR version gate)
- `.github/workflows/python-publish.yml` — Publish to PyPI via trusted publishing

**Consumer usage:** See [Python Integration](#python-integration) below.

---

## Integration Guide

Each project creates minimal wrapper workflows in `.github/workflows/` that call the centralized ones.

### Example: texforge

**`.github/workflows/ci.yml`** (~5 lines):
```yaml
name: CI
on:
  push:
    branches: [main, develop]
  pull_request:

jobs:
  rust-ci:
    uses: UniverLab/workflows/.github/workflows/rust-ci.yml@main
```

**`.github/workflows/release.yml`** (~12 lines):
```yaml
name: Release
on:
  pull_request:
    branches: [main]
    types: [closed]
    paths: [Cargo.toml]
  workflow_dispatch:

jobs:
  release:
    if: github.event.pull_request.merged == true || github.event_name == 'workflow_dispatch'
    uses: UniverLab/workflows/.github/workflows/rust-release.yml@main
    with:
      binary-name: texforge
    secrets: inherit
```

**Setup secrets:** Each repo needs `CARGO_REGISTRY_TOKEN` configured (GitHub Settings → Secrets). The `secrets: inherit` passes it to the workflow.

### Trunk-based release (rust-release-manual.yml)

**`.github/workflows/release.yml`**:
```yaml
name: Release
on:
  workflow_dispatch:

permissions:
  contents: write
  id-token: write

jobs:
  ci:
    uses: ./.github/workflows/ci.yml   # ci.yml also needs `on: workflow_call`
    secrets: inherit
  release:
    needs: ci
    uses: UniverLab/workflows/.github/workflows/rust-release-manual.yml@main
    with:
      binary-name: texforge
```

**Setup, once per repo:**
- A `production` environment with the owner as required reviewer and a deployment branch policy of `main` only.
- On crates.io, the crate's Settings → Trusted Publishing → GitHub: owner `UniverLab`, the repo, workflow `release.yml` (the caller's file: crates.io matches the top-level workflow), environment `production`.
- No `CARGO_REGISTRY_TOKEN` is needed.

### Same pattern for: gitkit, ghscaff

Only change: `binary-name: gitkit` / `binary-name: ghscaff`

### Python Integration

**`.github/workflows/ci.yml`** (~9 lines):
```yaml
name: CI
on:
  pull_request:
  workflow_dispatch:

jobs:
  python-ci:
    uses: UniverLab/workflows/.github/workflows/python-ci.yml@main
```

On pull requests targeting `main`, the Python CI also requires the version in
`pyproject.toml` to differ from `origin/main`. Set `main-pr-checks: false` only
for projects whose version is generated dynamically.

**`.github/workflows/publish.yml`** (~15 lines):
```yaml
name: Publish
on:
  pull_request:
    branches: [main]
    types: [closed]
    paths: [pyproject.toml]
  workflow_dispatch:

jobs:
  publish:
    if: github.event.pull_request.merged == true || github.event_name == 'workflow_dispatch'
    uses: UniverLab/workflows/.github/workflows/python-publish.yml@main
    with:
      package-name: my-package
    secrets: inherit
```

**Setup secrets:** Each repo needs `PYPI_API_TOKEN` configured (GitHub Settings → Secrets). The `secrets: inherit` passes it to the workflow. Also configure a `pypi` environment for deployment protection.

---

## License

MIT — see the main organization LICENSE.

---

Made with ❤️ by UniverLab
