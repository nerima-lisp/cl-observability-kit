#.(progn
    (in-package #:observability-kit/prometheus)
    nil)

(defun %write-metric (snapshot stream)
  (let ((name (metric-snapshot-name snapshot)))
    (format stream "# HELP ~A ~A~%"
            name
            (%escaped-string (metric-snapshot-help snapshot)
                             :escape-help-p t))
    (format stream "# TYPE ~A ~(~A~)~%"
            name
            (metric-snapshot-type snapshot))
    (when (metric-snapshot-unit snapshot)
      (format stream "# UNIT ~A ~A~%"
              name
              (%escaped-string (metric-snapshot-unit snapshot)
                               :escape-help-p t)))
    (dolist (sample (metric-snapshot-samples snapshot))
      (unless (metric-sample-p sample)
        (%export-error "Metric ~S contains an invalid sample." name))
      (if (eq (metric-snapshot-type snapshot) :histogram)
          (progn
            (dolist (bucket (metric-sample-buckets sample))
              (%write-sample-line (concatenate 'string name "_bucket")
                                  (%histogram-labels
                                   (metric-sample-labels sample)
                                   (car bucket))
                                  (cdr bucket)
                                  stream))
            (%write-sample-line (concatenate 'string name "_sum")
                                (metric-sample-labels sample)
                                (metric-sample-sum sample)
                                stream)
            (%write-sample-line (concatenate 'string name "_count")
                                (metric-sample-labels sample)
                                (metric-sample-count sample)
                                stream))
          (%write-sample-line name
                              (metric-sample-labels sample)
                              (metric-sample-value sample)
                              stream)))))

(defun render-prometheus (source &key stream)
  "Render SOURCE as deterministic Prometheus text exposition.

SOURCE may be a metric, registry, metric snapshot, or list of snapshots.
The returned string is also written to STREAM when STREAM is non-NIL.  Core
metric values stay exact; only values that cannot be represented by a
Prometheus decimal literal are converted at this text boundary."
  (let ((text
          (with-output-to-string (output)
            (dolist (snapshot (%snapshot-list source))
              (%write-metric snapshot output)))))
    (when stream
      (write-string text stream))
    text))
