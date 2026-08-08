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
   #:make-cancellation-token
   #:cancellation-token-p
   #:cancel-cancellation-token
   #:cancellation-requested-p
   #:cancellation-reason

   ;; Instrumentation context
   #:instrumentation-context
   #:instrumentation-context-p
   #:make-instrumentation-context
   #:instrumentation-context-trace-id
   #:instrumentation-context-span-id
   #:instrumentation-context-trace-flags
   #:instrumentation-context-attributes
   #:instrumentation-context-baggage
   #:context-attribute
   #:context-with-attribute
   #:context-with-attributes
   #:current-instrumentation-context
   #:with-instrumentation-context
   #:capture-instrumentation-context
   #:call-with-captured-instrumentation-context
   #:with-captured-instrumentation-context))

(defpackage #:observability-kit/prometheus
  (:nicknames #:cl-observability-kit/prometheus)
  (:use #:cl)
  (:import-from #:observability-kit
                #:observability-error
                #:metric
                #:metric-p
                #:metric-registry
                #:metric-registry-p
                #:metric-snapshot
                #:metric-snapshot-p
                #:metric-snapshot-name
                #:metric-snapshot-help
                #:metric-snapshot-type
                #:metric-snapshot-unit
                #:metric-snapshot-label-names
                #:metric-snapshot-samples
                #:metric-sample-labels
                #:metric-sample-value
                #:metric-sample-count
                #:metric-sample-sum
                #:metric-sample-buckets
                #:metric-sample-p
                #:+infinity+)
  (:export #:render-prometheus))

(defpackage #:observability-kit/otlp
  (:nicknames #:cl-observability-kit/otlp)
  (:use #:cl)
  (:import-from #:observability-kit
                #:observability-error
                #:metric
                #:metric-p
                #:metric-registry
                #:metric-registry-p
                #:metric-snapshot
                #:metric-snapshot-p
                #:metric-snapshot-name
                #:metric-snapshot-help
                #:metric-snapshot-type
                #:metric-snapshot-unit
                #:metric-snapshot-samples
                #:metric-sample-labels
                #:metric-sample-value
                #:metric-sample-count
                #:metric-sample-sum
                #:metric-sample-buckets
                #:metric-sample-p
                #:+infinity+)
  (:export #:metric-snapshot->otlp
           #:snapshot->otlp
           #:registry->otlp))

(defpackage #:observability-kit/log-kit
  (:nicknames #:cl-observability-kit/log-kit)
  (:use #:cl)
  (:import-from #:observability-kit
                #:instrumentation-context
                #:instrumentation-context-p
                #:instrumentation-context-trace-id
                #:instrumentation-context-span-id
                #:instrumentation-context-trace-flags
                #:instrumentation-context-attributes
                #:instrumentation-context-baggage)
  (:export #:instrumentation-context-log-fields
           #:with-log-kit-context
           #:call-with-log-kit-context))
