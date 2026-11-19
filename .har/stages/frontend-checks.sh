#!/usr/bin/env bash
# frontend-checks (tier: full) — only when the slot changed JS/TS files:
#   * pnpm run typecheck                (tsc --build, whole project, a few minutes)
#   * pnpm test-ci <direct spec files>  changed *.spec.{ts,tsx} plus the sibling
#     <name>.spec.{ts,tsx} of each changed module. Deliberately NOT
#     --findRelatedTests: it is transitive and a change to a shared util pulls in
#     hundreds of specs (10+ min); CI runs the wider set.
# Skips cleanly (pass) for backend-only changes.
# Log: .har/artifacts/frontend-checks/agent-<id>.log
set -euo pipefail

AGENT_ID="${1:-${AGENT_ID:?Usage: frontend-checks.sh <agent-id>}}"
: "${ENV_FILE:?ENV_FILE not set — launch the slot first: har env launch ${AGENT_ID}}"
: "${WORK_DIR:?WORK_DIR not set — launch the slot first: har env launch ${AGENT_ID}}"
HAR_DIR="${HAR_HARNESS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$WORK_DIR"

artifacts="$HAR_DIR/artifacts/frontend-checks"
mkdir -p "$artifacts"
log_file="$artifacts/agent-${AGENT_ID}.log"
: >"$log_file"

mapfile -t changed < <(bash "$HAR_DIR/scripts/sentry-slot.sh" changed-files)
ts=()
specs=()
for f in "${changed[@]}"; do
  case "$f" in
    *.spec.ts | *.spec.tsx) ts+=("$f"); specs+=("$f") ;;
    *.ts | *.tsx | *.js | *.jsx | *.mjs)
      ts+=("$f")
      base="${f%.*}"
      for s in "$base.spec.tsx" "$base.spec.ts"; do [ -f "$s" ] && specs+=("$s"); done
      ;;
  esac
done

if [ "${#ts[@]}" -eq 0 ]; then
  echo "No changed JS/TS files — skipping typecheck and jest." | tee "$log_file"
  exit 0
fi

status=0
echo "==> pnpm run typecheck" | tee -a "$log_file"
pnpm run typecheck >>"$log_file" 2>&1 || status=1

if [ "${#specs[@]}" -gt 0 ]; then
  mapfile -t specs < <(printf '%s\n' "${specs[@]}" | sort -u)
  echo "==> pnpm test-ci (${#specs[@]} spec file(s)): ${specs[*]}" | tee -a "$log_file"
  # pnpm runs test-ci in every workspace; absolute paths + --runTestsByPath let
  # scripts/testCi.js route each spec to its owning workspace.
  pnpm test-ci --passWithNoTests --runTestsByPath "${specs[@]/#/$WORK_DIR/}" >>"$log_file" 2>&1 || status=1
else
  echo "==> no direct spec files for the changed modules — jest skipped" | tee -a "$log_file"
fi

[ "$status" -eq 0 ] || tail -n 40 "$log_file"
exit "$status"
