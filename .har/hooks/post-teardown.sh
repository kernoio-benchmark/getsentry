#!/usr/bin/env bash
# post-teardown — drop this slot's pytest databases (created by the
# backend-tests stage: test_{region,control,secondary}_agent<id>), so the next
# session on this slot builds them from its own branch's models. HAR itself
# already drops agent_<id>. Failure only warns (HARNESS_HOOK_POST_FAILURE=warn).
set -euo pipefail

: "${AGENT_ID:?AGENT_ID not set (HAR hook contract)}"
container="har-sentry-db-1"
docker ps --format '{{.Names}}' | grep -qx "$container" || exit 0

for alias in region control secondary; do
  docker exec "$container" dropdb -U postgres --if-exists "test_${alias}_agent${AGENT_ID}"
done
echo "Dropped pytest databases for agent ${AGENT_ID}." >&2
