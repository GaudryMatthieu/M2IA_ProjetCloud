#!/usr/bin/env bash
# Démontre l'autoscaling horizontal du back-end. Usage : test-hpa.sh [env=dev] [durée_s=300]
. "$(dirname "$0")/lib.sh"; need kubectl
ENVN="${1:-dev}"; DUR="${2:-300}"; NS="$(ns_for "$ENVN")"; OUT="$ROOT/results/hpa-$ENVN.txt"
kubectl top nodes >/dev/null 2>&1 || die "metrics-server indisponible (terraform/platform appliqué ?)"
: > "$OUT"
log "état initial"; kubectl -n "$NS" get hpa backend | tee -a "$OUT"
kubectl -n "$NS" delete pod load-test --ignore-not-found >/dev/null
# 1) création d'un utilisateur existant (le login avec mauvais mot de passe déclenche un bcrypt = CPU)
kubectl -n "$NS" run seed-user --rm -i --restart=Never --image=curlimages/curl --labels=app=load-test --quiet -- \
  -s -o /dev/null -X POST http://backend:8000/auth/register -H 'Content-Type: application/json' \
  -d '{"email":"load@example.com","password":"password123"}' || true
# 2) générateur de charge (8 boucles parallèles)
kubectl -n "$NS" run load-test --image=curlimages/curl --labels=app=load-test --restart=Never --command -- sh -c '
for i in 1 2 3 4 5 6 7 8; do
  ( while true; do curl -s -o /dev/null -X POST http://backend:8000/auth/login -H "Content-Type: application/json" \
      -d "{\"email\":\"load@example.com\",\"password\":\"wrong-password\"}"; done ) &
done; wait'
log "charge lancée, observation pendant ${DUR}s (Ctrl-C pour arrêter)"
END=$(( $(date +%s) + DUR ))
while [ "$(date +%s)" -lt "$END" ]; do
  line="$(date +%T)  $(kubectl -n "$NS" get hpa backend --no-headers | awk '{print "cpu="$3" replicas="$6}')"
  echo "$line" | tee -a "$OUT"
  sleep 10
done
log "arrêt de la charge -> retour à la normale (scale-down après ~1-5 min)"
kubectl -n "$NS" delete pod load-test --ignore-not-found --wait=false >/dev/null
for i in $(seq 1 12); do
  echo "$(date +%T)  $(kubectl -n "$NS" get hpa backend --no-headers | awk '{print "cpu="$3" replicas="$6}')" | tee -a "$OUT"; sleep 15
done
ok "résultats : $OUT"
