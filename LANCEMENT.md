# LANCEMENT.md — Ordre d'exécution du projet « Du code à la supervision »

Application **Helpdesk** (tickets) : front Nginx + API FastAPI + worker + PostgreSQL + RabbitMQ + MinIO (stockage objet S3), déployée sur Kubernetes, livrée par CI/CD, provisionnée par Terraform et supervisée.

Tout se lance **depuis ton PC**, dans des conteneurs Docker. Kubernetes tourne dans Docker grâce à *kind*, piloté par Terraform. Les seuls services distants sont ceux que le sujet impose : **GitHub Actions** (CI/CD) et **GHCR** (registre d'images).

Tu peux tout enchaîner avec `./launch.sh all-local`. Ce document explique chaque étape pour que tu puisses les lancer une par une, comprendre ce qui se passe et prendre tes captures pour le rapport.

---

## 0. Vue d'ensemble

```
Navigateur ──HTTPS──> Ingress NGINX ──> frontend (Nginx, SPA) ──/api──> backend (FastAPI, HPA 2→6)
                                                                          │   │   │
                                              PostgreSQL (PV) <───────────┘   │   └──> RabbitMQ ──> worker
                                              MinIO / S3 (PV, chiffré) <──────┴─────────────────────┘
                                              CronJob de sauvegarde : PostgreSQL ──> MinIO (backups/)
Supervision : Prometheus + Alertmanager + Grafana + Loki/Promtail (namespace monitoring)
```

| Besoin du sujet | Ce que fait le projet | Où |
|---|---|---|
| Front / back / worker dockerisés (multi-stage, légers, sans secret) | Images non-root, multi-stage pour back et worker | `app/*/Dockerfile` |
| Images taguées et publiées sur un registre | Registre local `localhost:5001` + **GHCR** via la CI | `scripts/build-push.sh`, `ci-cd.yml` |
| `docker compose` de toute la stack | front + back + worker + base + file + stockage objet | `docker-compose.yml` |
| Kubernetes : Deployments, Services, Ingress, ConfigMap/Secrets, requests/limits | Kustomize avec un overlay par environnement | `k8s/` |
| Autoscaling, résilience, rolling update, PV | HPA, PDB, StatefulSets avec PVC, scripts de test | `k8s/base/`, `scripts/test-*.sh` |
| Stockage objet pour les fichiers | **MinIO**, API S3 | `k8s/base/minio.yaml` |
| Traitement asynchrone | RabbitMQ + worker (notification et export CSV) | `app/worker/` |
| Pipeline CI/CD | lint, tests, scan Trivy, build, push, déploiement d'essai, déploiement local | `.github/workflows/ci-cd.yml` |
| IaC reproductible depuis zéro | Terraform : cluster, réseau, registre, ingress, namespaces, quotas, supervision | `terraform/` |
| Observabilité, alerte, SLI/SLO | Prometheus, Grafana, Loki, 4 alertes, 2 SLI | `monitoring/`, `k8s/monitoring/` |
| Sécurité (ISO 27001) | Voir le §11 | — |
| FinOps | Quotas, snapshot des coûts, mesure de la taille des images | `scripts/finops.sh` |

**Deux écarts assumés par rapport au sujet.**
- **Stockage objet « cloud »** : en local, c'est MinIO, compatible S3. Le code parle l'API S3 standard. Pour viser un vrai bucket cloud (AWS S3, Scaleway, Cloudflare R2…), il suffit de changer `S3_ENDPOINT` dans `k8s/base/kustomization.yaml` et les clés S3 dans le secret. Aucun code n'est à modifier.
- **Cluster** : Terraform crée un cluster *kind* local, pas un cluster managé (AKS/EKS). Le sujet demande « cluster + base + stockage + réseau » décrits en Terraform. Ici, la base et le stockage sont des StatefulSets déployés par Kustomize, et Terraform décrit le cluster, le réseau, le registre, l'ingress, les namespaces, les quotas et la supervision. À toi de décider si tu veux aller jusqu'à un cluster managé. Le code applicatif et les manifests ne changeraient pas.

---

## 1. Prérequis (étape 0)

**Machine** : 4 vCPU et 15 Go de disque libre. Compte **8 Go de RAM** sans supervision (`ENABLE_MONITORING=false`) et **12 à 16 Go** avec.
**Système** : Linux, macOS, ou Windows via **WSL2 + Docker Desktop**. Lance toutes les commandes **depuis le terminal WSL**.

```bash
# Docker (Desktop sur Windows/macOS, ou docker-ce sur Linux) + git + openssl + curl + python3
docker --version && docker compose version

# kubectl
curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install kubectl /usr/local/bin/

# Terraform (≥ 1.5) : https://developer.hashicorp.com/terraform/install
terraform -version
```

Puis, depuis le dossier du projet :

```bash
chmod +x launch.sh scripts/*.sh scripts/*.py
./launch.sh check
```
✔ Attendu : toutes les lignes en `OK`.

> Si `*.localtest.me` ne se résout pas (réseau d'entreprise, hors-ligne), ajoute à `/etc/hosts` :
> `127.0.0.1 dev.helpdesk.localtest.me prod.helpdesk.localtest.me`

---

## 2. Étape 1 — Tests unitaires et lint *(C7.2)*

```bash
./launch.sh test
```
Lance `ruff` et `pytest` dans un conteneur `python:3.12-slim`, pour le back-end puis pour le worker.
✔ Attendu : 8 tests back-end et 3 tests worker passent.

---

## 3. Étape 2 — Stack complète avec Docker Compose *(C6.2, C7.1)*

```bash
./launch.sh compose-env        # crée .env avec des secrets aléatoires (jamais committé)
./launch.sh compose-up         # build des 3 images + démarrage de 6 conteneurs
./launch.sh compose-test       # smoke test de bout en bout
```

Avec la supervision : `MONITORING=1 ./launch.sh compose-up`.

| Service | URL |
|---|---|
| Application | http://localhost:8081 (le **premier compte créé est « agent »**) |
| API / Swagger | http://localhost:8000/docs |
| RabbitMQ | http://localhost:15672 (identifiants dans `.env`) |
| MinIO | http://localhost:9001 (identifiants dans `.env`) |
| Prometheus / Grafana | http://localhost:9090 / http://localhost:3000 |

✔ Attendu pour `compose-test` : 9 lignes `[OK]`, puis `SMOKE TEST RÉUSSI`. Il vérifie la chaîne front → API → PostgreSQL → MinIO → RabbitMQ → worker.

```bash
./launch.sh compose-down       # arrêt (ajouter -v pour effacer les volumes)
```

---

## 4. Étape 3 — Infrastructure as Code : cluster Kubernetes *(C8.2, C6.1)*

```bash
ENABLE_MONITORING=true ./launch.sh infra-up      # false pour alléger
export KUBECONFIG=$PWD/terraform/cluster/helpdesk-config
kubectl get nodes
```

`infra-up` enchaîne **deux `terraform apply`**, séparés volontairement :

1. `terraform/cluster` : cluster kind (1 control-plane + 2 workers), ports 8080 et 8443 publiés sur ton PC, **registre d'images** `localhost:5001` rattaché au réseau du cluster.
2. `terraform/platform` : namespaces `helpdesk-dev` et `helpdesk-prod` avec **quotas** et valeurs par défaut, **ingress-nginx**, **metrics-server** (indispensable au HPA), puis **kube-prometheus-stack** et **Loki**.

Compte 5 à 15 minutes la première fois, le temps de télécharger les images.
✔ Attendu : 3 nœuds `Ready`, et `kubectl get pods -A` montre ingress-nginx, metrics-server et monitoring en `Running`.

**Reproductibilité depuis zéro** : `./launch.sh infra-down`, puis `./launch.sh infra-up`.

---

## 5. Étape 4 — Build, publication, scan *(C6.2, C7.1, C7.3)*

```bash
./launch.sh build              # tag = SHA git court (ou horodatage), écrit dans .last_tag
./launch.sh scan               # Trivy HIGH/CRITICAL → results/trivy-*.txt
./launch.sh finops-images      # compare image naïve et multi-stage → results/finops-images.txt
```
✔ Attendu : `curl localhost:5001/v2/_catalog` liste `helpdesk-backend`, `helpdesk-worker` et `helpdesk-frontend`.

---

## 6. Étape 5 — Déploiement Kubernetes *(C7.1, C8.1)*

```bash
./launch.sh deploy dev         # puis : ./launch.sh deploy prod
./launch.sh smoke dev
./launch.sh smoke prod
```

Le script `deploy.sh` fait, dans cet ordre :
1. crée le **Secret** `helpdesk-secrets` avec des valeurs aléatoires (`create-secrets.sh`) ;
2. crée un **certificat TLS** auto-signé pour l'Ingress (`gen-tls.sh`) ;
3. applique `kubectl kustomize k8s/overlays/<env>` ;
4. attend PostgreSQL, RabbitMQ et MinIO (StatefulSets), puis backend, worker et frontend.

| Environnement | URL | Réplicas back-end (HPA) |
|---|---|---|
| dev | https://dev.helpdesk.localtest.me:8443 | 1 → 5 |
| prod | https://prod.helpdesk.localtest.me:8443 | 2 → 6 |

Accepte l'avertissement du certificat auto-signé dans ton navigateur.

**Stratégie de déploiement (à documenter dans le rapport)** : *Rolling update* avec `maxUnavailable: 0` et `maxSurge: 1`, des sondes `readiness` et `startup`, et un PodDisruptionBudget. La promotion se fait d'abord en **dev**, puis la **même image** est déployée en **prod** (`./launch.sh deploy prod <tag>`). Sur GitHub, la promotion exige une approbation manuelle (voir §10).

*Option canary* (démonstration facultative) : dupliquer le Deployment `backend` en `backend-canary` avec un nouveau tag, créer son Service, puis ajouter un second Ingress avec les annotations `nginx.ingress.kubernetes.io/canary: "true"` et `canary-weight: "10"`.

✔ Attendu : `smoke dev` et `smoke prod` finissent par `SMOKE TEST RÉUSSI`.

---

## 7. Étape 6 — Observabilité *(C8.1, C6.3)*

```bash
./launch.sh monitoring-config  # ServiceMonitors + règles d'alerte + dashboard Grafana
./launch.sh grafana            # affiche le mot de passe admin + port-forward → http://localhost:3000
```

Dans Grafana : dashboard **« Helpdesk — Vue d'ensemble »** (débit, erreurs 5xx, latence p95, SLI, jobs du worker). Les **logs** sont dans *Explore → Loki*, avec la requête `{namespace="helpdesk-prod", container="backend"}`. Pour les événements de sécurité : `... |= "\"security\": true"`.

| Élément | Définition |
|---|---|
| SLI disponibilité | part de requêtes non-5xx sur 5 min, **SLO 99 %** |
| SLI latence | part de requêtes servies en moins de 500 ms, **SLO 95 %** |
| Alertes | `HelpdeskBackendDown` (critique), `HelpdeskHighErrorRate`, `HelpdeskHighLatencyP95`, `HelpdeskWorkerJobsFailing` |

---

## 8. Étape 7 — Tests d'exploitation *(C7.1, C8.1)*

Chaque test écrit son résultat dans `results/` : c'est ta preuve pour le rapport.

| Commande | Ce que ça démontre | Résultat attendu |
|---|---|---|
| `./launch.sh t-hpa dev` | **Autoscaling** : charge CPU, puis montée du nombre de réplicas, puis retour à la normale | `results/hpa-dev.txt` : `replicas` passe de 1 à 3 ou plus |
| `./launch.sh t-resilience prod` | **Résilience** : suppression de pods back-end sous trafic, puis suppression du pod PostgreSQL | peu ou pas de KO ; le ticket est toujours là après le redémarrage (**PV**) |
| `./launch.sh t-rolling prod` | **Rolling update sans coupure**, puis **rollback** | `KO=0` pendant le rollout |
| `./launch.sh t-backup dev` | **Sauvegarde** vers MinIO, vérification SSE, **restauration** dans une base temporaire | liste des objets `backups/…`, puis `tickets_restaures` |
| `./launch.sh t-alert prod` | **Alerte** : arrêt du back-end, puis `HelpdeskBackendDown = firing` | état `firing` après environ 1 à 2 min |

Pour t'entraîner sans charge, tu peux aussi tuer un pod à la main : `kubectl -n helpdesk-prod delete pod -l app=backend`.

---

## 9. Étape 8 — FinOps *(C6.4)*

Le sujet demande « coût chiffré + au moins deux optimisations réellement appliquées, avec mesure de l'effet ».

```bash
export PRICE_VCPU_HOUR=<€ par vCPU-heure>   # à lire sur la grille tarifaire du cloud de référence
export PRICE_GB_HOUR=<€ par Go-heure de RAM>
./launch.sh finops-snapshot avant            # requests, usage réel (kubectl top), coût/h et coût/mois estimés
# ... applique tes optimisations (voir ci-dessous) ...
./launch.sh finops-snapshot apres
./launch.sh finops-images
```

Je n'ai pas mis de tarifs : je n'ai pas de source pour ta grille de prix. Cite la page tarifaire que tu utilises dans ton rapport.

Optimisations **déjà dans le dépôt**, que tu peux mesurer :
1. **Images multi-stage et slim** contre l'image naïve : `finops-images` donne la différence de taille.
2. **Réplicas minimums différents par environnement et HPA** : dev tourne à 1 réplica, prod à 2.
3. **Quotas par namespace** (Terraform) : plafond de consommation.

Optimisations **à appliquer toi-même**, avant/après :
- **Right-sizing** : compare `kubectl top pods` aux `requests` dans `k8s/base/*.yaml`, puis baisse-les.
- **Arrêt de dev hors heures de travail** : `kubectl -n helpdesk-dev scale deploy --all --replicas=0`.

---

## 10. CI/CD avec GitHub Actions *(C7.2, C7.3)*

1. Crée un dépôt GitHub (privé ou public) et pousse le projet :
   ```bash
   git init && git add . && git commit -m "init" && git branch -M main
   git remote add origin https://github.com/<toi>/<repo>.git && git push -u origin main
   ```
2. Le workflow `.github/workflows/ci-cd.yml` se lance au push :

| Job | Rôle |
|---|---|
| `lint-test` | ruff, pytest (back et worker), analyse bandit |
| `validate-infra` | `terraform validate` sur les deux dossiers, `kubeconform` sur les manifests |
| `build-push` | build, **scan Trivy bloquant** sur les CRITICAL corrigeables, push vers **GHCR** |
| `deploy-ephemeral` | cluster kind jetable dans le runner, déploiement, **smoke test** |
| `deploy-dev` / `deploy-prod` | *optionnels* : déploiement sur ton cluster local via un **runner auto-hébergé** |

3. **Contrôle d'accès au code (A.8.4)** : dans *Settings → Branches*, protège `main` (pull request obligatoire, relecture des Code Owners, checks verts). Édite `.github/CODEOWNERS` avec ton compte.
4. **Déploiement sur ton cluster local (optionnel)** : *Settings → Actions → Runners → New self-hosted runner* (sur ton PC). Puis, dans *Variables* : `DEPLOY_LOCAL=true` et `LOCAL_KUBECONFIG=<chemin absolu de terraform/cluster/helpdesk-config>`. Dans *Environments*, crée `dev` et `production`. Sur `production`, ajoute **Required reviewers** : c'est l'approbation manuelle avant la prod.

> Le premier `terraform validate` en CI est la première vraie validation de mon code Terraform (voir §12). Si un job échoue, ses logs te disent quoi corriger.

---

## 11. Correspondance ISO 27001:2022 (Annexe A)

| Mesure | Contrôle(s) | Où dans le dépôt |
|---|---|---|
| Chiffrement en transit : TLS sur l'Ingress, redirection HTTPS | A.8.24 | `k8s/base/ingress.yaml`, `scripts/gen-tls.sh` |
| Chiffrement au repos : SSE-S3 du bucket (clé KMS MinIO), mots de passe hachés bcrypt | A.8.24 | `app/backend/app/storage.py`, `security.py`, `minio.yaml` |
| RBAC Kubernetes : pods sans token d'API, `Role` limité pour le CI | A.5.15, A.8.2, A.8.3 | `k8s/base/rbac.yaml` |
| Conteneurs non-root, FS en lecture seule, `capabilities: drop ALL`, seccomp | A.8.3 | `k8s/base/backend.yaml` et autres |
| Authentification : JWT signé, mot de passe ≥ 8, bcrypt, rôles agent/utilisateur | A.8.5 | `app/backend/app/security.py` |
| Secrets : générés aléatoirement, jamais dans Git, `.env` ignoré | A.5.17, A.8.12 | `scripts/create-secrets.sh`, `.gitignore` |
| Journalisation des événements de sécurité : logs JSON, champ `security:true` | A.8.15 | `logging_conf.py`, Loki |
| Supervision, dashboards, alertes | A.8.16 | `monitoring/`, `k8s/monitoring/` |
| Sauvegarde de la base vers le stockage objet, restauration testée | A.8.13 | `backup-cronjob.yaml`, `scripts/test-backup.sh` |
| Configuration versionnée (Terraform, Kustomize) | A.8.9 | `terraform/`, `k8s/` |
| Séparation dev / prod en namespaces avec quotas | A.8.31 | `terraform/platform/main.tf`, `k8s/overlays/` |
| Accès au code source : branche protégée, CODEOWNERS | A.8.4 | `.github/CODEOWNERS` |
| Sécurité dans le pipeline : tests, bandit, Trivy | A.8.25, A.8.28, A.8.7 | `ci-cd.yml`, `scripts/trivy-scan.sh` |

---

## 12. État de validation et limites connues (à lire avant de lancer)

**Ce que j'ai réellement exécuté** (dans mon environnement, sans Docker ni Kubernetes) :
- 8 tests back-end et 3 tests worker : OK. Le lint `ruff` est propre.
- Le script `api_client.py` (smoke test) a été exécuté contre l'API réelle avec un faux S3 et un faux worker : OK.
- Syntaxe validée : tous les YAML (34 documents), le workflow, `bash -n` sur tous les scripts, `node --check` sur le JS du front.

**Ce que je n'ai PAS pu exécuter** : `docker build`, `docker compose`, `kustomize/kubectl`, `terraform`, `helm`. Ces parties sont écrites mais **jamais lancées**. Si une étape échoue, copie-moi le message d'erreur et je corrige. Les points les plus susceptibles de demander un ajustement :
- **Terraform** : versions des providers et des charts Helm (`ingress-nginx 4.11.3`, `metrics-server 3.12.2`, `kube-prometheus-stack 61.9.0`, `loki-stack 2.10.2`). Si un chart est introuvable, change la version dans `terraform/platform/main.tf`.
- **MinIO** : l'image est en `latest` (pas de version épinglée). Le chiffrement SSE dépend de `MINIO_KMS_SECRET_KEY`. S'il échoue, l'application continue de fonctionner : seul un avertissement est journalisé.
- **NetworkPolicy** : déclarées et valides, mais le CNI par défaut de kind **n'applique pas toujours** ces règles. Tu peux donc les présenter comme « définies » sans prétendre les avoir testées en blocage réel.
- **Chiffrement au repos du disque** : en local, les volumes (PostgreSQL) ne sont pas chiffrés par la plateforme. Seul le stockage objet est chiffré. Dans le rapport, indique que sur un cloud managé, le chiffrement des disques est une option d'infrastructure.
- **Moindre privilège MinIO** : l'application utilise les identifiants root de MinIO, par simplicité. Un utilisateur dédié avec une politique restreinte serait l'amélioration naturelle.
- **Connexions** : pas de limitation de débit sur `/auth/login`. Les tentatives échouées sont journalisées, mais pas bloquées.

---

## 13. Dépannage rapide

| Symptôme | Piste |
|---|---|
| `compose-up` : un service reste `unhealthy` | `docker compose logs <service>`. Souvent un `.env` incomplet : supprime-le et relance `compose-env`. |
| `ImagePullBackOff` sur `localhost:5001/...` | Le registre n'est pas dans le réseau `kind` : `docker ps` doit montrer `kind-registry`. Relance `terraform apply` dans `terraform/cluster`, puis `./launch.sh build`. |
| Pods `Pending` avec une erreur de quota | `kubectl -n helpdesk-dev describe resourcequota`. Augmente les quotas dans `terraform/platform/variables.tf`, ou lance `kubectl -n helpdesk-dev scale deploy --all --replicas=1`. |
| `kubectl top` échoue | metrics-server n'est pas prêt : `kubectl -n kube-system get pods`. |
| `t-hpa` ne scale pas | Attends 1 à 2 min, ou augmente la charge en relançant le script. Vérifie que `kubectl top pods` renvoie des valeurs. |
| Le front affiche « Not Found » pour `/api` | Le backend n'est pas prêt : `kubectl -n helpdesk-dev logs deploy/backend`. |
| Pas assez de RAM | `ENABLE_MONITORING=false ./launch.sh infra-up`, et ne déploie que `dev`. |

---

## 14. Nettoyage

```bash
./launch.sh compose-down -v     # stack compose + volumes
./launch.sh infra-down          # cluster, registre, supervision (terraform destroy)
```
