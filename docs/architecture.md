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

## Data and logic

The source layout keeps the primary data model separate from operations:

- `metrics-model.lisp` contains registry, metric, series, snapshot, and
  sample structures.
- `metrics-definition.lisp` contains the macro-first metric definition API.
- `metrics-operation.lisp` contains updates and exact numeric validation.
- `metrics-snapshot.lisp` detaches and sorts exporter input.
- `health-model.lisp` contains check, result, registry, and cancellation data.
- `health-registry.lisp` contains registration and lookup operations.
- `health-execution.lisp` runs checks, isolates conditions, and applies
  timeout/cancellation policy.

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

## Health execution

Health checks are filtered by kind (`:liveness`, `:readiness`, or `:startup`)
and return independent result objects. The execution path is continuation
based: each completed check invokes the continuation for the next check, so a
condition in one check is represented in that result and cannot terminate the
registry-wide run.

Timeouts first request cooperative cancellation, then wait for a bounded
grace period. On the supported SBCL runtime, a worker that ignores the token
is terminated and the implementation verifies that it stopped. If the
runtime cannot provide that guarantee, the result is an explicit health error;
the package never reports a timed-out check as healthy. Check functions should
poll their token and bound their own external operations.

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
