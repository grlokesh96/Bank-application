# Phase 8 — Backup & Disaster Recovery with Velero (EKS)

> **Status:** 📝 Written to be run *as we do it*. Follow top-to-bottom; every
> command is copy-paste ready for this cluster (account `118178010323`, region
> `us-east-1`, cluster `banking-dev`).

**Goal:** Install **Velero** so we can **back up the cluster to S3** and **restore
it** — same cluster or a brand-new one — for disaster recovery. We focus on the
data that isn't already reproducible from Git (Postgres, Kafka).

**Time:** ~30–40 min including a real backup → delete → restore test.

---

## What is Velero?

**Velero** (by VMware Tanzu) is the standard open-source tool for **Kubernetes
backup, restore, and migration**. It has two jobs:

1. **Back up Kubernetes objects** — it queries the API server and writes the
   selected resources (Deployments, Services, ConfigMaps, Secrets, PVCs, CRDs, …)
   as an archive into an **S3 bucket**.
2. **Back up the data in volumes** — it captures the contents of your
   **PersistentVolumes**, either as **EBS snapshots** (cloud-native) or as
   **file-level backups** (kopia) streamed to the same S3 bucket.

A **restore** replays a backup: it recreates the objects and rehydrates the
volumes — into the same cluster (undo an accident) or a fresh one (full DR /
cluster migration).

### Why Velero here — the advantages

| Advantage | Why it matters for this platform |
| --------- | -------------------------------- |
| **Disaster recovery** | If the cluster is lost, `terraform apply` + Argo CD rebuild the *stateless* app from Git — but **Postgres/Kafka data lives only on EBS volumes**. Velero is what brings that data back. |
| **Namespace-scoped** | Back up just the `banking` namespace (app + data) without touching the rest. |
| **Cluster migration** | Restore into a new cluster (e.g. new region, or a rebuilt `banking-dev`) — great for "recreate from scratch" drills. |
| **Point-in-time via schedules** | Daily automated backups with retention (TTL), so you can roll back to yesterday. |
| **Granular restore** | Restore a single namespace, or filter to specific resources/labels. |
| **S3-backed & cheap** | Backups are just objects in S3 — durable, versioned, and inexpensive. |
| **GitOps-friendly** | Installs as a Helm chart / Argo CD app; schedules are CRDs kept in Git. |

### What we actually back up (and what we don't need to)

```
Reproducible from Git + ECR (Argo redeploys)          → NOT the priority
  30 services · api-gateway · frontend · configs

Stateful data on EBS volumes (only exists in-cluster) → 🔴 THE reason for Velero
  postgres-0  PVC   ← the banking data (accounts, ledger, transactions)
  kafka-0     PVC   ← event log / outbox
  (optional) prometheus / loki / tempo PVCs
```

We back up the **`banking` namespace including its PVC data**. The app itself is
already "backed up" by Git (manifests) + ECR (images).

---

## How Velero captures volume data — two modes

| Mode | How | Trade-off |
| ---- | --- | --------- |
| **File System Backup (FSB, kopia)** ⭐ *(we use this)* | A `node-agent` DaemonSet reads the mounted volume files and streams them to S3. | Simplest — **no extra CSI snapshot controller needed**, works on any volume. Slower for huge volumes; crash-consistent. |
| **CSI / EBS snapshots** | Velero asks the EBS CSI driver to snapshot the volume. | Fast, EBS-native. **Requires** the external-snapshotter controller + a `VolumeSnapshotClass` (extra install). |

We use **FSB (kopia)** — fewest moving parts and it just works on EKS. The CSI
snapshot alternative is described at the end.

---

## Architecture

```
   ┌──────────────── EKS: banking-dev ─────────────────┐
   │  namespace: velero                                 │
   │   ┌────────────┐        ┌─────────────────────┐    │
   │   │ velero     │        │ node-agent (kopia)   │    │
   │   │ server     │        │ DaemonSet (per node) │    │
   │   └─────┬──────┘        └──────────┬───────────┘    │
   │         │ IRSA role (no static keys)│               │
   └─────────┼───────────────────────────┼──────────────┘
             │  k8s objects (yaml)        │ volume file data (kopia)
             ▼                            ▼
        ┌──────────────────────────────────────────┐
        │  S3: banking-velero-backups-118178010323  │
        └──────────────────────────────────────────┘
```

---

## ✅ Prerequisites

| Need | How to check |
| ---- | ------------ |
| Cluster up + `kubectl` context | `kubectl get nodes` → Ready |
| EBS CSI driver present (Phase 1) | `kubectl -n kube-system get pods | grep ebs-csi` |
| OIDC provider on the cluster (IRSA) | `terraform -chdir=terraform/environments/dev output oidc_provider_arn` |
| `terraform` ≥ 1.10, `helm`, `aws` CLI | version commands |
| Argo CD running (for the GitOps install) | `kubectl -n argocd get pods` |

---

## Step 1 — AWS resources (Terraform): S3 bucket + IAM + IRSA

Velero needs an **S3 bucket** for backups and an **IAM role** (assumed via IRSA,
so **no static keys** in the cluster). These are **already committed** as an
optional, standalone Terraform stack (`terraform/modules/velero/` +
`terraform/velero/`) — kept out of `environments/dev` on purpose. The module
contents are shown below for reference; you don't need to create them.

`terraform/modules/velero/main.tf`:
```hcl
# S3 bucket for Velero backups (object storage for k8s objects + kopia data).
resource "aws_s3_bucket" "this" {
  bucket = var.bucket_name
  tags   = var.tags
}

resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.this.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket                  = aws_s3_bucket.this.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# IAM policy: S3 (backup store) + EC2 snapshot perms (for the optional CSI/EBS mode).
data "aws_iam_policy_document" "velero" {
  statement {
    effect    = "Allow"
    actions   = ["ec2:DescribeVolumes", "ec2:DescribeSnapshots", "ec2:CreateTags",
                 "ec2:CreateVolume", "ec2:CreateSnapshot", "ec2:DeleteSnapshot"]
    resources = ["*"]
  }
  statement {
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:DeleteObject", "s3:PutObject",
                 "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"]
    resources = ["${aws_s3_bucket.this.arn}/*"]
  }
  statement {
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.this.arn]
  }
}

resource "aws_iam_policy" "velero" {
  name   = "${var.name}-velero"
  policy = data.aws_iam_policy_document.velero.json
}

# IRSA role assumed by the velero ServiceAccount (velero/velero).
data "aws_iam_policy_document" "assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider}:sub"
      values   = ["system:serviceaccount:velero:velero"]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "velero" {
  name               = "${var.name}-velero-irsa"
  assume_role_policy = data.aws_iam_policy_document.assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "velero" {
  role       = aws_iam_role.velero.name
  policy_arn = aws_iam_policy.velero.arn
}
```

`terraform/modules/velero/variables.tf`:
```hcl
variable "name"              { type = string }
variable "bucket_name"       { type = string }
variable "oidc_provider_arn" { type = string }
variable "oidc_provider"     { type = string } # issuer URL without https://
variable "tags"              { type = map(string) ; default = {} }
```

`terraform/modules/velero/outputs.tf`:
```hcl
output "bucket_name"   { value = aws_s3_bucket.this.bucket }
output "irsa_role_arn" { value = aws_iam_role.velero.arn }
```

### The standalone root — apply ONLY Velero

The module is **not** wired into `environments/dev` (Velero is optional — a normal
infra apply must never create it). Instead it's driven by a small standalone root
at **`terraform/velero/`** with its **own state** (`dev/velero.tfstate`). It reads
the running cluster's OIDC provider via a data source, so it needs nothing from
the Phase-1 stack — just that the cluster exists.

`terraform/velero/main.tf` (already committed):
```hcl
data "aws_caller_identity" "current" {}
data "aws_eks_cluster" "this" { name = var.cluster_name }   # banking-dev

locals {
  oidc_issuer   = data.aws_eks_cluster.this.identity[0].oidc[0].issuer
  oidc_provider = replace(local.oidc_issuer, "https://", "")
  oidc_arn      = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${local.oidc_provider}"
  bucket_name   = "banking-velero-backups-${data.aws_caller_identity.current.account_id}"
}

module "velero" {
  source            = "../modules/velero"
  name              = var.name
  bucket_name       = local.bucket_name
  oidc_provider_arn = local.oidc_arn
  oidc_provider     = local.oidc_provider
}
```
It also ships `backend.tf` (key `dev/velero.tfstate`), `providers.tf`,
`variables.tf`, `outputs.tf` — all committed.

**Apply just this stack:**
```bash
cd terraform/velero
terraform init                 # its own state — separate from the Phase-1 infra
terraform apply                # creates ONLY: S3 bucket + IAM policy + IRSA role
terraform output velero_irsa_role_arn   # arn:aws:iam::118178010323:role/banking-dev-velero-irsa
terraform output velero_bucket          # banking-velero-backups-118178010323
```

> ✅ **This never touches the core infra.** The Phase-1 apply (`environments/dev`)
> and this Velero apply have separate state files, so you can `terraform destroy`
> Velero on its own later (`cd terraform/velero && terraform destroy`) without
> affecting the cluster.

---

## Step 2 — Install the Velero CLI (your laptop)

Used to create/inspect backups and restores.
```bash
VELERO_VERSION=v1.18.1
curl -fsSL -o /tmp/velero.tar.gz \
  "https://github.com/vmware-tanzu/velero/releases/download/${VELERO_VERSION}/velero-${VELERO_VERSION}-linux-amd64.tar.gz"
tar -xzf /tmp/velero.tar.gz -C /tmp
sudo mv /tmp/velero-${VELERO_VERSION}-linux-amd64/velero /usr/local/bin/velero
velero version --client-only     # Client: v1.18.1
```

---

## Step 3 — Install the Velero server (GitOps, Argo CD app)

> ✅ **Already done if you bootstrapped Argo CD in Phase 4.** The Velero app is
> part of the app-of-apps, so the Velero server + node-agents are
> **already installed** — `kubectl -n velero get pods` shows them Running and
> `kubectl -n argocd get app velero` is `Synced / Healthy`. **You do not need to
> re-apply anything here.** Once Step 1's Terraform creates the S3 bucket + IRSA
> role, the `default` BackupStorageLocation flips to `Available` on its own and you
> can skip straight to Step 2 (CLI) / Step 4 (first backup). The rest of this step
> is reference for *what* got installed and how to do it manually.

Add the Velero Application (the app-of-apps picks it up). It installs the Velero
Helm chart with the **AWS plugin**, **IRSA** (no static keys), and the
**node-agent** for file-system backups:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: velero
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: banking
  source:
    repoURL: https://vmware-tanzu.github.io/helm-charts
    chart: velero
    targetRevision: 12.1.0
    helm:
      values: |
        initContainers:
          - name: velero-plugin-for-aws
            image: velero/velero-plugin-for-aws:v1.14.2
            imagePullPolicy: IfNotPresent
            volumeMounts:
              - mountPath: /target
                name: plugins
        # IRSA — assume the AWS role, no static credentials in the cluster
        credentials:
          useSecret: false
        serviceAccount:
          server:
            name: velero    # ⚠️ MUST be "velero" — the IRSA trust policy is scoped to
                            # system:serviceaccount:velero:velero. The chart otherwise
                            # names it "velero-server", so S3 auth fails (BSL Unavailable).
            annotations:
              eks.amazonaws.com/role-arn: arn:aws:iam::118178010323:role/banking-dev-velero-irsa
        configuration:
          backupStorageLocation:
            - name: default
              provider: aws
              bucket: banking-velero-backups-118178010323
              config:
                region: us-east-1
          volumeSnapshotLocation:
            - name: default
              provider: aws
              config:
                region: us-east-1
        snapshotsEnabled: true
        deployNodeAgent: true      # node-agent DaemonSet for file-system (kopia) backups
  destination:
    server: https://kubernetes.default.svc
    namespace: velero
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
```

The `banking` AppProject must **allow the Velero Helm repo AND the `velero`
namespace destination**. Both are part of the app-of-apps bootstrap project:
```yaml
  sourceRepos:
    - "https://vmware-tanzu.github.io/helm-charts"   # ← already present
  destinations:
    - { server: https://kubernetes.default.svc, namespace: velero }   # ← already present
```
> If you edited the project after Argo CD was bootstrapped, re-apply it so the
> live AppProject picks up the change: `kubectl apply -f bootstrap/project.yaml`
> (otherwise the velero app fails with `InvalidSpecError: ... do not match any of
> the allowed destinations`).

Commit the velero app and let the app-of-apps create it:
```bash
git add bootstrap/velero.yaml
git commit -m "argocd: add velero backup/DR app"
git push origin main
kubectl -n argocd annotate app platform-root argocd.argoproj.io/refresh=hard --overwrite
```

> **Non-GitOps alternative (Helm directly):**
> ```bash
> helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts && helm repo update
> helm install velero vmware-tanzu/velero -n velero --create-namespace --version 12.1.0 \
>   --set-json 'initContainers=[{"name":"velero-plugin-for-aws","image":"velero/velero-plugin-for-aws:v1.14.2","volumeMounts":[{"mountPath":"/target","name":"plugins"}]}]' \
>   --set credentials.useSecret=false \
>   --set serviceAccount.server.annotations."eks\.amazonaws\.com/role-arn"=arn:aws:iam::118178010323:role/banking-dev-velero-irsa \
>   --set configuration.backupStorageLocation[0].name=default \
>   --set configuration.backupStorageLocation[0].provider=aws \
>   --set configuration.backupStorageLocation[0].bucket=banking-velero-backups-118178010323 \
>   --set configuration.backupStorageLocation[0].config.region=us-east-1 \
>   --set deployNodeAgent=true --wait
> ```

Verify the install:
```bash
kubectl -n velero get pods           # velero-* + node-agent-* (one per node) Running
velero backup-location get           # default   Available
```
> `Available` on the backup location confirms Velero authenticated to S3 via IRSA.

---

## Step 4 — Take a backup (and confirm volume data is included)

On-demand backup of the `banking` namespace **with file-system volume backup**:
```bash
velero backup create banking-manual-1 \
  --include-namespaces banking \
  --default-volumes-to-fs-backup \
  --wait
```
- `--include-namespaces banking` → only the app namespace.
- `--default-volumes-to-fs-backup` → back up **all** PV contents (Postgres/Kafka)
  via kopia, not just the k8s objects.

Inspect:
```bash
velero backup describe banking-manual-1 --details
velero backup logs banking-manual-1 | tail
# and confirm objects landed in S3:
aws s3 ls s3://banking-velero-backups-118178010323/backups/banking-manual-1/
```
You should see `Phase: Completed` and PodVolumeBackups for `postgres-0` / `kafka-0`.

---

## Step 5 (Optional) — Scheduled daily backups (retention)

A `Schedule` CRD runs backups automatically and expires old ones (`--ttl`):
```bash
velero schedule create daily-banking \
  --schedule="0 2 * * *" \
  --include-namespaces banking \
  --default-volumes-to-fs-backup \
  --ttl 168h0m0s          # keep 7 days
velero schedule get
```
Commit the schedule as code (optional, GitOps): export it and add to the repo:
```bash
velero schedule get daily-banking -o yaml > velero/schedule-daily-banking.yaml
```

---

## Step 6 (Optional, recommended) — Disaster-recovery restore test (prove it works)

Simulate data loss and restore:

```bash
# 1) create a marker so we can see the restore work
kubectl -n banking create configmap dr-test --from-literal=ok=before-restore

# 2) back up
velero backup create dr-demo --include-namespaces banking --default-volumes-to-fs-backup --wait

# 3) "lose" it
kubectl -n banking delete configmap dr-test

# 4) restore just that (or the whole namespace)
velero restore create --from-backup dr-demo --wait

# 5) confirm it's back
kubectl -n banking get configmap dr-test -o jsonpath='{.data.ok}{"\n"}'   # before-restore
```

**Full cluster DR** (cluster destroyed) is the same idea end-to-end:
1. `terraform apply` → new EKS cluster
2. Install Traefik + Argo CD → app-of-apps redeploys the stateless app from Git
3. Reinstall Velero (Step 3) pointed at the **same S3 bucket**
4. `velero restore create --from-backup <latest daily-banking>` → Postgres/Kafka
   **data** comes back
5. Restart app pods if needed → platform whole again

---

## Postgres consistency (important for a real DB)

A file-system backup of a live Postgres volume is **crash-consistent** — Postgres
replays its WAL on restart, which is fine for a learning cluster. For
production-grade consistency, add a **Velero backup hook** that quiesces the DB,
or take **logical dumps**. Example pre-backup hook annotation on the Postgres pod:
```yaml
# on the postgres StatefulSet pod template:
annotations:
  pre.hook.backup.velero.io/command: '["/bin/sh","-c","pg_dump -U banking banking > /var/lib/postgresql/data/backup.sql || true"]'
```
Or run a separate `CronJob` that `pg_dump`s to S3 for point-in-time restores.

---

## CSI / EBS snapshot mode (optional, faster alternative)

Instead of kopia file backups, use native EBS snapshots:
1. Install the **external-snapshotter** (snapshot CRDs + controller):
   ```bash
   kubectl apply -k "https://github.com/kubernetes-csi/external-snapshotter/client/config/crd?ref=v8.2.0"
   kubectl apply -k "https://github.com/kubernetes-csi/external-snapshotter/deploy/kubernetes/snapshot-controller?ref=v8.2.0"
   ```
2. Create a `VolumeSnapshotClass` for the EBS CSI driver:
   ```bash
   kubectl apply -f - <<EOF
   apiVersion: snapshot.storage.k8s.io/v1
   kind: VolumeSnapshotClass
   metadata:
     name: ebs-csi
     labels: { velero.io/csi-volumesnapshot-class: "true" }
   driver: ebs.csi.aws.com
   deletionPolicy: Retain
   EOF
   ```
3. Enable the CSI feature on Velero (`configuration.features: EnableCSI` in the
   Helm values) and drop `--default-volumes-to-fs-backup` from backups — Velero
   will snapshot PVCs via CSI instead.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
| ------- | ------------ | --- |
| `backup-location get` shows `Unavailable` | **SA name ≠ IRSA trust** (chart names it `velero-server`, trust expects `velero:velero`), or role/bucket/region wrong | Set `serviceAccount.server.name: velero` in the Helm values (Step 3); confirm `kubectl -n velero get sa velero` has the role annotation; bucket + region match Step 1; `kubectl -n velero logs deploy/velero`. |
| velero app `InvalidSpecError: ... allowed destinations` | AppProject missing the `velero` namespace destination | Add `{ namespace: velero }` to `project.yaml` destinations and re-apply it. |
| Backup `PartiallyFailed`, PVCs skipped | Forgot `--default-volumes-to-fs-backup` (FSB) or node-agent not running | Add the flag; `kubectl -n velero get pods` (node-agent DaemonSet, one per node). |
| `AccessDenied` writing to S3 | IAM policy missing S3 actions / wrong bucket ARN | Re-check the `aws_iam_policy_document.velero` S3 statements + bucket name. |
| Restore leaves pods `Pending` | New PVCs need the `gp3` StorageClass | Ensure `cluster-storage` app (gp3) exists before restoring PVCs. |
| CSI snapshot backups empty | external-snapshotter/VolumeSnapshotClass missing | Do the CSI section, or just use FSB (`--default-volumes-to-fs-backup`). |

---

## Teardown note

Velero's S3 bucket + IAM are Terraform-managed, so `terraform destroy` removes
them — **but** S3 won't delete a non-empty bucket. Empty it first:
```bash
aws s3 rm s3://banking-velero-backups-118178010323 --recursive
```
(Keep the backups if you might restore into a rebuilt cluster — that's the whole
point of DR.)

---

✅ You now have **automated daily backups to S3** and a **proven restore path** —
the piece that makes the platform genuinely disaster-recoverable.
