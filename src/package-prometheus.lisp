#.(progn
    (in-package #:cl-user)
    nil)

(defpackage #:observability-kit/prometheus
  (:nicknames #:cl-observability-kit/prometheus)
  (:use #:cl)
  (:import-from #:observability-kit
                #:observability-error
                #:metric
                #:metric-p
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
  (:export #:render-prometheus))
