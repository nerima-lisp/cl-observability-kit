#.(progn
    (in-package #:observability-kit)
    nil)

(defun %normalize-metric-scope-value (value what)
  (when value
    (unless (stringp value)
      (error 'observability-error
             :message (format nil "~A must be a string." what)))
    (unless (plusp (length value))
      (error 'observability-error
             :message (format nil "~A must not be empty." what)))
    (%copy-observability-value value)))

(defun make-metric-registry (&rest option-list)
  "Create an independent registry of metrics.

Every metric definition has a finite cardinality limit.  A definition that
  does not specify one inherits DEFAULT-CARDINALITY-LIMIT."
  (let* ((options (%parse-keyword-options
                   option-list
                   '(:default-cardinality-limit :max-label-value-length
                     :scope-name :scope-version :scope-schema-url)
                   "MAKE-METRIC-REGISTRY"))
         (default-cardinality-limit
           (%option-value options :default-cardinality-limit 1000))
         (max-label-value-length
           (%option-value options :max-label-value-length 256))
         (scope-name
           (%normalize-metric-scope-value
            (%option-value options :scope-name nil)
            "Metric scope name"))
         (scope-version
           (%normalize-metric-scope-value
            (%option-value options :scope-version nil)
            "Metric scope version"))
         (scope-schema-url
           (%normalize-metric-scope-value
            (%option-value options :scope-schema-url nil)
            "Metric scope schema URL")))
    (%validate-positive-integer default-cardinality-limit
                                "Default cardinality limit")
    (%validate-positive-integer max-label-value-length
                                "Maximum label value length")
    (%make-metric-registry (cl-concurrent-kit:make-lock :name "observability-metrics")
                           (make-hash-table :test #'equal)
                           default-cardinality-limit
                           max-label-value-length
                           scope-name
                           scope-version
                           scope-schema-url)))

(defun metric-registry-metrics (registry)
  "Return REGISTRY's definitions sorted by metric name."
  (check-type registry metric-registry)
  (cl-concurrent-kit:with-lock-held ((%metric-registry-lock registry))
    (sort (loop for metric being the hash-values of (%metric-registry-metrics registry)
                collect metric)
          #'string<
          :key #'%metric-name)))

(defun metric-registry-scope-name (registry)
  (check-type registry metric-registry)
  (%copy-observability-value (%metric-registry-scope-name registry)))

(defun metric-registry-scope-version (registry)
  (check-type registry metric-registry)
  (%copy-observability-value (%metric-registry-scope-version registry)))

(defun metric-registry-scope-schema-url (registry)
  (check-type registry metric-registry)
  (%copy-observability-value (%metric-registry-scope-schema-url registry)))

(defun %insert-metric-series (series-order series)
  "Insert SERIES into the normalized label order used by snapshots."
  (let ((labels (%metric-series-labels series)))
    (if (or (null series-order)
            (%labels-less-p labels
                            (%metric-series-labels (first series-order))))
        (cons series series-order)
        (loop for tail on series-order
              for next = (cdr tail)
              when (or (null next)
                       (%labels-less-p
                        labels
                        (%metric-series-labels (car next))))
                do (setf (cdr tail) (cons series next))
                   (return series-order)))))

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

(defun up-down-counter-p (metric)
  (and (metric-p metric) (eq (%metric-kind metric) :up-down-counter)))

(defun observable-counter-p (metric)
  (and (metric-p metric) (eq (%metric-kind metric) :observable-counter)))

(defun observable-gauge-p (metric)
  (and (metric-p metric) (eq (%metric-kind metric) :observable-gauge)))

(defun observable-up-down-counter-p (metric)
  (and (metric-p metric)
       (eq (%metric-kind metric) :observable-up-down-counter)))

(defun gauge-p (metric)
  (and (metric-p metric) (eq (%metric-kind metric) :gauge)))

(defun histogram-p (metric)
  (and (metric-p metric) (eq (%metric-kind metric) :histogram)))
