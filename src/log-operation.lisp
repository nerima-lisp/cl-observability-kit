#.(progn
    (in-package #:observability-kit)
    nil)

(defun %normalize-log-severity (severity)
  (let* ((name (%designator-string severity))
         (keyword (and name (intern (string-upcase name) :keyword)))
         (entry (assoc keyword *log-severity-levels* :test #'eq)))
    (unless entry
      (error 'invalid-log-severity
             :severity severity
             :message (format nil
                              "Log severity must be TRACE, DEBUG, INFO, WARN, ERROR, or FATAL; got ~S."
                              severity)))
    (values keyword (second entry) (cddr entry))))

(defun %validate-log-severity-number (number)
  (when number
    (unless (and (integerp number) (<= 1 number 24))
      (error 'logging-error
             :message (format nil
                              "Log severity number must be an integer from 1 through 24, got ~S."
                              number))))
  number)

(defun %validate-log-timestamp (timestamp)
  (unless (and (realp timestamp) (%finite-real-p timestamp))
    (error 'logging-error
           :message (format nil
                            "Log timestamp must be a finite real number, got ~S."
                            timestamp)))
  timestamp)

(defun %normalize-log-body (body)
  (unless (or (null body) (stringp body) (numberp body)
              (keywordp body) (symbolp body))
    (error 'logging-error
           :message (format nil
                            "Log body has an unsupported value type: ~S."
                            body)))
  (%copy-observability-value body))

(defun %normalize-log-scope-value (value what)
  (when value
    (unless (and (stringp value) (plusp (length value)) (<= (length value) 256))
      (error 'logging-error
             :message (format nil
                              "~A must be a non-empty string of at most 256 characters."
                              what))))
  (%copy-observability-value value))

(defun %log-context-option (options)
  (if (%option-supplied-p options :context)
      (let ((context (%option-value options :context nil)))
        (when context
          (check-type context instrumentation-context))
        (capture-instrumentation-context context))
      (capture-instrumentation-context)))

(defun make-log-record (&rest option-list)
  "Create a detached structured log record.

The default CONTEXT is the currently bound instrumentation context; pass
`:context NIL` to make an explicitly uncorrelated record.  The returned
record, its attributes, context, and resource are detached copies suitable
for retaining until an exporter or adapter consumes them."
  (let* ((options (%parse-keyword-options
                   option-list
                   '(:timestamp :severity :severity-number :body :attributes
                     :context :resource :scope-name :scope-version
                     :scope-schema-url)
                   "MAKE-LOG-RECORD"))
         (timestamp (%validate-log-timestamp
                     (if (%option-supplied-p options :timestamp)
                         (%option-value options :timestamp nil)
                         (get-universal-time))))
         (severity (%option-value options :severity :info))
         (severity-number-option
           (%validate-log-severity-number
            (%option-value options :severity-number nil)))
         (attributes (%normalize-attributes
                      (%option-value options :attributes nil)))
         (resource (%option-value options :resource (make-resource)))
         (scope-name (%normalize-log-scope-value
                      (%option-value options :scope-name nil)
                      "LOG scope name"))
         (scope-version (%normalize-log-scope-value
                         (%option-value options :scope-version nil)
                         "LOG scope version"))
         (scope-schema-url (%normalize-log-scope-value
                            (%option-value options :scope-schema-url nil)
                            "LOG scope schema URL")))
    (multiple-value-bind (normalized-severity severity-text default-number)
        (%normalize-log-severity severity)
      (check-type resource resource)
      (%make-log-record
       timestamp
       normalized-severity
       severity-text
       (or severity-number-option default-number)
       (%normalize-log-body (%option-value options :body nil))
       attributes
       (%log-context-option options)
       (make-resource :attributes (resource-attributes resource))
       scope-name
       scope-version
       scope-schema-url))))

(defun log-record-timestamp (record)
  (check-type record log-record)
  (%log-record-timestamp record))

(defun log-record-severity (record)
  (check-type record log-record)
  (%log-record-severity record))

(defun log-record-severity-text (record)
  (check-type record log-record)
  (%copy-observability-value (%log-record-severity-text record)))

(defun log-record-severity-number (record)
  (check-type record log-record)
  (%log-record-severity-number record))

(defun log-record-body (record)
  (check-type record log-record)
  (%copy-observability-value (%log-record-body record)))

(defun log-record-attributes (record)
  (check-type record log-record)
  (%copy-alist (%log-record-attributes record)))

(defun log-record-context (record)
  (check-type record log-record)
  (capture-instrumentation-context (%log-record-context record)))

(defun log-record-resource (record)
  (check-type record log-record)
  (make-resource :attributes
                 (resource-attributes (%log-record-resource record))))

(defun log-record-scope-name (record)
  (check-type record log-record)
  (%copy-observability-value (%log-record-scope-name record)))

(defun log-record-scope-version (record)
  (check-type record log-record)
  (%copy-observability-value (%log-record-scope-version record)))

(defun log-record-scope-schema-url (record)
  (check-type record log-record)
  (%copy-observability-value (%log-record-scope-schema-url record)))
