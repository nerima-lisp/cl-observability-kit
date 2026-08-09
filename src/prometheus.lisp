#.(progn
    (in-package #:observability-kit/prometheus)
    nil)

(defun %write-metric (snapshot stream)
  (let* ((name (observability-kit::%metric-snapshot-name snapshot))
         (help (observability-kit::%metric-snapshot-help snapshot))
         (type (observability-kit::%metric-snapshot-type snapshot))
         (unit (observability-kit::%metric-snapshot-unit snapshot))
         (histogram-p (eq type :histogram))
         (type-name (case type
                      (:counter "counter")
                      (:gauge "gauge")
                      (:histogram "histogram")
                      (otherwise (string-downcase (symbol-name type))))))
    (write-string "# HELP " stream)
    (write-string name stream)
    (write-char #\Space stream)
    (%write-escaped-string help stream :escape-help-p t)
    (terpri stream)
    (write-string "# TYPE " stream)
    (write-string name stream)
    (write-char #\Space stream)
    (write-string type-name stream)
    (terpri stream)
    (when unit
      (write-string "# UNIT " stream)
      (write-string name stream)
      (write-char #\Space stream)
      (%write-escaped-string unit stream :escape-help-p t)
      (terpri stream))
    (dolist (sample (observability-kit::%metric-snapshot-samples snapshot))
      (unless (metric-sample-p sample)
        (%export-error "Metric ~S contains an invalid sample." name))
      (let ((labels (%sorted-labels
                     (observability-kit::%metric-sample-labels sample))))
        (if histogram-p
            (progn
              (let ((buckets (observability-kit::%metric-sample-buckets sample)))
                (when buckets
                  (let ((bucket (first buckets)))
                    (%write-histogram-sample-line name
                                                   labels
                                                   (car bucket)
                                                   (cdr bucket)
                                                   stream
                                                   :name-suffix "_bucket")
                    (dolist (bucket (rest buckets))
                      (%write-histogram-sample-line name
                                                     labels
                                                     (car bucket)
                                                     (cdr bucket)
                                                     stream
                                                     :name-suffix "_bucket"
                                                     :labels-le-validated-p t)))))
              (%write-sample-line name
                                  labels
                                  (observability-kit::%metric-sample-sum sample)
                                  stream
                                  :labels-sorted-p t
                                  :name-suffix "_sum")
              (%write-sample-line name
                                  labels
                                  (observability-kit::%metric-sample-count sample)
                                  stream
                                  :labels-sorted-p t
                                  :name-suffix "_count"))
            (%write-sample-line name
                                labels
                                (observability-kit::%metric-sample-value sample)
                                stream
                                :labels-sorted-p t))))))

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
