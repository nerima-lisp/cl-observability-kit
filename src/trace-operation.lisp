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

(defun %start-span-under-lock (provider tracer span-name kind attributes
                                parent-context options)
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
           (cl-boundary-kit:clock-monotonic (%tracer-provider-clock provider))))
    (values
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
      nil)
     recording-p
     (copy-list (%tracer-provider-span-processors provider)))))

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
         (provider (%tracer-provider tracer)))
    (multiple-value-bind (span recording-p processors)
        (cl-concurrent-kit:with-lock-held ((%tracer-provider-lock provider))
          (when (%tracer-provider-shutdown-p provider)
            (error 'tracer-provider-shutdown :provider provider))
          (%start-span-under-lock provider tracer span-name kind attributes
                                  parent-context options))
      (when recording-p
        (dolist (processor processors)
          (%call-span-processor provider processor :on-start span)))
      span)))
