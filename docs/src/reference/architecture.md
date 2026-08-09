# Architecture

`cl-observability-kit` is the small, transport-neutral layer between an
application and its observability integrations. It owns validated telemetry
data, aggregation semantics, context propagation, and the lifecycle of
detached trace and log records. It does not own HTTP routes or clients,
network connections, logger handlers or sinks, wire encoding, or deployment
policy.

## Systems and boundaries

| System | Owns | Does not own |
| --- | --- | --- |
| `cl-observability-kit` | metric data, aggregation, validation, cardinality limits, health semantics, cancellation tokens, resources, tracer/provider/span lifecycle, structured logs, W3C propagation, HTTP semantic conventions | HTTP I/O, logger handlers and sinks, wire encoding, network I/O |
| `cl-observability-kit/prometheus` | deterministic Prometheus text rendering and escaping | an HTTP server or `/metrics` route |
| `cl-observability-kit/otlp` | deterministic OTLP-shaped Common Lisp data | JSON/protobuf encoding, an OTLP client, export retries |
| `cl-observability-kit/log-kit` | explicit context-field mapping to `cl-log-kit` | log records, handlers, sinks, formatting, span lifecycle |

The application chooses metric names, health probes, routes, exporter
lifecycle, and provider-specific attributes. This keeps the core useful for a
library as well as for a service and prevents an integration package from
silently becoming an application framework.

The core ASDF system depends directly on `cl-concurrent-kit` and
`cl-boundary-kit`: the former supplies synchronization and the latter supplies
the injectable wall/monotonic clock protocol. `cl-date-kit` remains a flake
input because it is followed by the nerima-lisp dependency graph, but it is
not a direct source dependency here. Optional systems add only the integration
they need.

Health registries and tracer providers accept injected clocks, so custom
clocks do not inherit an implicit SBCL timing unit. Tracer providers also
accept ID generators, samplers, exporter callbacks, and explicit flush and
shutdown callbacks; the application owns the concrete exporter and its
transport lifecycle.

## Data and logic

The source layout keeps the primary data model separate from operations:

- `metrics-model.lisp` contains registry, metric, series, snapshot, and
  sample structures.
- `metrics-definition.lisp` contains the macro-first metric definition API.
- `metrics-operation.lisp` contains updates and exact numeric validation.
- `metrics-snapshot.lisp` detaches and sorts exporter input.
- `validation.lisp`, `validation-values.lisp`, and `validation-numbers.lisp`
  keep list, string, and numeric validation policies separate.
- `health-declarations.lisp` contains check, result, registry, cancellation,
  and thread-controller data structures.
- `health-model.lisp` creates cancellation tokens and registries and validates
  their clock and timeout configuration.
- `health-registry.lisp` contains registration and lookup operations.
- `health-thread.lisp` owns monotonic deadlines, bounded joins, and thread
  lifecycle boundaries.
- `health-execution.lisp` runs checks and isolates conditions through the
  continuation boundary.
- `health-status.lisp` computes aggregate status without starting checks.
- `health-macros.lisp` provides the macro-first health definition API.
- `resource-declarations.lisp` and `resource.lisp` define immutable resource
  metadata shared by metric, trace, and log records.
- `trace-model.lisp` and `trace-operation.lisp` define tracer providers,
  instrumentation scopes, spans, lifecycle callbacks, and detached span
  records.
- `propagation.lisp` formats and validates W3C `traceparent`, `tracestate`,
  and `baggage` values without performing I/O.
- `log-operation.lisp` creates detached structured log records correlated with
  instrumentation context.
- `http.lisp` validates HTTP semantic-convention attributes and attaches them
  to an existing span; it does not implement an HTTP client or server.
- `prometheus-source.lisp` selects and snapshots exporter input.
- `prometheus-format.lisp` normalizes numbers and escapes exposition text.
- `prometheus-samples.lisp` emits labels, samples, and histogram buckets.
- `otlp.lisp` converts detached metric, span, and log records to deterministic
  OTLP-shaped Common Lisp data.

Metric definitions are macros because names and options are configuration, not
runtime input. `define-counter`, `define-gauge`, and `define-histogram` reject
non-symbol names and unknown or duplicate options during macroexpansion. The
runtime API receives the resulting metric object and never guesses a metric
name from arbitrary input.

## Concurrency and cardinality

Registry mutation, series creation, metric updates, and snapshots are
protected by the locks supplied by `cl-concurrent-kit`. Snapshot accessors
return detached data, so exporters can sort and render without holding a
metric lock. Applications should define metrics during setup and update them
during operation; metric definitions are intentionally stable after
registration.

Label names are fixed per metric. Every labelled update must provide exactly
the declared names, label names and values are validated, and the registry
limits value length and series count. A new series beyond the configured
cardinality limit signals a condition instead of growing an unbounded table.
Metric values remain Common Lisp numbers until an exporter boundary; there is
no implicit float conversion in the core.

Instrumentation context bindings are thread-local. Worker threads do not
inherit a caller's dynamic context implicitly; use
`with-captured-instrumentation-context` at an explicit worker boundary when
context propagation is desired. `inject-trace-context` and
`extract-trace-context` provide the W3C header boundary; the application owns
the carrier and its network transport.

## Health execution

Health checks are filtered by kind (`:liveness`, `:readiness`, or `:startup`)
and return independent result objects. `define-health-check` validates the
source-level name and options at macroexpansion time. The execution path is
continuation based: each completed check invokes the continuation for the next
check, so a condition in one check is represented in that result and cannot
terminate the registry-wide run.

Timeouts use the registry's injected `cl-boundary-kit` clock and declared
monotonic units-per-second scale for deadlines and durations. A finite timeout
also has an independent real-time safety deadline, so a custom or fake clock
that stops advancing cannot keep a worker wait alive indefinitely. They first
request cooperative cancellation, then wait for a bounded grace period. On the
supported SBCL runtime, a worker that
ignores the token is terminated and the implementation verifies that it
stopped. If the runtime cannot provide that guarantee, the result is an
explicit health error; the package never reports a timed-out check as healthy.
Check functions should poll their token and bound their own external
operations.

`health-status` reads the last completed run only. It does not run checks as a
side effect, and separate health kinds are never implicitly merged. The
application decides which status belongs to each route and how a startup
failure affects service admission.

## Export and security boundaries

Snapshots and detached span/log records are the stable hand-off format for
exporters. Prometheus output sorts metric and label data, emits cumulative
histogram buckets, and escapes label/help/unit text. OTLP conversion preserves
resource and instrumentation-scope metadata in deterministic Common Lisp
data. Ending a recorded span invokes the configured export callback; explicit
flush and shutdown callbacks provide lifecycle boundaries. None of these
operations starts an HTTP client/server, opens a connection, or starts a
network thread.

Do not put personal information, tokens, credentials, authorization values,
raw headers, or unbounded user input into metric labels or instrumentation
attributes. The validator rejects common sensitive names, but callers must
still classify and redact values because no generic validator can recognize
every secret.

## Verification and coverage boundary

`run-coverage.lisp` passes explicit include and exclude pathnames to cl-weave
and requires 100% expression and branch coverage for the executable runtime
files. The excluded declaration and macro-expansion files are
`package.lisp`, `conditions.lisp`, `validation-data.lisp`,
`metrics-declarations.lisp`, `metrics-macros.lisp`, `health-declarations.lisp`,
`health-macros.lisp`, `context-declarations.lisp`, `context-macros.lisp`,
`log-kit-macros.lisp`, `package-prometheus.lisp`, `package-otlp.lisp`, and
`package-log-kit.lisp`.
Those files are still covered by compilation/loading, public API tests, and
boundary tests; the reported 100% is intentionally not a claim about every
source form. The test command uses a fail-closed empty or partially
non-runnable test policy so coverage cannot pass with no selected tests or a
silently reduced selection.

Each source component selects its package with a reader-time `#.` form, keeping
package setup outside executable coverage while preserving independent ASDF
loading. Package definition files remain explicit components in the system
definition.

The test suite uses cl-weave beyond example-based assertions: composed
generators exercise exact gauge state transitions, while `it-fuzz` feeds
Prometheus rendering label values containing escaping-sensitive characters.
Set `CL_WEAVE_PROPERTY_TESTS` and `CL_WEAVE_PROPERTY_SEED` to reproduce a
property run.

The raw `coverage.sexp` is an implementation artifact of cl-weave and SBCL and
may contain loaded dependency pathnames. The filtered `coverage-report/`
output and the explicit source policy above are the acceptance boundary; the
raw artifact is not application telemetry.
