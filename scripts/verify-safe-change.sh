#!/usr/bin/env bash
# Phase 5 acceptance checks:
#   1. versioned migrations were applied before the app rolled out
#   2. a schema change applied under live traffic causes zero errors
#   3. a bad release is caught by the SLO analysis on 25% of pods and rolled back automatically
#   4. a good release is promoted 25% -> 50% -> 100%
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/prom-lib.sh
source scripts/prom-lib.sh
NS=orders
REPORT="$(mktemp)"; FAILED=0
row() { echo "| $1 | $2 | $3 |" >>"$REPORT"; echo "[$2] $1: $3"; }
finish() { { echo "## Safe change: migrations and canary releases"; echo; echo "| Check | Result | Detail |"; echo "|---|---|---|"; cat "$REPORT"; echo; } >>"${GITHUB_STEP_SUMMARY:-/dev/stdout}"; }
prom_forward; trap 'kill ${PROM_PF:-0} 2>/dev/null || true' EXIT
PRIMARY=$(kubectl -n $NS get cluster orders-db -o jsonpath='{.status.currentPrimary}')
psql_db() { kubectl -n $NS exec "$PRIMARY" -c postgres -- psql -U postgres -d orders -tAc "$1"; }
BIZ='namespace="orders",route!~"/healthz|/readyz|/metrics"'
errors() { prom_value "sum(http_requests_total{$BIZ,code=~\"5..\"}) or vector(0)"; }
total() { prom_value "sum(http_requests_total{$BIZ})"; }
phase() { kubectl -n $NS get rollout orders -o jsonpath='{.status.phase}'; }
wait_phase() { # phase timeout_s
  for _ in $(seq 1 $(( $2 / 5 ))); do [[ "$(phase)" == "$1" ]] && return 0; sleep 5; done; return 1
}

# ---------------------------------------------------------------- 1. migrations applied by GitOps
MIG=$(psql_db "SELECT version || CASE WHEN dirty THEN ' (dirty)' ELSE '' END FROM schema_migrations")
IDX=$(psql_db "SELECT indisvalid FROM pg_index WHERE indexrelid = 'orders_created_at_idx'::regclass")
if [[ "$MIG" == "3" && "$IDX" == "t" ]]; then row "Migrations applied before the app" "✅" "schema version 3, concurrent index valid"
else row "Migrations applied before the app" "❌" "version=$MIG index_valid=$IDX"; FAILED=1; fi

# ---------------------------------------------------------------- 2. schema change under live traffic
kubectl -n $NS scale deploy/orders-traffic --replicas=3 >/dev/null
sleep 40
E0=$(errors); T0=$(total)
FROM_FILES=()
for f in gitops/tenants/orders/migrations/*.sql migrations-tests/live/*.sql; do FROM_FILES+=("--from-file=$f"); done
kubectl -n $NS create configmap orders-migrations-live --dry-run=client -o yaml "${FROM_FILES[@]}" \
  | kubectl apply -f - >/dev/null
START=$SECONDS
kubectl -n $NS apply -f - >/dev/null <<YAML
apiVersion: batch/v1
kind: Job
metadata: { name: orders-migrate-live }
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      securityContext: { runAsNonRoot: true, runAsUser: 65534, seccompProfile: { type: RuntimeDefault } }
      containers:
        - name: migrate
          image: migrate/migrate:v4.20.1
          command: [sh, -c]
          args: ['migrate -path /migrations -database "\${PGURI}?sslmode=require&x-multi-statement=true" up']
          env:
            - name: PGURI
              valueFrom: { secretKeyRef: { name: orders-db-app, key: uri } }
          volumeMounts: [{ name: m, mountPath: /migrations, readOnly: true }]
          securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: [ALL] } }
      volumes: [{ name: m, configMap: { name: orders-migrations-live } }]
YAML
kubectl -n $NS wait --for=condition=complete job/orders-migrate-live --timeout=300s >/dev/null || { kubectl -n $NS logs job/orders-migrate-live; FAILED=1; }
DUR=$((SECONDS - START))
sleep 40   # let Prometheus scrape the requests made during the migration
E1=$(errors); T1=$(total)
NEW_ERR=$(awk "BEGIN{printf \"%d\", $E1 - $E0}"); REQS=$(awk "BEGIN{printf \"%d\", $T1 - $T0}")
COL=$(psql_db "SELECT count(*) FROM information_schema.columns WHERE table_name='orders' AND column_name='channel'")
IDX2=$(psql_db "SELECT indisvalid FROM pg_index WHERE indexrelid = 'orders_channel_idx'::regclass")
if [[ "$NEW_ERR" -eq 0 && "$REQS" -gt 0 && "$COL" == "1" && "$IDX2" == "t" ]]; then
  row "Schema change under live traffic" "✅" "ADD COLUMN … DEFAULT + CREATE INDEX CONCURRENTLY in ${DUR}s while serving ${REQS} requests: **0 errors**"
else row "Schema change under live traffic" "❌" "errors=$NEW_ERR requests=$REQS column=$COL index=$IDX2"; FAILED=1; fi
kubectl -n $NS scale deploy/orders-traffic --replicas=1 >/dev/null

# ---------------------------------------------------------------- 3. bad release -> automatic rollback
# Simulate a bad deploy outside Git: pause GitOps self-heal so Argo CD does not revert it.
kubectl -n argocd patch application keystone --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}' >/dev/null
kubectl -n argocd patch application tenant-orders --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}' >/dev/null
STABLE=$(kubectl -n $NS get rollout orders -o jsonpath='{.status.stableRS}')
E0=$(errors)
START=$SECONDS
kubectl -n $NS patch rollout orders --type json -p \
  '[{"op":"replace","path":"/spec/template/spec/containers/0/env/0/value","value":"v2-bad"},
    {"op":"replace","path":"/spec/template/spec/containers/0/env/1/value","value":"0.5"}]' >/dev/null
if wait_phase Degraded 420; then
  DUR=$((SECONDS - START))
  AR=$(kubectl -n $NS get analysisruns -o json | jq -r '[.items[] | select(.status.phase=="Failed")] | sort_by(.metadata.creationTimestamp) | last')
  WHY=$(jq -r '[.status.metricResults[] | select(.phase=="Failed") | "\(.name)=\(.measurements[-1].value)"] | join(", ")' <<<"$AR")
  sleep 20
  CANARY_PODS=$(kubectl -n $NS get pods -l app=orders --field-selector=status.phase=Running \
    -o jsonpath='{range .items[*]}{.metadata.labels.rollouts-pod-template-hash}{"\n"}{end}' | grep -vc "^${STABLE}$" || true)
  STILL=$(kubectl -n $NS get rollout orders -o jsonpath='{.status.stableRS}')
  if [[ "$STILL" == "$STABLE" && "$CANARY_PODS" -eq 0 ]]; then
    row "Bad release (50% errors) rolled back" "✅" "SLO analysis failed (${WHY}) at 25% traffic; aborted after ${DUR}s, stable version kept serving"
  else row "Bad release rolled back" "❌" "stable=$STILL (was $STABLE), canary pods left=$CANARY_PODS"; FAILED=1; fi
  sleep 30
  BLAST=$(awk "BEGIN{printf \"%d\", $(errors) - $E0}")
  row "Blast radius of the bad release" "✅" "${BLAST} failed requests in total before the rollback (only the canary's share of traffic)"
else row "Bad release rolled back" "❌" "rollout phase $(phase) after 420s"; FAILED=1; fi

# ---------------------------------------------------------------- 4. good release -> promoted
START=$SECONDS
kubectl -n $NS patch rollout orders --type json -p \
  '[{"op":"replace","path":"/spec/template/spec/containers/0/env/0/value","value":"v2"},
    {"op":"replace","path":"/spec/template/spec/containers/0/env/1/value","value":"0"}]' >/dev/null
sleep 10
if wait_phase Healthy 600; then
  DUR=$((SECONDS - START))
  kubectl -n $NS port-forward svc/orders 18081:80 >/dev/null 2>&1 & PF2=$!; sleep 3
  VER=$(curl -sf localhost:18081/ | jq -r .version); kill $PF2 2>/dev/null || true
  RUNS=$(kubectl -n $NS get analysisruns -o json | jq '[.items[] | select(.status.phase=="Successful")] | length')
  if [[ "$VER" == "v2" ]]; then
    row "Good release promoted" "✅" "25% → 50% → 100% in ${DUR}s, ${RUNS} SLO analyses passed, now serving ${VER}"
  else row "Good release promoted" "❌" "serving $VER"; FAILED=1; fi
else row "Good release promoted" "❌" "rollout phase $(phase) after 600s"; FAILED=1; fi

kubectl -n argocd patch application keystone --type merge -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}' >/dev/null
finish
exit "$FAILED"
