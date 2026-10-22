# Phase 5 — DNS: apex domain via Route 53 (Terraform + GoDaddy delegation)

> **Status:** ✅ Written *as we do it* on the EKS cluster.

**Goal:** Serve the platform on the **bare apex `vijaygiduthuri.in`** (no
subdomain), with the Route 53 hosted zone and the apex record **managed by
Terraform**, and a one-time **manual GoDaddy nameserver delegation**.

**Time:** ~20 min (most of it waiting for nameserver delegation to propagate).

> Before: `http://k8s-traefik-….elb.us-east-1.amazonaws.com/`
> After:  `http://vijaygiduthuri.in/`  and  `http://vijaygiduthuri.in/argocd/`

> Set this once and reuse it in every command below:
> ```bash
> export HOSTNAME_APP="vijaygiduthuri.in"   # 👈 your apex domain
> ```

---

## The one AWS-specific rule (why we use Route 53)

An AWS NLB gives you a **DNS hostname**, not a fixed IP:
```
k8s-traefik-traefik-abc123.elb.us-east-1.amazonaws.com
```
DNS rules mean:
- A **subdomain** (`app`, `grafana`…) could `CNAME` to that hostname. ✅
- The **apex** (`vijaygiduthuri.in`) **cannot** be a `CNAME` — and **GoDaddy DNS
  has no `ALIAS`/`ANAME`** record to work around it. ❌

We want the **apex**, so DNS is hosted in **Amazon Route 53**, which has a
special **ALIAS** record that *can* sit on the apex and point at an NLB.
**GoDaddy stays the registrar** — we only delegate its nameservers to Route 53.

```
GoDaddy (registrar)  --delegate NS-->  Route 53 hosted zone (vijaygiduthuri.in)
   (manual, once)                            │  ALIAS A  @  ->  Traefik NLB
                                             ▼        (Terraform)
                                       Traefik NLB  ->  cluster
```

Everything is defined in Terraform (`terraform/modules/route53/`, wired into
`terraform/environments/dev/main.tf`).
Because the apex record targets the Traefik NLB — which only exists **after**
Traefik is installed (Phase 2) — the module has a **two-stage** design:

| Stage | `create_apex_record` | Creates | When |
| ----- | -------------------- | ------- | ---- |
| **1** | `false` (default) | the **hosted zone** only → outputs nameservers | Phase 1 apply (already done) |
| **2** | `true` | the **apex ALIAS** → Traefik NLB | now (Phase 5), after Traefik is up |

---

## ✅ Prerequisites

| Need | How to check |
| ---- | ------------ |
| Phase 1 applied (route53 module created the zone) | `terraform -chdir=terraform/environments/dev output route53_name_servers` returns 4 servers |
| Phase 2 done (Traefik NLB exists) | `kubectl -n traefik get svc traefik` shows an EXTERNAL-IP (hostname) |
| Phase 4 done (app reachable via the NLB) | `kubectl -n banking get pods` → ~35 Running |
| `terraform` + `aws` CLI configured | `aws sts get-caller-identity` |
| `dig` / `nslookup` on your laptop | `dig +short google.com` works |

---

## Step 1 — Read the Route 53 nameservers (created in Phase 1)

The `route53` module already created the hosted zone during the Phase 1 infra
apply (stage 1, `create_apex_record = false`). Read the four nameservers:

```bash
cd terraform/environments/dev
terraform output route53_name_servers
# [
#   "ns-123.awsdns-45.com",
#   "ns-678.awsdns-90.net",
#   "ns-901.awsdns-12.org",
#   "ns-234.awsdns-56.co.uk",
# ]
```

> If the zone doesn't exist yet, apply stage 1 first:
> ```bash
> terraform -chdir=terraform/environments/dev apply
> # (create_apex_record defaults to false → zone only)
> ```

Copy those **four nameservers** — you paste them into GoDaddy next.

---

## Step 2 — Delegate GoDaddy's nameservers to Route 53 (manual, once)

This is the **only** GoDaddy step. GoDaddy remains the **registrar**; Route 53
becomes the **DNS host**.

1. Sign in → https://account.godaddy.com/products
2. Your domain → **DNS** → **Nameservers** → **Change** → **Enter my own nameservers (advanced)**.
3. Replace the existing ones with the **four Route 53 nameservers** from Step 1
   (no trailing dots).
4. **Save**.

> ⏳ Delegation can take from a few minutes up to a few hours (often <30 min).
> Verify it has taken effect:
> ```bash
> dig +short NS ${HOSTNAME_APP}
> # should list the ns-….awsdns-… servers (NOT GoDaddy's domaincontrol.com)
> ```

---

## Step 3 — Create the apex ALIAS record (Terraform stage 2)

Now that Traefik's NLB exists, flip the stage-2 toggle and apply. Terraform
**discovers the NLB by its Kubernetes service tag** and writes the apex ALIAS
A record at it — no hand-copied hostnames.

```bash
terraform -chdir=terraform/environments/dev apply -var="create_apex_record=true"
```

Confirm the plan adds:
- `module.route53.data.aws_lb.traefik` (reads the Traefik NLB)
- `module.route53.aws_route53_record.apex` (the ALIAS)

then approve. Verify:
```bash
terraform -chdir=terraform/environments/dev output apex_fqdn
# "vijaygiduthuri.in"
```

> 💡 **ALIAS, not CNAME.** The ALIAS is resolved by Route 53 itself — it returns
> the NLB's current IPs at query time, sits legally on the apex, costs nothing,
> and needs no TTL. **IPv4 only** (the default NLB isn't dual-stack); add an
> `AAAA` alias later if you enable IPv6 on the NLB.
>
> 📌 To make `create_apex_record=true` the default (so plain `terraform apply`
> keeps the record), set it in a `*.tfvars` or change the variable default —
> otherwise pass `-var` each apply.

---

## Step 4 — Verify DNS resolution

```bash
dig +short ${HOSTNAME_APP}
# → the NLB's IP addresses (ALIAS resolves server-side, so you see A records, not a CNAME)

nslookup ${HOSTNAME_APP}
# Non-authoritative answer: Name: vijaygiduthuri.in  Address: 52.x.x.x (and more)
```

If they disagree across regions, check https://dnschecker.org (paste
`vijaygiduthuri.in`). Then a quick HTTP probe:

```bash
curl -sI -o /dev/null -w "%{http_code}\n" "http://${HOSTNAME_APP}/"
# 404 until Step 5 lands — Traefik got the request but no Ingress matches this Host yet.
```

---

## Step 5 — Point the chart's Ingress at the apex

The platform uses a standard Kubernetes **`Ingress`** with a single `host`
([`k8s/40-ingress.yaml`](../../k8s/40-ingress.yaml)), so this is a small edit to
that file — no template surgery.

Open `k8s/40-ingress.yaml`, find the `spec:` block, and set it:

```yaml
ingress:
  enabled: true                 # 👈 turn on for EKS
  className: traefik
  host: vijaygiduthuri.in       # 👈 YOUR apex domain
  tls: false                    # Phase 7 flips this to true
  tlsSecretName: banking-tls
  clusterIssuer: letsencrypt-prod
```

That one Ingress routes, on `vijaygiduthuri.in`:
- `/api` → `api-gateway`
- `/` → `frontend`

**(Optional, tidy)** On EKS the gateway/frontend don't need NodePorts anymore —
Traefik reaches them by ClusterIP. Set:
```yaml
apiGateway:
  serviceType: ClusterIP
frontend:
  serviceType: ClusterIP
```
(The Ingress works even if they stay NodePort; ClusterIP is just cleaner.)

> **Argo CD** is already reachable at `/argocd` on the same NLB (Phase 4's
> IngressRoute matches the `/argocd` path on any host), so
> `http://vijaygiduthuri.in/argocd/` will work too — the more-specific
> `/argocd` route wins over the app's `/` route.

---

## Step 6 — Push through the GitOps loop

```bash
git add k8s/40-ingress.yaml
git commit -m "phase 5: expose the platform on vijaygiduthuri.in"
git push origin main
kubectl apply -f k8s/40-ingress.yaml
```

Argo CD picks up the commit on its poll (default 3 min). To apply immediately:
```bash
kubectl -n argocd annotate app banking-platform \
  argocd.argoproj.io/refresh=hard --overwrite

kubectl -n argocd get app banking-platform -w
# wait for Synced / Healthy, then Ctrl+C
```

> Note: the CI workflow rebuilds and re-pushes the service images on every
> push to `main`. That's harmless — the Ingress is applied straight from Git.

---

## Step 7 — Verify apex access

```bash
echo "=== via apex ==="
curl -s -o /dev/null -w "  /                -> HTTP %{http_code}\n" "http://${HOSTNAME_APP}/"
curl -s -o /dev/null -w "  /argocd/         -> HTTP %{http_code}\n" "http://${HOSTNAME_APP}/argocd/"
curl -s -o /dev/null -w "  /api/v1/fx/rates -> HTTP %{http_code}\n" "http://${HOSTNAME_APP}/api/v1/fx/rates"
```

Expect `200` for all three.

> ⚠️ **Test before DNS resolves** — hit the NLB directly with a `Host` header:
> ```bash
> NLB=$(kubectl -n traefik get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
> curl -s -o /dev/null -w "%{http_code}\n" -H "Host: ${HOSTNAME_APP}" "http://${NLB}/api/v1/fx/rates"
> ```

Open in a browser:
- **App:** http://vijaygiduthuri.in/
- **Argo CD:** http://vijaygiduthuri.in/argocd/  (trailing slash required)

---

## Step 8 (Optional) — Sanity-check Traefik's parsed routers

If Step 7 fails, confirm Traefik actually accepted the route (a bad matcher
silently disables a router):

```bash
kubectl -n traefik exec deploy/traefik -- wget -qO- http://localhost:8080/api/http/routers \
  | python3 -c "
import json, sys
rs = json.load(sys.stdin)
for r in rs:
    if 'banking' in r.get('name','').lower() or 'argocd' in r.get('name','').lower():
        print(f\"  {r.get('status'):8}  {r.get('rule','')[:70]}\")"
```

Every relevant router should show `enabled`. If one is `disabled`, the output
includes the parse error.

---

## Step 9 (Optional) — NLB recreated → just re-apply Terraform

The ALIAS **tracks the NLB's IPs automatically**, so node changes, `helm
upgrade`, and pod restarts need no DNS action.

The one case that does: if the Traefik `Service` is **deleted and recreated**, a
**new NLB** (new DNS name) is provisioned. Because the module discovers the NLB
by tag, you just re-apply — Terraform re-reads the current NLB and updates the
ALIAS. **Nothing at GoDaddy changes** (delegation stays):

```bash
terraform -chdir=terraform/environments/dev apply -var="create_apex_record=true"
```

So: **don't casually delete the Traefik Service.** `helm upgrade` in place keeps
the same NLB and needs no re-apply.

---

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `dig NS ${HOSTNAME_APP}` still shows `domaincontrol.com` | GoDaddy delegation not applied/propagated | Re-check GoDaddy Nameservers = the 4 Route 53 NS (Step 1/2); wait (can take hours). |
| `terraform apply -var=create_apex_record=true` → `data.aws_lb … no matching LB found` | Traefik NLB not up yet, or wrong service tag | Confirm `kubectl -n traefik get svc traefik` has an EXTERNAL-IP; check the NLB tag `kubernetes.io/service-name=traefik/traefik` (module var `traefik_service_tag`). |
| `data.aws_lb … multiple LBs matched` | Another LB shares the tag filter | Make the Traefik service tag unique, or narrow `traefik_service_tag`. |
| `dig ${HOSTNAME_APP}` returns nothing | ALIAS not created, or delegation not live | `terraform output apex_fqdn`; confirm Step 3 applied and Step 2 propagated. |
| Host resolves but `curl http://<host>/` is 404 | Ingress `host` not set / not synced | Do Step 5, then Step 6 (hard refresh Argo). |
| `curl -I` (HEAD) 404 but GET 200 | Some routes have no HEAD handler | Expected — real traffic is GET. Test with GET. |
| Argo `Synced` but old behaviour | Polled an old revision | `kubectl -n argocd annotate app banking-platform argocd.argoproj.io/refresh=hard --overwrite`. |
| DNS resolves to a dead NLB after reinstalling Traefik | New Service → new NLB | Re-apply Terraform (Step 9). |
| `vijaygiduthuri.in/argocd/` hits the app, not Argo | `/argocd` IngressRoute missing or lower priority | Confirm Phase 4's IngressRoute exists; `/argocd` (more specific) should win over `/`. |

---

➡️ **Next:** [Phase 6 — Observability](06-observability.md)
