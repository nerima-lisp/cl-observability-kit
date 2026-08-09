# cl-observability-kit

`cl-observability-kit` is a small, deterministic observability substrate for
Common Lisp applications and libraries. The core owns stable metrics, health
semantics, and instrumentation metadata while applications own routes,
exporter lifecycle, logging, and span lifecycle.

## Systems

| ASDF system | Responsibility |
| --- | --- |
| `cl-observability-kit` | Metrics, labels, registries, snapshots, health checks, cancellation tokens, and instrumentation context. |
| `cl-observability-kit/prometheus` | Deterministic Prometheus text exposition. |
| `cl-observability-kit/otlp` | Deterministic, transport-neutral OTLP-shaped Common Lisp data. It does not encode JSON/protobuf or send anything. |
| `cl-observability-kit/log-kit` | Optional bridge from instrumentation context to `cl-log-kit`'s existing log context. |

## Boundaries

There is intentionally no HTTP system in the core. `/metrics`, `/health`,
`/ready`, and `/live` routes, HTTP server lifecycle, and any `cl-http-kit`
adapter belong to the application boundary. The exporter systems can be used
with any HTTP stack or without HTTP at all.

The core also does not create spans, start exporter clients, encode wire
formats, or choose provider-specific attributes. Its snapshots and OTLP-shaped
values are hand-off data for an integration chosen by the application.

## Start here

- [Getting started](getting-started.md) — load the systems and build the first
  metric or health registry.
- [API reference](reference/api.md) — public packages, operations, conditions,
  and adapter entry points.
- [Architecture](reference/architecture.md) — ownership boundaries,
  concurrency, cancellation, and coverage policy.
- [Development](project/development.md) — tests, coverage, formatting, and
  documentation checks.
