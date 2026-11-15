# POC results: Helm bundle for the OpenShift AI stack

Plan: `poc.md`. Fill in as each phase finishes. Status values: DONE (verified), OFFLINE-ONLY (written/rendered, not run on a cluster), PENDING, BLOCKED.
Rule: a phase is DONE only with evidence below. Last updated: 2026-11-15 (template created).

| Phase | Status | Date | Run by |
|---|---|---|---|
| 1 Operators chart on SNO | OFFLINE-ONLY | | |
| 2 Config chart on SNO (CPU) | OFFLINE-ONLY | | |
| 3 GPU + MIG chart (render) | OFFLINE-ONLY | | |
| 4 Air-gap + Fusion values | OFFLINE-ONLY | | |
| 5 GitOps (Argo CD) | OFFLINE-ONLY | | |
| 6 Transfer bundle (to/from air-gap) | OFFLINE-ONLY, scripts never run | | |
| 7 MIG on hardware | PENDING (no MIG GPU) | | |

## Phase 1: operators chart (SNO)
- Done offline: charts/rhoai-operators; helm lint + kubeconform green (sno, fusion) per user report.
- Pending: install on SNO, `oc get csv -A` all Succeeded.
- Evidence: _(paste)_

## Phase 2: config chart (SNO, CPU only)
- Done offline: charts/rhoai-config; lint/kubeconform green (sno-config, fusion-config).
- Pending: DSC Ready, MinIO Running, data connection, one inference request returns.
- Evidence: _(paste)_

## Phase 3: GPU + MIG (render-only)
- Done offline: `gpu:` block, ClusterPolicy, custom-mig-config, time-slicing option, node plan, Kueue queues; MIG+time-slicing render fails by design.
- UNVERIFIED: H200 profile names, ClusterPolicy required fields, Kueue apiVersion, driver version.
- Pending: review against NVIDIA docs; Fusion run (phase 7).
- Evidence: _(paste)_

## Phase 4: air-gap + Fusion values
- Done offline: charts/airgap-config, values/fusion*.yaml; mirror-path clash negative test fails as designed.
- UNVERIFIED: kinds/fields vs OCP 4.20, MCO reboot on mirror/CA change, RHOAI 3.4 channel name, Trident parameters.
- Pending: `--dry-run=server` on a 4.20 cluster or on Fusion.
- Evidence: _(paste)_

## Phase 5: GitOps
- Done offline: argocd/ (root + child Applications for sno and fusion, bootstrap GitOps Subscription, README).
- Pending: install GitOps operator, register repo, sync on SNO; adoption of hand-applied objects; check Application health ordering.
- Evidence: _(paste)_

## Phase 6: transfer bundle
- Done offline: scripts/to-airgap.sh, scripts/from-airgap.sh, docs/airgap.md (written; shellcheck and dry run not yet confirmed).
- Pending: run on a connected host, verify checksums, push to a registry with `--dry-run` first.
- Evidence: _(paste)_

## Phase 7: MIG on hardware
- Status: PENDING. Procedure: `docs/mig-hardware-checklist.md`. Evidence list: its section 7.
- Do not claim "MIG works" until: `nvidia-smi -L` shows MIG devices, a pod on `nvidia.com/mig-<profile>` ran, a KServe model answered on a slice, rollback tested.
- Evidence: _(paste)_

## Open items carried forward
UNVERIFIED lists are in `HANDOFF.md` and `charts/README.md`. Version gap: SNO OCP 4.22 / RHOAI 3.5 vs target OCP 4.20 / RHOAI 3.4.
