#!/usr/bin/env bash
# Reconcile CMP portal records (cube-portal MongoDB) left behind when the worker /
# NATS was down: rows stuck at status "requesting", or instance rows with no
# instance_id. Each row is checked against the project's VMs on CubeCOS:
#
#   instance  VM exists   -> fill instance_id / vm_state / power_state / cidr, status ""
#             VM missing  -> delete the row
#   app       VM missing  -> delete the row
#   cluster   no node VM  -> delete the row
#   app / cluster that DO exist are only reported: their rows also need floating-ip,
#   port and Rancher clusterId objects this script can't rebuild safely.
#
# Every change asks y/N first, and the row is saved to a local backup file before
# it is touched.
#
# Usage:
#   COS_IP=10.231.0.100 CMP=app-framework.yaml PROJ=GOV111027 bash portal-reconcile.sh
# Optional env:
#   NS=cube-portal             namespace of cube-portal-mongodb
#   OPENRC=/etc/admin-openrc.sh
#   MIN_AGE_MIN=30             ignore rows younger than this (may still be in flight)
#   KUBECTL_OPTS=--insecure-skip-tls-verify
# Requires locally: kubectl, jq, ssh with root key access to COS_IP.
set -Eeuo pipefail

: "${COS_IP:?set COS_IP}" "${CMP:?set CMP to the CMP kubeconfig}" "${PROJ:?set PROJ}"
[[ $PROJ =~ ^[A-Za-z0-9_.-]+$ ]] || { echo "bad PROJ: $PROJ" >&2; exit 1; }
NS=${NS:-cube-portal}
OPENRC=${OPENRC:-/etc/admin-openrc.sh}
MIN_AGE_MIN=${MIN_AGE_MIN:-30}
read -ra KOPTS <<<"${KUBECTL_OPTS:-}"
BACKUP=portal-reconcile-$PROJ-$(date +%Y%m%d-%H%M%S).ejson

k() { kubectl --kubeconfig "$CMP" ${KOPTS[@]+"${KOPTS[@]}"} -n "$NS" "$@"; }
# no -i / -n: kubectl exec and ssh must not eat the y/N answers on stdin
cos() { ssh -n -o BatchMode=yes "root@$COS_IP" "source $OPENRC >/dev/null && $1"; }
# JS goes in as argv, so neither shell re-quotes it
mongo_on() {
    k exec "$1" -c mongodb -- bash -c \
        'mongosh --quiet -u root -p "$MONGODB_ROOT_PASSWORD" --authenticationDatabase admin "mongodb://localhost:27017/portal?directConnection=true" --eval "$0"' "$2"
}
js() { jq -Rn --arg s "$1" '$s'; }   # shell value -> JS string literal

PRIMARY=
for p in $(k get pod -l app.kubernetes.io/name=mongodb -o jsonpath='{.items[*].metadata.name}'); do
    [ "$(mongo_on "$p" 'print(db.hello().isWritablePrimary)' 2>/dev/null)" = true ] && { PRIMARY=$p; break; }
done
[ -n "$PRIMARY" ] || { echo "no writable mongodb primary in namespace $NS" >&2; exit 1; }
mongo() { mongo_on "$PRIMARY" "$1"; }
echo "mongo primary : $PRIMARY"

SERVERS=$(cos "openstack server list --project $PROJ -f json -c ID -c Name")
echo "COS servers   : $(jq length <<<"$SERVERS") in project $PROJ"

# one line per suspect row: coll|_id|status|name|match-key|cidr|created
CAND=$(mongo "
const P=$(js "$PROJ"), cut=Date.now()-$MIN_AGE_MIN*60000;
const old=d=>{ const t=typeof d.created_at==='number'?d.created_at:Date.parse(d.created_at||''); return isNaN(t)||t<cut; };
const out=(c,d,name,key,cidr)=>print([c,String(d._id),d.status,name,key,cidr||'',d.created_at||''].join('|'));
db.instances.find({project:P,\$or:[{status:'requesting'},{status:'',instance_id:{\$exists:false}}]})
  .forEach(d=>old(d)&&out('instances',d,d.name,d.name,(d.network||{}).cidr));
db.apps.find({project:P,status:'requesting'})
  .forEach(d=>old(d)&&out('apps',d,d.app.name,(d.app.instances||[]).map(i=>i.name).join(',')));
db.clusters.find({project:P,status:'requesting'})
  .forEach(d=>old(d)&&out('clusters',d,d.name,(d.clusterSpec||{}).rancherUniqName||[d.name,'default',P.toLowerCase(),String(d.id).slice(0,8)].join('-')));
")
[ -n "$CAND" ] || { echo "nothing stuck in $PROJ (older than ${MIN_AGE_MIN}m)"; exit 0; }

n_done=0 n_skip=0
while IFS='|' read -r coll id status name key cidr created <&3; do
    case $coll in
        instances) ids=$(jq -r --arg n "$key" '[.[]|select(.Name==$n)|.ID]|join(" ")' <<<"$SERVERS") ;;
        apps)      ids=$(jq -r --arg n "$key" '($n|split(",")) as $w|[.[]|select(.Name as $x|$w|any(.==$x))|.ID]|join(" ")' <<<"$SERVERS") ;;
        clusters)  ids=$(jq -r --arg n "$key" '[.[]|select(.Name|startswith($n))|.ID]|join(" ")' <<<"$SERVERS") ;;
    esac
    printf '\n[%s] %s  status=%s created=%s _id=%s\n' "$coll" "$name" "${status:-<empty>}" "$created" "$id"

    filter="{_id:ObjectId($(js "$id")),project:$(js "$PROJ"),status:$(js "$status")}"
    if [ -z "$ids" ]; then
        echo "  COS: not found -> DELETE record"
        op="db.$coll.deleteOne($filter).deletedCount"
    elif [ "$coll" != instances ]; then
        echo "  COS: exists ($ids) -> needs a manual fix, skipped"
        n_skip=$((n_skip+1)); continue
    elif [ "$(wc -w <<<"$ids")" -ne 1 ]; then
        echo "  COS: several VMs named $name ($ids) -> skipped"
        n_skip=$((n_skip+1)); continue
    else
        s=$(cos "openstack server show $ids -f json -c OS-EXT-STS:vm_state -c OS-EXT-STS:power_state -c OS-SRV-USG:launched_at -c addresses")
        set=$(jq -c --arg id "$ids" --arg cidr "$cidr" '
            (.addresses | if type=="object" then [.[][]] else [scan("[0-9]+(?:\\.[0-9]+){3}")] end | .[0] // "") as $ip
            | {status:"", instance_id:$id, vm_state:."OS-EXT-STS:vm_state", power_state:(."OS-EXT-STS:power_state"|tostring)}
              + (if $cidr != "" then {cidr:$cidr} else {} end)
              + (if $ip != "" then {interface_ip:$ip} else {} end)
              + (if ."OS-SRV-USG:launched_at" then {launched_at:."OS-SRV-USG:launched_at"} else {} end)' <<<"$s")
        echo "  COS: exists $ids -> UPDATE record with $set"
        op="db.instances.updateOne($filter,{\$set:$set}).modifiedCount"
    fi

    read -r -p "  apply? [y/N/q] " ans || ans=q
    case $ans in
        y|Y) ;;
        q|Q) echo "  quit"; break ;;
        *)   echo "  skipped"; n_skip=$((n_skip+1)); continue ;;
    esac
    mongo "print(EJSON.stringify(db.$coll.findOne({_id:ObjectId($(js "$id"))})))" >>"$BACKUP"
    if [ "$(mongo "print($op)")" = 1 ]; then
        echo "  done"; n_done=$((n_done+1))
    else
        echo "  NOT applied: record changed since the check (status moved?)"
    fi
done 3<<<"$CAND"

echo
echo "applied=$n_done skipped=$n_skip"
[ -s "$BACKUP" ] && echo "backup of changed records: $PWD/$BACKUP"
exit 0
