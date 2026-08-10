#.(progn
    (in-package #:observability-kit)
    nil)

(defstruct (metric-reader
            (:constructor %make-metric-reader
                (source exporter flush shutdown error-handler lock shutdown-p
                 last-error last-snapshots))
            (:conc-name %metric-reader-))
  source
  exporter
  flush
  shutdown
  error-handler
  lock
  shutdown-p
  last-error
  last-snapshots)

(defun %metric-callback-p (value)
  (or (functionp value)
      (and (symbolp value) (fboundp value))))

(defun %validate-optional-metric-callback (value what)
  (when (and value (not (%metric-callback-p value)))
    (error 'observability-error
           :message (format nil "~A must be a function." what)))
  value)

(defun %metric-reader-source-p (source)
  (or (metric-p source)
      (metric-registry-p source)
      (meter-p source)
      (meter-provider-p source)))

(defun %copy-metric-snapshot (snapshot)
  (make-metric-snapshot
   :name (%copy-observability-value (%metric-snapshot-name snapshot))
   :help (%copy-observability-value (%metric-snapshot-help snapshot))
   :type (%metric-snapshot-type snapshot)
   :unit (%copy-observability-value (%metric-snapshot-unit snapshot))
   :label-names (mapcar #'%copy-observability-value
                        (%metric-snapshot-label-names snapshot))
   :samples (mapcar #'%copy-metric-sample
                    (%metric-snapshot-samples snapshot))
   :resource (metric-snapshot-resource snapshot)
   :scope-name (%copy-observability-value
                (%metric-snapshot-scope-name snapshot))
   :scope-version (%copy-observability-value
                   (%metric-snapshot-scope-version snapshot))
   :scope-schema-url (%copy-observability-value
                      (%metric-snapshot-scope-schema-url snapshot))))

(defun %metric-source-snapshots (source)
  (let ((snapshots (metric-snapshot source)))
    (if (listp snapshots)
        snapshots
        (list snapshots))))

(defun register-metric-reader (provider reader)
  "Attach READER to PROVIDER for provider-level flush and shutdown calls."
  (check-type provider meter-provider)
  (check-type reader metric-reader)
  (cl-concurrent-kit:with-lock-held ((%meter-provider-lock provider))
    (when (%meter-provider-shutdown-p provider)
      (error 'observability-error
             :message "Cannot register a metric reader on a shut down meter provider."))
    (pushnew reader (%meter-provider-readers provider) :test #'eq))
  reader)

(defun make-metric-reader (source &rest option-list)
  "Create a pull reader for SOURCE.

EXPORTER receives a detached list of metric snapshots.  Readers never call an
exporter while holding a registry or provider lock; exporter failures are
retained in METRIC-READER-LAST-ERROR and passed to ERROR-HANDLER when one is
configured."
  (unless (%metric-reader-source-p source)
    (error 'type-error
           :datum source
           :expected-type '(or metric metric-registry meter meter-provider)))
  (let* ((options (%parse-keyword-options
                   option-list
                   '(:exporter :flush :shutdown :error-handler)
                   "MAKE-METRIC-READER"))
         (exporter (%validate-optional-metric-callback
                    (%option-value options :exporter nil)
                    "Metric reader exporter"))
         (flush (%validate-optional-metric-callback
                 (%option-value options :flush nil)
                 "Metric reader flush callback"))
         (shutdown (%validate-optional-metric-callback
                    (%option-value options :shutdown nil)
                    "Metric reader shutdown callback"))
         (error-handler (%validate-optional-metric-callback
                         (%option-value options :error-handler nil)
                         "Metric reader error handler"))
         (reader (%make-metric-reader
                  source exporter flush shutdown error-handler
                  (cl-concurrent-kit:make-lock :name "observability-metric-reader")
                  nil nil nil)))
    (when (meter-provider-p source)
      (register-metric-reader source reader))
    reader))

(defun metric-reader-source (reader)
  (check-type reader metric-reader)
  (%metric-reader-source reader))

(defun metric-reader-shutdown-p (reader)
  (check-type reader metric-reader)
  (cl-concurrent-kit:with-lock-held ((%metric-reader-lock reader))
    (%metric-reader-shutdown-p reader)))

(defun metric-reader-last-error (reader)
  (check-type reader metric-reader)
  (cl-concurrent-kit:with-lock-held ((%metric-reader-lock reader))
    (%metric-reader-last-error reader)))

(defun metric-reader-last-snapshots (reader)
  (check-type reader metric-reader)
  (cl-concurrent-kit:with-lock-held ((%metric-reader-lock reader))
    (mapcar #'%copy-metric-snapshot
            (%metric-reader-last-snapshots reader))))

(defun collect-metric-reader (reader &key (export-p t))
  "Collect SOURCE and optionally pass detached snapshots to EXPORTER."
  (check-type reader metric-reader)
  (handler-case
      (progn
        (when (metric-reader-shutdown-p reader)
          (error 'observability-error
                 :message "Cannot collect from a shut down metric reader."))
        (let* ((snapshots (%metric-source-snapshots (%metric-reader-source reader)))
               (detached (mapcar #'%copy-metric-snapshot snapshots)))
          (cl-concurrent-kit:with-lock-held ((%metric-reader-lock reader))
            (setf (%metric-reader-last-snapshots reader)
                  detached))
          (when (and export-p (%metric-reader-exporter reader))
            (funcall (%metric-reader-exporter reader)
                     (mapcar #'%copy-metric-snapshot snapshots)))
          (values detached t)))
    (error (condition)
      (cl-concurrent-kit:with-lock-held ((%metric-reader-lock reader))
        (setf (%metric-reader-last-error reader) condition))
      (when (%metric-reader-error-handler reader)
        (ignore-errors
          (funcall (%metric-reader-error-handler reader) condition)))
      (values nil nil))))

(defun force-flush-metric-reader (reader)
  "Collect READER and invoke its flush callback, returning true on success."
  (check-type reader metric-reader)
  (multiple-value-bind (snapshots collected-p)
      (collect-metric-reader reader)
    (declare (ignore snapshots))
    (and collected-p
         (if (%metric-reader-flush reader)
             (handler-case
                 (progn
                   (funcall (%metric-reader-flush reader))
                   t)
               (error (condition)
                 (cl-concurrent-kit:with-lock-held ((%metric-reader-lock reader))
                   (setf (%metric-reader-last-error reader) condition))
                 (when (%metric-reader-error-handler reader)
                   (ignore-errors
                     (funcall (%metric-reader-error-handler reader) condition)))
                 nil))
             t))))

(defun metric-reader-force-flush (reader)
  "Compatibility spelling for FORCE-FLUSH-METRIC-READER."
  (force-flush-metric-reader reader))

(defun shutdown-metric-reader (reader)
  "Shut down READER exactly once and isolate shutdown callback failures."
  (check-type reader metric-reader)
  (let ((shutdown nil))
    (cl-concurrent-kit:with-lock-held ((%metric-reader-lock reader))
      (unless (%metric-reader-shutdown-p reader)
        (setf (%metric-reader-shutdown-p reader) t
              shutdown (%metric-reader-shutdown reader))))
    (when shutdown
      (handler-case
          (funcall shutdown)
        (error (condition)
          (cl-concurrent-kit:with-lock-held ((%metric-reader-lock reader))
            (setf (%metric-reader-last-error reader) condition))
          (when (%metric-reader-error-handler reader)
            (ignore-errors
              (funcall (%metric-reader-error-handler reader) condition))))))
    t))

(defun metric-reader-shutdown (reader)
  "Compatibility spelling for SHUTDOWN-METRIC-READER."
  (shutdown-metric-reader reader))

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
    ;; Validate the option shape before retaining it for future meters.
    (apply #'make-metric-registry registry-options)
    (%make-meter-provider
     (cl-concurrent-kit:make-lock :name "observability-meter-provider")
     (make-hash-table :test #'equal)
     (copy-list readers)
     (make-resource :attributes (resource-attributes resource))
     (copy-list registry-options)
     flush
     shutdown
     error-handler
     nil
     nil)))

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
  (let ((normalized-name
          (%normalize-metric-scope-value
           (%designator-string name)
           "Meter name"))
        (normalized-version
          (%normalize-metric-scope-value version "Meter version"))
        (normalized-schema-url
          (%normalize-metric-scope-value schema-url "Meter schema URL")))
    (let ((key (list normalized-name normalized-version normalized-schema-url)))
      (cl-concurrent-kit:with-lock-held ((%meter-provider-lock provider))
        (when (%meter-provider-shutdown-p provider)
          (error 'observability-error
                 :message "Cannot create a meter from a shut down meter provider."))
        (or (gethash key (%meter-provider-meters provider))
            (let ((registry
                    (apply #'make-metric-registry
                           (%metric-provider-registry-options-with-scope
                            (%meter-provider-registry-options provider)
                            normalized-name
                            normalized-version
                            normalized-schema-url))))
              (setf (gethash key (%meter-provider-meters provider))
                    (%make-meter provider
                                  normalized-name
                                  normalized-version
                                  normalized-schema-url
                                  registry))))))))

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
  (let ((readers nil)
        (flush nil)
        (active-p nil))
    (cl-concurrent-kit:with-lock-held ((%meter-provider-lock provider))
      (unless (%meter-provider-shutdown-p provider)
        (setf active-p t
              readers (copy-list (%meter-provider-readers provider))
              flush (%meter-provider-flush provider))))
    (when active-p
      (if (null readers)
          (if flush
              (handler-case
                  (progn (funcall flush) t)
                (error (condition)
                  (%record-meter-provider-error provider condition)
                  nil))
              t)
          (let ((success t))
            (dolist (reader readers)
              (unless (force-flush-metric-reader reader)
                (setf success nil)))
            (when flush
              (handler-case
                  (funcall flush)
                (error (condition)
                  (%record-meter-provider-error provider condition)
                  (setf success nil))))
            success)))))

(defun %record-meter-provider-error (provider condition)
  (let ((handler nil))
    (cl-concurrent-kit:with-lock-held ((%meter-provider-lock provider))
      (setf (%meter-provider-last-error provider) condition
            handler (%meter-provider-error-handler provider)))
    (when handler
      (ignore-errors (funcall handler condition)))
    nil))

(defun shutdown-meter-provider (provider)
  "Shut down readers and the provider callback exactly once."
  (check-type provider meter-provider)
  (let ((readers nil)
        (shutdown nil))
    (cl-concurrent-kit:with-lock-held ((%meter-provider-lock provider))
      (unless (%meter-provider-shutdown-p provider)
        (setf (%meter-provider-shutdown-p provider) t
              readers (copy-list (%meter-provider-readers provider))
              shutdown (%meter-provider-shutdown provider))))
    (dolist (reader readers)
      (shutdown-metric-reader reader))
    (when shutdown
      (handler-case
          (funcall shutdown)
        (error (condition)
          (%record-meter-provider-error provider condition))))
    t))
