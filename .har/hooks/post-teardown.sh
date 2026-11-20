#!/usr/bin/env bash
# post-teardown — remove what the slot created outside HAR's own bookkeeping,
# so the next session on this slot starts from its own branch's models:
#   * pytest databases (backend-tests stage): test_{region,control,secondary}_agent<id>
#   * the slot's Snuba containers + ClickHouse databases (live and test):
#     scripts/sentry-slot.sh snuba-down
# HAR itself already drops agent_<id>. Failure only warns (HARNESS_HOOK_POST_FAILURE=warn).
set -euo pipefail

: "${AGENT_ID:?AGENT_ID not set (HAR hook contract)}"
HAR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

container="har-sentry-db-1"
if docker ps --format '{{.Names}}' | grep -qx "$container"; then
  for alias in region control secondary; do
    docker exec "$container" dropdb -U postgres --if-exists "test_${alias}_agent${AGENT_ID}"
  done
  echo "Dropped pytest databases for agent ${AGENT_ID}." >&2
fi

bash "$HAR_DIR/scripts/sentry-slot.sh" snuba-down
