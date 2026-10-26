#!/usr/bin/env bash
# Proves LVMS storage works the way real workloads use it: a PVC that names NO
# StorageClass binds on the default class, a pod mounts it, writes a file and
# reads it back. Cleans up after itself. Exits non-zero on any FAIL.
#
# The PVC deliberately names no class. A test that names lvms-vg1 would pass
# even with gp3-csi still the default -- and it is exactly the class-less PVC
# that the image registry and RHOAI create (see docs/storage.md).
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

usage() {
  echo "usage: verify-lvms.sh -a <account-alias>" >&2
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
export KUBECONFIG="$kubeconfig"

ns=lvms-verify
fail=0
pass() { echo "PASS  $1"; }
bad() {
  echo "FAIL  $1" >&2
  fail=1
}

defaults=$(oc get sc -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}')
if [ "$defaults" = "lvms-vg1" ]; then
  pass "lvms-vg1 is the only default StorageClass"
else
  bad "default StorageClass(es): ${defaults:-none}"
fi

oc delete ns "$ns" --ignore-not-found --wait=true >/dev/null 2>&1
oc create ns "$ns" >/dev/null || exit 1
# shellcheck disable=SC2329 # invoked via the EXIT trap below
cleanup() { oc delete ns "$ns" --ignore-not-found --wait=false >/dev/null 2>&1; }
trap cleanup EXIT

# The pod's securityContext satisfies the "restricted" Pod Security level, which
# is what ordinary namespaces enforce here (an unrestricted pod only warns).
oc apply -n "$ns" -f - >/dev/null <<'YAML'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: probe
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: probe
spec:
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: probe
      image: registry.access.redhat.com/ubi9/ubi-minimal
      command: ["sh", "-c", "echo lvms-ok > /data/probe && cat /data/probe"]
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          drop: [ALL]
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: probe
YAML

# WaitForFirstConsumer: the PVC only binds once the pod is scheduled.
if oc wait -n "$ns" --for=jsonpath='{.status.phase}'=Succeeded pod/probe --timeout=300s >/dev/null 2>&1; then
  pass "pod ran to completion"
else
  bad "pod did not complete (phase: $(oc get pod probe -n "$ns" -o jsonpath='{.status.phase}' 2>&1))"
  oc describe pod probe -n "$ns" 2>&1 | tail -15 >&2
fi

pvc_class=$(oc get pvc probe -n "$ns" -o jsonpath='{.spec.storageClassName}' 2>&1)
if [ "$pvc_class" = "lvms-vg1" ]; then
  pass "class-less PVC was given lvms-vg1"
else
  bad "class-less PVC got '$pvc_class'"
fi

if [ "$(oc get pvc probe -n "$ns" -o jsonpath='{.status.phase}' 2>/dev/null)" = "Bound" ]; then
  pass "PVC Bound"
else
  bad "PVC not Bound"
fi

if [ "$(oc logs -n "$ns" probe 2>/dev/null)" = "lvms-ok" ]; then
  pass "wrote and read back a file on the volume"
else
  bad "file round-trip failed"
fi

exit $fail
