"""Reads real usage for one database from Prometheus."""
from __future__ import annotations

import json
import urllib.parse
import urllib.request
from dataclasses import dataclass


@dataclass
class Usage:
    samples: int                 # exporter scrapes seen in the window (data coverage)
    cpu_p95_cores: float | None  # 95th percentile CPU of the busiest instance
    mem_max_bytes: float | None  # peak memory working set of any instance
    writes_per_s: float          # rows inserted/updated/deleted per second (monitoring never writes)
    max_app_connections: float   # peak client connections (excluding superuser, replication and cnpg_* system roles)
    db_size_bytes: float | None


class Prometheus:
    def __init__(self, url: str, timeout: float = 20):
        self.url, self.timeout = url.rstrip("/"), timeout

    def scalar(self, query: str) -> float | None:
        qs = urllib.parse.urlencode({"query": query})
        with urllib.request.urlopen(f"{self.url}/api/v1/query?{qs}", timeout=self.timeout) as r:
            body = json.load(r)
        if body.get("status") != "success":
            raise RuntimeError(f"prometheus error: {body}")
        result = body["data"]["result"]
        if not result:
            return None
        return float(result[0]["value"][1])


def queries(ns: str, name: str, db: str, window: str) -> dict[str, str]:
    pod = f'namespace="{ns}",pod=~"{name}-[0-9]+"'
    return {
        "samples": f'sum(count_over_time(cnpg_collector_up{{{pod}}}[{window}]))',
        "cpu_p95_cores": (
            f'max(quantile_over_time(0.95, sum by (pod) (rate(container_cpu_usage_seconds_total{{{pod},container="postgres"}}[1m]))[{window}:15s]))'
        ),
        "mem_max_bytes": f'max(max_over_time(container_memory_working_set_bytes{{{pod},container="postgres"}}[{window}]))',
        # Not xact_commit: the CNPG exporter runs a catalog query inside every database on each scrape,
        # so an idle database still "commits". Row writes only come from applications.
        "writes_per_s": (
            f'sum(rate(cnpg_pg_stat_database_tup_inserted{{{pod},datname="{db}"}}[{window}]))'
            f' + sum(rate(cnpg_pg_stat_database_tup_updated{{{pod},datname="{db}"}}[{window}]))'
            f' + sum(rate(cnpg_pg_stat_database_tup_deleted{{{pod},datname="{db}"}}[{window}]))'
        ),
        "max_app_connections": (
            f'max_over_time(sum(cnpg_backends_total{{{pod},datname="{db}",usename!~"postgres|streaming_replica|cnpg_.*"}})[{window}:15s])'
        ),
        "db_size_bytes": f'max(cnpg_pg_database_size_bytes{{{pod},datname="{db}"}})',
    }


def read_usage(prom: Prometheus, ns: str, name: str, db: str, window: str) -> Usage:
    v = {k: prom.scalar(q) for k, q in queries(ns, name, db, window).items()}
    return Usage(
        samples=int(v["samples"] or 0),
        cpu_p95_cores=v["cpu_p95_cores"],
        mem_max_bytes=v["mem_max_bytes"],
        writes_per_s=v["writes_per_s"] or 0.0,
        max_app_connections=v["max_app_connections"] or 0.0,
        db_size_bytes=v["db_size_bytes"],
    )
