#!/usr/bin/env bash
# from-airgap.sh - run on the DISCONNECTED side. Verifies the bundle checksums and pushes the images
# from images/images.tsv to Artifactory with skopeo, one distinct path prefix per upstream registry
# (default rh-registry-<host with dots as dashes>, matching charts/values/fusion-airgap.yaml).
# Registry credentials: your own auth file (REGISTRY_AUTH_FILE or `skopeo login`), never in the bundle.
# Operators (oc-mirror) and Helm installs are separate steps: see docs/airgap.md.
set -euo pipefail

BUNDLE=""
DEST=""
DRY=0
VERIFY_ONLY=0
SKIP_VERIFY=0
MAPS=""

usage() {
  cat <<'EOF'
Usage: scripts/from-airgap.sh --bundle <dir> --dest <registry-host[:port]> [options]

  --bundle <dir>         extracted bundle directory (contains SHA256SUMS, images/)
  --dest <host[:port]>   Artifactory registry host, e.g. artifactory.example.internal
  --map <host>=<prefix>  override the path prefix for one upstream registry, repeatable
                         (default: rh-registry-<host with dots as dashes>, e.g. rh-registry-quay-io)
  --verify-only          only verify checksums
  --skip-verify          do not verify checksums (not recommended)
  --dry-run              print the skopeo commands, push nothing
  -h, --help
EOF
}
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --bundle) [ $# -ge 2 ] || die "--bundle needs a value"; BUNDLE=$2; shift 2 ;;
    --dest) [ $# -ge 2 ] || die "--dest needs a value"; DEST=$2; shift 2 ;;
    --map) [ $# -ge 2 ] || die "--map needs a value"; MAPS="$MAPS$2
"; shift 2 ;;
    --verify-only) VERIFY_ONLY=1; shift ;;
    --skip-verify) SKIP_VERIFY=1; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
done
[ -n "$BUNDLE" ] && [ -d "$BUNDLE" ] || die "--bundle <dir> is required and must exist"
BUNDLE=$(cd "$BUNDLE" && pwd)
command -v shasum >/dev/null 2>&1 || die "shasum not found"

if [ "$SKIP_VERIFY" -eq 0 ]; then
  echo "verifying checksums..."
  ( cd "$BUNDLE" && shasum -a 256 -c SHA256SUMS > /dev/null ) || die "checksum verification FAILED; do not import this bundle"
  echo "checksums OK"
fi
if [ "$VERIFY_ONLY" -eq 1 ]; then exit 0; fi

[ -n "$DEST" ] || die "--dest is required"
if [ "$DRY" -eq 0 ]; then command -v skopeo >/dev/null 2>&1 || die "skopeo not found (use --dry-run to only print)"; fi
[ -f "$BUNDLE/images/images.tsv" ] || die "no images/images.tsv in the bundle"
TRANSPORT=$(cat "$BUNDLE/images/transport.txt" 2>/dev/null || echo oci)

prefix_for() {
  local host=$1 line
  line=$(printf '%s\n' "$MAPS" | grep -E "^${host}=" | tail -n 1 || true)
  if [ -n "$line" ]; then printf '%s\n' "${line#*=}"; return 0; fi
  printf 'rh-registry-%s\n' "$(printf '%s' "$host" | sed 's/[.:]/-/g')"
}

FAILS=0
while IFS=$'\t' read -r id ref _digest status _src; do
  [ "$status" = "FAILED" ] && { echo "skip $ref (failed at bundle time)"; continue; }
  host=${ref%%/*}
  rest=${ref#*/}
  case "$rest" in
    *@sha256:*) hex=${rest##*@sha256:}; repo=${rest%%@*}; target="$repo:sha256-$hex" ;; # digest refs get a tag; pulls by digest still work
    *) target=$rest ;;
  esac
  dst="docker://$DEST/$(prefix_for "$host")/$target"
  if [ "$TRANSPORT" = "oci" ]; then src="oci:$BUNDLE/images/oci:img-$id"; else src="dir:$BUNDLE/images/dir/img-$id"; fi
  if [ "$DRY" -eq 1 ]; then
    echo "skopeo copy --all $src $dst"
  else
    echo "push $ref -> $dst"
    skopeo copy --all "$src" "$dst" < /dev/null || { FAILS=$((FAILS + 1)); echo "  FAILED" >&2; }
  fi
done < "$BUNDLE/images/images.tsv"

if [ "$FAILS" -gt 0 ]; then die "$FAILS push(es) failed"; fi
echo "done."
