"""HAR pytest plugin for Sentry backend tests run inside an agent slot.

Loaded only by .har/stages/backend-tests.sh (stage "unit-tests") via ``-p har_sentry_pytest`` with
this directory on PYTHONPATH. It never ships with the app.

Sentry's test settings (sentry.testutils.pytest.sentry) configure the default
Redis cluster without a host — redis-py falls back to localhost:6379 — and
flush it during their pytest_configure. They also use fixed split-silo test DB
names. The harness runs ONE shared Postgres and Redis for every slot, so:

* before sentry's pytest_configure, redis clients that would use the redis-py
  default address are redirected to REDIS_PORT on a per-slot logical DB
  (32 + AGENT_ID), so concurrent slots never ``flushdb`` each other
  (run without xdist);
* at session start, test DB names get an ``_agent<id>`` suffix
  (test_region_agent1, test_control_agent1, …);
* tests that fail only because Snuba/Kafka/Symbolicator/Objectstore are not
  running are reported as *skipped* with a ``HAR:`` reason — the harness does
  not run those services. That covers both the ``requires_*`` markers and
  tests that never declare Snuba but fail after a Snuba connection was refused
  (e.g. an endpoint returning 500 because its Snuba query failed).
"""

from __future__ import annotations

import functools
import os
from typing import Any

import pytest

_AGENT_ID = os.environ.get("AGENT_ID", "0")
_REDIS_PORT = int(os.environ.get("REDIS_PORT", "16479"))
_REDIS_DB = 32 + int(_AGENT_ID)

_SNUBA_DOWN = {"hit": False}
_SNUBA_DOWN_SIGNS = ("Connection refused", "Max retries exceeded", "Failed to establish")

_MISSING_SERVICE_MARKERS = (
    "requires 'snuba' server running",
    "requires 'kafka' server running",
    "requires 'symbolicator' server running",
    "requires 'objectstore' server running",
)


def _patch_redis() -> None:
    # Imported lazily: Sentry's pinned redis-py imports distutils, which
    # `import sentry` provides (sentry.monkey installs a shim on Python 3.12+).
    import sentry  # noqa: F401
    import redis.client

    original_init = redis.client.Redis.__init__
    if getattr(original_init, "_har_patched", False):
        return

    @functools.wraps(original_init)
    def patched_init(self: Any, *args: Any, **kwargs: Any) -> None:
        host = kwargs.get("host", "localhost")
        port = int(kwargs.get("port", 6379))
        if not args and host in ("localhost", "127.0.0.1") and port == 6379:
            kwargs.update(host="127.0.0.1", port=_REDIS_PORT, db=_REDIS_DB)
        original_init(self, *args, **kwargs)

    patched_init._har_patched = True  # type: ignore[attr-defined]
    redis.client.Redis.__init__ = patched_init  # type: ignore[method-assign]


def _flag_snuba_connection_errors() -> None:
    from sentry.utils import snuba

    cls = snuba.SnubaError
    original_init = cls.__init__
    if getattr(original_init, "_har_patched", False):
        return

    @functools.wraps(original_init)
    def patched_init(self: Any, *args: Any, **kwargs: Any) -> None:
        if any(sign in str(arg) for arg in args for sign in _SNUBA_DOWN_SIGNS):
            _SNUBA_DOWN["hit"] = True
        original_init(self, *args, **kwargs)

    patched_init._har_patched = True  # type: ignore[attr-defined]
    cls.__init__ = patched_init  # type: ignore[method-assign]


# NB: pytest only registers hook functions named pytest_* (specname aliases are
# ignored), hence one hook per phase.


@pytest.hookimpl(tryfirst=True)
def pytest_configure(config: pytest.Config) -> None:
    _patch_redis()


@pytest.hookimpl(tryfirst=True)
def pytest_sessionstart(session: pytest.Session) -> None:
    # After sentry's pytest_configure set up the DB aliases; before
    # pytest-django's session fixture creates the test databases.
    from django.conf import settings

    _flag_snuba_connection_errors()

    suffix = f"_agent{_AGENT_ID}"
    for db in settings.DATABASES.values():
        if not str(db.get("NAME", "")).endswith(suffix):
            db["NAME"] = f"{db['NAME']}{suffix}"


@pytest.hookimpl(tryfirst=True)
def pytest_runtest_setup(item: pytest.Item) -> None:
    _SNUBA_DOWN["hit"] = False


@pytest.hookimpl(hookwrapper=True)
def pytest_runtest_makereport(item: pytest.Item, call: pytest.CallInfo[None]):  # type: ignore[no-untyped-def]
    outcome = yield
    report = outcome.get_result()
    if report.failed and call.excinfo is not None:
        text = str(call.excinfo.value)
        for marker in _MISSING_SERVICE_MARKERS:
            if marker in text:
                report.outcome = "skipped"
                report.longrepr = (
                    str(item.path),
                    item.location[1] or 0,
                    f"HAR: {marker} (not provided by the harness)",
                )
                break
        else:
            if _SNUBA_DOWN["hit"]:
                report.outcome = "skipped"
                report.longrepr = (
                    str(item.path),
                    item.location[1] or 0,
                    "HAR: failed after a Snuba query could not connect (Snuba not provided by the harness)",
                )
