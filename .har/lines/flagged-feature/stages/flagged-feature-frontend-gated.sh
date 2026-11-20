#!/usr/bin/env bash
# flagged-feature line gate stage: frontend-gated (never on verify). Logic: flagged-feature-lib.sh.
exec bash "$(dirname "${BASH_SOURCE[0]}")/flagged-feature-lib.sh" frontend-gated "${1:-${AGENT_ID:?}}"
