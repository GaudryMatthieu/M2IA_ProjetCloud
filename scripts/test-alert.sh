#!/usr/bin/env bash
# Déclenche l'alerte HelpdeskBackendDown (0 réplica) puis la résout. Usage : test-alert.sh [env=dev]
. "$(dirname "$0")/lib.sh"; need kubectl; need curl
ENVN="${1:-dev}"; NS="$(ns_for "$ENVN")"; OUT="$ROOT/results/alert-$ENVN.txt"
kubectl -n monitoring get svc kube-prometheus-stack-prometheus >/dev/null || die "stack de supervision absente (terraform/platform + monitoring-config)"
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090 >/dev/null 2>&1 & PF=$!
trap 'kill $PF 2>/dev/null; kubectl -n "$NS" scale deploy/backend --replicas=2 >/dev/null' EXIT
sleep 3
{
log "arrêt du backend (replicas=0)"; kubectl -n "$NS" scale deploy/backend --replicas=0
for i in $(seq 1 15); do
  state="$(curl -s localhost:9090/api/v1/alerts | python3 -c "import sys,json;a=[x for x in json.load(sys.stdin)['data']['alerts'] if x['labels']['alertname']=='HelpdeskBackendDown'];print(a[0]['state'] if a else 'absente')")"
  echo "$(date +%T) HelpdeskBackendDown = $state"; [ "$state" = firing ] && break; sleep 10
done
log "restauration du backend"; kubectl -n "$NS" scale deploy/backend --replicas=2
} 2>&1 | tee "$OUT"
ok "résultats : $OUT"
