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

(defun %get-or-create-series (metric labels)
  (cl-concurrent-kit:with-lock-held ((%metric-lock metric))
    (or (gethash labels (%metric-series metric))
        (when (>= (hash-table-count (%metric-series metric))
                  (%metric-cardinality-limit metric))
          (error 'metric-cardinality-exceeded
                 :name (%metric-name metric)
                 :limit (%metric-cardinality-limit metric)
                 :message (format nil
                                  "Metric ~S exceeded its cardinality limit of ~D."
                                  (%metric-name metric)
                                  (%metric-cardinality-limit metric))))
        (setf (gethash labels (%metric-series metric))
              (%empty-series (%metric-kind metric)
                             (%metric-histogram-buckets metric)
                             labels)))))

(defun %normalized-operation-labels (metric labels)
  (%normalize-labels (%metric-label-names metric)
                     labels
                     (%metric-registry-max-label-value-length
                      (%metric-registry metric))))

(defun %validate-operation-value (metric operation value what)
  (handler-case
      (%validate-finite-real value what)
    (observability-error (condition)
      (error 'metric-operation-error
             :metric metric
             :operation operation
             :message (observability-error-message condition)))))

(defun %with-series (metric labels function)
  (let ((series (%get-or-create-series metric labels)))
    (cl-concurrent-kit:with-lock-held ((%metric-lock metric))
      (funcall function series))))

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
      (unless (or (counter-p metric) (gauge-p metric))
        (error 'metric-operation-error
               :metric metric
               :operation :metric-inc
               :message "Metric-inc requires a counter or gauge."))
      (%validate-operation-value metric :metric-inc amount "Metric increment")
      (when (and (counter-p metric) (minusp amount))
        (error 'metric-operation-error
               :metric metric
               :operation :metric-inc
               :message "Counters cannot be decremented."))
      (let ((normalized-labels (%normalized-operation-labels metric labels)))
        (%with-series metric normalized-labels
                      (lambda (series)
                        (incf (%metric-series-value series) amount)
                        (%metric-series-value series)))))))

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
    (%with-series metric normalized-labels
                  (lambda (series)
                    (setf (%metric-series-value series) value)
                    value))))

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
    (%with-series metric normalized-labels
                  (lambda (series)
                    (incf (%metric-series-count series))
                    (incf (%metric-series-sum series) observation)
                    (loop for bucket in (%metric-histogram-buckets metric)
                          for index from 0
                          when (<= observation bucket)
                            do (incf (nth index (%metric-series-bucket-counts series))))
                    (incf (car (last (%metric-series-bucket-counts series))))
                    observation))))
