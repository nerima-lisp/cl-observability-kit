#.(progn
    (in-package #:observability-kit)
    nil)

(defstruct (instrumentation-context
            (:constructor %make-instrumentation-context
                (trace-id span-id trace-flags attributes baggage tracestate
                 &optional remote-p))
            (:conc-name %instrumentation-context-))
  trace-id
  span-id
  trace-flags
  attributes
  baggage
  tracestate
  remote-p)

(defvar *instrumentation-context* nil
  "Dynamically scoped current instrumentation context.")
