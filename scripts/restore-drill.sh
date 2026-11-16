#!/usr/bin/env bash
# Phase 6: a backup is only trusted once it has been restored.
# Writes a marker row, picks a recovery target time, writes a second marker, then restores the production
# backup (base backup + archived WAL) to that exact second in a throwaway cluster and checks:
#   marker written before the target is present, marker written after it is absent.
set -euo pipefail
cd "$(dirname "$0")/.."
NS=orders; SRC=orders-db; DRILL=orders-restore-drill
PRIMARY=$(kubectl -n $NS get cluster $SRC -o jsonpath='{.status.currentPrimary}')
q() { kubectl -n $NS exec "$PRIMARY" -c postgres -- psql -U postgres -d orders -tAc "$1"; }
TAG=$(date +%s)

q "INSERT INTO orders (item, quantity) VALUES ('pitr-before-$TAG', 1)" >/dev/null
sleep 2
TARGET=$(q "SELECT to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"')")
sleep 2
q "INSERT INTO orders (item, quantity) VALUES ('pitr-after-$TAG', 1)" >/dev/null
ROWS=$(q "SELECT count(*) FROM orders WHERE created_at <= '$TARGET'::timestamptz")
WAL=$(q "SELECT pg_walfile_name(pg_current_wal_lsn())")
q "SELECT pg_switch_wal()" >/dev/null
echo "target=$TARGET rows_at_target=$ROWS waiting for $WAL to be archived"
for _ in $(seq 1 60); do
  last=$(q "SELECT coalesce(last_archived_wal, '') FROM pg_stat_archiver")
  [[ "$last" > "$WAL" || "$last" == "$WAL" ]] && break
  sleep 3
done

kubectl -n $NS delete cluster $DRILL --ignore-not-found --wait=true >/dev/null
START=$SECONDS
kubectl -n $NS apply -f - >/dev/null <<YAML
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: ${DRILL}
  labels: { keystone.io/purpose: restore-drill }
spec:
  instances: 1
  storage: { size: 2Gi }
  resources:
    requests: { cpu: 100m, memory: 256Mi }
    limits: { memory: 512Mi }
  bootstrap:
    recovery:
      source: origin
      recoveryTarget:
        targetTime: "${TARGET}"
  externalClusters:
    - name: origin
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters:
          barmanObjectName: ${SRC}-backups
          serverName: ${SRC}
YAML
if ! kubectl -n $NS wait --for=condition=Ready cluster/$DRILL --timeout=900s >/dev/null; then
  kubectl -n $NS describe cluster $DRILL | tail -30
  kubectl -n $NS logs -l cnpg.io/cluster=$DRILL --tail=50 --all-containers || true
  echo "| Point-in-time restore drill | ❌ | restore cluster never became ready |" >>"${GITHUB_STEP_SUMMARY:-/dev/stdout}"
  exit 1
fi
DUR=$((SECONDS - START))
R="$DRILL-1"
rq() { kubectl -n $NS exec "$R" -c postgres -- psql -U postgres -d orders -tAc "$1"; }
BEFORE=$(rq "SELECT count(*) FROM orders WHERE item = 'pitr-before-$TAG'")
AFTER=$(rq "SELECT count(*) FROM orders WHERE item = 'pitr-after-$TAG'")
RESTORED=$(rq "SELECT count(*) FROM orders")
kubectl -n $NS delete cluster $DRILL --wait=false >/dev/null

if [[ "$BEFORE" == "1" && "$AFTER" == "0" && "$RESTORED" -ge "$ROWS" ]]; then
  OK=0
  LINE="| Point-in-time restore drill | ✅ | restored to \`$TARGET\` from S3 (base backup + WAL) in ${DUR}s: ${RESTORED} orders; row written 2 s before the target present, row written 2 s after it absent |"
else
  OK=1
  LINE="| Point-in-time restore drill | ❌ | before=$BEFORE (want 1) after=$AFTER (want 0) restored=$RESTORED (want ≥ $ROWS) |"
fi
printf '## Resilience: backup restore drill\n\n| Check | Result | Detail |\n|---|---|---|\n%s\n\n' "$LINE" \
  | tee -a "${GITHUB_STEP_SUMMARY:-/dev/stdout}"
exit "$OK"
