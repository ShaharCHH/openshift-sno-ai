# Argo CD app-of-apps (phase 5)

One root Application per environment deploys child Applications, one per chart, in order:
`airgap-config` (wave -30, Fusion only) -> `rhoai-operators` (-10) -> `rhoai-config` (3). Inside each chart the
templates carry their own resource waves (see `charts/README.md`). Same values files as plain Helm (`valueFiles: ../values/...`).
Nothing here has run: no Argo CD exists on the SNO yet. Everything marked `UNVERIFIED` could not be checked offline.

| Env | Files | Sync |
|---|---|---|
| SNO | `root-sno.yaml`, `apps/sno/*` | automated, `prune: false`, `selfHeal: false` |
| Fusion | `root-fusion.yaml`, `apps/fusion/*` | manual (a human syncs, after reviewing the diff) |

`repoURL` / `targetRevision` are placeholders (`git.example.internal/REPLACE_ME`, `main`); pin a tag or SHA for Fusion. No tokens in git:
register the repo credentials in Argo (`argocd repo add` or a labelled Secret in `openshift-gitops`).

## Bootstrap

1. Install the operator (once, by hand): `oc apply -f argocd/bootstrap/gitops-subscription.yaml`, then wait for
   `oc get csv -n openshift-gitops-operator` = Succeeded and `oc get pods -n openshift-gitops`. The default instance's
   application controller is cluster-admin, which the bundle needs (it creates Subscriptions, CRs, MachineConfig-affecting objects).
2. Register the git repo in Argo. Create the Secrets the charts need (below).
3. `oc apply -f argocd/root-sno.yaml` (or `root-fusion.yaml`). SNO syncs by itself; Fusion: `argocd app sync rhoai-bundle-root`, then each child in order.
4. Verify: `oc get applications -n openshift-gitops`, `oc get csv -A`, `oc get dsc default-dsc -o jsonpath='{.status.phase}'`.

Why the GitOps Subscription is a bootstrap manifest and not in the operators chart: Argo cannot install itself, and a chart-managed
Subscription for Argo would be reverted/pruned by the Argo it installs. It is applied once; `ArgoCD` instance tuning can move into git later.

## Things that behave differently under Argo

- **Ordering.** Waves order the sync, but Argo does not wait for an operator CSV to reach `Succeeded` (Subscriptions are "Healthy" once created).
  So `rhoai-config` may sync before CRDs exist. `SkipDryRunOnMissingResource=true` stops the dry run failing; `ServerSideApply=true` avoids the
  last-applied annotation size limit on big CRs; `retry` (10 attempts, backoff) covers the gap. On Fusion, simply do not sync `rhoai-config` until CSVs are Succeeded.
- **Helm `lookup` is empty** (Argo renders with `helm template`). The chart's "generate MinIO/MySQL password once" cannot work. Create Secrets yourself
  (or via an external secret operator) and set `minio.auth.existingSecret` / `mysql.existingSecret` (already in the Application `valuesObject`).
  Real S3 keys: never in git. Example: `oc create secret generic minio-credentials -n rhoai-poc --from-literal=accessKey=... --from-literal=secretKey=...`.
- **Adopting existing objects (SNO, replaces `charts/adopt-existing.sh`).** Argo does not need Helm ownership markers (no Helm release exists under Argo).
  With `ServerSideApply=true` it applies over objects that already exist and records ownership via the `argocd.argoproj.io/tracking-id`
  annotation; the first sync shows a diff, review it. If an object refuses (field-manager conflicts), annotate that object with
  `argocd.argoproj.io/sync-options: Replace=true` (kubectl replace: overwrites the whole spec, so check the diff first), or add
  `ServerSideApply=true,Force=true`. UNVERIFIED on this stack. Do not run `adopt-existing.sh` and Argo for the same objects. If you used Helm before,
  the Helm release Secrets are inert and can be deleted later.
- **Do not cascade-delete.** No `resources-finalizer` is set, so deleting an Application leaves the cluster objects (including the DSC) alone. Keep it that way.
  Auto-prune is off for the same reason.
- **ignoreDifferences** (all UNVERIFIED): Subscription `/status` and `/spec/config`, DSC/DSCI/ClusterPolicy `/status`. Ignoring `/spec/config` hides real drift of the
  CPU trims; drop it if the RHOAI operator does not revert them. `RespectIgnoreDifferences=true` stops Argo applying over ignored fields.
- **Application health in the root** needs a health check for kind Application. Recent Argo CD versions include one; UNVERIFIED for the version the GitOps operator ships. If missing, add a `resource.customizations.health.argoproj.io_Application` entry, otherwise waves between child Applications do not wait for each other.
- **Fusion secrets/PEM** (CA bundle, named certs) cannot be in git; wiring is a placeholder in `apps/fusion/airgap-config.yaml` (private values repo via multiple sources, or external secrets). Open decision.

## Validate offline

    kubeconform -strict -ignore-missing-schemas -summary argocd/
    python3 -c 'import sys,yaml; [list(yaml.safe_load_all(open(f))) for f in sys.argv[1:]]' argocd/*.yaml argocd/*/*.yaml argocd/*/*/*.yaml
    helm template rhoai-operators charts/rhoai-operators -f charts/values/sno.yaml >/dev/null   # same render Argo will do
