#!/usr/bin/env bash
# pr-split (repo stage, NOT on verify) — the slot's change is one deployable PR:
# it must not mix frontend (static/) with backend (src/, migrations, Python).
# AGENTS.md: "Frontend (static/) and backend (src/, tests/) are not atomically
# deployed … split them into separate PRs." CI enforces the same rule after push;
# this asks it before handoff. Tagged by the flag-cleanup and flagged-feature
# factory lines from their first PR-producing station.
#
# Allowed alongside either side: tests that belong to it (tests/ with src/,
# *.spec.tsx with static/), and repo-neutral files (docs, .agents/, AGENTS.md).
set -euo pipefail

AGENT_ID="${1:-${AGENT_ID:?Usage: pr-split.sh <agent-id>}}"
HAR_DIR="${HAR_HARNESS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# `har env verify` exports the slot env; `har line gate` and `har env run-stage`
# do not, so fall back to the slot registry + .env.agent.<id> (same as
# backend-tests.sh).
if [ -z "${WORK_DIR:-}" ]; then
  registry="$HAR_DIR/slots/agent-${AGENT_ID}.json"
  [ -f "$registry" ] || { echo "Slot ${AGENT_ID} is not launched: har env launch ${AGENT_ID}" >&2; exit 1; }
  WORK_DIR="$(node -e 'process.stdout.write(require(process.argv[1]).workDir)' "$registry")"
fi
ENV_FILE="${ENV_FILE:-$WORK_DIR/.env.agent.${AGENT_ID}}"
[ -f "$ENV_FILE" ] || { echo "No slot env $ENV_FILE — run har env launch ${AGENT_ID}" >&2; exit 1; }
if [ -z "${PYTHON_BIN:-}" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi
ARTIFACTS_DIR="$HAR_DIR/artifacts/pr-split"
mkdir -p "$ARTIFACTS_DIR"
REPORT="$ARTIFACTS_DIR/agent-${AGENT_ID}.txt"
now_ms() { node -e 'process.stdout.write(String(Date.now()))' 2>/dev/null || echo 0; }
START=$(now_ms)

cd "$WORK_DIR"
mapfile -t changed < <(AGENT_ID="$AGENT_ID" bash "$HAR_DIR/scripts/sentry-slot.sh" changed-files)

frontend=() backend=()
for f in "${changed[@]}"; do
  case "$f" in
    static/*) frontend+=("$f") ;;
    src/* | tests/* | migrations_lockfile.txt | pyproject.toml | uv.lock) backend+=("$f") ;;
  esac
done

{
  echo "changed: ${#changed[@]} file(s); frontend: ${#frontend[@]}; backend: ${#backend[@]}"
  if [ "${#frontend[@]}" -gt 0 ] && [ "${#backend[@]}" -gt 0 ]; then
    echo "This change mixes frontend and backend — split it into two PRs (backend first when the frontend depends on it)."
    echo "backend:";  printf '  %s\n' "${backend[@]}"
    echo "frontend:"; printf '  %s\n' "${frontend[@]}"
  fi
} >"$REPORT"

status=pass summary="single-side change"
if [ "${#frontend[@]}" -gt 0 ] && [ "${#backend[@]}" -gt 0 ]; then
  status=fail summary="mixes static/ with src/"
elif [ "${#changed[@]}" -eq 0 ]; then
  summary="no changes"
fi

node -e '
  const [agent, status, total, summary, reportPath] = process.argv.slice(1);
  const output = require("fs").readFileSync(reportPath, "utf8").trim().split("\n").slice(0, 50).join("\n");
  process.stdout.write(JSON.stringify({ status, stageId: "pr-split", kind: "test", agent_id: Number(agent),
    total_ms: Number(total), summary, report: reportPath, output }, null, 2) + "\n");
' "$AGENT_ID" "$status" "$(($(now_ms) - START))" "$summary" "$REPORT"
echo "==> [pr-split agent-${AGENT_ID}] $status: $summary" >&2
[ "$status" = pass ]
