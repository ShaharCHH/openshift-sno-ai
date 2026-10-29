#!/usr/bin/env bash
# Read-only post-install check for single-node OpenShift. Reports whether the
# cluster is in the end state this platform expects, and changes nothing.
#
# Ported from the UPI source repo's cleanup script, which MUTATED things
# (patched the storage operator, tried ClusterCSIDriver managementState
# Removed, deleted StorageClasses). On SNO those levers are already settled,
# so this script only verifies them -- docs/storage.md has the evidence:
#   - ClusterCSIDriver managementState Removed is REFUSED by the operator;
#     `storageClassState: Unmanaged` (set by day2/install-lvms.sh) is the
#     supported lever. This script checks it is still in place.
#   - lvms-vg1 must be the sole default StorageClass.
#   - image-registry must be Available (day2/setup-registry.sh).
#   - storage and network are expected to stay broken, for the credential
#     reason -- scripts/check-known-inert.sh confirms the reason, not just
#     the symptom.
set -uo pipefail # NOT -e: every check runs and is reported, then the exit code
                 # says whether any failed.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

usage() {
  echo "usage: post-install-cleanup.sh -a <account-alias>" >&2
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

failed=0
check() { # check <description> <expected> <actual>
  if [ "$2" = "$3" ]; then
    echo "ok:   $1 = $3" >&2
  else
    echo "FAIL: $1: expected '$2', got '$3'" >&2
    failed=1
  fi
}

# A dead tunnel makes every oc call return empty, which would otherwise read
# as a pile of mismatches (or worse, as "nothing wrong").
oc get nodes >/dev/null 2>&1 || {
  echo "ERROR: cannot reach the API -- is the tunnel up?" >&2
  exit 1
}

check "ClusterCSIDriver storageClassState" "Unmanaged" \
  "$(oc get clustercsidriver ebs.csi.aws.com -o jsonpath='{.spec.storageClassState}' 2>/dev/null)"
check "ClusterCSIDriver managementState" "Managed" \
  "$(oc get clustercsidriver ebs.csi.aws.com -o jsonpath='{.spec.managementState}' 2>/dev/null)"
check "default StorageClass" "lvms-vg1" \
  "$(oc get sc -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}' 2>/dev/null)"
check "image-registry Available" "True" \
  "$(oc get co image-registry -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null)"
check "image-registry PVC" "Bound" \
  "$(oc get pvc image-registry-storage -n openshift-image-registry -o jsonpath='{.status.phase}' 2>/dev/null)"

echo >&2
"$repo_root/scripts/check-known-inert.sh" -a "$account_alias" || failed=1

[ "$failed" = 0 ] || {
  echo >&2
  echo "One or more checks failed -- see above." >&2
  exit 1
}
echo >&2
echo "ok: cluster is in the expected end state" >&2
