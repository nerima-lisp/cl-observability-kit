#.(progn
    (in-package #:observability-kit/log-kit)
    nil)

(defmacro with-log-kit-context ((context) &body body)
  "Run BODY with CONTEXT fields merged into the dynamic LOG-KIT context."
  (let ((context-var (gensym "CONTEXT-")))
    `(let ((,context-var ,context))
       (check-type ,context-var instrumentation-context)
       (log-kit:with-log-context
           (:observability-trace-id
            (instrumentation-context-trace-id ,context-var)
            :observability-span-id
            (instrumentation-context-span-id ,context-var)
            :observability-trace-flags
            (instrumentation-context-trace-flags ,context-var)
            :observability-attributes
            (instrumentation-context-attributes ,context-var)
            :observability-baggage
            (instrumentation-context-baggage ,context-var)
            :observability-tracestate
            (instrumentation-context-tracestate ,context-var))
         ,@body))))
