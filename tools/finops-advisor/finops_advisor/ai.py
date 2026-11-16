"""AI write-up via GitHub Models (free, rate-limited; uses the workflow's GITHUB_TOKEN with `models: read`).

Guardrail: the model only explains numbers the rules engine computed. Any dollar amount in its answer that
the engine did not produce means the text is rejected and a deterministic template is used instead.
"""
from __future__ import annotations

import json
import re
import urllib.error
import urllib.request

ENDPOINT = "https://models.github.ai/inference/chat/completions"

SYSTEM = """You are a FinOps analyst on a platform engineering team. You write the description of a pull
request that changes PostgreSQL database sizes. Use ONLY the numbers in the JSON you are given; never
estimate, round differently or invent figures. For each database with an action, explain in 2-3 sentences
what the usage shows, what changes, the monthly saving or cost, and the risk and how to roll back (revert
the PR). Mention databases with no action in one line. Start with a one-paragraph summary including the
total monthly saving. Use Markdown with a heading per database. Be concise and factual."""


def allowed_amounts(findings: list[dict], total: float, increase: float = 0.0) -> set[str]:
    amounts = {f"{total:.2f}", f"{increase:.2f}", f"{abs(total - increase):.2f}"}
    for f in findings:
        for k in ("current_cost", "proposed_cost", "monthly_saving"):
            amounts.add(f"{abs(f[k]):.2f}")
    return amounts


def validate(text: str, findings: list[dict], total: float, increase: float = 0.0) -> list[str]:
    """Return problems; empty means the AI text is safe to publish."""
    problems = []
    allowed = allowed_amounts(findings, total, increase)
    for amount in re.findall(r"\$\s?(-?[0-9][0-9,]*(?:\.[0-9]+)?)", text):
        norm = f"{abs(float(amount.replace(',', ''))):.2f}"
        if norm not in allowed:
            problems.append(f"unexpected amount ${amount}")
    for f in findings:
        if f["action"] in ("hibernate", "downsize", "upsize") and f["database"] not in text:
            problems.append(f"missing database {f['database']}")
    return problems


def write_with_ai(findings: list[dict], total: float, token: str, model: str, increase: float = 0.0,
                  timeout: float = 60) -> str:
    payload = {
        "model": model,
        "temperature": 0.1,
        "max_tokens": 1200,
        "messages": [
            {"role": "system", "content": SYSTEM},
            {"role": "user", "content": json.dumps({"total_monthly_saving_usd": total,
                                                    "total_monthly_increase_for_reliability_usd": increase,
                                                    "findings": findings}, indent=2)},
        ],
    }
    req = urllib.request.Request(
        ENDPOINT, data=json.dumps(payload).encode(), method="POST",
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json",
                 "Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"},
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            raw = r.read().decode("utf-8", "replace")
            status = r.status
    except urllib.error.HTTPError as exc:  # surface rate limits / permission problems clearly
        raise RuntimeError(f"HTTP {exc.code}: {exc.read().decode('utf-8', 'replace')[:300]}") from exc
    try:
        body = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"HTTP {status}, non-JSON response: {raw[:300]!r}") from exc
    return body["choices"][0]["message"]["content"].strip()


def template(findings: list[dict], total: float, increase: float = 0.0) -> str:
    lines = [f"The FinOps advisor found **${total:.2f}/month** in savings from observed usage."]
    if increase:
        lines.append(f"It also recommends **+${increase:.2f}/month** of upsizing where databases are running hot "
                     "(reliability over cost; needs human review).")
    lines.append("")
    for f in findings:
        if f["action"] in ("hibernate", "downsize", "upsize"):
            change = "hibernate (stop compute, keep data)" if f["action"] == "hibernate" else f"{f['tier']} → {f['proposed_tier']}"
            lines += [f"### {f['database']} ({f['namespace']}, {f['environment']})",
                      f"- Change: **{change}**",
                      f"- Why: {'; '.join(f['reasons'])}",
                      f"- Cost: ${f['current_cost']:.2f} → ${f['proposed_cost']:.2f} per month",
                      "- Rollback: revert this pull request; Argo CD restores the previous size.", ""]
        else:
            lines.append(f"- {f['database']}: no change ({'; '.join(f['reasons'])})")
    return "\n".join(lines)
