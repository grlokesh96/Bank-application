# Static Kubernetes manifests

Plain (non-Helm) Kubernetes manifests for all 32 workloads: 31 Go services under
`services/` plus `frontend`.

Each workload gets its own directory holding a `deployment.yaml` and a
`service.yaml`:

```
deploy/k8s/
  auth-service/
    deployment.yaml
    service.yaml
  api-gateway/
    deployment.yaml
    service.yaml
  ... (32 total)
```

## Which is the source of truth

**The Helm chart at `deploy/helm/banking-platform/` is the source of truth.**
ArgoCD reconciles it onto the cluster (`deploy/argocd/apps/banking-platform.yaml`),
and CI patches image tags in `values.yaml`.

These files mirror the chart 1:1 and are intended for `kubectl apply`, code
review, and local clusters. If you change workload config, change the chart too,
or the two will drift.

## Prerequisites

These manifests do **not** create the Secret they reference. Create it first:

```bash
kubectl create namespace banking
kubectl -n banking create secret generic banking-platform-secrets \
  --from-literal=POSTGRES_USER=... \
  --from-literal=POSTGRES_PASSWORD=... \
  --from-literal=JWT_SECRET=... \
  --from-literal=JWT_ISSUER=...
```

They also expect the shared infrastructure Services to exist: `postgres`
(`:5432`), `redis` (`:6379`), `kafka` (`:9092`), and the OpenTelemetry
collector at `otel-collector.observability.svc.cluster.local:4317`. The chart
provides these; to use the static manifests instead, render them from the chart
first:

```bash
helm template banking-platform deploy/helm/banking-platform \
  --set postgres.enabled=true --set redis.enabled=true --set kafka.enabled=true
```

## Image tags

Every `image:` ends in `:<service>-latest`, a placeholder. CI publishes both
`:<service>-<sha12>` and `:<service>-latest`, so patch the tag for the commit you
want to run rather than editing anything else in the file.

The registry prefix matches `values.yaml`
(`118178010323.dkr.ecr.us-east-1.amazonaws.com/banking-platform`). Note that CI
currently pushes to Docker Hub, so if you are targeting images CI produced,
update the prefix.

## Notable per-service differences

These are inherited from the chart, not accidents:

- **gRPC** — `auth-service`, `authz-service`, `ledger-service` and
  `account-service` expose a second port, `grpc` on `9090`.
- **NodePort** — `api-gateway` (30080) and `frontend` (30081) are the two
  externally reachable workloads on kind.
- **`frontend` has no securityContext and only a `PORT` env var.** It is an
  nginx container serving static assets; it has no database, cache, broker or
  signing config, and the official nginx image runs as root so a `runAsNonRoot`
  pod securityContext would stop it booting.
- **Every other service** runs as uid/gid `65532` with a read-only root
  filesystem, all capabilities dropped, and probes `/readyz`, `/healthz` and
  `/startupz`.

## Not included

These live in the chart only: the `HorizontalPodAutoscaler` per service, the
`ConfigMap` and `Secret` objects (folded into the Deployment as `env` here),
Postgres/Redis/Kafka, and the Traefik Ingress.

## Apply

```bash
# everything
kubectl apply -f deploy/k8s/

# one service
kubectl apply -f deploy/k8s/auth-service/
```