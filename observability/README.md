# Observability stack

Prometheus, Alertmanager, Grafana, Loki, Tempo and the OpenTelemetry Collector
— the third-party charts that the Banking Platform's telemetry flows into.

This directory holds the **Helm values** for those charts and a one-shot
install script. It is deliberately separate from [`../k8s/`](../k8s/):

| | What it is | How it is applied |
| --- | --- | --- |
| [`../k8s/`](../k8s/) | The Banking Platform itself — plain Kubernetes manifests | `kubectl apply -f k8s/` |
| `observability/` | Third-party observability charts | `helm upgrade --install` |

The platform's own contribution to the stack — the `ServiceMonitor` that scrapes
every service and the two Grafana dashboards — lives with the rest of the
platform manifests, in
[`../k8s/50-observability.yaml`](../k8s/50-observability.yaml).

## Install

```bash
observability/install.sh
```

It creates the `observability` namespace, adds the three Helm repos, installs
the four charts with the values in [`values/`](values/), and then applies the
platform's ServiceMonitor and dashboards.

Run it by hand if you would rather go step by step:

```bash
kubectl create namespace observability --dry-run=client -o yaml | kubectl apply -f -

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo update

helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  -n observability -f observability/values/kube-prometheus-stack.yaml --wait --timeout 10m
helm upgrade --install tempo grafana/tempo \
  -n observability -f observability/values/tempo.yaml --wait --timeout 5m
helm upgrade --install loki-stack grafana/loki-stack \
  -n observability -f observability/values/loki-stack.yaml --wait --timeout 5m
helm upgrade --install otel-collector open-telemetry/opentelemetry-collector \
  -n observability -f observability/values/otel-collector.yaml --wait --timeout 5m

kubectl apply -f k8s/50-observability.yaml
```

> The `loki-stack` release name is not free: Grafana's Loki datasource points at
> `loki-stack.observability.svc.cluster.local`. Rename it and the datasource
> breaks.

## Values

| File | Chart | What it sets |
| --- | --- | --- |
| [`values/kube-prometheus-stack.yaml`](values/kube-prometheus-stack.yaml) | `prometheus-community/kube-prometheus-stack` | Prometheus under `/prometheus`, Alertmanager under `/alertmanager`, Grafana under `/grafana` on NodePort 30090, Loki + Tempo datasources, dashboard sidecar |
| [`values/loki-stack.yaml`](values/loki-stack.yaml) | `grafana/loki-stack` | Loki with a 5Gi PVC, Promtail, Grafana and Prometheus disabled (they come from kube-prometheus-stack) |
| [`values/tempo.yaml`](values/tempo.yaml) | `grafana/tempo` | Single-binary Tempo, 24h retention, 5Gi PVC |
| [`values/otel-collector.yaml`](values/otel-collector.yaml) | `open-telemetry/opentelemetry-collector` | OTLP in on 4317/4318, Prometheus exporter on 8889, traces → Tempo, metrics → Prometheus |

See [`../docs/observability.md`](../docs/observability.md) for the design and
[`../docs/aws/06-observability.md`](../docs/aws/06-observability.md) for the
step-by-step guide.
