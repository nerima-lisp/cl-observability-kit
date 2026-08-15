#.(progn (in-package #:observability-kit) nil)

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

(defun %end-span-under-lock (span provider options)
  (if (%span-ended-p span)
      (values nil nil)
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
                   (%span-status-message span)))
             (record nil)
             (exporter nil))
        (setf (%span-end-time span) end-time
              (%span-end-monotonic span) end-monotonic
              (%span-status span) status
              (%span-status-message span) status-message
              (%span-ended-p span) t)
        (when (%span-recording-p span)
          (setf record (%make-span-record-from-span
                        span end-time end-monotonic status status-message)
                exporter (%tracer-provider-exporter provider)))
        (values record exporter))))

(defun %export-span-record (provider record exporter)
  (when record
    (dolist (processor (tracer-provider-span-processors provider))
      (%call-span-processor provider processor :on-end record))
    (when (and exporter (span-record-sampled-p record))
      (handler-case
          (funcall exporter record)
        (error (condition)
          (%record-export-error provider condition record))))))

(defun end-span (span &rest option-list)
  "End SPAN once and invoke its provider exporter when it was sampled.

Repeated END-SPAN calls are idempotent.  Exporter failures do not escape the
instrumented operation; inspect TRACER-PROVIDER-LAST-EXPORT-ERROR or supply
an EXPORT-ERROR-HANDLER to observe them."
  (check-type span span)
  (let* ((options (%parse-keyword-options
                   option-list '(:end-time :status :status-message)
                   "END-SPAN"))
         (provider (%span-provider span)))
    (multiple-value-bind (record exporter)
        (cl-concurrent-kit:with-lock-held ((%span-lock span))
          (%end-span-under-lock span provider options))
      (%export-span-record provider record exporter)
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
