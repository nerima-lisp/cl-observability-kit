# Architecture

`cl-observability-kit` is the small, transport-neutral layer between an
application and its observability integrations. It owns stable data and
aggregation semantics. It does not own HTTP routes, network connections,
logger handlers, span lifecycles, or deployment policy.

## Systems and boundaries

| System | Owns | Does not own |
| --- | --- | --- |
| `cl-observability-kit` | metric data, aggregation, validation, cardinality limits, health semantics, cancellation tokens, instrumentation metadata | HTTP, logging, spans, network I/O |
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
- `prometheus-source.lisp` selects and snapshots exporter input.
- `prometheus-format.lisp` normalizes numbers and escapes exposition text.
- `prometheus-samples.lisp` emits labels, samples, and histogram buckets.

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
context propagation is desired.

## Health execution

Health checks are filtered by kind (`:liveness`, `:readiness`, or `:startup`)
and return independent result objects. `define-health-check` validates the
source-level name and options at macroexpansion time. The execution path is
continuation based: each completed check invokes the continuation for the next
check, so a condition in one check is represented in that result and cannot
terminate the registry-wide run.

Timeouts use the registry's injected `cl-boundary-kit` clock for monotonic
deadlines and durations. They first request cooperative cancellation, then
wait for a bounded grace period. On the supported SBCL runtime, a worker that
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

Snapshots are the stable hand-off format for exporters. Prometheus output
sorts metric and label data, emits cumulative histogram buckets, and escapes
label/help/unit text. The OTLP system is similarly transport-neutral. Neither
system starts a client or server.

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
