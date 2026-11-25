#!/usr/bin/env bash
# Fonctions communes. À sourcer : . scripts/lib.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ROOT
REGISTRY="${REGISTRY:-localhost:5001}"
CLUSTER_NAME="${CLUSTER_NAME:-helpdesk}"
HTTPS_PORT="${HTTPS_PORT:-8443}"
# kubeconfig généré par Terraform (sauf si KUBECONFIG est déjà défini)
if [ -z "${KUBECONFIG:-}" ] && [ -f "$ROOT/terraform/cluster/${CLUSTER_NAME}-config" ]; then
  export KUBECONFIG="$ROOT/terraform/cluster/${CLUSTER_NAME}-config"
fi
mkdir -p "$ROOT/results"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m OK\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m !! \033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERR\033[0m %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "'$1' est introuvable (voir LANCEMENT.md, étape 0)"; }

host_for() { echo "$1.helpdesk.localtest.me"; }   # dev | prod | ci
ns_for()   { echo "helpdesk-$1"; }
last_tag() { cat "$ROOT/.last_tag" 2>/dev/null || echo dev; }
