# Helm bundle for OpenShift AI

Two charts for the SNO, applied in order (a Subscription creates CRDs later, so config cannot ship in the same release); a third, `airgap-config/`, goes first on Fusion only:

- `airgap-config/` (wave -30..-20, Fusion only): mirrored CatalogSources, image mirror sets, CA trust, Trident StorageClasses.
- `rhoai-operators/` (wave 0): Namespaces, OperatorGroups, Subscriptions for cert-manager, NFD, Kueue, NVIDIA GPU Operator, RHOAI.
- `rhoai-config/` (wave 3+): NFD instance, DSCInitialization, DataScienceCluster, data science project, MinIO, S3 data connection, optional MySQL (model registry), optional tiny CPU model. GPU ClusterPolicy/MIG is phase 3.

Overlays in `values/`: `sno.yaml` + `sno-config.yaml` (connected, CPU only), `fusion.yaml` + `fusion-config.yaml` + `fusion-airgap.yaml` (air-gap, RHOAI 3.4).
Each chart gets its own overlay because Helm values are per release. Anything marked `# UNVERIFIED` could not be confirmed offline.

## Render and validate (offline)

    helm lint charts/rhoai-operators -f charts/values/sno.yaml
    helm template rhoai-operators charts/rhoai-operators -f charts/values/sno.yaml
    helm template rhoai-operators charts/rhoai-operators -f charts/values/fusion.yaml
    helm lint charts/rhoai-config -f charts/values/sno-config.yaml
    helm template rhoai-config charts/rhoai-config -f charts/values/sno-config.yaml | kubeconform -strict -ignore-missing-schemas -summary
    # fusion needs S3 keys (placeholders here, real ones from an untracked file):
    helm template rhoai-config charts/rhoai-config -f charts/values/fusion-config.yaml \
      --set s3.accessKey=x --set s3.secretKey=xxxxxxxx

kubeconform has no schema for OLM/RHOAI kinds by default, hence `-ignore-missing-schemas`.

## GPU and MIG (phase 3, render-only)

Lives in `rhoai-config` under the `gpu:` value block (not a new chart): it needs the same release timing
(after the GPU Operator and NFD CSVs), the same Argo waves (`syncWaves.gpu` 4, `gpuQueues` 8), and one switch
(`gpu.enabled`) is enough. On in `values/fusion-config.yaml`, off in `values/sno-config.yaml` (no GPU there).
Nothing here has run on hardware; the SNO has no MIG-capable GPU.

Templates: `gpu-clusterpolicy.yaml` (ClusterPolicy: driver, toolkit, devicePlugin, dcgm/dcgmExporter, gfd, migManager,
`mig.strategy`), `gpu-configmaps.yaml` (`custom-mig-config`, optional `time-slicing-config`, optional driver repo/CA
ConfigMaps), `gpu-nodes-and-queues.yaml` (node label/taint plan, Kueue ResourceFlavors/ClusterQueue/LocalQueue).
Air-gap: `gpu.repository`, per-component `repository/image/version`, `gpu.imagePullSecrets`, `gpu.driver.repoConfig`,
`gpu.driver.certConfig`. No public registry is hardcoded; empty means the operator default (mirrored via IDMS).

The three-way decision (open item 8) is a values change:

| Choice | Values |
|---|---|
| whole GPU | `gpu.mig.strategy: none`, `gpu.timeSlicing.enabled: false` |
| MIG | `gpu.mig.strategy: single` (one profile on every GPU) or `mixed` (several / some GPUs whole) |
| time-slicing | `gpu.mig.strategy: none`, `gpu.timeSlicing.enabled: true`, `gpu.timeSlicing.replicas: N` |

MIG plus time-slicing together fails the render on purpose. A node picks its profile with the label
`nvidia.com/mig.config=<profile>` (profiles are `gpu.mig.profiles`); example profiles keep GPUs 0-3 whole and slice 4-7.
Node labels and the `nvidia.com/gpu:NoSchedule` taint are NOT applied by Helm (it should not own Node objects):
set `gpu.nodes` and the chart renders a ConfigMap `gpu-node-plan` with an `apply.sh` for you to review and run.
Kueue: flavor `gpu-whole` (resource `nvidia.com/gpu`) and `gpu-mig` (resources `nvidia.com/mig-<profile>`, which exist
only with `mixed`; under `single` the slices appear as `nvidia.com/gpu`).

**Operational caveat:** changing `nvidia.com/mig.config` makes MIG Manager evict GPU pods, reset the GPU and possibly
reboot the node. Fusion has one GPU node, so apply the MIG config before workloads go live and never change it live.

Verified vs not: only offline rendering (see below). UNVERIFIED: every H200 profile name (`1g.18gb`, `1g.35gb`,
`3g.71gb`; confirm with `nvidia-smi mig -lgip`), driver version, ClusterPolicy required sections, Kueue API version.
Sources used: NVIDIA GPU Operator "GPU Operator with MIG" page (docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/gpu-operator-mig.html):
confirms `custom-mig-config` key `config.yaml`, `spec.migManager.config.name`, `spec.mig.strategy`, label
`nvidia.com/mig.config`, state label `nvidia.com/mig.config.state`. It names H100/A100 profiles only, not H200.

    helm template rhoai-config charts/rhoai-config -f charts/values/fusion-config.yaml \
      --set s3.accessKey=x --set s3.secretKey=xxxxxxxx | kubeconform -strict -ignore-missing-schemas -summary
    helm template rhoai-config charts/rhoai-config -f charts/values/fusion-config.yaml \
      --set s3.accessKey=x --set s3.secretKey=xxxxxxxx --set gpu.mig.strategy=none --set gpu.timeSlicing.enabled=true

## Air-gap layer (phase 4, render-only): `airgap-config/`

A third chart, not an extension of `rhoai-config`, because the timing is opposite: it must be applied BEFORE
`rhoai-operators` (the Subscriptions resolve from its CatalogSources, and image pulls need its mirror sets and CA
trust), while `rhoai-config` is applied after. Helm values and releases are per chart, so mixing them would force
one release to be both first and last. It is only used on Fusion (`values/fusion-airgap.yaml`); the SNO never installs it.

| Template | Renders | Value block |
|---|---|---|
| `catalogs.yaml` | CatalogSource per mirrored index; OperatorHub `cluster` with `disableAllDefaultSources` | `catalogs`, `operatorHub` |
| `mirrors.yaml` | ImageDigestMirrorSet + ImageTagMirrorSet from `{source, mirrors[]}` lists | `mirrors` |
| `trust.yaml` | CA ConfigMap in `openshift-config` + Proxy `trustedCA`; registry CA ConfigMap + Image `additionalTrustedCA`; S3 endpoint CA; optional cert-manager `ClusterIssuer`; optional APIServer/IngressController named certs | `trust`, `issuer`, `namedCerts` |
| `storage.yaml` | StorageClasses `trident-nfs` (default) and `trident-iscsi` | `storage` |

- Open item 3: each upstream needs its own Artifactory path prefix. The render FAILS when two different sources share a mirror path.
  `mirrorSourcePolicy` defaults to `NeverContactSource`. No registry host is hardcoded; the values file holds `example.internal` placeholders.
- Open item 15: the ClusterIssuer is off and marked TBC. The CA key Secret, the named-cert TLS Secrets and all PEM text are
  supplied by you (`--set-file`, untracked file), never committed. The ClusterIssuer needs cert-manager CRDs, so enable it
  in a second `helm upgrade` after `rhoai-operators` (Argo wave 3).
- Storage: only the StorageClass objects. Trident itself and its backend CRs (TridentBackendConfig, credentials) are OUT OF SCOPE.
  Default class is a value (`storage.defaultClassName`); un-default the previous default yourself:
  `oc annotate sc <old> storageclass.kubernetes.io/is-default-class-`. Workbench/model PVCs take the default (trident-nfs);
  MySQL names `trident-iscsi` in `values/fusion-config.yaml`.
- Singletons (OperatorHub, Proxy, Image config, APIServer, IngressController `default`) already exist. Helm will refuse
  them until adopted (same three markers as `adopt-existing.sh`; that script does NOT cover them yet). Safer for these: render, review, and `oc apply` by hand or use Argo `ServerSideApply`.
- Changing mirror sets or the Proxy/Image CA makes the Machine Config Operator update nodes; reboot/drain behaviour on 4.20 is UNVERIFIED. Use a maintenance window.
- oc-mirror writes its own `idms-*.yaml` / `cs-*.yaml`; copy their content into the values rather than guessing names.

Verified: nothing beyond offline rendering (and only if you ran the commands below). UNVERIFIED: every kind/field against 4.20
(Image `additionalTrustedCA` key format `host..port`, OperatorHub fields, Trident provisioner and `backendType` parameter,
cert-manager `secretNamespace`, S3 CA consumers).

    helm lint charts/airgap-config -f charts/values/fusion-airgap.yaml --set trust.caBundle=dummy
    helm template airgap-config charts/airgap-config -f charts/values/fusion-airgap.yaml --set trust.caBundle=dummy | kubeconform -strict -ignore-missing-schemas -summary
    helm template airgap-config charts/airgap-config | wc -l      # defaults: everything off, expect 0 documents
    # negative test, must FAIL with "path ... is used by both":
    helm template airgap-config charts/airgap-config -f charts/values/fusion-airgap.yaml --set trust.caBundle=dummy \
      --set 'mirrors.digest[1].mirrors[0]=artifactory.example.internal/rh-registry-redhat-io'
    # optional objects:
    helm template airgap-config charts/airgap-config -f charts/values/fusion-airgap.yaml --set trust.caBundle=dummy \
      --set issuer.enabled=true --set issuer.secretName=x --set namedCerts.api.enabled=true \
      --set 'namedCerts.api.hostnames={api.fusion.example.internal}' --set namedCerts.api.secretName=api-tls \
      --set namedCerts.ingress.enabled=true --set namedCerts.ingress.secretName=ingress-tls \
      --set 'trust.registryCAs.artifactory\.example\.internal:443=dummy'

## Transfer bundle for the air-gap (`scripts/to-airgap.sh`)

On a connected machine `scripts/to-airgap.sh` packages these charts, mirrors the images they render (skopeo), builds the oc-mirror
operator set and an NVIDIA image list into one verified tar; `scripts/from-airgap.sh` pushes it on the other side.
Start with `scripts/to-airgap.sh --dry-run`; full steps in `docs/airgap.md`. Written, not yet run.

## GitOps and MIG on hardware

Argo CD app-of-apps (same values files, same waves): `argocd/README.md`. Under Argo, `lookup` is empty and `adopt-existing.sh` is not needed (see there).
MIG on the real H200 node (phase 7, not runnable yet): `docs/mig-hardware-checklist.md`; results go in `docs/poc-results.md`.

## Install order

0. (Fusion only) `airgap-config`.
1. `rhoai-operators`, then wait until every CSV is `Succeeded` (Helm does not wait for CSVs).
2. `rhoai-config`. Its CRDs (NodeFeatureDiscovery, DSCInitialization, DataScienceCluster) only exist after step 1, and `helm install` checks them up front.

## Adopting objects that already exist (the SNO)

RHOAI on the SNO was applied by hand (`manifests/rhoai/`, `day2/install-rhoai.sh`). Helm refuses to
take over objects it did not create. `charts/adopt-existing.sh` adds the three markers Helm looks for
(label `app.kubernetes.io/managed-by=Helm`, annotations `meta.helm.sh/release-name` and
`meta.helm.sh/release-namespace`) to the existing Namespace `redhat-ods-operator`, OperatorGroup
`rhods-operator-group`, Subscription `rhods-operator`, DSCI `default-dsci` and DSC `default-dsc`.
It changes no specs and skips objects that are absent.

    charts/adopt-existing.sh --dry-run        # prints the commands, touches no cluster
    charts/adopt-existing.sh                  # real run (5 s pause to check the context)

Both `helm` and the script must use the same release namespace (default `default`; the script's `--release-namespace`).
`values/sno.yaml` sets `operatorGroupName: rhods-operator-group` so Helm adopts the existing group instead of
creating a second one (OLM allows one OperatorGroup per namespace; two break the install).
After adoption the first `helm upgrade` may show a diff (for example the Subscription `config`); that is expected.
Caveat: objects Helm adopted are removed by `helm uninstall`, including the DSC. Do not uninstall casually.

## Install (SNO)

    oc whoami   # confirm you are on the intended cluster first
    charts/adopt-existing.sh --only operators
    helm upgrade --install rhoai-operators charts/rhoai-operators --namespace default -f charts/values/sno.yaml
    oc get csv -A | grep -E 'cert-manager|nfd|kueue|rhods'
    charts/adopt-existing.sh --only config
    helm upgrade --install rhoai-config charts/rhoai-config --namespace default -f charts/values/sno-config.yaml
    oc get dsc default-dsc -o jsonpath='{.status.phase}'   # Ready
    oc get pods -n rhoai-poc                               # minio Running

## Secrets

Nothing real is committed. MinIO credentials are generated on first install and reused on upgrade through
Helm `lookup`. `lookup` returns nothing under `helm template` and under Argo CD, so for GitOps either set
`minio.auth.existingSecret` / `mysql.existingSecret` (Secrets you create yourself) or pass keys from an
untracked values file. The data connection Secret copies MinIO's credentials unless `s3.accessKey/secretKey` are set.
Read the generated keys: `oc get secret minio-credentials -n rhoai-poc -o jsonpath='{.data.accessKey}' | base64 -d`.

## Serving a tiny CPU model (disabled by default)

1. Find the runtime image RHOAI ships (UNVERIFIED which template): `oc get template -n redhat-ods-applications` and look for the OpenVINO/OVMS one; copy its `image`.
2. Upload a small ONNX model to the bucket under `tiny-model/` (port-forward MinIO: `oc port-forward -n rhoai-poc svc/minio 9000`, then `mc` or `aws s3 cp --endpoint-url http://localhost:9000`). The cluster's egress to Hugging Face is untested, so download on the laptop.
3. `helm upgrade rhoai-config charts/rhoai-config -f charts/values/sno-config.yaml --set serving.enabled=true --set serving.runtime.image=<image>`
4. `oc get inferenceservice -n rhoai-poc`, then POST to the predictor Service (`/v2/models/tiny-model/infer`, KServe v2 protocol).

## Useful overrides

    --set operators.kueue.enabled=false
    --set operators.rhoai.startingCSV=rhods-operator.3.4.0
    --set installPlanApproval=Manual
    --set catalog.source=my-mirror-catalog
    --set dsc.components.modelregistry.managementState=Managed   # config chart

Per-operator `catalog`, `channel`, `nodeSelector`, `tolerations`, `resources`, `operatorGroupName` are also values.
Sync waves (Argo CD): operators chart namespaces -10, prereqs 0, gpu 1, rhoai 2; config chart project/NFD 3, DSCI 4, DSC 5, storage 6, serving 7 (`syncWaves` in each values.yaml).
