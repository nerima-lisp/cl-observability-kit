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
