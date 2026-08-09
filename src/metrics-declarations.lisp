(defparameter *default-histogram-buckets*
  '(0.005d0 0.01d0 0.025d0 0.05d0 0.1d0 0.25d0 0.5d0 1.0d0
    2.5d0 5.0d0 10.0d0)
  "The default upper bounds used by DEFINE-HISTOGRAM.")

(defstruct (metric-registry
            (:constructor %make-metric-registry
                (lock metrics default-cardinality-limit max-label-value-length))
            (:conc-name %metric-registry-))
  lock
  metrics
  default-cardinality-limit
  max-label-value-length)

(defstruct (metric
            (:constructor %make-metric
                (kind registry name help unit label-names cardinality-limit
                 series lock histogram-buckets))
            (:conc-name %metric-))
  kind
  registry
  name
  help
  unit
  label-names
  cardinality-limit
  series
  lock
  histogram-buckets)

(defstruct (metric-series
            (:constructor %make-metric-series (labels value count sum bucket-counts))
            (:conc-name %metric-series-))
  labels
  (value 0)
  (count 0)
  (sum 0)
  bucket-counts)

(defstruct (metric-snapshot
            (:conc-name %metric-snapshot-))
  name
  help
  type
  unit
  label-names
  samples)

(defstruct (metric-sample
            (:constructor %make-metric-sample
                (labels value count sum buckets))
            (:conc-name %metric-sample-))
  labels
  value
  count
  sum
  buckets)

(defparameter +infinity+ :infinity
  "The exact upper-bound marker for a histogram's final bucket.")
