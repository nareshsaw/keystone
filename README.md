# Keystone: Self-Service PostgreSQL Platform

![CI](https://github.com/nareshsaw/keystone/actions/workflows/ci.yml/badge.svg)

**An internal developer platform that gives every team a production-ready PostgreSQL database through
GitOps: highly available, zero-data-loss replication, continuous backups, connection pooling, and
failover that is tested continuously, not assumed.**

Most platform demos automate stateless apps. Keystone focuses on the hard part of cloud architecture:
**stateful data, failure recovery and safe change.**

## Self-service: a database in 10 lines

```yaml
apiVersion: platform.keystone.io/v1alpha1
kind: PostgresDatabase
metadata:
  name: orders-db
  namespace: orders
spec:
  environment: prod      # dev = 1 instance, staging = 2, prod = 3 + zero-data-loss replication
  tier: small            # small | medium | large
  databaseName: orders
  owner: team-orders
  costCenter: CC-1001
```

Crossplane turns this into a CloudNativePG cluster, WAL archiving + scheduled backups, TLS trust for the
backup store and a PgBouncer pooler, then reports the **estimated monthly cost** back to the team:

```console
$ kubectl get postgresdatabases -A
NAMESPACE   NAME           ENV    TIER    INSTANCES   COST/MONTH   STATUS                     SYNCED   READY
inventory   inventory-db   dev    small   1           $7.22        Cluster in healthy state   True     True
orders      orders-db      prod   small   3           $21.45       Cluster in healthy state   True     True
```

## Guardrails and FinOps (OPA Gatekeeper, Rego)

| Request | Result |
|---|---|
| Prod database without backups | ⛔ denied |
| Hibernating a prod database | ⛔ denied |
| `large` tier in dev | ⛔ denied |
| Storage above the tier limit | ⛔ denied |
| `environment` that doesn't match the namespace | ⛔ denied |
| **Request whose estimated cost exceeds the namespace's monthly budget** | ⛔ denied (FinOps) |
| Tenant namespace without owner / cost-centre / budget labels | ⛔ denied (FinOps showback) |
| Hand-rolled prod Postgres that bypasses self-service (1 instance, no backups) | ⛔ denied (defence in depth) |
| Idle dev database: `hibernate: true` | ✅ compute cost drops to $0, data kept |

The cost model lives in two places that must agree: the composition reports it, the policy enforces it.
CI renders the composition (`crossplane render`) and asserts the price, and `gator verify` runs 15 policy tests.

## AI FinOps advisor

A weekly job reads **real usage** from Prometheus and proposes right-sizing as a pull request:

Real output from CI (5-minute window on kind):

| Database | Env | Tier | p95 CPU (of request) | Writes/s | App clients | Recommendation | Now | After | Guardrails |
|---|---|---|---|---|---|---|---|---|---|
| analytics-db | dev | medium | 7.7% | 0.63 | 1 | ⬇ small | $30.56 | $7.22 | ✅ accepted |
| inventory-db | dev | small | — | 0 | 0 | 💤 hibernate | $7.22 | $0.28 | ✅ accepted |
| orders-db | prod | small | 92.7% | 1.72 | 4 | ⬆ medium (reliability) | $21.45 | $89.69 | ⛔ held back: over the $60 budget |

**Saves $30.28/month** on two databases, and flags that prod is running hot, but the upsize goes to the owner
for a budget decision instead of into the PR, because Gatekeeper rejects it.

How it stays safe:
1. **Rules decide, AI explains.** Recommendations and every dollar figure come from deterministic rules
   ([`rules.py`](tools/finops-advisor/finops_advisor/rules.py)) using the same price model as the budget policy.
   GitHub Models (free tier, `models: read`) only writes the PR description.
2. **Hallucination guard.** If the AI text contains any amount the rules didn't compute, or skips a database,
   it is rejected and a template is used instead.
3. **Guardrails re-check every proposal.** Changed manifests are validated by Gatekeeper on the live cluster
   (server-side dry-run) before the PR is opened, and CI runs again on the PR.
4. **Humans merge.** Prod changes are flagged for review; prod is never hibernated; no recommendation is made
   without enough data; under-provisioned databases get an *upsize* (FinOps is about value, not only cuts).

Idle detection uses row writes and client connections, not commit counts: the CNPG exporter connects to every
database (as `cnpg_metrics_exporter`) and runs a catalog query on each scrape, so an idle database still
"commits" and still shows a connection. System roles (`postgres`, `streaming_replica`, `cnpg_*`) are excluded.

## Observability and SLOs

- kube-prometheus-stack; every database, pooler and the app are scraped (PodMonitors created by the composition)
- **SLOs** for the orders API (99.9% availability, 99% under 300 ms) defined in [`slos/`](slos/) and compiled
  by Sloth into multi-window, multi-burn-rate alerts; CI fails if the generated rules are stale
- Database alerts with [runbooks](docs/runbooks/postgres.md): instance down, replication lag, WAL archiving
  failures, backup freshness, connection saturation
- The official CloudNativePG Grafana dashboard, provisioned through GitOps

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
| Self-service + FinOps | Crossplane v2 `PostgresDatabase` API with cost showback; Gatekeeper enforces safety rules and per-namespace budgets |
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
| 3. Self-service: Crossplane `PostgresDatabase` API (S/M/L tiers), Gatekeeper guardrails, FinOps showback and budgets | ✅ |
| 4. Observability: Prometheus, Grafana, SLOs with burn-rate alerts (Sloth), database alerts + runbooks | ✅ |
| 4b. **AI FinOps advisor**: right-sizing and hibernation PRs from real usage, AI-written and guardrail-checked | ✅ |
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
