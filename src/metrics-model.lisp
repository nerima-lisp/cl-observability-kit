(defun make-metric-registry (&rest option-list)
  "Create an independent registry of metrics.

Every metric definition has a finite cardinality limit.  A definition that
does not specify one inherits DEFAULT-CARDINALITY-LIMIT."
  (let* ((options (%parse-keyword-options
                   option-list
                   '(:default-cardinality-limit :max-label-value-length)
                   "MAKE-METRIC-REGISTRY"))
         (default-cardinality-limit
           (%option-value options :default-cardinality-limit 1000))
         (max-label-value-length
           (%option-value options :max-label-value-length 256)))
    (%validate-positive-integer default-cardinality-limit
                                "Default cardinality limit")
    (%validate-positive-integer max-label-value-length
                                "Maximum label value length")
    (%make-metric-registry (cl-concurrent-kit:make-lock :name "observability-metrics")
                           (make-hash-table :test #'equal)
                           default-cardinality-limit
                           max-label-value-length)))

(defun metric-registry-metrics (registry)
  "Return REGISTRY's definitions sorted by metric name."
  (check-type registry metric-registry)
  (cl-concurrent-kit:with-lock-held ((%metric-registry-lock registry))
    (sort (loop for metric being the hash-values of (%metric-registry-metrics registry)
                collect metric)
          #'string<
          :key #'%metric-name)))

(defun metric-name (metric)
  (check-type metric metric)
  (%copy-observability-value (%metric-name metric)))

(defun metric-help (metric)
  (check-type metric metric)
  (%copy-observability-value (%metric-help metric)))

(defun metric-unit (metric)
  (check-type metric metric)
  (%copy-observability-value (%metric-unit metric)))

(defun metric-label-names (metric)
  (check-type metric metric)
  (copy-list (%metric-label-names metric)))

(defun metric-kind (metric)
  (check-type metric metric)
  (%metric-kind metric))

(defun counter-p (metric)
  (and (metric-p metric) (eq (%metric-kind metric) :counter)))

(defun gauge-p (metric)
  (and (metric-p metric) (eq (%metric-kind metric) :gauge)))

(defun histogram-p (metric)
  (and (metric-p metric) (eq (%metric-kind metric) :histogram)))
