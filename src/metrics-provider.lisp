(in-package #:cl-observability-kit)

(defun %metric-provider-registry-options-with-scope
    (options name version schema-url)
  (let ((filtered nil))
    (loop for (key value) on options by #'cddr
          unless (member key '(:scope-name :scope-version :scope-schema-url)
                          :test #'eq)
            do (setf filtered (append filtered (list key value))))
    (append filtered
            (list :scope-name name
                  :scope-version version
                  :scope-schema-url schema-url))))

(defun make-meter-provider (&rest option-list)
  "Create a provider of named meter scopes and pull readers."
  (let* ((options (%parse-keyword-options
                   option-list
                   '(:resource :readers :registry-options :flush :shutdown
                     :error-handler)
                   "MAKE-METER-PROVIDER"))
         (resource (or (%option-value options :resource nil)
                       (make-resource)))
         (readers (%option-value options :readers nil))
         (registry-options (%option-value options :registry-options nil))
         (flush (%validate-optional-metric-callback
                 (%option-value options :flush nil)
                 "Meter provider flush callback"))
         (shutdown (%validate-optional-metric-callback
                    (%option-value options :shutdown nil)
                    "Meter provider shutdown callback"))
         (error-handler (%validate-optional-metric-callback
                         (%option-value options :error-handler nil)
                         "Meter provider error handler")))
    (check-type resource resource)
    (unless (proper-list-p readers)
      (error 'observability-error
             :message "Meter provider readers must be a proper list."))
    (unless (proper-list-p registry-options)
      (error 'observability-error
             :message "Meter provider registry options must be a proper list."))
    (dolist (reader readers)
      (check-type reader metric-reader))
    (apply #'make-metric-registry registry-options)
    (%make-meter-provider
     (cl-concurrent-kit:make-lock :name "observability-meter-provider")
     (make-hash-table :test #'equal)
     (copy-list readers)
     (make-resource :attributes (resource-attributes resource))
     (copy-list registry-options)
     flush shutdown error-handler nil nil)))

(defun meter-provider-resource (provider)
  (check-type provider meter-provider)
  (cl-concurrent-kit:with-lock-held ((%meter-provider-lock provider))
    (make-resource :attributes
                   (resource-attributes (%meter-provider-resource provider)))))

(defun meter-provider-meters (provider)
  (check-type provider meter-provider)
  (cl-concurrent-kit:with-lock-held ((%meter-provider-lock provider))
    (sort (loop for meter being the hash-values of (%meter-provider-meters provider)
                collect meter)
          (lambda (left right)
            (or (string< (%meter-name left) (%meter-name right))
                (and (string= (%meter-name left) (%meter-name right))
                     (string< (or (%meter-version left) "")
                              (or (%meter-version right) ""))))))))

(defun meter-provider-readers (provider)
  (check-type provider meter-provider)
  (cl-concurrent-kit:with-lock-held ((%meter-provider-lock provider))
    (copy-list (%meter-provider-readers provider))))

(defun meter-provider-shutdown-p (provider)
  (check-type provider meter-provider)
  (cl-concurrent-kit:with-lock-held ((%meter-provider-lock provider))
    (%meter-provider-shutdown-p provider)))

(defun meter-provider-last-error (provider)
  (check-type provider meter-provider)
  (cl-concurrent-kit:with-lock-held ((%meter-provider-lock provider))
    (%meter-provider-last-error provider)))

(defun make-meter (provider name &key version schema-url)
  "Create or return a meter identified by its instrumentation scope."
  (check-type provider meter-provider)
  (let ((normalized-name (%normalize-metric-scope-value
                          (%designator-string name) "Meter name"))
        (normalized-version (%normalize-metric-scope-value version "Meter version"))
        (normalized-schema-url (%normalize-metric-scope-value schema-url "Meter schema URL")))
    (let ((key (list normalized-name normalized-version normalized-schema-url)))
      (cl-concurrent-kit:with-lock-held ((%meter-provider-lock provider))
        (when (%meter-provider-shutdown-p provider)
          (error 'observability-error
                 :message "Cannot create a meter from a shut down meter provider."))
        (or (gethash key (%meter-provider-meters provider))
            (let ((registry (apply #'make-metric-registry
                                   (%metric-provider-registry-options-with-scope
                                    (%meter-provider-registry-options provider)
                                    normalized-name normalized-version
                                    normalized-schema-url))))
              (setf (gethash key (%meter-provider-meters provider))
                    (%make-meter provider normalized-name normalized-version
                                 normalized-schema-url registry))))))))

(defun meter-name (meter)
  (check-type meter meter)
  (%copy-observability-value (%meter-name meter)))

(defun meter-version (meter)
  (check-type meter meter)
  (%copy-observability-value (%meter-version meter)))

(defun meter-schema-url (meter)
  (check-type meter meter)
  (%copy-observability-value (%meter-schema-url meter)))

(defun meter-provider (meter)
  (check-type meter meter)
  (%meter-provider meter))

(defun meter-registry (meter)
  (check-type meter meter)
  (%meter-registry meter))

(defun force-flush-meter-provider (provider)
  "Flush every registered reader and the provider callback."
  (check-type provider meter-provider)
  (let ((readers nil) (flush nil) (active-p nil))
    (cl-concurrent-kit:with-lock-held ((%meter-provider-lock provider))
      (unless (%meter-provider-shutdown-p provider)
        (setf active-p t readers (copy-list (%meter-provider-readers provider))
              flush (%meter-provider-flush provider))))
    (when active-p
      (if (null readers)
          (if flush
              (handler-case (progn (funcall flush) t)
                (error (condition)
                  (%record-meter-provider-error provider condition) nil))
              t)
          (let ((success t))
            (dolist (reader readers)
              (unless (force-flush-metric-reader reader) (setf success nil)))
            (when flush
              (handler-case (funcall flush)
                (error (condition)
                  (%record-meter-provider-error provider condition)
                  (setf success nil))))
            success)))))

(defun %record-meter-provider-error (provider condition)
  (let ((handler nil))
    (cl-concurrent-kit:with-lock-held ((%meter-provider-lock provider))
      (setf (%meter-provider-last-error provider) condition
            handler (%meter-provider-error-handler provider)))
    (when handler (ignore-errors (funcall handler condition)))
    nil))

(defun shutdown-meter-provider (provider)
  "Shut down readers and the provider callback exactly once."
  (check-type provider meter-provider)
  (let ((readers nil) (shutdown nil))
    (cl-concurrent-kit:with-lock-held ((%meter-provider-lock provider))
      (unless (%meter-provider-shutdown-p provider)
        (setf (%meter-provider-shutdown-p provider) t
              readers (copy-list (%meter-provider-readers provider))
              shutdown (%meter-provider-shutdown provider))))
    (dolist (reader readers) (shutdown-metric-reader reader))
    (when shutdown
      (handler-case (funcall shutdown)
        (error (condition) (%record-meter-provider-error provider condition))))
    t))
