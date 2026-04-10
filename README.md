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
- `.github/workflows/rust-release.yml` — Release automation (tag, build, publish, crates.io)

**Consumer usage:** See [Integration Guide](#integration-guide) below.

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

### Same pattern for: gitkit, ghscaff

Only change: `binary-name: gitkit` / `binary-name: ghscaff`

---

## License

MIT — see the main organization LICENSE.

---

Made with ❤️ by UniverLab
