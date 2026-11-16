# ADR 0006: Prove resilience continuously, under load

**Status:** accepted

## Decision
Every CI run executes, against a real cluster with 20 writes/s from k6 plus background traffic:
1. **Primary pod kill** (Chaos Mesh `PodChaos`, grace period 0).
2. **Primary network isolation**: 100% packet loss for 60 s (Chaos Mesh `NetworkChaos`), the classic
   split-brain set-up. While the old primary is cut off we count instances that accept writes (must be 1).
3. **Point-in-time restore drill**: restore base backup + WAL from S3 into a throwaway cluster to a chosen
   second, and check a row written 2 s before the target is there and one written 2 s after is not.

Measured per experiment: time to a new primary, the longest gap between successful writes, failed requests,
and **lost acknowledged writes** (every 201 from the API is checked against the database afterwards).

## Design choices this forced
- `tcp_user_timeout = 5s` on PgBouncer. When a primary disappears from the network, pooled server
  connections would otherwise wait for TCP retransmission to give up (minutes) after failover has finished.
- Restore drills are exempt from the prod HA policy by label (`keystone.io/purpose: restore-drill`).
- The application retries transient connection errors with backoff, so a failover is a latency spike for
  users rather than a burst of errors.
