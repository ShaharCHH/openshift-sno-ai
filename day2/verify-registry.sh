#!/usr/bin/env bash
# Proves the internal image registry can actually store and serve an image,
# not just that the clusteroperator reports Available=True: builds a tiny image
# in a throwaway project (push), runs it back from the registry (pull), and
# confirms the registry pod's /registry is a real volume (LVMS), not the
# container's ephemeral overlay.
#
# Creates and deletes a project named registry-verify-<epoch>; the delete runs
# on exit, including on failure.
#
# If the build fails with `InvalidOutputReference` / `Output image could not be
# resolved`, openshift-controller-manager is still holding the registry's old,
# empty internalRegistryHostname from before setup-registry.sh ran. This script
# restarts it once and retries.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

usage() {
  echo "usage: verify-registry.sh -a <account-alias>" >&2
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

# `oc new-project` switches the current context and writes that back into the
# kubeconfig it was given. Work on a throwaway copy so the admin kubeconfig
# keeps its single-context shape.
scratch_kubeconfig="$(mktemp)"
cp "$kubeconfig" "$scratch_kubeconfig"
export KUBECONFIG="$scratch_kubeconfig"

project="registry-verify-$(date +%s)"
build_dir=""

cleanup() {
  oc delete project "$project" --ignore-not-found >/dev/null 2>&1 || true
  [ -n "$build_dir" ] && rm -rf "$build_dir"
  rm -f "$scratch_kubeconfig"
}
trap cleanup EXIT

oc get nodes >/dev/null 2>&1 || {
  echo "ERROR: cannot reach the API -- is the tunnel up?" >&2
  exit 1
}

# Base image: the cluster's own `cli` imagestream, resolved to its pinned
# quay.io reference. Nodes already pull from there, so this does not depend on
# registry.access.redhat.com being reachable.
base_image=$(oc get imagestream cli -n openshift \
  -o jsonpath='{.status.tags[0].items[0].dockerImageReference}' 2>/dev/null || echo "")
[ -n "$base_image" ] || {
  echo "ERROR: could not resolve a base image from imagestream openshift/cli." >&2
  exit 1
}
echo "Base image: $base_image" >&2

build_dir="$(mktemp -d)"
cat >"$build_dir/Dockerfile" <<EOF
FROM ${base_image}
RUN echo "registry-verify-ok" > /test.txt
EOF

echo "Creating throwaway project $project..." >&2
oc new-project "$project" >/dev/null

echo "Starting build (binary, docker strategy)..." >&2
oc -n "$project" new-build --name=roundtrip --binary --strategy=docker >/dev/null

run_build() {
  oc -n "$project" start-build roundtrip --from-dir="$build_dir" --follow 2>&1
}

build_log=$(run_build) || true
echo "$build_log"

if echo "$build_log" | grep -qi 'InvalidOutputReference\|Output image could not be resolved'; then
  echo >&2
  echo "Hit InvalidOutputReference -- restarting openshift-controller-manager and retrying once..." >&2
  oc delete pods -n openshift-controller-manager --all >/dev/null
  sleep 30
  build_log=$(run_build) || true
  echo "$build_log"
fi

if ! echo "$build_log" | grep -qi 'Push successful'; then
  echo "FAIL: build never reported a successful push. See log above." >&2
  exit 1
fi

echo >&2
echo "Pulling the built image back from the internal registry..." >&2
oc -n "$project" run pulltest \
  --image="image-registry.openshift-image-registry.svc:5000/${project}/roundtrip:latest" \
  --restart=Never --command -- cat /test.txt >/dev/null

pull_phase="Pending"
for _ in $(seq 1 24); do
  pull_phase=$(oc -n "$project" get pod pulltest -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
  case "$pull_phase" in Succeeded | Failed) break ;; esac
  sleep 5
done

pull_log=$(oc -n "$project" logs pulltest 2>&1 || echo "")
echo "$pull_log"

if [ "$pull_phase" != "Succeeded" ] || ! echo "$pull_log" | grep -q "registry-verify-ok"; then
  echo "FAIL: pull-back did not produce the expected file content." >&2
  oc -n "$project" describe pod pulltest >&2 || true
  exit 1
fi

echo >&2
echo "Confirming the blobs landed on the LVMS volume, not ephemeral storage..." >&2
reg_pod=$(oc get pods -n openshift-image-registry -l docker-registry=default -o name | head -1)
[ -n "$reg_pod" ] || {
  echo "ERROR: no running image-registry pod found." >&2
  exit 1
}
mount_line=$(oc exec -n openshift-image-registry "$reg_pod" -- sh -c 'mount | grep " /registry "' 2>/dev/null || echo "")
echo "mount: $mount_line" >&2
oc exec -n openshift-image-registry "$reg_pod" -- sh -c \
  'df -h /registry; ls /registry/docker/registry/v2/repositories/' >&2

# An LVMS (topolvm) volume is a block device mounted at /registry; the
# ephemeral fallback would show up as overlay or no mount line at all.
case "$mount_line" in
  "" | overlay*)
    echo "FAIL: /registry is not a dedicated volume -- got: '$mount_line'" >&2
    exit 1
    ;;
esac
if ! oc exec -n openshift-image-registry "$reg_pod" -- sh -c \
  "ls /registry/docker/registry/v2/repositories/" 2>/dev/null | grep -qx "$project"; then
  echo "FAIL: repository $project not found under /registry on the registry pod." >&2
  exit 1
fi

echo >&2
echo "PASS: build -> push -> pull round trip verified, blobs on the /registry volume." >&2
