#!/usr/bin/env bash
# Crée le Secret Kubernetes 'helpdesk-secrets' avec des valeurs aléatoires (jamais dans Git). A.5.17
# Usage : create-secrets.sh <namespace> [--rotate]
. "$(dirname "$0")/lib.sh"
NS="${1:?namespace}"; need kubectl; need openssl
kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create namespace "$NS"
if kubectl -n "$NS" get secret helpdesk-secrets >/dev/null 2>&1 && [ "${2:-}" != "--rotate" ]; then
  ok "secret déjà présent dans $NS (utiliser --rotate pour le régénérer)"; exit 0
fi
kubectl -n "$NS" create secret generic helpdesk-secrets \
  --from-literal=POSTGRES_PASSWORD="$(openssl rand -hex 16)" \
  --from-literal=RABBITMQ_PASSWORD="$(openssl rand -hex 16)" \
  --from-literal=S3_ACCESS_KEY="hd$(openssl rand -hex 6)" \
  --from-literal=S3_SECRET_KEY="$(openssl rand -hex 20)" \
  --from-literal=JWT_SECRET="$(openssl rand -hex 32)" \
  --from-literal=MINIO_KMS_SECRET_KEY="helpdesk-key:$(openssl rand -base64 32)" \
  --dry-run=client -o yaml | kubectl apply -f -
ok "secret helpdesk-secrets créé dans $NS"
