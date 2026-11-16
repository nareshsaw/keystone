# Keystone: Self-Service PostgreSQL Platform

![CI](https://github.com/nareshsaw/keystone/actions/workflows/ci.yml/badge.svg)

**An internal developer platform that gives every team a production-ready PostgreSQL database through
GitOps: highly available, zero-data-loss replication, continuous backups, connection pooling, and
failover that is tested continuously, not assumed.**

Most platform demos automate stateless apps. Keystone focuses on the hard part of cloud architecture:
**stateful data, failure recovery and safe change.**

## What runs today

```mermaid
flowchart LR
    Dev[Developer] -- PR --> Git[(Git)]
    Git --> Argo[Argo CD<br/>app-of-apps]
    Argo --> CM[cert-manager<br/>platform CA]
    Argo --> CNPG[CloudNativePG<br/>operator]
    Argo --> BP[Barman Cloud<br/>plugin]
    Argo --> OS[RustFS<br/>S3 over TLS]
    Argo --> T[Tenant: orders]
    subgraph T[Tenant namespace: orders]
      App[orders API x2] --> PB[PgBouncer x2]
      PB --> P[(Primary)]
      P -- sync quorum ANY 1 --> R1[(Replica)]
      P -- sync quorum ANY 1 --> R2[(Replica)]
    end
    P -- WAL + base backups --> OS
```

| Capability | How |
|---|---|
| GitOps everything | Argo CD app-of-apps with sync waves; CI deploys the exact commit under test |
| HA Postgres | 3 instances on 3 nodes (hard anti-affinity), automated failover by CloudNativePG |
| Zero data loss | Quorum synchronous replication + failover quorum ([ADR 0002](docs/adr/0002-synchronous-quorum-replication.md)) |
| Backups & PITR | Continuous WAL archiving + 6-hourly base backups via Barman Cloud plugin, over TLS ([ADR 0003](docs/adr/0003-backups-object-store.md)) |
| Connection pooling | PgBouncer (transaction mode) so failovers and connection storms never hit Postgres directly |
| No secrets in Git | Credentials generated at bootstrap; on AWS, EKS Pod Identity instead of keys |
| Cloud-ready | `terraform/aws`: VPC, EKS, Karpenter, encrypted S3 with per-tenant IAM; fmt, validate, tflint and Checkov in CI |

## Proof, on every push

CI creates a 4-node Kubernetes cluster (kind), bootstraps Argo CD, lets GitOps install the whole
platform from the commit under test, then **verifies** it. Each run's Summary page shows a report like:

| Check | Result |
|---|---|
| Cluster ready | ✅ |
| Topology: 3 instances, 1 primary, 3 different nodes | ✅ |
| Zero-data-loss replication: `ANY 1 (...)`, both replicas `quorum` | ✅ |
| Continuous WAL archiving to S3 over TLS | ✅ |
| Base backup completed | ✅ |
| App writes through PgBouncer, served by the primary | ✅ |

## Run it locally (free)

Needs Docker Desktop, [kind](https://kind.sigs.k8s.io/), kubectl, helm and jq.

```bash
make up        # cluster -> app image -> Argo CD -> GitOps -> wait -> verify  (~10 min)
kubectl get applications -n argocd
kubectl -n orders get cluster,pooler,backups
make down
```

## Roadmap

| Phase | Status |
|---|---|
| 1. Foundation: kind, Argo CD app-of-apps, Terraform for EKS | ✅ |
| 2. Stateful core: CloudNativePG, sync replication, backups to S3, PgBouncer, sample app | ✅ |
| 3. Self-service: Crossplane `PostgresDatabase` claim (S/M/L tiers) + OPA Gatekeeper guardrails | ⏳ |
| 4. Observability: Prometheus, Grafana, SLOs with burn-rate alerts (Sloth) | ⏳ |
| 5. Safe change: Atlas migration linting, expand/contract, SLO-gated canaries (Argo Rollouts) | ⏳ |
| 6. Resilience proof: chaos failovers under load (RTO/RPO measured), automated restore tests | ⏳ |

## Architecture decisions

- [ADR 0001: CloudNativePG over RDS/Patroni](docs/adr/0001-cloudnativepg-operator.md)
- [ADR 0002: Quorum synchronous replication](docs/adr/0002-synchronous-quorum-replication.md)
- [ADR 0003: Backups to S3-compatible storage](docs/adr/0003-backups-object-store.md)

## Results

<!-- Screenshot of a green CI run and its verification table -->

## What I learned

<!-- In your own words -->
