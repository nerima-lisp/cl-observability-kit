# cl-observability-kit

`cl-observability-kit` is a deterministic observability foundation for Common
Lisp applications and libraries. The core owns validated, detached telemetry
data and lifecycle semantics while applications choose the HTTP stack, logger
sinks, wire encoders, and network exporters.

## Systems

| ASDF system | Responsibility |
| --- | --- |
| `cl-observability-kit` | Metrics, health checks, resources, tracer/provider/span lifecycle, structured log records, W3C propagation, HTTP semantic conventions, and instrumentation context. |
| `cl-observability-kit/prometheus` | Deterministic Prometheus text exposition. |
| `cl-observability-kit/otlp` | Deterministic, transport-neutral OTLP-shaped metric, trace, and log data. It does not encode JSON/protobuf or send anything. |
| `cl-observability-kit/log-kit` | Optional bridge from instrumentation context to `cl-log-kit`'s existing log context. |

## Boundaries

There is intentionally no HTTP client or server in the core. `/metrics`,
`/health`, `/ready`, and `/live` routes, HTTP server lifecycle, and any
framework adapter belong to the application boundary. The HTTP API in the core
only validates and attaches semantic-convention attributes to an existing
span.

The core does not start exporter clients, encode wire formats, or choose
provider-specific transport policy. Ending a recorded span invokes the
configured exporter callback with a detached span record; flush and shutdown
callbacks make the lifecycle explicit without creating network threads.

## Start here

- [Getting started](getting-started.md) — load the systems and build the first
  metric or health registry.
- [API reference](reference/api.md) — public packages, operations, conditions,
  and adapter entry points.
- [Architecture](reference/architecture.md) — ownership boundaries,
  concurrency, cancellation, and coverage policy.
- [Development](project/development.md) — tests, coverage, formatting, and
  documentation checks.
