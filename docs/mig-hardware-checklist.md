# MIG on hardware: checklist (phase 7, Fusion H200 node)

Status: cannot be run yet (no MIG-capable GPU available). Nothing below has been executed; every command is a plan.
Record results in `docs/poc-results.md` (phase 7). Chart background: `charts/README.md` ("GPU and MIG").
Rule: "MIG works" goes into the POC result only with the evidence from section 7.

Conventions: `NODE` = the GPU node name, `NS=nvidia-gpu-operator`. Run on a machine with `oc` and cluster-admin.

    export NODE=<gpu-node-name>; export NS=nvidia-gpu-operator
    oc whoami; oc config current-context      # confirm the cluster first

## 0. Before the window (needs you)

- [ ] Maintenance window agreed: the single GPU node may drain or reboot (section 4). No live workloads on it.
- [ ] `airgap-config`, `rhoai-operators` applied; all CSVs Succeeded; `rhoai-config` applied with `gpu.enabled=true` (fusion-config).
- [ ] Decision on strategy recorded: `gpu.mig.strategy` single or mixed (architecture open item 8).

## 1. Pre-flight

    oc get node $NODE --show-labels | tr ',' '\n' | grep -E 'nvidia|gpu|feature.node'
    oc describe node $NODE | grep -A3 -i taints          # expect nvidia.com/gpu=present:NoSchedule if the node plan was applied
    oc get clusterpolicy                                 # state: ready
    oc get pods -n $NS                                   # driver, toolkit, device-plugin, dcgm-exporter, mig-manager Running; validator Completed
    oc get node $NODE -o jsonpath='{.metadata.labels.nvidia\.com/gpu\.present}{"\n"}{.metadata.labels.nvidia\.com/mig\.capable}{"\n"}'   # true / true (UNVERIFIED label names)

Run nvidia-smi inside the driver pod (pod name from `oc get pods -n $NS -l app=nvidia-driver-daemonset`):

    DRV=$(oc get pods -n $NS -l app=nvidia-driver-daemonset -o name | head -1)
    oc exec -n $NS $DRV -- nvidia-smi -L                 # 8 x H200 expected (or the count on this node)
    oc exec -n $NS $DRV -- nvidia-smi mig -lgip          # REAL profile names and counts per GPU

- [ ] **Fix the names.** Compare `-lgip` output with the `# UNVERIFIED` names and edit them everywhere:
  `charts/rhoai-config/values.yaml` (`gpu.mig.profiles`: `1g.18gb`, `3g.71gb`, `1g.35gb`; `gpu.kueue.clusterQueue.migSlices`)
  and `charts/values/fusion-config.yaml` if it overrides them. Remove the `# UNVERIFIED` comment only on names you saw.
- [ ] Check mig-parted rules: the instance counts per GPU must be valid (e.g. 7 x 1g, 2 x 3g). If `-lgip` shows fewer, fix the profile.
- [ ] Record `nvidia-smi` driver version and GPU Operator CSV version for the results file.
- [ ] Re-render and review: `helm template rhoai-config charts/rhoai-config -f charts/values/fusion-config.yaml --set s3.accessKey=x --set s3.secretKey=xxxxxxxx | grep -A30 custom-mig-config`

## 2. Apply order

1. Commit the corrected profile names (on a branch; PR as usual).
2. `strategy` must be set in the ClusterPolicy before labelling the node: `helm upgrade rhoai-config charts/rhoai-config -f charts/values/fusion-config.yaml ... --set gpu.mig.strategy=mixed` (or Argo sync). Check `oc get clusterpolicy -o jsonpath='{.items[0].spec.mig.strategy}'` and the `custom-mig-config` ConfigMap exists in `$NS`.
3. Wait until `oc get clusterpolicy` is `ready` again and pods are Running.
4. Review, then run the rendered node plan (labels/taint; Helm never edits Nodes): `oc get cm gpu-node-plan -n <release ns> -o jsonpath='{.data.apply\.sh}'`.

## 3. Set the MIG config

    oc label node $NODE nvidia.com/mig.config=h200-half-whole-half-small --overwrite      # profile name from gpu.mig.profiles
    oc get node $NODE -L nvidia.com/mig.config,nvidia.com/mig.config.state -w             # watch

State values: `pending` -> `rebooting` (if it reboots) -> `success`. `failed` = stop, go to section 6. Logs:

    oc logs -n $NS -l app=nvidia-mig-manager -c nvidia-mig-manager --tail=100 -f

## 4. Expected disruption (single GPU node)

- MIG Manager evicts GPU clients (device plugin, DCGM exporter, validator, any GPU pods), resets the GPUs, restarts them. On a bare-metal node a reboot is not normally needed; if the driver reports "pending reset" it is.
  UNVERIFIED for H200 on this stack. With a reboot the node goes NotReady for minutes; `oc get node $NODE -w`.
- Do NOT change the label again while `state` is `pending`/`rebooting`.
- Workloads on this node are down during the change. Confirm none are scheduled: `oc get pods -A -o wide --field-selector spec.nodeName=$NODE`.

## 5. Verify

    oc exec -n $NS $DRV -- nvidia-smi -L                        # lists MIG devices (MIG 1g.18gb Device 0: ...) under GPUs 4-7, whole GPUs 0-3
    oc get node $NODE -o jsonpath='{.status.allocatable}' | tr ',' '\n' | grep nvidia      # nvidia.com/gpu and nvidia.com/mig-<profile> (mixed) counts

Test pod on a slice (replace the profile with a name that appeared above; image must be mirrored on Fusion):

    cat <<'EOF' | oc apply -f -
    apiVersion: v1
    kind: Pod
    metadata: {name: mig-smoke, namespace: rhoai-poc}
    spec:
      restartPolicy: Never
      tolerations: [{key: nvidia.com/gpu, operator: Exists, effect: NoSchedule}]
      containers:
      - name: smi
        image: <mirrored cuda base image>   # PLACEHOLDER, e.g. nvidia/cuda ...
        command: [nvidia-smi, -L]
        resources: {limits: {nvidia.com/mig-1g.18gb: 1}}   # UNVERIFIED name
    EOF
    oc logs -n rhoai-poc mig-smoke      # exactly one MIG device
    oc delete pod -n rhoai-poc mig-smoke

- [ ] KServe model on a slice: set `serving.runtime` GPU resource to `nvidia.com/mig-<profile>: 1` (add `limits` in the ServingRuntime/InferenceService), deploy, send one inference request, confirm with `nvidia-smi` that memory is used on that MIG device.
- [ ] Kueue (if `gpu.kueue.enabled`): a Workload using the slice is admitted by `gpu-cq`: `oc get workload,clusterqueue`.
- [ ] DCGM metrics: `oc get svc,servicemonitor -n $NS | grep dcgm`; `oc port-forward -n $NS svc/nvidia-dcgm-exporter 9400` then `curl -s localhost:9400/metrics | grep -E 'DCGM_FI_DEV_GPU_UTIL.*GPU_I_ID'` (per-instance labels = MIG visible). UNVERIFIED service name.

## 6. Rollback

    oc label node $NODE nvidia.com/mig.config=all-disabled --overwrite
    oc get node $NODE -L nvidia.com/mig.config.state -w        # wait for success
    oc exec -n $NS $DRV -- nvidia-smi -L                        # whole GPUs again

If `state=failed` or the node does not return: collect `oc logs -n $NS -l app=nvidia-mig-manager`, `oc describe node $NODE`,
then `oc debug node/$NODE -- chroot /host nvidia-smi` and, last resort, ask IBM/Fusion support for a node reboot. Do not delete the ClusterPolicy.
Then set `gpu.mig.strategy=none` in values (git) so Argo/Helm does not re-apply MIG.

## 7. Evidence to capture (paste into `docs/poc-results.md`, phase 7)

- [ ] Date, who ran it, OCP and GPU Operator versions, driver version.
- [ ] `nvidia-smi -L` before and after; `nvidia-smi mig -lgip` output (this is the proof of the real profile names).
- [ ] Time-line: label set time, state transitions, whether the node rebooted, total downtime.
- [ ] `oc get node -o jsonpath` allocatable (mig resources), the test pod output, the KServe request/response (no secrets), DCGM metric sample.
- [ ] Corrected profile names and the commit/PR that fixed them; remaining UNVERIFIED items.
- [ ] Rollback tested (yes/no).
