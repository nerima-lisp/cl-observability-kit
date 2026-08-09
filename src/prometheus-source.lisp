#.(progn
    (in-package #:observability-kit/prometheus)
    nil)

(defun %export-error (format-control &rest arguments)
  (error 'observability-error
         :message (apply #'format nil format-control arguments)))

(defun %snapshot-list (source)
  (let ((snapshots
          (cond
            ((metric-snapshot-p source) (list source))
            ((metric-p source) (list (metric-snapshot source)))
            ((metric-registry-p source) (metric-snapshot source))
            ((null source) nil)
            ((proper-list-p source)
             (unless (every #'metric-snapshot-p source)
               (%export-error
                "Prometheus source lists must contain metric snapshots."))
             (copy-list source))
            (t
             (%export-error
              "Prometheus source must be a metric, registry, snapshot, or snapshot list; got ~S."
              source)))))
    (let ((names (make-hash-table :test #'equal)))
      (dolist (snapshot snapshots)
        (when (gethash (metric-snapshot-name snapshot) names)
          (%export-error "Prometheus source contains duplicate metric ~S."
                         (metric-snapshot-name snapshot)))
        (setf (gethash (metric-snapshot-name snapshot) names) t))
      (sort snapshots #'string< :key #'metric-snapshot-name))))
