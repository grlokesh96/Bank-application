# Observability Architecture

The platform emits metrics, logs and traces from every service and unifies
them in Grafana with click-through correlation (metrics → logs → traces).

## The three signals

```
                                   ┌──────────────────────────────┐
   ┌── metrics (Prometheus /metrics scrape) ─────────────────────►│  Prometheus  │
   │                                                              └──────┬───────┘
 ┌─┴──────────────┐   traces (OTLP gRPC)    ┌──────────────────┐        │
 │  Each Go       │────────────────────────►│  OpenTelemetry   │─traces►│  Tempo   │
 │  microservice  │   metrics (OTLP)        │  Collector       │─metrics►(Prom expo)│
 │  (OTel SDK +   │────────────────────────►│  (contrib)       │        │
 │  zap + promhttp)│                        └──────────────────┘        │
 └─┬──────────────┘                                                     ▼
   │  logs → stdout                                              ┌──────────────┐
   └────────────────► Promtail (DaemonSet) ────────────────────►│     Loki     │
                                                                 └──────┬───────┘
                                                                        ▼
                                                                 ┌──────────────┐
                                                                 │   Grafana    │  (dashboards +
                                                                 │  Prom/Loki/  │   metrics↔logs↔traces)
                                                                 │   Tempo DS   │
                                                                 └──────────────┘
```

### Metrics
- Every service runs Prometheus middleware (`pkg/httpserver`) exposing
  `/metrics`: `http_requests_total`, `http_request_duration_seconds`, and Go
  runtime metrics.
- A `ServiceMonitor` (`deploy/observability/servicemonitor.yaml`) selects all
  services labelled `app.kubernetes.io/part-of=banking-platform`; Prometheus
  (kube-prometheus-stack) scrapes them every 15s.
- Services also export OTLP metrics to the Collector, which re-exposes them for
  Prometheus (secondary path).

### Traces
- Each service is instrumented with the OpenTelemetry Go SDK (`pkg/telemetry`),
  with automatic spans for **HTTP (otelgin)**, **gRPC (otelgrpc)**,
  **PostgreSQL (otelpgx)**, **Redis (redisotel)**, and W3C context propagated
  across REST, gRPC and **Kafka** (headers in `pkg/kafka`).
- Spans are exported OTLP/gRPC to the **OpenTelemetry Collector**, which forwards
  them to **Tempo**.

### Logs
- Services log structured JSON to stdout (zap) including `trace_id` / `span_id`
  when a trace is active (`logger.WithTrace`).
- **Promtail** (DaemonSet) ships pod stdout to **Loki**.

## Correlation in Grafana
- **Loki → Tempo**: a derived field extracts `trace_id` from the JSON log line
  and links to the trace in Tempo.
- **Tempo → Loki**: `tracesToLogsV2` jumps from a span back to the logs for that
  trace.
- Result: from a latency spike on a dashboard → drill to the service's logs →
  open the exact trace across services.

## Install (kind or EKS)
```bash
deploy/observability/install.sh          # installs the 4 charts + ServiceMonitors + dashboard
# then enable OTLP export in the platform:
helm upgrade banking deploy/helm/banking-platform -n banking \
  -f deploy/helm/banking-platform/values-dev.yaml   # OTEL_ENABLED=true, endpoint=otel-collector
```

Grafana: `admin` / `admin` (dev). Dashboards: the kube-prometheus-stack bundle
(cluster/nodes/pods) plus **Banking Platform — Services** (request rate, p95
latency, error rate).
