"""Usage:
  python -m finops_advisor --prometheus http://localhost:9090 --window 7d --repo . --out out [--apply] [--ai]
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

from . import ai, edit
from .pricing import PriceModel
from .rules import evaluate
from .usage import Prometheus, read_usage


def list_databases() -> list[dict]:
    out = subprocess.run(["kubectl", "get", "postgresdatabases", "-A", "-o", "json"],
                         capture_output=True, text=True, check=True).stdout
    return json.loads(out)["items"]


def table(findings: list[dict]) -> str:
    rows = ["| Database | Env | Tier | p95 CPU | Peak mem | Writes/s | Clients | Action | Now | After | Saving |",
            "|---|---|---|---|---|---|---|---|---|---|---|"]
    for f in findings:
        e = f["evidence"]
        action = {"none": "—", "hibernate": "💤 hibernate", "downsize": f"⬇ {f['proposed_tier']}",
                  "upsize": f"⬆ {f['proposed_tier']}", "insufficient-data": "not enough data"}[f["action"]]
        rows.append(
            f"| {f['database']} | {f['environment']} | {f['tier']} | {e.get('cpu_p95_pct_of_request', 0)}% | "
            f"{e.get('mem_peak_mib', 0)} MiB ({e.get('mem_peak_pct_of_limit', 0)}%) | {e.get('writes_per_s', 0)} | "
            f"{e.get('max_app_connections', 0)} | {action} | ${f['current_cost']:.2f} | ${f['proposed_cost']:.2f} | "
            f"${f['monthly_saving']:.2f} |")
    return "\n".join(rows)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="finops-advisor")
    ap.add_argument("--prometheus", default=os.environ.get("PROMETHEUS_URL", "http://localhost:9090"))
    ap.add_argument("--window", default="7d", help="lookback window, e.g. 7d in production, 5m in CI")
    ap.add_argument("--repo", default=".", type=Path)
    ap.add_argument("--out", default="finops-out", type=Path)
    ap.add_argument("--apply", action="store_true", help="edit tenant manifests with the proposed changes")
    ap.add_argument("--ai", action="store_true", help="write the explanation with GitHub Models")
    ap.add_argument("--model", default=os.environ.get("FINOPS_MODEL", "openai/gpt-4.1-mini"))
    args = ap.parse_args(argv)

    prices = PriceModel.from_repo(args.repo)
    prom = Prometheus(args.prometheus)
    findings = []
    for db in list_databases():
        ns, name = db["metadata"]["namespace"], db["metadata"]["name"]
        usage = read_usage(prom, ns, name, db["spec"].get("databaseName", "app"), args.window)
        findings.append(evaluate(db, usage, prices).to_dict())
    findings.sort(key=lambda f: -f["monthly_saving"])
    actionable = [f for f in findings if f["action"] in ("hibernate", "downsize", "upsize")]
    total = round(sum(f["monthly_saving"] for f in actionable), 2)

    changed = []
    if args.apply:
        for f in actionable:
            path = edit.manifest_path(args.repo, f["namespace"])
            before = path.read_text()
            after = edit.apply(before, f["action"], f["proposed_tier"])
            if after != before:
                path.write_text(after)
                changed.append(str(path.relative_to(args.repo)))

    narrative, source = ai.template(findings, total), "template"
    if args.ai and actionable:
        token = os.environ.get("GITHUB_TOKEN", "")
        try:
            text = ai.write_with_ai(findings, total, token, args.model)
            problems = ai.validate(text, findings, total)
            if problems:
                print(f"AI text rejected by guardrail: {problems}", file=sys.stderr)
            else:
                narrative, source = text, f"GitHub Models ({args.model})"
        except Exception as exc:  # rate limit, model unavailable, network: degrade gracefully
            print(f"AI unavailable ({exc}); using template", file=sys.stderr)

    args.out.mkdir(parents=True, exist_ok=True)
    report = "\n".join([
        f"## FinOps advisor: ${total:.2f}/month potential savings", "",
        f"Observed window: `{args.window}` · Prices: `gitops/platform/guardrails-constraints` · Write-up: {source}", "",
        table(findings), "", narrative, "",
        "---", "*Numbers are computed by deterministic rules from Prometheus data; AI only writes the explanation "
        "and is rejected if it introduces any figure the rules did not produce. Every change is re-checked by the "
        "Gatekeeper guardrails and needs a human to merge.*",
    ])
    (args.out / "report.md").write_text(report + "\n")
    (args.out / "findings.json").write_text(json.dumps({"total_monthly_saving": total, "changed_files": changed,
                                                        "findings": findings}, indent=2))
    print(report)
    return 0


if __name__ == "__main__":
    sys.exit(main())
