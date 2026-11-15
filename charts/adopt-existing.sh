#!/usr/bin/env bash
# Lets Helm adopt RHOAI objects that were applied by hand (manifests/rhoai/*, day2/install-rhoai.sh).
#
# Helm refuses to install over an object it does not own ("exists and cannot be imported into the
# current release"). It treats an object as its own when it carries:
#   label       app.kubernetes.io/managed-by=Helm
#   annotations meta.helm.sh/release-name=<release>, meta.helm.sh/release-namespace=<ns>
# This script adds exactly those, nothing else. It never creates, deletes or edits specs, and skips
# objects that do not exist. Re-running is safe.
#
# Objects (names are the ones created by manifests/rhoai and the operator):
#   operators release: Namespace redhat-ods-operator, OperatorGroup rhods-operator-group,
#                      Subscription rhods-operator
#   config release:    DSCInitialization default-dsci, DataScienceCluster default-dsc
# Not adopted: the DSCI/DSC are only labelled if they exist; MinIO, the project and the data
# connection are new objects and need no adoption.
set -euo pipefail

usage() {
  cat <<'EOF'
usage: adopt-existing.sh [--dry-run] [--only operators|config|all]
                         [--operators-release NAME] [--config-release NAME]
                         [--release-namespace NS] [--cli oc|kubectl]
  --dry-run              print the commands, contact no cluster
  --only                 which release's objects to label (default: all)
  --operators-release    Helm release name of charts/rhoai-operators (default: rhoai-operators)
  --config-release       Helm release name of charts/rhoai-config (default: rhoai-config)
  --release-namespace    namespace the releases are installed into (default: default);
                         use the same value for helm --namespace
EOF
}

dry_run=false
only=all
op_release=rhoai-operators
cfg_release=rhoai-config
rel_ns=default
cli=oc

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry_run=true; shift ;;
    --only) only="${2:-}"; shift 2 ;;
    --operators-release) op_release="${2:-}"; shift 2 ;;
    --config-release) cfg_release="${2:-}"; shift 2 ;;
    --release-namespace) rel_ns="${2:-}"; shift 2 ;;
    --cli) cli="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$only" in operators|config|all) ;; *) echo "--only must be operators, config or all" >&2; exit 2 ;; esac
for v in "$op_release" "$cfg_release" "$rel_ns" "$cli"; do
  [ -n "$v" ] || { echo "empty option value" >&2; usage >&2; exit 2; }
done

if [ "$dry_run" = false ]; then
  command -v "$cli" >/dev/null 2>&1 || { echo "$cli not found" >&2; exit 1; }
  echo "Cluster context: $("$cli" whoami --show-server 2>/dev/null || echo unknown)"
  echo "Check this is the intended cluster; press Ctrl-C within 5s to abort."
  sleep 5
fi

adopt() { # kind name namespace(or "") release
  local kind="$1" name="$2" ns="$3" release="$4"
  local nsargs=""
  [ -n "$ns" ] && nsargs="-n $ns"

  if [ "$dry_run" = true ]; then
    echo "[dry-run] $cli get $kind $name $nsargs   (skip if absent)"
    echo "[dry-run] $cli label    $kind $name $nsargs --overwrite app.kubernetes.io/managed-by=Helm"
    echo "[dry-run] $cli annotate $kind $name $nsargs --overwrite meta.helm.sh/release-name=$release meta.helm.sh/release-namespace=$rel_ns"
    return 0
  fi

  # nsargs is deliberately unquoted: it is empty or "-n <ns>".
  # shellcheck disable=SC2086
  if ! "$cli" get "$kind" "$name" $nsargs >/dev/null 2>&1; then
    echo "skip   $kind/$name (not found)"
    return 0
  fi
  # shellcheck disable=SC2086
  "$cli" label "$kind" "$name" $nsargs --overwrite app.kubernetes.io/managed-by=Helm
  # shellcheck disable=SC2086
  "$cli" annotate "$kind" "$name" $nsargs --overwrite \
    "meta.helm.sh/release-name=$release" "meta.helm.sh/release-namespace=$rel_ns"
  echo "adopted $kind/$name -> release $release"
}

if [ "$only" = operators ] || [ "$only" = all ]; then
  adopt namespace redhat-ods-operator "" "$op_release"
  adopt operatorgroup.operators.coreos.com rhods-operator-group redhat-ods-operator "$op_release"
  adopt subscription.operators.coreos.com rhods-operator redhat-ods-operator "$op_release"
fi
if [ "$only" = config ] || [ "$only" = all ]; then
  adopt dscinitialization.dscinitialization.opendatahub.io default-dsci "" "$cfg_release"
  adopt datasciencecluster.datasciencecluster.opendatahub.io default-dsc "" "$cfg_release"
fi

echo "done. Next: helm upgrade --install <release> <chart> --namespace $rel_ns -f <values>"
