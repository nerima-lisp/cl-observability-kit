(defun %snapshot-series (metric series)
  (%make-metric-sample
   (%copy-alist (%metric-series-labels series))
   (unless (histogram-p metric)
     (%metric-series-value series))
   (when (histogram-p metric)
     (%metric-series-count series))
   (when (histogram-p metric)
     (%metric-series-sum series))
   (when (histogram-p metric)
     (loop for boundary in (append (%metric-histogram-buckets metric)
                                   (list +infinity+))
           for count in (%metric-series-bucket-counts series)
            collect (cons boundary count)))))

(defun %snapshot-metric (metric)
  (cl-concurrent-kit:with-lock-held ((%metric-lock metric))
    (let ((series (sort (loop for series being the hash-values of (%metric-series metric)
                              collect series)
                        #'%labels-less-p
                        :key #'%metric-series-labels)))
      (make-metric-snapshot
       :name (%copy-observability-value (%metric-name metric))
       :help (%copy-observability-value (%metric-help metric))
       :type (%metric-kind metric)
       :unit (%copy-observability-value (%metric-unit metric))
       :label-names (copy-list (%metric-label-names metric))
       :samples (mapcar (lambda (series)
                          (%snapshot-series metric series))
                        series)))))

(defun %copy-metric-sample (sample)
  (if (metric-sample-p sample)
      (%make-metric-sample
       (%copy-alist (%metric-sample-labels sample))
       (%metric-sample-value sample)
       (%metric-sample-count sample)
       (%metric-sample-sum sample)
       (%copy-alist (%metric-sample-buckets sample)))
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

(defun metric-snapshot (object)
  "Return a deterministic snapshot of one METRIC or every registry metric.

Registry snapshots are ordered by metric name.  Samples are ordered by their
normalized label pairs, and all returned strings and lists are detached copies."
  (cond
    ((metric-p object)
     (%snapshot-metric object))
    ((metric-registry-p object)
     (mapcar #'%snapshot-metric (metric-registry-metrics object)))
    (t
     (error 'type-error :datum object :expected-type '(or metric metric-registry)))))
