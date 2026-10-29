#!/usr/bin/env bash
# Gives the internal image registry a PVC on LVMS instead of its native S3
# backend. No pod here can hold an AWS credential (docs/storage.md), so the
# S3 default can never work; without this the image-registry clusteroperator
# stays Unavailable forever.
#
# Two things differ from a "normal" PVC-backed registry:
#   - lvms-vg1 binds WaitForFirstConsumer, so the PVC stays Pending until the
#     registry pod exists. Do NOT wait for Bound before patching the operator
#     config -- the pod that makes it bind only appears after the patch.
#   - `pvc.claim` must be set in the SAME merge patch that nulls `s3`. On AWS
#     the operator's defaulter re-adds s3 if storage is left empty, and then
#     loops on "unable to get cluster minted credentials".
# RWO volume => replicas 1 and rolloutStrategy Recreate.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

usage() {
  echo "usage: setup-registry.sh -a <account-alias>" >&2
  exit 1
}

account_alias=""
while [ $# -gt 0 ]; do
  case "$1" in
    -a)
      account_alias="${2:-}"
      shift 2
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

oc get sc lvms-vg1 >/dev/null 2>&1 || {
  echo "ERROR: StorageClass lvms-vg1 not found (or API unreachable) -- run day2/install-lvms.sh first." >&2
  exit 1
}

echo "Applying registry PVC..." >&2
oc apply -f "$repo_root/manifests/registry/registry-pvc.yaml"

echo "Pointing the registry at the PVC (s3 nulled in the same patch)..." >&2
oc patch configs.imageregistry.operator.openshift.io/cluster --type=merge \
  -p '{"spec":{"managementState":"Managed","replicas":1,"rolloutStrategy":"Recreate","storage":{"s3":null,"pvc":{"claim":"image-registry-storage"}}}}'

echo "Waiting for image-registry to become Available (up to 5 min)..." >&2
available="Unknown"
for _ in $(seq 1 30); do
  available=$(oc get co image-registry -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "Unknown")
  [ "$available" = "True" ] && break
  sleep 10
done

oc get pvc -n openshift-image-registry
oc get co image-registry
oc get pods -n openshift-image-registry

if [ "$available" != "True" ]; then
  echo "ERROR: image-registry not Available after 5 minutes -- inspect the output above." >&2
  exit 1
fi
echo "ok: image-registry Available, backed by PVC image-registry-storage on lvms-vg1" >&2
