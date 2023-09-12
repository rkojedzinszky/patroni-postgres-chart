#!/bin/sh

# This script tries to convert a helm deployment to a postgrespatroni instance, operated
# by github.com/k-web-s/postgres-patroni-operator.
# Please double check the script, the outputs. I am not responsible for any loss it may make.
#
# Feel free to modify, update.

help()
{
	cat <<-EOF >&2

	Usage: $0 [-n namespace] <helm instance name>

	This script tries to convert a helm deployment to a postgrespatroni instance, operated
	by github.com/k-web-s/postgres-patroni-operator.
	Please double check the script, the outputs. I am not responsible for any loss it may make.

	It will just emit commands you should run. It is assumed that github.com/k-web-s/postgres-patroni-operator
	is installed and running.

	EOF

	exit 1
}

log()
{
	echo "$@" >&2
}

options="$(getopt -- "n:h" "$@")"
if [ $? -ne 0 ]; then
	help
fi

tmpdir=$(mktemp -d)
trap "rm -rf $tmpdir" EXIT
stsfile="$tmpdir/statefulset.json"
pvcs="$tmpdir/pvcs.txt"

eval set -- "$options"

if ! type kubectl jq > /dev/null 2>&1 ; then
	log "[-] kubectl/jq not found"
	exit 2
fi

nsopt=
while [ "$1" != "--" ]; do
	case "$1" in
		-n)
			nsopt="-n $2"
			shift
			;;
		-h)
			help
			;;
	esac
	shift
done
shift

if [ $# -ne 1 ]; then
	help
fi

# Lookup StatefulSet
log "[=] Looking up StatefulSet"
instance="$1"
helmSelectors="app.kubernetes.io/instance=$instance,app.kubernetes.io/managed-by=Helm,app.kubernetes.io/name=patroni-postgres"
stsName=$(kubectl $nsopt get sts -l "$helmSelectors" --template '{{range .items}}{{.metadata.name}}{{"\n"}}{{end}}')
case $(echo "$stsName" | wc -w) in
	0)
		log "[-] StatefulSet not found"
		exit 3
		;;
	1)
		log "[+] StatefulSet found with name $stsName"
		break
		;;
	*)
		log "[-] Multiple StatefulSets found"
		exit 4
		;;
esac
operatorLabels="app.kubernetes.io/instance=$stsName app.kubernetes.io/managed-by=kwebs-patroni-postgres-operator"

pp="$(echo '{}' | jq -c --arg stsName $stsName '. + {"apiVersion":"kwebs.cloud/v1alpha1","kind":"PatroniPostgres","metadata":{"name":$stsName},"spec":{"volumes":[]}}')"

# read statefulset
kubectl $nsopt get sts $stsName -o json > "$stsfile"

jqsts()
{
	local filter="$1"

	jq -c -r "$filter" "$stsfile"
}

# parse pgversion
pgVersion="$(jqsts '.spec.template.spec.containers[0].env[] | select(.name == "PG_VERSION") | .value')"
echo "# Detected pgversion is $pgVersion"
pp="$(echo "$pp" | jq -c ".spec.version = $pgVersion")"

# read pvcNames
pvcNames=$(kubectl $nsopt get pvc -l "$helmSelectors" --template '{{range .items}}{{.metadata.name}} {{end}}')
if [ $(echo $pvcNames | wc -w) -eq 0 ]; then
	log "[-] No PVCs found for deployment"
	exit 5
fi

# Collect pvcSize and storageclasses
pvcSizes="$(kubectl $nsopt get pvc -l "$helmSelectors" --template '{{range .items}}{{.spec.resources.requests.storage}}{{"\n"}}{{end}}')"
if [ $(echo "$pvcSizes" | sort | uniq | wc -w) -ne 1 ]; then
	log "[-] Invalid pvc sizes found: $pvcSizes"
	exit 6
fi
pvcSize=$(echo "$pvcSizes" | head -1)
pp="$(echo "$pp" | jq -c --arg pvcSize $pvcSize '.spec += {"volumeSize":$pvcSize,"volumes":[]}')"

# Collect storageclasses
kubectl $nsopt get pvc -l "$helmSelectors" --template '{{range .items}}{{.metadata.name}} {{.spec.storageClassName}} {{index .spec.accessModes 0}}{{"\n"}}{{end}}' | sort -n > "$pvcs"
while read name class mode ; do
	vol="{\"storageClassName\":\"$class\"}"
	if [ "$mode" != "ReadWriteOnce" ]; then
		vol=$(echo "$vol" | jq -c --arg mode $mode '. + {"accessMode":$mode}')
	fi
	pp="$(echo "$pp" | jq -c ".spec.volumes += [$vol]")"
done < "$pvcs"

# parse annotations
annotations="$(jqsts '.spec.template.metadata.annotations')"
if [ "$annotations" != "null" ]; then
	pp="$(echo "$pp" | jq -c ".spec += {\"annotations\":$annotations}")"
fi

# parse container[0] resources
resources="$(jqsts '.spec.template.spec.containers[0].resources')"
if [ "$resources" != "null" ]; then
	pp="$(echo "$pp" | jq -c ".spec += {\"resources\":$resources}")"
fi

# Parse podAntiAffinityTopologyKey
podAntiAffinityTopologyKey="$(jqsts '.spec.template.spec.affinity.podAntiAffinity.requiredDuringSchedulingIgnoredDuringExecution[0].topologyKey')"
if [ "$podAntiAffinityTopologyKey" = "null" ]; then
	podAntiAffinityTopologyKey=""
fi
pp="$(echo "$pp" | jq -c --arg podAntiAffinityTopologyKey "$podAntiAffinityTopologyKey" '.spec += {"podAntiAffinityTopologyKey":$podAntiAffinityTopologyKey}')"

# parse nodeSelector
nodeSelector="$(jqsts '.spec.template.spec.nodeSelector')"
if [ "$nodeSelector" != "null" ]; then
	pp="$(echo "$pp" | jq -c ".spec += {\"nodeSelector\":$nodeSelector}")"
fi

# parse tolerations
tolerations="$(jqsts '.spec.template.spec.tolerations')"
if [ "$tolerations" != "null" ]; then
	pp="$(echo "$pp" | jq -c ".spec += {\"tolerations\":$tolerations}")"
fi

# parse extracontainer
extracontainer="$(jqsts '.spec.template.spec.containers[1]')"
if [ "$extracontainer" != "null" ]; then
	pp="$(echo "$pp" | jq -c ".spec += {\"extraContainers\":[$extracontainer]}")"
fi

# parse servicetype
serviceName=$(kubectl get service -l $helmSelectors --template '{{range .items}}{{.metadata.name}}{{"\n"}}{{end}}' | sed -n -r -e '/-headless$/{ s/-headless$//; p }' | head -1)
if [ -n "$serviceName" ]; then
	serviceType=$(kubectl $nsopt get service $serviceName --template '{{.spec.type}}')
	if [ -n "$serviceType" ]; then
		pp="$(echo "$pp" | jq -c --arg serviceType $serviceType '.spec += {"serviceType":$serviceType}')"
	fi
fi

# services not being owned, and to be patched
orphanServices=$(kubectl $nsopt get service -l $helmSelectors --template '{{range .items}}{{.metadata.name}}{{"\n"}}{{end}}' | grep -vE "^$stsName(-headless)?$")

####
####
####

echo "# This will remove helm secrets"
echo " kubectl $nsopt delete secret -l name=$instance,owner=helm"
echo ""

echo "# This will relabel PVCs"
echo " kubectl $nsopt label --overwrite pvc $pvcNames $operatorLabels"
echo ""

echo "# This will delete existing StatefulSet"
echo " kubectl $nsopt delete sts $stsName"
echo ""

if [ -n "$orphanServices" ]; then
	echo "# The following services will be patched to work, howewer, they will be orphaned,"
	echo "# and you should migrate away from using them."
	echo $orphanServices | sed -e 's/^/# /'

	spatch="$(echo '[]' | jq -c --arg instance $stsName '. + [{"op":"replace","path":"/spec/selector","value":{"app.kubernetes.io/instance":$instance,"app.kubernetes.io/managed-by":"kwebs-patroni-postgres-operator","app.kubernetes.io/name":"patroni-postgres","cluster-name":$instance,"role":"master"}}]')"

	for s in $orphanServices; do
		echo " kubectl $nsopt patch --type=json service $s --patch '$spatch'"
	done

	echo ""
fi

echo "# This will finally create PatroniPostgres instance"
echo " echo '$pp' | kubectl $nsopt apply -f -"
echo ""
