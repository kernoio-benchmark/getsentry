#!/usr/bin/env bash
# flagged-feature line gate stage: flag-registered (never on verify). Logic: flagged-feature-lib.sh.
exec bash "$(dirname "${BASH_SOURCE[0]}")/flagged-feature-lib.sh" flag-registered "${1:-${AGENT_ID:?}}"
