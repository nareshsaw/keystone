# ADR 0004: Zero-downtime schema migrations

**Status:** accepted

## Decision
- Versioned SQL migrations (golang-migrate) live next to the tenant's manifests and ship as a ConfigMap.
  An Argo CD sync hook (wave 1) applies them **before** the new app version rolls out (wave 2).
- **Squawk** lints every migration in CI. Rejected: non-concurrent index builds, column type changes,
  required columns without defaults, and any statement without `lock_timeout` / `statement_timeout`.
- **Expand / contract**: add nullable columns or columns with constant defaults first (metadata-only on PG 11+),
  ship code that writes them, backfill in batches, and only then add constraints or drop old columns.
- The migration Job connects **directly to the primary**, not through PgBouncer: session-level `SET` and
  golang-migrate's advisory lock don't survive transaction pooling.
- `x-multi-statement=true` runs statements individually, outside a transaction, so
  `CREATE INDEX CONCURRENTLY` works.

## Consequences
- A migration that can't get its lock within 5 s fails fast and the release stops, instead of queueing behind a
  long transaction and taking the table (and the app) down with it.
- CI applies a migration while traffic is flowing and asserts **zero failed requests**.
- No vendor account or licence is needed (both tools are open source).
