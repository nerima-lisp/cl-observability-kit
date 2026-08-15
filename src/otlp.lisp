#.(progn
    (in-package #:observability-kit/otlp)
    nil)

(defun %span-kind-document (kind)
  (string-upcase (symbol-name kind)))

(defun %span-status-document (status message)
  (list (cons "code" (string-upcase (symbol-name status)))
        (cons "message" (observability-kit::%copy-observability-value message))))

(defun %span-event-document (event)
  (list (cons "name" (observability-kit::%copy-observability-value
                      (span-event-name event)))
        (cons "timestamp" (span-event-timestamp event))
        (cons "attributes" (%attributes (span-event-attributes event)))))

(defun %span-link-document (link)
  (let ((context (span-link-context link)))
    (list (cons "trace-id" (observability-kit::%copy-observability-value
                             (instrumentation-context-trace-id context)))
          (cons "span-id" (observability-kit::%copy-observability-value
                            (instrumentation-context-span-id context)))
          (cons "trace-flags" (instrumentation-context-trace-flags context))
          (cons "remote" (instrumentation-context-remote-p context))
          (cons "attributes" (%attributes (span-link-attributes link))))))

(defun %span-record-document (record)
  (list (cons "trace-id" (span-record-trace-id record))
        (cons "span-id" (span-record-span-id record))
        (cons "parent-span-id" (span-record-parent-span-id record))
        (cons "name" (span-record-name record))
        (cons "kind" (%span-kind-document (span-record-kind record)))
        (cons "start-time" (span-record-start-time record))
        (cons "end-time" (span-record-end-time record))
        (cons "duration" (span-record-duration record))
        (cons "status" (%span-status-document (span-record-status record)
                                                (span-record-status-message record)))
        (cons "trace-flags" (span-record-trace-flags record))
        (cons "sampled" (span-record-sampled-p record))
        (cons "recording" (span-record-recording-p record))
        (cons "attributes" (%attributes (span-record-attributes record)))
        (cons "events" (mapcar #'%span-event-document (span-record-events record)))
        (cons "links" (mapcar #'%span-link-document (span-record-links record)))
        (cons "resource" (%resource-document (span-record-resource record)))
        (cons "scope" (%scope-document (span-record-tracer-name record)
                                        (span-record-tracer-version record)
                                        (span-record-tracer-schema-url record)))))

(defun span-record->otlp (record)
  "Return one detached, transport-neutral OTLP-shaped span document."
  (check-type record span-record)
  (%span-record-document record))

(defun %trace-record-before-p (left right)
  (or (string< (span-record-trace-id left) (span-record-trace-id right))
      (and (string= (span-record-trace-id left) (span-record-trace-id right))
           (string< (span-record-span-id left) (span-record-span-id right)))))

(defun %trace-record-list (source)
  (cond
    ((span-record-p source) (list source))
    ((null source) nil)
    ((proper-list-p source)
     (unless (every #'span-record-p source)
       (%otlp-error "OTLP trace source lists must contain span records."))
     (sort (copy-list source) #'%trace-record-before-p))
    (t (%otlp-error
        "OTLP trace source must be a span record or span record list; got ~S."
        source))))

(defun %trace-group-key (record)
  (list (resource-attributes (span-record-resource record))
        (span-record-tracer-name record)
        (span-record-tracer-version record)
        (span-record-tracer-schema-url record)))

(defun %trace-groups (records)
  (let ((groups (make-hash-table :test #'equal)))
    (dolist (record records)
      (let ((key (%trace-group-key record)))
        (push record (gethash key groups))))
    (sort (loop for key being the hash-keys of groups using (hash-value group)
                collect (cons key (nreverse group)))
          #'string< :key (lambda (group) (%group-key-string (car group))))))

(defun %trace-group-document (group)
  (let* ((records (cdr group)) (first-record (first records)))
    (list (cons "resource" (%resource-document (span-record-resource first-record)))
          (cons "scope-spans"
                (list (list
                       (cons "scope" (%scope-document
                                       (span-record-tracer-name first-record)
                                       (span-record-tracer-version first-record)
                                       (span-record-tracer-schema-url first-record)))
                       (cons "spans" (mapcar #'%span-record-document records))))))))

(defun traces->otlp (source)
  "Return a deterministic OTLP-shaped resource-spans document for SOURCE."
  (list (cons "resource-spans"
              (mapcar #'%trace-group-document
                      (%trace-groups (%trace-record-list source))))))

(defun %context-document (context)
  (when context
    (list (cons "trace-id" (observability-kit::%copy-observability-value
                             (instrumentation-context-trace-id context)))
          (cons "span-id" (observability-kit::%copy-observability-value
                            (instrumentation-context-span-id context)))
          (cons "trace-flags" (instrumentation-context-trace-flags context)))))

(defun %log-record-document (record)
  (let ((context (log-record-context record)))
    (list (cons "timestamp" (log-record-timestamp record))
          (cons "observed-timestamp" (log-record-observed-timestamp record))
          (cons "severity-text" (log-record-severity-text record))
          (cons "severity-number" (log-record-severity-number record))
          (cons "body" (observability-kit::%copy-observability-value
                         (log-record-body record)))
          (cons "attributes" (%attributes (log-record-attributes record)))
          (cons "event-name" (log-record-event-name record))
          (cons "context" (%context-document context))
          (cons "resource" (%resource-document (log-record-resource record)))
          (cons "scope" (%scope-document (log-record-scope-name record)
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
    (t (%otlp-error
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
    (sort (loop for key being the hash-keys of groups using (hash-value group)
                collect (cons key (nreverse group)))
          #'string< :key (lambda (group) (%group-key-string (car group))))))

(defun %log-group-document (group)
  (let ((records (cdr group)))
    (list
     (cons "resource"
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
