#.(progn
    (in-package #:observability-kit)
    nil)

(defun %normalize-help (name help)
  (if help
      (progn
        (unless (stringp help)
          (error 'observability-error
                 :message "Metric help must be a string."))
        (%copy-observability-value help))
      name))

(defun %normalize-unit (unit)
  (when unit
    (unless (stringp unit)
      (error 'observability-error
             :message "Metric unit must be a string."))
    (%copy-observability-value unit)))

(defun %normalize-buckets (buckets)
  (let ((source (or buckets *default-histogram-buckets*)))
    (unless (proper-list-p source)
      (error 'observability-error
             :message "Histogram buckets must be a proper list."))
    (let ((normalized (mapcar (lambda (bucket)
                               (%validate-finite-real bucket "Histogram bucket"))
                             source)))
      (unless (and normalized
                    (every #'< normalized (rest normalized)))
        (error 'observability-error
               :message "Histogram buckets must be strictly increasing."))
      (copy-list normalized))))

(defun %metric-definition-registry (owner)
  (cond
    ((metric-registry-p owner)
     owner)
    ((meter-p owner)
     (%meter-registry owner))
    (t
     (error 'type-error
            :datum owner
            :expected-type '(or metric-registry meter)))))

(defun %observable-metric-kind-p (kind)
  (member kind '(:observable-counter :observable-gauge
                 :observable-up-down-counter)
          :test #'eq))

(defun %normalize-metric-callback (kind callback supplied-p)
  (when (and supplied-p (not (%observable-metric-kind-p kind)))
    (error 'observability-error
           :message "Metric callbacks are only valid for observable metrics."))
  (when (%observable-metric-kind-p kind)
    (unless (and supplied-p
                 (or (functionp callback)
                     (and (symbolp callback) (fboundp callback))))
      (error 'observability-error
             :message "Observable metrics require a function callback.")))
  callback)

(defun %empty-series (kind buckets labels)
  (%make-metric-series labels
                       0
                       0
                       0
                       (when (eq kind :histogram)
                         (make-list (1+ (length buckets)) :initial-element 0))))

(defun %compatible-metric-p
    (metric kind help unit label-names cardinality-limit buckets callback)
  (and (eq (%metric-kind metric) kind)
       (string= (%metric-help metric) help)
       (equal (%metric-unit metric) unit)
       (equal (%metric-label-names metric) label-names)
       (= (%metric-cardinality-limit metric) cardinality-limit)
       (equal (%metric-histogram-buckets metric) buckets)
       (equal (%metric-callback metric) callback)))

(defun %define-metric (owner kind name &rest option-list)
  (let ((registry (%metric-definition-registry owner)))
  (let* ((options (%parse-keyword-options
                   option-list
                   '(:help :unit :label-names :cardinality-limit :buckets
                     :callback)
                   "DEFINE-METRIC"))
         (help (%option-value options :help nil))
         (unit (%option-value options :unit nil))
         (label-names (%option-value options :label-names nil))
         (cardinality-limit (%option-value options :cardinality-limit nil))
         (normalized-name (%validate-metric-name name))
         (normalized-label-names (%normalize-label-names label-names))
         (normalized-help (%normalize-help normalized-name help))
         (normalized-unit (%normalize-unit unit))
         (normalized-limit
           (if (%option-supplied-p options :cardinality-limit)
               (progn
                 (%validate-positive-integer cardinality-limit
                                              "Metric cardinality limit")
                 cardinality-limit)
               (%metric-registry-default-cardinality-limit registry)))
         (normalized-buckets (when (eq kind :histogram)
                               (%normalize-buckets
                                (%option-value options :buckets nil))))
         (normalized-callback
           (%normalize-metric-callback
            kind
            (%option-value options :callback nil)
            (%option-supplied-p options :callback))))
    (cl-concurrent-kit:with-lock-held ((%metric-registry-lock registry))
      (let ((existing (gethash normalized-name
                                (%metric-registry-metrics registry))))
        (cond
          (existing
           (unless (%compatible-metric-p existing kind normalized-help normalized-unit
                                          normalized-label-names normalized-limit
                                          normalized-buckets normalized-callback)
             (error 'metric-definition-conflict
                    :name normalized-name
                    :message (format nil
                                     "Metric ~S is already defined incompatibly."
                                     normalized-name)))
           existing)
          (t
           (let ((metric (%make-metric
                          kind registry normalized-name normalized-help normalized-unit
                          normalized-label-names normalized-limit
                          (make-hash-table :test #'equal)
                          nil
                          (cl-concurrent-kit:make-lock :name normalized-name)
                          normalized-buckets
                          normalized-callback
                          (get-universal-time))))
             (when (and (null normalized-label-names)
                        (not (%observable-metric-kind-p kind)))
               (let ((series (%empty-series kind normalized-buckets nil)))
                 (setf (gethash nil (%metric-series metric)) series
                       (%metric-series-order metric) (list series))))
             (setf (gethash normalized-name (%metric-registry-metrics registry)) metric)
             metric))))))))
