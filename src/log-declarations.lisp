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
