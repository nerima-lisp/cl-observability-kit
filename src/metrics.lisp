(in-package #:observability-kit)

(defparameter *default-histogram-buckets*
  '(0.005d0 0.01d0 0.025d0 0.05d0 0.1d0 0.25d0 0.5d0 1.0d0
    2.5d0 5.0d0 10.0d0)
  "The default upper bounds used by DEFINE-HISTOGRAM.")

(defstruct (metric-registry
            (:constructor %make-metric-registry
                (lock metrics default-cardinality-limit max-label-value-length))
            (:conc-name %metric-registry-))
  lock
  metrics
  default-cardinality-limit
  max-label-value-length)

(defstruct (metric
            (:constructor %make-metric
                (kind registry name help unit label-names cardinality-limit
                 series lock histogram-buckets))
            (:conc-name %metric-))
  kind
  registry
  name
  help
  unit
  label-names
  cardinality-limit
  series
  lock
  histogram-buckets)

(defstruct (metric-series
            (:constructor %make-metric-series (labels value count sum bucket-counts))
            (:conc-name %metric-series-))
  labels
  (value 0)
  (count 0)
  (sum 0)
  bucket-counts)

(defstruct metric-snapshot
  name
  help
  type
  unit
  label-names
  samples)

(defstruct metric-sample
  labels
  value
  count
  sum
  buckets)

(defparameter +infinity+ :infinity
  "The exact upper-bound marker for a histogram's final bucket.")

(defun make-metric-registry (&key (default-cardinality-limit 1000)
                                  (max-label-value-length 256))
  "Create an independent registry of metrics.

Every metric definition has a finite cardinality limit.  A definition that
does not specify one inherits DEFAULT-CARDINALITY-LIMIT."
  (%validate-positive-integer default-cardinality-limit
                              "Default cardinality limit")
  (%validate-positive-integer max-label-value-length
                              "Maximum label value length")
  (%make-metric-registry (cl-concurrent-kit:make-lock :name "observability-metrics")
                         (make-hash-table :test #'equal)
                         default-cardinality-limit
                         max-label-value-length))

(defun metric-registry-metrics (registry)
  "Return REGISTRY's definitions sorted by metric name."
  (check-type registry metric-registry)
  (cl-concurrent-kit:with-lock-held ((%metric-registry-lock registry))
    (sort (loop for metric being the hash-values of (%metric-registry-metrics registry)
                collect metric)
          #'string<
          :key #'%metric-name)))

(defun metric-name (metric)
  (%copy-observability-value (%metric-name metric)))

(defun metric-help (metric)
  (%copy-observability-value (%metric-help metric)))

(defun metric-unit (metric)
  (%copy-observability-value (%metric-unit metric)))

(defun metric-label-names (metric)
  (mapcar #'%copy-observability-value (%metric-label-names metric)))

(defun metric-kind (metric)
  (%metric-kind metric))

(defun counter-p (metric)
  (and (metric-p metric) (eq (%metric-kind metric) :counter)))

(defun gauge-p (metric)
  (and (metric-p metric) (eq (%metric-kind metric) :gauge)))

(defun histogram-p (metric)
  (and (metric-p metric) (eq (%metric-kind metric) :histogram)))

(defun %finite-real-p (value)
  (and (realp value)
       (or (not (floatp value))
           (and (= value value)
                (let ((predicate (and (find-package :sb-ext)
                                      (find-symbol "FLOAT-INFINITY-P" :sb-ext))))
                  (not (and predicate (funcall predicate value))))))))

(defun %validate-metric-number (value what)
  (%validate-real value what)
  (unless (%finite-real-p value)
    (error 'observability-error
           :message (format nil "~A must be finite, got ~S." what value)))
  value)

(defun %normalize-help (name help)
  (unless (or (null help) (stringp help))
    (error 'observability-error
           :message (format nil "Metric help must be a string, got ~S." help)))
  (or (%copy-observability-value help) name))

(defun %normalize-unit (unit)
  (unless (or (null unit) (stringp unit))
    (error 'observability-error
           :message (format nil "Metric unit must be a string, got ~S." unit)))
  (%copy-observability-value unit))

(defun %normalize-label-options (label-names label-names-supplied-p
                                 labels labels-supplied-p)
  (let ((first (if label-names-supplied-p
                  (%normalize-label-names label-names)
                  nil))
        (second (if labels-supplied-p
                    (%normalize-label-names labels)
                    nil)))
    (when (and label-names-supplied-p labels-supplied-p
               (not (equal first second)))
      (error 'observability-error
             :message "LABEL-NAMES and LABELS describe different definitions."))
    (cond
      (label-names-supplied-p first)
      (labels-supplied-p second)
      (t nil))))

(defun %normalize-buckets (buckets)
  (let ((source (or buckets *default-histogram-buckets*)))
    (unless (%proper-list-p source)
      (error 'observability-error
             :message "Histogram buckets must be supplied as a list."))
    (let ((normalized
            (mapcar (lambda (value)
                      (%validate-metric-number value "Histogram bucket"))
                    (copy-list source))))
      (loop for previous = nil then current
            for current in normalized
            when (and previous (not (< previous current)))
              do (error 'observability-error
                        :message "Histogram buckets must be strictly increasing.")
            finally (return normalized)))))

(defun %histogram-buckets-equal-p (left right)
  (and (= (length left) (length right))
       (every #'= left right)))

(defun %metric-definitions-compatible-p (metric kind help unit label-names
                                         cardinality-limit histogram-buckets)
  (and (eq (%metric-kind metric) kind)
       (string= (%metric-help metric) help)
       (equal (%metric-unit metric) unit)
       (equal (%metric-label-names metric) label-names)
       (= (%metric-cardinality-limit metric) cardinality-limit)
       (if (eq kind :histogram)
           (%histogram-buckets-equal-p (%metric-histogram-buckets metric)
                                       histogram-buckets)
           (null histogram-buckets))))

(defun %make-empty-series (metric)
  (%make-metric-series
   nil
   0
   0
   0
   (and (histogram-p metric)
        (make-array
         (1+ (length (%metric-histogram-buckets metric)))
         :initial-element 0))))

(defun %define-metric (registry kind name &key help unit
                                              label-names label-names-supplied-p
                                              labels labels-supplied-p
                                              cardinality-limit
                                              cardinality-limit-supplied-p
                                              buckets)
  (check-type registry metric-registry)
  (let* ((normalized-name (%validate-metric-name name))
         (normalized-help (%normalize-help normalized-name help))
         (normalized-unit (%normalize-unit unit))
         (normalized-label-names
           (%normalize-label-options label-names label-names-supplied-p
                                     labels labels-supplied-p))
         (normalized-limit
           (if cardinality-limit-supplied-p
               (%validate-positive-integer cardinality-limit
                                           "Metric cardinality limit")
               (%metric-registry-default-cardinality-limit registry)))
         (normalized-buckets (and (eq kind :histogram)
                                  (%normalize-buckets buckets))))
    (cl-concurrent-kit:with-lock-held ((%metric-registry-lock registry))
      (multiple-value-bind (existing present-p)
          (gethash normalized-name (%metric-registry-metrics registry))
        (if present-p
            (if (%metric-definitions-compatible-p
                 existing kind normalized-help normalized-unit
                 normalized-label-names normalized-limit normalized-buckets)
                existing
                (error 'metric-definition-conflict
                       :name normalized-name
                       :existing existing
                       :message (format nil "Metric ~S is already defined differently."
                                         normalized-name)))
            (let ((metric
                    (%make-metric kind registry normalized-name normalized-help
                                  normalized-unit normalized-label-names
                                  normalized-limit
                                  (make-hash-table :test #'equal)
                                  (cl-concurrent-kit:make-lock
                                   :name (format nil "metric-~A" normalized-name))
                                  normalized-buckets)))
              (when (null normalized-label-names)
                (setf (gethash nil (%metric-series metric))
                      (%make-empty-series metric)))
              (setf (gethash normalized-name (%metric-registry-metrics registry))
                    metric)
              metric))))))

(defun define-counter (registry name &key help unit
                                             (label-names nil label-names-supplied-p)
                                             (labels nil labels-supplied-p)
                                             (cardinality-limit nil cardinality-limit-supplied-p))
  "Define or return a COUNTER with NAME in REGISTRY.

LABEL-NAMES (or its LABELS alias) is a finite list of required label names.
Repeated compatible definitions return the original metric; incompatible
definitions signal METRIC-DEFINITION-CONFLICT."
  (%define-metric registry :counter name
                  :help help :unit unit
                  :label-names label-names
                  :label-names-supplied-p label-names-supplied-p
                  :labels labels :labels-supplied-p labels-supplied-p
                  :cardinality-limit cardinality-limit
                  :cardinality-limit-supplied-p cardinality-limit-supplied-p))

(defun define-gauge (registry name &key help unit
                                          (label-names nil label-names-supplied-p)
                                          (labels nil labels-supplied-p)
                                          (cardinality-limit nil cardinality-limit-supplied-p))
  "Define or return a GAUGE with NAME in REGISTRY."
  (%define-metric registry :gauge name
                  :help help :unit unit
                  :label-names label-names
                  :label-names-supplied-p label-names-supplied-p
                  :labels labels :labels-supplied-p labels-supplied-p
                  :cardinality-limit cardinality-limit
                  :cardinality-limit-supplied-p cardinality-limit-supplied-p))

(defun define-histogram (registry name &key help unit buckets
                                              (label-names nil label-names-supplied-p)
                                              (labels nil labels-supplied-p)
                                              (cardinality-limit nil cardinality-limit-supplied-p))
  "Define or return a HISTOGRAM with strictly increasing BUCKETS."
  (%define-metric registry :histogram name
                  :help help :unit unit :buckets buckets
                  :label-names label-names
                  :label-names-supplied-p label-names-supplied-p
                  :labels labels :labels-supplied-p labels-supplied-p
                  :cardinality-limit cardinality-limit
                  :cardinality-limit-supplied-p cardinality-limit-supplied-p))

(defun make-counter (&rest arguments)
  (apply #'define-counter arguments))

(defun make-gauge (&rest arguments)
  (apply #'define-gauge arguments))

(defun make-histogram (&rest arguments)
  (apply #'define-histogram arguments))

(defun %operation-error (metric operation message)
  (error 'metric-operation-error
         :metric metric
         :operation operation
         :message message))

(defun %parse-operation-arguments (arguments default-amount require-amount-p)
  (let ((remaining arguments)
        (amount default-amount)
        (amount-supplied-p nil)
        (labels nil)
        (labels-supplied-p nil))
    (when (and remaining (not (keywordp (first remaining))))
      (setf amount (pop remaining)
            amount-supplied-p t))
    (loop while remaining
          do (let ((key (pop remaining)))
               (unless (keywordp key)
                 (error 'observability-error
                        :message (format nil "Unexpected metric argument ~S." key)))
               (unless remaining
                 (error 'observability-error
                        :message (format nil "Metric argument ~S has no value." key)))
               (let ((value (pop remaining)))
                 (case key
                   ((:amount :delta :value :observation)
                    (when amount-supplied-p
                      (error 'observability-error
                             :message "Metric amount was supplied more than once."))
                    (setf amount value amount-supplied-p t))
                   ((:labels :label-values)
                    (when labels-supplied-p
                      (error 'observability-error
                             :message "Metric labels were supplied more than once."))
                    (setf labels value labels-supplied-p t))
                   (otherwise
                    (error 'observability-error
                           :message (format nil "Unknown metric argument ~S." key)))))))
    (when (and require-amount-p (not amount-supplied-p))
      (error 'observability-error :message "A metric value is required."))
    (values amount labels)))

(defun %labels-key (labels)
  (mapcar (lambda (pair) (list (car pair) (cdr pair))) labels))

(defun %normalized-operation-labels (metric labels)
  (%normalize-labels (%metric-label-names metric)
                     labels
                     (%metric-registry-max-label-value-length
                      (%metric-registry metric))))

(defun %get-or-create-series (metric labels)
  (let* ((key (%labels-key labels))
         (series-table (%metric-series metric)))
    (cl-concurrent-kit:with-lock-held ((%metric-lock metric))
      (multiple-value-bind (series present-p) (gethash key series-table)
        (if present-p
            series
            (if (>= (hash-table-count series-table)
                    (%metric-cardinality-limit metric))
                (error 'metric-cardinality-exceeded
                       :name (%metric-name metric)
                       :limit (%metric-cardinality-limit metric)
                       :labels labels
                       :message (format nil
                                        "Metric ~S exceeded its cardinality limit of ~D."
                                        (%metric-name metric)
                                        (%metric-cardinality-limit metric)))
                (setf (gethash key series-table)
                      (%make-metric-series (%copy-alist labels) 0 0 0
                                           (and (histogram-p metric)
                                                (make-array
                                                 (1+ (length (%metric-histogram-buckets metric)))
                                                 :initial-element 0))))))))))

(defun %with-series (metric labels function)
  (let ((series (%get-or-create-series metric labels)))
    (cl-concurrent-kit:with-lock-held ((%metric-lock metric))
      (funcall function series))))

(defun metric-inc (metric &rest arguments)
  "Increment a counter or gauge and return its new exact value.

The optional positional argument or :AMOUNT/:DELTA keyword is the amount;
labels are supplied with :LABELS as an alist or property list."
  (check-type metric metric)
  (unless (or (counter-p metric) (gauge-p metric))
    (%operation-error metric :increment
                      "METRIC-INC is supported only for counters and gauges."))
  (multiple-value-bind (amount labels)
      (%parse-operation-arguments arguments 1 nil)
    (if (counter-p metric)
        (progn
          (%validate-metric-number amount "Counter increment")
          (%validate-non-negative-real amount "Counter increment"))
        (%validate-metric-number amount "Gauge increment"))
    (let ((normalized-labels (%normalized-operation-labels metric labels)))
      (%with-series
       metric normalized-labels
       (lambda (series)
         (setf (%metric-series-value series)
               (+ (%metric-series-value series) amount)))))))

(defun metric-set (metric &rest arguments)
  "Set a gauge to an exact real value."
  (check-type metric metric)
  (unless (gauge-p metric)
    (%operation-error metric :set "METRIC-SET is supported only for gauges."))
  (multiple-value-bind (value labels)
      (%parse-operation-arguments arguments nil t)
    (%validate-metric-number value "Gauge value")
    (let ((normalized-labels (%normalized-operation-labels metric labels)))
      (%with-series
       metric normalized-labels
       (lambda (series)
         (setf (%metric-series-value series) value))))))

(defun metric-observe (metric &rest arguments)
  "Observe an exact real value in a histogram and return the value."
  (check-type metric metric)
  (unless (histogram-p metric)
    (%operation-error metric :observe
                      "METRIC-OBSERVE is supported only for histograms."))
  (multiple-value-bind (observation labels)
      (%parse-operation-arguments arguments nil t)
    (%validate-metric-number observation "Histogram observation")
    (let ((normalized-labels (%normalized-operation-labels metric labels)))
      (%with-series
       metric normalized-labels
       (lambda (series)
         (incf (%metric-series-count series))
         (incf (%metric-series-sum series) observation)
         (loop for boundary in (%metric-histogram-buckets metric)
               for index from 0
               when (<= observation boundary)
                 do (incf (aref (%metric-series-bucket-counts series) index)))
         (incf (aref (%metric-series-bucket-counts series)
                     (length (%metric-histogram-buckets metric)))
               1)
         observation)))))

(defun %snapshot-series (metric series)
  (if (histogram-p metric)
      (let ((buckets
              (loop for boundary in (%metric-histogram-buckets metric)
                    for index from 0
                    collect (cons boundary
                                  (aref (%metric-series-bucket-counts series) index)))))
        (setf buckets
              (append buckets
                      (list (cons +infinity+
                                   (aref (%metric-series-bucket-counts series)
                                         (length (%metric-histogram-buckets metric)))))))
        (make-metric-sample
         :labels (%copy-alist (%metric-series-labels series))
         :value nil
         :count (%metric-series-count series)
         :sum (%metric-series-sum series)
         :buckets buckets))
      (make-metric-sample
       :labels (%copy-alist (%metric-series-labels series))
       :value (%metric-series-value series))))

(defun %snapshot-metric (metric)
  (cl-concurrent-kit:with-lock-held ((%metric-lock metric))
    (let ((samples
            (sort (loop for series being the hash-values of (%metric-series metric)
                        collect (%snapshot-series metric series))
                  #'%labels-less-p
                  :key #'metric-sample-labels)))
      (make-metric-snapshot
       :name (%copy-observability-value (%metric-name metric))
       :help (%copy-observability-value (%metric-help metric))
       :type (%metric-kind metric)
       :unit (%copy-observability-value (%metric-unit metric))
       :label-names (mapcar #'%copy-observability-value
                            (%metric-label-names metric))
       :samples samples))))

(defun metric-snapshot (object)
  "Return a stable, sorted snapshot for a metric or registry.

The returned structures contain copies of labels and histogram bucket data;
subsequent updates cannot mutate an already returned snapshot."
  (cond
    ((metric-p object) (%snapshot-metric object))
    ((metric-registry-p object)
     (mapcar #'%snapshot-metric (metric-registry-metrics object)))
    (t
     (error 'observability-error
            :message (format nil "Cannot snapshot object ~S." object)))))

(defun registry-snapshot (registry)
  (metric-snapshot registry))
