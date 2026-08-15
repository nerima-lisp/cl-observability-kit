#.(progn
    (in-package #:observability-kit)
    nil)

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
