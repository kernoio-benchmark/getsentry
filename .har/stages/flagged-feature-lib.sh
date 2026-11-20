#!/usr/bin/env bash
# Shared implementation of the flagged-feature line's gate stages. Not a stage
# itself: each flagged-feature-*.sh wrapper execs this with its check name.
#
# Usage: flagged-feature-lib.sh <check> <agent-id>
#   check: flag-registered | migrations-consistent | backend-gated | frontend-gated
#
# Input: HAR_FLAG — the new feature's full flag name, e.g. organizations:my-feature.
#   HAR_FLAG=organizations:my-feature har line gate S3 --line flagged-feature --agent 3
#
# Stage contract (.har/STAGES.md): progress on stderr, one JSON result object on
# stdout, real exit code. Searches run with `git grep --untracked` in $WORK_DIR,
# so uncommitted edits in the slot count.
set -euo pipefail

CHECK="${1:?Usage: flagged-feature-lib.sh <check> <agent-id>}"
AGENT_ID="${2:-${AGENT_ID:?Usage: flagged-feature-lib.sh <check> <agent-id>}}"
STAGE_ID="flagged-feature-${CHECK}"
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

cd "$WORK_DIR"
TEMPORARY=src/sentry/features/temporary.py
ggrep() { git grep -n --untracked -F "$@" || true; }

# migrations-consistent needs no flag; every other check does.
if [ "$CHECK" != "migrations-consistent" ]; then
  FLAG="${HAR_FLAG:-}"
  if [ -z "$FLAG" ]; then
    echo "HAR_FLAG is not set. Run: HAR_FLAG=organizations:<name> har line gate <station> --line flagged-feature --agent ${AGENT_ID}" >"$REPORT"
    finish fail "HAR_FLAG not set"
  fi
  case "$FLAG" in
    organizations:* | projects:* | users:*) ;;
    *) echo "HAR_FLAG must be a full flag name with its scope prefix, got: $FLAG" >"$REPORT"; finish fail "bad HAR_FLAG" ;;
  esac
  SHORT="${FLAG#*:}"
  echo "flag: $FLAG (frontend name: $SHORT)" >>"$REPORT"
fi
echo "==> [$STAGE_ID agent-${AGENT_ID}] in $WORK_DIR" >&2

case "$CHECK" in
  flag-registered)
    # S2: the feature ships dark. Registered as a temporary FlagPole flag.
    reg=$(ggrep -e "manager.add(\"$FLAG\"" -- "$TEMPORARY")
    if [ -z "$reg" ]; then
      echo "$FLAG is not registered in $TEMPORARY. Add: manager.add(\"$FLAG\", OrganizationFeature, FeatureHandlerStrategy.FLAGPOLE, api_expose=True)  (feature-flags skill)" >>"$REPORT"
      finish fail "flag not registered"
    fi
    echo "registered: $reg" >>"$REPORT"
    case "$reg" in *FeatureHandlerStrategy.FLAGPOLE*) ;; *)
      echo "Registration must use FeatureHandlerStrategy.FLAGPOLE so rollout is controlled from sentry-options-automator." >>"$REPORT"
      finish fail "not a FlagPole flag" ;;
    esac
    case "$reg" in *"default=True"*)
      echo "default=True would ship the feature ON before rollout. New features default off." >>"$REPORT"
      finish fail "default=True" ;;
    esac
    finish pass "registered as FlagPole, default off"
    ;;

  migrations-consistent)
    # S2: every model change has its migration and migrations_lockfile.txt is
    # current — the same command as CI's .github/workflows/scripts/migration-check.sh,
    # against the slot's DB and config.
    set +e
    SENTRY_LOG_LEVEL=ERROR "${PYTHON_BIN:-.venv/bin/python}" -m sentry django makemigrations --check --dry-run --no-input >>"$REPORT" 2>&1
    rc=$?
    set -e
    case "$rc" in
      0) finish pass "no missing migrations, lockfile current" ;;
      1) echo "Migration required: sentry django makemigrations -n <name> && git add migrations_lockfile.txt (generate-migration skill)" >>"$REPORT"; finish fail "migration missing" ;;
      2) echo "Lockfile mismatch: sentry django makemigrations -n <name> && git add migrations_lockfile.txt" >>"$REPORT"; finish fail "lockfile mismatch" ;;
      *) finish fail "makemigrations exited $rc" ;;
    esac
    ;;

  backend-gated)
    # S3: new backend behaviour is actually behind the flag, and tests exercise
    # it with the flag on (self.feature(...)).
    reads=$(ggrep -e "\"$FLAG\"" -- src | grep -v -E "^${TEMPORARY}:" || true)
    tests=$(ggrep -e "\"$FLAG\"" -- tests)
    if [ -z "$reads" ]; then
      echo "No backend read of $FLAG in src/ — gate the new endpoint/behaviour with features.has(\"$FLAG\", organization, actor=request.user)." >>"$REPORT"
      finish fail "flag registered but never read"
    fi
    if [ -z "$tests" ]; then
      printf 'Backend reads it:\n%s\nbut no test enables it — add tests under `with self.feature("%s"):` and one asserting the flag-off behaviour.\n' "$reads" "$FLAG" >>"$REPORT"
      finish fail "no test enables the flag"
    fi
    printf 'reads:\n%s\ntests:\n%s\n' "$reads" "$tests" >>"$REPORT"
    finish pass "backend gated and tested"
    ;;

  frontend-gated)
    # S4: the UI checks the flag, which only works when the backend exposes it.
    reg=$(ggrep -e "manager.add(\"$FLAG\"" -- "$TEMPORARY")
    case "$reg" in *"api_expose=True"*) ;; *)
      echo "Registration lacks api_expose=True, so organization.features never contains '$SHORT' and the UI stays hidden. Fix it in a backend PR first." >>"$REPORT"
      finish fail "flag not exposed to the frontend" ;;
    esac
    uses=$(ggrep -e "'$SHORT'" -e "\"$SHORT\"" -e "\`$SHORT\`" -- static/app | grep -v -E '\.spec\.tsx?:' || true)
    specs=$(ggrep -e "'$SHORT'" -e "\"$SHORT\"" -e "\`$SHORT\`" -- static/app | grep -E '\.spec\.tsx?:' || true)
    if [ -z "$uses" ]; then
      echo "No frontend check of '$SHORT' in static/app — gate the UI with organization.features.includes('$SHORT') or <Feature features=\"$SHORT\">." >>"$REPORT"
      finish fail "UI not gated"
    fi
    if [ -z "$specs" ]; then
      printf 'UI checks it:\n%s\nbut no spec renders it with the flag on — add OrganizationFixture({features: ['"'"'%s'"'"']}) to a spec.\n' "$uses" "$SHORT" >>"$REPORT"
      finish fail "no spec enables the flag"
    fi
    printf 'uses:\n%s\nspecs:\n%s\n' "$uses" "$specs" >>"$REPORT"
    finish pass "UI gated and tested"
    ;;

  *)
    echo "unknown check: $CHECK" >>"$REPORT"
    finish fail "unknown check"
    ;;
esac
