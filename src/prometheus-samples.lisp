#.(progn
    (in-package #:observability-kit/prometheus)
    nil)

(defun %write-labels (labels stream &key labels-sorted-p)
  (when labels
    (write-char #\{ stream)
    (loop for (name . value) in (if labels-sorted-p
                                   labels
                                   (%sorted-labels labels))
          for first-p = t then nil
          do (unless first-p (write-char #\, stream))
             (write-string name stream)
             (write-string "=\"" stream)
             (%write-escaped-string value stream)
             (write-char #\" stream))
    (write-char #\} stream))
  stream)

(defun %write-sample-line (name labels value stream
                           &key labels-sorted-p name-suffix)
  (write-string name stream)
  (when name-suffix
    (write-string name-suffix stream))
  (%write-labels labels stream :labels-sorted-p labels-sorted-p)
  (write-char #\Space stream)
  (%write-number value stream)
  (terpri stream))

(defun %write-histogram-sample-line (name labels boundary value stream
                                     &key labels-le-validated-p name-suffix)
  (unless labels-le-validated-p
    (when (assoc "le" labels :test #'string=)
      (%export-error
       "Histogram labels cannot contain the reserved Prometheus label LE.")))
  (write-string name stream)
  (when name-suffix
    (write-string name-suffix stream))
  (write-char #\{ stream)
  (let ((first-p t)
        (inserted-p nil))
    (dolist (label labels)
      (when (and (not inserted-p)
                 (string< "le" (car label)))
        (unless first-p
          (write-char #\, stream))
        (write-string "le=\"" stream)
        (%write-number boundary stream)
        (write-char #\" stream)
        (setf inserted-p t
              first-p nil))
      (unless first-p
        (write-char #\, stream))
      (write-string (car label) stream)
      (write-string "=\"" stream)
      (%write-escaped-string (cdr label) stream)
      (write-char #\" stream)
      (setf first-p nil))
    (unless inserted-p
      (unless first-p
        (write-char #\, stream))
      (write-string "le=\"" stream)
      (%write-number boundary stream)
      (write-char #\" stream)))
  (write-char #\} stream)
  (write-char #\Space stream)
  (%write-number value stream)
  (terpri stream))

(defun %histogram-labels (labels boundary &key labels-sorted-p)
  (when (assoc "le" labels :test #'string=)
    (%export-error
     "Histogram labels cannot contain the reserved Prometheus label LE."))
  (let ((histogram-label
          (cons "le"
                (if (eq boundary +infinity+)
                    "+Inf"
                    (%number-string boundary))))
        (sorted-labels (if labels-sorted-p
                           labels
                           (%sorted-labels labels)))
        (result nil)
        (inserted-p nil))
    (dolist (label sorted-labels)
      (when (and (not inserted-p)
                 (string< "le" (car label)))
        (push histogram-label result)
        (setf inserted-p t))
      (push label result))
    (unless inserted-p
      (push histogram-label result))
    (nreverse result)))
