#!/usr/bin/env bash
# Tests de résilience : (1) suppression de pods back-end sous trafic, (2) perte du pod PostgreSQL (persistance PV).
# Usage : test-resilience.sh [env=prod]  (prod = 2 réplicas minimum)
. "$(dirname "$0")/lib.sh"; need kubectl; need curl
ENVN="${1:-prod}"; NS="$(ns_for "$ENVN")"; HOST="$(host_for "$ENVN")"; OUT="$ROOT/results/resilience-$ENVN.txt"
URL="https://$HOST:$HTTPS_PORT/api/healthz"
probe() { curl -sk --resolve "$HOST:$HTTPS_PORT:127.0.0.1" -o /dev/null -w "%{http_code}" --max-time 2 "$URL" || echo 000; }
{
echo "=== Test 1 : suppression de pods backend (un à la fois) pendant 40 s de trafic ==="
kubectl -n "$NS" rollout status deploy/backend --timeout=120s
ok_n=0; ko_n=0
( sleep 5; kubectl -n "$NS" delete "$(kubectl -n "$NS" get pod -l app=backend -o name | head -1)" --wait=false
  sleep 15; kubectl -n "$NS" delete "$(kubectl -n "$NS" get pod -l app=backend -o name | head -1)" --wait=false ) &
for i in $(seq 1 100); do c="$(probe)"; [ "$c" = 200 ] && ok_n=$((ok_n+1)) || ko_n=$((ko_n+1)); sleep 0.4; done
wait
echo "requêtes OK=$ok_n KO=$ko_n  (objectif : 0 ou très peu de KO grâce aux 2 réplicas)"
kubectl -n "$NS" get pods -l app=backend

echo; echo "=== Test 2 : persistance — suppression du pod PostgreSQL ==="
python3 "$ROOT/scripts/api_client.py" seed --url "https://127.0.0.1:$HTTPS_PORT" --host "$HOST"
kubectl -n "$NS" delete pod postgres-0
kubectl -n "$NS" wait --for=condition=Ready pod/postgres-0 --timeout=180s
sleep 10
python3 "$ROOT/scripts/api_client.py" verify --url "https://127.0.0.1:$HTTPS_PORT" --host "$HOST"
kubectl -n "$NS" get pvc
} 2>&1 | tee "$OUT"
ok "résultats : $OUT"
