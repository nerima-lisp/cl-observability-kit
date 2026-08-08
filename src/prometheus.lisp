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
            ((observability-kit::%proper-list-p source)
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

(defun %sorted-labels (labels)
  (sort (copy-list labels)
        (lambda (left right)
          (or (string< (car left) (car right))
              (and (string= (car left) (car right))
                   (string< (cdr left) (cdr right)))))))

(defun %write-escaped-string (string stream &key escape-help-p)
  (loop for character across string
        do (cond
             ((char= character #\\)
              (write-char #\\ stream)
              (write-char #\\ stream))
             ((and (not escape-help-p) (char= character #\"))
              (write-char #\\ stream)
              (write-char #\" stream))
             ((char= character #\Newline)
              (write-char #\\ stream)
              (write-char #\n stream))
             ((char= character #\Return)
              (write-char #\\ stream)
              (write-char #\r stream))
             (t
              (write-char character stream))))
  stream)

(defun %escaped-string (string &key escape-help-p)
  (with-output-to-string (stream)
    (%write-escaped-string string stream :escape-help-p escape-help-p)))

(defun %factor-count (number factor)
  (let ((count 0))
    (loop while (zerop (mod number factor))
          do (incf count)
             (setf number (/ number factor)))
    (values count number)))

(defun %terminating-rational-string (value)
  (let* ((negative (minusp value))
         (numerator (abs (numerator value)))
         (denominator (denominator value)))
    (multiple-value-bind (twos remaining-after-twos)
        (%factor-count denominator 2)
      (multiple-value-bind (fives remaining)
          (%factor-count remaining-after-twos 5)
        (when (= remaining 1)
          (let* ((scale (max twos fives))
                 (scaled (* numerator
                            (expt 2 (- scale twos))
                            (expt 5 (- scale fives))))
                 (digits (princ-to-string scaled))
                 (sign (if negative "-" "")))
            (let ((split (- (length digits) scale)))
              (if (plusp split)
                  (concatenate 'string sign
                               (subseq digits 0 split)
                               "."
                               (subseq digits split))
                  (concatenate 'string sign
                               "0."
                               (make-string (- split)
                                            :initial-element #\0)
                               digits)))))))))

(defun %normalize-float-number (string)
  (let ((trimmed (string-trim '(#\Space #\Tab #\Newline #\Return)
                              string)))
    (with-output-to-string (stream)
      (loop for character across trimmed
            do (write-char (if (member character '(#\d #\D))
                               #\e
                               character)
                            stream)))))

(defun %number-string (value)
  (cond
    ((eq value +infinity+) "+Inf")
    ((integerp value) (princ-to-string value))
    ((rationalp value)
     (or (%terminating-rational-string value)
         ;; Prometheus has no rational literal.  The conversion is confined
         ;; to this text boundary; the core snapshot remains exact.
         (%normalize-float-number
          (format nil "~,17G" (coerce value 'double-float)))))
    ((floatp value)
     (%normalize-float-number (format nil "~,17G" value)))
    (t
     (%export-error "Metric value ~S is not a supported real number." value))))

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
