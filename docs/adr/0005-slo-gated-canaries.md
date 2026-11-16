# ADR 0005: Canary releases gated by the SLO

**Status:** accepted

## Decision
Argo Rollouts canary 25% → 50% → 100%. At each step an `AnalysisTemplate` queries Prometheus for the
**canary pods only** (`rollouts_pod_template_hash` relabelled onto app metrics) and requires:
- error rate < 1% (the availability SLO's SLI), and
- p99 latency < 300 ms (the latency SLO's threshold).

Any failed measurement aborts the rollout: traffic goes back to the stable ReplicaSet, with no human involved.

## Consequences
- The bad release only ever reaches the canary's share of traffic (CI measures this "blast radius").
- Replica-based weighting (no service mesh) keeps the platform simple; weights are approximate (1 of 4 pods = 25%).
  A mesh or Gateway API traffic router can be added later for exact splits.
- Error-rate query uses `or vector(0)` so "no errors" reads as 0, not "no data".
