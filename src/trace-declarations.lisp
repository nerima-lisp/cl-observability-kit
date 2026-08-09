#.(progn
    (in-package #:observability-kit)
    nil)

(defstruct (tracer-provider
            (:constructor %make-tracer-provider
                (lock tracers resource clock monotonic-units-per-second
                 id-generator sampler exporter flush shutdown
                 export-error-handler last-export-error shutdown-p))
            (:conc-name %tracer-provider-))
  lock
  tracers
  resource
  clock
  monotonic-units-per-second
  id-generator
  sampler
  exporter
  flush
  shutdown
  export-error-handler
  last-export-error
  shutdown-p)

(defstruct (tracer
            (:constructor %make-tracer (provider name version schema-url))
            (:conc-name %tracer-))
  provider
  name
  version
  schema-url)

(defstruct (span-event
            (:constructor %make-span-event (name timestamp attributes))
            (:conc-name %span-event-))
  name
  timestamp
  attributes)

(defstruct (span-link
            (:constructor %make-span-link (context attributes))
            (:conc-name %span-link-))
  context
  attributes)

(defstruct (span
            (:constructor %make-span
                (lock provider tracer name kind trace-id span-id
                 parent-span-id trace-flags context-attributes baggage
                 tracestate
                 start-time start-monotonic end-time end-monotonic
                 status status-message attributes events links recording-p
                 sampled-p ended-p))
            (:conc-name %span-))
  lock
  provider
  tracer
  name
  kind
  trace-id
  span-id
  parent-span-id
  trace-flags
  context-attributes
  baggage
  tracestate
  start-time
  start-monotonic
  end-time
  end-monotonic
  status
  status-message
  attributes
  events
  links
  recording-p
  sampled-p
  ended-p)

(defstruct (span-record
            (:constructor %make-span-record
                (trace-id span-id parent-span-id name kind start-time
                 end-time duration status status-message trace-flags
                 sampled-p recording-p attributes events links resource
                 tracer-name tracer-version tracer-schema-url))
            (:conc-name %span-record-))
  trace-id
  span-id
  parent-span-id
  name
  kind
  start-time
  end-time
  duration
  status
  status-message
  trace-flags
  sampled-p
  recording-p
  attributes
  events
  links
  resource
  tracer-name
  tracer-version
  tracer-schema-url)

(defvar *current-span* nil
  "Dynamically scoped current span, when a span scope is active.")
