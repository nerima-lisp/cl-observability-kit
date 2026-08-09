(in-package #:observability-kit.test)

(describe "structured logs"
  (it "captures detached context, resource, severity, and body values"
    (let* ((context (make-instrumentation-context
                     :trace-id "trace-log"
                     :span-id "span-log"
                     :trace-flags 1))
           (resource (make-resource
                      :attributes '(("service.name" . "log-api"))))
           (body (copy-seq "request completed"))
           (record nil))
      (with-instrumentation-context (context)
        (setf record
              (make-log-record
               :timestamp 123
               :severity :warn
               :body body
               :attributes '(("http.status_code" . 200))
               :resource resource
               :scope-name "request-logger"
               :scope-version "1")))
      (setf (char body 0) #\X)
      (expect (log-record-timestamp record) :to-equal 123)
      (expect (log-record-severity record) :to-equal :warn)
      (expect (log-record-severity-text record) :to-equal "WARN")
      (expect (log-record-severity-number record) :to-equal 13)
      (expect (log-record-body record) :to-equal "request completed")
      (expect (log-record-attributes record)
              :to-equal '(("http.status_code" . 200)))
      (expect (instrumentation-context-trace-id
               (log-record-context record))
              :to-equal "trace-log")
      (expect (resource-attribute (log-record-resource record)
                                  "service.name")
              :to-equal "log-api")
      (expect (log-record-scope-name record) :to-equal "request-logger")
      (expect (log-record-scope-version record) :to-equal "1")))

  (it "supports explicit correlation and validates severity boundaries"
    (let ((record (make-log-record
                   :timestamp 456
                   :severity "error"
                   :severity-number 18
                   :body 42
                   :context nil)))
      (expect (log-record-severity record) :to-equal :error)
      (expect (log-record-severity-text record) :to-equal "ERROR")
      (expect (log-record-severity-number record) :to-equal 18)
      (expect (log-record-body record) :to-equal 42)
      (expect (log-record-context record) :to-equal nil))
    (signals invalid-log-severity
      (make-log-record :severity :unknown))
    (signals logging-error
      (make-log-record :severity-number 25))
    (signals logging-error
      (make-log-record :severity-number "not-a-number")))

  (it "rejects invalid log records and scope values"
    (signals logging-error
      (make-log-record :timestamp "not-time"))
    (signals logging-error
      (make-log-record :body (list :unsupported)))
    (signals logging-error
      (make-log-record :scope-name ""))
    (signals logging-error
      (make-log-record
       :scope-version
       (make-string 257 :initial-element #\x)))))
