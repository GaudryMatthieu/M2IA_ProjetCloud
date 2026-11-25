#!/usr/bin/env bash
# Scan de vulnérabilités des images (Trivy exécuté dans un conteneur). A.8.7 / A.8.25
. "$(dirname "$0")/lib.sh"; need docker
TAG="${1:-$(last_tag)}"
for svc in backend worker frontend; do
  log "trivy $svc:$TAG"
  docker run --rm -v /var/run/docker.sock:/var/run/docker.sock aquasec/trivy:latest image \
    --severity HIGH,CRITICAL --ignore-unfixed "$REGISTRY/helpdesk-$svc:$TAG" | tee "$ROOT/results/trivy-$svc.txt" | tail -15
done
ok "rapports : results/trivy-*.txt"
