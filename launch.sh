#!/usr/bin/env bash
# Point d'entrée unique. ./launch.sh help
. "$(dirname "${BASH_SOURCE[0]}")/scripts/lib.sh"
S="$ROOT/scripts"
cd "$ROOT"

usage() { cat <<'U'
Usage : ./launch.sh <commande> [args]

  ÉTAPE 0  check                    vérifie les prérequis
  ÉTAPE 1  test                     lint + tests unitaires (back + worker) dans des conteneurs Docker
  ÉTAPE 2  compose-env              génère .env (secrets aléatoires)
           compose-up               lance toute la stack en local (docker compose)   [MONITORING=1 pour Prometheus+Grafana]
           compose-test             smoke test de bout en bout sur la stack compose
           compose-down [-v]        arrête la stack (-v : supprime aussi les volumes)
  ÉTAPE 3  infra-up                 Terraform : cluster kind + registre + ingress + quotas + supervision   [ENABLE_MONITORING=false pour alléger]
  ÉTAPE 4  build [tag]              construit + publie les images dans le registre local
           scan [tag]               scan de vulnérabilités Trivy
  ÉTAPE 5  deploy <dev|prod> [tag]  déploie sur Kubernetes (Kustomize)
           smoke <dev|prod>         smoke test via l'Ingress (HTTPS)
  ÉTAPE 6  monitoring-config        ServiceMonitors + règles d'alerte + dashboard Grafana
           grafana                  affiche le mot de passe et ouvre un port-forward sur http://localhost:3000
  ÉTAPE 7  t-hpa | t-resilience | t-rolling | t-backup | t-alert     tests d'exploitation (résultats dans results/)
  ÉTAPE 8  finops-snapshot <label> | finops-images
           status                   état du cluster
           all-local                enchaîne les étapes 0 à 8 (≈ 20-30 min la première fois)
           infra-down               détruit le cluster (Terraform destroy)
U
}

cmd="${1:-help}"; shift || true
case "$cmd" in
  help|-h|--help) usage ;;
  check) "$S/check-prereqs.sh" ;;

  test)
    need docker
    log "back-end : ruff + pytest"
    docker run --rm -v "$ROOT/app/backend":/src -w /src python:3.12-slim sh -c "pip install -q -r requirements-dev.txt && ruff check . && python -m pytest -q"
    log "worker : ruff + pytest"
    docker run --rm -v "$ROOT/app/worker":/src -w /src python:3.12-slim sh -c "pip install -q -r requirements-dev.txt && ruff check . && python -m pytest -q"
    ok "tests unitaires OK" ;;

  compose-env)
    if [ -f .env ]; then warn ".env existe déjà, non modifié"; else
      need openssl
      cat > .env <<EOF
POSTGRES_USER=helpdesk
POSTGRES_PASSWORD=$(openssl rand -hex 16)
POSTGRES_DB=helpdesk
RABBITMQ_USER=helpdesk
RABBITMQ_PASSWORD=$(openssl rand -hex 16)
S3_ACCESS_KEY=hd$(openssl rand -hex 6)
S3_SECRET_KEY=$(openssl rand -hex 20)
MINIO_KMS_SECRET_KEY=helpdesk-key:$(openssl rand -base64 32)
JWT_SECRET=$(openssl rand -hex 32)
GRAFANA_ADMIN_PASSWORD=$(openssl rand -hex 8)
EOF
      ok ".env généré (non versionné)"; fi ;;
  compose-up)
    [ -f .env ] || "$0" compose-env
    prof=(); [ "${MONITORING:-0}" = 1 ] && prof=(--profile monitoring)
    docker compose "${prof[@]}" up -d --build
    ok "front : http://localhost:8081 | API/Swagger : http://localhost:8000/docs | RabbitMQ : http://localhost:15672 | MinIO : http://localhost:9001"
    [ "${MONITORING:-0}" = 1 ] && ok "Prometheus : http://localhost:9090 | Grafana : http://localhost:3000 (admin / GRAFANA_ADMIN_PASSWORD du .env)"
    log "attente de l'API…"; for i in $(seq 1 40); do curl -fs http://localhost:8000/readyz >/dev/null 2>&1 && break; sleep 3; done
    docker compose ps ;;
  compose-test) "$S/smoke-test.sh" compose ;;
  compose-down) docker compose --profile monitoring down "$@" ;;

  infra-up)
    need terraform; need docker; need kubectl
    log "Terraform 1/2 : cluster + réseau + registre"
    terraform -chdir=terraform/cluster init -input=false
    terraform -chdir=terraform/cluster apply -auto-approve -input=false
    export KUBECONFIG="$ROOT/terraform/cluster/${CLUSTER_NAME}-config"
    log "Terraform 2/2 : plateforme (ingress, quotas, supervision)"
    terraform -chdir=terraform/platform init -input=false
    terraform -chdir=terraform/platform apply -auto-approve -input=false -var "enable_monitoring=${ENABLE_MONITORING:-true}"
    ok "infrastructure prête. Pour kubectl dans votre terminal :  export KUBECONFIG=$ROOT/terraform/cluster/${CLUSTER_NAME}-config"
    kubectl get nodes ;;
  infra-down)
    need terraform
    terraform -chdir=terraform/platform destroy -auto-approve -input=false || true
    terraform -chdir=terraform/cluster destroy -auto-approve -input=false
    rm -rf "$ROOT/.tls" "$ROOT/.last_tag"; ok "infrastructure détruite" ;;

  build) "$S/build-push.sh" "$@" ;;
  scan) "$S/trivy-scan.sh" "$@" ;;
  deploy) "$S/deploy.sh" "$@" ;;
  smoke) "$S/smoke-test.sh" "$@" ;;

  monitoring-config)
    need kubectl
    kubectl apply -f k8s/monitoring/monitoring.yaml
    kubectl -n monitoring create configmap helpdesk-dashboard \
      --from-file=helpdesk.json=monitoring/grafana/dashboards/helpdesk.json --dry-run=client -o yaml \
      | kubectl label --local -f - grafana_dashboard=1 -o yaml | kubectl apply -f -
    ok "règles d'alerte, ServiceMonitors et dashboard appliqués" ;;
  grafana)
    pw="$(terraform -chdir=terraform/platform output -raw grafana_admin_password)"
    ok "http://localhost:3000   utilisateur : admin   mot de passe : $pw"
    kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80 ;;

  t-hpa) "$S/test-hpa.sh" "$@" ;;
  t-resilience) "$S/test-resilience.sh" "$@" ;;
  t-rolling) "$S/test-rolling-update.sh" "$@" ;;
  t-backup) "$S/test-backup.sh" "$@" ;;
  t-alert) "$S/test-alert.sh" "$@" ;;
  finops-snapshot) "$S/finops.sh" snapshot "$@" ;;
  finops-images) "$S/finops.sh" images ;;

  status) kubectl get nodes; kubectl get pods -A | grep -E 'helpdesk|monitoring|ingress' || true ;;

  all-local)
    "$0" check
    "$0" test
    "$0" compose-env
    "$0" compose-up
    "$0" compose-test
    "$0" compose-down
    "$0" infra-up
    "$0" build
    "$0" scan || warn "scan en échec (non bloquant ici)"
    "$0" finops-images || true
    "$0" deploy dev
    "$0" smoke dev
    "$0" deploy prod
    "$0" smoke prod
    [ "${ENABLE_MONITORING:-true}" = true ] && "$0" monitoring-config
    "$0" finops-snapshot avant-tests
    "$0" t-rolling
    "$0" t-resilience
    "$0" t-backup dev
    "$0" t-hpa dev
    [ "${ENABLE_MONITORING:-true}" = true ] && "$0" t-alert prod
    "$0" finops-snapshot apres-tests
    ok "tout est terminé : consultez le dossier results/" ;;
  *) usage; exit 1 ;;
esac
