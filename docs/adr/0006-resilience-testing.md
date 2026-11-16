# ADR 0006: Prove resilience continuously, under load

**Status:** accepted

## Decision
Every CI run executes, against a real cluster with 20 writes/s from k6 plus background traffic:
1. **Primary pod kill**: force-delete with no grace period (crash / OOM kill).
2. **Primary network isolation**: every packet to and from the primary dropped for 60 s at its node
   (`iptables` in the kind node), the classic split-brain set-up. While the old primary is cut off we count
   instances that accept writes (must be 1).
3. **Point-in-time restore drill**: restore base backup + WAL from S3 into a throwaway cluster to a chosen
   second, and check a row written 2 s before the target is there and one written 2 s after is not.

Measured per experiment: time to a new primary, the longest gap between successful writes, failed requests,
and **lost acknowledged writes** (every 201 from the API is checked against the database afterwards).

## Why not Chaos Mesh
It was the first choice, but its controller crash-looped on this cluster in CI. The two faults we need are
exactly what it does internally (delete a pod; drop a pod's packets), so injecting them directly removes a
privileged DaemonSet and a failure mode from the platform. Chaos Mesh / Litmus remain good options for
richer experiments (latency, disk, clock skew) on a real cluster.

## Design choices this forced
- `tcp_user_timeout = 5s` on PgBouncer. When a primary disappears from the network, pooled server
  connections would otherwise wait for TCP retransmission to give up (minutes) after failover has finished.
- Restore drills are exempt from the prod HA policy by label (`keystone.io/purpose: restore-drill`).
- The application retries transient connection errors with backoff, so a failover is a latency spike for
  users rather than a burst of errors.
