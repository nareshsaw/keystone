# Runbook: Keystone PostgreSQL alerts

Every alert carries `namespace` and `pod`. Commands assume the [`cnpg` kubectl plugin](https://cloudnative-pg.io/documentation/current/kubectl-plugin/).

## Instance down
**Impact:** one instance gone. With 3 instances and `ANY 1` sync replication, writes continue.
1. `kubectl cnpg status <cluster> -n <ns>`: is the primary affected? The operator fails over automatically.
2. `kubectl -n <ns> describe pod <pod>`: OOMKilled or node lost? OOM means the tier is too small (see the FinOps advisor's upsize findings).
3. If the PVC is corrupt: `kubectl cnpg destroy <cluster> <instance> -n <ns>` and let the operator re-clone it.

## Replication lag
**Impact:** a lagging replica can't satisfy the sync quorum alone; if both lag, commits slow down.
1. Check node and disk pressure on the replica's node.
2. Look for long-running transactions on the primary: `kubectl cnpg psql <cluster> -n <ns> -- -c "select pid, now()-xact_start, query from pg_stat_activity order by 2 desc limit 5"`.

## WAL archiving
**Impact:** point-in-time recovery stops advancing and WAL piles up on the primary's disk.
1. `kubectl -n cnpg-system logs deploy/plugin-barman-cloud` and `kubectl -n backup-store logs deploy/object-store`.
2. Check credentials (`backup-store-credentials`) and the CA secret (`<cluster>-backup-store-trust`).

## Backup too old
**Impact:** the recovery point objective is at risk.
1. `kubectl -n <ns> get backups --sort-by=.metadata.creationTimestamp`: look at the last failed backup's status.
2. Trigger one manually: `kubectl cnpg backup <cluster> -n <ns> --method=plugin --plugin-name=barman-cloud.cloudnative-pg.io`.

## Connections
**Impact:** new connections fail at `max_connections`.
1. Are clients bypassing PgBouncer (connecting to `<cluster>-rw` directly)? They should use `<cluster>-pooler-rw`.
2. Persistent pressure means the tier is too small; the FinOps advisor will propose an upsize.
