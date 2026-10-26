# Install-method spike (2026-10-26)

Question: how do we get a single-node OpenShift onto one EC2 instance in this
SCP-restricted account (no ELB, no Route 53, no VPC endpoints, no public AMIs)?

## Verified (offline, no AWS resources created)
`openshift-install` 4.22.9, `platform: aws`, BYO private subnet with explicit
subnet roles, `credentialsMode: Manual`, `controlPlane.replicas: 1`,
`compute.replicas: 0`, `publish: Internal`:
- `create manifests` accepts it. Infrastructure comes out
  `controlPlaneTopology: SingleReplica` / `infrastructureTopology: SingleReplica`,
  and the master is made schedulable (no manifest patch needed).
- `create ignition-configs` succeeds (bootstrap.ign ~300 KB, master.ign 1.7 KB
  pointer-sized, same shape as the source repo's 3-master flow).
- The source repo already parameterises `master_count` (tfvars -> terraform
  control-plane module -> render-install-config.sh). Only
  `generate-ignition.sh` hardcodes `replicas: 3` (the IngressController
  manifest); that must become 1.

## Path A: source-repo UPI flow, 1 master + temporary bootstrap EC2
Reuses the whole proven flow (bastion DNS/HAProxy/ignition server, custom AMI,
pointer ignition, NM keyfile). Changes: master_count=1, ingress replicas=1,
HAProxy backends, instance type g5.8xlarge, and the AMI needs the NVIDIA
driver story handled by the GPU Operator at day 2 (no AMI change).
**Unverified at runtime:** that etcd/CVO settle on one node after the bootstrap
node is removed. This is the same shape AWS IPI uses for single-node, so it is
expected to work, but it has to be observed.

## Path B: ignition runs coreos-installer onto a second EBS volume, swap root
No bootstrap EC2, but needs the bootstrap-in-place ignition, a live-ISO-style
environment on AWS, and a stop/detach/attach root swap. Much more novel
machinery in an account where every novelty has hit an SCP wall. Not pursued.

## Recommendation
Path A. First runtime test on a cheap instance (m5.2xlarge, 8 vCPU / 32 GiB,
~$0.4/hr) to prove bootstrap -> single-master handoff, then switch the type to
g5.8xlarge. Gate to pass: `openshift-install wait-for install-complete` succeeds
and `oc get co` shows only the known-inert operators degraded.
