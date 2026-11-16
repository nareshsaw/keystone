#!/usr/bin/env bash
# Phase 3 acceptance checks: self-service databases come up with cost showback, and the guardrails
# reject unsafe or over-budget requests at the API server (Gatekeeper admission, server-side dry-run).
set -euo pipefail
cd "$(dirname "$0")/.."
SAMPLES=policies/tests/samples
REPORT="$(mktemp)"
FAILED=0
row() { echo "| $1 | $2 | $3 |" >>"$REPORT"; echo "[$2] $1: $3"; }

for db in orders/orders-db inventory/inventory-db; do
  kubectl -n "${db%/*}" wait --for=condition=Ready "postgresdatabase/${db#*/}" --timeout=900s >/dev/null \
    || { row "Self-service: ${db#*/}" "❌" "not Ready"; FAILED=1; continue; }
  read -r inst cost phase < <(kubectl -n "${db%/*}" get postgresdatabase "${db#*/}" \
    -o jsonpath='{.status.instances} {.status.estimatedMonthlyCostUSD} {.status.phase}{"\n"}')
  row "Self-service: ${db#*/} (${db%/*})" "✅" "${inst} instance(s) · ${phase} · est. ${cost}/month"
done

echo; kubectl get postgresdatabases -A; echo

expect() { # file  allow|deny  description
  local out rc
  out=$(kubectl apply --dry-run=server -f "$1" 2>&1) && rc=0 || rc=$?
  local reason
  reason=$(sed -n 's/.*denied the request: //p' <<<"$out" | head -1 | cut -c1-180 | tr '|' '/')
  if [[ "$2" == allow && $rc -eq 0 ]]; then row "$3" "✅ allowed" "as expected"
  elif [[ "$2" == deny && $rc -ne 0 && -n "$reason" ]]; then row "$3" "⛔ denied" "$reason"
  else row "$3" "❌" "expected $2, got: $(head -c 200 <<<"$out" | tr '\n|' ' /')"; FAILED=1; fi
}

expect "$SAMPLES/db-good-prod.yaml"       allow "Prod database, small tier, within budget"
expect "$SAMPLES/db-good-dev.yaml"        allow "Hibernated dev database"
expect "$SAMPLES/db-prod-no-backup.yaml"  deny  "Prod database without backups"
expect "$SAMPLES/db-prod-hibernated.yaml" deny  "Hibernate a prod database"
expect "$SAMPLES/db-dev-large.yaml"       deny  "Large tier in dev"
expect "$SAMPLES/db-too-much-storage.yaml" deny "Storage above the tier limit"
expect "$SAMPLES/db-env-mismatch.yaml"    deny  "Environment does not match namespace"
expect "$SAMPLES/db-over-budget.yaml"     deny  "Medium prod database over a \$60 budget (FinOps)"
expect "$SAMPLES/cluster-bypass.yaml"     deny  "Hand-rolled prod Postgres bypassing self-service"
expect "$SAMPLES/ns-missing-labels.yaml"  deny  "Tenant namespace without owner/budget labels"

{ echo "## Self-service and guardrails"; echo; echo "| Request | Result | Detail |"; echo "|---|---|---|"; cat "$REPORT"; echo; } \
  >>"${GITHUB_STEP_SUMMARY:-/dev/stdout}"
exit "$FAILED"
