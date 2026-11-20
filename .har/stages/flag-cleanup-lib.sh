#!/usr/bin/env bash
# Shared implementation of the flag-cleanup line's gate stages. Not a stage
# itself: each flag-cleanup-*.sh wrapper execs this with its check name.
#
# Usage: flag-cleanup-lib.sh <check> <agent-id>
#   check: not-permanent | reads-backend | reads-frontend | registration-absent
#
# Input: HAR_FLAG — the full flag name, e.g. organizations:my-feature.
#   HAR_FLAG=organizations:my-feature har line gate S1 --line flag-cleanup --agent 3
#
# Stage contract (.har/STAGES.md): progress on stderr, one JSON result object on
# stdout, real exit code. Searches run with `git grep --untracked` in $WORK_DIR,
# so uncommitted edits in the slot count.
set -euo pipefail

CHECK="${1:?Usage: flag-cleanup-lib.sh <check> <agent-id>}"
AGENT_ID="${2:-${AGENT_ID:?Usage: flag-cleanup-lib.sh <check> <agent-id>}}"
STAGE_ID="flag-cleanup-${CHECK}"
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
ARTIFACTS_DIR="$HAR_DIR/artifacts/$STAGE_ID"
mkdir -p "$ARTIFACTS_DIR"
REPORT="$ARTIFACTS_DIR/agent-${AGENT_ID}.txt"
: >"$REPORT"

now_ms() { node -e 'process.stdout.write(String(Date.now()))' 2>/dev/null || echo 0; }
START=$(now_ms)

finish() {
  local status="$1" summary="$2"
  node -e '
    const [stageId, agent, status, total, summary, reportPath] = process.argv.slice(1);
    let output = "";
    try { output = require("fs").readFileSync(reportPath, "utf8").trim().split("\n").slice(0, 50).join("\n"); } catch {}
    process.stdout.write(JSON.stringify({ status, stageId, kind: "test", agent_id: Number(agent),
      total_ms: Number(total), summary, report: reportPath, output }, null, 2) + "\n");
  ' "$STAGE_ID" "$AGENT_ID" "$status" "$(($(now_ms) - START))" "$summary" "$REPORT"
  echo "==> [$STAGE_ID agent-${AGENT_ID}] $status: $summary" >&2
  [ "$status" = "pass" ] && exit 0 || exit 1
}

FLAG="${HAR_FLAG:-}"
if [ -z "$FLAG" ]; then
  echo "HAR_FLAG is not set. Run: HAR_FLAG=organizations:<name> har line gate <station> --line flag-cleanup --agent ${AGENT_ID}" >"$REPORT"
  finish fail "HAR_FLAG not set"
fi
case "$FLAG" in
  organizations:* | projects:* | users:*) ;;
  *) echo "HAR_FLAG must be a full flag name with its scope prefix, got: $FLAG" >"$REPORT"; finish fail "bad HAR_FLAG" ;;
esac
SHORT="${FLAG#*:}" # what the frontend reads: organization.features.includes('<short>')

cd "$WORK_DIR"
TEMPORARY=src/sentry/features/temporary.py
PERMANENT=src/sentry/features/permanent.py

# git grep -F over tracked + untracked files; never fails on "no match".
ggrep() { git grep -n --untracked -F "$@" || true; }

echo "flag: $FLAG (frontend name: $SHORT)" >>"$REPORT"
echo "==> [$STAGE_ID agent-${AGENT_ID}] $FLAG in $WORK_DIR" >&2

case "$CHECK" in
  not-permanent)
    # S0 question: is this flag removable at all? Plan/tier entitlements live in
    # permanent.py and are never deleted. Still true after S4 (flag gone) — the
    # ratchet runs this at every later station.
    hits=$(ggrep -e "\"$FLAG\"" -- "$PERMANENT")
    if [ -n "$hits" ]; then
      printf '%s\n%s\n' "$FLAG is registered in $PERMANENT — it is permanent, not something to clean up." "$hits" >>"$REPORT"
      finish fail "flag is permanent"
    fi
    reg=$(ggrep -e "manager.add(\"$FLAG\"" -- "$TEMPORARY")
    if [ -n "$reg" ]; then
      echo "registered: $reg" >>"$REPORT"
      case "$reg" in *"default=True"*)
        echo "WARNING: default=True — the flag stays ON for features.has() after the automator block is removed (S3), but reads false in the frontend. Collapse every read before S3." >>"$REPORT" ;;
      esac
      finish pass "registered in temporary.py"
    fi
    echo "not registered in $TEMPORARY (already removed, or the name is wrong — check the spelling)" >>"$REPORT"
    finish pass "not registered"
    ;;

  reads-backend)
    # S1: no backend read remains. The registration line in temporary.py (and
    # a SENTRY_FEATURES default, if any) are S4's job, so they don't count.
    hits=$(ggrep -e "$FLAG" -- src tests \
      | grep -v -E "^${TEMPORARY}:[0-9]+:.*manager\.add\(\"${FLAG}\"" \
      | grep -v -E "^src/sentry/conf/server\.py:" || true)
    if [ -n "$hits" ]; then
      n=$(printf '%s\n' "$hits" | wc -l)
      printf 'Backend still reads %s (%s hit(s)) — collapse each to the outcome that won, delete the losing branch and its tests:\n%s\n' "$FLAG" "$n" "$hits" >>"$REPORT"
      finish fail "$n backend read(s) left"
    fi
    echo "no backend reads of $FLAG in src/ or tests/" >>"$REPORT"
    finish pass "no backend reads"
    ;;

  reads-frontend)
    # S2: no frontend read remains: features.includes('x'), <Feature features="x">,
    # features: ['x'] fixtures, … — any quoted occurrence of the short name.
    hits=$(ggrep -e "'$SHORT'" -e "\"$SHORT\"" -e "\`$SHORT\`" -e "$FLAG" -- static)
    if [ -n "$hits" ]; then
      n=$(printf '%s\n' "$hits" | wc -l)
      printf 'Frontend still reads %s (%s hit(s)). If a hit is an unrelated string with the same text, rename nothing — say so in the handoff:\n%s\n' "$SHORT" "$n" "$hits" >>"$REPORT"
      finish fail "$n frontend read(s) left"
    fi
    echo "no frontend reads of '$SHORT' in static/" >>"$REPORT"
    finish pass "no frontend reads"
    ;;

  registration-absent)
    # S4: registration removed, and nothing anywhere still names the flag.
    hits=$(ggrep -e "$FLAG" -- src tests static fixtures)
    if [ -n "$hits" ]; then
      n=$(printf '%s\n' "$hits" | wc -l)
      printf '%s is still referenced (%s hit(s)):\n%s\n' "$FLAG" "$n" "$hits" >>"$REPORT"
      finish fail "$n reference(s) left"
    fi
    echo "$FLAG is gone from src/, tests/, static/, fixtures/" >>"$REPORT"
    finish pass "registration removed"
    ;;

  *)
    echo "unknown check: $CHECK" >>"$REPORT"
    finish fail "unknown check"
    ;;
esac
