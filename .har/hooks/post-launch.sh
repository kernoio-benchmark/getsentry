#!/usr/bin/env bash
# post-launch — start this slot's own Snuba for the running app:
# container har-sentry-snuba-agent<id> on 127.0.0.1:1218<id> (the SNUBA url in
# .env.agent.<id>), backed by ClickHouse database har_agent<id> on the shared
# har-sentry-clickhouse-1. Runs after PM2 is up; Sentry only connects to Snuba
# on the first query, so the order is fine.
#
# The pytest Snuba (1228<id>) is started lazily by stages/backend-tests.sh.
# Failure only warns (HARNESS_HOOK_POST_FAILURE=warn): the slot still works,
# Snuba-backed pages and tests then fail until `snuba-up` succeeds.
set -euo pipefail

: "${AGENT_ID:?AGENT_ID not set (HAR hook contract)}"
HAR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec bash "$HAR_DIR/scripts/sentry-slot.sh" snuba-up live
