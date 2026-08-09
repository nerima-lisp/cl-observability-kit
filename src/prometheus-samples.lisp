#.(progn
    (in-package #:observability-kit/prometheus)
    nil)

(defun %write-labels (labels stream)
  (when labels
    (write-char #\{ stream)
    (loop for (name . value) in (%sorted-labels labels)
          for first-p = t then nil
          do (unless first-p (write-char #\, stream))
             (write-string name stream)
             (write-string "=\"" stream)
             (%write-escaped-string value stream)
             (write-char #\" stream))
    (write-char #\} stream))
  stream)

(defun %write-sample-line (name labels value stream)
  (write-string name stream)
  (%write-labels labels stream)
  (write-char #\Space stream)
  (write-string (%number-string value) stream)
  (terpri stream))

(defun %histogram-labels (labels boundary)
  (when (assoc "le" labels :test #'string=)
    (%export-error
     "Histogram labels cannot contain the reserved Prometheus label LE."))
  (acons "le"
         (if (eq boundary +infinity+)
             "+Inf"
             (%number-string boundary))
         (%sorted-labels labels)))
