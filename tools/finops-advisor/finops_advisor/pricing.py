"""Price model. Single source of truth: the Gatekeeper budget constraint, so the advisor, the policy and
(by CI assertion) the composition all agree on what a database costs."""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

import yaml

TIER_ORDER = ["small", "medium", "large"]


@dataclass(frozen=True)
class PriceModel:
    params: dict

    @classmethod
    def from_repo(cls, repo: Path) -> "PriceModel":
        path = Path(repo) / "gitops/platform/guardrails-constraints/constraints.yaml"
        for doc in yaml.safe_load_all(path.read_text()):
            if doc and doc.get("kind") == "KeystoneDatabaseGuardrails":
                return cls(doc["spec"]["parameters"])
        raise ValueError(f"no KeystoneDatabaseGuardrails constraint in {path}")

    def tier(self, name: str) -> dict:
        return self.params["tiers"][name]

    def instances(self, env: str) -> int:
        return self.params["instances"][env]

    def monthly_cost(self, env: str, tier: str, storage_gb: float | None = None, backup: bool = True,
                     hibernate: bool = False) -> float:
        p, t, n = self.params["pricing"], self.tier(tier), self.instances(env)
        storage = storage_gb if storage_gb is not None else t["defaultStorageGB"]
        compute = 0.0 if hibernate else n * (t["cpu"] * p["vcpuHour"] + t["memoryGB"] * p["memoryGBHour"]) * self.params["hoursPerMonth"]
        backups = storage * self.params["backupMultiplier"] * p["backupGBMonth"] if backup else 0.0
        return round(compute + n * storage * p["storageGBMonth"] + backups, 2)

    def smaller(self, tier: str) -> str | None:
        i = TIER_ORDER.index(tier)
        return TIER_ORDER[i - 1] if i > 0 else None

    def larger(self, tier: str) -> str | None:
        i = TIER_ORDER.index(tier)
        return TIER_ORDER[i + 1] if i < len(TIER_ORDER) - 1 else None
