#!/usr/bin/env bash
# unit-tests stage (tier: full) — pytest for the Python tests related to this
# slot's changes. Sentry's full suite is far too large to run per change, so:
#   * changed tests/**/test_*.py files run directly;
#   * changed src/sentry/<path>/<mod>.py maps to tests/sentry/<path>/test_<mod>.py
#     (when that file exists).
# No related tests → pass with a note. Uses the shared harness Postgres
# (per-slot test DBs) and Redis via .har/pytest/har_sentry_pytest.py, and the
# slot's own TEST Snuba (har-sentry-snuba-test-agent<id> on 1228<id>, its own
# ClickHouse database — started here on first use, removed on teardown), so
# `reset_snuba` never touches the running app's or another slot's data. Tests
# needing Kafka/Symbolicator/Objectstore are reported as skipped.
# Log: .har/artifacts/backend-tests/.
# Set HAR_TESTS="<paths or node ids>" to run an explicit selection instead.
set -euo pipefail

AGENT_ID="${1:-${AGENT_ID:?Usage: backend-tests.sh <agent-id>}}"
HAR_DIR="${HAR_HARNESS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# `har env verify` exports the slot env; `har env run-stage` does not, so fall
# back to the slot registry + .env.agent.<id>.
if [ -z "${WORK_DIR:-}" ]; then
  registry="$HAR_DIR/slots/agent-${AGENT_ID}.json"
  [ -f "$registry" ] || { echo "Slot ${AGENT_ID} is not launched: har env launch ${AGENT_ID}" >&2; exit 1; }
  WORK_DIR="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["workDir"])' "$registry")"
fi
ENV_FILE="${ENV_FILE:-$WORK_DIR/.env.agent.${AGENT_ID}}"
if [ -z "${PYTHON_BIN:-}" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi
cd "$WORK_DIR"

artifacts="$HAR_DIR/artifacts/backend-tests"
mkdir -p "$artifacts"
log_file="$artifacts/agent-${AGENT_ID}.log"

tests=()
changed=()
if [ -n "${HAR_TESTS:-}" ]; then
  # Explicit selection (space-separated paths / node ids, relative to the work
  # dir): HAR_TESTS="tests/sentry/foo/test_bar.py::TestX" har env run-stage <id> unit-tests
  read -r -a tests <<<"$HAR_TESTS"
else
  mapfile -t changed < <(bash "$HAR_DIR/scripts/sentry-slot.sh" changed-files)
fi
for f in "${changed[@]+"${changed[@]}"}"; do
  case "$f" in
    tests/*/test_*.py | tests/test_*.py) tests+=("$f") ;;
    src/sentry/*.py)
      rel="${f#src/sentry/}"
      candidate="tests/sentry/$(dirname "$rel")/test_$(basename "$rel")"
      candidate="${candidate/\/.\//\/}"
      [ -f "$candidate" ] && tests+=("$candidate")
      ;;
  esac
done
mapfile -t tests < <(printf '%s\n' "${tests[@]+"${tests[@]}"}" | sed '/^$/d' | sort -u)

if [ "${#tests[@]}" -eq 0 ]; then
  echo "No changed or related backend test files — nothing to run." | tee "$log_file"
  exit 0
fi

echo "Running ${#tests[@]} test file(s): ${tests[*]}" | tee "$log_file"

# The slot's test Snuba (idempotent; ~25s the first time per session).
if AGENT_ID="$AGENT_ID" bash "$HAR_DIR/scripts/sentry-slot.sh" snuba-up test 2>&1 | tee -a "$log_file"; then
  export HAR_SNUBA_TEST_URL="http://127.0.0.1:1228${AGENT_ID}"
  export SNUBA="$HAR_SNUBA_TEST_URL"
else
  echo "WARNING: slot test Snuba could not start — Snuba-dependent tests will be reported as HAR: skipped." | tee -a "$log_file"
fi
set +e
PYTHONPATH="$HAR_DIR/pytest${PYTHONPATH:+:$PYTHONPATH}" \
  "${PYTHON_BIN:-.venv/bin/python}" -m pytest -p har_sentry_pytest --reuse-db -q -rs \
  "${tests[@]}" >>"$log_file" 2>&1
code=$?
set -e
tail -n 40 "$log_file"
exit "$code"
