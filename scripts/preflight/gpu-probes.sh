#!/usr/bin/env bash
# GPU feasibility probes for the SNO + OpenShift AI build. All read-only or
# dry-run; nothing is created. Probes:
#   offering - is the instance type offered in the subnet's AZ?
#   quota    - does the G/VT vCPU quota (L-DB2E81BA) cover the instance?
#   scp      - does run-instances --dry-run succeed (SCP may restrict types)?
#   egress   - (opt-in) can the bastion reach nvcr.io / registry.redhat.io?
# Exits non-zero if any probe is BLOCKED or INCONCLUSIVE.
set -euo pipefail

usage() {
  cat <<'EOF'
usage: gpu-probes.sh <region> <subnet-id> <instance-type> [--ami <ami-id>] [--egress <bastion-instance-id>]

  --ami     self-owned AMI for the dry-run (default: first AMI from --owners self)
  --egress  run a curl check through SSM on this instance (opt-in)
EOF
}

case "${1:-}" in -h | --help) usage; exit 0 ;; esac
[ $# -ge 3 ] || { usage >&2; exit 2; }

region="$1"; subnet_id="$2"; itype="$3"; shift 3
ami_id=""; bastion=""
while [ $# -gt 0 ]; do
  case "$1" in
    --ami) ami_id="${2:?--ami needs a value}"; shift 2 ;;
    --egress) bastion="${2:?--egress needs a value}"; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

# Static keys without a session token override AWS_PROFILE and fail with
# InvalidClientTokenId once stale; refuse to run rather than misreport.
if [ -n "${AWS_ACCESS_KEY_ID:-}" ] && [ -z "${AWS_SESSION_TOKEN:-}" ]; then
  echo "AWS_ACCESS_KEY_ID is set without a session token and overrides AWS_PROFILE." >&2
  echo "Run: unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY" >&2
  exit 2
fi
aws sts get-caller-identity --region "$region" >/dev/null || {
  echo "Not authenticated; run 'aws sso login'." >&2
  exit 2
}

overall_rc=0
pass() { echo "PASS                $1"; }
blocked() { echo "BLOCKED             $1"; overall_rc=1; }
inconclusive() { echo "INCONCLUSIVE        $1"; overall_rc=1; }

# --- offering ---
az=$(aws ec2 describe-subnets --region "$region" --subnet-ids "$subnet_id" \
  --query 'Subnets[0].AvailabilityZone' --output text)
offered=$(aws ec2 describe-instance-type-offerings --region "$region" \
  --location-type availability-zone \
  --filters "Name=instance-type,Values=$itype" "Name=location,Values=$az" \
  --query 'InstanceTypeOfferings[].InstanceType' --output text)
if [ -n "$offered" ]; then
  pass "offering  $itype offered in $az"
else
  blocked "offering  $itype NOT offered in $az"
fi

# --- quota ---
vcpus=$(aws ec2 describe-instance-types --region "$region" --instance-types "$itype" \
  --query 'InstanceTypes[0].VCpuInfo.DefaultVCpus' --output text 2>/dev/null || true)
quota=$(aws service-quotas get-service-quota --region "$region" --service-code ec2 \
  --quota-code L-DB2E81BA --query 'Quota.Value' --output text 2>/dev/null || true)
if [ -z "$vcpus" ] || [ "$vcpus" = "None" ] || [ -z "$quota" ] || [ "$quota" = "None" ]; then
  inconclusive "quota     could not read vCPUs ($vcpus) or quota ($quota)"
elif [ "${quota%.*}" -ge "$vcpus" ]; then
  pass "quota     G/VT quota ${quota%.*} >= $vcpus vCPUs"
else
  blocked "quota     G/VT quota ${quota%.*} < $vcpus vCPUs"
fi

# --- scp (dry-run) ---
if [ -z "$ami_id" ]; then
  ami_id=$(aws ec2 describe-images --region "$region" --owners self \
    --query 'Images[0].ImageId' --output text 2>/dev/null || true)
fi
if [ -z "$ami_id" ] || [ "$ami_id" = "None" ]; then
  inconclusive "scp       no self-owned AMI to dry-run with (build the RHCOS AMI first)"
else
  out=$(aws ec2 run-instances --region "$region" --dry-run --image-id "$ami_id" \
    --instance-type "$itype" --subnet-id "$subnet_id" 2>&1 || true)
  if echo "$out" | grep -q 'DryRunOperation'; then
    pass "scp       run-instances dry-run allowed ($itype, $ami_id)"
  elif echo "$out" | grep -qiE 'UnauthorizedOperation|AccessDenied|explicit deny'; then
    blocked "scp       run-instances denied: ${out//$'\n'/ }"
  else
    inconclusive "scp       ${out//$'\n'/ }"
  fi
fi

# --- egress (opt-in) ---
if [ -n "$bastion" ]; then
  # shellcheck disable=SC2016 # $u must expand on the bastion, not locally
  cmd_id=$(aws ssm send-command --region "$region" --instance-ids "$bastion" \
    --document-name AWS-RunShellScript \
    --parameters 'commands=["for u in https://nvcr.io/v2/ https://registry.redhat.io/v2/; do echo \"$u $(curl -s -o /dev/null -m 10 -w %{http_code} $u)\"; done"]' \
    --query 'Command.CommandId' --output text 2>&1) || cmd_id=""
  if [ -z "$cmd_id" ]; then
    inconclusive "egress    SSM send-command failed"
  else
    sleep 8
    res=$(aws ssm get-command-invocation --region "$region" --command-id "$cmd_id" \
      --instance-id "$bastion" --query 'StandardOutputContent' --output text 2>&1 || true)
    for u in nvcr.io registry.redhat.io; do
      code=$(echo "$res" | grep "$u" | awk '{print $2}')
      case "$code" in
        200 | 401) pass "egress    $u reachable (HTTP $code)" ;;
        "") inconclusive "egress    $u no result (SSM still running or failed)" ;;
        *) blocked "egress    $u HTTP $code" ;;
      esac
    done
  fi
else
  echo "SKIPPED             egress (pass --egress <bastion-instance-id> to run)"
fi

exit "$overall_rc"
