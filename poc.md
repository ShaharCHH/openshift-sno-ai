# POC: Helm bundle for the OpenShift AI stack (+ GPU MIG)

Status: DRAFT v0.1, 2026-11-15. Nothing in here has been built or run yet.
Source of truth for the target: `IBM fusion HCI/oscp-pai-architecture` (draft v0.8, air-gapped, Fusion HCI, 8x H200 NVL).

## Summary

Goal: one Helm "bundle" that installs everything OpenShift AI needs, in the right order, driven only by values files.
The same chart runs on my SNO (to prove it works) and on the Fusion HCI cluster (different values: air-gap catalogs, Trident storage, H200 GPUs).
Second goal: GPU partitioning with MIG (Multi-Instance GPU: one physical GPU split into hardware-isolated slices), configured by the same bundle.

The SNO has no MIG-capable GPU (g5 = A10G, no MIG; and g5 capacity was refused anyway). So the POC proves the bundle + CPU path on SNO, and proves MIG only at "renders and validates" level until MIG hardware exists. See "MIG reality check".

## Challenge to the plan (once)

1. **Helm is a poor fit for operators.** A Subscription creates CRDs *later*; a DataScienceCluster in the same release fails ("no matches for kind"). Fix: split into two charts (operators, then config) and order them with Argo CD sync waves (the architecture already decides ArgoCD) or Helm hooks. Why: Helm checks CRDs at render/install time, not after the operator lands.
2. **Version mismatch.** Target = OCP 4.20.28 + RHOAI 3.4.z. My SNO = OCP 4.22.9 + RHOAI 3.5.2. A chart green on SNO does not prove it on 4.20 / 3.4. I keep versions as values, and the Fusion values file is the one that counts.
3. **MIG can't be proven on my SNO** (above). Don't let "MIG works" appear in the POC result unless it ran on real hardware.

## Scope

In (bundle contents, from architecture docs 06/07):

| Layer | Component | Needed for |
|---|---|---|
| Prereq operators | cert-manager, Node Feature Discovery, Red Hat build of Kueue | KServe/Kueue, GPU labeling, quotas |
| GPU | NVIDIA GPU Operator 25.10.x + ClusterPolicy, MIG config | drivers, device plugin, MIG slicing |
| RHOAI | operator, DSCInitialization, DataScienceCluster (dashboard, workbenches, kserve, pipelines, model registry, kueue) | the platform |
| RHOAI deps | S3 (MinIO on POC, StorageGRID/ONTAP S3 on Fusion), MySQL (model registry), default StorageClass | serving, pipelines, registry |
| Air-gap glue | CatalogSource, ImageDigestMirrorSet, trusted CA bundle | Fusion only |

Out of POC (decided later): llm-d, Run:ai, Llama Stack/Service Mesh 3, LiteLLM/MaaS, Langfuse/OTel/Tempo, Trident, Fusion data layer, Alteon, backup. Each is an optional subchart later, not phase 1.

## Proposed layout (new directory, no refactor of existing day2/ scripts)

```
charts/
  rhoai-operators/        # wave 0: Namespaces, OperatorGroups, Subscriptions (cert-manager, NFD, Kueue, GPU op, RHOAI)
  rhoai-config/           # wave 1+: NFD instance, ClusterPolicy (+MIG), DSCI, DSC, S3, MySQL, data connection
  values/
    sno.yaml              # m5.2xlarge, CPU only, MinIO, LVMS, minimal DSC (what already works)
    fusion.yaml           # air-gap catalog, RHOAI 3.4, H200, MIG on, trident-nfs / trident-iscsi, external S3
    mig-test.yaml         # small MIG profile set for a rented/loaned MIG GPU
argocd/                   # app-of-apps with sync waves (phase 4)
docs/poc-results.md       # filled in as phases finish
```

Reuses what exists: `manifests/rhoai/*.yaml` and `day2/install-rhoai.sh` become the templates (the `config.resources` CPU trims move into `values/sno.yaml`).

## Phases

1. **Operators chart on SNO.** Wrap the existing Subscriptions + add cert-manager, NFD, Kueue. Done when: all CSVs Succeeded. (`helm template` + `kubeconform` before touching the cluster.)
2. **Config chart on SNO, CPU only.** DSCI, DSC, MinIO, data connection, one tiny model served on CPU. Done when: one inference request returns. This also finishes the earlier trim-CPU / MinIO / model work.
3. **GPU + MIG chart (render-only on SNO).** NFD rule, ClusterPolicy with `mig.strategy`, mig-parted config as a ConfigMap, node label `nvidia.com/mig.config`. Done when: `helm template -f values/fusion.yaml` is valid and reviewed against the NVIDIA GPU Operator docs.
4. **Air-gap + Fusion values.** Catalog/mirror templates, CA bundle, Trident classes, RHOAI 3.4 channel. Test with `--dry-run=server` against any 4.20 cluster, or on Fusion when available.
5. **GitOps.** Argo CD app-of-apps with sync waves; same values files.
6. **MIG on hardware** (only when a MIG GPU is available): apply, `nvidia-smi -L` shows slices, a pod requests `nvidia.com/mig-<profile>`, KServe model lands on a slice.

## MIG reality check

- MIG needs A100/A30/H100/H200-class GPUs. A10G (g5) and T4 do not support it.
- Options to get hardware: (a) wait for the Fusion H200 node (best, real target); (b) short-lived AWS p4d/p5 instance, but the SCP limits me to il-central-1 and capacity is doubtful and expensive; (c) skip and stay render-only.
- Recommendation: (c) now, (a) for the real test. Why: cheapest honest path; a rented p5 for a few hours buys little over the real node.
- Architecture notes to carry in: H200 NVL is PCIe with 2/4-way NVLink bridges (not NVSwitch); MIG vs time-slicing vs whole-GPU split is an open decision (open item 8). The chart should let some GPUs be sliced and others whole (per-node `mig.config` label), so the decision stays a values change.
- Rebooting/reconfiguring a GPU for MIG can drain the node. The Fusion GPU node is single, so schedule it before workloads go live.

## Tools and access I need (tell me what's missing)

| Need | For | Have? |
|---|---|---|
| `helm` 3.x | author/render charts | unverified |
| `kubeconform`, `helm-unittest`, `shellcheck` | validate without a cluster | unverified |
| `oc`, working tunnel to SNO | install tests | yes (needs SSO + wake) |
| Argo CD (OpenShift GitOps operator) | phase 5 | not installed on SNO |
| `oc-mirror` + `skopeo` + Artifactory path | air-gap mirror (RHOAI 3.4 set is ~75 GB, 100 GB free on mirror host) | Fusion side, TBC |
| Red Hat pull secret | operator images | yes (SNO) |
| NVIDIA NGC key / NVAIE entitlement | GPU Operator images, NVAIE 7.5 | TBC (open item 2) |
| MIG-capable GPU | phase 6 | no |
| RHOAI 3.4 channel name in the catalog | Fusion values | unverified; check `oc get packagemanifest rhods-operator` |

## Risks

- CRD ordering and operator reconcile races (the two-chart split + waves is the mitigation).
- Operators revert resource tweaks (the trim script already hit this question; unverified).
- 3.4 vs 3.5 API differences (e.g. DSC v2 shape) may force per-version templates.
- Egress from SNO to quay.io / Hugging Face untested.
- Fusion specifics (who owns OCP upgrades, Artifactory acceptance, provisioning) sit with IBM, not in my control.

## Decisions I'm assuming (shout if wrong)

1. Bundle = umbrella of two charts (operators, config), not one monolith.
2. "MIG" = NVIDIA Multi-Instance GPU (not the Migration Toolkit).
3. Work happens in this repo on a new branch off main; nothing is committed until you say so.
4. SNO stays on m5.2xlarge; GPU retry stays a separate step.

## What I need to run myself

Nothing yet. Phase 1 needs: `aws sso login --profile <your-sso-profile>`, then `./scripts/wake.sh -a sno` and the tunnel. `helm install` / `oc apply` steps will come as one paste-ready block.
