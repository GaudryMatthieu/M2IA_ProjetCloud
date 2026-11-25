#!/usr/bin/env bash
# FinOps : (1) coût estimé à partir des requests réels, (2) mesure de l'effet des optimisations.
#   finops.sh snapshot <label>   -> requests/limits/usage réel par namespace + coût estimé  (results/finops-<label>.txt)
#   finops.sh images             -> compare une image "naïve" et l'image multi-stage (taille)
# Tarifs : à renseigner d'après la grille du cloud de référence (variables d'environnement) :
#   PRICE_VCPU_HOUR (€ par vCPU-heure)  PRICE_GB_HOUR (€ par Go-heure de RAM)
. "$(dirname "$0")/lib.sh"
case "${1:-}" in
snapshot)
  need kubectl; LABEL="${2:?label}"; OUT="$ROOT/results/finops-$LABEL.txt"
  PV="${PRICE_VCPU_HOUR:-0}"; PG="${PRICE_GB_HOUR:-0}"
  for ns in helpdesk-dev helpdesk-prod; do kubectl get ns $ns >/dev/null 2>&1 || continue
    kubectl -n $ns get pods -o json | python3 -c "
import json,sys,re
def cpu(v): return float(v[:-1])/1000 if v.endswith('m') else float(v)
def mem(v):
    m=re.match(r'(\d+)(Ki|Mi|Gi)?',v); n=int(m[1]); return n*{None:1,'Ki':1024,'Mi':1024**2,'Gi':1024**3}[m[2]]/1024**3
c=m=0;n=0
for p in json.load(sys.stdin)['items']:
    if p['status']['phase']!='Running': continue
    n+=1
    for k in p['spec']['containers']:
        r=k.get('resources',{}).get('requests',{}); c+=cpu(r.get('cpu','0')); m+=mem(r.get('memory','0'))
pv,pg=$PV,$PG
print(f'$ns pods={n} requests: {c:.2f} vCPU, {m:.2f} Go RAM | coût/heure={c*pv+m*pg:.4f} € | coût/mois(730h)={(c*pv+m*pg)*730:.2f} €')"
    kubectl top pods -n $ns 2>/dev/null || true
  done | tee "$OUT"
  [ "$PV" = 0 ] && warn "PRICE_VCPU_HOUR / PRICE_GB_HOUR non définis : coûts à 0 (renseignez la grille tarifaire du cloud choisi)"
  ok "snapshot : $OUT" ;;
images)
  need docker; OUT="$ROOT/results/finops-images.txt"
  cd "$ROOT/app/backend"
  docker build -q -f Dockerfile.naive -t helpdesk-backend:naive . >/dev/null
  docker build -q -t helpdesk-backend:multistage . >/dev/null
  { echo "Taille des images backend :"; docker images --format '  {{.Repository}}:{{.Tag}}  {{.Size}}' | grep -E 'helpdesk-backend:(naive|multistage)'; } | tee "$OUT" ;;
*) echo "usage: finops.sh snapshot <label> | images"; exit 1 ;;
esac
