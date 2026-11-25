#!/usr/bin/env bash
# Certificat TLS auto-signé pour l'Ingress (chiffrement en transit, A.8.24).
# Usage : gen-tls.sh <env: dev|prod|ci>
. "$(dirname "$0")/lib.sh"
ENVN="${1:?env}"; need kubectl; need openssl
NS="$(ns_for "$ENVN")"; HOST="$(host_for "$ENVN")"
kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create namespace "$NS"
if kubectl -n "$NS" get secret helpdesk-tls >/dev/null 2>&1; then ok "TLS déjà présent dans $NS"; exit 0; fi
D="$ROOT/.tls/$ENVN"; mkdir -p "$D"
openssl req -x509 -newkey rsa:2048 -nodes -days 365 -keyout "$D/tls.key" -out "$D/tls.crt" \
  -subj "/CN=$HOST" -addext "subjectAltName=DNS:$HOST" 2>/dev/null
kubectl -n "$NS" create secret tls helpdesk-tls --cert="$D/tls.crt" --key="$D/tls.key"
ok "certificat TLS créé pour $HOST"
