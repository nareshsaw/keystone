# ADR 0003: Backups through the Barman Cloud plugin to S3-compatible storage

**Status:** accepted

## Decision
- Continuous WAL archiving + scheduled base backups through the **Barman Cloud CNPG-I plugin**
  (the in-tree `barmanObjectStore` is deprecated).
- Locally and in CI the target is **RustFS** (S3-compatible, same image the plugin's own tests use) served
  over **TLS** from the platform's cert-manager CA. MinIO was not chosen because its community edition
  no longer ships maintained container images.
- On AWS the target is an S3 bucket (versioned, KMS-encrypted, TLS-only policy, lifecycle expiry) and each
  tenant's pods get access to **their own prefix only** through EKS Pod Identity: no static keys.

## Consequences
- Point-in-time recovery to any second within the retention window.
- A backup is only trusted once it has been restored: Phase 6 adds an automated restore test.
