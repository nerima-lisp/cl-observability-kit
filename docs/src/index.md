# cl-observability-kit

cl-observability-kit is a deterministic observability foundation for Common
Lisp applications and libraries. The core owns validated, detached telemetry
data and lifecycle semantics while applications choose the HTTP stack, logger
sinks, wire encoders, and network exporters.

## Systems

| ASDF system | Responsibility |
| --- | --- |
| cl-observability-kit | Metrics, health checks, resources, instrumentation context, tracer/meter providers, span/log processors, structured logs, samplers, configuration, propagation adapters, and HTTP semantic conventions. |
| cl-observability-kit/prometheus | Deterministic Prometheus text exposition. |
| cl-observability-kit/otlp | Deterministic, transport-neutral OTLP-shaped metric, trace, and log data. It does not encode JSON/protobuf or send anything. |
| cl-observability-kit/log-kit | Optional bridge from instrumentation context to cl-log-kit's existing log context. |

## Boundaries

There is intentionally no HTTP client or server in the core. /metrics,
/health, /ready, and /live routes, HTTP server lifecycle, and framework
adapters belong to the application boundary. The HTTP API in the core only
validates and attaches semantic-convention attributes to an existing span.

Providers, processors, readers, and exporters use callbacks and detached
records. They define lifecycle and error boundaries without selecting a
network protocol. The core does not encode wire formats, start exporter
clients, implement retries or batching queues, or choose deployment policy.

## Start here

- [Getting started](getting-started.md) — load the systems and build the
  first metric, provider, span, log record, or propagation boundary.
- [API reference](reference/api.md) — public packages, operations, conditions,
  configuration, readers, processors, and adapters.
- [Architecture](reference/architecture.md) — ownership boundaries,
  concurrency, lifecycle, security, and coverage policy.
- [Development](project/development.md) — tests, coverage, formatting, and
  documentation checks.
