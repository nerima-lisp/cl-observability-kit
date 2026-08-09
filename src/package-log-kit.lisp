#.(progn
    (in-package #:cl-user)
    nil)

(defpackage #:observability-kit/log-kit
  (:nicknames #:cl-observability-kit/log-kit)
  (:use #:cl)
  (:import-from #:observability-kit
                #:instrumentation-context
                #:instrumentation-context-p
                #:instrumentation-context-trace-id
                #:instrumentation-context-span-id
                #:instrumentation-context-trace-flags
                #:instrumentation-context-attributes
                #:instrumentation-context-baggage
                #:instrumentation-context-tracestate)
  (:export #:instrumentation-context-log-fields
           #:with-log-kit-context
           #:call-with-log-kit-context))
