#.(progn
    (in-package #:observability-kit)
    nil)

(defstruct (log-record
            (:constructor %make-log-record
                (timestamp severity severity-text severity-number body
                 attributes context resource scope-name scope-version
                 scope-schema-url))
            (:conc-name %log-record-))
  timestamp
  severity
  severity-text
  severity-number
  body
  attributes
  context
  resource
  scope-name
  scope-version
  scope-schema-url)

(defstruct (log-processor
            (:constructor %make-log-processor
                (on-emit force-flush shutdown error-handler))
            (:conc-name %log-processor-))
  on-emit
  force-flush
  shutdown
  error-handler)

(defstruct (log-provider
            (:constructor %make-log-provider
                (lock loggers resource processors exporter flush shutdown
                 error-handler last-error shutdown-p))
            (:conc-name %log-provider-))
  lock
  loggers
  resource
  processors
  exporter
  flush
  shutdown
  error-handler
  last-error
  shutdown-p)

(defstruct (logger
            (:constructor %make-logger
                (provider name version schema-url))
            (:conc-name %logger-))
  provider
  name
  version
  schema-url)
