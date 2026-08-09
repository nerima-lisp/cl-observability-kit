#.(progn
    (in-package #:observability-kit/otlp)
    nil)

(defun %otlp-error (format-control &rest arguments)
  (error 'observability-error
         :message (apply #'format nil format-control arguments)))

(defun %snapshot-list (source)
  (cond
    ((metric-snapshot-p source) (list source))
    ((metric-p source) (list (metric-snapshot source)))
    ((metric-registry-p source) (metric-snapshot source))
    ((null source) nil)
    ((proper-list-p source)
     (unless (every #'metric-snapshot-p source)
       (%otlp-error "OTLP source lists must contain metric snapshots."))
     (sort (copy-list source) #'string< :key #'metric-snapshot-name))
    (t
     (%otlp-error
      "OTLP source must be a metric, registry, snapshot, or snapshot list; got ~S."
      source))))

(defun %attributes (labels)
  (mapcar (lambda (pair)
            (list (cons "key" (car pair))
                  (cons "value" (cdr pair))))
          labels))

(defun %data-point (sample &key value count sum)
  (append (list (cons "attributes" (%attributes (metric-sample-labels sample))))
          (unless (null value) (list (cons "value" value)))
          (unless (null count) (list (cons "count" count)))
          (unless (null sum) (list (cons "sum" sum)))))

(defun %histogram-counts (buckets)
  (let ((previous 0))
    (mapcar (lambda (bucket)
              (prog1 (- (cdr bucket) previous)
                (setf previous (cdr bucket))))
            buckets)))

(defun %histogram-data-point (sample)
  (let* ((buckets (metric-sample-buckets sample))
         (finite-buckets
           (remove-if (lambda (bucket)
                        (eq (car bucket) +infinity+))
                      buckets)))
    (append
     (list (cons "attributes" (%attributes (metric-sample-labels sample))))
     (list (cons "count" (metric-sample-count sample)))
     (list (cons "sum" (metric-sample-sum sample)))
     (list (cons "explicit-bounds" (mapcar #'car finite-buckets)))
     (list (cons "bucket-counts" (%histogram-counts buckets))))))

(defun %metric-data (snapshot)
  (case (metric-snapshot-type snapshot)
    (:counter
     (list (cons "type" "sum")
           (cons "aggregation-temporality" "cumulative")
           (cons "is-monotonic" t)
           (cons "data-points"
                 (mapcar (lambda (sample)
                           (%data-point sample
                                        :value (metric-sample-value sample)))
                         (metric-snapshot-samples snapshot)))))
    (:gauge
     (list (cons "type" "gauge")
           (cons "data-points"
                 (mapcar (lambda (sample)
                           (%data-point sample
                                        :value (metric-sample-value sample)))
                         (metric-snapshot-samples snapshot)))))
    (:histogram
     (list (cons "type" "histogram")
           (cons "aggregation-temporality" "cumulative")
           (cons "data-points"
                 (mapcar #'%histogram-data-point
                         (metric-snapshot-samples snapshot)))))
    (otherwise
     (%otlp-error "Unsupported metric snapshot type ~S."
                  (metric-snapshot-type snapshot)))))

(defun metric-snapshot->otlp (snapshot)
  "Return one deterministic, transport-neutral OTLP-shaped metric alist.

The returned Common Lisp numbers are the exact values from SNAPSHOT.  This
function deliberately does not serialize JSON or coerce rationals to
double-floats; a transport adapter can choose the wire representation at its
boundary.  HISTOGRAM bucket counts are converted from the cumulative counts
used by the core snapshot to OTLP's per-bucket counts."
  (check-type snapshot metric-snapshot)
  (append (list (cons "name" (metric-snapshot-name snapshot))
                (cons "description" (metric-snapshot-help snapshot))
                (cons "unit" (or (metric-snapshot-unit snapshot) "")))
          (%metric-data snapshot)))

(defun snapshot->otlp (source)
  "Alias for METRIC-SNAPSHOT->OTLP accepting a metric or snapshot source."
  (cond
    ((metric-snapshot-p source) (metric-snapshot->otlp source))
    ((metric-p source) (metric-snapshot->otlp (metric-snapshot source)))
    (t
     (%otlp-error "SNAPSHOT->OTLP expects a metric snapshot or metric; got ~S."
                  source))))

(defun registry->otlp (source &key scope-name scope-version)
  "Return a deterministic OTLP-shaped scope document for SOURCE.

SOURCE may be a registry, metric, snapshot, or snapshot list.  SCOPE-NAME and
SCOPE-VERSION are metadata only; resource ownership and network export remain
with the application or another optional integration."
  (let ((scope
          (remove nil
                  (list (and scope-name (cons "name" scope-name))
                        (and scope-version (cons "version" scope-version))))))
    (unless (every (lambda (pair) (stringp (cdr pair)))
                   scope)
      (%otlp-error "OTLP scope metadata must contain string values."))
    (list (cons "scope" scope)
          (cons "metrics"
                (mapcar #'metric-snapshot->otlp (%snapshot-list source))))))
