# Phase 4 — Deploy the Banking Platform with Argo CD (EKS)

> **Status:** 🗄️ **Archived.** The Argo CD applications and the Helm chart this
> guide bootstraps have been removed from this repository — the platform is now
> deployed from the plain manifests in [`k8s/`](../../k8s/) (see
> [`k8s/README.md`](../../k8s/README.md)). This guide is kept for reference:
> it still describes how Argo CD is wired up on the cluster, and the YAML
> excerpts below are the ones that were committed under `deploy/argocd/`.

**Goal:** Move the platform from a manual `helm install` to a GitOps loop where
**every push to `main` ends up in the cluster automatically**. After this phase:

```
you edit code  →  git push  →  GitHub Actions (build + push to ECR + bump values.yaml)
                                          ↓
                              Argo CD detects the values.yaml change
                                          ↓
                              Argo CD syncs the chart on the cluster
                                          ↓
                              new pods roll out with the new image tag
```

There is **no manual `helm upgrade` or `kubectl apply`** anywhere in that loop
once it's set up.

---

## Prerequisites (from earlier phases)

| What | How to check |
| ---- | ------------ |
| EKS cluster reachable from kubectl | `kubectl config current-context` returns the cluster ARN |
| Traefik installed (namespace `traefik`) | `kubectl -n traefik get svc traefik` shows an EXTERNAL-IP (NLB hostname) |
| CI pushes the service images | `docker pull docker.io/<username>/banking-platform/account-service-latest` succeeds |
| `helm` v3 + `kubectl` locally | `helm version`, `kubectl version --client` |
| EBS CSI driver + default `gp3` StorageClass | `kubectl get sc` shows `gp3 (default)` (Phase 1 Step 4) |

---

## Step 1 — Remove any manual Helm release (if you did one)

If you tested the chart with `helm install banking …`, delete it first so Argo CD
can **own** that same release (two controllers must not fight over the same
objects). If you never ran a manual install, skip to Step 2.

```bash
helm uninstall banking -n banking
```

**What survives** the uninstall:

| Resource | State |
| -------- | ----- |
| Deployments, Services, ConfigMaps, Secrets, HPAs, Ingress | deleted |
| Postgres + Kafka **PVCs** (`data-postgres-0`, `data-kafka-0`) | **preserved** |
| Namespace `banking` | preserved |

```bash
kubectl -n banking get pvc
# Expect: data-postgres-0 and data-kafka-0 both Bound
```

> Helm `uninstall` doesn't touch PVCs created by a StatefulSet's
> `volumeClaimTemplates`, so Postgres data + Kafka logs survive. When Argo CD
> re-creates the StatefulSets they reattach to the existing PVCs.

There's a **~1 minute window** between uninstall and Argo CD's first sync where
the app is unreachable — expected for a clean transition.

---

## Step 2 — Install Argo CD

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update argo

helm install argocd argo/argo-cd \
  --namespace argocd --create-namespace \
  --set server.service.type=ClusterIP \
  --set 'configs.params.server\.insecure=true' \
  --set 'configs.params.server\.rootpath=/argocd' \
  --wait --timeout=5m
```

What these flags do:

| Flag | Why |
| ---- | --- |
| `server.service.type=ClusterIP` | Put Argo CD behind the **existing Traefik NLB** via an IngressRoute — no second load balancer. |
| `configs.params.server\.insecure=true` | Argo serves plain HTTP; Traefik terminates TLS in Phase 7. Without this it redirects to `https://` and the route breaks. |
| `configs.params.server\.rootpath=/argocd` | Serve the UI under `/argocd`. The IngressRoute matches the same prefix. |
| `--wait --timeout=5m` | Block until all pods are Ready. |

Expect the Argo CD pods Running:
```bash
kubectl -n argocd get pods
# argocd-application-controller-0, -applicationset-controller, -dex-server,
# -notifications-controller, -redis, -repo-server, -server  (all Running)
```

---

## Step 3 — Expose Argo CD via Traefik (`/argocd` path)

Reuse the same Traefik NLB that fronts the app (Traefik's CRD provider is enabled
from Phase 2). Apply an IngressRoute in the `argocd` namespace:

```bash
kubectl apply -f - <<'EOF'
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: argocd
  namespace: argocd
spec:
  entryPoints:
    - web              # plain HTTP for now; Phase 7 adds TLS via websecure
  routes:
    - match: PathPrefix(`/argocd`)
      kind: Rule
      priority: 100    # MUST beat the app's Host && PathPrefix("/") router (once the
                       # banking app is deployed in Step 5) — else /argocd falls
                       # through to the frontend SPA. Traefik ranks by rule length,
                       # so set this explicitly.
      services:
        - name: argocd-server
          port: 80
EOF
```

> **No StripPrefix middleware.** Because we set `server.rootpath=/argocd`, Argo CD
> expects the `/argocd` prefix and rewrites its own links accordingly. Stripping
> it would break the UI.

Verify it's reachable through the NLB:
```bash
NLB=$(kubectl -n traefik get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl -sI -o /dev/null -w "/argocd  -> HTTP %{http_code}\n"  "http://${NLB}/argocd"
curl -sI -o /dev/null -w "/argocd/ -> HTTP %{http_code}\n"  "http://${NLB}/argocd/"
# Expect: /argocd -> 307 (redirect to trailing slash),  /argocd/ -> 200 (login)
```

### 3a — Open the UI + get the admin password

```bash
NLB=$(kubectl -n traefik get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "URL:      http://${NLB}/argocd/"
echo "Username: admin"
echo -n "Password: "; kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

Paste the URL (trailing slash matters) → Argo CD login page → log in as `admin`.

### 3b — (optional) Access via port-forward instead

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:80
# then open http://localhost:8080/argocd/
```

### 3c — Lock down the bootstrap password (do once)

After your first login: top-right (👤 admin) → **Update Password**, then delete
the one-shot secret:
```bash
kubectl -n argocd delete secret argocd-initial-admin-secret
```

---

## Step 4 — Give Argo CD access to the private repo (HTTPS + classic PAT)

`argocd-repo-server` has no Git identity. For a private repo, store credentials
in a labeled Secret. We use **HTTPS + a GitHub classic PAT** (Argo treats it as
the HTTP basic-auth password).

> A **fine-grained** PAT often returns **HTTP 404** because it needs each repo
> explicitly allow-listed at creation. A **classic** PAT with the `repo` scope
> sees every repo your account can — use that.

### 4a — Create the PAT
GitHub → **Settings → Developer settings → Personal access tokens (classic) →
Generate new token (classic)** → tick **`repo`** → copy the `ghp_…` value.

### 4b — Create the k8s Secret
```bash
GH_PAT='ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'

kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: banking-repo
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository   # how repo-server discovers creds
stringData:
  type: git
  url: https://github.com/vijaygiduthuri/banking_application_eks.git
  username: vijaygiduthuri
  password: ${GH_PAT}
EOF
```

### 4c — Verify
```bash
kubectl -n argocd get secret banking-repo \
  -o jsonpath='{.metadata.labels}{"\n"}'
# {"argocd.argoproj.io/secret-type":"repository"}
```

---

## Step 5 — Bootstrap GitOps (app-of-apps)

These manifests used to be **committed** under `deploy/argocd/`. That directory
has been removed from this repository together with the Helm chart it pointed
at. We use the **app-of-apps** pattern: you apply two bootstrap files once, and
a root Application creates everything else (`banking-platform`, `cert-manager`,
and the observability apps). The YAML for those files is reproduced below, so
you can recreate them if you want to run Argo CD alongside the plain
manifests.

### 5a — Repo URL (already set)

Every Application points at
`https://github.com/vijaygiduthuri/banking_application_eks.git`. Nothing to edit
— just make sure Argo CD has read credentials for it (Step 4) if the repo is
private.

### 5b — Apply the two bootstrap files

```bash
kubectl apply -f bootstrap/project.yaml    # AppProject "banking"  (copy from below)
kubectl apply -f bootstrap/root-app.yaml   # app-of-apps root     (copy from below)

kubectl -n argocd get applications
# platform-root, cluster-storage, metrics-server, banking-platform, cert-manager, cert-manager-issuer,
# kube-prometheus-stack, loki-stack, tempo, otel-collector, observability-extras, velero
```

That's it — Argo CD clones the repo and reconciles all of them. The rest of this
step shows **what those committed files contain** (identical YAML, for reference).

<details>
<summary>AppProject + banking-platform Application (contents of the committed files)</summary>

```bash
export REPO_URL="https://github.com/vijaygiduthuri/banking_application_eks.git"
export REVISION="main"
```

**AppProject** — scopes allowed repos + namespaces:
```bash
kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: banking
  namespace: argocd
spec:
  description: Banking platform
  sourceRepos:
    - "${REPO_URL}"
    - "https://prometheus-community.github.io/helm-charts"
    - "https://grafana.github.io/helm-charts"
    - "https://open-telemetry.github.io/opentelemetry-helm-charts"
  destinations:
    - { server: https://kubernetes.default.svc, namespace: banking }
    - { server: https://kubernetes.default.svc, namespace: observability }
    - { server: https://kubernetes.default.svc, namespace: argocd }
  clusterResourceWhitelist:
    - { group: "*", kind: "*" }
EOF
```

**Application** — deploys the chart, auto-syncs, and ignores the immutable
StatefulSet `volumeClaimTemplates` (see Troubleshooting):
```bash
kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: banking-platform
  namespace: argocd
spec:
  project: banking
  source:
    repoURL: ${REPO_URL}
    targetRevision: ${REVISION}
    path: k8s                       # plain manifests — no chart, no templating
    directory:
      recurse: true
  destination:
    server: https://kubernetes.default.svc
    namespace: banking
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
      - RespectIgnoreDifferences=true
  ignoreDifferences:
    - group: apps
      kind: StatefulSet
      jsonPointers:
        - /spec/volumeClaimTemplates
EOF
```

</details>

`syncPolicy.automated` means Argo starts cloning + reconciling immediately — no
manual `argocd app sync`.

**Expected boot timeline** (~60–90 s):
```
0s   Argo discovers the Application, clones the repo
10s  Helm chart rendered; all manifests applied
15s  Postgres + Kafka PVCs reattach (same data as before uninstall)
20s  postgres-0 + kafka-0 Running
20s  Go services start; some fail first attempt — Postgres/Kafka DNS not ready yet
40s  Postgres/Kafka readiness passes; services restart (fail-fast) and connect
75s  All pods Running 1/1
```

The first ~20 s of `CrashLoopBackOff` is **expected**: our services exit on
startup if Postgres/Kafka isn't reachable yet; the kubelet restarts them and
they come up cleanly once the datastores are ready.

**Verify:**
```bash
kubectl -n argocd get app banking-platform
# NAME               SYNC STATUS   HEALTH STATUS
# banking-platform   Synced        Healthy

kubectl -n banking get pods         # ~35 pods Running 1/1 after ~90s
```

---

### 5c — Verify EVERYTHING Argo CD created (all apps + all namespaces)

Step 5b applies the app-of-apps, which fans out into **12 Argo CD Applications**
across several namespaces — not just `banking-platform`. Use the commands below to
confirm the whole cluster is healthy.

**1. All Argo CD applications at a glance** (the master health view):
```bash
kubectl get applications -n argocd
```
Expected — all `Synced` + `Healthy` (only `platform-root` may read `OutOfSync`; see note below):
```
NAME                    SYNC STATUS   HEALTH STATUS
banking-platform        Synced        Healthy
cert-manager            Synced        Healthy
cert-manager-issuer     Synced        Healthy
cluster-storage         Synced        Healthy
kube-prometheus-stack   Synced        Healthy
loki-stack              Synced        Healthy
metrics-server          Synced        Healthy
observability-extras    Synced        Healthy
otel-collector          Synced        Healthy
platform-root           OutOfSync     Healthy
tempo                   Synced        Healthy
velero                  Synced        Healthy
```

**What each app deploys and where it runs:**

| Namespace       | What's there                                                                                          | Argo app(s)                                                              |
|-----------------|-------------------------------------------------------------------------------------------------------|-------------------------------------------------------------------------|
| `argocd`        | 7 Argo CD components                                                                                   | (installed in Step 2)                                                    |
| `banking`       | 30 microservices + api-gateway + frontend + postgres + kafka + redis                                   | `banking-platform`                                                       |
| `cert-manager`  | controller, cainjector, webhook + the ClusterIssuer                                                    | `cert-manager`, `cert-manager-issuer`                                    |
| `kube-system`   | EBS CSI driver, metrics-server, coredns                                                                | `cluster-storage`, `metrics-server`                                      |
| `observability` | grafana, prometheus, alertmanager, loki, promtail, tempo, otel-collector, node-exporters              | `kube-prometheus-stack`, `loki-stack`, `tempo`, `otel-collector`, `observability-extras` |
| `traefik`       | 2 Traefik ingress pods (the NLB)                                                                       | (installed in Step 2 / docs 02)                                          |
| `velero`        | velero server + node-agents                                                                            | `velero`                                                                 |

**2. All pods in the whole cluster:**
```bash
kubectl get pods -A
```

**3. Per Argo-app namespaces — check the "other" apps individually:**
```bash
# cert-manager (+ the issuer and any TLS certs)
kubectl get pods -n cert-manager
kubectl get clusterissuer,certificate,certificaterequest -A

# storage (EBS CSI) + metrics-server
kubectl get pods -n kube-system
kubectl get storageclass                        # cluster-storage → gp3 (default) + gp2

# observability stack (kube-prometheus-stack, loki, tempo, otel, extras)
kubectl get pods -n observability
kubectl get svc  -n observability

# velero
kubectl get pods -n velero
kubectl get backupstoragelocation -n velero     # PHASE should be "Available"

# traefik ingress
kubectl get pods -n traefik
kubectl get svc  -n traefik                      # the AWS NLB (EXTERNAL-IP)
```

**4. One-shot cluster-wide overview:**
```bash
kubectl get applications -n argocd
kubectl get pods,svc,ingressroute -A
kubectl get pvc -A                               # postgres/kafka/redis/loki/prometheus volumes → Bound
kubectl get nodes -o wide
```

**5. Drill into any single app** (replace `<app>`):
```bash
kubectl get application <app> -n argocd -o wide
kubectl describe application <app> -n argocd | sed -n '/Status:/,$p'
```

> **Note — `platform-root` shows `OutOfSync` but `Healthy`:** this is the
> app-of-apps root. As long as all 12 child apps are `Synced`, the root being
> `OutOfSync` is cosmetic (a minor field drift Argo adds to the child Application
> objects) and blocks nothing. To inspect the drift:
> ```bash
> kubectl get application platform-root -n argocd \
>   -o jsonpath='{range .status.resources[?(@.status=="OutOfSync")]}{.kind}/{.name}: {.status}{"\n"}{end}'
> ```
> You can leave it as-is, or click **Sync** on `platform-root` in the Argo CD UI.

---

## Step 6 — Verify the GitOps loop end-to-end

```
 1. edit any service (e.g. add a comment)
 2. git push origin main
 3. .github/workflows/devsecops.yaml runs
       → build → Trivy scan → push to Docker Hub  <service>-<sha> / <service>-latest
 4. Argo CD poller (default 3 min) sees the commit  — or click "Refresh" in the UI
 5. Argo diffs cluster vs git, sees new image tags → OutOfSync
 6. selfHeal=true → Argo applies the new spec → kubelet rolls the pods
 7. New pods run the just-built image. Done.
```

Smoke test once green (through the gateway):
```bash
NLB=$(kubectl -n traefik get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
TOKEN=$(curl -s -X POST http://$NLB/api/v1/auth/register -H "Host: vijaygiduthuri.in" \
  -d '{"email":"gitops@bank.io","password":"password123"}' | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')
echo "token len: ${#TOKEN}"
```
(Once DNS is set in Phase 5 you'll use `https://vijaygiduthuri.in` directly.)

---

## A note on routing (path-based, single apex host)

This doc set serves **everything on the apex `vijaygiduthuri.in`** with
**path-based routing** — no subdomains. Argo CD lives at **`/argocd`** on the
shared Traefik NLB (one LB, one Route 53 apex ALIAS — see docs 05 and 07),
alongside the app at `/` and (Phase 7) Grafana/Prometheus/Alertmanager at
`/grafana`, `/prometheus`, `/alertmanager`. One host keeps everything under a
single TLS cert and needs no extra DNS records.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
| ------- | ------------ | --- |
| App `ComparisonError: SSH agent requested but SSH_AUTH_SOCK not-specified` | `repoURL` is the `git@github.com:…` SSH form but the Secret holds an HTTPS PAT | Use `https://github.com/vijaygiduthuri/banking_application_eks.git` in the Secret **and** the Application. |
| GitHub API `HTTP 404` for `/repos/<you>/<repo>` with a valid PAT | Fine-grained PAT missing this repo in its allowlist | Add the repo to the token, or use a **classic** PAT with `repo` scope. |
| App permanently `OutOfSync` with only `StatefulSet/postgres` + `StatefulSet/kafka` differing | `volumeClaimTemplates` is immutable after creation | Keep the `ignoreDifferences` block + `RespectIgnoreDifferences=true` (already in Step 5). |
| Many service pods `CrashLoopBackOff` right after sync | Services started before Postgres/Kafka DNS resolved (fail-fast exit) | **Expected.** Wait ~60–90 s. If still crashing after 2 min, `kubectl logs <pod> --previous` for a real error. |
| Argo UI loads but assets 404 / blank | `server.rootpath` not set, or a StripPrefix middleware on the route | `helm upgrade argocd argo/argo-cd -n argocd --reuse-values --set 'configs.params.server\.rootpath=/argocd'`; do **not** add StripPrefix. |
| App `Unknown / Unable to connect to repository` | Repo Secret missing the `repository` label, or its `url` doesn't byte-match `source.repoURL` | Confirm the label; make `url` and `repoURL` match exactly (incl. trailing `.git`). |
| CI `update-gitops` push denied | `GITHUB_TOKEN` lacks `contents:write` or branch protection blocks bots | Settings → Actions → Workflow permissions = **Read and write**, or set `GITOPS_TOKEN` PAT. |
| `ImagePullBackOff` after sync | Tag not in ECR / node can't pull | Confirm CI pushed the tag; node role has ECR read (from `iam` module). |

---

➡️ **Next:** [Phase 5 — DNS (GoDaddy)](05-dns-godaddy.md)
