#!/usr/bin/env bash
# Construit et publie les 3 images dans le registre (local par défaut : localhost:5001).
# Usage : build-push.sh [tag]
. "$(dirname "$0")/lib.sh"; need docker
TAG="${1:-$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || date +%Y%m%d%H%M%S)}"
for svc in backend worker frontend; do
  log "build + push helpdesk-$svc:$TAG"
  docker build -q -t "$REGISTRY/helpdesk-$svc:$TAG" "$ROOT/app/$svc"
  docker push -q "$REGISTRY/helpdesk-$svc:$TAG" >/dev/null
done
echo "$TAG" > "$ROOT/.last_tag"
ok "images publiées dans $REGISTRY avec le tag $TAG"
curl -s "http://$REGISTRY/v2/_catalog" || true; echo
