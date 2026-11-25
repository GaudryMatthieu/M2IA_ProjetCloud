#!/usr/bin/env bash
# Rolling update sans coupure + rollback. Usage : test-rolling-update.sh [env=prod]
. "$(dirname "$0")/lib.sh"; need kubectl; need curl
ENVN="${1:-prod}"; NS="$(ns_for "$ENVN")"; HOST="$(host_for "$ENVN")"; OUT="$ROOT/results/rolling-$ENVN.txt"
URL="https://$HOST:$HTTPS_PORT/api/healthz"
probe() { curl -sk --resolve "$HOST:$HTTPS_PORT:127.0.0.1" -o /dev/null -w "%{http_code}" --max-time 2 "$URL" || echo 000; }
{
echo "=== Rolling update du backend (rollout restart) sous trafic ==="
kubectl -n "$NS" rollout history deploy/backend | tail -3
ok_n=0; ko_n=0
( sleep 3; kubectl -n "$NS" rollout restart deploy/backend; kubectl -n "$NS" rollout status deploy/backend --timeout=240s ) &
RP=$!
while kill -0 $RP 2>/dev/null; do c="$(probe)"; [ "$c" = 200 ] && ok_n=$((ok_n+1)) || ko_n=$((ko_n+1)); sleep 0.3; done
echo "pendant le rollout : OK=$ok_n KO=$ko_n  (maxUnavailable=0 => objectif KO=0)"
echo; echo "=== Rollback ==="
kubectl -n "$NS" rollout undo deploy/backend
kubectl -n "$NS" rollout status deploy/backend --timeout=240s
kubectl -n "$NS" rollout history deploy/backend
} 2>&1 | tee "$OUT"
ok "résultats : $OUT"
