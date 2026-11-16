"""Deterministic, explainable right-sizing rules. The AI never decides; it only explains these results."""
from __future__ import annotations

from dataclasses import asdict, dataclass, field

from .pricing import PriceModel
from .usage import Usage

THRESHOLDS = {
    "min_samples": 10,           # refuse to recommend on too little data
    "idle_writes_per_s": 0.01,   # < 1 row written per 100 s
    "downsize_cpu_ratio": 0.20,  # p95 CPU below 20% of the request...
    "downsize_mem_ratio": 0.40,  # ...and peak memory below 40% of the limit
    "upsize_cpu_ratio": 0.80,
    "upsize_mem_ratio": 0.85,
    "prod_downsize_cpu_ratio": 0.10,  # prod needs much stronger evidence
}

GB = 1024**3


@dataclass
class Finding:
    namespace: str
    database: str
    environment: str
    tier: str
    action: str                      # none | hibernate | downsize | upsize | insufficient-data
    proposed_tier: str | None
    current_cost: float
    proposed_cost: float
    reasons: list[str] = field(default_factory=list)
    evidence: dict = field(default_factory=dict)
    needs_human_review: bool = False

    @property
    def monthly_saving(self) -> float:
        return round(self.current_cost - self.proposed_cost, 2)

    def to_dict(self) -> dict:
        d = asdict(self)
        d["monthly_saving"] = self.monthly_saving
        return d


def evaluate(db: dict, usage: Usage, prices: PriceModel, t: dict = THRESHOLDS) -> Finding:
    meta, spec = db["metadata"], db["spec"]
    env, tier = spec["environment"], spec.get("tier", "small")
    storage = spec.get("storageGB")
    backup = spec.get("backup", {}).get("enabled", True)
    hibernated = spec.get("hibernate", False)
    current = prices.monthly_cost(env, tier, storage, backup, hibernated)
    tier_cfg = prices.tier(tier)
    cpu_req, mem_limit = tier_cfg["cpu"], tier_cfg["memoryGB"] * GB
    cpu_ratio = (usage.cpu_p95_cores or 0) / cpu_req
    mem_ratio = (usage.mem_max_bytes or 0) / mem_limit
    evidence = {
        "samples": usage.samples,
        "cpu_p95_cores": round(usage.cpu_p95_cores or 0, 4),
        "cpu_p95_pct_of_request": round(cpu_ratio * 100, 1),
        "mem_peak_mib": round((usage.mem_max_bytes or 0) / 1024**2, 1),
        "mem_peak_pct_of_limit": round(mem_ratio * 100, 1),
        "writes_per_s": round(usage.writes_per_s, 3),
        "max_app_connections": int(usage.max_app_connections),
        "db_size_mib": round((usage.db_size_bytes or 0) / 1024**2, 1),
    }
    f = Finding(meta["namespace"], meta["name"], env, tier, "none", None, current, current, evidence=evidence)

    if hibernated:
        f.reasons.append("already hibernated")
        return f
    if usage.samples < t["min_samples"]:
        f.action = "insufficient-data"
        f.reasons.append(f"only {usage.samples} metric samples in the window; need {t['min_samples']}")
        return f

    if env != "prod" and usage.writes_per_s < t["idle_writes_per_s"] and usage.max_app_connections == 0:
        f.action = "hibernate"
        f.proposed_cost = prices.monthly_cost(env, tier, storage, backup, hibernate=True)
        f.reasons.append(f"no application connections and {usage.writes_per_s:.3f} row writes/s over the window: idle")
        return f

    if cpu_ratio > t["upsize_cpu_ratio"] or mem_ratio > t["upsize_mem_ratio"]:
        bigger = prices.larger(tier)
        if bigger:
            f.action, f.proposed_tier = "upsize", bigger
            f.proposed_cost = prices.monthly_cost(env, bigger, storage, backup)
            f.needs_human_review = True
            f.reasons.append(f"p95 CPU at {cpu_ratio:.0%} of request / peak memory at {mem_ratio:.0%} of limit: risk of throttling or OOM")
        return f

    cpu_limit = t["prod_downsize_cpu_ratio"] if env == "prod" else t["downsize_cpu_ratio"]
    smaller = prices.smaller(tier)
    if smaller and cpu_ratio < cpu_limit and mem_ratio < t["downsize_mem_ratio"]:
        small_cfg = prices.tier(smaller)
        # the smaller tier must still have headroom for the observed peak
        if (usage.cpu_p95_cores or 0) < 0.5 * small_cfg["cpu"] and (usage.mem_max_bytes or 0) < 0.6 * small_cfg["memoryGB"] * GB:
            f.action, f.proposed_tier = "downsize", smaller
            f.proposed_cost = prices.monthly_cost(env, smaller, storage, backup)
            f.needs_human_review = env == "prod"
            f.reasons.append(
                f"p95 CPU {cpu_ratio:.0%} of request and peak memory {mem_ratio:.0%} of limit; "
                f"'{smaller}' still leaves headroom for the observed peak"
            )
            return f
    f.reasons.append("right-sized for the observed load")
    return f
