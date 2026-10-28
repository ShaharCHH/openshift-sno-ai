# Storage: LVMS, and the default StorageClass

## Why LVMS
Nothing in the cluster can hold an AWS credential (`iam:CreateUser` and
`iam:CreateOpenIDConnectProvider` are SCP-denied; see the source repo's
`docs/scp-blockers.md` rows 8/9). The AWS EBS CSI driver therefore can never
provision a volume here. LVMS (LVM Storage) carves volumes out of a local disk
and needs no cloud identity. Terraform attaches an extra, blank gp3 volume
(`master_data_volume_size`, default 200 GiB, `/dev/sdf` -> `/dev/nvme1n1`) for it.

Run: `day2/install-lvms.sh -a <alias>`, then `day2/verify-lvms.sh -a <alias>`.

## Verified on a live cluster (OCP 4.22.9, LVMS 4.22.0)
- Operator installs from `redhat-operators`, channel `stable-4.22`, in ~50 s.
- With no `deviceSelector`, LVMS claims only the blank data disk. The root disk
  and its partitions land under `excluded` in `status.deviceClassStatuses`.
- A 1 GiB PVC on `lvms-vg1` binds, mounts, and round-trips a file.

## The default-class problem
Left alone, `gp3-csi` stays the default and a PVC naming no class binds to it and
sits `Pending` forever. The image registry and RHOAI both create class-less PVCs.
Two controllers each undo a manual fix:

| Attempt | Result |
|---|---|
| `oc annotate sc gp3-csi ...is-default-class-` | Reverted within seconds by cluster-storage-operator |
| `oc annotate sc lvms-vg1 ...is-default-class=true` | Reset to `"false"` by LVMS while another default exists |
| `ClusterCSIDriver.spec.managementState: Removed` | Refused: `Removed is not supported for AWSEBSCSIDriver operator`; adds a second Degraded condition. Reverted. |
| `ClusterCSIDriver.spec.storageClassState: Unmanaged` | The supported lever. CSI operator stops reconciling its StorageClasses. This is what `install-lvms.sh` uses. |

`install-lvms.sh` applies `Unmanaged`, clears the default flag on `gp3-csi` and
`gp2-csi`, sets it on `lvms-vg1`, then re-reads after 30 s (the earlier attempts
"succeeded" and were undone seconds later, so the exit code alone proves nothing).
`verify-lvms.sh` creates a PVC with no `storageClassName` to prove the outcome.

## Still broken, and expected
The `storage` clusteroperator stays Degraded/Unavailable (the EBS driver
deployment can never start without a credential), as does `image-registry` until
it is given a PVC, and `network` stays Progressing. Same root cause; do not chase.

## Image registry on LVMS
`day2/setup-registry.sh -a <alias>` creates a 20 GiB RWO PVC on `lvms-vg1`
(`manifests/registry/registry-pvc.yaml`) and points the registry operator at it
(replicas 1, `rolloutStrategy: Recreate`, `s3: null` and `pvc.claim` in one patch).
`lvms-vg1` binds `WaitForFirstConsumer`, so the PVC is `Pending` until the
registry pod exists -- the script does not wait for `Bound` before patching.

Verified on OCP 4.22.9: PVC `Bound` ~30 s after the patch, `image-registry`
Available. `openshift-apiserver` briefly went Available=False right after
(single-node pod restart) and recovered by itself within ~2 min; the cause was
not confirmed.

`day2/post-install-cleanup.sh -a <alias>` is a read-only check of the end state:
`storageClassState=Unmanaged`, `lvms-vg1` sole default, registry Available and
Bound, then `scripts/check-known-inert.sh` for `storage` and `network`.
It does not try `ClusterCSIDriver managementState: Removed` -- see the table
above, the operator refuses it.
