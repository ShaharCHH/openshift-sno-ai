# Auto-shutdown

A timer on the bastion runs `day2/auto-shutdown/idle-check.sh` every 15 minutes.
If the cluster has shown no activity for `THRESHOLD_MIN` minutes (default 120),
it stops every instance of the deployment -- the same end state as
`scripts/hibernate.sh` -- master(s) first, the bastion last. EBS volumes keep
billing while stopped; this saves compute only.

## What counts as activity

The idle clock is `now - newest of`:

| Signal | How it is read | Notes |
| --- | --- | --- |
| Bastion boot | `/proc/uptime` | `wake.sh` boots the bastion, so waking restarts the clock |
| Keepalive | `KeepAliveUntil` tag on the bastion | `scripts/keepalive.sh` |
| LLM use | vLLM `/metrics` via the API pod proxy: `num_requests_running` > 0, or `request_success_total` changed since the last check | A merely *running* model pod is not activity. No vLLM pod = no signal. |
| Human change | `managedFields` manager `kubectl*`, `oc`, `Mozilla*` (console), `helm*` on pods, deployments, statefulsets, jobs, configmaps, PVCs, routes, InferenceServices, Notebooks in non-system namespaces | Operators, kubelet and controllers use their own manager names and are ignored. Namespaces `openshift*`, `kube-*`, `default` are skipped. |
| Login | newest `oauthaccesstokens` creation | |

Not detected: read-only browsing (`oc get`, console tabs) with no changes and no
login. Use `keepalive.sh` for that. A vLLM pod restart resets its counter and
counts as one burst of activity.

If the cluster API is unreachable the check exits non-zero and stops nothing.

## Use

```sh
# pause auto-shutdown from your laptop (tag on the bastion; expires by itself)
./scripts/keepalive.sh -a sno on --hours 6
./scripts/keepalive.sh -a sno status
./scripts/keepalive.sh -a sno off

# on the bastion (SSM): see what it would decide, without stopping anything
sudo /usr/local/bin/sno-idle-check.sh --dry-run
# try a short threshold for real (this WILL stop the cluster if idle that long)
sudo /usr/local/bin/sno-idle-check.sh --threshold-min 1

journalctl -u sno-auto-shutdown.service -n 20   # past decisions
systemctl list-timers sno-auto-shutdown.timer
```

## Install / change the threshold

1. `terraform apply` -- adds the bastion's `ec2:StopInstances` policy (only on
   instances tagged `Project=openshift-sno-ai`).
2. `./scripts/install-auto-shutdown.sh -a sno [--threshold-min 120]` -- applies
   `rbac.yaml` (read-only ServiceAccount), then installs the script, a
   ServiceAccount kubeconfig, the env file and the timer on the bastion. Re-run
   it to change the threshold.

On a rebuild, re-run step 2 (the bastion is new).

## Tests

`day2/auto-shutdown/test-idle-check.sh` checks the parsing and decision helpers
offline against canned vLLM metrics and `managedFields`.
