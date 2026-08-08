(defstruct (instrumentation-context
            (:constructor %make-instrumentation-context
                (trace-id span-id trace-flags attributes baggage))
            (:conc-name %instrumentation-context-))
  trace-id
  span-id
  trace-flags
  attributes
  baggage)

(defvar *instrumentation-context* nil
  "Dynamically scoped current instrumentation context.")
