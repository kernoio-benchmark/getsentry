#!/usr/bin/env bash
# flagged-feature line gate stage: backend-gated (never on verify). Logic: flagged-feature-lib.sh.
exec bash "$(dirname "${BASH_SOURCE[0]}")/flagged-feature-lib.sh" backend-gated "${1:-${AGENT_ID:?}}"
