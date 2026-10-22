# Phase 7 — HTTPS with Let's Encrypt + Path-Routed Sub-Apps (EKS)

> **Status:** ✅ Written *as we do it* on the EKS cluster.

**Goal:** Install **cert-manager**, mint a free **Let's Encrypt** certificate for
your domain, flip the app to **HTTPS**, and move Argo CD + Grafana + Prometheus
+ Alertmanager over to HTTPS too — so you finish with:

```
https://vijaygiduthuri.in                — the banking app UI
https://vijaygiduthuri.in/argocd         — Argo CD UI
https://vijaygiduthuri.in/grafana        — Grafana
https://vijaygiduthuri.in/prometheus     — Prometheus
https://vijaygiduthuri.in/alertmanager   — Alertmanager
```

**Time:** ~15 minutes (most of it Let's Encrypt issuing the cert).

> Set this once and reuse it below:
> ```bash
> export HOSTNAME_APP="vijaygiduthuri.in"     # 👈 your apex domain (from Phase 5)
> export ACME_EMAIL="vijaygiduthuri@gmail.com"        # 👈 Let's Encrypt expiry notices
> ```

---

## What & why

After Phase 5 you have HTTP working. Browsers warn on HTTP and many auth flows
refuse to run over it, so HTTPS is next.

**cert-manager** is the Kubernetes operator that obtains + renews TLS certs from
ACME servers. We use Let's Encrypt with the **HTTP-01** challenge: cert-manager
serves a token at `http://<host>/.well-known/acme-challenge/…`, Let's Encrypt
fetches it to prove you control the domain, and issues a 90-day cert (auto-renewed
at ~day 75).

```
  cert-manager (cert-manager ns)
     ClusterIssuer "letsencrypt-prod"
                 │  HTTP-01 via Traefik (ingressClass: traefik)
                 ▼
  Certificate → Secret "banking-tls" (banking ns)   ← created automatically by
                 │                                     cert-manager's ingress-shim
                 ▼                                     from the app's Ingress
  Traefik serves TLS on :443 for vijaygiduthuri.in
  (the same Secret is copied to argocd/observability for their routes)
```

**Two cert paths in this doc:**
- **App** — the chart's `Ingress` carries a `cert-manager.io/cluster-issuer`
  annotation, so cert-manager **auto-issues** `banking-tls` when you flip
  `ingress.tls=true`. Pure GitOps — no manual `Certificate`.
- **Argo CD / Grafana / Prometheus / Alertmanager** — these use Traefik
  **IngressRoutes**; we **reuse the app's cert** (same host) by copying the
  `banking-tls` Secret into their namespaces.

---

## ✅ Prerequisites

| Check | How |
|---|---|
| Phase 5 done (domain resolves to the NLB) | `dig +short ${HOSTNAME_APP}` → the NLB hostname |
| Phase 6 done (observability) | `kubectl -n observability get pods` healthy |
| Port 80 reachable from the internet | HTTP-01 challenge uses it; Traefik listens on 80 |
| `kubectl` + `helm` work | `kubectl get nodes`, `helm version` |

> 💡 **Keep port 80 open** even after going HTTPS — cert-manager needs it for
> renewals. Traefik redirects normal `:80` traffic to `:443` (Step 7) while still
> passing `/.well-known/acme-challenge/…` through to the solver.

---

## Step 1 — Install cert-manager

Pick one path.

### Option A — Argo CD Application (GitOps)

cert-manager is an Application in the app-of-apps, and the `banking`
AppProject allows the jetstack repo + `cert-manager` namespace. So if you
bootstrapped Argo CD in Phase 4, **cert-manager is already installed** — no
patch, no manual apply.

> The Argo CD application manifests were removed from this repository together
> with the rest of `deploy/`. The manifest this page needs is now
> [`k8s/45-tls-clusterissuer.yaml`](../../k8s/45-tls-clusterissuer.yaml).

Confirm it's healthy:
```bash
kubectl -n argocd get app cert-manager -w   # wait for Synced / Healthy, Ctrl+C
```

<details>
<summary>Contents of the committed cert-manager Application (for reference)</summary>

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cert-manager
  namespace: argocd
spec:
  project: banking
  source:
    repoURL: https://charts.jetstack.io
    chart: cert-manager
    targetRevision: v1.15.3
    helm:
      values: |
        crds:
          enabled: true
        replicaCount: 2
        global:
          leaderElection:
            namespace: cert-manager   # keep leader-election RBAC out of kube-system
        resources:
          requests: { cpu: 50m, memory: 64Mi }
          limits: { cpu: 200m, memory: 128Mi }
  destination:
    server: https://kubernetes.default.svc
    namespace: cert-manager
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true, ServerSideApply=true]  # CRDs > annotation limit → SSA
```

</details>

### Option B — Direct `helm install`

```bash
helm repo add jetstack https://charts.jetstack.io
helm repo update jetstack

helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --set crds.enabled=true \
  --set replicaCount=2 \
  --set global.leaderElection.namespace=cert-manager \
  --wait --timeout=5m
```

Either way, verify:
```bash
kubectl get crd | grep cert-manager.io   # 6 CRDs
kubectl -n cert-manager get pods          # cert-manager (×2), cainjector, webhook Running
```

---

## Step 2 — Let's Encrypt ClusterIssuer (already GitOps-managed)

The `letsencrypt-prod` ClusterIssuer is **committed**
([`k8s/45-tls-clusterissuer.yaml`](../../k8s/45-tls-clusterissuer.yaml)) and
applied by the `cert-manager-issuer` Argo app — so once Argo CD is bootstrapped
(Phase 4), it's created automatically (it retries until the cert-manager CRDs
exist). Without Argo CD, apply it yourself:

```bash
kubectl apply -f k8s/45-tls-clusterissuer.yaml
```

Just confirm it's ready:

```bash
kubectl get clusterissuer
# NAME               READY   AGE
# letsencrypt-prod   True    30s
```

<details>
<summary>Contents of the committed ClusterIssuer (for reference)</summary>

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: vijaygiduthuri@gmail.com
    privateKeySecretRef:
      name: letsencrypt-prod-account-key
    solvers:
      - http01:
          ingress:
            class: traefik
```

</details>

> Iterating and worried about the **5 certs/week/domain** prod rate limit? Add a
> second issuer `letsencrypt-staging` with
> `server: https://acme-staging-v02.api.letsencrypt.org/directory` and use it
> while debugging (staging is unlimited but browser-untrusted).

---

## Step 3 — Flip the app to HTTPS (GitOps, via the chart)

Our app is a standard `Ingress` with a `cert-manager.io/cluster-issuer`
annotation baked in, so we just toggle values and let Argo + cert-manager do the
rest — no manual `Certificate`, no auto-sync override.

The Ingress in [`k8s/40-ingress.yaml`](../../k8s/40-ingress.yaml) is
**already set up for TLS** in the repo:
```yaml
spec:
  ingressClassName: traefik
  tls:
    - hosts:
        - vijaygiduthuri.in        # from Phase 5
      secretName: banking-tls     # cert-manager auto-issues this
  rules:
    - host: vijaygiduthuri.in
      # ...
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
```

> 📌 **You don't need to edit anything here** — because `tls: true` is committed,
> cert-manager's ingress-shim tries to issue `banking-tls` as soon as the app
> deploys (Phase 4). If DNS isn't delegated yet, the cert just sits `READY=False`
> and **auto-issues the moment Phase 5 DNS resolves** (HTTP-01 needs the public
> name). No manual flip. *(If you ever want the app on plain HTTP first, set
> `tls: false`, and flip it back to `true` after DNS — then commit.)*

Wait for the cert, then confirm it's a real Let's Encrypt cert:
```bash
kubectl -n banking get certificate -w      # banking-tls  READY=True (30-60s), Ctrl+C

kubectl -n banking get secret banking-tls \
  -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -issuer -dates
# issuer=C=US, O=Let's Encrypt, CN=R10/R11
```

Smoke test:
```bash
curl -sI "https://${HOSTNAME_APP}/" | head -1                       # HTTP/2 200
curl -s  "https://${HOSTNAME_APP}/api/v1/fx/rates" | head -c 120; echo
```

🎉 The app is on **HTTPS with a browser-trusted cert**.

> **If issuance is stuck:** `kubectl -n banking describe certificate banking-tls`
> and `kubectl -n banking get challenges`. The usual cause is port 80 not
> reachable — test:
> `curl -v http://${HOSTNAME_APP}/.well-known/acme-challenge/test` should return
> **404** (reached Traefik), not connection-refused.

---

## Step 4 — Serve Grafana / Prometheus / Alertmanager under sub-paths

Path-routing these UIs means they must know their sub-path (else assets/links
break). These keys already exist in
[`observability/values/kube-prometheus-stack.yaml`](../../observability/values/kube-prometheus-stack.yaml)
— if you did the Phase 6
HTTP access step (doc 06, Step 5a) they're set to `http://`; now that TLS is in
place, **change the scheme to `https://`** so the browser loads assets over HTTPS
(a `root_url`/`externalUrl` of `http://` on an HTTPS page causes mixed-content
breakage — the mirror image of the Phase 6 problem):

```yaml
grafana:
  grafana.ini:
    server:
      root_url: "https://vijaygiduthuri.in/grafana"   # was http:// in Phase 6
      serve_from_sub_path: true

prometheus:
  prometheusSpec:
    routePrefix: /prometheus
    externalUrl: https://vijaygiduthuri.in/prometheus  # was http:// in Phase 6

alertmanager:
  alertmanagerSpec:
    routePrefix: /alertmanager
    externalUrl: https://vijaygiduthuri.in/alertmanager  # was http:// in Phase 6
```

Commit → Argo re-syncs the `kube-prometheus-stack` app. (Argo CD itself already
serves under `/argocd` from Phase 4's `server.rootpath`.)

```bash
git add observability/values/kube-prometheus-stack.yaml
git commit -m "phase 7: serve grafana/prometheus/alertmanager under sub-paths"
git push origin main
kubectl -n argocd annotate app kube-prometheus-stack argocd.argoproj.io/refresh=hard --overwrite
```

Changing these values rolls the Grafana, Prometheus, and Alertmanager pods. Watch
them recreate and come back healthy before moving on (Ctrl+C to stop watching):

```bash
kubectl get pods -n observability -w
# grafana + prometheus-… + alertmanager-… terminate and restart with the new
# https config; wait until all show Running and fully READY (e.g. 3/3, 2/2)
```

---

## Step 5 — HTTPS routes for Argo CD / Grafana / Prometheus / Alertmanager

Two things: (1) Traefik reads the TLS Secret **from the IngressRoute's own
namespace**, so copy `banking-tls` into `argocd` + `observability`; (2) apply the
`websecure` IngressRoutes.

### 5a — Copy the TLS Secret into the other namespaces
Extract the cert + key and recreate a clean Secret in each namespace (avoids
carrying over `resourceVersion`/`uid`/owner metadata that a raw `-o yaml` copy
would):
```bash
CRT=$(kubectl -n banking get secret banking-tls -o jsonpath='{.data.tls\.crt}')
KEY=$(kubectl -n banking get secret banking-tls -o jsonpath='{.data.tls\.key}')
for ns in argocd observability; do
kubectl apply -n "$ns" -f - <<EOF
apiVersion: v1
kind: Secret
metadata: { name: banking-tls, namespace: $ns }
type: kubernetes.io/tls
data:
  tls.crt: ${CRT}
  tls.key: ${KEY}
EOF
done
```
> 💡 cert-manager only renews the **original** Secret (`banking` ns). After a
> renewal (~day 75) re-run these two copies — or install
> [reflector](https://github.com/emberstack/kubernetes-reflector) to auto-propagate.

**Verify the Secret landed in both namespaces:**
```bash
kubectl get secret banking-tls -n argocd
kubectl get secret banking-tls -n observability
# NAME          TYPE                DATA   AGE
# banking-tls   kubernetes.io/tls   2      5s        (DATA=2 → tls.crt + tls.key)
```

> ⚠️ **Set an explicit `priority` on these routes.** The banking app is a plain
> k8s `Ingress` whose router is `Host(...) && PathPrefix(\`/\`)`. Traefik derives
> router priority from **rule length**, so that `/` router can out-rank a bare
> `PathPrefix(\`/argocd\`)` — and then **every path falls through to the frontend
> SPA** (which serves `index.html` for any URL, so it looks like a redirect to the
> app). Give each sub-path route `priority: 100` so it always wins over `/`.

### 5b — Argo CD IngressRoute (HTTPS)
```bash
kubectl apply -f - <<EOF
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: argocd
  namespace: argocd
spec:
  entryPoints: [websecure]
  routes:
    - match: Host(\`${HOSTNAME_APP}\`) && PathPrefix(\`/argocd\`)
      kind: Rule
      priority: 100          # beat the app's Host && PathPrefix("/") router
      services:
        - name: argocd-server
          port: 80
  tls:
    secretName: banking-tls
EOF
```

**Verify:**
```bash
kubectl -n argocd get ingressroute argocd
# NAME     AGE
# argocd   5s

# confirm it's on the websecure entrypoint and using the TLS Secret:
kubectl -n argocd get ingressroute argocd -o jsonpath='{.spec.entryPoints} {.spec.tls.secretName}{"\n"}'
# [websecure] banking-tls
```

### 5c — Grafana / Prometheus / Alertmanager IngressRoutes (HTTPS)
```bash
kubectl apply -f - <<EOF
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata: { name: grafana, namespace: observability }
spec:
  entryPoints: [websecure]
  routes:
    - match: Host(\`${HOSTNAME_APP}\`) && PathPrefix(\`/grafana\`)
      kind: Rule
      priority: 100
      services:
        - { name: kube-prometheus-stack-grafana, port: 80 }
  tls: { secretName: banking-tls }
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata: { name: prometheus, namespace: observability }
spec:
  entryPoints: [websecure]
  routes:
    - match: Host(\`${HOSTNAME_APP}\`) && PathPrefix(\`/prometheus\`)
      kind: Rule
      priority: 100
      services:
        - { name: kube-prometheus-stack-prometheus, port: 9090 }
  tls: { secretName: banking-tls }
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata: { name: alertmanager, namespace: observability }
spec:
  entryPoints: [websecure]
  routes:
    - match: Host(\`${HOSTNAME_APP}\`) && PathPrefix(\`/alertmanager\`)
      kind: Rule
      priority: 100
      services:
        - { name: kube-prometheus-stack-alertmanager, port: 9093 }
  tls: { secretName: banking-tls }
EOF
```

**Verify all three HTTPS routes:**
```bash
kubectl -n observability get ingressroute
# NAME                AGE
# alertmanager        5s      ← websecure (this step)
# grafana             5s      ← websecure (this step)
# prometheus          5s      ← websecure (this step)
# alertmanager-http   …       ← the Phase 6 http routes (delete after this step)
# grafana-http        …
# prometheus-http     …

# confirm each new one is websecure + TLS:
for r in grafana prometheus alertmanager; do
  echo -n "$r: "
  kubectl -n observability get ingressroute $r -o jsonpath='{.spec.entryPoints} {.spec.tls.secretName}{"\n"}'
done
# grafana: [websecure] banking-tls
# prometheus: [websecure] banking-tls
# alertmanager: [websecure] banking-tls
```

> 🧹 Now that the `websecure` routes exist, **delete the Phase 6 HTTP routes** so
> they don't linger (Step 7's redirect would otherwise loop them to HTTPS anyway):
> ```bash
> kubectl -n observability delete ingressroute grafana-http prometheus-http alertmanager-http
> ```

---

## Step 6 — Verify all 5 URLs over HTTPS

```bash
D=$HOSTNAME_APP
curl -sI  "https://$D/"                    | head -1   # 200  (app)
curl -sIL "https://$D/argocd/"             | head -1   # 200  (Argo, 307→200)
curl -sIL "https://$D/grafana/login"       | head -1   # 200  (Grafana)
curl -sIL "https://$D/prometheus/-/ready"  | head -1   # 200  (Prometheus)
curl -sL  "https://$D/alertmanager/-/ready"            # OK   (Alertmanager)
```

Open each in a browser — expect the **🔒 padlock** (Let's Encrypt issuer):
- https://vijaygiduthuri.in/            → banking UI
- https://vijaygiduthuri.in/argocd/     → Argo CD (admin / your password)
- https://vijaygiduthuri.in/grafana/    → Grafana (admin / admin)
- https://vijaygiduthuri.in/prometheus/ → Prometheus
- https://vijaygiduthuri.in/alertmanager/ → Alertmanager

---

## Step 7 — Redirect HTTP → HTTPS (Traefik entrypoint)

The app + all UIs are served on **both** `web` (80) and `websecure` (443). Force
HTTPS with a redirect on the Traefik **`web` entrypoint** — one setting that
covers *every* route (app, `/argocd`, `/grafana`, …), and `allowACMEByPass` keeps
cert-manager's HTTP-01 renewals working:

```bash
helm upgrade traefik traefik/traefik -n traefik --reuse-values \
  --set ports.web.http.redirections.entryPoint.to=websecure \
  --set ports.web.http.redirections.entryPoint.scheme=https \
  --set ports.web.http.redirections.entryPoint.permanent=true \
  --set ports.web.allowACMEByPass=true \
  --wait --timeout=4m
```

> **Why the entrypoint, not a Middleware + catch-all IngressRoute?** Traefik ranks
> routers by **rule length**, so a low-priority catch-all on `web` *loses* to the
> app's `Host && PathPrefix("/")` router — the app would keep serving plain HTTP.
> The **entrypoint** redirect runs *before* routing, so it catches everything.
> `allowACMEByPass=true` lets the `/.well-known/acme-challenge/…` path through for
> renewals. `--reuse-values` keeps the NLB annotations, so the load balancer is
> unchanged. (The chart key is `ports.web.http.redirections.entryPoint`, **not**
> the older `ports.web.redirectTo`, which newer charts reject.)

Verify:
```bash
curl -sI "http://${HOSTNAME_APP}/" | awk '/^HTTP|^[Ll]ocation:/'
# HTTP/1.1 308 Permanent Redirect
# Location: https://vijaygiduthuri.in/
curl -s -o /dev/null -w "%{http_code}\n" "https://${HOSTNAME_APP}/"   # 200
```

---

## 🐛 Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| **`/argocd`, `/grafana`, `/prometheus`, `/alertmanager` all show the banking app** (SPA) | The app's `PathPrefix(\`/\`)` router out-ranks the sub-path routers (Traefik priority = rule length), so requests fall through to the frontend, which serves `index.html` for any path — a **200 that looks like the real page**. Verify with the body, not the status: `curl -s https://${HOSTNAME_APP}/grafana/api/health` should be JSON, not HTML. | Set **`priority: 100`** on each sub-path IngressRoute (5b/5c). Check live priorities: `kubectl -n traefik exec deploy/traefik -- wget -qO- http://localhost:8080/api/http/routers`. |
| `Certificate` stuck `READY=False` | HTTP-01 can't reach `http://<host>/.well-known/acme-challenge/…` | `curl http://${HOSTNAME_APP}/.well-known/acme-challenge/test` must return 404 (not refused). `kubectl -n banking get challenges` shows the probed URL. DNS must resolve (Phase 5). |
| Browser "CERT_AUTHORITY_INVALID" | Cert not ready, or hitting the NLB by hostname without the `Host` header (Traefik serves a default self-signed cert) | Confirm `banking-tls` `READY=True`; curl the real hostname, not the NLB. |
| Rate-limited by Let's Encrypt | Too many prod issuances | Use the **staging** issuer while iterating; prod limit is 5/week/domain (rolling). |
| `/grafana` loads blank/un-styled | Sub-path not configured, or TLS Secret missing in `observability` | Do Step 4 (`serve_from_sub_path`) + Step 5a (copy Secret); confirm the IngressRoute is `websecure`. |
| `/argocd` → ERR_TOO_MANY_REDIRECTS | `server.insecure` lost on an upgrade | `helm upgrade argocd argo/argo-cd -n argocd --reuse-values --set 'configs.params.server\.insecure=true' --set 'configs.params.server\.rootpath=/argocd'` + restart. |
| Renewed cert but `/grafana` `/argocd` serve the OLD cert | Copied Secrets are stale | Re-run Step 5a; or install reflector for auto-propagation. |
| `no matches for kind "Certificate"` | cert-manager CRDs missing | `kubectl get crd | grep cert-manager.io` (expect 6); reinstall with `crds.enabled=true`. |

---

## 📋 Phase 7 cheatsheet

| # | What | How |
|---|---|---|
| 1 | cert-manager | Argo app (1) or `helm install` |
| 2 | ClusterIssuer `letsencrypt-prod` | `kubectl apply` heredoc |
| 3 | App HTTPS | flip `ingress.tls=true` in values → commit (Argo + cert-manager) |
| 4 | Grafana/Prom/Alertmgr sub-paths | kube-prometheus-stack values → commit |
| 5 | Copy `banking-tls` + `websecure` IngressRoutes | Step 5a/5b/5c |
| 6 | Verify 5 URLs over HTTPS | Step 6 |
| 7 | HTTP→HTTPS redirect | Middleware + catch-all IngressRoute |

Final round-trip:
```bash
for U in / /argocd/ /grafana/login /prometheus/-/ready /alertmanager/-/ready; do
  printf "%-26s -> " "$U"
  curl -sIL -o /dev/null -w "HTTP %{http_code}\n" "https://${HOSTNAME_APP}$U"
done
```

---

## 🎉 What you accomplished

- ✅ **cert-manager** + Let's Encrypt production issuer
- ✅ A **browser-trusted TLS cert**, auto-renewing (~day 75)
- ✅ App flipped to HTTPS via the chart's `ingress.tls` toggle — no template edits, pure GitOps
- ✅ **All 5 UIs** (app, Argo CD, Grafana, Prometheus, Alertmanager) on the **same domain** over HTTPS

```
https://vijaygiduthuri.in                🏦 the app
https://vijaygiduthuri.in/argocd         🚀 GitOps controller
https://vijaygiduthuri.in/grafana        📊 dashboards
https://vijaygiduthuri.in/prometheus     📈 metrics
https://vijaygiduthuri.in/alertmanager   🚨 alerts
```

---

## 🧹 Tearing it all down

```bash
# 1. Delete the Traefik Service FIRST so the NLB + its ENIs are removed
#    (otherwise they block VPC deletion).
helm uninstall traefik -n traefik

# 2. (Optional) uninstall the rest
helm uninstall cert-manager -n cert-manager
kubectl -n argocd delete applications --all       # Argo-managed apps
helm uninstall argocd -n argocd

# 3. Delete StatefulSet PVCs (not auto-deleted)
kubectl -n banking delete pvc --all
kubectl -n observability delete pvc --all

# 4. Empty the S3 documents bucket if it has objects, then destroy the infra
cd terraform/environments/dev && terraform destroy
```

---

🏁 **Done.** The full DevOps lifecycle in seven phases on EKS:
**infra → ingress → CI → CD → DNS → observability → HTTPS.**
