#.(progn
    (in-package #:observability-kit/otlp)
    nil)

(defun %otlp-error (format-control &rest arguments)
  (error 'observability-error
         :message (apply #'format nil format-control arguments)))

(defun %snapshot-list (source)
  (cond
    ((metric-snapshot-p source) (list source))
    ((metric-p source) (list (metric-snapshot source)))
    ((metric-registry-p source) (metric-snapshot source))
    ((null source) nil)
    ((proper-list-p source)
     (unless (every #'metric-snapshot-p source)
       (%otlp-error "OTLP source lists must contain metric snapshots."))
     (sort (copy-list source)
           #'string<
           :key #'observability-kit::%metric-snapshot-name))
    (t
     (%otlp-error
      "OTLP source must be a metric, registry, snapshot, or snapshot list; got ~S."
      source))))

(defun %attributes (labels)
  (mapcar (lambda (pair)
            (list (cons "key"
                        (observability-kit::%copy-observability-value
                         (car pair)))
                  (cons "value"
                        (observability-kit::%copy-observability-value
                         (cdr pair)))))
          labels))

(defun %data-point (sample &key value count sum)
  (let ((data-point
          (list (cons "attributes"
                      (%attributes
                       (observability-kit::%metric-sample-labels sample))))))
    (when (not (null value))
      (push (cons "value" value) data-point))
    (when (not (null count))
      (push (cons "count" count) data-point))
    (when (not (null sum))
      (push (cons "sum" sum) data-point))
    (nreverse data-point)))

(defun %histogram-components (buckets)
  (let ((previous 0)
        (bounds nil)
        (counts nil))
    (dolist (bucket buckets)
      (let ((boundary (car bucket))
            (cumulative (cdr bucket)))
        (unless (eq boundary +infinity+)
          (push boundary bounds))
        (push (- cumulative previous) counts)
        (setf previous cumulative)))
    (values (nreverse bounds)
            (nreverse counts))))

(defun %histogram-data-point (sample)
  (multiple-value-bind (bounds counts)
      (%histogram-components
       (observability-kit::%metric-sample-buckets sample))
    (let ((data-point
            (list (cons "attributes"
                        (%attributes
                         (observability-kit::%metric-sample-labels sample))))))
      (push (cons "count"
                  (observability-kit::%metric-sample-count sample))
            data-point)
      (push (cons "sum"
                  (observability-kit::%metric-sample-sum sample))
            data-point)
      (push (cons "explicit-bounds" bounds) data-point)
      (push (cons "bucket-counts" counts) data-point)
      (nreverse data-point))))

(defun %metric-data (snapshot)
  (let ((type (observability-kit::%metric-snapshot-type snapshot))
        (samples (observability-kit::%metric-snapshot-samples snapshot)))
    (case type
      (:counter
       (list (cons "type" "sum")
             (cons "aggregation-temporality" "cumulative")
             (cons "is-monotonic" t)
             (cons "data-points"
                   (mapcar (lambda (sample)
                             (%data-point
                              sample
                              :value
                              (observability-kit::%metric-sample-value sample)))
                           samples))))
      (:gauge
       (list (cons "type" "gauge")
             (cons "data-points"
                   (mapcar (lambda (sample)
                             (%data-point
                              sample
                              :value
                              (observability-kit::%metric-sample-value sample)))
                           samples))))
      (:histogram
       (list (cons "type" "histogram")
             (cons "aggregation-temporality" "cumulative")
             (cons "data-points"
                   (mapcar #'%histogram-data-point samples))))
      (otherwise
       (%otlp-error "Unsupported metric snapshot type ~S." type)))))

(defun metric-snapshot->otlp (snapshot)
  "Return one deterministic, transport-neutral OTLP-shaped metric alist.

The returned Common Lisp numbers are the exact values from SNAPSHOT.  This
function deliberately does not serialize JSON or coerce rationals to
double-floats; a transport adapter can choose the wire representation at its
boundary.  HISTOGRAM bucket counts are converted from the cumulative counts
used by the core snapshot to OTLP's per-bucket counts."
  (check-type snapshot metric-snapshot)
  (append
   (list (cons "name"
               (observability-kit::%copy-observability-value
                (observability-kit::%metric-snapshot-name snapshot)))
         (cons "description"
               (observability-kit::%copy-observability-value
                (observability-kit::%metric-snapshot-help snapshot)))
         (cons "unit"
               (or (observability-kit::%copy-observability-value
                    (observability-kit::%metric-snapshot-unit snapshot))
                   "")))
          (%metric-data snapshot)))

(defun snapshot->otlp (source)
  "Alias for METRIC-SNAPSHOT->OTLP accepting a metric or snapshot source."
  (cond
    ((metric-snapshot-p source) (metric-snapshot->otlp source))
    ((metric-p source) (metric-snapshot->otlp (metric-snapshot source)))
    (t
     (%otlp-error "SNAPSHOT->OTLP expects a metric snapshot or metric; got ~S."
                  source))))

(defun registry->otlp (source &key scope-name scope-version)
  "Return a deterministic OTLP-shaped scope document for SOURCE.

SOURCE may be a registry, metric, snapshot, or snapshot list.  SCOPE-NAME and
SCOPE-VERSION are metadata only; resource ownership and network export remain
with the application or another optional integration."
  (let ((scope
          (remove nil
                  (list (and scope-name (cons "name" scope-name))
                        (and scope-version (cons "version" scope-version))))))
    (unless (every (lambda (pair) (stringp (cdr pair)))
                   scope)
      (%otlp-error "OTLP scope metadata must contain string values."))
    (list (cons "scope" scope)
          (cons "metrics"
                (mapcar #'metric-snapshot->otlp (%snapshot-list source))))))

(defun %scope-document (name version schema-url)
  (remove nil
          (list (and name (cons "name"
                                (observability-kit::%copy-observability-value name)))
                (and version (cons "version"
                                   (observability-kit::%copy-observability-value
                                    version)))
                (and schema-url (cons "schema-url"
                                      (observability-kit::%copy-observability-value
                                       schema-url))))))

(defun %resource-document (resource)
  (list (cons "attributes" (%attributes (resource-attributes resource)))))

(defun %span-kind-document (kind)
  (string-upcase (symbol-name kind)))

(defun %span-status-document (status message)
  (list (cons "code" (string-upcase (symbol-name status)))
        (cons "message"
              (observability-kit::%copy-observability-value message))))

(defun %span-event-document (event)
  (list (cons "name"
              (observability-kit::%copy-observability-value
               (span-event-name event)))
        (cons "timestamp" (span-event-timestamp event))
        (cons "attributes" (%attributes (span-event-attributes event)))))

(defun %span-link-document (link)
  (let ((context (span-link-context link)))
    (list (cons "trace-id"
                (observability-kit::%copy-observability-value
                 (instrumentation-context-trace-id context)))
          (cons "span-id"
                (observability-kit::%copy-observability-value
                 (instrumentation-context-span-id context)))
          (cons "trace-flags"
                (instrumentation-context-trace-flags context))
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
        (cons "status"
              (%span-status-document (span-record-status record)
                                      (span-record-status-message record)))
        (cons "trace-flags" (span-record-trace-flags record))
        (cons "sampled" (span-record-sampled-p record))
        (cons "recording" (span-record-recording-p record))
        (cons "attributes" (%attributes (span-record-attributes record)))
        (cons "events" (mapcar #'%span-event-document
                               (span-record-events record)))
        (cons "links" (mapcar #'%span-link-document
                              (span-record-links record)))
        (cons "resource" (%resource-document (span-record-resource record)))
        (cons "scope"
              (%scope-document (span-record-tracer-name record)
                               (span-record-tracer-version record)
                               (span-record-tracer-schema-url record)))))

(defun span-record->otlp (record)
  "Return one detached, transport-neutral OTLP-shaped span document.

Times and durations retain the exact Common Lisp values held by RECORD.  No
wire-unit conversion or serialization is performed at this boundary."
  (check-type record span-record)
  (%span-record-document record))

(defun %trace-record-before-p (left right)
  (or (string< (span-record-trace-id left)
               (span-record-trace-id right))
      (and (string= (span-record-trace-id left)
                    (span-record-trace-id right))
           (string< (span-record-span-id left)
                    (span-record-span-id right)))))

(defun %trace-record-list (source)
  (cond
    ((span-record-p source) (list source))
    ((null source) nil)
    ((proper-list-p source)
     (unless (every #'span-record-p source)
       (%otlp-error "OTLP trace source lists must contain span records."))
     (sort (copy-list source) #'%trace-record-before-p))
    (t
     (%otlp-error
      "OTLP trace source must be a span record or span record list; got ~S."
      source))))

(defun %trace-group-key (record)
  (list (resource-attributes (span-record-resource record))
        (span-record-tracer-name record)
        (span-record-tracer-version record)
        (span-record-tracer-schema-url record)))

(defun %group-key-string (key)
  (with-output-to-string (stream)
    (write key :stream stream :readably t)))

(defun %trace-groups (records)
  (let ((groups (make-hash-table :test #'equal)))
    (dolist (record records)
      (let ((key (%trace-group-key record)))
        (push record (gethash key groups))))
    (sort (loop for key being the hash-keys of groups
                using (hash-value group)
                collect (cons key (nreverse group)))
          #'string<
          :key (lambda (group) (%group-key-string (car group))))))

(defun %trace-group-document (group)
  (let* ((key (car group))
         (records (cdr group))
         (first-record (first records)))
    (list (cons "resource"
                (%resource-document (span-record-resource first-record)))
          (cons "scope-spans"
                (list
                 (list
                  (cons "scope"
                        (%scope-document
                         (span-record-tracer-name first-record)
                         (span-record-tracer-version first-record)
                         (span-record-tracer-schema-url first-record)))
                  (cons "spans" (mapcar #'%span-record-document records))))))))

(defun traces->otlp (source)
  "Return a deterministic OTLP-shaped resource-spans document for SOURCE.

SOURCE may be one span record, NIL, or a proper list of span records.  Records
are grouped by resource and instrumentation scope and sorted by trace and
span identifier.  The result is detached and transport-neutral."
  (list (cons "resource-spans"
              (mapcar #'%trace-group-document
                      (%trace-groups (%trace-record-list source))))))

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
          (cons "severity-text" (log-record-severity-text record))
          (cons "severity-number" (log-record-severity-number record))
          (cons "body"
                (observability-kit::%copy-observability-value
                 (log-record-body record)))
          (cons "attributes" (%attributes (log-record-attributes record)))
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
