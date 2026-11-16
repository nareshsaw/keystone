# ADR 0002: Quorum-based synchronous replication with failover quorum

**Status:** accepted

## Context
With asynchronous replication, a failover can lose the last committed transactions (RPO > 0).
Orders are money; losing acknowledged writes is not acceptable.

## Decision
`synchronous: { method: any, number: 1, dataDurability: required, failoverQuorum: true }` on 3 instances:
- every commit waits for **any 1** of the 2 replicas (`ANY 1 (...)`), so one replica can be slow or down
  without blocking writes;
- `failoverQuorum` only promotes a replica that is guaranteed to hold every acknowledged commit.

## Consequences
- RPO = 0 for acknowledged writes; this is verified by chaos tests in Phase 6.
- Commit latency includes one network round-trip to the fastest replica.
- If **both** replicas are lost, writes pause (durability over availability). That is a deliberate
  trade-off; `dataDurability: preferred` would flip it.
