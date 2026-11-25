#!/usr/bin/env bash
# Sauvegarde PostgreSQL -> stockage objet, vérification du chiffrement, test de restauration. Usage : test-backup.sh [env=dev]
. "$(dirname "$0")/lib.sh"; need kubectl
ENVN="${1:-dev}"; NS="$(ns_for "$ENVN")"; OUT="$ROOT/results/backup-$ENVN.txt"
{
J="backup-manual-$(date +%H%M%S)"
log "lancement d'une sauvegarde immédiate ($J)"
kubectl -n "$NS" create job --from=cronjob/db-backup "$J"
kubectl -n "$NS" wait --for=condition=complete "job/$J" --timeout=240s || { kubectl -n "$NS" logs "job/$J" --all-containers; die "backup échoué"; }
log "objets présents dans le bucket (et chiffrement SSE)"
kubectl -n "$NS" exec deploy/backend -- python -c "
from app.storage import get_storage
s=get_storage(); r=s.client.list_objects_v2(Bucket=s.bucket,Prefix='backups/').get('Contents',[])
for o in r:
    h=s.client.head_object(Bucket=s.bucket,Key=o['Key']); print(o['Key'], o['Size'],'octets', 'SSE=',h.get('ServerSideEncryption'))
assert r, 'aucune sauvegarde'"
log "test de restauration dans une base temporaire helpdesk_restore"
KEY="$(kubectl -n "$NS" exec deploy/backend -- python -c "
from app.storage import get_storage
s=get_storage(); r=sorted(s.client.list_objects_v2(Bucket=s.bucket,Prefix='backups/')['Contents'],key=lambda o:o['LastModified']); print(r[-1]['Key'])")"
kubectl -n "$NS" exec postgres-0 -- psql -U helpdesk -d postgres -c "DROP DATABASE IF EXISTS helpdesk_restore" -c "CREATE DATABASE helpdesk_restore"
kubectl -n "$NS" exec deploy/backend -- python -c "
import sys
from app.storage import get_storage
s=get_storage()
for c in s.stream('$KEY'): sys.stdout.buffer.write(c)" | gunzip | kubectl -n "$NS" exec -i postgres-0 -- psql -q -U helpdesk -d helpdesk_restore >/dev/null
kubectl -n "$NS" exec postgres-0 -- psql -U helpdesk -d helpdesk_restore -c "SELECT count(*) AS tickets_restaures FROM tickets"
kubectl -n "$NS" exec postgres-0 -- psql -U helpdesk -d postgres -c "DROP DATABASE helpdesk_restore"
} 2>&1 | tee "$OUT"
ok "résultats : $OUT"
