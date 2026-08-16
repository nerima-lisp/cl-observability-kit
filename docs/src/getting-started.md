# Getting started

## Prerequisites

The package follows the current cl-concurrent-kit stack and targets SBCL.
Use an ASDF setup that can see the checkout containing
cl-observability-kit.asd, or enter the Nix development shell:

~~~sh
nix develop
~~~

Pin to the `v1.0.0` tag for a reproducible checkout, or use `main` for the
current development source. There is no Quicklisp or Ultralisp distribution;
installation is a git checkout made visible to ASDF.

## Load the systems

Load the core first. Integration systems are independent and can be loaded
only when needed:

~~~lisp
(asdf:load-system "cl-observability-kit")
(asdf:load-system "cl-observability-kit/prometheus")
;; Optional:
;; (asdf:load-system "cl-observability-kit/otlp")
;; (asdf:load-system "cl-observability-kit/log-kit")
~~~

The core has no HTTP client/server, network exporter, or cl-log-kit
dependency. It provides validated telemetry data, provider and processor
lifecycle, context propagation, structured log records, and HTTP
semantic-convention helpers. The Prometheus system renders text, the OTLP
system returns transport-neutral Common Lisp data, and the log-kit system maps
context fields into the existing cl-log-kit context.

## Record metrics

Define instruments during application setup. Names are symbols and definition
options are checked when the macro expands:

~~~lisp
(defparameter *registry* (observability-kit:make-metric-registry))

(defparameter *requests*
  (observability-kit:define-counter
   *registry* requests-total
   :help "Completed requests."
   :label-names '("method" "status")))

(observability-kit:metric-inc
 *requests* 1
 :labels '(("method" . "GET") ("status" . "200")))

(format t "~A"
        (observability-kit/prometheus:render-prometheus *registry*))
~~~

Use define-up-down-counter when a value may increase or decrease, and
define-gauge with metric-set or metric-inc for a current value. Use
define-histogram with metric-observe for exact count, sum, and cumulative
bucket data. Observable instruments receive a callback that calls the
provided observe function during collection.

Label values are strings, every labelled update must provide the complete
declared label set, and each registry has a maximum label-value length of 256
by default. Each metric has a cardinality limit of 1000 by default. Snapshots
are detached and sorted deterministically.

### Meter providers and readers

Use a meter provider when instrumentation scopes and reader lifecycle matter:

~~~lisp
(let* ((provider (observability-kit:make-meter-provider
                  :resource
                  (observability-kit:make-resource
                   :attributes '(("service.name" . "orders")))))
       (meter (observability-kit:make-meter provider "orders"))
       (registry (observability-kit:meter-registry meter))
       (reader
         (observability-kit:make-metric-reader
          provider
          :exporter
          (lambda (snapshots)
            ;; Hand detached snapshots to an application exporter.
            (declare (ignore snapshots))
            t))))
  (observability-kit:define-counter registry requests-total)
  (observability-kit:force-flush-metric-reader reader)
  (observability-kit:shutdown-meter-provider provider))
~~~

The reader exporter receives a detached list of metric snapshots. A reader
created from a meter provider is registered with that provider, so provider
flush and shutdown also reach it. A periodic reader can collect the same
source:

~~~lisp
(let* ((reader
         (observability-kit:make-periodic-metric-reader
          *registry*
          :interval 30.0d0
          :start nil
          :exporter (lambda (snapshots)
                      (declare (ignore snapshots))
                      t))))
  (observability-kit:start-periodic-metric-reader reader)
  (observability-kit:force-flush-periodic-metric-reader reader)
  (observability-kit:shutdown-periodic-metric-reader reader))
~~~

The periodic interval is in seconds and defaults to 60.0d0. Shutdown stops
and joins the worker before returning. Reader and provider callback failures
are isolated, retained as last-error state, and optionally sent to an
error-handler.

## Run a health check

Health checks are explicit observations. Register a check once, run the
selected kind from an application route or scheduler, and map the result to
the application's response:

~~~lisp
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
~~~

The supported kinds are :liveness, :readiness, and :startup. Each check
receives a child cancellation token and produces an independent result. A
timeout requests cooperative cancellation and then applies the configured
grace period. Before a kind has run, its registry status is :UNKNOWN.
health-status does not start a check implicitly.

## Carry context explicitly

Instrumentation context is immutable by convention and dynamically scoped.
Worker threads do not inherit a caller's current context implicitly. Capture
and install it at the worker boundary when propagation is intended:

~~~lisp
(let ((captured (observability-kit:capture-instrumentation-context)))
  (observability-kit:call-with-captured-instrumentation-context
   captured
   (lambda ()
     ;; Work that should observe the captured context.
     nil)))
~~~

Do not place credentials, raw headers, personal information, or unbounded
user-controlled values in labels or context attributes. Validation rejects
common sensitive names, but callers remain responsible for classification and
redaction.

## Record spans

Create one provider per application boundary, then create tracers for the
instrumentation scopes that use it. A span processor sees lifecycle events,
and the exporter receives a detached span record when a recorded span ends:

~~~lisp
(let* ((processor
         (observability-kit:make-span-processor
          :on-end (lambda (record)
                    ;; Hand the detached record to an application exporter.
                    (declare (ignore record))
                    t)))
       (provider
         (observability-kit:make-tracer-provider
          :resource
          (observability-kit:make-resource
           :attributes '(("service.name" . "orders")))
          :span-processors (list processor)))
       (tracer (observability-kit:make-tracer provider "orders")))
  (observability-kit:with-span
      (root tracer "GET /orders" :kind :server)
    (observability-kit:span-set-http-request
     root "GET" :route "/orders" :scheme "https")
    (observability-kit:span-set-http-response root 200))
  (observability-kit:force-flush-tracer-provider provider)
  (observability-kit:shutdown-tracer-provider provider))
~~~

with-span binds the current span and instrumentation context, records a
condition as an exception on error, and ends the span on every exit path. Use
:parent nil for an explicit root span or pass a span/context as :parent for a
detached parent. Samplers can drop a span, record it without sampling, or
record and sample it.

The built-in local sampler configuration supports always_on, always_off,
traceidratio, parentbased_always_on, parentbased_always_off, and
parentbased_traceidratio. The ratio sampler validates a value in the closed
range 0 through 1 and makes a deterministic decision from the trace ID.

### Choose a span processor

Use `make-simple-span-processor` for synchronous export. Its exporter receives
a proper list containing one sampled, detached span record per call. Use
`make-batch-span-processor` when export should run on a local worker with a
bounded queue:

~~~lisp
(let* ((processor
         (observability-kit:make-batch-span-processor
          (lambda (records)
            ;; Encode or send records in an application integration.
            (declare (ignore records))
            t)
          :schedule-delay 1.0d0
          :max-queue-size 2048
          :max-export-batch-size 512))
       (provider
         (observability-kit:make-tracer-provider
          :span-processors (list processor)))
       (tracer (observability-kit:make-tracer provider "orders")))
  (observability-kit:with-span (span tracer "GET /orders")
    (declare (ignore span)))
  (observability-kit:force-flush-tracer-provider provider)
  (observability-kit:shutdown-tracer-provider provider))
~~~

The batch defaults are a five-second schedule delay, a 2048-record queue, and
512 records per export. Set `:start nil` to start the worker lazily when the
first sampled record arrives. `force-flush-tracer-provider` drains pending and
in-flight records; shutdown drains the queue, joins the local worker, and is
idempotent. Records arriving after `:max-queue-size` is reached are dropped,
so choose the limit together with the application's loss and backpressure
policy. `:flush` and `:shutdown` callbacks receive the provider. An
`:error-handler` receives the error and the failed callback argument (the
batch for an exporter failure, or `nil` for a worker lifecycle failure).

Install these processors through `:span-processors` and leave the provider's
legacy direct `:exporter` option unset; configuring both exports a span twice.
Both built-in processors invoke application callbacks only. Serialization,
retry policy, and network I/O remain integration responsibilities.

## Emit structured logs

Log providers mirror tracer providers: records are detached before processor
and exporter callbacks, and callback failures are isolated:

~~~lisp
(let* ((processor
         (observability-kit:make-log-processor
          :on-emit (lambda (record)
                     (declare (ignore record))
                     t)))
       (provider
         (observability-kit:make-log-provider
          :processors (list processor)
          :exporter (lambda (record)
                      (declare (ignore record))
                      t)))
       (logger (observability-kit:make-logger provider "orders")))
  (observability-kit:emit-log
   logger
   :severity :info
   :body "request completed"
   :attributes '(("route" . "/orders")))
  (observability-kit:force-flush-log-provider provider)
  (observability-kit:shutdown-log-provider provider))
~~~

Use make-log-record and emit-log-record when a record is constructed by
another integration. The current instrumentation context is attached by
default; pass :context nil for an explicitly uncorrelated record. Each record
has a `timestamp` and an `observed-timestamp`, both defaulting to construction
time, plus normalized severity text and number. The standard severities are
`TRACE`, `DEBUG`, `INFO`, `WARN`, `ERROR`, and `FATAL`; pass
`:severity-number` to provide an integer from 1 through 24, and pass
`:event-name` when the integration has a stable event name.

## Propagate across a boundary

Propagation is an explicit boundary operation. Headers are string-keyed
alists; unrelated headers are copied and existing fields owned by the selected
propagator are replaced:

~~~lisp
(let* ((outgoing
         (observability-kit:inject-trace-context
          (observability-kit:current-instrumentation-context)
          '(("user-agent" . "orders-client"))))
       (incoming (observability-kit:extract-trace-context outgoing)))
  incoming)
~~~

The default configuration is W3C Trace Context plus W3C Baggage. The
propagation API also provides B3 single-header, B3 multi-header, Jaeger, and
AWS X-Ray adapters:

~~~lisp
(let ((b3 (observability-kit:make-b3-propagator)))
  (observability-kit:propagator-inject
   b3
   (observability-kit:current-instrumentation-context)
   nil))
~~~

Use make-composite-propagator to try configured propagators in order during
extraction and to inject through all of them. The adapters do not perform
I/O. traceparent, tracestate, and baggage are validated at the trusted
boundary; callers should still apply their own trust and redaction policy.

## Read environment configuration

read-sdk-configuration accepts an explicit environment alist, which makes
configuration deterministic in tests and in application startup:

~~~lisp
(let ((configuration
        (observability-kit:read-sdk-configuration
         :environment
         '(("OTEL_SERVICE_NAME" . "orders")
           ("OTEL_RESOURCE_ATTRIBUTES" . "deployment.environment=prod")
           ("OTEL_TRACES_SAMPLER" . "traceidratio")
           ("OTEL_TRACES_SAMPLER_ARG" . "0.25")
           ("OTEL_PROPAGATORS" . "tracecontext,baggage,b3")))))
  (observability-kit:sdk-configuration-service-name configuration))
~~~

The parser covers SDK disabled state, service name, resource attributes,
propagator selection, metric export interval and timeout, local trace sampler,
sampler argument, and log level. Supported propagator tokens are
tracecontext, baggage, b3, b3multi, jaeger, xray, and none. Unsupported or
conflicting propagator or sampler selections signal configuration-error;
invalid ratio arguments use the documented default instead of being evaluated
as code.

Remote sampler clients, exporter selection, batch queues, retries, and
environment-specific network endpoints remain application or integration
responsibilities. The configuration object describes those boundaries but
does not silently create clients or network threads.

## Convert detached records

Load cl-observability-kit/otlp when an application needs OTLP-shaped data:

~~~lisp
(observability-kit/otlp:metric-snapshot->otlp metric-snapshot)
(observability-kit/otlp:registry->otlp registry)
(observability-kit/otlp:span-record->otlp span-record)
(observability-kit/otlp:log-record->otlp log-record)
(observability-kit/otlp:traces->otlp span-records)
(observability-kit/otlp:logs->otlp log-records)
~~~

These functions return deterministic Common Lisp alists for an adapter. They
do not perform serialization, retries, batching, or network I/O.
