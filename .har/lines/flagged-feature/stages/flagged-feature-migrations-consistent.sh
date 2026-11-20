#!/usr/bin/env bash
# flagged-feature line gate stage: migrations-consistent (never on verify). Logic: flagged-feature-lib.sh.
exec bash "$(dirname "${BASH_SOURCE[0]}")/flagged-feature-lib.sh" migrations-consistent "${1:-${AGENT_ID:?}}"
