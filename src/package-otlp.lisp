#.(progn
    (in-package #:cl-user)
    nil)

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
                #:proper-list-p
                #:+infinity+)
  (:export #:metric-snapshot->otlp
           #:snapshot->otlp
           #:registry->otlp))
