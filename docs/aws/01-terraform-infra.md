# Phase 1 — AWS Infrastructure (Terraform)

**Goal:** Provision the entire AWS foundation for the banking platform with
Terraform — **VPC, EKS, managed node group, ECR, S3, IAM/IRSA** — then connect
`kubectl` to the new **EKS cluster** and run `kubectl get nodes`.

**Time:** ~20–25 minutes (the EKS control plane alone takes ~10–15 min).

---

## What you'll build in this phase

```
                              AWS region  (us-east-1)
   ┌────────────────────────────────────────────────────────────────┐
   │                     VPC  (banking-dev  10.10.0.0/16)             │
   │                                                                  │
   │   Public subnets  (10.10.0.0/20, .16/20, .32/20  — 3 AZs)        │
   │      └── IGW + NAT gateway(s)  ──► outbound internet             │
   │                                                                  │
   │   Private subnets (10.10.128.0/20, .144/20, .160/20 — 3 AZs)     │
   │      └── EKS managed node group (3–6x t3.xlarge)                │
   │                                                                  │
   │   EKS control plane (public endpoint) ◀── kubectl (your laptop) │
   │      OIDC provider ──► IRSA for pods (e.g. document-service→S3)  │
   │                                                                  │
   │   Subnet tags: kubernetes.io/role/elb (public),                 │
   │                internal-elb (private), cluster/<name>=shared     │
   └────────────────────────────────────────────────────────────────┘
   ECR: ONE repo "banking-platform"  (images: auth-service-<sha>, …)
   S3 : "banking-dev-documents-<acct>"  (document/statement storage)
```

**Key design points**

- **Single ECR repository** (`banking-platform`) holds every service's image,
  distinguished by tag prefix (`auth-service-<sha>`, `account-service-<sha>`, …).
- **Nodes run in private subnets**; only NAT gateways and load balancers live in
  public subnets.
- **IRSA (IAM Roles for Service Accounts)** is enabled via the cluster OIDC
  provider so pods can assume least-privilege IAM roles (e.g. document-service
  reaching S3) without static keys.
- **Public, CIDR-restrictable API endpoint** — you connect directly with
  `aws eks update-kubeconfig`. (An optional SSM bastion for private-only access
  is described at the end.)

---

## ✅ Prerequisites

| Tool / thing                              | How to check                    | Where to get it                                            |
| ----------------------------------------- | ------------------------------- | ---------------------------------------------------------- |
| AWS account + billing enabled             | `aws sts get-caller-identity`   | https://portal.aws.amazon.com/billing/signup              |
| IAM user/role with admin *(easy for learning)* | keys in `~/.aws/credentials` | IAM → Users → Create → access key                          |
| **Terraform ≥ 1.10** (needed for S3 `use_lockfile`) | `terraform -version`   | https://developer.hashicorp.com/terraform/install         |
| **AWS CLI v2**                            | `aws --version`                 | https://docs.aws.amazon.com/cli/latest/userguide/install  |
| `kubectl`                                 | `kubectl version --client`     | https://kubernetes.io/docs/tasks/tools/                    |
| `helm` (for later phases)                 | `helm version`                  | https://helm.sh/docs/intro/install/                       |
| Repo cloned locally                       | `ls terraform/environments/dev` | `git clone <your-repo>.git`                               |

> 🔑 **Authenticating Terraform.** Configure AWS creds once:
> ```bash
> aws configure   # or export AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_REGION
> aws sts get-caller-identity   # confirm you're the right account
> ```
> Never paste keys into chat/commits. Use a dedicated learning account and
> rotate/delete keys after teardown.

---

## Step 0 — Bootstrap remote state (one-time per account)

Each environment's `backend.tf` stores state in **S3** with **native lockfile
locking** (`use_lockfile = true`, Terraform ≥ 1.10) — **no DynamoDB needed**.
S3 holds the lock itself as a `.tflock` object via conditional writes. So you
only create the **one bucket** before the first `init`:

```bash
REGION=us-east-1
aws s3api create-bucket --bucket banking-platform-tfstate-118178010323 --region $REGION
aws s3api put-bucket-versioning --bucket banking-platform-tfstate-118178010323 \
  --versioning-configuration Status=Enabled
```

> **Why no DynamoDB?** Before Terraform 1.10, the S3 backend couldn't lock on its
> own, so a DynamoDB table was required. Since 1.10, `use_lockfile = true` gives
> native locking — the DynamoDB table is legacy. (Requires you run Terraform
> ≥ 1.10, which our `required_version` enforces.)

> Just trying things out? Skip this and run `terraform init -backend=false` to
> validate locally without remote state.

---

## Tour of `terraform/`

```
terraform/
├── modules/
│   ├── vpc/     # VPC, public/private subnets (3 AZs), IGW, NAT, routes, EKS subnet tags
│   ├── iam/     # EKS cluster role, node role, ECR push policy
│   ├── eks/     # EKS cluster + managed node group + OIDC/IRSA + addons
│   ├── ecr/     # ONE ECR repo (tag-prefix per service) + lifecycle policy
│   ├── s3/      # private, encrypted, versioned bucket (documents/statements)
│   └── route53/ # apex hosted zone (+ optional apex ALIAS -> NLB, Phase 5)
└── environments/
    ├── dev/     # 10.10.0.0/16, single NAT, t3.xlarge  (this doc uses dev)
    ├── qa/      # 10.20.0.0/16, single NAT
    └── prod/    # 10.30.0.0/16, one NAT per AZ (HA), t3.xlarge, HPA on
```

Each environment is a root module that wires the six modules together. The
cluster + node IAM roles come from the `iam` module (the EKS module reuses them
via `create_iam_role = false`). The `route53` module creates the apex hosted zone
now and outputs its nameservers; the apex ALIAS record is added later in Phase 5
(`create_apex_record=true`) once the Traefik NLB exists.

---

## Step 1 — Pick an environment & review variables

For this walkthrough we use **`dev`**. Open
`terraform/environments/dev/variables.tf` in the Terraform repository.
Sensible defaults are set; the ones you might change:

| Knob                  | Default              | What it controls                                     |
| --------------------- | -------------------- | ---------------------------------------------------- |
| `region`              | `us-east-1`          | AWS region for everything                            |
| `cluster_name`        | `banking-dev`        | EKS cluster name                                     |
| `vpc_cidr`            | `10.10.0.0/16`       | VPC address space                                    |
| `azs`                 | 3 × `us-east-1a/b/c` | AZs to spread subnets across                         |
| `node_instance_types` | `["t3.xlarge"]`      | Node size — t3.xlarge fits the full app + observability |
| `node_min/max/desired`| `3 / 6 / 4`          | Managed node group autoscaling bounds                |
| `single_nat_gateway`  | `true`               | One NAT (cheap) for dev; prod uses one per AZ        |
| `ecr_repository_name` | `banking-platform`   | The single ECR repo all services push to             |
| `domain_name`         | `vijaygiduthuri.in`  | Apex domain hosted in Route 53 (delegated from GoDaddy) |
| `create_apex_record`  | `false`              | Phase 5 flips this to `true` to add the apex ALIAS → NLB |

> 💡 **Sizing reality:** 30 Go services + gateway + Postgres/Redis/Kafka +
> Argo CD + the observability stack is a lot. The dev default is **`t3.xlarge`
> (4 vCPU/16 GB) × 4** — that's what we ran the full stack on. `t3.large` × 3 is
> too tight once observability + Argo are added (pods go `Pending`).

---

## Step 2 — Init and apply

```bash
cd terraform/environments/dev

terraform init             # configures the S3 backend (from Step 0)
terraform plan  -out=tfplan
terraform apply tfplan     # EKS control plane ~10-15 min — the slow step
```

### Apply order (if debugging a module)
```bash
terraform apply -target=module.vpc
terraform apply -target=module.iam
terraform apply -target=module.eks
terraform apply -target=module.ecr
terraform apply -target=module.s3
terraform apply -target=module.route53
```

### Useful outputs after apply
```bash
terraform output
# vpc_id               = "vpc-…"
# private_subnet_ids   = ["subnet-…", …]
# cluster_name         = "banking-dev"
# cluster_endpoint     = "https://….eks.amazonaws.com"
# oidc_provider_arn    = "arn:aws:iam::…:oidc-provider/…"   # for IRSA
# ecr_repository_url   = "<acct>.dkr.ecr.us-east-1.amazonaws.com/banking-platform"
# documents_bucket     = "banking-dev-documents-<acct>"
# route53_zone_id      = "Z0123456789ABCDEFGHIJ"
# route53_name_servers = ["ns-….awsdns-….com", …]   # 👈 paste into GoDaddy (Phase 5)
```

---

## Step 3 — Connect kubectl

```bash
aws eks update-kubeconfig --name banking-dev --region us-east-1

kubectl config current-context      # arn:aws:eks:us-east-1:…:cluster/banking-dev
kubectl get nodes
# Expect 3 Ready nodes:
# NAME                            STATUS   ROLES    AGE   VERSION
# ip-10-10-1xx….ec2.internal      Ready    <none>   5m    v1.31.x
# …
```

> The EKS API endpoint is public by default. For real environments, restrict it
> to your IP with `cluster_endpoint_public_access_cidrs` in the `eks` module (and
> optionally enable the private endpoint) — see the SSM bastion note below.

---

## Step 4 — Storage: EBS CSI driver + gp3 (already automated)

Postgres/Kafka and the observability stack use `PersistentVolumeClaims`, so the
cluster needs the **EBS CSI driver** and a default **gp3** StorageClass. Both are
handled for you — **no manual commands**:

- **EBS CSI driver** — the `eks` module installs it as a **managed add-on** with
  its own IRSA role (`aws-ebs-csi-driver` + the `eks` module). It comes up
  with the cluster on `terraform apply`.
- **gp3 default StorageClass** — applied via **GitOps** (kept out of Terraform so
  Terraform stays AWS-only). The `cluster-storage` Argo CD app creates `gp3` as
  the default and un-defaults the EKS-provided `gp2`. It syncs when you
  bootstrap Argo CD (Phase 4). The StorageClass manifests themselves are no
  longer kept in this repository — the platform's own StatefulSets create their
  PersistentVolumeClaims with the `gp3` class
  ([`k8s/10-infra.yaml`](../../k8s/10-infra.yaml)).

Verify after the cluster + Argo CD are up:
```bash
kubectl get storageclass
# gp3 (default)   ebs.csi.aws.com        ...
# gp2             kubernetes.io/aws-ebs  ...
```

> In the Helm chart, `postgres.storageClass` / `kafka.storageClass` are empty →
> they use the default StorageClass (this `gp3`). Set them explicitly for prod.

---

## Step 5 — Smoke-test the ECR repo

CI (Phase 3) pushes images here. Verify auth works:

```bash
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REG=$ACCOUNT.dkr.ecr.us-east-1.amazonaws.com
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin $REG

docker pull busybox:1.36
docker tag busybox:1.36 $REG/banking-platform:smoke-test
docker push $REG/banking-platform:smoke-test

aws ecr batch-delete-image --repository-name banking-platform \
  --image-ids imageTag=smoke-test --region us-east-1
```

If you get `denied: …`, the IAM identity lacks ECR push (attach the
`banking-<env>-ecr-push` policy from `terraform/modules/iam`) or you logged in
to the wrong registry host.

---

## Step 6 — Destroy when done (cost discipline)

EKS control plane is **~$73/mo** ($0.10/hr), plus NAT (~$32/mo each) and nodes.
Tear it all down when idle:

```bash
cd terraform/environments/dev
terraform destroy
```

> ⚠️ Delete Kubernetes `LoadBalancer` Services (Traefik, Phase 2) **before**
> `terraform destroy`, or the NLB + its ENIs can block VPC deletion. Also empty
> the S3 documents bucket if it has objects.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
| ------- | ------------ | --- |
| `Error: creating EKS Cluster … AccessDenied` | IAM identity lacks EKS permissions | Use an admin identity for the apply, or attach EKS/EC2/IAM perms. |
| `terraform init` → `bucket does not exist` | Remote-state bucket not created | Run **Step 0**, or `terraform init -backend=false` for a local trial. |
| EKS create hangs at `Still creating…` >15 min | Normal — control plane provisioning is slow | Wait; check the EKS console for an explicit error after 20 min. |
| `kubectl get nodes` → `Unauthorized` | Your IAM identity isn't mapped to the cluster | The creating identity has admin (`enable_cluster_creator_admin_permissions`). Use the same identity, or add an EKS access entry. |
| Nodes `NotReady` | VPC CNI / NAT egress issue | `kubectl describe node`; confirm NAT gateway exists and private route tables point to it. |
| PVCs stuck `Pending` | EBS CSI driver / StorageClass missing | Do **Step 4** (addon + gp3 default SC). |
| `denied` pushing to ECR | Missing ECR push policy or wrong login host | Attach `banking-<env>-ecr-push`; re-run `aws ecr get-login-password … | docker login`. |

---

## Optional: SSM bastion (private-endpoint hardening)

For private-only cluster access with no SSH keys and no open ports, use a small
EC2 instance reachable via **AWS Systems Manager Session Manager**:

- Launch a `t3.micro` in a **private** subnet with the
  `AmazonSSMManagedInstanceCore` policy; connect with
  `aws ssm start-session --target <instance-id>`.
- Flip the EKS endpoint to private (`cluster_endpoint_public_access = false`,
  `cluster_endpoint_private_access = true`) and drive `kubectl` from the bastion.

This isn't in the Terraform yet (dev/qa use the public, CIDR-restrictable
endpoint for simplicity). Add it as a `bastion` module when you want the
locked-down setup.

---

➡️ **Next:** [Phase 2 — Traefik Ingress](02-traefik-ingress.md)
