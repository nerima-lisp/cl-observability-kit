#.(progn
    (in-package #:observability-kit/otlp)
    nil)

(defun %context-document (context)
  (when context
    (list (cons "trace-id"
                (observability-kit::%copy-observability-value
                 (instrumentation-context-trace-id context)))
          (cons "span-id"
                (observability-kit::%copy-observability-value
                 (instrumentation-context-span-id context)))
          (cons "trace-flags"
                (instrumentation-context-trace-flags context)))))

(defun %log-record-document (record)
  (let ((context (log-record-context record)))
    (list (cons "timestamp" (log-record-timestamp record))
          (cons "observed-timestamp"
                (log-record-observed-timestamp record))
          (cons "severity-text" (log-record-severity-text record))
          (cons "severity-number" (log-record-severity-number record))
          (cons "body"
                (observability-kit::%copy-observability-value
                 (log-record-body record)))
          (cons "attributes" (%attributes (log-record-attributes record)))
          (cons "event-name" (log-record-event-name record))
          (cons "context" (%context-document context))
          (cons "resource" (%resource-document (log-record-resource record)))
          (cons "scope"
                (%scope-document (log-record-scope-name record)
                                 (log-record-scope-version record)
                                 (log-record-scope-schema-url record))))))

(defun log-record->otlp (record)
  "Return one detached, transport-neutral OTLP-shaped log record document."
  (check-type record log-record)
  (%log-record-document record))

(defun %log-record-list (source)
  (cond
    ((log-record-p source) (list source))
    ((null source) nil)
    ((proper-list-p source)
     (unless (every #'log-record-p source)
       (%otlp-error "OTLP log source lists must contain log records."))
     (copy-list source))
    (t
     (%otlp-error
      "OTLP log source must be a log record or log record list; got ~S."
      source))))

(defun %log-group-key (record)
  (list (resource-attributes (log-record-resource record))
        (log-record-scope-name record)
        (log-record-scope-version record)
        (log-record-scope-schema-url record)))

(defun %log-groups (records)
  (let ((groups (make-hash-table :test #'equal)))
    (dolist (record records)
      (let ((key (%log-group-key record)))
        (push record (gethash key groups))))
    (sort (loop for key being the hash-keys of groups
                using (hash-value group)
                collect (cons key (nreverse group)))
          #'string<
          :key (lambda (group) (%group-key-string (car group))))))

(defun %log-group-document (group)
  (let ((records (cdr group)))
    (list (cons "resource"
                (%resource-document (log-record-resource (first records))))
          (cons "scope-logs"
                (list
                 (list
                  (cons "scope"
                        (%scope-document
                         (log-record-scope-name (first records))
                         (log-record-scope-version (first records))
                         (log-record-scope-schema-url (first records))))
                  (cons "logs" (mapcar #'%log-record-document records))))))))

(defun logs->otlp (source)
  "Return a deterministic OTLP-shaped resource-logs document for SOURCE."
  (list (cons "resource-logs"
              (mapcar #'%log-group-document
                      (%log-groups (%log-record-list source))))))
