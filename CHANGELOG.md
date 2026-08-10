# Changelog

All notable changes to this project are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.1.0] - 2026-08-10

Initial release. cl-observability-kit is a deterministic, transport-neutral
observability substrate for Common Lisp: it owns validated telemetry data,
aggregation semantics, and lifecycle boundaries, while applications keep
ownership of HTTP clients/servers, logger sinks, wire encoding, and network
exporter I/O.

### Added

- **Metrics** — a metric registry with counter, up-down counter, gauge, and
  histogram instruments defined through `define-counter`,
  `define-up-down-counter`, `define-gauge`, and `define-histogram`, plus
  callback-driven observable variants. Registries enforce bounded label
  cardinality and label-value length, and snapshots are detached and
  deterministically sorted.
- **Metric SDK lifecycle** — meter providers, pull metric readers, and
  periodic readers with an interval-driven worker, force-flush, and shutdown,
  with isolated and retained callback errors.
- **Health checks** — a health registry supporting liveness, readiness, and
  startup checks with explicit cancellation tokens, per-check timeouts, a
  configurable cancellation grace period, and injectable clock support for
  deterministic testing.
- **Tracing** — tracer providers, spans, span events and links, exception
  recording, and built-in samplers (always-on, always-off, trace-ID ratio,
  and parent-based). Ships synchronous (`make-simple-span-processor`) and
  bounded, worker-backed batch (`make-batch-span-processor`) span processors
  that hand detached span records to application-owned exporter callbacks.
- **Structured logs** — log providers, processors, and loggers producing
  detached log records with `timestamp`, `observed-timestamp`, normalized
  severity text and number, body, optional event name, attributes,
  instrumentation context, resource, and instrumentation-scope metadata.
- **Instrumentation context and resources** — immutable, validated
  instrumentation context (trace/span identifiers, trace flags, attributes,
  baggage, tracestate) that is dynamically scoped and explicitly captured
  across worker-thread boundaries, plus immutable resource metadata shared
  across metric, trace, and log records.
- **Propagation** — W3C Trace Context and Baggage as the default propagator,
  plus B3 single-header, B3 multi-header, Jaeger, and AWS X-Ray adapters, and
  a composite propagator that chains multiple adapters. All adapters operate
  on detached header alists and never perform I/O.
- **HTTP semantic conventions** — validated request/response attribute
  helpers (`http-request-attributes`, `http-response-attributes`,
  `span-set-http-request`, `span-set-http-response`) for attaching
  semantic-convention data to an existing span; this package is not an HTTP
  client or server.
- **Environment configuration** — `read-sdk-configuration` parses standard
  `OTEL_*` environment variables (SDK disabled state, service name, resource
  attributes, propagator selection, metric export interval/timeout, trace
  sampler and argument, log level) into a validated, detached configuration
  object.
- **cl-observability-kit/prometheus** — deterministic Prometheus text
  exposition via `render-prometheus`, including cumulative histogram bucket
  samples and escaped label/HELP/UNIT text.
- **cl-observability-kit/otlp** — a transport-neutral OTLP-shaped document
  adapter converting metric snapshots, span records, and log records into
  deterministic Common Lisp alists, without JSON/protobuf encoding or network
  I/O.
- **cl-observability-kit/log-kit** — an optional bridge that maps
  instrumentation context fields into cl-log-kit's existing log context.
