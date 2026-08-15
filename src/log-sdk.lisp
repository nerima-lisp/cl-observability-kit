#.(progn
    (in-package #:observability-kit)
    nil)

(defun %log-callback-p (value)
  (or (functionp value)
      (and (symbolp value) (fboundp value))))

(defun %validate-optional-log-callback (value what)
  (when (and value (not (%log-callback-p value)))
    (error 'observability-error
           :message (format nil "~A must be a function." what)))
  value)

(defun make-log-processor (&rest option-list)
  "Create a processor for structured log records.

ON-EMIT receives a detached LOG-RECORD.  FORCE-FLUSH and SHUTDOWN receive
the LOG-PROVIDER.  ERROR-HANDLER receives a condition and the callback
argument that was being processed when the condition occurred."
  (let* ((options (%parse-keyword-options
                   option-list
                   '(:on-emit :force-flush :shutdown :error-handler)
                   "MAKE-LOG-PROCESSOR"))
         (on-emit (%validate-optional-log-callback
                   (%option-value options :on-emit nil)
                   "Log processor ON-EMIT callback"))
         (force-flush (%validate-optional-log-callback
                       (%option-value options :force-flush nil)
                       "Log processor FORCE-FLUSH callback"))
         (shutdown (%validate-optional-log-callback
                    (%option-value options :shutdown nil)
                    "Log processor SHUTDOWN callback"))
         (error-handler (%validate-optional-log-callback
                         (%option-value options :error-handler nil)
                         "Log processor ERROR-HANDLER callback")))
    (%make-log-processor on-emit force-flush shutdown error-handler)))

(defun make-log-provider (&rest option-list)
  "Create a provider of named log scopes and log processors.

EXPORTER receives a detached LOG-RECORD.  Processor, exporter, flush, and
shutdown failures are isolated and retained as LOG-PROVIDER-LAST-ERROR."
  (let* ((options (%parse-keyword-options
                   option-list
                   '(:resource :processors :exporter :flush :shutdown
                     :error-handler)
                   "MAKE-LOG-PROVIDER"))
         (resource (or (%option-value options :resource nil)
                       (make-resource)))
         (processors (%option-value options :processors nil))
         (exporter (%validate-optional-log-callback
                    (%option-value options :exporter nil)
                    "Log provider exporter"))
         (flush (%validate-optional-log-callback
                 (%option-value options :flush nil)
                 "Log provider flush callback"))
         (shutdown (%validate-optional-log-callback
                    (%option-value options :shutdown nil)
                    "Log provider shutdown callback"))
         (error-handler (%validate-optional-log-callback
                         (%option-value options :error-handler nil)
                         "Log provider error handler")))
    (check-type resource resource)
    (unless (proper-list-p processors)
      (error 'observability-error
             :message "Log provider processors must be a proper list."))
    (dolist (processor processors)
      (check-type processor log-processor))
    (%make-log-provider
     (cl-concurrent-kit:make-lock :name "observability-log-provider")
     (make-hash-table :test #'equal)
     (make-resource :attributes (resource-attributes resource))
     (copy-list processors)
     exporter
     flush
     shutdown
     error-handler
     nil
     nil)))

(defun %normalize-log-scope-name (name)
  (unless (and (stringp name) (plusp (length name)) (<= (length name) 256))
    (error 'logging-error
           :message "Logger name must be a non-empty string of at most 256 characters."))
  (%copy-observability-value name))

(defun %normalize-log-scope-option (value what)
  (when value
    (unless (and (stringp value) (<= (length value) 256))
      (error 'logging-error
             :message (format nil "~A must be a string of at most 256 characters."
                              what))))
  (%copy-observability-value value))

(defun make-logger (provider name &rest option-list)
  "Return a cached logger for NAME, VERSION, and SCHEMA-URL metadata."
  (check-type provider log-provider)
  (let* ((options (%parse-keyword-options option-list '(:version :schema-url)
                                          "MAKE-LOGGER"))
         (normalized-name (%normalize-log-scope-name name))
         (version (%normalize-log-scope-option
                   (%option-value options :version nil)
                   "Logger version"))
         (schema-url (%normalize-log-scope-option
                      (%option-value options :schema-url nil)
                      "Logger schema URL"))
         (key (list normalized-name version schema-url)))
    (cl-concurrent-kit:with-lock-held ((%log-provider-lock provider))
      (when (%log-provider-shutdown-p provider)
        (error 'log-provider-shutdown :provider provider))
      (or (gethash key (%log-provider-loggers provider))
          (setf (gethash key (%log-provider-loggers provider))
                (%make-logger provider normalized-name version schema-url))))))

(defun register-log-processor (provider processor)
  "Attach PROCESSOR to PROVIDER for emission and lifecycle calls."
  (check-type provider log-provider)
  (check-type processor log-processor)
  (cl-concurrent-kit:with-lock-held ((%log-provider-lock provider))
    (when (%log-provider-shutdown-p provider)
      (error 'log-provider-shutdown :provider provider))
    (setf (%log-provider-processors provider)
          (append (%log-provider-processors provider) (list processor))))
  processor)

(defun %copy-log-record (record)
  (make-log-record
   :timestamp (log-record-timestamp record)
   :observed-timestamp (log-record-observed-timestamp record)
   :severity (log-record-severity record)
   :severity-number (log-record-severity-number record)
   :body (log-record-body record)
   :attributes (log-record-attributes record)
   :context (log-record-context record)
   :resource (log-record-resource record)
   :scope-name (log-record-scope-name record)
   :scope-version (log-record-scope-version record)
   :scope-schema-url (log-record-scope-schema-url record)
   :event-name (log-record-event-name record)))

(defun %record-log-error (provider condition argument &optional processor)
  (let ((provider-handler nil)
        (processor-handler nil))
    (cl-concurrent-kit:with-lock-held ((%log-provider-lock provider))
      (setf (%log-provider-last-error provider) condition
            provider-handler (%log-provider-error-handler provider)))
    (when processor
      (setf processor-handler (%log-processor-error-handler processor)))
    (when processor-handler
      (handler-case
          (funcall processor-handler condition argument)
        (error () nil)))
    (when provider-handler
      (handler-case
          (funcall provider-handler condition argument)
        (error () nil)))))

(defun %call-log-processor (provider processor phase argument)
  (let ((callback
          (ecase phase
            (:on-emit (%log-processor-on-emit processor))
            (:force-flush (%log-processor-force-flush processor))
            (:shutdown (%log-processor-shutdown processor)))))
    (if (null callback)
        t
        (handler-case
            (progn
              (funcall callback argument)
              t)
          (error (condition)
            (%record-log-error provider condition argument processor)
            nil)))))

(defun %call-log-provider-callback (provider callback)
  (if (null callback)
      t
      (handler-case
          (progn
            (funcall callback provider)
            t)
        (error (condition)
          (%record-log-error provider condition provider)
          nil))))

(defun emit-log-record (logger record)
  "Emit RECORD through LOGGER's processors and provider exporter.

The returned record is detached and is the same object passed to every
processor and the exporter.  Callback failures are isolated and available
through LOG-PROVIDER-LAST-ERROR and configured error handlers."
  (check-type logger logger)
  (check-type record log-record)
  (let* ((provider (%logger-provider logger))
         (processors nil)
         (exporter nil))
    (cl-concurrent-kit:with-lock-held ((%log-provider-lock provider))
      (when (%log-provider-shutdown-p provider)
        (error 'log-provider-shutdown :provider provider))
      (setf processors (copy-list (%log-provider-processors provider))
            exporter (%log-provider-exporter provider)))
    (let ((detached (%copy-log-record record)))
      (dolist (processor processors)
        (%call-log-processor provider processor :on-emit detached))
      (when exporter
        (handler-case
            (funcall exporter detached)
          (error (condition)
            (%record-log-error provider condition detached))))
      detached)))

(defun emit-log (logger &rest option-list)
  "Create and emit a structured log record in LOGGER's scope.

The accepted options are the record fields that describe one emission:
TIMESTAMP, OBSERVED-TIMESTAMP, SEVERITY, SEVERITY-NUMBER, BODY, ATTRIBUTES,
CONTEXT, and EVENT-NAME."
  (check-type logger logger)
  (%parse-keyword-options
   option-list
   '(:timestamp :observed-timestamp :severity :severity-number :body :attributes
     :context :event-name)
   "EMIT-LOG")
  (let ((provider (%logger-provider logger)))
    (emit-log-record
     logger
     (apply #'make-log-record
            (append option-list
                    (list :resource (log-provider-resource provider)
                          :scope-name (logger-name logger)
                          :scope-version (logger-version logger)
                          :scope-schema-url (logger-schema-url logger)))))))

(defun force-flush-log-provider (provider)
  "Run log processor and provider flush callbacks, returning true on success."
  (check-type provider log-provider)
  (let ((processors nil)
        (callback nil)
        (success t)
        (active-p nil))
    (cl-concurrent-kit:with-lock-held ((%log-provider-lock provider))
      (unless (%log-provider-shutdown-p provider)
        (setf active-p t
              processors (copy-list (%log-provider-processors provider))
              callback (%log-provider-flush provider))))
    (when active-p
      (dolist (processor processors)
        (unless (%call-log-processor provider processor :force-flush provider)
          (setf success nil)))
      (unless (%call-log-provider-callback provider callback)
        (setf success nil))
      success)))

(defun shutdown-log-provider (provider)
  "Mark PROVIDER shut down and invoke processor/provider callbacks once."
  (check-type provider log-provider)
  (let ((processors nil)
        (callback nil))
    (cl-concurrent-kit:with-lock-held ((%log-provider-lock provider))
      (unless (%log-provider-shutdown-p provider)
        (setf (%log-provider-shutdown-p provider) t
              processors (copy-list (%log-provider-processors provider))
              callback (%log-provider-shutdown provider))))
    (dolist (processor processors)
      (%call-log-processor provider processor :shutdown provider))
    (when callback
      (%call-log-provider-callback provider callback)))
  provider)
