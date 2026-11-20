#!/usr/bin/env bash
# flag-cleanup line gate stage: not-permanent (never on verify). Logic: flag-cleanup-lib.sh.
exec bash "$(dirname "${BASH_SOURCE[0]}")/flag-cleanup-lib.sh" not-permanent "${1:-${AGENT_ID:?}}"
