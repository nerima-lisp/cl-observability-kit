#.(progn
    (in-package #:observability-kit)
    nil)

(defun %static-metric-name (name)
  "Return the source-level metric name required by DEFINE-* macros.

Metric names are intentionally compile-time symbols.  This keeps definitions
readable and removes the old runtime string/designator compatibility surface."
  (unless (and (symbolp name) (not (keywordp name)))
    (error 'program-error))
  (string-downcase (symbol-name name)))

(defun %validate-metric-definition-options (options)
  (let ((accepted '(:help :unit :label-names :cardinality-limit :buckets))
        (seen '()))
    (unless (evenp (length options))
      (error 'program-error))
    (loop for key in options by #'cddr
          do (unless (and (keywordp key) (member key accepted :test #'eq))
               (error 'program-error))
             (when (member key seen :test #'eq)
               (error 'program-error))
             (push key seen)))
  options)

(defmacro %with-metric-series ((series metric labels) &body body)
  "Run BODY with the locked metric series for LABELS.

The lookup, cardinality check, creation, and update share one lock so a new
series cannot race another operation for the same metric."
  (let ((metric-variable (gensym "METRIC-"))
        (labels-variable (gensym "LABELS-")))
    `(let ((,metric-variable ,metric)
           (,labels-variable ,labels))
       (cl-concurrent-kit:with-lock-held ((%metric-lock ,metric-variable))
         (let ((,series
                 (or (gethash ,labels-variable (%metric-series ,metric-variable))
                     (when (>= (hash-table-count (%metric-series ,metric-variable))
                               (%metric-cardinality-limit ,metric-variable))
                       (error 'metric-cardinality-exceeded
                              :name (%metric-name ,metric-variable)
                              :limit (%metric-cardinality-limit ,metric-variable)
                              :labels ,labels-variable
                              :message (format nil
                                               "Metric ~S exceeded its cardinality limit of ~D."
                                               (%metric-name ,metric-variable)
                                               (%metric-cardinality-limit ,metric-variable))))
                     (setf (gethash ,labels-variable
                                    (%metric-series ,metric-variable))
                           (%empty-series (%metric-kind ,metric-variable)
                                          (%metric-histogram-buckets ,metric-variable)
                                          ,labels-variable)))))
           ,@body)))))

(defmacro define-counter (registry name &rest options)
  "Define a counter named by the symbol NAME in REGISTRY."
  (%validate-metric-definition-options options)
  `(%define-metric ,registry :counter ,(%static-metric-name name) ,@options))

(defmacro define-gauge (registry name &rest options)
  "Define a gauge named by the symbol NAME in REGISTRY."
  (%validate-metric-definition-options options)
  `(%define-metric ,registry :gauge ,(%static-metric-name name) ,@options))

(defmacro define-histogram (registry name &rest options)
  "Define a histogram named by the symbol NAME in REGISTRY."
  (%validate-metric-definition-options options)
  `(%define-metric ,registry :histogram ,(%static-metric-name name) ,@options))
