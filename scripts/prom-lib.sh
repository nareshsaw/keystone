#!/usr/bin/env bash
# Shared helpers: port-forward Prometheus and run instant queries.
PROM_PORT="${PROM_PORT:-19090}"
PROM_URL="http://localhost:${PROM_PORT}"
prom_forward() {
  kubectl -n monitoring port-forward svc/kps-prometheus "${PROM_PORT}:9090" >/dev/null 2>&1 &
  export PROM_PF=$!  # killed by the sourcing script's EXIT trap
  for _ in $(seq 1 30); do curl -sf "${PROM_URL}/-/ready" >/dev/null && return 0; sleep 2; done
  echo "Prometheus not reachable"; return 1
}
# prom_value '<promql>' -> first sample value, or empty
prom_value() {
  curl -sfG "${PROM_URL}/api/v1/query" --data-urlencode "query=$1" | jq -r '.data.result[0].value[1] // empty'
}
