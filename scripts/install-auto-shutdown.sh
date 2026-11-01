#!/usr/bin/env bash
# Installs the idle auto-shutdown on the bastion (run from your laptop):
#   1. applies day2/auto-shutdown/rbac.yaml (read-only ServiceAccount) to the cluster
#   2. pushes idle-check.sh, a kubeconfig for that ServiceAccount, the env file and a
#      systemd timer (every 15 min) to the bastion over SSM
# Needs: AWS credentials, a working `oc` session as cluster-admin (tunnel up),
# and the terraform apply that adds the bastion's ec2:StopInstances policy.
# Safe to re-run (it overwrites the same files).
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
# shellcheck source=lib/read-tfvars.sh
source "$repo_root/scripts/lib/read-tfvars.sh"

usage() {
  echo "usage: install-auto-shutdown.sh -a <account-alias> [--threshold-min N]" >&2
  exit 1
}

account_alias=""
threshold_min=120
while [ $# -gt 0 ]; do
  case "$1" in
    -a) account_alias="${2:-}"; shift 2 ;;
    --threshold-min) threshold_min="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$account_alias" ] || usage
case "$threshold_min" in '' | *[!0-9]*) usage ;; esac

tfvars="$repo_root/accounts/${account_alias}.tfvars"
[ -f "$tfvars" ] || { echo "ERROR: $tfvars not found." >&2; exit 1; }
region=$(read_tfvar aws_region "$tfvars")
[ -n "$region" ] || { echo "ERROR: aws_region not set in $tfvars" >&2; exit 1; }

admin_kubeconfig="$repo_root/.ignition/${account_alias}/auth/kubeconfig"
[ -f "$admin_kubeconfig" ] || { echo "ERROR: $admin_kubeconfig not found." >&2; exit 1; }
export KUBECONFIG="$admin_kubeconfig"
oc whoami >/dev/null || { echo "ERROR: cannot reach the cluster (is the tunnel up?)" >&2; exit 1; }

bastion=$(aws ec2 describe-instances --region "$region" \
  --filters "Name=tag:AccountAlias,Values=${account_alias}" "Name=tag:Project,Values=openshift-sno-ai" \
            "Name=tag:Name,Values=*-bastion" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].InstanceId' --output text)
[ -n "$bastion" ] && [ "$(echo "$bastion" | wc -w)" -eq 1 ] || {
  echo "ERROR: expected exactly one running bastion, found: '${bastion}'" >&2
  exit 1
}

echo "==> applying read-only RBAC to the cluster"
oc apply -f "$repo_root/day2/auto-shutdown/rbac.yaml"

echo "==> waiting for the ServiceAccount token"
token=""
for _ in $(seq 1 30); do
  token=$(oc -n sno-idle-check get secret idle-check-token -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)
  [ -n "$token" ] && break
  sleep 2
done
[ -n "$token" ] || { echo "ERROR: token never appeared" >&2; exit 1; }

# kubeconfig for the ServiceAccount, built in a private temp dir; contains a
# credential, so it is never printed and the dir is removed on exit.
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
server=$(oc config view --raw --minify -o jsonpath='{.clusters[0].cluster.server}')
oc config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d > "$work/ca.crt"
sa_kc="$work/kubeconfig"
oc --kubeconfig "$sa_kc" config set-cluster sno --server "$server" --certificate-authority "$work/ca.crt" --embed-certs=true >/dev/null
oc --kubeconfig "$sa_kc" config set-credentials idle-check --token "$token" >/dev/null
oc --kubeconfig "$sa_kc" config set-context sno --cluster sno --user idle-check >/dev/null
oc --kubeconfig "$sa_kc" config use-context sno >/dev/null

b64() { base64 < "$1" | tr -d '\n'; }

cat > "$work/env" <<ENVEOF
AWS_REGION=${region}
ACCOUNT_ALIAS=${account_alias}
KUBECONFIG=/etc/sno-auto-shutdown.kubeconfig
THRESHOLD_MIN=${threshold_min}
ENVEOF

cat > "$work/service" <<'UNITEOF'
[Unit]
Description=Stop the SNO cluster when idle

[Service]
Type=oneshot
ExecStart=/usr/local/bin/sno-idle-check.sh
UNITEOF

cat > "$work/timer" <<'UNITEOF'
[Unit]
Description=Check SNO idleness every 15 minutes

[Timer]
OnBootSec=15min
OnUnitActiveSec=15min

[Install]
WantedBy=timers.target
UNITEOF

cat > "$work/remote.sh" <<REMOTEEOF
set -euo pipefail
command -v jq >/dev/null || dnf install -y jq
echo '$(b64 "$repo_root/day2/auto-shutdown/idle-check.sh")' | base64 -d > /usr/local/bin/sno-idle-check.sh
chmod 755 /usr/local/bin/sno-idle-check.sh
echo '$(b64 "$work/env")' | base64 -d > /etc/sno-auto-shutdown.env
echo '$(b64 "$sa_kc")' | base64 -d > /etc/sno-auto-shutdown.kubeconfig
chmod 600 /etc/sno-auto-shutdown.kubeconfig
echo '$(b64 "$work/service")' | base64 -d > /etc/systemd/system/sno-auto-shutdown.service
echo '$(b64 "$work/timer")' | base64 -d > /etc/systemd/system/sno-auto-shutdown.timer
systemctl daemon-reload
systemctl enable --now sno-auto-shutdown.timer
echo "--- dry run:"
/usr/local/bin/sno-idle-check.sh --dry-run
REMOTEEOF

echo "==> installing on bastion ${bastion} via SSM"
params="$work/params.json"
jq -n --rawfile s "$work/remote.sh" '{commands: [$s]}' > "$params"
cmd_id=$(aws ssm send-command --region "$region" --instance-ids "$bastion" \
  --document-name AWS-RunShellScript --parameters "file://$params" \
  --query Command.CommandId --output text)
aws ssm wait command-executed --region "$region" --command-id "$cmd_id" --instance-id "$bastion" || true
aws ssm get-command-invocation --region "$region" --command-id "$cmd_id" --instance-id "$bastion" \
  --query '[Status,StandardOutputContent,StandardErrorContent]' --output text
status=$(aws ssm get-command-invocation --region "$region" --command-id "$cmd_id" --instance-id "$bastion" \
  --query Status --output text)
[ "$status" = "Success" ] || { echo "ERROR: remote install status: $status" >&2; exit 1; }
echo "Installed. Timer runs every 15 min; threshold ${threshold_min} min."
