#!/usr/bin/env bash
# Confirms the two operators this platform expects to stay broken forever
# (storage Degraded, network Progressing) are broken for the EXPECTED reason
# -- not just that they're broken -- and that image-registry, which
# day2/setup-registry.sh fixes, is Available. Both inert ones trace to the
# same missing cloud credential (docs/storage.md). A UPI install has no
# Machine objects, so the source repo's control-plane-machine-set check does
# not apply here. A genuinely new failure
# can hide behind "oh, that's the known one" if nobody actually reads the
# condition message -- this is meant to be run whenever something looks off,
# not just once after install.
set -uo pipefail # NOT -e: a mismatch here is a real finding to report, not
                 # a reason to abort before checking the other two.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

usage() {
  echo "usage: check-known-inert.sh -a <account-alias>" >&2
  exit 1
}

account_alias=""
while [ $# -gt 0 ]; do
  case "$1" in
    -a)
      account_alias="$2"
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

oc_cmd() { oc --kubeconfig "$kubeconfig" "$@"; }

storage_msg=$(oc_cmd get co storage -o jsonpath='{.status.conditions[?(@.type=="Degraded")].message}' 2>/dev/null || echo "")
network_msg=$(oc_cmd get co network -o jsonpath='{.status.conditions[?(@.type=="Progressing")].message}' 2>/dev/null || echo "")
registry_avail=$(oc_cmd get co image-registry -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "")

echo "storage Degraded:                 $storage_msg"
echo "network Progressing:              $network_msg"
echo "image-registry Available:         $registry_avail"

# The EBS CSI driver's controller deployment can never start without a cloud
# credential; the network operator waits on cloud-network-config-controller
# for the same reason. These are the messages seen on a live 4.22.9 cluster.
any_unexpected=false
case "$storage_msg" in *AWSEBSDriverControllerService*) ;; *) any_unexpected=true ;; esac
case "$network_msg" in *cloud-network-config-controller*) ;; *) any_unexpected=true ;; esac
[ "$registry_avail" = "True" ] || any_unexpected=true

if [ "$any_unexpected" = "true" ]; then
  echo
  echo "WARNING: at least one condition message doesn't match the credential-wall" >&2
  echo "explanation this project has relied on -- read it above rather than assuming" >&2
  echo "known-inert. See docs/runbook.md's 'Known-inert, do not chase' list." >&2
  exit 1
fi

echo
echo "OK: storage and network are broken for the expected reason; image-registry is Available."
