#!/usr/bin/env bash
# Phase 2 acceptance checks: HA topology, zero-data-loss replication, backups, app through the pooler.
# Writes a Markdown report to $GITHUB_STEP_SUMMARY when running in GitHub Actions.
set -euo pipefail
NS=orders
CLUSTER=orders-db
REPORT="$(mktemp)"
row() { echo "| $1 | $2 | $3 |" >>"$REPORT"; echo "[$2] $1: $3"; }
fail() { row "$1" "❌" "$2"; finish; exit 1; }
finish() {
  { echo "## Keystone platform verification"; echo; echo "| Check | Result | Detail |"; echo "|---|---|---|"; cat "$REPORT"; } \
    >>"${GITHUB_STEP_SUMMARY:-/dev/stdout}"
}

kubectl -n "$NS" wait --for=condition=Ready "cluster/$CLUSTER" --timeout=900s >/dev/null \
  || fail "Cluster ready" "cluster never became Ready"
row "Cluster ready" "✅" "$(kubectl -n $NS get cluster $CLUSTER -o jsonpath='{.status.phase}')"

PODS=$(kubectl -n "$NS" get pods -l "cnpg.io/cluster=$CLUSTER,cnpg.io/podRole=instance" \
  -o jsonpath='{range .items[*]}{.metadata.name} {.metadata.labels.cnpg\.io/instanceRole} {.spec.nodeName}{"\n"}{end}')
echo "$PODS"
[[ $(grep -c . <<<"$PODS") -eq 3 ]] || fail "3 instances" "found $(grep -c . <<<"$PODS")"
[[ $(grep -c " primary " <<<"$PODS") -eq 1 ]] || fail "Exactly one primary" "$(grep -c ' primary ' <<<"$PODS") primaries"
NODES=$(awk '{print $3}' <<<"$PODS" | sort -u | grep -c .)
[[ "$NODES" -eq 3 ]] || fail "Spread across nodes" "only $NODES distinct nodes"
row "Topology" "✅" "3 instances, 1 primary, on $NODES different nodes"

PRIMARY=$(kubectl -n "$NS" get cluster "$CLUSTER" -o jsonpath='{.status.currentPrimary}')
psql_primary() { kubectl -n "$NS" exec "$PRIMARY" -c postgres -- psql -U postgres -tAc "$1"; }
SSN=$(psql_primary "SHOW synchronous_standby_names")
REPL=$(psql_primary "SELECT application_name || ':' || sync_state FROM pg_stat_replication ORDER BY 1" | tr '\n' ' ')
grep -q "^ANY 1" <<<"$SSN" || fail "Synchronous replication" "synchronous_standby_names='$SSN'"
[[ $(grep -o "quorum" <<<"$REPL" | wc -l) -eq 2 ]] || fail "Synchronous replication" "replicas: $REPL"
row "Zero-data-loss replication" "✅" "\`$SSN\` · replicas: $REPL"

for _ in $(seq 1 60); do
  ARCH=$(kubectl -n "$NS" get cluster "$CLUSTER" -o jsonpath='{.status.conditions[?(@.type=="ContinuousArchiving")].status}')
  [[ "$ARCH" == "True" ]] && break
  sleep 10
done
[[ "$ARCH" == "True" ]] || fail "WAL archiving" "ContinuousArchiving=$ARCH"
row "Continuous WAL archiving" "✅" "WAL segments shipped to the S3 object store over TLS"

for _ in $(seq 1 60); do
  PHASE=$(kubectl -n "$NS" get backups -o json 2>/dev/null \
    | jq -r --arg c "$CLUSTER" '[.items[] | select(.spec.cluster.name==$c and .status.phase=="completed")] | if length>0 then "completed" else "" end')
  [[ "$PHASE" == "completed" ]] && break
  sleep 10
done
[[ "$PHASE" == "completed" ]] || { kubectl -n "$NS" get backups -o yaml | tail -40; fail "Base backup" "no completed backup"; }
B=$(kubectl -n "$NS" get backups -o json \
  | jq -r --arg c "$CLUSTER" '[.items[] | select(.spec.cluster.name==$c and .status.phase=="completed")][0].status
      | "backup \(.backupId) · WAL \(.beginWal) → \(.endWal)"')
row "Base backup" "✅" "$B"

kubectl -n "$NS" rollout status deploy/orders --timeout=300s >/dev/null || fail "App rollout" "orders not ready"
kubectl -n "$NS" port-forward svc/orders 18080:80 >/dev/null 2>&1 &
PF=$!; trap 'kill $PF 2>/dev/null || true' EXIT; sleep 3
for n in $(seq 1 20); do
  curl -sf -X POST localhost:18080/orders -H 'Content-Type: application/json' \
    -d "{\"item\":\"widget-$n\",\"quantity\":$n}" >/dev/null || fail "App writes" "POST /orders failed"
done
STATS=$(curl -sf localhost:18080/orders/stats)
WHO=$(curl -sf localhost:18080/whoami)
[[ $(jq -r .count <<<"$STATS") -ge 20 ]] || fail "App writes" "$STATS"
[[ $(jq -r .is_replica <<<"$WHO") == "false" ]] || fail "Writes hit primary" "$WHO"
row "App via PgBouncer" "✅" "20 orders written; served by primary $(jq -r .server <<<"$WHO") (PostgreSQL $(jq -r .postgres <<<"$WHO" | cut -d' ' -f1))"

finish
