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
stsName=$(kubectl $nsopt get sts -l "$helmSelectors" --template '{{range .items}}{{.metadata.name}} {{end}}')
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
sts="$(kubectl $nsopt get sts $stsName -o json)"

# parse pgversion
pgVersion="$(echo "$sts" | jq -r '.spec.template.spec.containers[0].env[] | select(.name == "PG_VERSION") | .value')"
echo "# Detected pgversion is $pgVersion"
pp="$(echo "$pp" | jq -c ".spec.version = $pgVersion")"

# read pvcNames
pvcNames=$(kubectl $nsopt get pvc -l "$helmSelectors" --template '{{range .items}}{{.metadata.name}} {{end}}')
if [ $(echo $pvcNames | wc -w) -eq 0 ]; then
	log "[-] No PVCs found for deployment"
	exit 5
fi

# Collect pvcSize and storageclasses
storageClasses=$(kubectl $nsopt get pvc -l "$helmSelectors" --template '{{range .items}}{{.metadata.name}} {{.spec.storageClassName}}{{"\n"}}{{end}}' | sort -n | awk '{print $2}')
pvcSizes="$(kubectl $nsopt get pvc -l "$helmSelectors" --template '{{range .items}}{{.spec.resources.requests.storage}}{{"\n"}}{{end}}')"
if [ $(echo "$pvcSizes" | sort | uniq | wc -w) -ne 1 ]; then
	log "[-] Invalid pvc sizes found: $pvcSizes"
	exit 6
fi
pvcSize=$(echo "$pvcSizes" | head -1)

pp="$(echo "$pp" | jq -c --arg pvcSize $pvcSize '.spec += {"volumeSize":$pvcSize,"volumes":[]}')"
for sc in $storageClasses ; do
	pp="$(echo "$pp" | jq -c --arg sc $sc '.spec.volumes += [{"storageClassName":$sc}]')"
done

# parse annotations
annotations="$(echo "$sts" | jq -c '.spec.template.metadata.annotations')"
if [ "$annotations" != "null" ]; then
	pp="$(echo "$pp" | jq -c ".spec += {\"annotations\":$annotations}")"
fi

# parse container[0] resources
resources="$(echo "$sts" | jq -c '.spec.template.spec.containers[0].resources')"
if [ "$resources" != "null" ]; then
	pp="$(echo "$pp" | jq -c ".spec += {\"resources\":$resources}")"
fi

# Parse podAntiAffinityTopologyKey
podAntiAffinityTopologyKey="$(echo "$sts" | jq -r '.spec.template.spec.affinity.podAntiAffinity.requiredDuringSchedulingIgnoredDuringExecution[0].topologyKey')"
if [ "$podAntiAffinityTopologyKey" = "null" ]; then
	podAntiAffinityTopologyKey=""
fi
pp="$(echo "$pp" | jq -c --arg podAntiAffinityTopologyKey "$podAntiAffinityTopologyKey" '.spec += {"podAntiAffinityTopologyKey":$podAntiAffinityTopologyKey}')"

# parse nodeSelector
nodeSelector="$(echo "$sts" | jq '.spec.template.spec.nodeSelector')"
if [ "$nodeSelector" != "null" ]; then
	pp="$(echo "$pp" | jq -c ".spec += {\"nodeSelector\":$nodeSelector}")"
fi

# parse tolerations
tolerations="$(echo "$sts" | jq '.spec.template.spec.tolerations')"
if [ "$tolerations" != "null" ]; then
	pp="$(echo "$pp" | jq -c ".spec += {\"tolerations\":$tolerations}")"
fi

# parse extracontainer
extracontainer="$(echo "$sts" | jq -c ".spec.template.spec.containers[1]")"
if [ "$extracontainer" != "null" ]; then
	pp="$(echo "$pp" | jq -c ".spec += {\"extraContainers\":[$extracontainer]}")"
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

echo "# This will create PatroniPostgres instance"
echo " echo '$pp' | kubectl $nsopt apply -f -"
echo ""

#    app.kubernetes.io/instance: pp-patroni-postgres
#    app.kubernetes.io/managed-by: kwebs-patroni-postgres-operator
#    app.kubernetes.io/name: patroni-postgres
#    cluster-name: pp-patroni-postgres
#    role: master

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
