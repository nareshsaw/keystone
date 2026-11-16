# ADR 0001: Run PostgreSQL with the CloudNativePG operator

**Status:** accepted

## Context
Keystone must give every team a highly available Postgres with automated failover, backups and
point-in-time recovery, managed through GitOps. Options considered:

| Option | Pros | Cons |
|---|---|---|
| Amazon RDS / Aurora | Fully managed | Not portable, not GitOps-native, cost per tenant, no local/CI parity |
| Patroni (e.g. Zalando/Crunchy operators) | Mature | Extra consensus store (etcd/Consul) or DCS-on-K8s indirection |
| **CloudNativePG** | Kubernetes API *is* the source of truth; no external DCS; declarative backups, poolers, sync replication; CNCF project | Team must operate Postgres on Kubernetes |

## Decision
Use CloudNativePG. The instance manager uses the Kubernetes API for leader election and fencing,
which removes a whole class of split-brain issues caused by a separate consensus store.

## Consequences
- The same manifests run on kind (CI) and EKS (production).
- We own Postgres operations: monitoring, upgrades, capacity. Phases 4–6 cover this.
