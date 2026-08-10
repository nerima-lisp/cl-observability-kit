#.(progn
    (in-package #:observability-kit)
    nil)

(defun tracer-provider-resource (provider)
  (check-type provider tracer-provider)
  (cl-concurrent-kit:with-lock-held ((%tracer-provider-lock provider))
    (make-resource :attributes
                   (resource-attributes (%tracer-provider-resource provider)))))

(defun tracer-provider-clock (provider)
  (check-type provider tracer-provider)
  (%tracer-provider-clock provider))

(defun tracer-name (tracer)
  (check-type tracer tracer)
  (%copy-observability-value (%tracer-name tracer)))

(defun tracer-version (tracer)
  (check-type tracer tracer)
  (%copy-observability-value (%tracer-version tracer)))

(defun tracer-schema-url (tracer)
  (check-type tracer tracer)
  (%copy-observability-value (%tracer-schema-url tracer)))

(defun %tracer-before-p (left right)
  (or (string< (tracer-name left) (tracer-name right))
      (and (string= (tracer-name left) (tracer-name right))
           (string< (or (tracer-version left) "")
                    (or (tracer-version right) "")))))

(defun tracer-provider-tracers (provider)
  (check-type provider tracer-provider)
  (cl-concurrent-kit:with-lock-held ((%tracer-provider-lock provider))
    (sort (loop for tracer being the hash-values of (%tracer-provider-tracers provider)
                collect tracer)
          #'%tracer-before-p)))

(defun tracer-provider-shutdown-p (provider)
  (check-type provider tracer-provider)
  (cl-concurrent-kit:with-lock-held ((%tracer-provider-lock provider))
    (%tracer-provider-shutdown-p provider)))

(defun tracer-provider-last-export-error (provider)
  (check-type provider tracer-provider)
  (cl-concurrent-kit:with-lock-held ((%tracer-provider-lock provider))
    (%tracer-provider-last-export-error provider)))

(defun tracer-provider-span-processors (provider)
  (check-type provider tracer-provider)
  (cl-concurrent-kit:with-lock-held ((%tracer-provider-lock provider))
    (copy-list (%tracer-provider-span-processors provider))))

(defun span-processor-on-start (processor)
  (check-type processor span-processor)
  (%span-processor-on-start processor))

(defun span-processor-on-end (processor)
  (check-type processor span-processor)
  (%span-processor-on-end processor))

(defun span-processor-force-flush (processor)
  (check-type processor span-processor)
  (%span-processor-force-flush processor))

(defun span-processor-shutdown (processor)
  (check-type processor span-processor)
  (%span-processor-shutdown processor))

(defun span-processor-error-handler (processor)
  (check-type processor span-processor)
  (%span-processor-error-handler processor))

(defun register-span-processor (provider processor)
  "Register PROCESSOR for future spans and return it."
  (check-type provider tracer-provider)
  (check-type processor span-processor)
  (cl-concurrent-kit:with-lock-held ((%tracer-provider-lock provider))
    (when (%tracer-provider-shutdown-p provider)
      (error 'tracer-provider-shutdown :provider provider))
    (setf (%tracer-provider-span-processors provider)
          (append (%tracer-provider-span-processors provider)
                  (list processor))))
  processor)

(defun make-tracer (provider name &rest option-list)
  "Return a cached tracer for NAME, VERSION, and SCHEMA-URL metadata."
  (check-type provider tracer-provider)
  (let* ((options (%parse-keyword-options option-list '(:version :schema-url)
                                          "MAKE-TRACER"))
         (normalized-name (%normalize-span-name name))
         (version (%option-value options :version nil))
         (schema-url (%option-value options :schema-url nil)))
    (dolist (entry (list (cons :version version) (cons :schema-url schema-url)))
      (when (cdr entry)
        (unless (and (stringp (cdr entry)) (<= (length (cdr entry)) 256))
          (error 'tracing-error
                 :message (format nil "Tracer ~A must be a string of at most 256 characters."
                                  (car entry))))))
    (let ((key (list normalized-name version schema-url)))
      (cl-concurrent-kit:with-lock-held ((%tracer-provider-lock provider))
        (when (%tracer-provider-shutdown-p provider)
          (error 'tracer-provider-shutdown :provider provider))
        (or (gethash key (%tracer-provider-tracers provider))
            (setf (gethash key (%tracer-provider-tracers provider))
                  (%make-tracer provider normalized-name
                                (%copy-observability-value version)
                                (%copy-observability-value schema-url))))))))

(defun %parent-context (parent)
  (cond
    ((eq parent :current)
     (capture-instrumentation-context))
    ((null parent) nil)
    ((span-p parent) (span-context parent))
    ((instrumentation-context-p parent)
     (capture-instrumentation-context parent))
    (t
     (error 'tracing-error
            :message (format nil
                             "SPAN parent must be :CURRENT, NIL, a span, or an instrumentation context; got ~S."
                             parent)))))

(defun %context-trace-id (context)
  (and context (%instrumentation-context-trace-id context)))

(defun %context-span-id (context)
  (and context (%instrumentation-context-span-id context)))

(defun %context-trace-flags (context)
  (and context (%instrumentation-context-trace-flags context)))

(defun %context-attributes (context)
  (if context
      (%copy-alist (%instrumentation-context-attributes context))
      nil))

(defun %context-baggage (context)
  (if context
      (%copy-alist (%instrumentation-context-baggage context))
      nil))

(defun %context-tracestate (context)
  (and context
       (%copy-observability-value
        (%instrumentation-context-tracestate context))))

(defun %trace-id-for-parent (parent-context id-generator)
  (or (%context-trace-id parent-context)
      (%generate-trace-id id-generator 32)))

(defun %span-flags (parent-context sampled-p)
  (let ((flags (or (%context-trace-flags parent-context) 0)))
    (if sampled-p
        (logior flags 1)
        (logand flags #xfe))))

(defun %record-span-processor-error (provider processor condition argument)
  (let ((processor-handler nil)
        (provider-handler nil))
    (cl-concurrent-kit:with-lock-held ((%tracer-provider-lock provider))
      (setf (%tracer-provider-last-export-error provider) condition
            processor-handler (%span-processor-error-handler processor)
            provider-handler (%tracer-provider-export-error-handler provider)))
    (when processor-handler
      (handler-case
          (funcall processor-handler condition argument)
        (error () nil)))
    (when provider-handler
      (handler-case
          (funcall provider-handler condition argument)
        (error () nil)))))

(defun %call-span-processor (provider processor phase argument)
  (let ((callback
          (ecase phase
            (:on-start (%span-processor-on-start processor))
            (:on-end (%span-processor-on-end processor))
            (:force-flush (%span-processor-force-flush processor))
            (:shutdown (%span-processor-shutdown processor)))))
    (if (null callback)
        t
        (handler-case
            (progn
              (funcall callback argument)
              t)
          (error (condition)
            (%record-span-processor-error provider processor condition argument)
            nil)))))

(defun start-span (tracer name &rest option-list)
  "Start a span and return it.

PARENT defaults to :CURRENT, NIL creates a root span, and a span or
instrumentation context may be supplied explicitly.  SAMPLER decisions are
made by the provider; a dropped span still carries a valid context but does
not retain data or invoke the exporter."
  (check-type tracer tracer)
  (let* ((options (%parse-keyword-options
                   option-list '(:parent :kind :attributes :start-time)
                   "START-SPAN"))
         (parent (%option-value options :parent :current))
         (parent-context (%parent-context parent))
         (span-name (%normalize-span-name name))
         (kind (%normalize-span-kind (%option-value options :kind :internal)))
         (attributes (%normalize-attributes (%option-value options :attributes nil)))
         (provider (%tracer-provider tracer))
         (span nil)
         (recording-p nil)
         (processors nil))
    (cl-concurrent-kit:with-lock-held ((%tracer-provider-lock provider))
      (when (%tracer-provider-shutdown-p provider)
        (error 'tracer-provider-shutdown :provider provider))
      (let* ((id-generator (%tracer-provider-id-generator provider))
             (trace-id (%trace-id-for-parent parent-context id-generator))
             (decision (%sampler-decision
                        (%tracer-provider-sampler provider)
                        parent-context span-name kind attributes trace-id))
             (current-recording-p (not (eq decision :drop)))
             (sampled-p (eq decision :record-and-sample))
             (span-id (%generate-trace-id id-generator 16))
             (start-time
               (if (%option-supplied-p options :start-time)
                   (%validate-trace-time (%option-value options :start-time nil)
                                         "Span start time")
                   (cl-boundary-kit:clock-now (%tracer-provider-clock provider))))
             (start-monotonic
               (cl-boundary-kit:clock-monotonic (%tracer-provider-clock provider))))
        (setf recording-p current-recording-p
              processors (copy-list (%tracer-provider-span-processors provider))
              span
              (%make-span
               (cl-concurrent-kit:make-lock :name "observability-span")
               provider
               tracer
               span-name
               kind
               trace-id
               span-id
               (%context-span-id parent-context)
               (%span-flags parent-context sampled-p)
               (%context-attributes parent-context)
               (%context-baggage parent-context)
               (%context-tracestate parent-context)
               start-time
               start-monotonic
               nil
               nil
               :unset
               nil
               attributes
               nil
               nil
               current-recording-p
               sampled-p
               nil))))
    (when recording-p
      (dolist (processor processors)
        (%call-span-processor provider processor :on-start span)))
    span))

(defun span-name (span)
  (check-type span span)
  (%copy-observability-value (%span-name span)))

(defun span-kind (span)
  (check-type span span)
  (%span-kind span))

(defun span-trace-id (span)
  (check-type span span)
  (%copy-observability-value (%span-trace-id span)))

(defun span-id (span)
  (check-type span span)
  (%copy-observability-value (%span-span-id span)))

(defun span-parent-span-id (span)
  (check-type span span)
  (%copy-observability-value (%span-parent-span-id span)))

(defun span-trace-flags (span)
  (check-type span span)
  (%span-trace-flags span))

(defun span-start-time (span)
  (check-type span span)
  (%span-start-time span))

(defun span-end-time (span)
  (check-type span span)
  (%span-end-time span))

(defun span-duration (span)
  (check-type span span)
  (cl-concurrent-kit:with-lock-held ((%span-lock span))
    (when (%span-end-monotonic span)
      (/ (- (%span-end-monotonic span) (%span-start-monotonic span))
         (%tracer-provider-monotonic-units-per-second (%span-provider span))))))

(defun span-status (span)
  (check-type span span)
  (%span-status span))

(defun span-status-message (span)
  (check-type span span)
  (%copy-observability-value (%span-status-message span)))

(defun span-recording-p (span)
  (check-type span span)
  (%span-recording-p span))

(defun span-sampled-p (span)
  (check-type span span)
  (%span-sampled-p span))

(defun span-ended-p (span)
  (check-type span span)
  (cl-concurrent-kit:with-lock-held ((%span-lock span))
    (%span-ended-p span)))

(defun span-context (span)
  "Return the detached propagation context represented by SPAN."
  (check-type span span)
  (%make-instrumentation-context
   (%span-trace-id span)
   (%span-span-id span)
   (%span-trace-flags span)
   (%copy-alist (%span-context-attributes span))
   (%copy-alist (%span-baggage span))
   (%span-tracestate span)))

(defun span-attributes (span)
  (check-type span span)
  (cl-concurrent-kit:with-lock-held ((%span-lock span))
    (%copy-alist (%span-attributes span))))

(defun %ensure-span-open (span operation)
  (when (%span-ended-p span)
    (error 'span-operation-error :span span :operation operation
           :message (format nil "Cannot ~A an ended span." operation))))

(defun span-update-name (span name)
  "Update SPAN's name while it is open and return SPAN.

Non-recording spans accept the operation as a no-op after validation."
  (check-type span span)
  (let ((normalized (%normalize-span-name name)))
    (cl-concurrent-kit:with-lock-held ((%span-lock span))
      (%ensure-span-open span "update its name")
      (when (%span-recording-p span)
        (setf (%span-name span) normalized))))
  span)

(defun %set-span-attribute (span name value &key allow-sensitive-names)
  (check-type span span)
  (let* ((normalized (%validate-attribute-name
                      name
                      :allow-sensitive-names allow-sensitive-names))
         (normalized-value (car (%normalize-attributes
                                (list (cons normalized value))
                                :allow-sensitive-names allow-sensitive-names))))
    (cl-concurrent-kit:with-lock-held ((%span-lock span))
      (%ensure-span-open span "set an attribute")
      (when (%span-recording-p span)
        (setf (%span-attributes span)
              (cons normalized-value
                    (remove normalized (%span-attributes span)
                            :key #'car :test #'string=))))))
  span)

(defun span-set-attribute (span name value)
  "Set one validated attribute on SPAN and return SPAN.

Non-recording spans accept the operation as a no-op after validation."
  (%set-span-attribute span name value))

(defun span-event-name (event)
  (check-type event span-event)
  (%copy-observability-value (%span-event-name event)))

(defun span-event-timestamp (event)
  (check-type event span-event)
  (%span-event-timestamp event))

(defun span-event-attributes (event)
  (check-type event span-event)
  (%copy-alist (%span-event-attributes event)))

(defun %copy-span-event (event)
  (%make-span-event (span-event-name event)
                    (span-event-timestamp event)
                    (span-event-attributes event)))

(defun span-events (span)
  (check-type span span)
  (cl-concurrent-kit:with-lock-held ((%span-lock span))
    (mapcar #'%copy-span-event (reverse (%span-events span)))))

(defun span-add-event (span name &rest option-list)
  "Append an event to SPAN in timestamp order."
  (check-type span span)
  (let* ((options (%parse-keyword-options option-list '(:attributes :timestamp)
                                          "SPAN-ADD-EVENT"))
         (normalized-name (%normalize-span-name name))
         (attributes (%normalize-attributes (%option-value options :attributes nil))))
    (cl-concurrent-kit:with-lock-held ((%span-lock span))
      (%ensure-span-open span "add an event")
      (when (%span-recording-p span)
        (let ((timestamp
                (if (%option-supplied-p options :timestamp)
                    (%validate-trace-time (%option-value options :timestamp nil)
                                          "Span event timestamp")
                    (cl-boundary-kit:clock-now (%tracer-provider-clock
                                                (%span-provider span))))))
          (push (%make-span-event normalized-name timestamp attributes)
                (%span-events span)))))
  span))

(defun %context-for-link (context)
  (cond
    ((span-p context) (span-context context))
    ((instrumentation-context-p context) (capture-instrumentation-context context))
    (t
     (error 'tracing-error
            :message "Span links require a span or instrumentation context."))))

(defun span-link-context (link)
  (check-type link span-link)
  (capture-instrumentation-context (%span-link-context link)))

(defun span-link-attributes (link)
  (check-type link span-link)
  (%copy-alist (%span-link-attributes link)))

(defun %copy-span-link (link)
  (%make-span-link (span-link-context link)
                   (span-link-attributes link)))

(defun span-links (span)
  (check-type span span)
  (cl-concurrent-kit:with-lock-held ((%span-lock span))
    (mapcar #'%copy-span-link (reverse (%span-links span)))))

(defun span-add-link (span context &rest option-list)
  "Append a link to another span or detached instrumentation context."
  (check-type span span)
  (let* ((options (%parse-keyword-options option-list '(:attributes)
                                          "SPAN-ADD-LINK"))
         (linked-context (%context-for-link context))
         (attributes (%normalize-attributes (%option-value options :attributes nil))))
    (cl-concurrent-kit:with-lock-held ((%span-lock span))
      (%ensure-span-open span "add a link")
      (when (%span-recording-p span)
        (push (%make-span-link linked-context attributes) (%span-links span)))))
  span)

(defun span-set-status (span status &rest option-list)
  "Set SPAN status to :UNSET, :OK, or :ERROR and return SPAN."
  (check-type span span)
  (let* ((options (%parse-keyword-options option-list '(:message)
                                          "SPAN-SET-STATUS"))
         (normalized (%normalize-span-status status))
         (message (%normalize-span-status-message
                   (%option-value options :message nil))))
    (cl-concurrent-kit:with-lock-held ((%span-lock span))
      (%ensure-span-open span "set status")
      (when (%span-recording-p span)
        (setf (%span-status span) normalized
              (%span-status-message span) message))))
  span)

(defun span-record-exception (span condition &rest option-list)
  "Record CONDITION as an exception event and mark SPAN as :ERROR."
  (check-type span span)
  (check-type condition condition)
  (let* ((options (%parse-keyword-options option-list '(:timestamp)
                                          "SPAN-RECORD-EXCEPTION"))
         (type (string-downcase (symbol-name (type-of condition))))
         (message (princ-to-string condition))
         (message (if (> (length message) 1024)
                      (subseq message 0 1024)
                      message)))
    (span-set-status span :error :message message)
    (span-add-event span "exception"
                    :timestamp (if (%option-supplied-p options :timestamp)
                                   (%option-value options :timestamp nil)
                                   (cl-boundary-kit:clock-now
                                    (%tracer-provider-clock (%span-provider span))))
                    :attributes (list (cons "exception.type" type)
                                      (cons "exception.message" message))))
  span)

(defun %copy-span-record-event (event)
  (%copy-span-event event))

(defun %copy-span-record-link (link)
  (%copy-span-link link))

(defun %make-span-record-from-span (span end-time end-monotonic status message)
  (let* ((provider (%span-provider span))
         (tracer (%span-tracer span))
         (duration (/ (- end-monotonic (%span-start-monotonic span))
                      (%tracer-provider-monotonic-units-per-second provider))))
    (%make-span-record
     (%span-trace-id span)
     (%span-span-id span)
     (%span-parent-span-id span)
     (%span-name span)
     (%span-kind span)
     (%span-start-time span)
     end-time
     (max 0 duration)
     status
     message
     (%span-trace-flags span)
     (%span-sampled-p span)
     (%span-recording-p span)
     (%copy-alist (%span-attributes span))
     (mapcar #'%copy-span-record-event (reverse (%span-events span)))
     (mapcar #'%copy-span-record-link (reverse (%span-links span)))
     (tracer-provider-resource provider)
     (tracer-name tracer)
     (tracer-version tracer)
     (tracer-schema-url tracer))))

(defun %record-export-error (provider condition record)
  (let ((handler nil))
    (cl-concurrent-kit:with-lock-held ((%tracer-provider-lock provider))
      (setf (%tracer-provider-last-export-error provider) condition
            handler (%tracer-provider-export-error-handler provider)))
    (when handler
      (handler-case
          (funcall handler condition record)
        (error () nil)))))

(defun end-span (span &rest option-list)
  "End SPAN once and invoke its provider exporter when it was sampled.

Repeated END-SPAN calls are idempotent.  Exporter failures do not escape the
instrumented operation; inspect TRACER-PROVIDER-LAST-EXPORT-ERROR or supply
an EXPORT-ERROR-HANDLER to observe them."
  (check-type span span)
  (let* ((options (%parse-keyword-options
                   option-list '(:end-time :status :status-message)
         "END-SPAN"))
         (record nil)
         (processors nil)
         (exporter nil)
         (provider (%span-provider span)))
    (cl-concurrent-kit:with-lock-held ((%span-lock span))
      (unless (%span-ended-p span)
        (let* ((end-time
                 (if (%option-supplied-p options :end-time)
                     (%validate-trace-time (%option-value options :end-time nil)
                                           "Span end time")
                     (cl-boundary-kit:clock-now (%tracer-provider-clock provider))))
               (end-monotonic (cl-boundary-kit:clock-monotonic
                               (%tracer-provider-clock provider)))
               (status (if (%option-supplied-p options :status)
                           (%normalize-span-status (%option-value options :status nil))
                           (%span-status span)))
               (status-message
                 (if (%option-supplied-p options :status-message)
                     (%normalize-span-status-message
                      (%option-value options :status-message nil))
                     (%span-status-message span))))
          (setf (%span-end-time span) end-time
                (%span-end-monotonic span) end-monotonic
                (%span-status span) status
                (%span-status-message span) status-message
                (%span-ended-p span) t)
          (when (%span-recording-p span)
            (setf record (%make-span-record-from-span
                          span end-time end-monotonic status status-message)
                exporter (%tracer-provider-exporter provider)))))
    (when record
      (setf processors (tracer-provider-span-processors provider))
      (dolist (processor processors)
        (%call-span-processor provider processor :on-end record)))
    (when (and record exporter (span-record-sampled-p record))
      (handler-case
          (funcall exporter record)
        (error (condition)
          (%record-export-error provider condition record))))
    span)))

(defun %call-provider-callback (provider callback)
  (when callback
    (handler-case
        (progn
          (funcall callback provider)
          t)
      (error (condition)
        (%record-export-error provider condition nil)
        nil))))

(defun force-flush-tracer-provider (provider)
  "Run span processor and provider flush callbacks, returning true on success."
  (check-type provider tracer-provider)
  (let ((processors nil)
        (callback nil)
        (success t)
        (active-p nil))
    (cl-concurrent-kit:with-lock-held ((%tracer-provider-lock provider))
      (unless (%tracer-provider-shutdown-p provider)
        (setf active-p t
              processors (copy-list (%tracer-provider-span-processors provider))
              callback (%tracer-provider-flush provider))))
    (when active-p
      (dolist (processor processors)
        (unless (%call-span-processor provider processor :force-flush provider)
          (setf success nil)))
      (unless (or (null callback)
                  (%call-provider-callback provider callback))
        (setf success nil))
      success)))

(defun shutdown-tracer-provider (provider)
  "Mark PROVIDER shut down and invoke processor and provider callbacks once."
  (check-type provider tracer-provider)
  (let ((processors nil)
        (callback nil))
    (cl-concurrent-kit:with-lock-held ((%tracer-provider-lock provider))
      (unless (%tracer-provider-shutdown-p provider)
        (setf (%tracer-provider-shutdown-p provider) t
              processors (copy-list (%tracer-provider-span-processors provider))
              callback (%tracer-provider-shutdown provider))))
    (dolist (processor processors)
      (%call-span-processor provider processor :shutdown provider))
    (when callback
      (%call-provider-callback provider callback)))
  provider)

(defun current-span (&optional default)
  "Return the dynamically scoped span, or DEFAULT when none is active."
  (or *current-span* default))

(defun call-with-span (span function)
  "Call FUNCTION with SPAN and its propagation context dynamically bound."
  (check-type span span)
  (check-type function function)
  (let ((*current-span* span)
        (*instrumentation-context* (span-context span)))
    (funcall function span)))

;;; Public readers for detached span records.
(defun span-record-trace-id (record)
  (check-type record span-record)
  (%copy-observability-value (%span-record-trace-id record)))

(defun span-record-span-id (record)
  (check-type record span-record)
  (%copy-observability-value (%span-record-span-id record)))

(defun span-record-parent-span-id (record)
  (check-type record span-record)
  (%copy-observability-value (%span-record-parent-span-id record)))

(defun span-record-name (record)
  (check-type record span-record)
  (%copy-observability-value (%span-record-name record)))

(defun span-record-kind (record)
  (check-type record span-record)
  (%span-record-kind record))

(defun span-record-start-time (record)
  (check-type record span-record)
  (%span-record-start-time record))

(defun span-record-end-time (record)
  (check-type record span-record)
  (%span-record-end-time record))

(defun span-record-duration (record)
  (check-type record span-record)
  (%span-record-duration record))

(defun span-record-status (record)
  (check-type record span-record)
  (%span-record-status record))

(defun span-record-status-message (record)
  (check-type record span-record)
  (%copy-observability-value (%span-record-status-message record)))

(defun span-record-trace-flags (record)
  (check-type record span-record)
  (%span-record-trace-flags record))

(defun span-record-sampled-p (record)
  (check-type record span-record)
  (%span-record-sampled-p record))

(defun span-record-recording-p (record)
  (check-type record span-record)
  (%span-record-recording-p record))

(defun span-record-attributes (record)
  (check-type record span-record)
  (%copy-alist (%span-record-attributes record)))

(defun span-record-events (record)
  (check-type record span-record)
  (mapcar #'%copy-span-record-event (%span-record-events record)))

(defun span-record-links (record)
  (check-type record span-record)
  (mapcar #'%copy-span-record-link (%span-record-links record)))

(defun span-record-resource (record)
  (check-type record span-record)
  (make-resource :attributes
                 (resource-attributes (%span-record-resource record))))

(defun span-record-tracer-name (record)
  (check-type record span-record)
  (%copy-observability-value (%span-record-tracer-name record)))

(defun span-record-tracer-version (record)
  (check-type record span-record)
  (%copy-observability-value (%span-record-tracer-version record)))

(defun span-record-tracer-schema-url (record)
  (check-type record span-record)
  (%copy-observability-value (%span-record-tracer-schema-url record)))
