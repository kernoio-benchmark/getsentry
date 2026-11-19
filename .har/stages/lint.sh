#!/usr/bin/env bash
# lint (tier: full) — the repo's own lint entry points, scoped to this slot's
# changed files (AGENTS.md: "prek is the single entrypoint for all lint,
# format, and type-checking tools"):
#   * prek run --files <changed>      (ruff, formatting, mypy pre-commit hooks, …)
#   * pnpm run lint:js <changed JS/TS> (oxlint in the owning workspace)
# Log: .har/artifacts/lint/agent-<id>.log
set -euo pipefail

AGENT_ID="${1:-${AGENT_ID:?Usage: lint.sh <agent-id>}}"
: "${ENV_FILE:?ENV_FILE not set — launch the slot first: har env launch ${AGENT_ID}}"
: "${WORK_DIR:?WORK_DIR not set — launch the slot first: har env launch ${AGENT_ID}}"
HAR_DIR="${HAR_HARNESS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$WORK_DIR"

artifacts="$HAR_DIR/artifacts/lint"
mkdir -p "$artifacts"
log_file="$artifacts/agent-${AGENT_ID}.log"
: >"$log_file"

mapfile -t changed < <(bash "$HAR_DIR/scripts/sentry-slot.sh" changed-files)
if [ "${#changed[@]}" -eq 0 ]; then
  echo "No changed files — nothing to lint." | tee "$log_file"
  exit 0
fi

js=()
for f in "${changed[@]}"; do
  case "$f" in *.ts | *.tsx | *.js | *.jsx | *.mjs | *.cjs) js+=("$f") ;; esac
done

status=0
venv_bin="$(dirname "${PYTHON_BIN:-.venv/bin/python}")"
echo "==> prek run --files (${#changed[@]} file(s))" | tee -a "$log_file"
"$venv_bin/prek" run -q --files "${changed[@]}" >>"$log_file" 2>&1 || status=1

if [ "${#js[@]}" -gt 0 ]; then
  echo "==> pnpm run lint:js (${#js[@]} file(s))" | tee -a "$log_file"
  pnpm run lint:js "${js[@]}" >>"$log_file" 2>&1 || status=1
fi

[ "$status" -eq 0 ] || tail -n 40 "$log_file"
exit "$status"
