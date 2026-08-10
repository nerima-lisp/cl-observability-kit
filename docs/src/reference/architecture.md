# Architecture

cl-observability-kit is the small, transport-neutral layer between an
application and its observability integrations. It owns validated telemetry
data, aggregation semantics, context propagation, provider lifecycle, and
detached records. It does not own HTTP routes or clients, network connections,
logger handlers or sinks, wire encoding, or deployment policy.

## Systems and boundaries

| System | Owns | Does not own |
| --- | --- | --- |
| cl-observability-kit | metric instruments and aggregation, readers, periodic collection, health semantics, cancellation tokens, resources, context, sampler decisions, tracer/provider/span lifecycle, structured logs, synchronous and bounded batch span processors, W3C and adapter propagation, HTTP semantic conventions, environment parsing | HTTP I/O, logger handlers and sinks, wire encoding, network I/O, network exporter queues and retries |
| cl-observability-kit/prometheus | deterministic Prometheus text rendering and escaping | an HTTP server or /metrics route |
| cl-observability-kit/otlp | deterministic OTLP-shaped Common Lisp data | JSON/protobuf encoding, an OTLP client, export retries |
| cl-observability-kit/log-kit | explicit context-field mapping to cl-log-kit | log records, handlers, sinks, formatting, span lifecycle |

The application chooses metric names, health probes, routes, exporter
lifecycle, provider-specific attributes, batching policy, and transport
security. This keeps the core useful for a library as well as for a service
and prevents an integration package from silently becoming an application
framework.

The core ASDF system depends directly on cl-concurrent-kit and
cl-boundary-kit: the former supplies synchronization and the latter supplies
the injectable wall/monotonic clock protocol. cl-date-kit remains a flake
input because it is followed by the nerima-lisp dependency graph, but it is
not a direct source dependency here. Optional systems add only the
integration they need.

## Provider and lifecycle flow

The signal providers share the same boundary shape:

1. Application setup creates a provider with resource metadata and callbacks.
2. Instrumentation scopes create meters, tracers, or loggers.
3. Operations update instruments or create detached span and log records.
4. Readers, processors, and exporters receive detached values outside the
   registry/provider locks.
5. Application shutdown calls force-flush and shutdown; callbacks and reader
   workers are isolated and joined at their own lifecycle boundary.

Metric providers own registries for instrumentation scopes. Pull readers
collect detached snapshots, and periodic readers run the same collection on a
worker at a configured interval. Trace processors observe span start/end and
provider lifecycle. Log processors observe detached log records and provider
lifecycle. The core provides a callback-only processor plus synchronous and
bounded batch span processors. The batch worker is local and bounded: it
preserves completion order, can emit partial batches after a delay, drops new
records when full, and drains during force-flush or shutdown. It is not a
serializer or network client.

## Data and source layout

The source layout keeps the primary data model separate from operations:

- metrics-model.lisp contains registry, metric, series, snapshot, and sample
  structures.
- metrics-definition.lisp contains the macro-first metric definition API.
- metrics-operation.lisp contains updates and exact numeric validation.
- metrics-snapshot.lisp detaches and sorts exporter input.
- metrics-sdk.lisp contains meter providers and pull readers.
- metrics-periodic.lisp contains periodic reader workers and lifecycle.
- validation.lisp, validation-values.lisp, and validation-numbers.lisp keep
  list, string, and numeric validation policies separate.
- health-declarations.lisp contains check, result, registry, cancellation,
  and thread-controller data structures.
- health-model.lisp creates cancellation tokens and registries and validates
  clock and timeout configuration.
- health-registry.lisp contains registration and lookup operations.
- health-thread.lisp owns monotonic deadlines, bounded joins, and thread
  lifecycle boundaries.
- health-execution.lisp runs checks and isolates conditions through the
  continuation boundary.
- health-status.lisp computes aggregate status without starting checks.
- health-macros.lisp provides the macro-first health definition API.
- resource-declarations.lisp and resource.lisp define immutable resource
  metadata shared by metric, trace, and log records.
- trace-model.lisp and trace-operation.lisp define tracer providers,
  instrumentation scopes, samplers, spans, lifecycle callbacks, and detached
  span records.
- propagation.lisp formats and validates W3C traceparent, tracestate, and
  baggage values without performing I/O.
- propagator.lisp composes propagation adapters.
- propagation-adapters.lisp implements B3, Jaeger, and AWS X-Ray carriers.
- configuration.lisp parses validated SDK environment settings.
- log-operation.lisp and log-sdk.lisp create detached structured log records,
  providers, processors, and logger scopes.
- trace-processors.lisp contains synchronous and bounded batch span processors,
  including worker lifecycle, queue limits, flush, shutdown, and error
  isolation.
- http.lisp validates HTTP semantic-convention attributes and attaches them to
  an existing span; it does not implement an HTTP client or server.
- prometheus-source.lisp selects and snapshots exporter input.
- prometheus-format.lisp normalizes numbers and escapes exposition text.
- prometheus-samples.lisp emits labels, samples, and histogram buckets.
- otlp.lisp converts detached metric, span, and log records to deterministic
  OTLP-shaped Common Lisp data.

Metric definitions are macros because names and options are configuration, not
runtime input. define-counter, define-gauge, and define-histogram reject
non-symbol names and unknown or duplicate options during macroexpansion. The
runtime API receives the resulting metric object and never guesses a metric
name from arbitrary input.

## Concurrency and cardinality

Registry mutation, series creation, metric updates, snapshots, and provider
registries are protected by locks supplied by cl-concurrent-kit. Snapshot
accessors return detached data, so exporters can sort and render without
holding a metric lock. Applications should define metrics during setup and
update them during operation; metric definitions are intentionally stable
after registration.

Label names are fixed per metric. Every labelled update must provide exactly
the declared names, label names and values are validated, and the registry
limits value length and series count. A new series beyond the configured
cardinality limit signals a condition instead of growing an unbounded table.
Metric values remain Common Lisp numbers until an exporter boundary; there is
no implicit float conversion in the core.

Instrumentation context bindings are thread-local. Worker threads do not
inherit a caller's dynamic context implicitly; use
with-captured-instrumentation-context at an explicit worker boundary when
context propagation is desired. Inject and extract operations provide the
carrier boundary; the application owns the carrier and its network transport.

## Sampling and propagation

The ratio sampler validates the closed interval from zero through one and
decides deterministically from the candidate trace ID. Parent-based sampling
preserves a valid parent decision and delegates root spans to its configured
root sampler. Custom sampler callbacks retain the four-argument API so
existing instrumentation remains compatible.

The default propagator is W3C Trace Context plus W3C Baggage. The core also
provides B3 single-header, B3 multi-header, Jaeger, and AWS X-Ray adapters,
plus a composite propagator. Adapter injection and extraction operate on
detached header alists and never perform I/O. Applications own carrier
transport, trust policy, and redaction.

## Health execution

Health checks are filtered by kind (:liveness, :readiness, or :startup) and
return independent result objects. define-health-check validates the
source-level name and options at macroexpansion time. The execution path is
continuation based: each completed check invokes the continuation for the
next check, so a condition in one check is represented in that result and
cannot terminate the registry-wide run.

Timeouts use the registry's injected cl-boundary-kit clock and declared
monotonic units-per-second scale for deadlines and durations. A finite timeout
also has an independent real-time safety deadline, so a custom or fake clock
that stops advancing cannot keep a worker wait alive indefinitely. The
implementation first requests cooperative cancellation, then waits for a
bounded grace period. On the supported SBCL runtime, a worker that ignores
the token is terminated and the implementation verifies that it stopped. If
the runtime cannot provide that guarantee, the result is an explicit health
error; the package never reports a timed-out check as healthy.

health-status reads the last completed run only. It does not run checks as a
side effect, and separate health kinds are never implicitly merged. The
application decides which status belongs to each route and how a startup
failure affects service admission.

## Export, configuration, and security boundaries

Snapshots and detached span/log records are the stable hand-off format for
exporters. Prometheus output sorts metric and label data, emits cumulative
histogram buckets, and escapes label/help/unit text. Metric snapshots retain
exact Common Lisp numeric values until this exporter boundary; Prometheus
formatting performs the text conversion there and keeps standard histogram
boundary representations deterministic. Structured log records carry
timestamp and observed timestamp, normalized severity text and number,
body, optional event name, attributes, context, resource, and
instrumentation-scope metadata. OTLP conversion maps these fields and
preserves resource and instrumentation-scope metadata in deterministic Common
Lisp data. Ending a recorded span invokes the configured processor/export
callbacks; explicit flush and shutdown callbacks provide lifecycle boundaries.
The built-in batch processor may start one local worker and keeps its queue
bounded, but none of these operations starts an HTTP client/server, opens a
connection, or performs network I/O.

The configuration parser accepts explicit environment alists and validates
SDK disabled state, service/resource metadata, propagator selection, metric
interval/timeout, local sampler selection, sampler arguments, and log level.
It does not construct remote sampler clients, network exporters, batching
queues, retry loops, or endpoint credentials. Those responsibilities belong
to an application or integration package that can make the relevant
transport and security choices.

Do not put personal information, tokens, credentials, authorization values,
raw headers, or unbounded user input into metric labels or instrumentation
attributes. The validator rejects common sensitive names, but callers must
still classify and redact values because no generic validator can recognize
every secret.

## Verification and coverage boundary

run-coverage.lisp passes explicit include and exclude pathnames to cl-weave
and requires 100% expression and branch coverage for the executable runtime
files. The excluded declaration and macro-expansion files are:

~~~text
package.lisp
conditions.lisp
validation-data.lisp
metrics-declarations.lisp
metrics-macros.lisp
health-declarations.lisp
health-macros.lisp
context-declarations.lisp
context-macros.lisp
resource-declarations.lisp
trace-declarations.lisp
trace-macros.lisp
log-declarations.lisp
log-kit-macros.lisp
package-prometheus.lisp
package-otlp.lisp
package-log-kit.lisp
~~~

Those files are still covered by compilation/loading, public API tests, and
boundary tests; the reported 100% is intentionally not a claim about every
source form. The test command uses a fail-closed empty or partially
non-runnable test policy so coverage cannot pass with no selected tests or a
silently reduced selection.

Each source component selects its package with a reader-time #. form, keeping
package setup outside executable coverage while preserving independent ASDF
loading. Package definition files remain explicit components in the system
definition.

The test suite uses cl-weave beyond example-based assertions: composed
generators exercise exact gauge state transitions, while it-fuzz feeds
Prometheus rendering label values containing escaping-sensitive characters.
Set CL_WEAVE_PROPERTY_TESTS and CL_WEAVE_PROPERTY_SEED to reproduce a
property run.

The raw coverage.sexp is an implementation artifact of cl-weave and SBCL and
may contain loaded dependency pathnames. The filtered coverage-report/
output and the explicit source policy above are the acceptance boundary; the
raw artifact is not application telemetry.
