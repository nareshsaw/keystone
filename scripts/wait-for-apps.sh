#!/usr/bin/env bash
# Waits until every Argo CD application is Synced and Healthy, or fails with diagnostics.
set -uo pipefail
TIMEOUT="${1:-1200}"
EXPECTED="${EXPECTED_APPS:-7}"
deadline=$((SECONDS + TIMEOUT))
while (( SECONDS < deadline )); do
  status=$(kubectl get applications -n argocd \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.sync.status}{" "}{.status.health.status}{"\n"}{end}' 2>/dev/null)
  total=$(grep -c . <<<"$status")
  ready=$(grep -c " Synced Healthy$" <<<"$status")
  echo "[$(date +%H:%M:%S)] ${ready}/${EXPECTED} apps Synced+Healthy"
  if (( total >= EXPECTED && ready == total )); then
    kubectl get applications -n argocd
    exit 0
  fi
  sleep 20
done
echo "::error::Timed out waiting for Argo CD applications"
kubectl get applications -n argocd -o wide
for app in $(kubectl get applications -n argocd -o name); do
  echo "---- ${app}"
  kubectl get "$app" -n argocd -o jsonpath='{.status.conditions}{"\n"}{.status.operationState.message}{"\n"}'
  kubectl get "$app" -n argocd -o jsonpath='{range .status.resources[?(@.health.status!="Healthy")]}{.kind}/{.name} {.health.status} {.health.message}{"\n"}{end}'
done
kubectl get pods -A | grep -vE "Running|Completed" || true
kubectl get events -A --sort-by=.lastTimestamp | tail -40
exit 1
