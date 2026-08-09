# Getting started

## Prerequisites

The package follows the current `cl-concurrent-kit` stack and targets SBCL.
Use an ASDF setup that can see the checkout containing
`cl-observability-kit.asd`, or enter the Nix development shell:

```sh
nix develop
```

There is no release tag published in this repository yet. The examples below
therefore describe loading the current source checkout rather than claiming a
release pin.

## Load the systems

Load the core first. Integration systems are independent and can be loaded
only when they are needed:

```lisp
(asdf:load-system "cl-observability-kit")
(asdf:load-system "cl-observability-kit/prometheus")
;; Optional:
;; (asdf:load-system "cl-observability-kit/otlp")
;; (asdf:load-system "cl-observability-kit/log-kit")
```

The core has no HTTP client/server, network exporter, or `cl-log-kit`
dependency. It does provide span lifecycle, context propagation, structured
log records, and HTTP semantic-convention helpers. The Prometheus system
renders text, the OTLP system returns transport-neutral Common Lisp data, and
the `/log-kit` system maps context fields into the existing `cl-log-kit`
context.

## Record a metric

Define metrics during application setup. Names are symbols, and definition
options are checked when the macro expands:

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

Use `define-gauge` with `metric-set` or `metric-inc` for a current value, and
`define-histogram` with `metric-observe` for exact count, sum, and cumulative
bucket data. Counters accept finite non-negative real increments; gauges and
histograms accept finite real values. Label values are strings, each registry
has a maximum label-value length of 256 by default, and each metric has a
cardinality limit of 1000 by default.

An unlabelled metric exposes an initial zero sample. A labelled series is
created when its complete declared label set is first updated. Snapshots keep
the supplied Common Lisp numbers exact and sort their output deterministically.

## Run a health check

Health checks are explicit observations. Register a check once, run the
selected kind from an application route or scheduler, and map the result to
the application's response:

```lisp
(defparameter *health* (observability-kit:make-health-registry))

(observability-kit:define-health-check
 *health* database (:kind :readiness) (cancellation-token)
   ;; Poll the token around bounded dependency operations in real code.
   (if (observability-kit:cancellation-requested-p cancellation-token)
       nil
       t))

(observability-kit:run-health-checks *health* :kind :readiness)
(observability-kit:health-status *health* :kind :readiness)
;; => :HEALTHY after the successful run
```

`define-health-check` is a macro: NAME is a source-level symbol and its
options are checked at macroexpansion time, mirroring `define-counter`,
`define-gauge`, and `define-histogram`. Use the underlying
`register-health-check` function directly when the name or check function is
only known at runtime.

The supported kinds are `:liveness`, `:readiness`, and `:startup`. Each check
receives a child cancellation token and produces an independent result. A
timeout first requests cooperative cancellation and then applies the
configured grace period; on SBCL, a worker that remains alive is terminated
and checked. Before a kind has run, its registry status is `:UNKNOWN`.
`health-status` does not start a check implicitly.

## Carry context explicitly

Instrumentation context is immutable by convention and dynamically scoped.
Worker threads do not inherit a caller's current context implicitly. Capture
and install it at the worker boundary when propagation is intended:

```lisp
(let ((captured (observability-kit:capture-instrumentation-context)))
  (observability-kit:call-with-captured-instrumentation-context
   captured
   (lambda ()
     ;; Work that should observe the captured context.
     nil)))
```

Do not place credentials, raw headers, personal information, or unbounded
user-controlled values in labels or context attributes. Validation rejects
common sensitive names, but callers remain responsible for classification and
redaction.

## Record a span and correlated log

Create one provider per application boundary, then create tracers for the
instrumentation scopes that use it. The exporter callback receives a detached
`span-record` when a recorded span ends; it can hand that record to an
application exporter or to the OTLP adapter.

```lisp
(let ((exported nil))
  (let* ((provider
           (observability-kit:make-tracer-provider
            :resource
            (observability-kit:make-resource
             :attributes '(("service.name" . "orders")))
            :exporter (lambda (record) (push record exported))))
         (tracer (observability-kit:make-tracer provider "orders")))
    (observability-kit:with-span (root tracer "GET /orders" :kind :server)
      (observability-kit:span-set-http-request
       root "GET" :route "/orders" :scheme "https")
      (observability-kit:make-log-record
       :severity :info :body "request started")
      (observability-kit:span-set-http-response root 200))
    (observability-kit:shutdown-tracer-provider provider)
    exported))
```

`with-span` binds the current span and instrumentation context, records a
condition as an exception on error, and ends the span on every exit path. Use
`:parent nil` for an explicit root span or pass a span/context as `:parent`
for a detached parent.

## Propagate across a boundary

Propagation is an explicit boundary operation. Headers are string-keyed
alists; unrelated headers are copied and existing W3C fields are replaced.

```lisp
(let* ((outgoing
         (observability-kit:inject-trace-context
          (observability-kit:current-instrumentation-context)
          '(("user-agent" . "orders-client"))))
       (incoming (observability-kit:extract-trace-context outgoing)))
  incoming)
```

`traceparent`, `tracestate`, and `baggage` are validated at the trusted
boundary. Malformed incoming optional fields are ignored while a valid
`traceparent` is retained; callers should still apply their own trust and
redaction policy.

## Convert detached records

Load `cl-observability-kit/otlp` when an application needs OTLP-shaped data:

```lisp
(observability-kit/otlp:span-record->otlp span-record)
(observability-kit/otlp:log-record->otlp log-record)
(observability-kit/otlp:traces->otlp span-records)
```

These functions return deterministic Common Lisp alists for an adapter. They
do not perform serialization, retries, batching, or network I/O.
