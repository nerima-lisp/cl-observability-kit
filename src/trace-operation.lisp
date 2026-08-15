#.(progn
    (in-package #:observability-kit)
    nil)

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

(defun %start-span-under-lock
    (provider tracer span-name kind attributes parent-context options)
  "Create a span while PROVIDER's lock is held.

Return the span, whether it records data, and the processor snapshot.  Keeping
the sampler decision and mutable provider reads in this locked helper leaves
START-SPAN responsible only for boundary normalization and continuation of
the lifecycle callbacks."
  (let* ((id-generator (%tracer-provider-id-generator provider))
         (trace-id (%trace-id-for-parent parent-context id-generator))
         (decision (%sampler-decision
                    (%tracer-provider-sampler provider)
                    parent-context span-name kind attributes trace-id))
         (recording-p (not (eq decision :drop)))
         (sampled-p (eq decision :record-and-sample))
         (span-id (%generate-trace-id id-generator 16))
         (start-time
           (if (%option-supplied-p options :start-time)
               (%validate-trace-time (%option-value options :start-time nil)
                                     "Span start time")
               (cl-boundary-kit:clock-now (%tracer-provider-clock provider))))
         (start-monotonic
           (cl-boundary-kit:clock-monotonic (%tracer-provider-clock provider)))
         (processors (copy-list (%tracer-provider-span-processors provider)))
         (span
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
            recording-p
            sampled-p
            nil)))
    (values span recording-p processors)))

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
      (multiple-value-setq (span recording-p processors)
        (%start-span-under-lock provider tracer span-name kind attributes
                                parent-context options)))
    (when recording-p
      (dolist (processor processors)
        (%call-span-processor provider processor :on-start span)))
    span))

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
     (mapcar #'%copy-span-event (reverse (%span-events span)))
     (mapcar #'%copy-span-link (reverse (%span-links span)))
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
