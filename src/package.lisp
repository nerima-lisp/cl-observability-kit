#.(progn
    (in-package #:cl-user)
    nil)

(defpackage #:observability-kit
  (:nicknames #:cl-observability-kit)
  (:use #:cl)
  (:export
   ;; Conditions
   #:observability-error
   #:validation-error
   #:invalid-metric-name
   #:invalid-label-name
   #:invalid-label-value
   #:invalid-label-set
   #:unsafe-attribute-name
   #:metric-definition-conflict
   #:metric-cardinality-exceeded
   #:metric-operation-error
   #:health-error
   #:health-check-timeout
   #:health-check-cancelled
   #:tracing-error
   #:invalid-span-name
   #:tracer-provider-shutdown
   #:span-operation-error
   #:logging-error
   #:invalid-log-severity
   #:propagation-error
   #:invalid-traceparent
   #:http-error
   #:invalid-http-method
   #:invalid-http-method-method
   #:invalid-http-status
   #:invalid-http-status-status

   ;; Metrics and snapshots
   #:metric-registry
   #:metric-registry-p
   #:make-metric-registry
   #:metric
   #:metric-p
   #:counter-p
   #:gauge-p
   #:histogram-p
   #:metric-name
   #:metric-help
   #:metric-unit
   #:metric-label-names
   #:metric-kind
   #:metric-registry-metrics
   #:define-counter
   #:define-gauge
   #:define-histogram
   #:metric-inc
   #:metric-set
   #:metric-observe
   #:metric-snapshot
   #:metric-snapshot-p
   #:metric-snapshot-name
   #:metric-snapshot-help
   #:metric-snapshot-type
   #:metric-snapshot-unit
   #:metric-snapshot-label-names
   #:metric-snapshot-samples
   #:metric-sample
   #:metric-sample-p
   #:metric-sample-labels
   #:metric-sample-value
   #:metric-sample-count
   #:metric-sample-sum
   #:metric-sample-buckets
   #:+infinity+

   ;; Health checks
   #:health-registry
   #:health-registry-p
   #:make-health-registry
   #:health-registry-clock
   #:health-registry-monotonic-units-per-second
   #:health-check
   #:health-check-p
   #:health-check-name
   #:health-check-kind
   #:health-check-function
   #:health-check-timeout
   #:health-check-cancellation-grace-period
   #:register-health-check
   #:unregister-health-check
   #:health-registry-checks
   #:health-registry-last-results
   #:run-health-checks
   #:health-result
   #:health-result-p
   #:health-result-name
   #:health-result-kind
   #:health-result-status
   #:health-result-value
   #:health-result-condition
   #:health-result-duration
   #:health-status
   #:define-health-check
   #:make-cancellation-token
   #:cancellation-token-p
   #:cancel-cancellation-token
   #:cancellation-requested-p
   #:cancellation-reason

   ;; Shared validation protocol
   #:proper-list-p

   ;; Instrumentation context
   #:instrumentation-context
   #:instrumentation-context-p
   #:make-instrumentation-context
   #:instrumentation-context-trace-id
   #:instrumentation-context-span-id
   #:instrumentation-context-trace-flags
   #:instrumentation-context-attributes
   #:instrumentation-context-baggage
   #:instrumentation-context-tracestate
   #:context-attribute
   #:context-with-attribute
   #:context-with-attributes
   #:current-instrumentation-context
   #:with-instrumentation-context
   #:capture-instrumentation-context
   #:call-with-captured-instrumentation-context
   #:with-captured-instrumentation-context

   ;; Resources
   #:resource
   #:resource-p
   #:make-resource
   #:resource-attributes
   #:resource-attribute
   #:resource-with-attribute
   #:resource-with-attributes

   ;; Tracing
   #:tracer-provider
   #:tracer-provider-p
   #:make-tracer-provider
   #:tracer-provider-resource
   #:tracer-provider-clock
   #:tracer-provider-tracers
   #:tracer-provider-shutdown-p
   #:tracer-provider-last-export-error
   #:force-flush-tracer-provider
   #:shutdown-tracer-provider
   #:tracer
   #:tracer-p
   #:make-tracer
   #:tracer-name
   #:tracer-version
   #:tracer-schema-url
   #:span
   #:span-p
   #:start-span
   #:end-span
   #:span-name
   #:span-kind
   #:span-trace-id
   #:span-id
   #:span-parent-span-id
   #:span-trace-flags
   #:span-start-time
   #:span-end-time
   #:span-duration
   #:span-status
   #:span-status-message
   #:span-recording-p
   #:span-sampled-p
   #:span-ended-p
   #:span-attributes
   #:span-set-attribute
   #:span-event
   #:span-event-p
   #:span-event-name
   #:span-event-timestamp
   #:span-event-attributes
   #:span-events
   #:span-add-event
   #:span-link
   #:span-link-p
   #:span-link-context
   #:span-link-attributes
   #:span-links
   #:span-add-link
   #:span-set-status
   #:span-record-exception
   #:span-context
   #:span-record
   #:span-record-p
   #:span-record-trace-id
   #:span-record-span-id
   #:span-record-parent-span-id
   #:span-record-name
   #:span-record-kind
   #:span-record-start-time
   #:span-record-end-time
   #:span-record-duration
   #:span-record-status
   #:span-record-status-message
   #:span-record-trace-flags
   #:span-record-sampled-p
   #:span-record-recording-p
   #:span-record-attributes
   #:span-record-events
   #:span-record-links
   #:span-record-resource
   #:span-record-tracer-name
   #:span-record-tracer-version
   #:span-record-tracer-schema-url
   #:current-span
   #:with-span
   #:call-with-span
   #:*current-span*

   ;; Structured logs
   #:log-record
   #:log-record-p
   #:make-log-record
   #:log-record-timestamp
   #:log-record-severity
   #:log-record-severity-text
   #:log-record-severity-number
   #:log-record-body
   #:log-record-attributes
   #:log-record-context
   #:log-record-resource
   #:log-record-scope-name
   #:log-record-scope-version
   #:log-record-scope-schema-url

   ;; W3C propagation
   #:format-traceparent
   #:parse-traceparent
   #:format-baggage
   #:parse-baggage
   #:inject-trace-context
   #:extract-trace-context

   ;; HTTP semantic conventions
   #:http-request-attributes
   #:http-response-attributes
   #:span-set-http-request
   #:span-set-http-response))
