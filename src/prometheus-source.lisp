#.(progn
    (in-package #:observability-kit/prometheus)
    nil)

(defun %export-error (format-control &rest arguments)
  (error 'observability-error
         :message (apply #'format nil format-control arguments)))

(defun %snapshot-list (source)
  (cond
    ;; A single snapshot, metric, or registry is already deterministic.  In
    ;; particular, METRIC-SNAPSHOT on a registry returns metrics in name order.
    ((metric-snapshot-p source) (list source))
    ((metric-p source) (list (metric-snapshot source)))
    ((metric-registry-p source) (metric-snapshot source))
    ((null source) nil)
    ((proper-list-p source)
     (unless (every #'metric-snapshot-p source)
       (%export-error
        "Prometheus source lists must contain metric snapshots."))
     (let ((snapshots (copy-list source))
           (names (make-hash-table :test #'equal)))
       (dolist (snapshot snapshots)
         (let ((name (observability-kit::%metric-snapshot-name snapshot)))
           (when (gethash name names)
             (%export-error "Prometheus source contains duplicate metric ~S."
                            name))
           (setf (gethash name names) t)))
       (sort snapshots #'string<
             :key #'observability-kit::%metric-snapshot-name)))
    (t
     (%export-error
      "Prometheus source must be a metric, registry, snapshot, or snapshot list; got ~S."
      source))))
