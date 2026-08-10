#.(progn
    (in-package #:observability-kit)
    nil)

(defun %metric-temporality (metric)
  (when (member (%metric-kind metric)
                '(:counter :up-down-counter :observable-counter
                  :observable-up-down-counter :histogram)
                :test #'eq)
    :cumulative))

(defun %snapshot-series (metric series timestamp)
  (let ((histogram-p (histogram-p metric)))
    (%make-metric-sample
     (%copy-alist (%metric-series-labels series))
     (unless histogram-p
       (%metric-series-value series))
     (when histogram-p
       (%metric-series-count series))
     (when histogram-p
       (%metric-series-sum series))
     (when histogram-p
       (let ((count-cell (%metric-series-bucket-counts series))
             (samples nil))
         (dolist (boundary (%metric-histogram-buckets metric))
           (push (cons boundary (car count-cell)) samples)
           (setf count-cell (cdr count-cell)))
         (nreverse
          (cons (cons +infinity+ (car count-cell))
                samples))))
     timestamp
     (and (%metric-temporality metric)
          (%metric-start-time metric)))))

(defun %snapshot-metric (metric &optional resource)
  (let* ((timestamp (get-universal-time))
         (temporality (%metric-temporality metric))
         (start-time (and temporality (%metric-start-time metric))))
    (if (%observable-metric-kind-p (%metric-kind metric))
        (%snapshot-observable-metric metric resource timestamp)
        (cl-concurrent-kit:with-lock-held ((%metric-lock metric))
          ;; Series order is maintained when a series is created, so snapshots do
          ;; not repeatedly collect and sort the metric's hash-table values.
          (let ((series (%metric-series-order metric))
                (registry (%metric-registry metric)))
            (make-metric-snapshot
             :name (%copy-observability-value (%metric-name metric))
             :help (%copy-observability-value (%metric-help metric))
             :type (%metric-kind metric)
             :unit (%copy-observability-value (%metric-unit metric))
             :label-names (copy-list (%metric-label-names metric))
             :samples (mapcar (lambda (series)
                                (%snapshot-series metric series timestamp))
                              series)
             :resource (and resource
                            (make-resource
                             :attributes (resource-attributes resource)))
             :scope-name (%copy-observability-value
                          (%metric-registry-scope-name registry))
             :scope-version (%copy-observability-value
                             (%metric-registry-scope-version registry))
             :scope-schema-url (%copy-observability-value
                                (%metric-registry-scope-schema-url registry))
             :temporality temporality
             :timestamp timestamp
             :start-time start-time))))))

(defun %snapshot-observable-metric (metric &optional resource timestamp)
  (let ((series-table (make-hash-table :test #'equal))
        (series-order nil)
        (registry (%metric-registry metric))
        (snapshot-time (if (null timestamp) (get-universal-time) timestamp)))
    (flet ((observe (value &key labels)
             (%validate-operation-value metric :metric-observe value
                                        "Observable metric value")
             (when (and (observable-counter-p metric) (minusp value))
               (error 'metric-operation-error
                      :metric metric
                      :operation :metric-observe
                      :message "Observable counters cannot report negative values."))
             (let ((normalized-labels (%normalized-operation-labels metric labels)))
               (let ((series (gethash normalized-labels series-table)))
                 (unless series
                   (when (>= (hash-table-count series-table)
                             (%metric-cardinality-limit metric))
                     (error 'metric-cardinality-exceeded
                            :name (%metric-name metric)
                            :limit (%metric-cardinality-limit metric)
                            :labels normalized-labels
                            :message (format nil
                                             "Metric ~S exceeded its cardinality limit of ~D."
                                             (%metric-name metric)
                                             (%metric-cardinality-limit metric))))
                   (setf series (%empty-series (%metric-kind metric) nil
                                                normalized-labels)
                         (gethash normalized-labels series-table) series
                         series-order (%insert-metric-series series-order series)))
               (setf (%metric-series-value series) value)
               value))))
      (funcall (%metric-callback metric) #'observe))
    (make-metric-snapshot
     :name (%copy-observability-value (%metric-name metric))
     :help (%copy-observability-value (%metric-help metric))
     :type (%metric-kind metric)
     :unit (%copy-observability-value (%metric-unit metric))
     :label-names (copy-list (%metric-label-names metric))
     :samples (mapcar (lambda (series)
                        (%snapshot-series metric series snapshot-time))
                      series-order)
     :resource (and resource
                    (make-resource
                     :attributes (resource-attributes resource)))
     :scope-name (%copy-observability-value
                  (%metric-registry-scope-name registry))
     :scope-version (%copy-observability-value
                     (%metric-registry-scope-version registry))
     :scope-schema-url (%copy-observability-value
                        (%metric-registry-scope-schema-url registry))
     :temporality (%metric-temporality metric)
     :timestamp snapshot-time
     :start-time (and (%metric-temporality metric)
                      (%metric-start-time metric)))))

(defun %copy-metric-sample (sample)
  (if (metric-sample-p sample)
      (%make-metric-sample
       (%copy-alist (%metric-sample-labels sample))
       (%metric-sample-value sample)
       (%metric-sample-count sample)
       (%metric-sample-sum sample)
       (%copy-alist (%metric-sample-buckets sample))
       (%metric-sample-timestamp sample)
       (%metric-sample-start-time sample))
      sample))

(defun metric-snapshot-name (snapshot)
  (check-type snapshot metric-snapshot)
  (%copy-observability-value (%metric-snapshot-name snapshot)))

(defun metric-snapshot-help (snapshot)
  (check-type snapshot metric-snapshot)
  (%copy-observability-value (%metric-snapshot-help snapshot)))

(defun metric-snapshot-type (snapshot)
  (check-type snapshot metric-snapshot)
  (%metric-snapshot-type snapshot))

(defun metric-snapshot-unit (snapshot)
  (check-type snapshot metric-snapshot)
  (%copy-observability-value (%metric-snapshot-unit snapshot)))

(defun metric-snapshot-label-names (snapshot)
  (check-type snapshot metric-snapshot)
  (mapcar #'%copy-observability-value
          (%metric-snapshot-label-names snapshot)))

(defun metric-snapshot-samples (snapshot)
  (check-type snapshot metric-snapshot)
  (mapcar #'%copy-metric-sample (%metric-snapshot-samples snapshot)))

(defun metric-snapshot-resource (snapshot)
  (check-type snapshot metric-snapshot)
  (let ((resource (%metric-snapshot-resource snapshot)))
    (and resource
         (make-resource :attributes (resource-attributes resource)))))

(defun metric-snapshot-scope-name (snapshot)
  (check-type snapshot metric-snapshot)
  (%copy-observability-value (%metric-snapshot-scope-name snapshot)))

(defun metric-snapshot-scope-version (snapshot)
  (check-type snapshot metric-snapshot)
  (%copy-observability-value (%metric-snapshot-scope-version snapshot)))

(defun metric-snapshot-scope-schema-url (snapshot)
  (check-type snapshot metric-snapshot)
  (%copy-observability-value (%metric-snapshot-scope-schema-url snapshot)))

(defun metric-snapshot-temporality (snapshot)
  (check-type snapshot metric-snapshot)
  (%metric-snapshot-temporality snapshot))

(defun metric-snapshot-timestamp (snapshot)
  (check-type snapshot metric-snapshot)
  (%metric-snapshot-timestamp snapshot))

(defun metric-snapshot-start-time (snapshot)
  (check-type snapshot metric-snapshot)
  (%metric-snapshot-start-time snapshot))

(defun metric-sample-labels (sample)
  (check-type sample metric-sample)
  (%copy-alist (%metric-sample-labels sample)))

(defun metric-sample-value (sample)
  (check-type sample metric-sample)
  (%metric-sample-value sample))

(defun metric-sample-count (sample)
  (check-type sample metric-sample)
  (%metric-sample-count sample))

(defun metric-sample-sum (sample)
  (check-type sample metric-sample)
  (%metric-sample-sum sample))

(defun metric-sample-buckets (sample)
  (check-type sample metric-sample)
  (%copy-alist (%metric-sample-buckets sample)))

(defun metric-sample-timestamp (sample)
  (check-type sample metric-sample)
  (%metric-sample-timestamp sample))

(defun metric-sample-start-time (sample)
  (check-type sample metric-sample)
  (%metric-sample-start-time sample))

(defun metric-snapshot (object)
  "Return a deterministic snapshot of one metric source.

Registry snapshots are ordered by metric name.  Samples are ordered by their
normalized label pairs, and all returned strings and lists are detached copies."
  (cond
    ((metric-p object)
     (%snapshot-metric object))
    ((metric-registry-p object)
     (mapcar #'%snapshot-metric (metric-registry-metrics object)))
    ((meter-p object)
     (mapcar (lambda (metric)
               (%snapshot-metric
                metric
                (meter-provider-resource (%meter-provider object))))
             (metric-registry-metrics (%meter-registry object))))
    ((meter-provider-p object)
     (let (meters resource)
       (cl-concurrent-kit:with-lock-held ((%meter-provider-lock object))
         (setf meters
               (sort (loop for meter being the hash-values of
                                     (%meter-provider-meters object)
                           collect meter)
                     (lambda (left right)
                       (or (string< (%meter-name left) (%meter-name right))
                           (and (string= (%meter-name left) (%meter-name right))
                                (string< (or (%meter-version left) "")
                                         (or (%meter-version right) ""))))))
               resource
               (make-resource
                :attributes
                (resource-attributes (%meter-provider-resource object)))))
       (mapcan (lambda (meter)
                 (mapcar (lambda (metric)
                           (%snapshot-metric
                            metric
                            resource))
                         (metric-registry-metrics (%meter-registry meter))))
               meters)))
    (t
     (error 'type-error
            :datum object
            :expected-type '(or metric metric-registry meter meter-provider)))))
