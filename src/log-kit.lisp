#.(progn
    (in-package #:observability-kit/log-kit)
    nil)

(defun instrumentation-context-log-fields (context)
  "Return a fresh plist suitable for LOG-KIT's WITH-LOG-CONTEXT.

The field names are namespaced and the core context has already rejected
known sensitive names.  This bridge adds fields only; it does not create a
span, own a logger, or change log-kit's record, handler, or sink semantics."
  (check-type context instrumentation-context)
  (list :observability-trace-id
        (instrumentation-context-trace-id context)
        :observability-span-id
        (instrumentation-context-span-id context)
        :observability-trace-flags
        (instrumentation-context-trace-flags context)
        :observability-attributes
        (instrumentation-context-attributes context)
        :observability-baggage
        (instrumentation-context-baggage context)))

(defun call-with-log-kit-context (context function)
  "Call FUNCTION with CONTEXT fields bound in LOG-KIT's dynamic context."
  (check-type context instrumentation-context)
  (check-type function function)
  (with-log-kit-context (context)
    (funcall function)))
