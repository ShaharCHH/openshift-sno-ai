#!/usr/bin/env bash
# Pauses (or resumes) the bastion's idle auto-shutdown from your laptop by
# setting an EC2 tag on the bastion: KeepAliveUntil=<epoch>. The idle check
# reads it, so no SSM session is needed, and it expires by itself.
#   keepalive.sh -a sno on [--hours N]   (default 4)
#   keepalive.sh -a sno off
#   keepalive.sh -a sno status
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
# shellcheck source=lib/read-tfvars.sh
source "$repo_root/scripts/lib/read-tfvars.sh"

usage() {
  echo "usage: keepalive.sh -a <account-alias> on [--hours N] | off | status" >&2
  exit 1
}

account_alias=""
while [ $# -gt 0 ]; do
  case "$1" in
    -a) account_alias="${2:-}"; shift 2 ;;
    *) break ;;
  esac
done
[ -n "$account_alias" ] && [ $# -ge 1 ] || usage
action="$1"
shift

hours=4
while [ $# -gt 0 ]; do
  case "$1" in
    --hours) hours="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done
case "$hours" in '' | *[!0-9]*) usage ;; esac

tfvars="$repo_root/accounts/${account_alias}.tfvars"
[ -f "$tfvars" ] || { echo "ERROR: $tfvars not found." >&2; exit 1; }
region=$(read_tfvar aws_region "$tfvars")
[ -n "$region" ] || { echo "ERROR: aws_region not set in $tfvars" >&2; exit 1; }

# The bastion can be stopped or running; its tag is what matters.
bastion=$(aws ec2 describe-instances --region "$region" \
  --filters "Name=tag:AccountAlias,Values=${account_alias}" "Name=tag:Project,Values=openshift-sno-ai" \
            "Name=tag:Name,Values=*-bastion" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].InstanceId' --output text)
[ -n "$bastion" ] && [ "$(echo "$bastion" | wc -w)" -eq 1 ] || {
  echo "ERROR: expected exactly one bastion for account-alias=${account_alias}, found: '${bastion}'" >&2
  exit 1
}

case "$action" in
  on)
    until=$(( $(date +%s) + hours * 3600 ))
    aws ec2 create-tags --region "$region" --resources "$bastion" --tags "Key=KeepAliveUntil,Value=${until}"
    echo "Auto-shutdown paused for ${hours}h (until $(date -r "$until" '+%Y-%m-%d %H:%M %Z'))."
    ;;
  off)
    aws ec2 delete-tags --region "$region" --resources "$bastion" --tags "Key=KeepAliveUntil"
    echo "Keepalive removed; auto-shutdown is active again."
    ;;
  status)
    until=$(aws ec2 describe-instances --region "$region" --instance-ids "$bastion" \
      --query "Reservations[0].Instances[0].Tags[?Key=='KeepAliveUntil'].Value | [0]" --output text)
    case "$until" in
      '' | None | *[!0-9]*) echo "No keepalive set; auto-shutdown is active." ;;
      *)
        if [ "$until" -gt "$(date +%s)" ]; then
          echo "Keepalive ON until $(date -r "$until" '+%Y-%m-%d %H:%M %Z')."
        else
          echo "Keepalive expired at $(date -r "$until" '+%Y-%m-%d %H:%M %Z'); auto-shutdown is active."
        fi
        ;;
    esac
    ;;
  *) usage ;;
esac
