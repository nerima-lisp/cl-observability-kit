# API reference

The public API is split between the core package and three independently
loadable integration packages. Exported names are declared in
src/package.lisp, src/package-otlp.lisp, src/package-prometheus.lisp, and
src/package-log-kit.lisp.

## Core package

Use the observability-kit package (also available as cl-observability-kit)
for metrics, health, resources, tracing, structured logs, propagation, HTTP
semantic conventions, context, configuration, and shared conditions.

## Metrics

| Operation | Purpose |
| --- | --- |
| make-metric-registry &rest option-list | Create a registry. :default-cardinality-limit defaults to 1000 and :max-label-value-length defaults to 256. |
| define-counter, define-up-down-counter, define-gauge, define-histogram | Define synchronous instruments with :help, :unit, :label-names, :cardinality-limit, and histogram :buckets. These are macros. |
| define-observable-counter, define-observable-up-down-counter, define-observable-gauge | Define callback-driven instruments. The callback receives an observe function during collection. |
| metric-inc metric &rest arguments | Increment a counter, up-down counter, or gauge. The amount defaults to 1; the operation option is :labels. |
| metric-set metric value &key labels | Set a gauge to an exact finite real value. |
| metric-observe metric observation &key labels | Record an exact finite real observation in a histogram. |
| metric-snapshot object | Return detached data for a metric, registry, or supported snapshot source. |
| metric-registry-metrics registry | Return definitions in deterministic metric-name order. |

Metric accessors include metric-name, metric-help, metric-unit,
metric-label-names, and metric-kind. Snapshot accessors include
metric-snapshot-name, metric-snapshot-help, metric-snapshot-type,
metric-snapshot-unit, metric-snapshot-label-names, and
metric-snapshot-samples. Sample accessors expose labels, value, histogram
count, sum, and buckets. +infinity+ marks a histogram's final bucket.

Metric names and labels are validated as bounded ASCII names. Label names are
fixed at definition time; updates must provide the complete set. Counter
values cannot be negative, and all metric values must be finite real numbers.

## Metric SDK lifecycle

| Operation | Purpose |
| --- | --- |
| make-meter-provider &rest option-list | Create a provider with :resource, :readers, :registry-options, :flush, :shutdown, and :error-handler. |
| make-meter provider name &key version schema-url | Create or return a cached instrumentation scope and its registry. |
| meter-registry meter | Return the registry owned by a meter. |
| make-metric-reader source &rest option-list | Create a pull reader from a metric, registry, meter, or provider. Options are :exporter, :flush, :shutdown, and :error-handler. |
| collect-metric-reader reader &key export-p | Collect detached snapshots and optionally call the exporter. |
| force-flush-metric-reader, shutdown-metric-reader | Run reader lifecycle callbacks; shutdown is idempotent. |
| make-periodic-metric-reader source &rest option-list | Wrap a reader with a worker. :interval is in seconds, :start defaults to true, and reader callback options are forwarded. |
| start-periodic-metric-reader, collect-periodic-metric-reader | Start a periodic worker or collect it immediately. |
| force-flush-periodic-metric-reader, shutdown-periodic-metric-reader | Flush a periodic reader or stop/join its worker and shut it down. |
| force-flush-meter-provider, shutdown-meter-provider | Flush or shut down registered readers and provider callbacks. |

Reader exporters receive detached lists of metric snapshots. Exporter,
flush, shutdown, and error-handler failures are isolated and retained in
last-error accessors. The core owns collection and lifecycle boundaries but
does not select a transport, serialize a wire format, or implement a
batching queue.

## Health

| Operation | Purpose |
| --- | --- |
| make-health-registry &rest option-list | Create a registry. :default-timeout defaults to 5.0d0; :cancellation-grace-period defaults to 0.1d0; :clock and :monotonic-units-per-second configure time injection. |
| define-health-check registry name (options) lambda-list &body body | Define and register a check with :kind, :timeout, :cancellation-grace-period, and :replace. This is a macro. |
| register-health-check registry name function &rest option-list | Register a function accepting one cancellation token. |
| unregister-health-check registry name &rest option-list | Remove a check, using :kind to select the check kind. |
| run-health-checks registry &key kind kinds cancellation-token | Run selected checks and return independent health-result objects. |
| health-status object &key kind | Read :healthy, :unhealthy, or :unknown from a result, result list, or last completed registry run. |

The check function returns true for pass, nil for a normal failure, or may
signal a condition. Supported kinds are :liveness, :readiness, and :startup.
Cancellation is explicit through make-cancellation-token,
cancel-cancellation-token, cancellation-requested-p, and
cancellation-reason. A child token can inherit cancellation from a parent.

## Resources and instrumentation context

| Operation | Purpose |
| --- | --- |
| make-resource &key attributes | Create immutable service/process metadata shared by emitted records. |
| make-instrumentation-context &key trace-id span-id trace-flags attributes baggage tracestate | Create validated, sorted metadata without starting a span. |
| context-attribute context name &optional default | Read one attribute. |
| context-with-attribute context name value | Return a context with one attribute override. |
| context-with-attributes context attributes | Return a context with merged attributes. |
| current-instrumentation-context &optional default | Read the dynamically scoped context. |
| with-instrumentation-context | Dynamically bind a context. |
| capture-instrumentation-context &optional context | Return a detached context copy. |
| call-with-captured-instrumentation-context context function | Run a function with a detached context dynamically bound. |
| with-captured-instrumentation-context | Macro form of the captured-context boundary. |

Context accessors expose trace and span identifiers, trace flags, attributes,
tracestate, and baggage. Context creation and updates reject common sensitive
attribute names; they do not replace application-level redaction. Worker
threads do not inherit a caller's dynamic context implicitly.

## Tracing and sampling

| Operation | Purpose |
| --- | --- |
| make-tracer-provider &rest option-list | Create a provider with :resource, :clock, :id-generator, :sampler, :exporter, :span-processors, :flush, :shutdown, and :export-error-handler. |
| make-tracer provider name &rest option-list | Create an instrumentation scope with optional :version and :schema-url. |
| make-span-processor &rest option-list | Create lifecycle callbacks :on-start, :on-end, :force-flush, :shutdown, and :error-handler. |
| make-simple-span-processor exporter &rest option-list | Create a synchronous processor. The exporter receives one sampled, detached span record in a proper list; optional callbacks are :flush, :shutdown, and :error-handler. |
| make-batch-span-processor exporter &rest option-list | Create an asynchronous bounded processor. Options include :schedule-delay, :max-queue-size, :max-export-batch-size, :start, :flush, :shutdown, and :error-handler. |
| register-span-processor provider processor | Attach a processor to an existing provider. |
| start-span tracer name &rest option-list | Start a span with :parent, :kind, :attributes, and :start-time. :parent defaults to the current span. |
| end-span span &rest option-list | End a span with :end-time, :status, and :status-message. |
| with-span (variable tracer name &rest options) &body body | Bind a span/context, record errors as exceptions, and end the span on every exit path. |
| make-trace-id-ratio-sampler ratio | Make a deterministic ratio sampler for a value in the range 0 through 1. |
| make-parent-based-sampler root-sampler | Preserve a valid parent decision and apply the root sampler when no parent decision exists. |
| force-flush-tracer-provider, shutdown-tracer-provider | Invoke processor, exporter, and provider lifecycle callbacks. |

Span accessors expose identity, parent, kind, timing, status, recording and
sampling state, attributes, events, links, instrumentation scope, resource,
and immutable span-context. The custom sampler callback keeps its four
argument contract: parent context, operation name, span kind, and attributes.
The built-in ratio sampler also uses the candidate trace ID for deterministic
decisions.

Built-in processors export sampled records only. The simple processor invokes
its exporter synchronously. The batch processor preserves completion order,
exports partial batches after its schedule delay, drops new records when its
bounded queue is full, and drains pending records during force-flush or
shutdown; shutdown also joins its local worker. Set :start to nil for lazy
startup. Install these processors through :span-processors and leave the
provider's direct :exporter unset to avoid duplicate export. Processor
callbacks receive detached proper lists and do not encode or send a wire
format.

## Structured logs

| Operation | Purpose |
| --- | --- |
| make-log-record &rest option-list | Create a detached record with `timestamp`, `observed-timestamp`, normalized severity text and number, body, optional event name, attributes, context, resource, and instrumentation-scope metadata. |
| make-log-processor &rest option-list | Create :on-emit, :force-flush, :shutdown, and :error-handler callbacks. |
| make-log-provider &rest option-list | Create a provider with :resource, :processors, :exporter, :flush, :shutdown, and :error-handler. |
| make-logger provider name &rest option-list | Create or return a logger scope with optional :version and :schema-url. |
| emit-log logger &rest option-list | Create and emit a record with timestamp, observed timestamp, severity, optional severity number, body, attributes, context, and event name fields. |
| emit-log-record logger record | Emit an existing record through processors and the provider exporter. |
| force-flush-log-provider, shutdown-log-provider | Invoke processor and provider lifecycle callbacks. |

The standard severity names are `TRACE`, `DEBUG`, `INFO`, `WARN`, `ERROR`, and
`FATAL`; their default severity numbers are 1, 5, 9, 13, 17, and 21. An
explicit `:severity-number` must be an integer from 1 through 24. Both
`:timestamp` and `:observed-timestamp` default to record construction time,
and `:event-name`, when supplied, must be a string. The public record
accessors expose these fields along with body, attributes, context, resource,
and instrumentation-scope metadata.

The current instrumentation context is attached by default; pass :context
nil for an explicitly uncorrelated record. Processors and exporters receive
detached records, and callback errors are isolated.

## Configuration

read-sdk-configuration accepts an environment alist through :environment or
reads the process environment when that argument is omitted. Accessors
include:

- sdk-configuration-disabled-p
- sdk-configuration-service-name
- sdk-configuration-resource-attributes
- sdk-configuration-resource
- sdk-configuration-propagator
- sdk-configuration-metric-export-interval
- sdk-configuration-metric-export-timeout
- sdk-configuration-trace-sampler
- sdk-configuration-log-level

The parser recognizes the SDK disabled flag, OTEL_SERVICE_NAME,
OTEL_RESOURCE_ATTRIBUTES, OTEL_PROPAGATORS, OTEL_METRIC_EXPORT_INTERVAL,
OTEL_METRIC_EXPORT_TIMEOUT, OTEL_TRACES_SAMPLER,
OTEL_TRACES_SAMPLER_ARG, and OTEL_LOG_LEVEL. The metric interval and timeout
are returned in seconds; defaults are 60 seconds and 30 seconds.

Supported propagator tokens are tracecontext, baggage, b3, b3multi, jaeger,
xray, and none. The default is tracecontext,baggage. Supported local sampler
tokens are always_on, always_off, traceidratio, parentbased_always_on,
parentbased_always_off, and parentbased_traceidratio. Invalid or conflicting
propagator or sampler selections signal configuration-error; malformed ratio
arguments are ignored and use the documented default without read-time
evaluation.

Remote sampler clients, exporter endpoint selection, batch queues, retries,
and network security policy are intentionally outside this parser and must be
implemented by the application or an integration package.

## Propagation

| Operation | Purpose |
| --- | --- |
| format-traceparent context / parse-traceparent header | Format or validate a W3C traceparent value. |
| format-baggage context / parse-baggage header | Format or parse normalized W3C baggage members. |
| inject-trace-context context headers / extract-trace-context headers | Inject or extract W3C Trace Context and Baggage. |
| make-w3c-propagator | Create the W3C adapter. |
| make-composite-propagator &rest propagators | Try adapters in order for extraction and inject through all adapters. |
| make-b3-propagator / make-b3-multi-propagator | Use B3 single or multi-header carriers. |
| make-jaeger-propagator | Use the Jaeger uber-trace-id carrier. |
| make-xray-propagator | Use the AWS X-Ray trace header carrier. |
| propagator-inject / propagator-extract | Apply a selected propagator to a header alist and context. |

Propagation never performs I/O. Headers are copied before injection and
malformed incoming optional fields are ignored at the trusted boundary.
Applications own carrier transport, trust policy, and redaction.

## HTTP semantic conventions

The HTTP API attaches validated semantic-convention attributes to an existing
span; it is not an HTTP client or server:

| Operation | Purpose |
| --- | --- |
| http-request-attributes method &rest option-list | Return request attributes for method, route, URL, scheme, addresses/ports, user agent, body size, and protocol version. |
| http-response-attributes status &rest option-list | Return response attributes for status and body size. |
| span-set-http-request span method &rest option-list | Attach request attributes to a span. |
| span-set-http-response span status &rest option-list | Attach response attributes to a span. |

## Integration packages

### observability-kit/prometheus

Load cl-observability-kit/prometheus and call render-prometheus source
&key stream. The source may be a metric, registry, snapshot, or list of
snapshots. The renderer sorts output deterministically, emits cumulative
histogram bucket samples plus _sum and _count, and escapes label, HELP, and
UNIT text.

### observability-kit/otlp

Load cl-observability-kit/otlp for metric-snapshot->otlp, registry->otlp,
span-record->otlp, traces->otlp, log-record->otlp, and
logs->otlp. These return deterministic Common Lisp alists shaped for an OTLP
adapter. They do not encode JSON or protobuf, open a connection, or perform
retries. Metric conversion accepts optional scope metadata; trace and log
conversion preserves resource and instrumentation-scope data.

### observability-kit/log-kit

Load cl-observability-kit/log-kit for instrumentation-context-log-fields,
with-log-kit-context, and call-with-log-kit-context. This bridge maps context
fields into the existing cl-log-kit context; it does not create loggers,
handlers, sinks, or spans.

## Conditions

The core exports observability-error, validation-error, metric validation and
operation conditions, cardinality and definition-conflict conditions,
unsafe-attribute-name, health-error, health-check-timeout,
health-check-cancelled, tracing conditions, logging conditions,
propagation-error, configuration-error, and HTTP conditions such as
invalid-http-method and invalid-http-status. Callers can handle these at the
boundary where invalid input, failed probes, export failures, or cancellation
should be reported.
