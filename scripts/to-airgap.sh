#!/usr/bin/env bash
# to-airgap.sh - run on a CONNECTED machine. Builds ONE transfer bundle (directory + .tar) with
# everything the disconnected cluster needs: Helm charts, container images, operator catalog
# content (oc-mirror), GPU image list, optional model files, tool versions, MANIFEST.txt, SHA256SUMS.
# bash 3.2 compatible (macOS). No secrets are written anywhere; registry credentials come from your
# own auth file (REGISTRY_AUTH_FILE or ~/.docker/config.json), NGC key only from $NGC_API_KEY.
# Import side: docs/airgap.md and scripts/from-airgap.sh (both are copied into the bundle).
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
CHARTS="$REPO_ROOT/charts"

OUT="./airgap-bundle"
PROFILE="fusion"
OCP="4.20"
MULTI="all"
TRANSPORT="oci"
DRY=0
SKIP_IMAGES=0
SKIP_OPERATORS=0
SKIP_MODELS=0
COPY_GPU=0
INCLUDE_TOOLS=0
VALUES_OVR=""
GPU_OVR=""
MODELS=""
EXTRA_IMAGES=""
NGC_IMAGES=""
WORK=""

usage() {
  cat <<'EOF'
Usage: scripts/to-airgap.sh [options]

Builds ONE transfer bundle (directory + .tar + .tar.sha256) on a connected machine.

  --out <dir>             bundle directory (default ./airgap-bundle); the tar is <dir>.tar
  --profile fusion|sno    default values set per chart (default fusion)
  --values <chart>=<file> override one chart's values file, repeatable
                          (charts: rhoai-operators, rhoai-config, airgap-config)
  --ocp <x.y>             OCP catalog index version for oc-mirror (default 4.20)
  --multi-arch all|system|index-only
                          skopeo copy mode: all = every architecture (--all, default),
                          system = this machine's platform only, index-only = manifest list only
  --transport oci|dir     image layout in the bundle (default oci: one shared dir, deduplicated blobs).
                          dir keeps manifests byte-for-byte (digest-safe for schema2 images)
  --extra-images <file>   extra image refs to include, one per line ('#' comments ok)
  --skip-images           do not copy chart-rendered images
  --skip-operators        do not run oc-mirror (the ImageSetConfiguration is still written)
  --skip-models           do not download models
  --model <repo|url>      Hugging Face repo (org/name) or direct URL, repeatable
  --model-list <file>     file with one model per line
  --gpu-version <c>=<tag> override a GPU image tag, repeatable. c = operator, validator, driver,
                          toolkit, device-plugin, dcgm-exporter, dcgm, mig-manager, gfd
  --copy-gpu              also copy the GPU Operator images (default: list only; tags are UNVERIFIED)
  --ngc-images <file>     NVAIE/NGC image refs; copied only if $NGC_API_KEY is set (never written to disk)
  --include-tools         copy the helm/skopeo/oc-mirror/oc binaries into the bundle (this machine's OS/arch)
  --dry-run               print the plan and the full image list; copy and write nothing, no network
  -h, --help              this help

Environment: REGISTRY_AUTH_FILE (registry creds for skopeo/oc-mirror), NGC_API_KEY, HF_TOKEN.
EOF
}

log() { printf '%s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

# shellcheck disable=SC2329  # invoked via the EXIT trap below
cleanup() {
  if [ -n "$WORK" ] && [ -d "$WORK" ]; then rm -rf "$WORK"; fi
}
trap cleanup EXIT

# ---------- arguments ----------
need_arg() { [ "$2" -ge 2 ] || die "option $1 needs a value (see --help)"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --out) need_arg "$1" $#; OUT=$2; shift 2 ;;
    --profile) need_arg "$1" $#; PROFILE=$2; shift 2 ;;
    --values) need_arg "$1" $#
      case "$2" in *=*) ;; *) die "--values needs <chart>=<file>, got '$2'" ;; esac
      VALUES_OVR="$VALUES_OVR$2
"; shift 2 ;;
    --ocp) need_arg "$1" $#; OCP=$2; shift 2 ;;
    --multi-arch) need_arg "$1" $#; MULTI=$2; shift 2 ;;
    --transport) need_arg "$1" $#; TRANSPORT=$2; shift 2 ;;
    --extra-images) need_arg "$1" $#; EXTRA_IMAGES=$2; shift 2 ;;
    --skip-images) SKIP_IMAGES=1; shift ;;
    --skip-operators) SKIP_OPERATORS=1; shift ;;
    --skip-models) SKIP_MODELS=1; shift ;;
    --model) need_arg "$1" $#; MODELS="$MODELS$2
"; shift 2 ;;
    --model-list) need_arg "$1" $#
      [ -f "$2" ] || die "model list not found: $2"
      MODELS="$MODELS$(grep -v -E '^[[:space:]]*(#|$)' "$2" || true)
"; shift 2 ;;
    --gpu-version) need_arg "$1" $#
      case "$2" in *=*) ;; *) die "--gpu-version needs <component>=<tag>, got '$2'" ;; esac
      GPU_OVR="$GPU_OVR$2
"; shift 2 ;;
    --copy-gpu) COPY_GPU=1; shift ;;
    --ngc-images) need_arg "$1" $#; NGC_IMAGES=$2; shift 2 ;;
    --include-tools) INCLUDE_TOOLS=1; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
done

case "$PROFILE" in fusion|sno) ;; *) die "--profile must be fusion or sno" ;; esac
case "$MULTI" in all|system|index-only) ;; *) die "--multi-arch must be all, system or index-only" ;; esac
case "$TRANSPORT" in oci|dir) ;; *) die "--transport must be oci or dir" ;; esac
printf '%s' "$OCP" | grep -q -E '^[0-9]+\.[0-9]+$' || die "--ocp must look like 4.20"
[ -d "$CHARTS" ] || die "charts directory not found: $CHARTS"
if [ -n "$EXTRA_IMAGES" ] && [ ! -f "$EXTRA_IMAGES" ]; then die "extra images file not found: $EXTRA_IMAGES"; fi
if [ -n "$NGC_IMAGES" ] && [ ! -f "$NGC_IMAGES" ]; then die "NGC images file not found: $NGC_IMAGES"; fi

# ---------- tools (fail early) ----------
MISSING=""
need() { command -v "$1" >/dev/null 2>&1 || MISSING="$MISSING $1"; }
need helm; need awk; need sed; need grep; need sort; need shasum; need tar
if [ "$DRY" -eq 0 ]; then
  if [ "$SKIP_IMAGES" -eq 0 ] || [ "$COPY_GPU" -eq 1 ] || [ -n "$NGC_IMAGES" ]; then need skopeo; fi
  if [ "$SKIP_OPERATORS" -eq 0 ]; then need oc-mirror; fi
  if [ "$SKIP_MODELS" -eq 0 ] && [ -n "$(printf '%s' "$MODELS" | tr -d '[:space:]')" ]; then need curl; fi
fi
if [ -n "$MISSING" ]; then
  die "missing required tool(s):$MISSING
  Install them (see the Tools section of docs/airgap.md for download URLs) or use --dry-run / --skip-* flags."
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/to-airgap.XXXXXX")

# ---------- helpers ----------
values_for() {
  local name=$1 line f=""
  line=$(printf '%s\n' "$VALUES_OVR" | grep -E "^${name}=" | tail -n 1 || true)
  if [ -n "$line" ]; then printf '%s\n' "${line#*=}"; return 0; fi
  case "$PROFILE:$name" in
    fusion:rhoai-operators) f=fusion.yaml ;;
    fusion:rhoai-config) f=fusion-config.yaml ;;
    fusion:airgap-config) f=fusion-airgap.yaml ;;
    sno:rhoai-operators) f=sno.yaml ;;
    sno:rhoai-config) f=sno-config.yaml ;;
  esac
  if [ -n "$f" ]; then printf '%s\n' "$CHARTS/values/$f"; fi
  return 0
}

# Render one chart. Dummy values below exist only so templates that "required" a value can render;
# rendered output is never stored in the bundle.
render_chart() {
  local name=$1 vf
  vf=$(values_for "$name")
  if [ -n "$vf" ] && [ ! -f "$vf" ]; then die "values file for $name not found: $vf"; fi
  case "$name" in
    rhoai-config) set -- --set s3.accessKey=x --set s3.secretKey=xxxxxxxx ;;
    airgap-config) set -- --set trust.caBundle=dummy ;;
    *) set -- ;;
  esac
  if [ -n "$vf" ]; then
    helm template "$name" "$CHARTS/$name" -f "$vf" "$@"
  else
    helm template "$name" "$CHARTS/$name" "$@"
  fi
}

# Normalise an image ref: add docker.io/ when no registry host is present.
norm_ref() {
  local r=$1 first
  first=${r%%/*}
  case "$r" in
    */*)
      case "$first" in
        *.*|*:*|localhost) printf '%s\n' "$r" ;;
        *) printf 'docker.io/%s\n' "$r" ;;
      esac ;;
    *) printf 'docker.io/library/%s\n' "$r" ;;
  esac
}

# Print image refs found in a rendered chart (stdin). CatalogSource images are skipped (oc-mirror makes those);
# ClusterPolicy repository/image/version triples are joined into one ref.
extract_images() {
  local ref_re='[a-z0-9][a-z0-9.-]*\.[a-z]{2,}(:[0-9]+)?/[A-Za-z0-9._/-]+((:[A-Za-z0-9._-]+)(@sha256:[0-9a-f]{64})?|@sha256:[0-9a-f]{64})'
  awk '
    function val(l) { sub(/^[^:]*:[ ]*/, "", l); gsub(/["\047]/, "", l); sub(/[ ]+#.*$/, "", l); return l }
    function flush(   i, l, iscat, iscp, repo, img, ver) {
      if (n == 0) return
      iscat = 0; iscp = 0
      for (i = 1; i <= n; i++) {
        if (buf[i] ~ /^kind: CatalogSource/) iscat = 1
        if (buf[i] ~ /^kind: ClusterPolicy/) iscp = 1
      }
      if (!iscat) {
        if (iscp) {
          repo = ""; img = ""; ver = ""
          for (i = 1; i <= n; i++) {
            l = buf[i]
            if (l ~ /^ +repository: /) repo = val(l)
            else if (l ~ /^ +image: /) img = val(l)
            else if (l ~ /^ +version: /) ver = val(l)
            if (repo != "" && img != "" && ver != "") { print "image: " repo "/" img ":" ver; repo = ""; img = ""; ver = "" }
          }
        } else {
          for (i = 1; i <= n; i++) print buf[i]
        }
      }
      n = 0
    }
    /^---/ { flush(); next }
    { buf[++n] = $0 }
    END { flush() }
  ' > "$WORK/doc.filtered"
  {
    { grep -E '^[[:space:]-]*image:[[:space:]]*[^[:space:]]' "$WORK/doc.filtered" || true; } \
      | sed -E 's/^[[:space:]-]*image:[[:space:]]*//; s/[[:space:]]+#.*$//; s/^["'\'']//; s/["'\'']$//'
    # images referenced from env values or container args
    { grep -E '^[[:space:]-]*(value:|- "?--)|--[a-z-]+=' "$WORK/doc.filtered" || true; } \
      | { grep -v -E 'https?://' || true; } \
      | { grep -o -E "$ref_re" || true; }
  } | { grep -v -E '^$|\{\{|\$\(' || true; }
}

# ---------- charts, images ----------
CHART_NAMES=""
for d in "$CHARTS"/*/; do
  [ -f "${d}Chart.yaml" ] || continue
  n=$(basename "$d")
  CHART_NAMES="$CHART_NAMES $n"
done
[ -n "$CHART_NAMES" ] || die "no charts found under $CHARTS"

: > "$WORK/images.raw"
: > "$WORK/placeholders.txt"
for n in $CHART_NAMES; do
  log "rendering $n ($(values_for "$n" | sed "s|$REPO_ROOT/||"))"
  render_chart "$n" > "$WORK/render-$n.yaml" || die "helm template failed for $n (run it by hand to see why)"
  extract_images < "$WORK/render-$n.yaml" > "$WORK/found-$n.txt"
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    r=$(norm_ref "$r")
    case "$r" in
      *example.internal*) printf '%s\t%s\n' "$r" "$n" >> "$WORK/placeholders.txt" ;;
      *) printf '%s\t%s\n' "$r" "$n" >> "$WORK/images.raw" ;;
    esac
  done < "$WORK/found-$n.txt"
done

if [ -n "$EXTRA_IMAGES" ]; then
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    printf '%s\t%s\n' "$(norm_ref "$r")" "extra" >> "$WORK/images.raw"
  done < <(grep -v -E '^[[:space:]]*(#|$)' "$EXTRA_IMAGES" || true)
fi

# ---------- GPU image list (UNVERIFIED tags) ----------
gpu_tag() {
  local o
  o=$(printf '%s\n' "$GPU_OVR" | awk -F= -v k="$1" '$1==k { sub(/^[^=]*=/, ""); print; exit }')
  if [ -n "$o" ]; then printf '%s\n' "$o"; return 0; fi
  case "$1" in
    operator|validator) echo "v25.10.0" ;;
    driver) echo "580.82.07" ;;
    toolkit) echo "v1.18.0-ubi9" ;;
    device-plugin|gfd) echo "v0.18.0" ;;
    dcgm-exporter) echo "4.4.1-4.5.0-ubi9" ;;
    dcgm) echo "4.4.1-1-ubi9" ;;
    mig-manager) echo "v0.13.0" ;;
    *) die "unknown GPU component: $1" ;;
  esac
}
for c in operator validator driver toolkit device-plugin dcgm-exporter dcgm mig-manager gfd; do gpu_tag "$c" >/dev/null; done

gpu_list() {
  printf 'operator\tnvcr.io/nvidia/gpu-operator:%s\n' "$(gpu_tag operator)"
  printf 'validator\tnvcr.io/nvidia/gpu-operator:%s\n' "$(gpu_tag validator)"
  printf 'driver\tnvcr.io/nvidia/driver:%s-rhcos%s\n' "$(gpu_tag driver)" "$OCP"
  printf 'toolkit\tnvcr.io/nvidia/k8s/container-toolkit:%s\n' "$(gpu_tag toolkit)"
  printf 'device-plugin\tnvcr.io/nvidia/k8s-device-plugin:%s\n' "$(gpu_tag device-plugin)"
  printf 'gfd\tnvcr.io/nvidia/k8s-device-plugin:%s\n' "$(gpu_tag gfd)"
  printf 'dcgm-exporter\tnvcr.io/nvidia/k8s/dcgm-exporter:%s\n' "$(gpu_tag dcgm-exporter)"
  printf 'dcgm\tnvcr.io/nvidia/cloud-native/dcgm:%s\n' "$(gpu_tag dcgm)"
  printf 'mig-manager\tnvcr.io/nvidia/cloud-native/k8s-mig-manager:%s\n' "$(gpu_tag mig-manager)"
}
gpu_list > "$WORK/gpu.tsv"
if [ "$COPY_GPU" -eq 1 ]; then
  while IFS=$'\t' read -r _ r; do printf '%s\t%s\n' "$r" "gpu(UNVERIFIED tag)" >> "$WORK/images.raw"; done < "$WORK/gpu.tsv"
fi

# NGC (needs a key; copied later only if NGC_API_KEY is set)
: > "$WORK/ngc.txt"
if [ -n "$NGC_IMAGES" ]; then
  grep -v -E '^[[:space:]]*(#|$)' "$NGC_IMAGES" | while IFS= read -r r; do norm_ref "$r"; done > "$WORK/ngc.txt" || true
fi

# dedupe, number
LC_ALL=C sort -t "$(printf '\t')" -k1,1 "$WORK/images.raw" | awk -F'\t' '!s[$1]++ { printf "%04d\t%s\t%s\n", ++k, $1, $2 }' > "$WORK/images.tsv"
LC_ALL=C sort -u "$WORK/placeholders.txt" > "$WORK/placeholders.sorted"
IMG_COUNT=$(wc -l < "$WORK/images.tsv" | tr -d ' ')

# ---------- operator ImageSetConfiguration ----------
OPS_VALUES=$(values_for rhoai-operators)
render_chart rhoai-operators 2>/dev/null | awk -v ocp="$OCP" '
  function val(l) { sub(/^[^:]*:[ ]*/, "", l); gsub(/["\047]/, "", l); return l }
  function idx(src) {
    if (src ~ /certified/) return "certified-operator-index"
    if (src ~ /community/) return "community-operator-index"
    if (src ~ /marketplace/) return "redhat-marketplace-index"
    return "redhat-operator-index"
  }
  function flush(   c) {
    if (issub && pkg != "") {
      c = idx(src)
      if (!(c in seen)) { seen[c] = 1; order[++nc] = c }
      list[c] = list[c] pkg "\t" ch "\n"
    }
    issub = 0; pkg = ""; ch = ""; src = ""; inspec = 0
  }
  /^---/ { flush(); next }
  /^[A-Za-z]/ { inspec = ($0 ~ /^spec:/) }
  /^kind: Subscription/ { issub = 1 }
  inspec && /^  name:/ { pkg = val($0) }
  inspec && /^  channel:/ { ch = val($0) }
  inspec && /^  source:/ { src = val($0) }
  END {
    flush()
    print "# Generated by scripts/to-airgap.sh from the rhoai-operators chart Subscriptions."
    print "# UNVERIFIED: apiVersion v2alpha1 is what oc-mirror v2 uses as far as known; check the oc-mirror docs for your 4.20 build."
    print "# UNVERIFIED: catalog index names/tags, and that these channels exist in the OCP " ocp " catalogs."
    print "kind: ImageSetConfiguration"
    print "apiVersion: mirror.openshift.io/v2alpha1"
    print "mirror:"
    print "  operators:"
    for (i = 1; i <= nc; i++) {
      c = order[i]
      print "    - catalog: registry.redhat.io/redhat/" c ":v" ocp
      print "      packages:"
      m = split(list[c], rows, "\n")
      for (j = 1; j <= m; j++) {
        if (rows[j] == "") continue
        split(rows[j], f, "\t")
        print "        - name: " f[1]
        print "          channels:"
        print "            - name: " f[2]
      }
    }
  }' > "$WORK/imageset-config.yaml" || die "could not derive the ImageSetConfiguration from rhoai-operators"
grep -q 'name:' "$WORK/imageset-config.yaml" || die "no Subscriptions found in rhoai-operators render; ImageSetConfiguration would be empty"

# ---------- plan ----------
print_plan() {
  echo "=== to-airgap plan ($( [ "$DRY" -eq 1 ] && echo DRY-RUN || echo REAL ))"
  echo "profile=$PROFILE ocp=$OCP multi-arch=$MULTI transport=$TRANSPORT out=$OUT"
  echo "charts:$CHART_NAMES"
  for n in $CHART_NAMES; do
    vshow=$(values_for "$n" | sed "s|$REPO_ROOT/||")
    echo "  $n values: ${vshow:-(chart defaults)}"
  done
  echo "skip: images=$SKIP_IMAGES operators=$SKIP_OPERATORS models=$SKIP_MODELS; include-tools=$INCLUDE_TOOLS; copy-gpu=$COPY_GPU"
  echo
  echo "--- images to copy ($IMG_COUNT, deduped)  [idx  ref  (from)]"
  awk -F'\t' '{ printf "  %s  %s  (%s)\n", $1, $2, $3 }' "$WORK/images.tsv"
  if [ -s "$WORK/placeholders.sorted" ]; then
    echo "--- SKIPPED (placeholder host *.example.internal; give the real upstream via --extra-images or fix the values)"
    awk -F'\t' '{ printf "  %s  (from %s)\n", $1, $2 }' "$WORK/placeholders.sorted"
  fi
  echo "--- GPU Operator runtime images (ALL TAGS UNVERIFIED; override with --gpu-version c=tag)"
  awk -F'\t' '{ printf "  %-14s %s\n", $1, $2 }' "$WORK/gpu.tsv"
  echo "  NFD operand images and the GPU Operator's relatedImages come with the oc-mirror operator mirror (UNVERIFIED)."
  if [ -s "$WORK/ngc.txt" ]; then
    echo "--- NGC/NVAIE images ($(wc -l < "$WORK/ngc.txt" | tr -d ' ')): copied only if NGC_API_KEY is set (currently: $( [ -n "${NGC_API_KEY:-}" ] && echo set || echo NOT set ))"
    sed 's/^/  /' "$WORK/ngc.txt"
  else
    echo "--- NGC/NVAIE: none listed (--ngc-images <file> + NGC_API_KEY; open item 2)"
  fi
  echo "--- operators (oc-mirror, from $OPS_VALUES)"
  sed 's/^/  /' "$WORK/imageset-config.yaml"
  echo "--- models"
  if [ "$SKIP_MODELS" -eq 1 ]; then echo "  skipped"; else
    printf '%s' "$MODELS" | grep -v '^$' | sed 's/^/  /' || echo "  none"
  fi
}
print_plan
if [ "$DRY" -eq 1 ]; then
  log "dry-run: nothing copied or written."
  exit 0
fi

# ---------- build the bundle ----------
if [ -e "$OUT" ] && [ -n "$(ls -A "$OUT" 2>/dev/null)" ]; then die "$OUT exists and is not empty"; fi
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
MANIFEST="$OUT/MANIFEST.txt"
m() { printf '%s\n' "$*" >> "$MANIFEST"; }
FAILS=0
WARNS=0

GIT_REV=$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)
m "# MANIFEST - generated by scripts/to-airgap.sh"
m "created_utc: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
m "host: $(uname -sm)"
m "repo_commit: $GIT_REV (working tree may be dirty)"
m "profile: $PROFILE  ocp_catalog: v$OCP  multi_arch: $MULTI  transport: $TRANSPORT"
m ""

# 1. charts
log "packaging charts"
mkdir -p "$OUT/charts/packages"
m "## charts"
for n in $CHART_NAMES; do
  helm package "$CHARTS/$n" --destination "$OUT/charts/packages" >/dev/null || die "helm package failed for $n"
done
cp -R "$CHARTS/values" "$OUT/charts/values"
for f in adopt-existing.sh README.md; do
  if [ -f "$CHARTS/$f" ]; then cp "$CHARTS/$f" "$OUT/charts/$f"; else m "WARNING: charts/$f not found, not bundled"; fi
done
for p in "$OUT"/charts/packages/*.tgz; do m "chart: $(basename "$p") sha256=$(shasum -a 256 "$p" | awk '{print $1}')"; done
for n in $CHART_NAMES; do
  vf=$(values_for "$n")
  if [ -n "$vf" ]; then m "values-used: $n -> $(basename "$vf") sha256=$(shasum -a 256 "$vf" | awk '{print $1}')"; fi
done
m ""
mkdir -p "$OUT/docs" "$OUT/scripts"
if [ -f "$REPO_ROOT/docs/airgap.md" ]; then cp "$REPO_ROOT/docs/airgap.md" "$OUT/docs/airgap.md"; fi
if [ -f "$REPO_ROOT/scripts/from-airgap.sh" ]; then cp "$REPO_ROOT/scripts/from-airgap.sh" "$OUT/scripts/from-airgap.sh"; fi

# skopeo copy of one ref into the bundle; sets COPY_DIGEST and COPY_STATUS
copy_one() {
  local ref=$1 id=$2 dst src_digest dst_digest creds_user
  COPY_DIGEST="-"; COPY_STATUS="FAILED"
  if [ "$TRANSPORT" = "oci" ]; then dst="oci:$OUT/images/oci:img-$id"; else dst="dir:$OUT/images/dir/img-$id"; fi
  # shellcheck disable=SC2016  # literal NGC user name, not an expansion
  creds_user='$oauthtoken'
  local credargs_set=0
  if [ "${3:-}" = "ngc" ]; then credargs_set=1; fi
  case "$MULTI" in
    all) set -- --all ;;
    index-only) set -- --multi-arch=index-only ;;
    *) set -- ;;
  esac
  if [ "$credargs_set" -eq 1 ]; then
    # NOTE: --src-creds is visible in `ps` while skopeo runs on this machine; it is never written to disk.
    skopeo copy "$@" --src-creds "${creds_user}:${NGC_API_KEY}" "docker://$ref" "$dst" < /dev/null || return 0
    src_digest=$(skopeo inspect --raw --creds "${creds_user}:${NGC_API_KEY}" "docker://$ref" < /dev/null | shasum -a 256 | awk '{print $1}') || src_digest=""
  else
    skopeo copy "$@" "docker://$ref" "$dst" < /dev/null || return 0
    src_digest=$(skopeo inspect --raw "docker://$ref" < /dev/null | shasum -a 256 | awk '{print $1}') || src_digest=""
  fi
  dst_digest=$(skopeo inspect --raw "$dst" < /dev/null | shasum -a 256 | awk '{print $1}') || dst_digest=""
  if [ -z "$dst_digest" ]; then COPY_STATUS="FAILED"; return 0; fi
  COPY_DIGEST="sha256:$dst_digest"
  if [ -n "$src_digest" ] && [ "$src_digest" != "$dst_digest" ]; then COPY_STATUS="DIGEST-CHANGED"; else COPY_STATUS="OK"; fi
  return 0
}

# 2. images
mkdir -p "$OUT/images"
printf '%s\n' "$TRANSPORT" > "$OUT/images/transport.txt"
: > "$OUT/images/images.tsv"
if [ "$SKIP_IMAGES" -eq 1 ] && [ "$COPY_GPU" -eq 0 ]; then
  m "## images: skipped (--skip-images)"
else
  log "copying $IMG_COUNT images (skopeo)"
  m "## images (idx ref manifest-digest status from)"
  while IFS=$'\t' read -r id ref src; do
    # with --skip-images only GPU images are copied
    if [ "$SKIP_IMAGES" -eq 1 ]; then case "$src" in gpu*) ;; *) continue ;; esac; fi
    log "  [$id] $ref"
    copy_one "$ref" "$id"
    case "$COPY_STATUS" in
      FAILED) FAILS=$((FAILS + 1)); log "    FAILED (auth? REGISTRY_AUTH_FILE; network)" ;;
      DIGEST-CHANGED) WARNS=$((WARNS + 1)); log "    WARNING digest changed by format conversion (retry with --transport dir)" ;;
    esac
    printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$ref" "$COPY_DIGEST" "$COPY_STATUS" "$src" >> "$OUT/images/images.tsv"
    m "$id $ref $COPY_DIGEST $COPY_STATUS $src"
  done < "$WORK/images.tsv"
fi
m ""

# 4. GPU / NGC
mkdir -p "$OUT/gpu"
{
  echo "# GPU Operator runtime images. ALL TAGS UNVERIFIED (guesses for GPU Operator 25.10 / OCP $OCP)."
  echo "# Cross-check against the CSV relatedImages of the mirrored gpu-operator-certified bundle and NVIDIA's support matrix."
  echo "# Copied into the bundle only with --copy-gpu (see images/images.tsv, source 'gpu(UNVERIFIED tag)')."
  echo "# The driver image tag follows <driver>-rhcos<ocp>; with OpenShift the Driver Toolkit image comes from the OCP release payload (platform mirror, not here)."
  cat "$WORK/gpu.tsv"
} > "$OUT/gpu/gpu-images.txt"
m "## gpu: list in gpu/gpu-images.txt (UNVERIFIED tags; copied=$COPY_GPU)"
if [ -s "$WORK/ngc.txt" ]; then
  if [ -n "${NGC_API_KEY:-}" ]; then
    log "copying NGC images (key from \$NGC_API_KEY, not stored)"
    : > "$OUT/gpu/ngc-images.tsv"
    k=0
    while IFS= read -r ref; do
      k=$((k + 1)); id=$(printf 'n%03d' "$k")
      copy_one "$ref" "$id" ngc
      if [ "$COPY_STATUS" = "FAILED" ]; then FAILS=$((FAILS + 1)); fi
      printf '%s\t%s\t%s\t%s\tngc\n' "$id" "$ref" "$COPY_DIGEST" "$COPY_STATUS" >> "$OUT/gpu/ngc-images.tsv"
      m "$id $ref $COPY_DIGEST $COPY_STATUS ngc"
    done < "$WORK/ngc.txt"
    cat "$OUT/gpu/ngc-images.tsv" >> "$OUT/images/images.tsv"
  else
    cp "$WORK/ngc.txt" "$OUT/gpu/ngc-images.todo.txt"
    m "NGC: NGC_API_KEY not set; list saved in gpu/ngc-images.todo.txt, NOT copied"
  fi
else
  m "NGC/NVAIE: none requested (open item 2). Use --ngc-images <file> with NGC_API_KEY exported."
fi
m ""

# 3. operators
mkdir -p "$OUT/operators"
cp "$WORK/imageset-config.yaml" "$OUT/operators/imageset-config.yaml"
m "## operators: operators/imageset-config.yaml (from rhoai-operators Subscriptions, catalog v$OCP)"
if [ "$SKIP_OPERATORS" -eq 1 ]; then
  m "oc-mirror: skipped (--skip-operators)"
else
  log "running oc-mirror (mirror to disk; large download, UNVERIFIED flags for your oc-mirror build)"
  mkdir -p "$OUT/operators/mirror"
  if oc-mirror --v2 -c "$OUT/operators/imageset-config.yaml" "file://$OUT/operators/mirror"; then
    m "oc-mirror: OK (archives in operators/mirror; cluster resources idms/itms/cs are generated at IMPORT time into the working-dir)"
  else
    FAILS=$((FAILS + 1)); m "oc-mirror: FAILED"; log "oc-mirror FAILED"
  fi
fi
m ""

# 5. models
mkdir -p "$OUT/models"
m "## models"
if [ "$SKIP_MODELS" -eq 1 ] || [ -z "$(printf '%s' "$MODELS" | tr -d '[:space:]')" ]; then
  m "none"
else
  while IFS= read -r mdl; do
    [ -n "$mdl" ] || continue
    case "$mdl" in
      http://*|https://*)
        f="$OUT/models/$(basename "${mdl%%\?*}")"
        log "downloading $mdl"
        if curl -fL --retry 3 -o "$f" "$mdl"; then m "model: $mdl -> models/$(basename "$f")"; else FAILS=$((FAILS + 1)); m "model: $mdl FAILED"; fi ;;
      *)
        safe=$(printf '%s' "$mdl" | tr '/' '_')
        hf_cmd=""
        if command -v hf >/dev/null 2>&1; then hf_cmd=hf; elif command -v huggingface-cli >/dev/null 2>&1; then hf_cmd=huggingface-cli; fi
        if [ -z "$hf_cmd" ]; then
          FAILS=$((FAILS + 1)); m "model: $mdl FAILED (no 'hf' or 'huggingface-cli': pip install -U huggingface_hub[cli])"
          log "no hf/huggingface-cli for $mdl"
        else
          log "downloading $mdl with $hf_cmd (HF_TOKEN from env if set)"
          if "$hf_cmd" download "$mdl" --local-dir "$OUT/models/$safe"; then
            rm -rf "$OUT/models/$safe/.cache"; m "model: $mdl -> models/$safe"
          else FAILS=$((FAILS + 1)); m "model: $mdl FAILED"; fi
        fi ;;
    esac
  done <<EOF
$MODELS
EOF
fi
m ""

# 6. tools
mkdir -p "$OUT/tools"
m "## tools used (versions)"
{
  echo "machine: $(uname -sm)"
  echo "helm: $( (helm version --short 2>&1 || true) | head -n 1)"
  echo "skopeo: $( (skopeo --version 2>&1 || true) | head -n 1)"
  echo "oc-mirror: $( (oc-mirror --v2 version 2>&1 || oc-mirror version 2>&1 || true) | head -n 3 | tr '\n' ' ')"
  echo "oc: $( (oc version --client 2>&1 || true) | head -n 1)"
  echo
  echo "Download URLs (UNVERIFIED, check for your OCP version / OS):"
  echo "  oc, oc-mirror: https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable-$OCP/"
  echo "  helm:          https://github.com/helm/helm/releases (get.helm.sh)"
  echo "  skopeo:        distro package (dnf install skopeo) or https://github.com/containers/skopeo/releases"
  echo "  hf CLI:        pip install -U 'huggingface_hub[cli]'"
} > "$OUT/tools/TOOLS.txt"
sed 's/^/tools: /' "$OUT/tools/TOOLS.txt" | grep -v -E '^tools: *$' >> "$MANIFEST" || true
if [ "$INCLUDE_TOOLS" -eq 1 ]; then
  m "tools: binaries included from $(uname -sm); they run only on the same OS/arch (a macOS binary will NOT run on RHEL)"
  for t in helm skopeo oc-mirror oc; do
    if command -v "$t" >/dev/null 2>&1; then cp "$(command -v "$t")" "$OUT/tools/$t"; else m "tools: $t not found, not included"; fi
  done
fi

# summary, checksums, tar
m ""
m "## summary: failures=$FAILS digest_changed_warnings=$WARNS images_in_list=$IMG_COUNT"
log "writing SHA256SUMS"
# shellcheck disable=SC2094  # SHA256SUMS is excluded from the find, so it is never read while written
( cd "$OUT" && find . -type f ! -name SHA256SUMS -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256 > SHA256SUMS )
PARENT=$(dirname "$OUT"); BASE=$(basename "$OUT")
log "creating $OUT.tar"
tar -cf "$OUT.tar" -C "$PARENT" "$BASE"
( cd "$PARENT" && shasum -a 256 "$BASE.tar" > "$BASE.tar.sha256" )

echo "bundle: $OUT"
echo "tar:    $OUT.tar (+ $BASE.tar.sha256)"
echo "failures=$FAILS digest_changed_warnings=$WARNS (details in MANIFEST.txt)"
if [ "$FAILS" -gt 0 ]; then die "$FAILS item(s) failed; the bundle is incomplete, see MANIFEST.txt"; fi
exit 0
