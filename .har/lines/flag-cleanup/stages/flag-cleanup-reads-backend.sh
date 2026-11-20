#!/usr/bin/env bash
# flag-cleanup line gate stage: reads-backend (never on verify). Logic: flag-cleanup-lib.sh.
exec bash "$(dirname "${BASH_SOURCE[0]}")/flag-cleanup-lib.sh" reads-backend "${1:-${AGENT_ID:?}}"
