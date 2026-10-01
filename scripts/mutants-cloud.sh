#!/usr/bin/env bash
# mutants-cloud.sh — run a crate's mutation testing on GitHub runners and wait.
#
# Called by canopy's spec-less quality graph (the "Mutants (cloud)" check node),
# from the crate's root, on the branch the loop works on:
#
#   bash mutants-cloud.sh <owner/repo> [lock-reason]
#
# 1. pushes HEAD to its branch on origin (unlocking gitkit's lock for the push
#    and restoring it afterwards when a reason is given);
# 2. dispatches rust-mutants.yml on UniverLab/workflows for that exact SHA;
# 3. waits for the run, downloads its mutants-report artifact and prints it.
#
# Exit 0: no surviving mutants. Exit 1: missed/timed-out mutants (the list is
# printed, it becomes the fixer's feedback) or the run failed. Exit 2: the run
# could not be started or found.
#
# Tunables (env): MUTANTS_BASE (develop), MUTANTS_SHARDS (4), MUTANTS_JOBS (2),
# MUTANTS_TEST_TOOL (cargo), MUTANTS_SYSTEM_PACKAGES (""), MUTANTS_FEATURES ("").
set -uo pipefail

REPO="${1:?usage: mutants-cloud.sh <owner/repo> [lock-reason]}"
LOCK_REASON="${2:-}"
BASE="${MUTANTS_BASE:-develop}"
SHARDS="${MUTANTS_SHARDS:-4}"
JOBS="${MUTANTS_JOBS:-2}"
TEST_TOOL="${MUTANTS_TEST_TOOL:-cargo}"
SYSTEM_PACKAGES="${MUTANTS_SYSTEM_PACKAGES:-}"
FEATURES="${MUTANTS_FEATURES:-}"
WF_REPO="UniverLab/workflows"

branch="$(git branch --show-current)"
if [ -z "$branch" ]; then echo "mutants-cloud: detached HEAD, nothing to push"; exit 2; fi
if [ -n "$(git status --porcelain)" ]; then
  echo "mutants-cloud: the tree has uncommitted changes; the cloud would test something else"; exit 2
fi
sha="$(git rev-parse HEAD)"

command -v gitkit >/dev/null 2>&1 && gitkit unlock >/dev/null 2>&1
git push -q origin "HEAD:refs/heads/${branch}"
pushed=$?
if [ -n "$LOCK_REASON" ] && command -v gitkit >/dev/null 2>&1; then
  gitkit lock --timeout 6h --reason "$LOCK_REASON" >/dev/null 2>&1
fi
if [ "$pushed" -ne 0 ]; then echo "mutants-cloud: push of ${branch} failed"; exit 2; fi

rid="$(basename "$REPO")-$(date +%s)-$$"
if ! gh workflow run rust-mutants.yml -R "$WF_REPO" \
    -f repository="$REPO" -f ref="$sha" -f base="$BASE" -f shards="$SHARDS" \
    -f jobs="$JOBS" -f test-tool="$TEST_TOOL" -f system-packages="$SYSTEM_PACKAGES" \
    -f features="$FEATURES" -f request-id="$rid" >/dev/null; then
  echo "mutants-cloud: dispatch failed"; exit 2
fi

run_id=""
for _ in $(seq 1 30); do
  sleep 6
  run_id="$(gh run list -R "$WF_REPO" --workflow rust-mutants.yml --limit 30 \
    --json databaseId,displayTitle \
    --jq ".[] | select(.displayTitle | contains(\"[${rid}]\")) | .databaseId" | head -1)"
  [ -n "$run_id" ] && break
done
if [ -z "$run_id" ]; then echo "mutants-cloud: dispatched run ${rid} not found"; exit 2; fi
url="https://github.com/${WF_REPO}/actions/runs/${run_id}"
echo "mutants-cloud: ${REPO}@${sha:0:7} (${branch}) → ${url}"

# `gh run watch` can return before the run ends (an API hiccup): wait until the
# run is really completed, then take its conclusion as the exit code.
wait_for_run() {
  local status conclusion deadline=$(( $(date +%s) + 6 * 3600 ))
  while :; do
    gh run watch "$run_id" -R "$WF_REPO" --interval 60 >/dev/null 2>&1
    status="$(gh run view "$run_id" -R "$WF_REPO" --json status --jq .status 2>/dev/null)"
    [ "$status" = completed ] && break
    [ "$(date +%s)" -ge "$deadline" ] && { echo "mutants-cloud: run still ${status:-unknown} after 6 h"; return 1; }
    sleep 60
  done
  conclusion="$(gh run view "$run_id" -R "$WF_REPO" --json conclusion --jq .conclusion 2>/dev/null)"
  [ "$conclusion" = success ]
}

wait_for_run
code=$?

# Shard jobs that ended without success: "<shard>\t<job id>\t<has artifact>".
failed_shards() {
  local artifacts
  artifacts="$(gh api "repos/${WF_REPO}/actions/runs/${run_id}/artifacts" --jq '.artifacts[].name' 2>/dev/null)"
  gh run view "$run_id" -R "$WF_REPO" --json jobs \
    --jq '.jobs[] | select((.name | startswith("Mutants shard")) and .status == "completed" and .conclusion != "success") | "\(.name | ltrimstr("Mutants shard "))\t\(.databaseId)"' 2>/dev/null |
    while IFS=$'\t' read -r shard job; do
      if printf '%s\n' "$artifacts" | grep -qx "mutants-shard-${shard}"; then has=yes; else has=no; fi
      printf '%s\t%s\t%s\n' "$shard" "$job" "$has"
    done
}

# A shard with no artifact was lost to the runner (shutdown, cancellation), not
# to the code: its mutants were never counted. Rerun the failed jobs once.
if [ "$code" -ne 0 ] && failed_shards | grep -q $'\tno$'; then
  echo "mutants-cloud: shard(s) $(failed_shards | awk -F'\t' '$3=="no"{printf "%s ", $1}')lost to the runner; rerunning the failed jobs once"
  if gh run rerun "$run_id" -R "$WF_REPO" --failed >/dev/null 2>&1; then
    sleep 20
    wait_for_run
    code=$?
  fi
fi

out="$(git rev-parse --git-dir)/mutants-report"
rm -rf "$out"; mkdir -p "$out"
if gh run download "$run_id" -R "$WF_REPO" -n mutants-report -D "$out" >/dev/null 2>&1; then
  cat "$out/summary.txt"
  if [ -s "$out/missed.txt" ]; then echo; echo "MISSED ($(wc -l < "$out/missed.txt")):"; head -400 "$out/missed.txt"; fi
  if [ -s "$out/timeout.txt" ]; then echo; echo "TIMEOUT ($(wc -l < "$out/timeout.txt")):"; head -100 "$out/timeout.txt"; fi
else
  echo "mutants-cloud: no mutants-report artifact; see ${url}"
fi

# A failed shard that still uploaded a report but tested nothing had a broken
# baseline (the unmutated suite failed) or build: its mutants are not in the
# counts above. Print why, from the shard log, so the fixer can act on it.
if [ "$code" -ne 0 ]; then
  failed_shards | while IFS=$'\t' read -r shard job has; do
    echo
    if [ "$has" = no ]; then
      echo "INCOMPLETE: shard ${shard} produced no report even after a rerun (runner lost); its mutants were not tested"
      continue
    fi
    reason="$(gh api "repos/${WF_REPO}/actions/jobs/${job}/logs" 2>/dev/null | sed 's/^[0-9TZ:.-]* //; s/\x1b\[[0-9;]*m//g' |
      grep -E "Unmutated baseline|unmutated tree|panicked at|^ *(ERROR|error)(\[| |:)|Bad |FAILED" | grep -v '^\s*MISSED' | head -12)"
    if [ -n "$reason" ]; then
      echo "INCOMPLETE: shard ${shard} failed outside the mutants (baseline or build); first lines of its log:"
      printf '%s\n' "$reason"
    fi
  done
fi

if [ "$code" -eq 0 ]; then echo "MUTANTS PASSED"; exit 0; fi
echo "MUTANTS FAILED (${url})"
exit 1
