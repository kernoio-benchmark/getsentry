#!/usr/bin/env bash
# Sentry-specific helper for the HAR harness.
#
# NOT a lifecycle entry point — `har env …` / HAR MCP are. This script is only
# invoked by the harness itself, through harness.env keys and stage scripts:
#
#   install        HARNESS_INSTALL_CMD   (cwd = work dir, slot .venv active)
#   migrate        HARNESS_DB_MIGRATE_CMD (template DB in setup-infra; slot DB at launch)
#   conf           writes $SENTRY_CONF/{sentry.conf.py,config.yml} from env
#   changed-files  files changed in the slot vs its base commit (used by stages)
#   smoke          HARNESS_READINESS_CMD — "agent usable" check (login + API + UI)
#
# It resolves paths from its own location (the MAIN checkout's .har/), so it
# works whether or not .har/ is committed into the session worktree.
set -euo pipefail

HAR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_REDIS_PORT=16479 # keep in sync with docker-compose.agent.yml / env.template

log() { echo "[sentry-slot] $*" >&2; }
die() { echo "[sentry-slot] ERROR: $*" >&2; exit 1; }

# ── git exclude for per-worktree generated files ──────────────────────────────
exclude_generated() {
  local common exclude
  common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 0
  exclude="$common/info/exclude"
  mkdir -p "$(dirname "$exclude")"
  grep -qxF '.sentry-har/' "$exclude" 2>/dev/null || echo '.sentry-har/' >>"$exclude"
}

# ── Node: install the version pinned in devenv/config.ini (same tarball devenv uses)
ensure_node() {
  local bin_dir="$1" cfg="devenv/config.ini"
  [ -f "$cfg" ] || die "$cfg not found (run from the repo/worktree root)"
  local version key url sha os arch
  version="$(sed -n 's/^version = v\{0,1\}\(.*\)$/\1/p' "$cfg" | head -1)"
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  arch="$(uname -m)"
  case "$arch" in x86_64 | amd64) arch=x86_64 ;; aarch64 | arm64) arch=arm64 ;; esac
  key="${os}_${arch}"
  url="$(sed -n "s|^${key} = \(.*\)$|\1|p" "$cfg" | head -1)"
  sha="$(sed -n "s|^${key}_sha256 = \(.*\)$|\1|p" "$cfg" | head -1)"
  [ -n "$version" ] && [ -n "$url" ] && [ -n "$sha" ] || die "no node pin for $key in $cfg"

  local cache="${XDG_CACHE_HOME:-$HOME/.cache}/har-sentry/node-v${version}-${key}"
  if [ ! -x "$cache/bin/node" ]; then
    log "Installing node v$version (devenv pin) into $cache"
    local tmp
    tmp="$(mktemp -d)"
    curl -fsSL "$url" -o "$tmp/node.tar.xz"
    echo "$sha  $tmp/node.tar.xz" | sha256sum -c - >/dev/null || die "node tarball sha256 mismatch"
    mkdir -p "$cache"
    tar -xJf "$tmp/node.tar.xz" -C "$cache" --strip-components=1
    rm -rf "$tmp"
  fi
  mkdir -p "$bin_dir"
  local tool
  for tool in node npm npx; do
    [ -e "$cache/bin/$tool" ] && ln -sfn "$cache/bin/$tool" "$bin_dir/$tool"
  done
}

# ── Python: honour .python-version; fall back to the newest local/downloadable
# interpreter of the same minor when this uv can't provide the exact patch.
resolve_python() {
  local want minor found
  want="$(tr -d '[:space:]' <.python-version 2>/dev/null || true)"
  [ -n "$want" ] || { echo "3.13"; return; }
  minor="$(echo "$want" | cut -d. -f1,2)"
  if ! found="$(uv python find --no-project "$want" 2>/dev/null)"; then
    uv python install "$want" >/dev/null 2>&1 || true
    found="$(uv python find --no-project "$want" 2>/dev/null)" || found=""
  fi
  if [ -n "$found" ]; then
    echo "$found"
    return
  fi
  uv python install "$minor" >/dev/null 2>&1 || true
  found="$(uv python find --no-project "$minor" 2>/dev/null)" || die "no Python $minor available to uv"
  log "WARNING: Python $want unavailable to this uv ($(uv --version)); using $found"
  echo "$found"
}

# Make sure VIRTUAL_ENV runs the pinned minor (HAR may have created it with the
# system python3, e.g. 3.14, which Sentry's uv.lock does not support).
ensure_venv_python() {
  local venv="$1" interp="$2" want_minor have
  want_minor="$("$interp" -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
  have="$("$venv/bin/python" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || true)"
  if [ "$have" != "$want_minor" ]; then
    log "Recreating $venv with Python $want_minor (was: ${have:-none})"
    uv venv --clear --quiet --python "$interp" "$venv"
  fi
}

cmd_install() {
  [ -n "${VIRTUAL_ENV:-}" ] || die "install expects the slot venv to be active (VIRTUAL_ENV)"
  command -v uv >/dev/null || die "uv is required (https://docs.astral.sh/uv/)"
  command -v pnpm >/dev/null || die "pnpm is required on PATH (corepack enable, or install pnpm)"
  exclude_generated

  local interp
  interp="$(resolve_python)"
  ensure_venv_python "$VIRTUAL_ENV" "$interp"
  log "uv sync (python deps into $VIRTUAL_ENV)"
  UV_PYTHON="$interp" uv sync --frozen --inexact --quiet --active

  ensure_node "$VIRTUAL_ENV/bin"
  export PATH="$VIRTUAL_ENV/bin:$PATH"
  log "node $(node --version); pnpm install --frozen-lockfile"
  CI=true NODE_ENV=development pnpm install --frozen-lockfile --reporter=append-only
}

# ── Sentry config (env-driven; regenerated before every use) ──────────────────
cmd_conf() {
  local conf="${SENTRY_CONF:?SENTRY_CONF must be set}"
  mkdir -p "$conf/files" "$conf/relocation" "$conf/profiles"
  cat >"$conf/sentry.conf.py" <<'PY'
# Generated by .har/scripts/sentry-slot.sh — do not edit; regenerated on launch.
# Mirrors `sentry init --dev`, but reads the slot's Postgres/Redis/ports from env.
import os

from sentry.conf.server import *  # noqa: F401,F403

_env = os.environ.get

DATABASES = {
    "default": {
        "ENGINE": "sentry.db.postgres",
        "NAME": _env("PGDATABASE", "sentry"),
        "USER": _env("PGUSER", "postgres"),
        "PASSWORD": _env("PGPASSWORD", ""),
        "HOST": _env("PGHOST", "127.0.0.1"),
        "PORT": _env("PGPORT", ""),
        "AUTOCOMMIT": True,
        "ATOMIC_REQUESTS": False,
    }
}

SENTRY_SINGLE_ORGANIZATION = True
DEBUG = True

SENTRY_CACHE = "sentry.cache.redis.RedisCache"
SENTRY_RATELIMITER = "sentry.ratelimits.redis.RedisRateLimiter"
SENTRY_BUFFER = "sentry.buffer.redis.RedisBuffer"
SENTRY_QUOTAS = "sentry.quotas.redis.RedisQuota"
SENTRY_TSDB = "sentry.tsdb.snuba.SnubaTSDB"
SENTRY_DIGESTS = "sentry.digests.backends.redis.RedisBackend"

SENTRY_WEB_HOST = "127.0.0.1"
SENTRY_WEB_PORT = int(_env("API_PORT") or 9000)
SENTRY_WEB_OPTIONS = {}
DEVSERVER_REQUEST_LOG_EXCLUDES = ["/api/0/relays/projectconfigs/"]

# Harness slots run no Kafka/taskbroker/taskworkers: execute tasks inline so
# request-triggered tasks (and post-upgrade bootstrap) complete without them.
TASKWORKER_ALWAYS_EAGER = True
# The setting alone is not wired to the task client; this module flag is what
# Task.delay()/apply_async() check (same switch sentry's TaskRunner patches).
import taskbroker_client.task as _har_task  # noqa: E402

_har_task.ALWAYS_EAGER = True

# Browsers reach the slot through the rsbuild dev server (FE_PORT), not Django
# (API_PORT) — point absolute URLs and org/customer-domain redirects there.
_fe_port = _env("FE_PORT")
if _fe_port:
    SENTRY_OPTIONS["system.url-prefix"] = f"http://localhost:{_fe_port}"
    SENTRY_BASE_HOSTNAME = f"localhost:{_fe_port}"
    SENTRY_ORGANIZATION_BASE_HOSTNAME = f"{{slug}}.localhost:{_fe_port}"
    SENTRY_ORGANIZATION_URL_TEMPLATE = "http://{hostname}"
PY

  local redis_port="${REDIS_PORT:-$DEFAULT_REDIS_PORT}" redis_db="${REDIS_DB:-0}"
  cat >"$conf/config.yml" <<YML
# Generated by .har/scripts/sentry-slot.sh — do not edit; regenerated on launch.
mail.backend: 'console'
# Dev-only key, identical for every harness slot. Never use outside local dev.
system.secret-key: 'har-local-dev-only-secret-key-not-for-production-use-0123456789'
redis.clusters:
  default:
    hosts:
      0:
        host: 127.0.0.1
        port: ${redis_port}
        db: ${redis_db}
  rc-default:
    is_redis_cluster: true
    hosts:
      - host: 127.0.0.1
        port: 7000
filestore.backend: 'filesystem'
filestore.options:
  location: '${conf}/files'
filestore.relocation-backend: 'filesystem'
filestore.relocation-options:
  location: '${conf}/relocation'
filestore.profiles-backend: 'filesystem'
filestore.profiles-options:
  location: '${conf}/profiles'
  allow_overwrite: true
YML
}

# ── Migrations ────────────────────────────────────────────────────────────────
# Slot launch: env file sourced → PYTHON_BIN / SENTRY_CONF point into the worktree.
# Template DB (setup-infra): runs in the main checkout with only PG* set → use a
# harness-owned venv under .har/state so the developer's own .venv is untouched.
cmd_migrate() {
  local py="${PYTHON_BIN:-}"
  if [ -z "$py" ] || [ -z "${SENTRY_CONF:-}" ]; then
    local venv="$HAR_DIR/state/template-venv"
    command -v uv >/dev/null || die "uv is required (https://docs.astral.sh/uv/)"
    log "Template migration: syncing python deps into $venv (first run takes a few minutes)"
    local interp
    interp="$(resolve_python)"
    ensure_venv_python "$venv" "$interp"
    UV_PYTHON="$interp" UV_PROJECT_ENVIRONMENT="$venv" uv sync --frozen --inexact --quiet
    py="$venv/bin/python"
    export SENTRY_CONF="$HAR_DIR/state/sentry-conf-template"
    export REDIS_DB=0
  fi
  cmd_conf
  log "sentry upgrade --noinput (db=${PGDATABASE:-?} conf=$SENTRY_CONF)"
  "$py" -m sentry upgrade --noinput
}

# ── Changed files vs the slot's base commit ───────────────────────────────────
cmd_changed_files() {
  local base="" registry="$HAR_DIR/slots/agent-${AGENT_ID:-0}.json"
  if [ -f "$registry" ]; then
    base="$(sed -n 's/.*"baseCommit"[[:space:]]*:[[:space:]]*"\([0-9a-f]\{7,40\}\)".*/\1/p' "$registry" | head -1)"
  fi
  if [ -z "$base" ] || ! git cat-file -e "$base^{commit}" 2>/dev/null; then
    base="$(git merge-base HEAD origin/master 2>/dev/null || git merge-base HEAD master 2>/dev/null || echo HEAD)"
  fi
  {
    git diff --name-only --diff-filter=d "$base"
    git ls-files --others --exclude-standard
  } | sort -u | while IFS= read -r f; do
    case "$f" in .har/* | .sentry-har/* | .env.agent.* | ecosystem.agent.*) continue ;; esac
    [ -f "$f" ] && echo "$f"
  done
}

# ── Agent-usable smoke ────────────────────────────────────────────────────────
cmd_smoke() {
  : "${API_PORT:?API_PORT not set — run via har env verify}" "${FE_PORT:?FE_PORT not set}"
  local api="http://localhost:${API_PORT}" fe="http://localhost:${FE_PORT}"
  local jar
  jar="$(mktemp)"
  # Retries ride out a Django autoreload (connection reset) between steps.
  local -a retry=(--retry 5 --retry-all-errors --retry-delay 2)
  trap 'rm -f "$jar"' RETURN

  # Django's autoreloader restarts the web process after .py edits — give it
  # time to come back instead of failing on a mid-reload probe.
  log "1/5 Django health: $api/_health/ (waits up to 120s for an autoreload)"
  local i
  for i in $(seq 1 60); do
    curl -fsS -o /dev/null --max-time 5 "$api/_health/" 2>/dev/null && break
    [ "$i" -eq 60 ] && die "Django /_health/ failed on $api — check: har env agent ${AGENT_ID:-<id>} logs web"
    sleep 2
  done

  log "2/5 CSRF + session test cookie: GET /auth/login/ and /api/0/auth/config/ (as the React login page does)"
  curl "${retry[@]}" -fsS -o /dev/null -c "$jar" -b "$jar" "$api/auth/login/" || die "GET /auth/login/ failed"
  curl "${retry[@]}" -fsS -o /dev/null -c "$jar" -b "$jar" "$api/api/0/auth/config/" || die "GET /api/0/auth/config/ failed"
  local csrf
  # Sentry's CSRF_COOKIE_NAME is "sc" (src/sentry/conf/server.py).
  csrf="$(awk '$6 == "sc" {print $7}' "$jar" | tail -1)"
  [ -n "$csrf" ] || die "no CSRF cookie set by /auth/login/"

  log "3/5 login as admin@sentry.io via POST /api/0/auth/login/"
  local code
  code="$(curl "${retry[@]}" -sS -o /dev/null -w '%{http_code}' -c "$jar" -b "$jar" \
    -H "Content-Type: application/json" -H "X-CSRFToken: $csrf" \
    -H "Origin: $api" -H "Referer: $api/auth/login/" \
    --data '{"username":"admin@sentry.io","password":"admin"}' \
    "$api/api/0/auth/login/")"
  [ "$code" = "200" ] || die "login returned HTTP $code (expected 200) — dev admin missing? see .har/README.md"

  log "4/5 org + project: GET /api/0/organizations/sentry/projects/"
  local projects
  projects="$(curl "${retry[@]}" -fsS -c "$jar" -b "$jar" "$api/api/0/organizations/sentry/projects/")" ||
    die "authenticated API call failed"
  echo "$projects" | grep -q '"slug":"internal"' || die "default org 'sentry' / project 'internal' not found"

  log "5/5 UI via rsbuild ($fe): login page + its JS bundle"
  local html script
  html="$(curl "${retry[@]}" -fsS -b "$jar" "$fe/auth/login/")" || die "rsbuild dev server not serving $fe/auth/login/"
  script="$(echo "$html" | grep -o 'src="/_static/dist/[^"]*\.js"' | head -1 | sed 's/^src="//; s/"$//')"
  [ -n "$script" ] || die "login page has no /_static/dist/*.js bundle reference"
  for i in $(seq 1 60); do
    if curl -fsS -o /dev/null "$fe$script"; then
      log "OK — slot is agent-usable: $fe (admin@sentry.io / admin)"
      return 0
    fi
    sleep 3
  done
  die "UI bundle $fe$script not served after 180s — check: har env agent ${AGENT_ID:-<id>} logs ui"
}

case "${1:-}" in
  install) cmd_install ;;
  conf) cmd_conf ;;
  migrate) cmd_migrate ;;
  changed-files) cmd_changed_files ;;
  smoke) cmd_smoke ;;
  *) die "usage: sentry-slot.sh install|conf|migrate|changed-files|smoke" ;;
esac
