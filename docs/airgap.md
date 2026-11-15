# Air-gap transfer: export on the connected side, import on the disconnected side

Plain-English summary: `scripts/to-airgap.sh` runs on a machine with internet and builds one folder (and a `.tar`) holding the
Helm charts, every container image the charts need, the operator catalog content (via oc-mirror), a list of NVIDIA GPU images,
and optional model files, plus `MANIFEST.txt` and `SHA256SUMS`. You carry it across, verify it, push the images to Artifactory,
apply the oc-mirror results, then install the charts in order. Nothing secret is stored in the bundle.

Status: written, NOT run. Everything marked UNVERIFIED below needs checking on first real use.

## 1. Connected side: build the bundle

    scripts/to-airgap.sh --dry-run                      # plan + full image list, no network, writes nothing
    export REGISTRY_AUTH_FILE=$HOME/.config/containers/auth.json   # your own login for registry.redhat.io, quay.io (not copied)
    scripts/to-airgap.sh --out ./airgap-bundle --ocp 4.20 --model Qwen/Qwen2.5-0.5B --ngc-images ngc.txt

Useful flags: `--values rhoai-config=my-values.yaml` (override one chart's values), `--profile sno`, `--skip-images`,
`--skip-operators`, `--skip-models`, `--multi-arch all|system|index-only`, `--transport oci|dir`, `--copy-gpu`,
`--gpu-version driver=580.95.05`, `--include-tools`, `--extra-images file`. `--help` lists all.

What the images step does:
- Renders every chart under `charts/` with the chosen values (default: the fusion set: `fusion.yaml`, `fusion-config.yaml`,
  `fusion-airgap.yaml`), collects every `image:` plus image refs in env values and args, dedupes, and runs `skopeo copy`
  (`--all` by default) into one OCI layout `images/oci/` (tag `img-NNNN`). `images/images.tsv` maps index to source ref and
  records the manifest digest; the copy also compares it with the source digest.
- Refs on a placeholder host (`*.example.internal`, e.g. the mysql image in `fusion-config.yaml`) are SKIPPED and listed. Put the real
  upstream in a file for `--extra-images` (for example `registry.redhat.io/rhel9/mysql-80:<tag>`), or fix the values.
- CatalogSource images are not copied by skopeo: oc-mirror produces the catalogs.
- If a status says `DIGEST-CHANGED`: the OCI layout cannot hold Docker schema2 manifests, so skopeo converted them and the
  digest changed. Digest-based mirror rules (IDMS) would then not match. Re-run with `--transport dir` (keeps manifests
  byte-for-byte; whether `--all` works with `dir:` is UNVERIFIED).

Operators: `operators/imageset-config.yaml` is generated from the Subscriptions of `rhoai-operators` (package + channel, catalog
`registry.redhat.io/redhat/<index>:v<ocp>`), then `oc-mirror --v2 -c ... file://<bundle>/operators/mirror` runs.
UNVERIFIED: the v2 apiVersion (`mirror.openshift.io/v2alpha1`), the CLI form, and that the channels exist in the catalog
(check with `oc-mirror list operators --catalog ... --package ...`). The RHOAI 3.4 channel is still unconfirmed in `values/fusion.yaml`.
Mirroring all of RHOAI 3.4 is about 75 GB (poc.md); check disk space first.

GPU images (`gpu/gpu-images.txt`): driver, toolkit, device-plugin, dcgm-exporter, dcgm, mig-manager, validator (same image as the
operator), gfd. ALL TAGS ARE UNVERIFIED guesses; override with `--gpu-version`, and cross-check against the `relatedImages` of the
mirrored `gpu-operator-certified` bundle (oc-mirror already copies those) and NVIDIA's support matrix. They are only copied with
`--copy-gpu`. NFD operand images also come with oc-mirror. On OpenShift the Driver Toolkit image comes from the OCP release
payload, which is a platform mirror and not part of this bundle (UNVERIFIED).

NVAIE / NGC (open item 2): put refs in a file, `export NGC_API_KEY=...` (never written to disk; briefly visible in `ps` through
skopeo `--src-creds`), pass `--ngc-images`. Without the key the list is saved to `gpu/ngc-images.todo.txt` and not copied.

Models: `--model org/name` (needs `hf` or `huggingface-cli`; `HF_TOKEN` from the env if gated) or `--model https://...`. Files land
in `models/`; later upload them to the S3 bucket.

Tools: `tools/TOOLS.txt` records helm, skopeo, oc-mirror and oc versions and download URLs (UNVERIFIED). `--include-tools` copies this
machine's binaries; a macOS binary will not run on the RHEL import host.

Output: `<out>/` (MANIFEST.txt, SHA256SUMS, charts/, images/, operators/, gpu/, models/, tools/, docs/, scripts/), `<out>.tar`, `<out>.tar.sha256`.
The script exits non-zero if any copy, oc-mirror run or download failed; MANIFEST.txt says which.

## 2. Carry across and verify

    shasum -a 256 -c airgap-bundle.tar.sha256        # on Linux: sha256sum -c
    tar -xf airgap-bundle.tar && cd airgap-bundle
    shasum -a 256 -c SHA256SUMS                      # every file; Linux: sha256sum -c SHA256SUMS

## 3. Push images to Artifactory

Path prefixes must match `charts/values/fusion-airgap.yaml` (`mirrors`), one distinct prefix per upstream (open item 3):
`rh-registry-redhat-io`, `rh-registry-access-redhat-com`, `rh-registry-quay-io`, `rh-registry-nvcr-io`.

    export REGISTRY_AUTH_FILE=...                    # your Artifactory login, not in the bundle
    scripts/from-airgap.sh --bundle . --dest artifactory.example.internal --dry-run    # print the commands
    scripts/from-airgap.sh --bundle . --dest artifactory.example.internal

Refs pinned by digest are pushed under the tag `sha256-<hex>`; pulls by digest still work. Create the repositories in Artifactory first if it
does not auto-create them (UNVERIFIED).

## 4. Operators (oc-mirror)

    oc-mirror --v2 -c operators/imageset-config.yaml --from file://$PWD/operators/mirror docker://artifactory.example.internal/rh-registry-redhat-io

UNVERIFIED: the destination path form and flags for your oc-mirror build. Use the SAME prefix as the `mirrors` entries so IDMS rules match.
oc-mirror writes `cluster-resources/` under its working directory: `idms-oc-mirror.yaml` (ImageDigestMirrorSet),
`itms-oc-mirror.yaml` (ImageTagMirrorSet), `cs-*.yaml` (CatalogSource per index) and possibly an UpdateService. Names are UNVERIFIED.
The charts do not apply these files: copy their content into `values/fusion-airgap.yaml` (`catalogs.sources[].image`, `mirrors`) and keep
the CatalogSource names equal to `catalog.source` in `values/fusion.yaml`. Do not `oc apply` oc-mirror's files AND install `airgap-config`
(duplicate objects). Changing mirror sets makes the Machine Config Operator roll nodes; plan a window.

## 5. Install order

    helm upgrade --install airgap-config  charts/packages/airgap-config-*.tgz  -f charts/values/fusion-airgap.yaml --set-file trust.caBundle=ca.pem
    # wait: CatalogSources READY (oc get catalogsource -n openshift-marketplace)
    helm upgrade --install rhoai-operators charts/packages/rhoai-operators-*.tgz -f charts/values/fusion.yaml
    # wait: every CSV Succeeded (oc get csv -A); approve InstallPlans (installPlanApproval is Manual)
    helm upgrade --install rhoai-config   charts/packages/rhoai-config-*.tgz   -f charts/values/fusion-config.yaml --set s3.accessKey=... --set s3.secretKey=...

(Pass the real chart file names; the glob only works if exactly one version exists. Singletons such as OperatorHub/Proxy need adoption, see charts/README.md.)

## 6. Checklist

- [ ] Tar checksum and `SHA256SUMS` verified
- [ ] MANIFEST.txt: failures=0; no `DIGEST-CHANGED`; skipped placeholder images resolved
- [ ] Images pushed (`from-airgap.sh`), prefixes match `fusion-airgap.yaml`
- [ ] oc-mirror import done; IDMS/ITMS/CatalogSource content copied into values
- [ ] Artifactory CA in `trust.caBundle`
- [ ] GPU image tags checked against the mirrored GPU Operator CSV
- [ ] Models uploaded to the S3 bucket
- [ ] Charts installed in order: airgap-config, rhoai-operators, rhoai-config
