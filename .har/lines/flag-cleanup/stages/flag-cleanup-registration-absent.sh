#!/usr/bin/env bash
# flag-cleanup line gate stage: registration-absent (never on verify). Logic: flag-cleanup-lib.sh.
exec bash "$(dirname "${BASH_SOURCE[0]}")/flag-cleanup-lib.sh" registration-absent "${1:-${AGENT_ID:?}}"
