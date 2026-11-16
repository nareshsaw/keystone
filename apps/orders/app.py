"""orders: a tiny API used to exercise the platform (failover, migrations, canaries).

Connection settings come from the standard libpq environment (PGHOST, PGUSER, ...), pointed
at the PgBouncer pooler, so the app never needs to know which instance is the primary.
"""
from __future__ import annotations

import json
import logging
import os
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import psycopg
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest

from validation import validate

REQUESTS = Counter("http_requests_total", "HTTP requests", ["method", "route", "code"])
LATENCY = Histogram(
    "http_request_duration_seconds", "HTTP request latency", ["method", "route"],
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.2, 0.3, 0.5, 1, 2.5, 5),
)
ROUTES = {"/", "/healthz", "/readyz", "/metrics", "/orders", "/orders/stats", "/whoami"}

log = logging.getLogger("orders")

SCHEMA = """
CREATE TABLE IF NOT EXISTS orders (
    id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    item       TEXT        NOT NULL CHECK (length(item) BETWEEN 1 AND 100),
    quantity   INTEGER     NOT NULL CHECK (quantity > 0),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
)
"""


def connect() -> psycopg.Connection:
    # prepare_threshold=None: PgBouncer in transaction mode must not see server-side prepared statements
    return psycopg.connect(connect_timeout=3, prepare_threshold=None, autocommit=True)


def with_retry(fn, attempts: int = 5, delay: float = 0.5):
    """Retry transient connection errors, e.g. while a replica is being promoted."""
    for i in range(attempts):
        try:
            with connect() as conn:
                return fn(conn)
        except psycopg.OperationalError as exc:
            if i == attempts - 1:
                raise
            log.warning("database unavailable (%s), retrying", exc)
            time.sleep(delay * (2**i))


class Handler(BaseHTTPRequestHandler):
    def _send(self, code: int, payload: dict | bytes, content_type: str = "application/json") -> None:
        body = payload if isinstance(payload, bytes) else json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        route = self.path if self.path in ROUTES else "other"  # bounded label cardinality
        REQUESTS.labels(self.command, route, str(code)).inc()
        LATENCY.labels(self.command, route).observe(time.perf_counter() - self._start)

    def handle_one_request(self):
        self._start = time.perf_counter()
        super().handle_one_request()

    def log_message(self, fmt, *args):  # structured-ish access log
        log.info("%s %s", self.command, self.path)

    def do_GET(self):
        try:
            if self.path == "/metrics":
                return self._send(200, generate_latest(), CONTENT_TYPE_LATEST)
            if self.path == "/healthz":
                return self._send(200, {"status": "ok"})
            if self.path == "/readyz":
                with_retry(lambda c: c.execute("SELECT 1").fetchone(), attempts=1)
                return self._send(200, {"status": "ready"})
            if self.path == "/orders/stats":
                count, last = with_retry(
                    lambda c: c.execute("SELECT count(*), max(id) FROM orders").fetchone())
                return self._send(200, {"count": count, "last_id": last})
            if self.path == "/whoami":
                addr, in_recovery, version = with_retry(lambda c: c.execute(
                    "SELECT inet_server_addr()::text, pg_is_in_recovery(), current_setting('server_version')"
                ).fetchone())
                return self._send(200, {"server": addr, "is_replica": in_recovery, "postgres": version})
            return self._send(404, {"error": "not found"})
        except psycopg.Error as exc:
            return self._send(503, {"error": "database unavailable", "detail": str(exc).strip()})

    def do_POST(self):
        if self.path != "/orders":
            return self._send(404, {"error": "not found"})
        try:
            length = int(self.headers.get("Content-Length", 0))
            item, qty = validate(json.loads(self.rfile.read(length) or b"{}"))
        except (ValueError, json.JSONDecodeError) as exc:
            return self._send(400, {"error": str(exc)})
        try:
            (order_id,) = with_retry(lambda c: c.execute(
                "INSERT INTO orders (item, quantity) VALUES (%s, %s) RETURNING id", (item, qty)).fetchone())
        except psycopg.Error as exc:
            return self._send(503, {"error": "database unavailable", "detail": str(exc).strip()})
        return self._send(201, {"id": order_id, "item": item, "quantity": qty})


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
    with_retry(lambda c: c.execute(SCHEMA), attempts=30, delay=1)  # Phase 5 replaces this with Atlas migrations
    port = int(os.environ.get("PORT", "8080"))
    log.info("listening on :%d", port)
    ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()


if __name__ == "__main__":
    main()
