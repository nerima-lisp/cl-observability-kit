# Changelog

All notable changes to this project are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [1.0.0] - 2026-08-16

First stable release. 1.0.0 marks the substrate as production-ready rather
than announcing a redesign: every public operation from 0.1.0 keeps its name,
signature, and behavior apart from the single removal listed below. The
release also completes the project's release infrastructure, which 0.1.0
shipped without.

### Removed

- **Breaking.** `http-response-attributes` no longer accepts `:body-size` as a
  short alias for `:response-body-size`. Passing `:body-size` now signals the
  ordinary unsupported-option error instead of being rewritten, and the
  "supplied more than once" error for passing both spellings is gone with it.
  Callers should pass `:response-body-size`. The alias was never documented;
  `:request-body-size` on `http-request-attributes` is unaffected.

### Fixed

- Restored five exported symbols that the SDK component split dropped from the
  package definitions while leaving their definitions, their internal callers,
  and their documentation in place: `metric-reader-force-flush`,
  `metric-reader-shutdown`, `make-jaeger-propagator`, and
  `make-xray-propagator` in `observability-kit`, and `snapshot->otlp` in
  `observability-kit/otlp`. `make-jaeger-propagator` and
  `make-xray-propagator` are the only public way to build those carriers
  directly, and the API reference documented them throughout.
- Restored the test coverage deleted alongside those exports: Jaeger and X-Ray
  injection round-trips, their malformed-header rejection cases, unknown
  sampling state across compatibility boundaries, invalid-context injection,
  the `snapshot->otlp` metric/snapshot/invalid dispatch, the metric-reader
  compatibility spellings, and `OTEL_PROPAGATORS=jaeger,xray` selection.
- Dropped a duplicate `#:meter-provider` entry from the core export list.

### Added

- `LICENSE` carrying the MIT text the ASDF systems have always declared.
- GitHub Actions workflows: `ci.yml` runs `nix flake check` and a diff-hygiene
  gate on every push and pull request; `docs.yml` publishes the MkDocs site to
  GitHub Pages; `release.yml` refuses to publish a tag whose name disagrees
  with the `.asd` `:version`, verifies the tagged tree, and opens a draft
  release; `flake-update.yml` proposes weekly `flake.lock` updates. A shared
  `nix-setup` composite action pins the installer and Cachix action SHAs in one
  place.
- Dependabot coverage for GitHub Actions and Nix, `CODEOWNERS`, a pull request
  template, and bug-report and feature-request issue templates.
- Complete ASDF metadata on all five systems: a named `:author` and
  `:maintainer`, plus `:homepage`, `:bug-tracker`, and `:source-control`, and a
  `:version` on the previously unversioned test system.

### Changed

Internal only; no public API impact.

- Split `otlp.lisp` into `otlp.lisp`, `otlp-metrics.lisp`, `otlp-traces.lisp`,
  and `otlp-logs.lisp`, and `trace-operation.lisp` into `trace-provider.lisp`,
  `trace-span-data.lisp`, `trace-span-lifecycle.lisp`, and
  `trace-records.lisp`.
- `with-span` now expands into a `call-with-span` call rather than binding
  `*current-span*` and `*instrumentation-context*` inline. `call-with-span` was
  already exported in 0.1.0.
- Consolidated the seven `define-*` metric macros onto a single
  `%expand-metric-declaration` helper and moved the compile-time metric-name
  and option validators into an `eval-when`.
- Extracted `%traceparent-fields` from `parse-traceparent`.

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
