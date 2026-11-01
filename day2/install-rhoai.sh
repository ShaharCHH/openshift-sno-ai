#!/usr/bin/env bash
# Installs the Red Hat OpenShift AI operator (channel stable-3.x) and waits for
# its CSV to succeed. The DataScienceCluster is a separate step (manifests/rhoai/
# 10-datasciencecluster.yaml, applied once the operator's CRDs exist).
#
# Idempotent: every step is an `oc apply` and the waits return at once when the
# thing is already ready. Safe to re-run on a live cluster.
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

usage() {
  echo "usage: install-rhoai.sh -a <account-alias> [--dry-run]" >&2
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

m="$repo_root/manifests/rhoai"
ns=redhat-ods-operator

# Same dry-run limitation as install-lvms.sh: namespaced objects cannot be
# dry-run until their namespace really exists.
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
  oc get csv -n "$ns" --no-headers 2>/dev/null | grep -q 'rhods-operator.*Succeeded'
}

echo "Installing the RHOAI operator (stable-3.x)..." >&2
oc apply -f "$m/00-namespace.yaml" || exit 1
oc apply -f "$m/01-operatorgroup.yaml" -f "$m/02-subscription.yaml" || exit 1
wait_for 900 "rhods-operator CSV Succeeded" csv_succeeded || {
  oc get subscription,installplan,csv -n "$ns" >&2
  exit 1
}
wait_for 120 "DataScienceCluster CRD registered" oc get crd datascienceclusters.datasciencecluster.opendatahub.io || exit 1

echo >&2
oc get csv -n "$ns"
