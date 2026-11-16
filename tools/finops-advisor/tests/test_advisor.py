import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from finops_advisor import ai, edit  # noqa: E402
from finops_advisor.pricing import PriceModel  # noqa: E402
from finops_advisor.rules import GB, evaluate  # noqa: E402
from finops_advisor.usage import Usage, queries  # noqa: E402

PRICES = PriceModel.from_repo(ROOT)


def db(ns, name, env, tier, **spec):
    return {"metadata": {"namespace": ns, "name": name},
            "spec": {"environment": env, "tier": tier, "databaseName": "app", **spec}}


def usage(cpu=0.01, mem_mib=100, writes=1.0, conns=2, samples=100):
    return Usage(samples, cpu, mem_mib * 1024**2, writes, conns, 10 * 1024**2)


# ---- price model agrees with what the composition reported live in CI
def test_prices_match_the_composition():
    assert PRICES.monthly_cost("prod", "small") == 21.45
    assert PRICES.monthly_cost("dev", "small") == 7.22
    assert PRICES.monthly_cost("prod", "medium") == 89.69   # the over-budget request Gatekeeper denies
    assert PRICES.monthly_cost("dev", "small", hibernate=True) == 0.28


# ---- rules
def test_idle_dev_database_is_hibernated():
    f = evaluate(db("inventory", "inventory-db", "dev", "small"), usage(writes=0.0, conns=0), PRICES)
    assert f.action == "hibernate" and f.monthly_saving == pytest.approx(6.94)


def test_idle_prod_database_is_never_hibernated():
    f = evaluate(db("orders", "orders-db", "prod", "small"), usage(writes=0.0, conns=0), PRICES)
    assert f.action != "hibernate"


def test_overprovisioned_dev_medium_is_downsized():
    f = evaluate(db("analytics", "analytics-db", "dev", "medium"), usage(cpu=0.02, mem_mib=150), PRICES)
    assert (f.action, f.proposed_tier) == ("downsize", "small")
    assert f.monthly_saving == pytest.approx(PRICES.monthly_cost("dev", "medium") - PRICES.monthly_cost("dev", "small"))
    assert not f.needs_human_review


def test_downsize_requires_headroom_in_the_smaller_tier():
    # 200m CPU is <20% of a medium request but would be 80% of a small one: keep medium
    f = evaluate(db("analytics", "analytics-db", "dev", "medium"), usage(cpu=0.15, mem_mib=150), PRICES)
    assert f.action == "none"


def test_prod_downsize_needs_stronger_evidence_and_review():
    weak = evaluate(db("orders", "orders-db", "prod", "medium"), usage(cpu=0.15, mem_mib=200), PRICES)
    strong = evaluate(db("orders", "orders-db", "prod", "medium"), usage(cpu=0.05, mem_mib=200), PRICES)
    assert weak.action == "none"
    assert strong.action == "downsize" and strong.needs_human_review


def test_hot_database_is_upsized_for_reliability():
    f = evaluate(db("orders", "orders-db", "prod", "small"), usage(cpu=0.24, mem_mib=480), PRICES)
    assert f.action == "upsize" and f.proposed_tier == "medium" and f.monthly_saving < 0


def test_no_recommendation_without_enough_data():
    f = evaluate(db("inventory", "inventory-db", "dev", "small"), usage(writes=0, conns=0, samples=3), PRICES)
    assert f.action == "insufficient-data"


def test_queries_scope_to_the_database_pods():
    q = queries("orders", "orders-db", "orders", "7d")
    assert 'pod=~"orders-db-[0-9]+"' in q["cpu_p95_cores"] and "[7d:15s]" in q["cpu_p95_cores"]


# ---- manifest edits
MANIFEST = """# comment kept
apiVersion: platform.keystone.io/v1alpha1
kind: PostgresDatabase
metadata:
  name: analytics-db
spec:
  environment: dev
  tier: medium
  owner: team-analytics
  costCenter: CC-3003
"""


def test_edit_downsize_keeps_comments():
    out = edit.apply(MANIFEST, "downsize", "small")
    assert "  tier: small  # proposed by the FinOps advisor" in out and out.startswith("# comment kept")


def test_edit_hibernate_appends_once():
    out = edit.apply(MANIFEST, "hibernate", None)
    assert out.count("hibernate: true") == 1
    assert edit.apply(out, "hibernate", None).count("hibernate: true") == 1


# ---- AI guardrail
FINDINGS = [
    {"database": "inventory-db", "action": "hibernate", "current_cost": 7.22, "proposed_cost": 0.28, "monthly_saving": 6.94},
    {"database": "orders-db", "action": "none", "current_cost": 21.45, "proposed_cost": 21.45, "monthly_saving": 0.0},
]


def test_ai_text_with_only_computed_numbers_passes():
    text = "Total saving $6.94/month. inventory-db is idle: $7.22 → $0.28."
    assert ai.validate(text, FINDINGS, 6.94) == []


def test_ai_text_with_invented_number_is_rejected():
    text = "inventory-db is idle; hibernating saves about $83.28 per year."
    assert any("unexpected amount" in p for p in ai.validate(text, FINDINGS, 6.94))


def test_ai_text_missing_a_database_is_rejected():
    assert ai.validate("Total saving $6.94.", FINDINGS, 6.94) == ["missing database inventory-db"]


def test_idle_signal_ignores_exporter_commits():
    q = queries("inventory", "inventory-db", "inventory", "5m")
    assert "xact_commit" not in q["writes_per_s"] and "tup_inserted" in q["writes_per_s"]


def test_cnpg_system_roles_are_not_app_clients():
    q = queries("inventory", "inventory-db", "inventory", "5m")
    assert "cnpg_.*" in q["max_app_connections"]  # cnpg_metrics_exporter, cnpg_pooler_pgbouncer


def test_ai_may_quote_the_reliability_increase():
    text = "Save $6.94/month. orders-db upsize adds $68.24/month for reliability. inventory-db idle."
    assert ai.validate(text, FINDINGS, 6.94, 68.24) == []
