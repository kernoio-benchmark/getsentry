# Sentry Development Guide for AI Agents

> **IMPORTANT**: AGENTS.md files are the source of truth for AI agent instructions. Always update the relevant AGENTS.md file when adding or modifying agent guidance. Do not add to CLAUDE.md or Cursor rules.

## Command Execution Guide

Critical command instructions that apply across all Sentry development.

### Python Command Execution Requirements

**CRITICAL**: Python commands (pytest, mypy, prek, etc.) MUST run in the virtualenv. Prefix the full relative path, or source the activate script:

```bash
cd /path/to/sentry && .venv/bin/pytest tests/...
cd /path/to/sentry && source .venv/bin/activate && pytest tests/...
```

For AI agents: always use `required_permissions: ['all']` for Python commands to avoid sandbox permission issues.

### Backend Development Commands

#### Setup

```bash
# Refreshes dependencies. SENTRY_DEVENV_FRONTEND_ONLY=1 skips migrations
# (not needed for pytest). HIGHLY RECOMMENDED.
SENTRY_DEVENV_FRONTEND_ONLY=1 devenv sync

# Refresh dependencies AND apply migrations (only for a working dev server).
devenv sync

direnv allow    # activate the environment
devservices up  # bring up services
```

That is all that is required to run `pytest`. `devservices serve` starts the development server. For full environment setup/troubleshooting, use the **`setup-dev`** skill.

To bump an existing Python dependency, use the **`bump-sentry-dependency`** skill.

When the devserver runs, its full console output is teed to `.artifacts/dev.log` (ANSI-stripped, gitignored, truncated per process start; override with `SENTRY_DEV_LOG_FILE`). Agents can't see the devserver terminal — `tail`/`grep` this file to inspect startup, reloads, request logs, and tracebacks. Dev-only.

#### Linting

prek is the single entrypoint for all lint, format, and type-checking tools. Before considering a task complete, run `.venv/bin/prek run -q` (detects changed files automatically). To run a specific hook:

```bash
SENTRY_MYPY_PRE_PUSH=1 .venv/bin/prek run -q mypy --files src/sentry/foo/bar.py --stage pre-push
.venv/bin/prek run -q ruff-check --files src/sentry/foo/bar.py
```

If a hook fails, fix the issues, stage changes, then re-run until it passes.

#### Testing

For backend-scoped changes, prioritize running the individual relevant pytest files or nodeids locally. `make test-selective` is not optimized for routine local development, so use it only when useful for a particular investigation. If a PR's backend CI fails, inspect the `select-tests` job in `.github/workflows/backend.yml` and its selected-test output to identify the exact nodeids CI ran, then run those locally.

```bash
# Run a specific test file. Do not run pytest by itself; it'll take forever!
.venv/bin/pytest -n3 -svv --reuse-db tests/sentry/api/test_base.py
```

#### Database Operations

Creating/applying migrations and resolving rebase conflicts (`makemigrations`, `django migrate`, `update-migration`) → use the **`generate-migration`** skill. To reset the database (`make reset-db`) or other environment tasks → use the **`setup-dev`** skill.

### Frontend Development Commands

#### Development Setup

```bash
pnpm run dev     # full dev server (requires devservices up)
pnpm run dev-ui  # UI-only with hot reload; proxies API to production sentry.io
```

Dev server URLs: full devserver `http://dev.getsentry.net:8000`; frontend-only `https://sentry.dev.getsentry.net:7999/`.

#### Typechecking

Run `pnpm run typecheck` to run the typescript type checker. It does not accept file paths. DO NOT use `tsc` directly.

#### Linting

```bash
pnpm run lint:js                          # all JS/TS
pnpm run lint:js static/app/components/avatar.tsx # selected files in their owning projects
pnpm --filter @sentry/icons lint          # Icons: JS/TS, CSS
pnpm --filter @sentry/scraps lint         # Scraps: JS/TS, CSS
pnpm run lint:suppressions --ci          # check suppression budgets for all workspaces
pnpm run lint:suppressions --prune       # reduce suppression budgets for all workspaces
pnpm run lint:format                     # formatting for the whole repository
pnpm run fix                              # auto-fix
```

#### Testing

```bash
pnpm test-ci <file_path>                       # run tests
pnpm test-ci components/avatar.spec.tsx        # specific file(s)
```

### Context-Aware Loading

Use the right AGENTS.md for the area you're working in:

- **Backend** (`src/**/*.py`) → `src/AGENTS.md` (backend patterns)
- **Tests** (`tests/**/*.py`, `src/**/tests/**/*.py`) → `tests/AGENTS.md` (testing patterns)
- **Frontend** (`static/**/*.{ts,tsx,js,jsx,css,scss}`) → `static/AGENTS.md` (frontend patterns)
- **General** → This file (`AGENTS.md`) for Sentry overview and commands

Workflow steering (commit, pre-commit, hybrid cloud, etc.) lives in **skills** (`.agents/skills/`). Attach or read the area `AGENTS.md` when working in that tree. Add or update guidance in the appropriate AGENTS.md or skill—do not duplicate long guidance in editor-specific rule files.

## Agent Skills

Skills under `.agents/skills/` should follow the same current-practice conventions as the rest of the repo:

- Prefer diff-first review workflows. When no explicit file or patch is provided, default to the current branch diff.
- Keep skill descriptions aligned with natural user requests like PR review, branch audit, and Warden follow-up.
- If a downstream review harness controls the final response shape, do not hardcode a competing output format in the skill. Specify required evidence instead.

## Feature Flags (FlagPole)

New features should be gated behind a flag: register in `src/sentry/features/temporary.py`, check with `features.has(...)` (Python) or `organization.features.includes(...)` (frontend). For the full workflow (registration, `api_expose`, tests, rollout) → use the **`feature-flags`** skill, or see https://develop.sentry.dev/feature-flags/. Deleting a finished flag or option requires a fixed PR order across sentry and sentry-options-automator → use the **`remove-option-or-flag`** skill.

## Customer Information

**Never include customer information in pull requests, commits, or code.** This covers organization slugs, user emails, account names, internal IDs tied to specific customers, support ticket details, and any other data that identifies a Sentry customer. Use anonymized or synthetic examples (`org-slug`, `user@example.com`) in PR descriptions, commit messages, code comments, tests, and fixtures. If a real identifier is needed for debugging, keep it in internal tooling (Slack, tickets, private notes)—not in the public git history.

## Pull Requests

Frontend (`static/`) and backend (`src/`, `tests/`) are **not atomically deployed**. A CI check enforces this.

- If your changes touch both frontend and backend, split them into **separate PRs**.
- Land the backend PR first when the frontend depends on new API changes.
- Pure test additions alongside `src/` changes are fine in one PR.

<!-- har:agent-environment:start -->

## HAR / agent environment

This repository uses a `.har/` harness. It is **how you run and verify this
project** — launch a slot for live apps, browsers and screenshots; never
hand-roll docker or dev-server startup. If a harness command fails, fix the
harness or report it; do not fall back to ad-hoc commands.

1. **Launch first** — `har_launch_environment` / `har env launch <id>`. Make ALL
   edits under the returned **work dir**, never the main checkout. Bind tracker
   work with `--work-id` / `--work-url` when the task names an issue.
2. **Verify before done** — `har_run_verification` (`full: true`) /
   `har env verify <id> --full`. Commit in the session worktree.
3. **Stop at handoff** — report summary, session branch and preview URLs, then
   wait. Never autonomously `complete`, `teardown`, push, or open a PR.
4. **All slots taken?** Occupied slots always block a launch, and you never free
   one yourself. Run `har env status`, then show the user every slot — branch,
   work unit, what it achieves, last verify, and whether its commits are merged,
   pushed or unpushed — and recommend which to close: merged or abandoned work
   with nothing left to do first; never one with unpushed commits. On approval:
   `complete` / `teardown <id>`, then launch.

Customize the harness only through `harness.env`, `stages.json` + `.har/stages/`,
`.har/hooks/` and `.har/plugins/` — there is no generated `.har/*.sh` entry-point
surface.

Full detail — slot environment, readiness, definition of done, project commands,
commit gate: [`.har/README.md`](.har/README.md) and [`.har/stages.json`](.har/stages.json).
<!-- har:agent-environment:end -->

### HAR project-specific notes

- **What a slot runs**: Django (`sentry devserver --no-watchers`) on `API_PORT`, the
  rsbuild dev server on `FE_PORT` (open this one), and its own Snuba API
  (`SNUBA` = `127.0.0.1:1218<id>`; pytest gets a second one on `1228<id>`).
  Shared, once per machine: Postgres 14 (per-slot DB `agent_<id>` cloned from a
  migrated template), Redis 7 (per-slot DB index) and ClickHouse (per-slot
  databases `har_agent<id>[_test]`). Diagram: `.har/README.md` → "How a slot is
  wired". Get URLs with `har env agent <id> url`.
- **Login**: `admin@sentry.io` / `admin`, org `sentry`, project `internal`
  (created by `sentry upgrade` in dev mode; no seed step).
- **Snuba-backed tests run for real** (`SnubaTestCase`, `requires_snuba`) against the
  slot's test Snuba. Snuba-backed pages load, but the running app's Snuba stays
  empty: there is no ingestion.
- **Not available in slots**: Kafka, Relay, taskworkers, Symbolicator, objectstore —
  SDK events are not ingested; tasks run eagerly in-process. Don't start
  devservices or a Snuba yourself (repair with
  `bash .har/scripts/sentry-slot.sh snuba-up` and the slot env loaded); tests
  needing those services are reported as `HAR:` skipped by full verify — call
  them out in your handoff.
- **Inside a slot the commands above do NOT apply as written**: they assume
  devservices on `localhost:5432`/`6379`, which on this machine belong to other
  projects. Never run bare `.venv/bin/pytest` and never conclude "tests can't run
  here". Instead:
  - Backend tests: `har env run-stage <id> unit-tests` (changed/related files), or
    `HAR_TESTS="<paths or node ids>" har env run-stage <id> unit-tests`.
  - Everything else (prek, `sentry` commands, pnpm): first
    `cd <work dir> && set -a && . ./.env.agent.<id> && set +a`, then use
    `.venv/bin/…` / `"$PYTHON_BIN"` / `pnpm` (Node 26 is linked into `.venv/bin`).
- **New migration** → apply it to the slot DB (`"$PYTHON_BIN" -m sentry upgrade --noinput`
  with the slot env loaded), then `har env agent <id> restart`, or the live app 500s.
- **Backend down / UI 504 after an edit** → the dev server drops its workers on an
  import error and doesn't respawn them. Check `har env agent <id> logs web`, fix,
  then `har env agent <id> restart`.
- **Definition of done**: `har env verify <id> --full` passes (django check, health,
  changed-file lint, related pytest/jest, typecheck when TS changed, login + API + UI
  smoke), the change is exercised in the running slot, and frontend/backend changes
  are split into separate PRs. Handing off without a full verify run is not done.
- **Factory lines** (`har line status`): multi-PR programs in `.har/lines/<id>/`.
  Two are installed: `flag-cleanup` (retire a FlagPole flag) and `flagged-feature`
  (ship a feature dark behind a flag). When the task is one of those, read the
  line's `README.md` and work one station per slot. Before handing off a station,
  run both `har env verify <id> --full` and
  `HAR_FLAG=organizations:<name> har line gate <station> --line <line> --agent <id>`.
  Line gates are never part of verify. Never hand off a red gate.
