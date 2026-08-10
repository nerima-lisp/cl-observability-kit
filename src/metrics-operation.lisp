#.(progn
    (in-package #:observability-kit)
    nil)

(defun %operation-labels (arguments)
  (let ((labels nil)
        (labels-supplied-p nil)
        (remaining arguments))
    (loop while remaining
          do (let ((key (pop remaining)))
               (unless (eq key :labels)
                 (error 'metric-operation-error
                        :operation :metric-inc
                        :message (format nil "Unknown metric-inc option ~S." key)))
               (when labels-supplied-p
                 (error 'metric-operation-error
                        :operation :metric-inc
                        :message "Metric-inc labels were supplied more than once."))
               (unless remaining
                 (error 'metric-operation-error
                        :operation :metric-inc
                        :message "Metric-inc :labels requires a value."))
               (setf labels (pop remaining)
                     labels-supplied-p t)))
    (values labels labels-supplied-p)))

(defun %normalized-operation-labels (metric labels)
  (if (and (null labels)
           (null (%metric-label-names metric)))
      nil
      (%normalize-labels (%metric-label-names metric)
                         labels
                         (%metric-registry-max-label-value-length
                          (%metric-registry metric)))))

(defun %validate-operation-value (metric operation value what)
  (handler-case
      (%validate-finite-real value what)
    (observability-error (condition)
      (error 'metric-operation-error
             :metric metric
             :operation operation
             :message (observability-error-message condition)))))

(defun metric-inc (metric &rest arguments)
  "Increment a counter or gauge by an exact finite real amount.

The optional positional amount defaults to one.  The only option is
:LABELS, whose value must contain every label declared by the metric."
  (check-type metric metric)
  (let ((amount 1)
        (remaining arguments))
    (when (and remaining (not (keywordp (first remaining))))
      (setf amount (pop remaining)))
    (multiple-value-bind (labels labels-supplied-p)
        (%operation-labels remaining)
      (declare (ignore labels-supplied-p))
      (unless (or (counter-p metric) (up-down-counter-p metric) (gauge-p metric))
        (error 'metric-operation-error
               :metric metric
               :operation :metric-inc
               :message "Metric-inc requires a counter, up-down counter, or gauge."))
      (%validate-operation-value metric :metric-inc amount "Metric increment")
      (when (and (counter-p metric) (minusp amount))
        (error 'metric-operation-error
               :metric metric
               :operation :metric-inc
               :message "Counters cannot be decremented."))
      (let ((normalized-labels (%normalized-operation-labels metric labels)))
        (%with-metric-series (series metric normalized-labels)
          (incf (%metric-series-value series) amount)
          (%metric-series-value series))))))

(defun metric-set (metric value &key labels)
  "Set a gauge to the exact finite real VALUE for LABELS."
  (check-type metric metric)
  (unless (gauge-p metric)
    (error 'metric-operation-error
           :metric metric
           :operation :metric-set
           :message "Metric-set requires a gauge."))
  (%validate-operation-value metric :metric-set value "Gauge value")
  (let ((normalized-labels (%normalized-operation-labels metric labels)))
    (%with-metric-series (series metric normalized-labels)
      (setf (%metric-series-value series) value)
      value)))

(defun metric-observe (metric observation &key labels)
  "Record an exact finite real OBSERVATION in a histogram for LABELS."
  (check-type metric metric)
  (unless (histogram-p metric)
    (error 'metric-operation-error
           :metric metric
           :operation :metric-observe
           :message "Metric-observe requires a histogram."))
  (%validate-operation-value metric :metric-observe observation
                             "Histogram observation")
  (let ((normalized-labels (%normalized-operation-labels metric labels)))
    (%with-metric-series (series metric normalized-labels)
      (incf (%metric-series-count series))
      (incf (%metric-series-sum series) observation)
      (let* ((buckets (%metric-histogram-buckets metric))
             (counts (%metric-series-bucket-counts series)))
        (let ((count-cell counts))
          (dolist (bucket buckets)
            (when (<= observation bucket)
              (incf (car count-cell)))
            (setf count-cell (cdr count-cell)))
          (incf (car count-cell))))
      observation)))
