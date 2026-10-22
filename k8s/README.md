# Banking Platform — Kubernetes manifests

Plain Kubernetes manifests for the whole platform. No Helm, no ArgoCD, no
Terraform — just YAML you can read end to end and `kubectl apply` in order.

```
k8s/
├── 00-namespaces.yaml            namespaces + the two shared ConfigMaps
├── 01-secret.example.yaml        TEMPLATE for the shared Secret (never commit it)
├── 10-infra.yaml                 Postgres, Redis, Kafka
├── 20-services.yaml              32 Deployments + their Services
├── 30-hpa.yaml                   32 HorizontalPodAutoscalers
├── 40-ingress.yaml               Traefik Ingress for vijaygiduthuri.in
├── 45-tls-clusterissuer.yaml     Let's Encrypt ClusterIssuer (cert-manager)
└── 50-observability.yaml         Prometheus ServiceMonitors + Grafana dashboards
```

The numbering is the apply order. `kubectl apply -f k8s/` already applies
files in alphabetical order, so the numbering is documentation, not a
requirement — but it is what keeps the DAG obvious when you apply files one
by one.

## Prerequisites

| Need | Why |
| --- | --- |
| Kubernetes 1.25+ | `apps/v1`, `networking.k8s.io/v1` |
| A container runtime + images | `docker.io/lokeshzenbook/banking-platform:<service>-latest` |
| cert-manager *(optional)* | only for the TLS block in `40-ingress.yaml` |
| An Ingress controller *(optional)* | Traefik is assumed; use the NodePorts without one |
| Prometheus Operator *(optional)* | only for the ServiceMonitors in `50-observability.yaml` |

## Apply

```bash
# 1. Namespaces and shared configuration
kubectl apply -f k8s/00-namespaces.yaml

# 2. The shared Secret — created out-of-band, never committed
kubectl -n banking create secret generic banking-platform-secrets \
  --from-literal=POSTGRES_USER=banking \
  --from-literal=POSTGRES_PASSWORD='<a real password>' \
  --from-literal=JWT_SECRET='<a real signing key>' \
  --from-literal=JWT_ISSUER=banking-platform

# 3. Datastores, workloads, autoscaling, routing
kubectl apply -f k8s/10-infra.yaml
kubectl apply -f k8s/20-services.yaml
kubectl apply -f k8s/30-hpa.yaml
kubectl apply -f k8s/40-ingress.yaml
kubectl apply -f k8s/45-tls-clusterissuer.yaml
kubectl apply -f k8s/50-observability.yaml
```

`01-secret.example.yaml` is a template only. It contains `<replace-me>`
placeholders so that no real credential ever lands in Git.

## The pieces

### Namespaces and shared configuration (`00-namespaces.yaml`)

Two namespaces: `banking` (the platform) and `observability` (metrics).

Two ConfigMaps hold the settings that every service shares, so a value that
applies to everybody is edited in exactly one place:

- `banking-platform-config` — `ENVIRONMENT`, `LOG_LEVEL`, `LOG_FORMAT`,
  `HTTP_PORT`, and the OpenTelemetry settings. Referenced by all 31 backend
  services via `envFrom`.
- `banking-platform-datastores` — the Postgres, Redis and Kafka coordinates.
  Referenced by the 30 services that use a datastore. `api-gateway` does not,
  because it only fronts HTTP traffic.

### Shared Secret (`01-secret.example.yaml`)

One Secret, `banking-platform-secrets`, holding `POSTGRES_USER`,
`POSTGRES_PASSWORD`, `JWT_SECRET` and `JWT_ISSUER`. Every service mounts the
subset it needs through `secretKeyRef`.

### Datastores (`10-infra.yaml`)

Single-replica development instances, in the `banking` namespace so that
`postgres`, `redis` and `kafka` resolve as plain service names:

| Component | Kind | Image | Notes |
| --- | --- | --- | --- |
| Postgres | StatefulSet | `postgres:16-alpine` | PVC `data`, `/var/lib/postgresql/data` |
| Redis | Deployment | `redis:7-alpine` | no PVC — cache only |
| Kafka | StatefulSet | `apache/kafka:3.8.1` | single-node KRaft, PVC `data` |

For production, delete this file and point `banking-platform-datastores` at
managed equivalents instead.

### Workloads (`20-services.yaml`)

32 Deployments — 31 Go services plus the React frontend — each with its
ClusterIP Service.

- Ports: `http` on 8080 for every service. `account-service`, `auth-service`,
  `authz-service` and `ledger-service` also expose `grpc` on 9090;
  `account-service` additionally calls `ledger-service:9090`.
- `api-gateway` is the only service with a NodePort (30080) and the only one
  without the datastores ConfigMap. It fronts the API and holds the CORS,
  upstream and JWT configuration.
- `frontend` is the React app, NodePort 30081. It has no Prometheus
  annotations and no datastore access.
- Every container sets `enableServiceLinks: false`. Without it Kubernetes
  injects `POSTGRES_PORT=tcp://10.x.x.x:5432`, which collides with the typed
  datastore configuration below it.
- Every Go service has `/healthz`, `/readyz` and `/startupz` probes and
  `prometheus.io/scrape` annotations.

### Autoscaling (`30-hpa.yaml`)

One HPA per service. Most scale on 70% CPU and 80% memory between 1 and 5
replicas. `api-gateway` scales on CPU only (1–5), `frontend` on CPU only
(1–4).

### Ingress and TLS (`40-ingress.yaml`, `45-tls-clusterissuer.yaml`)

Path-based routing on `vijaygiduthuri.in`:

| Path | Backend |
| --- | --- |
| `/api` | `api-gateway:8080` |
| `/` | `frontend:8080` |

The Ingress assumes Traefik — change `ingressClassName` if your cluster runs
something else. The `tls:` block needs cert-manager and the
`letsencrypt-prod` ClusterIssuer; drop both it and the
`cert-manager.io/cluster-issuer` annotation if you are not using TLS.

Without an Ingress controller, reach the platform through the NodePorts:

```
http://localhost:30080   api-gateway
http://localhost:30081   frontend
```

### Observability (`50-observability.yaml`)

- `banking-platform-services` — ServiceMonitor that scrapes `/metrics` from
  every service in the `banking` namespace (15s interval).
- `otel-collector` — ServiceMonitor for the OpenTelemetry Collector's
  Prometheus exporter.
- `banking-services-dashboard` and `banking-service-detail-dashboard` —
  Grafana dashboard JSON, labelled `grafana_dashboard: "1"` so the Grafana
  sidecar picks them up.

These objects require the Prometheus Operator and Grafana to already be
installed. Applying the file does not install them.

## Changing things

- **A shared setting** (log level, OTLP endpoint, datastore host) — edit the
  ConfigMap in `00-namespaces.yaml`.
- **One service's setting** — edit its Deployment in `20-services.yaml`.
- **An image version** — every Deployment pins
  `docker.io/lokeshzenbook/banking-platform:<service>-latest`. CI also pushes
  an immutable `<service>-<commit-sha>` tag; switch to that for reproducible
  deployments.
- **Replicas** — set by the HPA in `30-hpa.yaml`. Remove the HPA and set
  `spec.replicas` on the Deployment to pin a fixed size.

## Teardown

```bash
kubectl delete -f k8s/50-observability.yaml
kubectl delete -f k8s/45-tls-clusterissuer.yaml
kubectl delete -f k8s/40-ingress.yaml
kubectl delete -f k8s/30-hpa.yaml
kubectl delete -f k8s/20-services.yaml
kubectl delete -f k8s/10-infra.yaml
kubectl delete -n banking secret banking-platform-secrets
kubectl delete namespace banking
```
