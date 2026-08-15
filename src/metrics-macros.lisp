#.(progn
    (in-package #:observability-kit)
    nil)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun %static-metric-name (name)
    "Return the source-level metric name required by DEFINE-* macros.

    Metric names are intentionally compile-time symbols.  This keeps definitions
    readable and removes the old runtime string/designator compatibility surface."
    (unless (and (symbolp name) (not (keywordp name)))
      (error 'program-error))
    (string-downcase (symbol-name name)))

  (defun %validate-metric-definition-options (options)
    (let ((accepted '(:help :unit :label-names :cardinality-limit :buckets
                      :callback))
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

  (defun %expand-metric-declaration (registry kind name options)
    (%validate-metric-definition-options options)
    `(%define-metric ,registry ,kind ,(%static-metric-name name) ,@options)))

(defmacro %with-metric-series ((series metric labels) &body body)
  "Run BODY with the locked metric series for LABELS.

The lookup, cardinality check, creation, and update share one lock so a new
series cannot race another operation for the same metric."
  (let ((metric-variable (gensym "METRIC-"))
        (labels-variable (gensym "LABELS-")))
    `(let ((,metric-variable ,metric)
           (,labels-variable ,labels))
       (cl-concurrent-kit:with-lock-held ((%metric-lock ,metric-variable))
         (let ((,series (gethash ,labels-variable
                                 (%metric-series ,metric-variable))))
           (unless ,series
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
             (setf ,series
                   (%empty-series (%metric-kind ,metric-variable)
                                  (%metric-histogram-buckets ,metric-variable)
                                  ,labels-variable))
             (setf (gethash ,labels-variable (%metric-series ,metric-variable))
                   ,series)
             (setf (%metric-series-order ,metric-variable)
                   (%insert-metric-series
                    (%metric-series-order ,metric-variable)
                    ,series)))
           ,@body)))))

(defmacro define-counter (registry name &rest options)
  "Define a counter named by the symbol NAME in REGISTRY."
  (%expand-metric-declaration registry :counter name options))

(defmacro define-up-down-counter (registry name &rest options)
  "Define a counter that may be incremented or decremented."
  (%expand-metric-declaration registry :up-down-counter name options))

(defmacro define-gauge (registry name &rest options)
  "Define a gauge named by the symbol NAME in REGISTRY."
  (%expand-metric-declaration registry :gauge name options))

(defmacro define-histogram (registry name &rest options)
  "Define a histogram named by the symbol NAME in REGISTRY."
  (%expand-metric-declaration registry :histogram name options))

(defmacro define-observable-counter (registry name &rest options)
  "Define a callback-driven observable counter."
  (%expand-metric-declaration registry :observable-counter name options))

(defmacro define-observable-gauge (registry name &rest options)
  "Define a callback-driven observable gauge."
  (%expand-metric-declaration registry :observable-gauge name options))

(defmacro define-observable-up-down-counter (registry name &rest options)
  "Define a callback-driven observable up-down counter."
  (%expand-metric-declaration registry :observable-up-down-counter name options))
