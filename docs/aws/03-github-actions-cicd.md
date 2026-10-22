# Phase 3 — CI/CD with GitHub Actions (→ Amazon ECR)

> **Status:** ✅ Written *as we do it*. Reflects the exact workflow file and the
> IAM / repo config that make it run.

**Goal:** On every push to `main`, **build → scan → push** all service images to
a single **Amazon ECR** repository. **Argo CD (Phase 4) does the deploy** —
this pipeline never runs `helm` or `kubectl`.

> **Note (repository state as of today).** The pipeline that lives in this
> repository now lives in
> [`.github/workflows/devsecops.yaml`](../../.github/workflows/devsecops.yaml):
> it builds and Trivy-scans every service image and pushes it to **Docker Hub**
> (`docker.io/<username>/banking-platform:<service>-<sha>` and `:latest`).
> There is **no GitOps bump job** any more — the image tags live directly in
> the plain manifests under [`k8s/`](../../k8s/). The rest of this guide
> documents the original ECR-based pipeline, which is still accurate for the
> ECR repository, IAM user and secret setup.

**Time:** ~10 minutes to configure (IAM user + repo secrets); builds run on push.

Workflow file:
[.github/workflows/devsecops.yaml](../../.github/workflows/devsecops.yaml)
(build/scan/push). The Terraform `fmt`/`validate` workflow lives in the
Terraform repository.

---

## Why it's built this way

| Decision | Why |
| -------- | --- |
| **GitOps split** — CI pushes images + bumps `values.yaml`; Argo CD deploys | One source of truth (git); the pipeline needs **no cluster credentials** at all |
| **Single ECR repo, tag-prefix per service** (`banking-platform:auth-service-<sha>`) | One repo to manage/scan/set lifecycle on, instead of 32 repos |
| **Matrix build** (32 workloads in parallel) | Whole platform rebuilt predictably; a shared change (in `pkg/`) rebuilds all |
| **Static IAM access keys** | Simplest to wire up; the CI user holds **only** an ECR-push policy (least privilege) |
| **Trivy scan** (report-only by default) | Scans every image for HIGH/CRITICAL and prints a table; `exit-code: "0"` so it never blocks (learning setup). Flip to `"1"` to make it a hard gate |
| **`[skip ci]` on the bump commit** | The GitOps commit must not re-trigger the pipeline (infinite loop) |

---

## Pipeline overview

```
push to main
   │
   ├─ build   (matrix: 30 services + api-gateway + frontend, in parallel)
   │     docker build (Buildx + GHA layer cache)
   │        → Trivy scan (HIGH/CRITICAL, report-only: exit-code 0)
   │        → push to ECR:
   │             <acct>.dkr.ecr.<region>.amazonaws.com/banking-platform:<service>-<sha>
   │             …:<service>-latest
   │
   └─ (today: push to Docker Hub, no version bump — the image tags live in k8s/)
```

---

## ✅ Prerequisites

| Need | How to check / get |
| ---- | ------------------ |
| ECR repo `banking-platform` exists (Phase 1) | `aws ecr describe-repositories --repository-names banking-platform` |
| ECR-push IAM **policy** from the `iam` module | `aws iam list-policies --scope Local --query "Policies[?PolicyName=='banking-dev-ecr-push'].Arn"` |
| Repo pushed to GitHub | `git remote -v` |
| `aws` CLI configured (admin, for the one-time IAM setup) | `aws sts get-caller-identity` |

---

## Step 1 — Create an IAM user for CI (ECR push only)

CI authenticates with **static access keys**. Give the user *only* the ECR-push
policy that Terraform already created — nothing else.

```bash
# 1a. Create the CI user
aws iam create-user --user-name banking-ci

# 1b. Find the ECR-push policy ARN (from terraform/modules/iam)
POLICY_ARN=$(aws iam list-policies --scope Local \
  --query "Policies[?PolicyName=='banking-dev-ecr-push'].Arn" --output text)
echo "$POLICY_ARN"

# 1c. Attach it
aws iam attach-user-policy --user-name banking-ci --policy-arn "$POLICY_ARN"

# 1d. Mint an access key (note the AccessKeyId + SecretAccessKey — shown once)
aws iam create-access-key --user-name banking-ci
```

> The `ecr_push` policy grants `ecr:GetAuthorizationToken` + push/pull on the
> single repo. For a hardening upgrade later, swap static keys for **GitHub OIDC**
> (`role-to-assume`) so there are no long-lived credentials — the workflow's
> `configure-aws-credentials` step supports both.

---

## Step 2 — Configure GitHub repo secrets & variables

**Settings → Secrets and variables → Actions**

| Kind | Name | Value |
|------|------|-------|
| Secret | `AWS_ACCESS_KEY_ID` | from Step 1d |
| Secret | `AWS_SECRET_ACCESS_KEY` | from Step 1d |
| Secret | `GITOPS_TOKEN` *(optional)* | classic PAT with `contents:write`, only if branch protection blocks the default `GITHUB_TOKEN` |
| Variable | `AWS_REGION` | `us-east-1` |
| Variable | `ECR_REGISTRY` | `<account>.dkr.ecr.us-east-1.amazonaws.com` |
| Variable | `ECR_REPOSITORY` | `banking-platform` |

Get the registry host for `ECR_REGISTRY`:
```bash
echo "$(aws sts get-caller-identity --query Account --output text).dkr.ecr.us-east-1.amazonaws.com"
```

The workflow composes them into one prefix:
```yaml
IMAGE_PREFIX: ${{ vars.ECR_REGISTRY }}/${{ vars.ECR_REPOSITORY }}
# → <account>.dkr.ecr.us-east-1.amazonaws.com/banking-platform
```

---

## Step 3 — How the `build` job works

Each matrix leg (one per service + frontend) runs, in order:

| Step | What it does |
| ---- | ------------ |
| **Resolve build inputs** | Backends share `build/service.Dockerfile` with `SERVICE=<name>` build-arg; the frontend uses `frontend/Dockerfile`. |
| **Configure AWS credentials** | `aws-actions/configure-aws-credentials@v4` with the static keys. |
| **Login to Amazon ECR** | `aws-actions/amazon-ecr-login@v2`. |
| **Build (load, no push)** | Buildx builds locally with **GHA layer cache** (`cache-from/to: type=gha, scope=<service>`) so rebuilds are fast. |
| **Trivy scan** | `aquasecurity/trivy-action@v0.36.0`, **report-only** (`exit-code: "0"`, `ignore-unfixed: true`) — scans + prints, never blocks. Set `exit-code: "1"` to hard-gate on fixable HIGH/CRITICAL. |
| **Push to ECR** | **Only** on `push` to `main` (PRs build+scan as a gate, no push). |

Image naming — single repo, tag-prefix per service:
```
<account>.dkr.ecr.us-east-1.amazonaws.com/banking-platform:auth-service-<sha>
                                                           :auth-service-latest
```

---

## Step 4 — How the `update-gitops` job works

This job no longer exists. It used to run once after **all** builds passed, on
`main` only, and it rewrote the image tag of every service in the Helm
`values.yaml` so that Argo CD would pick the new images up.

Today there is nothing to bump: the tags are written directly in the
manifests under [`k8s/`](../../k8s/), and the images are published to Docker
Hub as `<service>-<sha>` and `<service>-latest`. To pin a rollout to a specific
build, edit the `image:` line of that service in
[`k8s/20-services.yaml`](../../k8s/20-services.yaml) and re-apply:
`kubectl apply -f k8s/`.

---

## Step 5 — Trigger and watch

```bash
git commit --allow-empty -m "ci: trigger"   # or push a real change
git push origin main
```

Watch the **Actions** tab → the `build` matrix, then `update-gitops`. On success
you'll see a new commit on `main` updating `values.yaml`, which Argo CD picks up.

Verify images landed in ECR:
```bash
aws ecr list-images --repository-name banking-platform --region us-east-1 \
  --query 'imageIds[].imageTag' --output table | head
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
| ------- | ------------ | --- |
| `denied: not authorized to perform: ecr:...` | CI user lacks the ECR-push policy | Attach `banking-<env>-ecr-push` to the `banking-ci` user (Step 1c). |
| `no basic auth credentials` on push | `amazon-ecr-login` step skipped or AWS creds not set | Confirm the `AWS_ACCESS_KEY_ID`/`SECRET` secrets and the `AWS_REGION` variable exist. |
| `Unable to resolve action aquasecurity/trivy-action@0.28.0` | The action was retagged with a `v` prefix; bare `0.x.x` no longer resolves | Use a `v`-prefixed tag, e.g. `aquasecurity/trivy-action@v0.36.0`. |
| Trivy reports a base-image CVE but you want it to fail | Currently report-only (`exit-code: "0"`) | Set the scan `exit-code: "1"` to hard-gate on fixable HIGH/CRITICAL. |
| `update-gitops` push rejected | Branch protection blocks `GITHUB_TOKEN` | Add a `GITOPS_TOKEN` classic PAT with `contents:write`. |
| Pipeline loops forever | Bump commit re-triggered CI | Ensure the bump commit message contains `[skip ci]` (it does by default). |
| Buildx cache misses every run | First run / cache eviction | Normal on first build; subsequent runs are cached per service (`scope=<service>`). |
| `repository … does not exist` on push | ECR repo missing or wrong region | Apply Phase 1 Terraform (`ecr` module); confirm `AWS_REGION`/`ECR_REGISTRY`. |

---

➡️ **Next:** [Phase 4 — Argo CD](04-argocd.md)
