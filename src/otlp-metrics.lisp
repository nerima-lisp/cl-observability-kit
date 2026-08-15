#.(progn
    (in-package #:observability-kit/otlp)
    nil)

(defun %snapshot-list (source)
  (cond
    ((metric-snapshot-p source) (list source))
    ((metric-p source) (list (metric-snapshot source)))
    ((metric-registry-p source) (metric-snapshot source))
    ((meter-provider-p source) (metric-snapshot source))
    ((null source) nil)
    ((proper-list-p source)
     (unless (every #'metric-snapshot-p source)
       (%otlp-error "OTLP source lists must contain metric snapshots."))
     (sort (copy-list source)
           #'string<
           :key #'observability-kit::%metric-snapshot-name))
    (t
      (%otlp-error
      "OTLP source must be a metric, registry, meter provider, snapshot, or snapshot list; got ~S."
      source))))

(defun %snapshot-resource (snapshots)
  (when snapshots
    (let ((resource (metric-snapshot-resource (first snapshots))))
      (dolist (snapshot (rest snapshots))
        (let ((candidate (metric-snapshot-resource snapshot)))
          (unless (equal (and resource (resource-attributes resource))
                         (and candidate (resource-attributes candidate)))
            (%otlp-error
             "OTLP metric sources must share one resource; use separate documents for different resources."))))
      resource)))

(defun %data-point (sample &key value count sum timestamp start-time)
  (let ((data-point
          (list (cons "attributes"
                      (%attributes
                       (observability-kit::%metric-sample-labels sample))))))
    (when (not (null value)) (push (cons "value" value) data-point))
    (when (not (null count)) (push (cons "count" count) data-point))
    (when (not (null sum)) (push (cons "sum" sum) data-point))
    (when (not (null timestamp)) (push (cons "timestamp" timestamp) data-point))
    (when (not (null start-time)) (push (cons "start-time" start-time) data-point))
    (nreverse data-point)))

(defun %histogram-components (buckets)
  (let ((previous 0) (bounds nil) (counts nil))
    (dolist (bucket buckets)
      (let ((boundary (car bucket)) (cumulative (cdr bucket)))
        (unless (eq boundary +infinity+) (push boundary bounds))
        (push (- cumulative previous) counts)
        (setf previous cumulative)))
    (values (nreverse bounds) (nreverse counts))))

(defun %histogram-data-point (sample)
  (multiple-value-bind (bounds counts)
      (%histogram-components (observability-kit::%metric-sample-buckets sample))
    (let ((data-point
            (list (cons "attributes"
                        (%attributes
                         (observability-kit::%metric-sample-labels sample))))))
      (push (cons "count" (observability-kit::%metric-sample-count sample)) data-point)
      (push (cons "sum" (observability-kit::%metric-sample-sum sample)) data-point)
      (let ((timestamp (observability-kit::%metric-sample-timestamp sample))
            (start-time (observability-kit::%metric-sample-start-time sample)))
        (when timestamp (push (cons "timestamp" timestamp) data-point))
        (when start-time (push (cons "start-time" start-time) data-point)))
      (push (cons "explicit-bounds" bounds) data-point)
      (push (cons "bucket-counts" counts) data-point)
      (nreverse data-point))))

(defun %metric-data (snapshot)
  (let ((type (observability-kit::%metric-snapshot-type snapshot))
        (samples (observability-kit::%metric-snapshot-samples snapshot)))
    (case type
      ((:counter :up-down-counter :observable-counter :observable-up-down-counter)
       (list (cons "type" "sum") (cons "aggregation-temporality" "cumulative")
             (cons "is-monotonic"
                   (not (null (member type '(:counter :observable-counter) :test #'eq))))
             (cons "data-points"
                   (mapcar (lambda (sample)
                             (%data-point sample :value (observability-kit::%metric-sample-value sample)
                                          :timestamp (observability-kit::%metric-sample-timestamp sample)
                                          :start-time (observability-kit::%metric-sample-start-time sample)))
                           samples))))
      ((:gauge :observable-gauge)
       (list (cons "type" "gauge")
             (cons "data-points"
                   (mapcar (lambda (sample)
                             (%data-point sample :value (observability-kit::%metric-sample-value sample)
                                          :timestamp (observability-kit::%metric-sample-timestamp sample)))
                           samples))))
      (:histogram
       (list (cons "type" "histogram") (cons "aggregation-temporality" "cumulative")
             (cons "data-points" (mapcar #'%histogram-data-point samples))))
      (otherwise (%otlp-error "Unsupported metric snapshot type ~S." type)))))

(defun metric-snapshot->otlp (snapshot)
  "Return one deterministic, transport-neutral OTLP-shaped metric alist."
  (unless (metric-snapshot-p snapshot)
    (%otlp-error "METRIC-SNAPSHOT->OTLP expects a metric snapshot; got ~S." snapshot))
  (append
   (list (cons "name" (observability-kit::%copy-observability-value
                       (observability-kit::%metric-snapshot-name snapshot)))
         (cons "description" (observability-kit::%copy-observability-value
                               (observability-kit::%metric-snapshot-help snapshot)))
         (cons "unit" (or (observability-kit::%copy-observability-value
                           (observability-kit::%metric-snapshot-unit snapshot)) "")))
   (%metric-data snapshot)))

(defun registry->otlp (source &key scope-name scope-version)
  "Return a deterministic OTLP-shaped scope document for SOURCE."
  (let* ((scope (remove nil (list (and scope-name (cons "name" scope-name))
                                  (and scope-version (cons "version" scope-version)))))
         (snapshots (%snapshot-list source))
         (resource (%snapshot-resource snapshots))
         (document (list (cons "scope" scope)
                         (cons "metrics" (mapcar #'metric-snapshot->otlp snapshots)))))
    (unless (every (lambda (pair) (stringp (cdr pair))) scope)
      (%otlp-error "OTLP scope metadata must contain string values."))
    (if resource (cons (cons "resource" (%resource-document resource)) document)
        document)))
