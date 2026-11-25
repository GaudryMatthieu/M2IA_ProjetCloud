#!/usr/bin/env bash
. "$(dirname "$0")/lib.sh"
fail=0
for t in docker git openssl curl python3; do
  if command -v $t >/dev/null; then ok "$t"; else warn "$t manquant"; fail=1; fi
done
docker info >/dev/null 2>&1 && ok "daemon Docker actif" || { warn "Docker ne répond pas (Docker Desktop lancé ?)"; fail=1; }
docker compose version >/dev/null 2>&1 && ok "docker compose" || { warn "docker compose manquant"; fail=1; }
for t in kubectl terraform; do
  if command -v $t >/dev/null; then ok "$t ($($t version --client 2>/dev/null | head -1 || true))"; else warn "$t manquant (requis à partir de l'étape Kubernetes)"; fi
done
[ $fail -eq 0 ] || die "prérequis de base manquants"
