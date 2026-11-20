# .har — Agent Harness for getsentry/sentry

This directory is the **agent harness** for this repository. It lets AI coding
agents run Sentry in isolated slots — own git worktree, own ports, own
Postgres database, own Redis DB index — and verify their changes.

Generated and maintained by [`har`](https://github.com/os-factory/har) (profile
`default`). Run `har env maintain` when the stack changes.

**The harness is how you run this project.** Need Sentry live — manual testing,
a browser session, screenshots? `launch` a slot; don't hand-roll
`devservices up` / `sentry devserver` / docker. If a harness command fails, fix
the harness or report it — don't silently fall back to ad-hoc commands.

## What's in here

**Yours — the configuration surface:**

| File | Purpose |
|------|---------|
| `README.md` | This file — the harness reference |
| `harness.env` | Primary app, ports, `HARNESS_INFRA_SERVICES`, toolchain (`HARNESS_INSTALL_CMD`), migrate/readiness commands |
| `stages.json` | Registered stages, verification tiers (`verificationStages`), slot limit (`agentSlots.max = 3`), commit gate |
| `stages/api-health.sh` | Quick: Django `/_health/` on `API_PORT` |
| `stages/lint.sh` | Full: `prek run --files <changed>` + `pnpm run lint:js <changed JS/TS>` |
| `stages/backend-tests.sh` | Full stage `unit-tests`: pytest on changed / related Python test files (or `HAR_TESTS=…`) |
| `stages/frontend-checks.sh` | Full: `pnpm run typecheck` + jest on direct specs of changed JS/TS (skipped otherwise) |
| `hooks/post-launch.sh` | Starts the slot's own Snuba for the running app (`sentry-slot.sh snuba-up live`) |
| `hooks/post-teardown.sh` | Drops the slot's pytest DBs (`test_*_agent<id>`) and removes its Snuba containers + ClickHouse DBs (`snuba-down`) |
| `stages/readiness.sh` | Full: runs `HARNESS_READINESS_CMD` (agent-usable smoke) |
| `scripts/sentry-slot.sh` | Sentry helper called by `harness.env`, hooks and stages: `install`, `migrate`, `conf`, `changed-files`, `smoke`, `snuba-up [live\|test]`, `snuba-down`, `snuba-status`. Not an entry point. |
| `pytest/har_sentry_pytest.py` | pytest plugin loaded only by the `unit-tests` stage: Redis → harness Redis (per-slot DB), per-slot test DB names, Snuba → the slot's test Snuba, Kafka/Symbolicator/Objectstore-only failures → skips |
| `env.template` | Per-slot env (expanded into `.env.agent.<id>` at launch) |
| `ecosystem.agent.template.cjs` | PM2 processes for the primary app: `web` (Django) + `ui` (rsbuild) |
| `docker-compose.agent.yml` | Shared infra: `db` (Postgres 14), `redis` (Redis 7), `clickhouse` (Snuba's ClickHouse image) |
| `clickhouse/*.xml` | ClickHouse config, copied from Snuba's devservices config (memory capped at 4 GiB) |
| `STAGES.md` | Stage registry and script-contract guide |
| `justfile` | Optional shortcuts (requires `just`) |

**Generated state** (gitignored, don't edit):

| Path | Purpose |
|------|---------|
| `manifest.json` | Runtime version, profile, checksums — managed by the har CLI |
| `state/infra.env` | Resolved shared-infra host ports |
| `state/template-venv/`, `state/sentry-conf-template/` | Python env + Sentry config used only to migrate `template_sentry` |
| `slots/agent-<id>.json` | Slot registry (work dir, branch, ports, base commit) |
| `runs/` | Run history — `.har/runs/YYYY-MM-DD/HH-mm-ss_<stageId>_agent-<id>.json` |
| `artifacts/<stage>/agent-<id>.log` | Full logs of `lint`, `backend-tests` (stage `unit-tests`), `frontend-checks` |

## Quick start

```bash
har env launch 1            # first launch: ~15–30 min (template migration + deps); later ~5–10 min
har env verify 1            # quick: django check + /_health/ + UI proxy
har env verify 1 --full     # + lint, related tests, frontend checks, agent-usable smoke
har env agent 1 url         # resolved URLs
har env agent 1 logs web    # Django log      (logs ui → rsbuild)
har env teardown 1          # or: har env complete 1
```

MCP: `har_launch_environment`, `har_run_verification` (`full: true`),
`har_teardown_environment` / `har_complete_environment`. CLI and MCP are the
only entry points and write identical run records.

## Slot environment

| | |
|--|--|
| **UI (open this)** | `http://localhost:${FE_PORT}` — rsbuild dev server, proxies to Django |
| **Django / API** | `http://localhost:${API_PORT}` — `/_health/`, `/api/0/…` |
| **Login** | `admin@sentry.io` / `admin` (superuser) |
| **Org / project** | `sentry` / `internal` (single-organization mode) |
| **Postgres** | database `agent_<id>` on `localhost:${PGPORT}` (user `postgres` / `password`) |
| **Redis** | `localhost:${REDIS_PORT}` DB `${REDIS_DB}` (= agent id) |
| **Snuba** | `${SNUBA}` = `http://127.0.0.1:1218<id>` — the slot's own Snuba API, ClickHouse database `har_agent<id>` (pytest uses a second one on `1228<id>`) |
| **Sentry config** | `${SENTRY_CONF}` = `<work dir>/.sentry-har/` (generated, git-excluded) |
| **Python / Node** | `<work dir>/.venv` (`PYTHON_BIN`); Node v26 (devenv pin) linked into `.venv/bin` |
| **Work dir** | Fresh worktree per launch — see launch output or `.har/slots/agent-<id>.json` |

Ports are resolved at launch — read them with `har env agent <id> url` or from
`.env.agent.<id>`; never assume the formula values.

**Never edit the main checkout** — launch first, then make ALL edits under the
work dir. Python changes auto-reload (Django autoreloader); `static/` changes
trigger an rsbuild rebuild + full page reload. Use `har env agent <id> restart`
if a change doesn't take (e.g. new dependency → relaunch).

## How a slot is wired

Each slot has its own app processes **and** its own Snuba; the heavy servers
(Postgres, Redis, ClickHouse) run once per machine and isolate slots by
database. Every slot looks the same — `<N>` is the agent id:

```
 ┌─ slot <N> ─ worktree ~/worktrees/<base>-<sha4>-har-agent-<N>-<rand4> ────────────┐
 │                                                                                  │
 │   browser ──► rsbuild `ui`  :70N0 ──proxy──► Django `web`  :75N0                 │
 │               (PM2)                          (PM2)   │ SNUBA=127.0.0.1:1218N     │
 │                                                      ▼                           │
 │                                 Snuba API "live"   har-sentry-snuba-agentN       │
 │                                                    :1218N   (hooks/post-launch)  │
 │                                                                                  │
 │   har env run-stage N unit-tests                                                 │
 │   pytest + har_sentry_pytest ──► Snuba API "test"  har-sentry-snuba-test-agentN  │
 │                                                    :1228N   (started on 1st run) │
 └────────────┬──────────────────────┬──────────────────────────┬───────────────────┘
              │ Postgres             │ Redis                    │ ClickHouse
 ═════════════▼══════════════════════▼══════════════════════════▼══ shared, one per machine
   har-sentry-db-1          har-sentry-redis-1          har-sentry-clickhouse-1
   :15432 (scanned lane)    :16479 (fixed)              :18123 HTTP (fixed, debug only)
   ─────────────────        ─────────────────           ─────────────────────────
   template_sentry          DB 0      template          har_agentN       (live)
   agent_N       (app)      DB N      app               har_agentN_test  (pytest)
   test_*_agentN (pytest)   DB 16+N   Snuba live
                            DB 32+N   pytest
                            DB 48+N   Snuba test
```

Why two Snuba instances per slot: every `SnubaTestCase` test first calls
`reset_snuba`, which drops all data in its Snuba. Giving pytest its own
instance (own ClickHouse database) means a test run never wipes the running
app's data, and one slot never wipes another's — every slot clones the same
template, so they even share org/project ids. This is the same isolation
Sentry's CI uses for parallel test workers (`XDIST_PER_WORKER_SNUBA`,
`.github/workflows/scripts/bootstrap-snuba.py`): one ClickHouse server, and per
consumer its own ClickHouse database, Snuba API container and Snuba Redis DB.

### Lifecycle

```
 har env setup-infra        once per machine: db, redis, clickhouse (+ template_sentry)
        │
 har env launch N           worktree + .venv/node_modules, agent_N cloned & migrated,
        │                   PM2 web + ui, health check
        └─ hooks/post-launch.sh ──► snuba-up live    (~25 s: CREATE DATABASE,
        │                                             snuba bootstrap, snuba api)
 har env verify N --full
        └─ unit-tests stage ─────► snuba-up test     (first run only, ~25 s) → pytest
        │
 har env teardown|complete N  PM2 stopped, agent_N dropped, worktree removed
        └─ hooks/post-teardown.sh ► test_*_agentN dropped, snuba-down (both Snuba
                                    containers removed, both ClickHouse DBs dropped)
```

Inspect or repair a slot's Snuba (env loaded from `.env.agent.<id>`, or just
`AGENT_ID=<id>`): `bash .har/scripts/sentry-slot.sh snuba-status` /
`snuba-up live` (idempotent). Logs: `docker logs har-sentry-snuba-agent<id>`.

## Primary app vs shared services

| Resource | Model | Configuration |
|----------|-------|---------------|
| Sentry web (Django `web` + rsbuild `ui`) | Per slot, PM2 `har-sentry-agent-<id>-{web,ui}` | `ecosystem.agent.template.cjs` |
| Postgres 14 | One shared container `har-sentry-db-1`; per-slot DB `agent_<id>` cloned from `template_sentry` | `HARNESS_INFRA_SERVICES="db redis"` |
| Redis 7 | One shared container `har-sentry-redis-1`; per-slot logical DB = agent id (pytest: 32 + id; Snuba: 16 + id / 48 + id) | same |
| ClickHouse | One shared container `har-sentry-clickhouse-1`; per-slot databases `har_agent<id>` / `har_agent<id>_test` | `HARNESS_INFRA_SERVICES`, `clickhouse/*.xml` |
| Snuba API | **Per slot**, two containers: `har-sentry-snuba-agent<id>` (app, `:1218<id>`) and `har-sentry-snuba-test-agent<id>` (pytest, `:1228<id>`); image `ghcr.io/getsentry/snuba:nightly` | `hooks/post-launch.sh`, `scripts/sentry-slot.sh snuba-*` |
| Kafka / Relay / taskworkers / Symbolicator / objectstore / … | **Not run** — see below | — |

### Skipped full-dev setup (and the substitutes)

`devservices up` (default mode) runs Postgres, Redis, Snuba (+ ClickHouse,
Kafka), Relay, Spotlight and objectstore; ingestion and `--workers` add
taskbroker, taskworkers and Kafka consumers. The harness runs the part that can
be isolated per slot — Postgres, Redis and Snuba (see "How a slot is wired") —
and substitutes the rest:

- **Tasks** — `TASKWORKER_ALWAYS_EAGER = True` in the slot config: tasks run
  inline in the request (no Kafka/taskbroker needed; Sentry allows this with
  `DEBUG`).
- **Default data** — no seed command: `sentry upgrade` with `DEBUG = True`
  runs Sentry's `post_upgrade` receivers, which create the dev superuser
  `admin@sentry.io` / `admin`, org `sentry`, project `internal`. This happens
  once in `template_sentry`; every slot clones it.
- **Snuba without Kafka** — each slot's Snuba runs only its API (`snuba api`),
  like CI's per-worker instances; `snuba bootstrap --no-kafka` runs the
  ClickHouse migrations without a broker. Snuba-backed pages (Issues stream,
  Discover, Explore, Performance, dashboards) load and query the slot's Snuba —
  but it stays **empty in the running app**: nothing ingests events into it.
  Tests are unaffected: `SnubaTestCase.store_event` writes over HTTP
  (`/tests/entities/<entity>/insert`), not through Kafka.
- **Event ingestion** — Relay + Kafka + ingest/Snuba consumers are not run, so
  SDK events sent to a slot are dropped. Isolating them per slot would need
  per-slot Kafka topics on both the Sentry and Snuba side; use CI or a
  developer's own `devservices up --mode ingest` for ingestion work.
- **`requires_kafka` tests** — Sentry checks a hard-coded `127.0.0.1:9092`;
  the harness does not take that port (it is devservices' Kafka). Reported as
  `HAR:` skipped (3 markers in the suite).
- **Mock data** — `bin/load-mocks` / `bin/mock-*` are not run (they ingest
  through Kafka/Relay).
- **Assets** — rsbuild dev server per slot, error overlay off and HMR off
  (`rsbuild.config.ts` defaults): rebuilds cause full reloads, compile errors
  go to `har env agent <id> logs ui` instead of covering the page. First load
  of a route compiles lazily (a few seconds).

## Verification contract

| Mode | Command | Stages (`stages.json` → `verificationStages`) |
|------|---------|--------|
| Quick | `har env verify <id>` | `typecheck` (`sentry django check`), `api-health` (`/_health/` on API_PORT), `ui-health` (`/_health/` through rsbuild on FE_PORT) |
| Full | `har env verify <id> --full` | quick + `lint`, `unit-tests`, `frontend-checks`, `readiness` |

Stage ids `typecheck`, `unit-tests` and `readiness` are HAR's ecosystem
defaults: `har env maintain` / `doctor` re-insert a stock stage (`compileall`,
bare `pytest -q` — the whole suite against `localhost:5432`/`6379`) under any of
those ids that is missing. Keep the ids; change only what they run.

"Changed files" = `git diff <slot base commit>` + untracked files in the work
dir (`scripts/sentry-slot.sh changed-files`). The full suite is far too large
to run per change, so full verify is scoped to the change, like the repo's own
pre-commit / selective-test flow:

- `lint` — `.venv/bin/prek run -q --files <changed>` (ruff, formatting, flake8
  S-rules, …) and `pnpm run lint:js <changed JS/TS>`. Like the repo's
  pre-commit, fixer hooks **rewrite files in place** and still fail the run —
  review the diff and re-run verify. (mypy is a pre-push hook; it is not run.)
- `unit-tests` — pytest on changed `tests/**/test_*.py`, plus
  `tests/sentry/<path>/test_<mod>.py` for each changed `src/sentry/<path>/<mod>.py`
  (when it exists). Runs without xdist against the shared Postgres (test DBs
  `test_{region,control,secondary}_agent<id>`, reused within a session — pass
  `--create-db` by hand after model changes; dropped on teardown) and harness
  Redis (DB 32 + id).
  Snuba tests run for real against the slot's **test** Snuba
  (`har-sentry-snuba-test-agent<id>`, started by the stage on first use — the
  plugin points Sentry's `xdist.get_snuba_url()` hook at it, as CI does for
  per-worker Snuba). Tests that fail only because Kafka/Symbolicator/Objectstore
  are absent (their `requires_*` marker) are reported as **skipped** with a
  `HAR:` reason — mention them in your handoff; CI will run them. If the test
  Snuba could not start, the stage warns and Snuba tests are skipped the same
  way (fix with `sentry-slot.sh snuba-up test`). Run a chosen selection the same way:
  `HAR_TESTS="tests/sentry/foo/test_bar.py::TestX::test_y" har env run-stage <id> unit-tests`.
- `frontend-checks` — only if JS/TS changed: `pnpm run typecheck` (whole
  project, incremental) and `pnpm test-ci --runTestsByPath` on changed
  `*.spec.{ts,tsx}` plus each changed module's sibling spec. Not
  `--findRelatedTests`: it is transitive (a shared util pulled in hundreds of
  specs, 10+ min); CI runs the wider set.
- `readiness` — the agent-usable smoke below.

Full logs: `.har/artifacts/<stage>/agent-<id>.log` (main checkout).

### Known noise in `logs web`

- `Unexpected status code: 504 … /api/1/envelope/` — the dev SDK reports
  Sentry's own errors to the `internal` project through Relay, which slots
  don't run. Harmless.
- `KeyError: 'proto'` from `sentry_sdk` logging integration while formatting
  request logs — upstream dev-server noise, unrelated to the harness.

## Readiness layers

| Layer | What it means here | Where it's encoded |
|-------|--------------------|--------------------|
| Infra ready | `har-sentry-db-1` + `har-sentry-redis-1` + `har-sentry-clickhouse-1` up; `template_sentry` migrated with dev admin/org/project | `har env setup-infra` (`HARNESS_DB_MIGRATE_CMD`) |
| Slot data ready | `agent_<id>` cloned + migrated to the branch's schema; Redis DB `<id>`; `.sentry-har/` config generated; Snuba `har-sentry-snuba-agent<id>` healthy on `har_agent<id>` | `har env launch` + `hooks/post-launch.sh` |
| Process ready | PM2 `web` + `ui` online; `/_health/` on API_PORT and via FE_PORT | launch health wait, quick verify |
| Agent usable | Login `admin@sentry.io`/`admin` works, `GET /api/0/organizations/sentry/projects/` lists `internal`, UI login page + its JS bundle served by rsbuild | `readiness` stage (`scripts/sentry-slot.sh smoke`) |

Manual smoke: open `http://localhost:${FE_PORT}/auth/login/`, sign in as
`admin@sentry.io` / `admin`, land on org `sentry`. For API work, create a
token under *User Settings → Personal Tokens* or use the session cookie.

## Definition of done

- [ ] `har env verify <id> --full` returns `"status": "pass"`
- [ ] The change works in the running slot (UI and/or API) — not just green tests
- [ ] New behavior has test coverage (pytest under `tests/`, jest `*.spec.tsx` under `static/`)
- [ ] Any `HAR:` skipped tests (Kafka/Symbolicator/Objectstore-dependent) are called out in the handoff
- [ ] Frontend (`static/`) and backend (`src/`, `tests/`) changes are split into separate PRs (repo rule)
- [ ] Changes committed **in the session worktree** with a clear message
- [ ] Handoff: summary, session branch, preview URL (`http://localhost:${FE_PORT}`); then **wait for the user** before `complete`, push or PR

### Session handoff

After full verify and commit, stop and propose next steps. Never autonomously
run `complete`, `teardown`, `git push`, or open a PR. Default recommendation
when `gh` is available: push → PR → `har env complete <id>`. Prefer `complete`
over bare `teardown` when the work succeeded.

## Project commands

The repo's own commands (AGENTS.md) assume `devservices` on the default ports:
plain `.venv/bin/pytest` talks to Postgres `localhost:5432` and Redis
`localhost:6379` — on this machine those belong to **other projects**, never
the slot. Inside a slot use:

```bash
# backend tests — always through the harness (plugin + per-slot test DBs)
har env run-stage <id> unit-tests                                   # changed/related tests
HAR_TESTS="tests/sentry/api/test_base.py::TestX" har env run-stage <id> unit-tests

# anything else: from the work dir, with the slot env loaded first
cd <work dir> && set -a && . ./.env.agent.<id> && set +a
.venv/bin/prek run -q --files <files>          # lint / format (UV_PYTHON pinned by the env)
"$PYTHON_BIN" -m sentry django check           # settings + import smoke
"$PYTHON_BIN" -m sentry upgrade --noinput      # apply new migrations to agent_<id>
pnpm run typecheck                             # TypeScript
pnpm test-ci <spec files>                      # jest
pnpm run lint:js <files>                       # oxlint
```

**New migration** (use the repo's `generate-migration` skill): apply it to the
slot DB with `sentry upgrade` as above, then `har env agent <id> restart`.
Otherwise the running app queries a table that doesn't exist and pages that
touch the model return 500. (`unit-tests` builds its own test DBs, so tests
pass either way — check the live app.)

**Backend down after an edit** (`api-health` fails, UI shows 504): the dev
server drops its workers when an edit leaves the code unimportable (half-written
module) and only respawns them on the *next* Python file change. Read
`har env agent <id> logs web` for the ImportError, fix it, then
`har env agent <id> restart`.

## Port & shared services

### Port allocation

| Layer | Scope | Rule | Slot 1 default | On conflict |
|-------|-------|------|----------------|-------------|
| UI — rsbuild (`FE_PORT`) | Per slot | `HARNESS_FE_BASE_PORT (7000) + AGENT_ID × HARNESS_PORT_STEP (10)` | 7010 | Scan `STEP` increments within the slot lane |
| Django (`API_PORT`) | Per slot | `HARNESS_API_BASE_PORT (7500) + AGENT_ID × STEP` | 7510 | Same |
| Debug (`DEBUG_PORT`) | Per slot | `9200 + AGENT_ID × STEP` | 9210 | Same (unused by Sentry) |
| Postgres (`PGPORT`) | Per machine | `db` lane `15432:15432-15499` | 15432 | HAR scans the range; persisted in `.har/state/infra.env` |
| Redis (`REDIS_PORT`) | Per machine | **fixed** `16479` | 16479 | None — HAR has no redis lane; change `docker-compose.agent.yml`, `env.template` and `scripts/sentry-slot.sh` together |
| ClickHouse | Per machine | **fixed** `127.0.0.1:18123` (HTTP, debugging only — Snuba uses the `har-sentry_default` network) | 18123 | None — fixed lane like redis |
| Snuba live (`SNUBA`) | Per slot | `"1218"` + agent id (string, ids 1–9) | 12181 | None — fixed; `snuba-up` fails if busy. Change `env.template` and `snuba_vars` in `scripts/sentry-slot.sh` together |
| Snuba test | Per slot | `"1228"` + agent id | 12281 | Same |

Bases were chosen to avoid a developer's own `devservices serve` (8000/8001,
8010 in silo mode), Relay (7899), `pnpm dev-ui` (7999) and HAR Mission Control
(`har control up`, 3847).

### Do not

- Hardcode ports in app code, tests, or docs — read `.env.agent.<id>` / `har env agent <id> url`
- Run raw `docker compose`, `devservices up`, or `sentry devserver` for the harness — use `har env setup-infra` / `har env launch`
- Start Kafka/Relay/workers, or a Snuba by hand (`devservices up`, `docker run`) — the slot already has its own Snuba; use `sentry-slot.sh snuba-up` to repair it
- Point a slot or a test run at another slot's Snuba port, or at the live `1218<id>` from pytest — test resets would wipe that data
- Touch other slots' databases (`agent_<n>`), Redis DBs, worktrees or PM2 processes
- Edit `.env.agent.<id>`, `ecosystem.agent.<id>.config.cjs` or `.sentry-har/` by hand — they are regenerated on launch
- Edit the main checkout — all edits go under the session work dir

## Run history

Every entry point (`har env …`, MCP) writes the same run records to the
**main checkout** `.har/runs/YYYY-MM-DD/HH-mm-ss_<stageId>_agent-<id>.json`.
With worktree slots, code runs in the worktree but run JSON lives in the main
checkout; each record includes `workDir`.

## Session lifecycle

Every `launch` starts a fresh session: a new worktree from the main checkout's
current HEAD at `~/worktrees/<base-branch>-<sha4>-har-agent-<id>-<rand4>`, on a
branch of the same name, recorded in `.har/slots/agent-<id>.json`.

- Occupied slots block a launch: `har env complete <id>` (or `teardown <id>`) first.
- When every slot is occupied, don't pick one yourself — run `har env status`,
  summarize each slot (branch, work unit, last verify, merged/pushed/unpushed)
  and let the user choose; never free one with unpushed commits.
- `teardown` removes the worktree (and its `.venv`/`node_modules`) and drops
  `agent_<id>` but **keeps the branch**.
- Failed launch after the worktree exists: `har env launch <id> --resume` or `har env recover <id>`.

## Maintaining this harness

- Customize only through the contract: `harness.env`, `stages.json` + `stages/`,
  `hooks/`, `plugins/`. `har env doctor` validates.
- **Template DB refresh**: `template_sentry` is migrated once. Per-slot launches
  apply newer migrations on top, so it stays usable; to rebuild it from scratch
  (e.g. after a migration squash), drop it while no slot is running:
  `docker exec har-sentry-db-1 psql -U postgres -c "UPDATE pg_database SET datistemplate=false WHERE datname='template_sentry'" -c "DROP DATABASE template_sentry"`,
  then `har env setup-infra`. Do the same if the **first** template migration
  failed: HAR creates `template_sentry` before migrating and skips existing
  templates on later runs, so a half-migrated template must be dropped first.
- **Snuba image** — `ghcr.io/getsentry/snuba:nightly`, the tag devservices
  uses, pulled on first `snuba-up`. It drifts: `docker pull` it to update, then
  recreate a slot's Snuba with `snuba-down` + `snuba-up` (new ClickHouse
  migrations apply on `snuba bootstrap`). Pin with `HAR_SNUBA_IMAGE=<image>`.
- **ClickHouse** — same image as Snuba's devservices config; data in volume
  `har-sentry_agent-clickhouse-data`. Memory is capped at 4 GiB in
  `clickhouse/config.xml`. Measured idle: ClickHouse ~0.4 GB, each Snuba API
  ~0.16 GB.
- **Node / Python pins** come from the repo (`devenv/config.ini`, `.node-version`,
  `.python-version`, `uv.lock`, `pnpm-lock.yaml`) — nothing to update here.
  If the local `uv` is too old to download the exact `.python-version` patch,
  `sentry-slot.sh` falls back to the newest available 3.13.x and logs a
  WARNING (`uv self update` removes it). `UV_PYTHON` / `UV_PROJECT_ENVIRONMENT`
  in the slot env pin `uv run` (used by prek hooks) to the slot `.venv`.
- When Sentry's dev config changes (`src/sentry/data/config/*.default`,
  `sentry init --dev`), mirror it in `cmd_conf` of `scripts/sentry-slot.sh`.
