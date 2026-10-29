#!/usr/bin/env bash
# Runs ON THE BASTION (systemd timer, every 15 min). Stops every EC2 instance of
# this deployment once the cluster has shown no human/LLM activity for
# THRESHOLD_MIN minutes. Same end state as scripts/hibernate.sh.
#
# "Activity" is the newest of these signals (idle time = now - newest):
#   - the bastion's own boot            (so wake.sh restarts the clock)
#   - a KeepAliveUntil tag in the future (scripts/keepalive.sh)
#   - an LLM request: a vLLM pod is serving, or its request counter moved
#   - a HUMAN change to a workload object in a non-system namespace
#     (managedFields manager = kubectl*/oc/Mozilla(console)/helm; operators,
#     kubelet and controllers use their own manager names and are ignored)
#   - a new OAuth login
#
# Config comes from /etc/sno-auto-shutdown.env (see scripts/install-auto-shutdown.sh).
# Bash 3.2-compatible on purpose so the fixtures test runs on a laptop.
set -euo pipefail

ENV_FILE="${ENV_FILE:-/etc/sno-auto-shutdown.env}"
STATE_DIR="${STATE_DIR:-/var/lib/sno-auto-shutdown}"

# Matches the field-manager names a person's tooling leaves in managedFields.
HUMAN_MANAGER_RE='^(kubectl.*|oc|Mozilla.*|helm.*)$'
# Namespaces owned by the platform; a person editing there is not "using" the cluster.
SYSTEM_NS_RE='^(openshift|openshift-.*|kube-.*|default)$'
LLM_POD_SELECTOR='serving.kserve.io/inferenceservice'

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) auto-shutdown: $*"; }

# --- pure helpers (unit-tested in test-idle-check.sh) -------------------------

# stdin: vLLM /metrics text. stdout: "<running> <success_total>"
llm_stats_from_metrics() {
  awk '
    /^vllm:num_requests_running(\{| )/ { running += $NF }
    /^vllm:request_success_total(\{| )/ { total += $NF }
    END { printf "%d %d\n", running, total }'
}

# stdin: `oc get ... -o json --show-managed-fields` List. stdout: newest human
# change as epoch seconds, 0 if none.
latest_human_change_epoch() {
  jq -r --arg re "$HUMAN_MANAGER_RE" '
    [.items[]?.metadata.managedFields[]?
     | select((.manager // "") | test($re))
     | .time // empty | fromdateiso8601] | max // 0'
}

# stdin: oauthaccesstokens List. stdout: newest login as epoch seconds, 0 if none.
latest_login_epoch() {
  jq -r '[.items[]?.metadata.creationTimestamp | fromdateiso8601] | max // 0'
}

# args: now last_active. stdout: whole idle minutes.
idle_minutes() { echo $(( ($1 - $2) / 60 )); }

max_of() {
  local m=0 v
  for v in "$@"; do [ "$v" -gt "$m" ] && m="$v"; done
  echo "$m"
}

# shellcheck disable=SC2317
if [ "${IDLE_CHECK_SOURCE_ONLY:-0}" = 1 ]; then return 0 2>/dev/null || exit 0; fi

# --- main ---------------------------------------------------------------------

usage() {
  echo "usage: idle-check.sh [--dry-run] [--threshold-min N]" >&2
  exit 1
}

dry_run=0
threshold_override=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry_run=1; shift ;;
    --threshold-min) threshold_override="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done

# shellcheck disable=SC1090
[ -f "$ENV_FILE" ] && source "$ENV_FILE"
: "${AWS_REGION:?AWS_REGION not set (see $ENV_FILE)}"
: "${ACCOUNT_ALIAS:?ACCOUNT_ALIAS not set (see $ENV_FILE)}"
: "${KUBECONFIG:?KUBECONFIG not set (see $ENV_FILE)}"
export AWS_REGION AWS_DEFAULT_REGION="$AWS_REGION" KUBECONFIG
threshold_min="${threshold_override:-${THRESHOLD_MIN:-120}}"
llm_port="${LLM_METRICS_PORT:-8000}"

mkdir -p "$STATE_DIR"
now=$(date +%s)

# API unreachable (booting, or broken): never stop on missing data.
if ! oc get --raw /readyz >/dev/null 2>&1; then
  log "cluster API not reachable -- not touching anything"
  exit 1
fi

# Signal: bastion boot.
boot=$(( now - $(cut -d. -f1 /proc/uptime) ))

# Signal: keepalive tag on this instance.
imds_token=$(curl -sf -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' http://169.254.169.254/latest/api/token)
self_id=$(curl -sf -H "X-aws-ec2-metadata-token: $imds_token" http://169.254.169.254/latest/meta-data/instance-id)
keepalive_until=$(aws ec2 describe-instances --instance-ids "$self_id" \
  --query "Reservations[0].Instances[0].Tags[?Key=='KeepAliveUntil'].Value | [0]" --output text)
case "$keepalive_until" in '' | None | *[!0-9]*) keepalive_until=0 ;; esac
keepalive=0
[ "$keepalive_until" -gt "$now" ] && keepalive="$now"

# Signal: LLM requests. Scrape vLLM /metrics through the API server's pod proxy
# (the bastion cannot reach pod IPs directly).
llm=0
llm_running=0
llm_total=0
llm_pods=$(oc get pods -A -l "$LLM_POD_SELECTOR" --field-selector=status.phase=Running \
  -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}')
for p in $llm_pods; do
  ns=${p%%/*}
  name=${p##*/}
  stats=$(oc get --raw "/api/v1/namespaces/$ns/pods/$name:$llm_port/proxy/metrics" 2>/dev/null |
    llm_stats_from_metrics) || stats="0 0"
  llm_running=$(( llm_running + ${stats% *} ))
  llm_total=$(( llm_total + ${stats#* } ))
done
prev_total=""
[ -f "$STATE_DIR/llm_total" ] && prev_total=$(cat "$STATE_DIR/llm_total")
# A counter that moved (or went backwards after a pod restart) means requests happened.
if [ "$llm_running" -gt 0 ] || { [ -n "$prev_total" ] && [ "$llm_total" != "$prev_total" ]; }; then
  llm="$now"
fi

# Signal: human changes in non-system namespaces.
human=0
for ns in $(oc get ns -o jsonpath='{.items[*].metadata.name}'); do
  if echo "$ns" | grep -Eq "$SYSTEM_NS_RE"; then continue; fi
  t=$(oc get pods,deployments.apps,statefulsets.apps,jobs.batch,configmaps,persistentvolumeclaims,routes.route.openshift.io \
    -n "$ns" -o json --show-managed-fields | latest_human_change_epoch)
  # Optional RHOAI kinds: absent until RHOAI is installed, so errors are expected.
  t2=$(oc get inferenceservices.serving.kserve.io,notebooks.kubeflow.org \
    -n "$ns" -o json --show-managed-fields 2>/dev/null | latest_human_change_epoch || echo 0)
  human=$(max_of "$human" "$t" "${t2:-0}")
done

# Signal: OAuth logins.
login=$(oc get oauthaccesstokens -o json | latest_login_epoch)

prev_active=0
[ -f "$STATE_DIR/last_active" ] && prev_active=$(cat "$STATE_DIR/last_active")
last_active=$(max_of "$prev_active" "$boot" "$keepalive" "$llm" "$human" "$login")
idle=$(idle_minutes "$now" "$last_active")

log "idle=${idle}m threshold=${threshold_min}m (boot=$(( (now - boot) / 60 ))m ago, keepalive=$([ "$keepalive" -gt 0 ] && echo on || echo off), llm_running=$llm_running llm_total=$llm_total, human_change=$([ "$human" -gt 0 ] && echo "$(( (now - human) / 60 ))m ago" || echo none), login=$([ "$login" -gt 0 ] && echo "$(( (now - login) / 60 ))m ago" || echo none))"

if [ "$dry_run" -eq 0 ]; then
  echo "$last_active" > "$STATE_DIR/last_active"
  echo "$llm_total" > "$STATE_DIR/llm_total"
fi

if [ "$idle" -lt "$threshold_min" ]; then
  exit 0
fi

# Idle long enough: stop everything else first, this bastion last.
others=$(aws ec2 describe-instances \
  --filters "Name=tag:AccountAlias,Values=${ACCOUNT_ALIAS}" "Name=tag:Project,Values=openshift-sno-ai" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].InstanceId' --output text | tr '\t' '\n' | grep -v "^${self_id}$" || true)

if [ "$dry_run" -eq 1 ]; then
  log "DRY RUN: would stop [$(echo "$others" | tr '\n' ' ')] then $self_id"
  exit 0
fi

if [ -n "$others" ]; then
  # shellcheck disable=SC2086
  aws ec2 stop-instances --instance-ids $others >/dev/null
  # shellcheck disable=SC2086
  aws ec2 wait instance-stopped --instance-ids $others
fi
log "stopped [$(echo "$others" | tr '\n' ' ')]; stopping bastion $self_id"
aws ec2 stop-instances --instance-ids "$self_id" >/dev/null
