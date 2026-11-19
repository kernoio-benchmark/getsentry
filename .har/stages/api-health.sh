#!/usr/bin/env bash
# api-health (tier: quick) — Django health for the slot's primary app.
# Sentry's HealthCheck middleware answers /_health/ (HARNESS_HEALTH_CHECK_PATH)
# on API_PORT before ALLOWED_HOSTS / auth, so this proves the web process is up.
set -euo pipefail

AGENT_ID="${1:-${AGENT_ID:?Usage: api-health.sh <agent-id>}}"
: "${API_PORT:?API_PORT not set — launch the slot first: har env launch ${AGENT_ID}}"

exec curl -fsS --max-time 10 "http://localhost:${API_PORT}${HARNESS_HEALTH_CHECK_PATH:-/_health/}"
