# API reference

The public API is split into the core package and three independently loadable
integration packages. The exported names are declared in `src/package.lisp`.

## Core package

Use the `observability-kit` package (also available as `cl-observability-kit`)
for metrics, health, context, and shared conditions.

### Metrics

| Operation | Purpose |
| --- | --- |
| `make-metric-registry &rest option-list` | Create a registry. `:default-cardinality-limit` defaults to `1000`; `:max-label-value-length` defaults to `256`. |
| `define-counter`, `define-gauge`, `define-histogram` | Define a metric with a symbol name and options `:help`, `:unit`, `:label-names`, `:cardinality-limit`, and `:buckets`. These are macros. |
| `metric-inc metric &rest arguments` | Increment a counter or gauge. The optional amount defaults to `1`; the only operation option is `:labels`. |
| `metric-set metric value &key labels` | Set a gauge to an exact finite real value. |
| `metric-observe metric observation &key labels` | Record an exact finite real observation in a histogram. |
| `metric-snapshot object` | Return a detached snapshot for a metric, registry, or supported snapshot source. |
| `metric-registry-metrics registry` | Return definitions in deterministic metric-name order. |

Metric accessors include `metric-name`, `metric-help`, `metric-unit`,
`metric-label-names`, and `metric-kind`. Snapshot accessors include
`metric-snapshot-name`, `metric-snapshot-help`, `metric-snapshot-type`,
`metric-snapshot-unit`, `metric-snapshot-label-names`, and
`metric-snapshot-samples`. Sample accessors expose labels, value, histogram
count, sum, and buckets. `+infinity+` marks a histogram's final bucket.

Metric names and labels are validated as bounded ASCII names. Label names are
fixed at definition time; updates must provide the complete set. Counter values
cannot be negative, and all metric values must be finite real numbers.

### Health

| Operation | Purpose |
| --- | --- |
| `make-health-registry &rest option-list` | Create a registry. `:default-timeout` defaults to `5.0d0`; `:cancellation-grace-period` defaults to `0.1d0`; `:clock` and `:monotonic-units-per-second` configure time injection. |
| `define-health-check registry name (options) lambda-list &body body` | Define and register a check with a symbol name and options `:kind`, `:timeout`, `:cancellation-grace-period`, and `:replace`, checked at macroexpansion time. This is a macro. |
| `register-health-check registry name function &rest option-list` | Register a function accepting one cancellation token. Options are `:kind`, `:timeout`, `:cancellation-grace-period`, and `:replace`. Use this when the name or function is only known at runtime. |
| `unregister-health-check registry name &rest option-list` | Remove a check, using `:kind` to select the check kind. |
| `run-health-checks registry &key kind kinds cancellation-token` | Run selected checks and return independent `health-result` objects. |
| `health-status object &key kind` | Read `:healthy`, `:unhealthy`, or `:unknown` from a result, result list, or the last completed registry run. |

The check function returns true for pass, `nil` for a normal failure, or may
signal a condition. Supported kinds are `:liveness`, `:readiness`, and
`:startup`. `health-registry-checks` and `health-registry-last-results` expose
detached registry views.

When `:clock` is custom or fake, its monotonic values must use the unit scale
declared by `:monotonic-units-per-second`. `health-registry-clock` and
`health-registry-monotonic-units-per-second` expose the configured boundaries.

Cancellation is explicit through `make-cancellation-token`,
`cancel-cancellation-token`, `cancellation-requested-p`, and
`cancellation-reason`. A child token can inherit cancellation from a parent.

### Instrumentation context

| Operation | Purpose |
| --- | --- |
| `make-instrumentation-context &key trace-id span-id trace-flags attributes baggage` | Create validated, sorted metadata without starting a span. |
| `context-attribute context name &optional default` | Read one attribute. |
| `context-with-attribute context name value` | Return a context with one attribute override. |
| `context-with-attributes context attributes` | Return a context with merged attributes. |
| `current-instrumentation-context &optional default` | Read the dynamically scoped context. |
| `with-instrumentation-context` | Dynamically bind a context. |
| `capture-instrumentation-context &optional context` | Return a detached context copy. |
| `call-with-captured-instrumentation-context context function` | Run a function with a detached context dynamically bound. |
| `with-captured-instrumentation-context` | Macro form of the captured-context boundary. |

Context accessors expose trace and span identifiers, trace flags, attributes,
and baggage. Context creation and updates reject common sensitive attribute
names; they do not replace application-level redaction.

## Integration packages

### `observability-kit/prometheus`

Load `cl-observability-kit/prometheus` and call
`render-prometheus source &key stream`. `source` may be a metric, registry,
snapshot, or list of snapshots. The renderer sorts output deterministically,
emits cumulative histogram `_bucket` samples plus `_sum` and `_count`, and
escapes label, HELP, and UNIT text. `le` is reserved for histogram buckets.

### `observability-kit/otlp`

Load `cl-observability-kit/otlp` for `metric-snapshot->otlp`,
`snapshot->otlp`, and `registry->otlp`. These return deterministic Common Lisp
alists shaped for an OTLP adapter. They do not encode JSON or protobuf, open a
connection, or perform retries. `registry->otlp` accepts optional string
`scope-name` and `scope-version` metadata.

### `observability-kit/log-kit`

Load `cl-observability-kit/log-kit` for
`instrumentation-context-log-fields`, `with-log-kit-context`, and
`call-with-log-kit-context`. This bridge only maps context fields into the
existing `cl-log-kit` context; it does not create loggers, handlers, sinks, or
spans.

## Conditions

The core exports `observability-error`, `validation-error`, metric validation
and operation conditions, cardinality and definition-conflict conditions,
`unsafe-attribute-name`, `health-error`, `health-check-timeout`, and
`health-check-cancelled`. Callers can handle these conditions at the boundary
where an invalid update, failed probe, or cancellation should be reported.
