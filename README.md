# cl-observability-kit

`cl-observability-kit` is a transport-neutral observability substrate for
Common Lisp applications and libraries. It provides metrics, deterministic
snapshots, health semantics, and immutable instrumentation metadata while
leaving routes, exporters, logging, and span lifecycle to the application or
the appropriate integration package.

The core system has no HTTP client/server, network exporter, or dependency on
`cl-log-kit`. It uses `cl-concurrent-kit` for synchronization and the public
clock protocol from `cl-boundary-kit`; the current `cl-concurrent-kit`
integration is SBCL-only in the nerima-lisp stack.

## Systems

| ASDF system | Responsibility |
| --- | --- |
| `cl-observability-kit` | Metrics, labels, registry, snapshots, health checks, cancellation tokens, and instrumentation context. |
| `cl-observability-kit/prometheus` | Deterministic Prometheus text exposition. |
| `cl-observability-kit/otlp` | Deterministic, transport-neutral OTLP-shaped Common Lisp data. It does not encode JSON/protobuf or send anything. |
| `cl-observability-kit/log-kit` | Optional bridge that puts instrumentation context fields into `cl-log-kit`'s existing log context. |

There is intentionally no HTTP system in the core. `/metrics`, `/health`,
`/ready`, and `/live` routes, HTTP server lifecycle, and an optional
`cl-http-kit` adapter belong to the application boundary. The exporter
systems can therefore be used with any HTTP stack or without HTTP at all.

## Quick start

The following uses only the public core and Prometheus APIs:

```lisp
(defparameter *registry* (observability-kit:make-metric-registry))

(defparameter *requests*
  (observability-kit:define-counter
   *registry* requests_total
   :help "Completed requests."
   :label-names '("method" "status")))

(observability-kit:metric-inc
 *requests* 1
 :labels '(("method" . "GET") ("status" . "200")))

(format t "~A"
        (observability-kit/prometheus:render-prometheus *registry*))
```

`define-gauge`, `define-histogram`, `metric-set`, `metric-observe`,
`metric-snapshot` follows the same public model. Metric definitions are
macros and require a symbol so that invalid names and definition options fail
at macroexpansion time.
Unlabelled metrics expose an initial zero sample; labelled series are created
when their complete label set is first updated.

## Health quick start

Health checks are explicit observations. Register a check once, run the
selected kind from the application's health route or scheduler, and map the
returned status to the application's response:

```lisp
(defparameter *health* (observability-kit:make-health-registry))

(observability-kit:define-health-check
 *health* database (:kind :readiness) (cancellation-token)
   (declare (ignore cancellation-token))
   ;; Replace this with a bounded, cancellation-aware dependency probe.
   t)

(observability-kit:run-health-checks *health* :kind :readiness)
(observability-kit:health-status *health* :kind :readiness)
;; => :HEALTHY after the successful run
```

`run-health-checks` returns independent result objects and records the last
completed run. `health-status` only reads that recorded result; it never starts
checks implicitly. Liveness, readiness, and startup are separate filters, so
the application can expose them through different routes without coupling the
registry to an HTTP server.

## Metrics and labels

- Counters accept finite, non-negative real numbers.
- Gauges accept finite real numbers and can be set or incremented.
- Histograms retain exact count, sum, and cumulative bucket values. Their
  bucket boundaries are fixed at definition time and must be finite, strictly
  increasing real numbers.
- Metric names and label names use an ASCII validation policy. Label names are
  fixed when a metric is defined; every update must provide the complete set.
- Label values are strings and are bounded by the registry's configured
  maximum length (256 by default).
- Each metric has a bounded series/cardinality limit (1000 by default). A new
  label set beyond that limit signals `metric-cardinality-exceeded` instead of
  silently growing an unbounded table.
- Names beginning with `__` and names containing sensitive-data fragments are
  rejected. The same policy applies to instrumentation attribute names and
  health check names.

The core never implicitly converts metric values to floating point. Snapshot
values retain the supplied Common Lisp numeric value. Prometheus conversion
happens only at the text boundary for values that cannot be written as a
decimal literal directly.

Metric updates, series creation, and snapshots are protected by locks and are
safe to use concurrently. Snapshot accessors return detached data. A metric's
definition should be treated as stable after registration; applications should
define metrics during setup and update them during operation.

Snapshots sort metric names, label names, label pairs, and samples
deterministically. They are the stable hand-off representation for exporters.

## Prometheus exposition

`render-prometheus` accepts a metric, registry, snapshot, or list of
snapshots. It sorts metric and label output, emits histogram `_bucket`, `_sum`,
and `_count` samples, and escapes backslashes, quotes, and line endings in
label values. HELP and UNIT text escape backslashes and line endings.

The label name `le` is reserved for histogram buckets. Do not define it as a
regular histogram label.

## Health, readiness, liveness, and startup

Health checks are registered with one of `:liveness`, `:readiness`, or
`:startup`. `define-health-check` validates the source-level name and options
during macroexpansion. A check function receives one cancellation token and
returns a true value for pass, `nil` for a normal failure, or may signal a
condition.
Each check produces an isolated `health-result`; one failing or signalling
check does not abort the registry run. `health-status` reports the last
completed run and never starts checks implicitly. Before a selected kind has
run, its status is `:unknown`.

Timeouts use an injectable monotonic clock, request cooperative cancellation
first, and wait for the configured grace period. On the supported SBCL runtime, a still-running worker is
forcefully terminated and the implementation checks that it stopped; if the
runtime cannot stop it, the result carries a `health-error` instead of hiding
the failure. Checks should still poll `cancellation-requested-p` and bound
their own blocking operations so cancellation can finish promptly.

Startup checks are a distinct kind and are not automatically treated as
liveness or readiness checks. The application decides when to run them and
whether a startup failure should prevent serving traffic.

## Instrumentation context and security

`make-instrumentation-context` stores trace/span identifiers, flags, sorted
attributes, and baggage. Context values are immutable by convention: extension
functions return detached contexts, and dynamic binding is available through
`with-instrumentation-context`. This package does not create spans or own
span lifecycle.

Do not put personal information, user-controlled high-cardinality values,
tokens, passwords, cookies, `Authorization` values, API keys, credentials,
private keys, email addresses, phone numbers, or raw request headers in metric
labels or instrumentation attributes. Prefer bounded classifications such as
`"method"`, `"status"`, or a small deployment region set. Validation rejects
common sensitive names, but it cannot recognize every secret encoded in a
value, so callers remain responsible for data classification and redaction.

`cl-log-kit` remains responsible for structured log records, handlers, sinks,
formatting, and span lifecycle. The optional `/log-kit` system only maps an
instrumentation context to fields consumed by `log-kit:with-log-context`; it
does not create a logger, handler, span, or sink.

Applications remain responsible for domain-specific metric names, deployment
health checks, HTTP routes, exporter startup/shutdown, and provider-specific
attributes.

## Architecture and development

The core deliberately separates metric/health data from operations and keeps
transport concerns outside the package. Health execution uses a continuation
chain internally so one check, timeout, or cancellation result cannot abort
the remaining checks. See [the architecture notes](docs/architecture.md) for
the ownership boundaries, clock protocol, and extension points.

The repository pins the current nerima-lisp dependency floors in the ASDF
systems and provides a Nix development shell with the pinned `paredit-cli`
tool (the executable is `paredit`). The optional systems remain independently
loadable; loading the core does not load
`cl-log-kit`, an HTTP client/server, or an exporter transport.

Dynamic instrumentation context bindings are thread-local; a newly created
worker does not inherit the caller's current context. Capture and install it
explicitly at the worker boundary with
`with-captured-instrumentation-context` when propagation is intended.

## Testing

With the `nerima-lisp` repositories available to ASDF, run:

```lisp
(asdf:test-system "cl-observability-kit")
```

For a reproducible local run from the repository root:

```sh
sbcl --script run-tests.lisp
sbcl --script run-coverage.lisp
nix flake check
```

`run-coverage.lisp` asks cl-weave for expression and branch coverage with a
100% minimum. Coverage artifacts are written under `coverage-report/` and
`coverage.sexp`, both ignored by Git. The Nix shell also exposes the pinned
`paredit-cli` as `paredit` for read-only structural validation and analysis;
`nix fmt` runs the configured formatter.

The raw `coverage.sexp` is a cl-weave/SBCL artifact and may include pathnames
for loaded dependencies. Use the filtered `coverage-report/` output and the
explicit source policy above as the repository acceptance boundary; do not
publish the raw file as application telemetry.

The 100% threshold applies to the executable runtime files explicitly included
by `run-coverage.lisp`. Declaration and macro-expansion files are intentionally
excluded from SBCL runtime instrumentation because their behavior is exercised
through compile/load and public-boundary tests. The excluded files are:

```text
src/package.lisp
src/conditions.lisp
src/validation-data.lisp
src/metrics-declarations.lisp
src/metrics-macros.lisp
src/health-declarations.lisp
src/health-macros.lisp
src/context-declarations.lisp
src/context-macros.lisp
src/log-kit-macros.lisp
src/package-prometheus.lisp
src/package-otlp.lisp
src/package-log-kit.lisp
```

This is a documented coverage boundary, not a claim that every source form is
runtime-instrumented. The test runner also rejects an empty test selection, so
a vacuous green coverage run is not accepted.

Source files select their package with a reader-time `#.` form. This keeps
package setup out of executable coverage while allowing every ASDF component
to be loaded independently; package definitions themselves remain explicit
ASDF components.

The test system covers metric aggregation, validation, bounded cardinality,
deterministic snapshots, Prometheus escaping, concurrent updates, health
failure isolation and cancellation, readiness/liveness/startup separation,
instrumentation context, the optional log bridge, OTLP-shaped output, secret
rejection, and the public-API quick start. It also uses cl-weave's generator
composition (`gen-list`, `gen-tuple`, and `gen-member`) for metric invariants
and `it-fuzz` for Prometheus label escaping/no-crash coverage. Property tests
can be made reproducible with `CL_WEAVE_PROPERTY_TESTS` and
`CL_WEAVE_PROPERTY_SEED`.

## License

MIT.
