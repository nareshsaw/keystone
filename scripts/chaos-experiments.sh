#!/usr/bin/env bash
# Phase 6: failure experiments under load, with measured RTO and RPO.
#   pod-kill           : the primary's pod is force-deleted with no grace period (crash / OOM kill)
#   network-isolation  : every packet to and from the primary is dropped for 60 s on its node (split brain)
# Faults are injected directly (kubectl / iptables in the kind node), the same mechanisms chaos tools use.
# For each: k6 writes 20 orders/s throughout; we measure time to a new primary, the longest gap in successful
# writes, failed requests, and whether every acknowledged write survived.
set -euo pipefail
cd "$(dirname "$0")/.."
NS=orders; CLUSTER=orders-db
REPORT="$(mktemp)"; FAILED=0; RESULTS=chaos-results; mkdir -p "$RESULTS"
row() { echo "| $* |" >>"$REPORT"; echo "[$1] $*"; }
now_ms() { date +%s%3N; }
primary() { kubectl -n $NS get cluster $CLUSTER -o jsonpath='{.status.currentPrimary}'; }
healthy() { [[ "$(kubectl -n $NS get cluster $CLUSTER -o jsonpath='{.status.phase} {.status.readyInstances}')" == "Cluster in healthy state 3" ]]; }
wait_healthy() { for _ in $(seq 1 $(( $1 / 5 ))); do healthy && return 0; sleep 5; done; return 1; }
psql_on() { kubectl -n $NS exec "$1" -c postgres -- psql -U postgres -d orders -tAc "$2"; }

kubectl -n $NS create configmap chaos-write-probe --from-file=chaos/write-probe.js --dry-run=client -o yaml | kubectl apply -f - >/dev/null

run_experiment() { # name
  local name=$1 run old new t_inject t_failover t_healed
  run="${name}-$(date +%s)"
  wait_healthy 300 || { row "$name" "❌ cluster not healthy before start" "" "" "" "" ""; FAILED=1; return; }
  kubectl -n $NS delete job write-probe --ignore-not-found --wait=true >/dev/null
  kubectl -n $NS apply -f - >/dev/null <<YAML
apiVersion: batch/v1
kind: Job
metadata: { name: write-probe }
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      securityContext: { runAsNonRoot: true, runAsUser: 12345, seccompProfile: { type: RuntimeDefault } }
      containers:
        - name: k6
          image: grafana/k6:2.4.0
          args: [run, --quiet, --no-color, -e, RUN=${run}, -e, DURATION=150s, /scripts/write-probe.js]
          volumeMounts: [{ name: s, mountPath: /scripts, readOnly: true }]
          securityContext: { allowPrivilegeEscalation: false, capabilities: { drop: [ALL] } }
      volumes: [{ name: s, configMap: { name: chaos-write-probe } }]
YAML
  kubectl -n $NS wait --for=condition=Ready pod -l job-name=write-probe --timeout=120s >/dev/null
  sleep 30                                   # baseline under load
  old=$(primary); t_inject=$(now_ms)
  local node ip
  node=$(kubectl -n $NS get pod "$old" -o jsonpath='{.spec.nodeName}')
  ip=$(kubectl -n $NS get pod "$old" -o jsonpath='{.status.podIP}')
  case $name in
    pod-kill)
      kubectl -n $NS delete pod "$old" --grace-period=0 --force >/dev/null 2>&1
      ;;
    network-isolation)
      # Drop all traffic of the primary at its node: pod<->pod (FORWARD) and pod<->node/kubelet (INPUT/OUTPUT).
      # Established connections die too; kubectl exec still works (it goes through the container runtime).
      docker exec "$node" sh -c "iptables -I FORWARD 1 -s $ip -j DROP && iptables -I FORWARD 1 -d $ip -j DROP \
        && iptables -I INPUT 1 -s $ip -j DROP && iptables -I OUTPUT 1 -d $ip -j DROP"
      ( sleep 60; docker exec "$node" sh -c "iptables -D FORWARD -s $ip -j DROP; iptables -D FORWARD -d $ip -j DROP; \
          iptables -D INPUT -s $ip -j DROP; iptables -D OUTPUT -d $ip -j DROP" ) &
      HEAL_PID=$!
      ;;
  esac
  new=$old
  for _ in $(seq 1 360); do new=$(primary); [[ "$new" != "$old" && -n "$new" ]] && break; sleep 0.5; done
  t_failover=$(now_ms)
  local writers="n/a"
  if [[ "$name" == network-isolation && "$new" != "$old" ]]; then
    # Split-brain check while the old primary is still cut off: how many instances accept writes?
    writers=0
    for pod in $(kubectl -n $NS get pods -l cnpg.io/cluster=$CLUSTER,cnpg.io/podRole=instance -o name); do
      r=$(timeout 8 kubectl -n $NS exec "${pod#pod/}" -c postgres -- psql -U postgres -tAc "select pg_is_in_recovery()" 2>/dev/null || echo down)
      echo "    ${pod#pod/}: in_recovery=${r}"
      [[ "$r" == "f" ]] && writers=$((writers + 1))
    done
  fi
  kubectl -n $NS wait --for=condition=complete job/write-probe --timeout=300s >/dev/null || true
  [[ -n "${HEAL_PID:-}" ]] && { wait "$HEAL_PID" || true; HEAL_PID=""; }
  wait_healthy 420 && t_healed=$(now_ms) || t_healed=""
  kubectl -n $NS logs job/write-probe > "$RESULTS/$run.log"

  # ---- analyse the probe log
  local stats acked errors outage lost failover_s healed_s p99
  stats=$(python3 - "$RESULTS/$run.log" "$t_inject" <<'PY'
import re, sys, json
log, t_inject = sys.argv[1], int(sys.argv[2])
acks, errs = [], 0
for line in open(log):
    m = re.search(r'(ACK|ERR) (\S+) (\d+) (\d+)', line)
    if not m: continue
    if m.group(1) == "ACK": acks.append((m.group(2), int(m.group(3)), int(m.group(4))))
    else: errs += 1
done = sorted(a[2] for a in acks)
window = [d for d in done if d >= t_inject - 5000]
gaps = [b - a for a, b in zip(window, window[1:])]
lat = sorted(a[2] - a[1] for a in acks)
p99 = lat[int(len(lat) * 0.99) - 1] if lat else 0
json.dump({"acked": len(acks), "errors": errs, "outage_ms": max(gaps) if gaps else None, "p99_ms": p99,
           "items": [a[0] for a in acks]}, open(log + ".json", "w"))
print(len(acks), errs, max(gaps) if gaps else -1, p99)
PY
)
  read -r acked errors outage p99 <<<"$stats"
  # ---- RPO: every acknowledged write must be in the database
  local current; current=$(primary)
  psql_on "$current" "SELECT item FROM orders WHERE item LIKE 'chaos-${run}-%'" > "$RESULTS/$run.db"
  lost=$(python3 -c "import json,sys; a=set(json.load(open('$RESULTS/$run.log.json'))['items']); d=set(open('$RESULTS/$run.db').read().split()); print(len(a-d))")
  failover_s=$(awk "BEGIN{printf \"%.1f\", ($t_failover - $t_inject)/1000}")
  healed_s=$([[ -n "$t_healed" ]] && awk "BEGIN{printf \"%.0f\", ($t_healed - $t_inject)/1000}" || echo "not healed")
  local outage_s; outage_s=$(awk "BEGIN{printf \"%.1f\", $outage/1000}")
  local ok="✅"
  [[ "$new" != "$old" && "$lost" -eq 0 && "$acked" -gt 0 && -n "$t_healed" ]] || { ok="❌"; FAILED=1; }
  [[ "$writers" == "n/a" || "$writers" -eq 1 ]] || { ok="❌"; FAILED=1; }
  row "$name" "$ok" "${failover_s}s" "${outage_s}s" "$errors" "$acked" "**$lost**" "$writers" "${healed_s}s"
  echo "$name failover=${failover_s}s outage=${outage_s}s errors=$errors acked=$acked lost=$lost writers=$writers healed=${healed_s}s p99=${p99}ms" >> "$RESULTS/summary.txt"
}

run_experiment pod-kill
run_experiment network-isolation

{
  echo "## Resilience: chaos experiments under 20 writes/s"; echo
  echo "| Experiment | Result | New primary after | Longest write gap | Failed requests | Acknowledged writes | **Lost acknowledged writes (RPO)** | Primaries accepting writes during partition | Back to 3 healthy instances |"
  echo "|---|---|---|---|---|---|---|---|---|"
  cat "$REPORT"; echo
} >>"${GITHUB_STEP_SUMMARY:-/dev/stdout}"
cat "$RESULTS/summary.txt"
exit "$FAILED"
