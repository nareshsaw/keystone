"""Applies a finding to the tenant's GitOps manifest (minimal, comment-preserving line edits)."""
from __future__ import annotations

import re
from pathlib import Path

MARK = "  # proposed by the FinOps advisor"


def manifest_path(repo: Path, namespace: str) -> Path:
    return Path(repo) / "gitops" / "tenants" / namespace / "database.yaml"


def apply(text: str, action: str, proposed_tier: str | None) -> str:
    if action in ("downsize", "upsize"):
        new, n = re.subn(r"^(\s+tier:\s*)[a-z]+[^\n]*$", lambda m: f"{m.group(1)}{proposed_tier}{MARK}", text,
                         count=1, flags=re.M)
        if n == 0:  # tier not set explicitly: add it under spec
            new = re.sub(r"^spec:\n", f"spec:\n  tier: {proposed_tier}{MARK}\n", text, count=1, flags=re.M)
        return new
    if action == "hibernate":
        if re.search(r"^\s+hibernate:", text, flags=re.M):
            return re.sub(r"^(\s+hibernate:\s*)\S+[^\n]*$", lambda m: f"{m.group(1)}true{MARK}", text,
                          count=1, flags=re.M)
        return text.rstrip("\n") + f"\n  hibernate: true{MARK}\n"
    return text
