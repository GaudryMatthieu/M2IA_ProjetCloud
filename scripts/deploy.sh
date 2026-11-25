#!/usr/bin/env bash
# Déploie l'application (Kustomize) dans un environnement. Usage : deploy.sh <dev|prod|ci> [tag]
. "$(dirname "$0")/lib.sh"; need kubectl
ENVN="${1:?env (dev|prod|ci)}"; TAG="${2:-$(last_tag)}"; NS="$(ns_for "$ENVN")"
[ "$ENVN" = "ci" ] && TAG="ci"
"$ROOT/scripts/create-secrets.sh" "$NS"
[ "$ENVN" = "ci" ] || "$ROOT/scripts/gen-tls.sh" "$ENVN"

log "kubectl apply -k k8s/overlays/$ENVN  (tag=$TAG)"
kubectl kustomize "$ROOT/k8s/overlays/$ENVN" | sed "s/TAG_PLACEHOLDER/$TAG/g" | kubectl apply -f -

log "attente des services de données"
for s in postgres rabbitmq minio; do kubectl -n "$NS" rollout status "statefulset/$s" --timeout=300s; done
log "attente des applications"
for d in backend worker frontend; do kubectl -n "$NS" rollout status "deployment/$d" --timeout=300s; done
ok "environnement $ENVN déployé (tag $TAG)"
kubectl -n "$NS" get pods,hpa,ingress
