#!/usr/bin/env bash
# Installs the LVMS operator and an LVMCluster on the node's extra EBS disk, so
# the cluster has dynamic storage that needs no cloud identity (the AWS EBS CSI
# driver cannot work here -- credential wall, see docs/scp-blockers.md rows 8/9),
# then makes lvms-vg1 the cluster's one default StorageClass.
#
# Idempotent: every step is an `oc apply`/patch/annotate and the waits return
# at once when the thing is already ready. Safe to re-run on a live cluster.
#
# THE DEFAULT-CLASS PROBLEM (why the last section exists; docs/storage.md has
# the full story). Two controllers fight over the default flag:
#   - cluster-storage-operator re-adds is-default-class=true to gp3-csi within
#     seconds of anyone removing it. Confirmed: de-annotating by hand did not hold.
#   - LVMS refuses to mark lvms-vg1 default while another default exists, and
#     resets its annotation to "false" (confirmed the same way).
#   A PVC with no class then binds to gp3-csi, whose driver has no AWS credential,
#   and sits Pending forever -- and the registry and RHOAI both create such PVCs.
# `ClusterCSIDriver.spec.storageClassState: Unmanaged` is the supported lever:
# the CSI operator stops reconciling StorageClasses it already created.
# NOT `spec.managementState: Removed` -- that was tried and the operator refuses
# it ("Removed is not supported for AWSEBSCSIDriver operator") and adds a second
# Degraded condition on top of the existing one.
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

usage() {
  echo "usage: install-lvms.sh -a <account-alias> [--dry-run]" >&2
  echo "  --dry-run  server-side dry run of the manifests; changes nothing" >&2
  exit 1
}

account_alias=""
dry_run=false
while [ $# -gt 0 ]; do
  case "$1" in
    -a)
      account_alias="${2:-}"
      shift 2
      ;;
    --dry-run)
      dry_run=true
      shift
      ;;
    *) usage ;;
  esac
done
[ -n "$account_alias" ] || usage

kubeconfig="$repo_root/.ignition/${account_alias}/auth/kubeconfig"
[ -f "$kubeconfig" ] || {
  echo "ERROR: $kubeconfig not found." >&2
  exit 1
}
command -v oc >/dev/null 2>&1 || {
  echo "ERROR: oc not found on PATH." >&2
  exit 1
}
export KUBECONFIG="$kubeconfig"

oc whoami >/dev/null 2>&1 || {
  echo "ERROR: cannot reach the cluster. Is scripts/tunnel.sh -a $account_alias --api running?" >&2
  exit 1
}
echo "Cluster: $(oc whoami --show-server)" >&2

m="$repo_root/manifests/lvms"
ns=openshift-storage
default_ann='storageclass.kubernetes.io/is-default-class'

# A server-side dry run does not persist anything, so objects that live inside a
# namespace that does not exist yet fail with "namespace not found". That is a
# property of dry runs, not a problem with the manifests (hit for real). So:
# dry-run everything when the namespace already exists, otherwise just the
# namespace. The LVMCluster CRD only exists after the operator is installed, so
# 03-lvmcluster.yaml is never dry-run here; it is validated for real later.
if $dry_run; then
  if oc get ns "$ns" >/dev/null 2>&1; then
    oc apply --dry-run=server -f "$m/00-namespace.yaml" -f "$m/01-operatorgroup.yaml" -f "$m/02-subscription.yaml" || exit 1
  else
    oc apply --dry-run=server -f "$m/00-namespace.yaml" || exit 1
    echo "namespace $ns does not exist yet, so OperatorGroup/Subscription could not be dry-run" >&2
  fi
  echo "dry run OK" >&2
  exit 0
fi

# wait_for <seconds> <description> <command...>: poll until the command succeeds.
wait_for() {
  local limit="$1" what="$2" start now
  shift 2
  start=$(date +%s)
  until "$@" >/dev/null 2>&1; do
    now=$(date +%s)
    if [ $((now - start)) -ge "$limit" ]; then
      echo "ERROR: timed out after ${limit}s waiting for: $what" >&2
      return 1
    fi
    sleep 5
  done
  echo "ok: $what" >&2
}

csv_succeeded() {
  oc get csv -n "$ns" --no-headers 2>/dev/null | grep -q 'lvms-operator.*Succeeded'
}

lvmcluster_ready() {
  [ "$(oc get lvmcluster lvmcluster -n "$ns" -o jsonpath='{.status.state}' 2>/dev/null)" = "Ready" ]
}

sc_default() { # prints true/false/"" for a StorageClass's default annotation
  oc get sc "$1" -o jsonpath="{.metadata.annotations.storageclass\\.kubernetes\\.io/is-default-class}" 2>/dev/null
}

echo "Installing the LVMS operator..." >&2
oc apply -f "$m/00-namespace.yaml" || exit 1
oc apply -f "$m/01-operatorgroup.yaml" -f "$m/02-subscription.yaml" || exit 1
wait_for 600 "lvms-operator CSV Succeeded" csv_succeeded || {
  oc get subscription,installplan,csv -n "$ns" >&2
  exit 1
}
wait_for 120 "LVMCluster CRD registered" oc get crd lvmclusters.lvm.topolvm.io || exit 1

echo "Creating the LVMCluster..." >&2
oc apply -f "$m/03-lvmcluster.yaml" || exit 1
wait_for 600 "LVMCluster Ready" lvmcluster_ready || {
  oc get lvmcluster lvmcluster -n "$ns" -o yaml | tail -40 >&2
  exit 1
}
wait_for 120 "StorageClass lvms-vg1 exists" oc get sc lvms-vg1 || exit 1

echo "Devices LVMS claimed:" >&2
oc get lvmcluster lvmcluster -n "$ns" \
  -o jsonpath='{range .status.deviceClassStatuses[*]}{.name}{": "}{range .nodeStatus[*]}{.node}{" -> "}{.devices}{"\n"}{end}{end}' >&2

echo "Making lvms-vg1 the only default StorageClass..." >&2
# 1. Stop the CSI operator re-adding its own default (see header).
oc patch clustercsidriver ebs.csi.aws.com --type=merge -p '{"spec":{"storageClassState":"Unmanaged"}}' || exit 1
# 2. Clear the default flag on the EBS classes -- they can never provision here.
for sc in gp3-csi gp2-csi; do
  if oc get sc "$sc" >/dev/null 2>&1; then
    oc annotate sc "$sc" "$default_ann=false" --overwrite >/dev/null || exit 1
  fi
done
# 3. Now nothing else is default, so lvms-vg1 can be.
oc annotate sc lvms-vg1 "$default_ann=true" --overwrite >/dev/null || exit 1

# Read it back after a pause long enough for either controller to undo it,
# rather than trusting the patch's exit code (the first attempt "succeeded" and
# was reverted seconds later).
sleep 30
defaults=$(oc get sc -o jsonpath="{range .items[?(@.metadata.annotations.storageclass\\.kubernetes\\.io/is-default-class==\"true\")]}{.metadata.name}{\"\\n\"}{end}")
if [ "$defaults" != "lvms-vg1" ]; then
  echo "ERROR: default StorageClass is not exactly lvms-vg1 after 30s: '${defaults:-none}'" >&2
  oc get sc >&2
  exit 1
fi
echo "ok: lvms-vg1 is the only default StorageClass (held for 30s)" >&2

echo >&2
oc get sc
