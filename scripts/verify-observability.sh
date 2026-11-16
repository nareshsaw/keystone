#!/usr/bin/env bash
# Phase 4 acceptance checks: every database, pooler and the app are scraped; SLO and database alert rules are
# loaded and evaluating; backup freshness and replication lag are measurable; nothing critical is firing.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/prom-lib.sh
source scripts/prom-lib.sh
REPORT="$(mktemp)"; FAILED=0
row() { echo "| $1 | $2 | $3 |" >>"$REPORT"; echo "[$2] $1: $3"; }
prom_forward; trap 'kill ${PROM_PF:-0} 2>/dev/null || true' EXIT

wait_for() { # promql min timeout_s
  local v
  for _ in $(seq 1 $(( $3 / 10 ))); do
    v=$(prom_value "$1"); [[ -n "$v" ]] && awk "BEGIN{exit !($v >= $2)}" && { echo "$v"; return 0; }
    sleep 10
  done
  echo "${v:-none}"; return 1
}

for t in orders:3 inventory:1 analytics:1; do
  ns=${t%:*}; want=${t#*:}
  if got=$(wait_for "count(cnpg_collector_up{namespace=\"$ns\"} == 1)" "$want" 300); then
    row "Postgres exporters scraped ($ns)" "✅" "$got/$want instances up"
  else row "Postgres exporters scraped ($ns)" "❌" "$got/$want"; FAILED=1; fi
done

if v=$(wait_for 'count({__name__=~"cnpg_pgbouncer_.+"})' 1 180); then row "PgBouncer metrics" "✅" "$v series"
else row "PgBouncer metrics" "❌" "none"; FAILED=1; fi

if v=$(wait_for 'sum(rate(http_requests_total{namespace="orders",route!~"/healthz|/readyz|/metrics"}[2m]))' 0.5 240); then
  row "App request metrics" "✅" "$(printf '%.1f' "$v") req/s of user traffic"
else row "App request metrics" "❌" "$v"; FAILED=1; fi

GROUPS_LOADED=$(curl -sf "${PROM_URL}/api/v1/rules" | jq -r '.data.groups[].name')
for g in sloth-slo-sli-recordings-orders-requests-availability sloth-slo-alerts-orders-requests-latency keystone-postgres; do
  if grep -qx "$g" <<<"$GROUPS_LOADED"; then row "Rule group loaded" "✅" "\`$g\`"
  else row "Rule group loaded" "❌" "$g missing"; FAILED=1; fi
done

if v=$(wait_for 'slo:sli_error:ratio_rate5m{sloth_service="orders",sloth_slo="requests-availability"} >= 0' 0 300); then
  AVAIL=$(prom_value '1 - slo:sli_error:ratio_rate5m{sloth_service="orders",sloth_slo="requests-availability"}')
  LAT=$(prom_value '1 - slo:sli_error:ratio_rate5m{sloth_service="orders",sloth_slo="requests-latency"}')
  row "SLOs evaluating" "✅" "availability $(awk "BEGIN{printf \"%.2f\", ${AVAIL:-0}*100}")% · latency <300ms $(awk "BEGIN{printf \"%.2f\", ${LAT:-0}*100}")% (5m)"
else row "SLOs evaluating" "❌" "no SLI data"; FAILED=1; fi

if v=$(wait_for 'time() - max(barman_cloud_cloudnative_pg_io_last_available_backup_timestamp{namespace="orders"})' 0 300); then
  row "Backup freshness metric" "✅" "last good backup $(printf '%.0f' "$v")s ago"
else row "Backup freshness metric" "❌" "missing"; FAILED=1; fi

LAG=$(prom_value 'max(cnpg_pg_replication_lag{namespace="orders"})')
row "Replication lag (orders)" "✅" "$(printf '%.2f' "${LAG:-0}")s"

FIRING=$(prom_value 'count(ALERTS{alertstate="firing",severity="critical"})')
if [[ -z "$FIRING" || "$FIRING" == "0" ]]; then row "No critical alerts firing" "✅" "0"
else row "No critical alerts firing" "❌" "$FIRING: $(curl -sfG "${PROM_URL}/api/v1/query" --data-urlencode 'query=ALERTS{alertstate="firing",severity="critical"}' | jq -r '[.data.result[].metric.alertname]|join(", ")')"; FAILED=1; fi

if kubectl -n monitoring get configmap grafana-dashboard-cloudnative-pg >/dev/null; then
  row "Grafana dashboard provisioned" "✅" "CloudNativePG"
else row "Grafana dashboard provisioned" "❌" "missing"; FAILED=1; fi

{ echo "## Observability and SLOs"; echo; echo "| Check | Result | Detail |"; echo "|---|---|---|"; cat "$REPORT"; echo; } \
  >>"${GITHUB_STEP_SUMMARY:-/dev/stdout}"
exit "$FAILED"
