#!/usr/bin/env bash
# flag-cleanup line gate stage: reads-frontend (never on verify). Logic: flag-cleanup-lib.sh.
exec bash "$(dirname "${BASH_SOURCE[0]}")/flag-cleanup-lib.sh" reads-frontend "${1:-${AGENT_ID:?}}"
