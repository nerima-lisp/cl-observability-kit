(in-package #:observability-kit.test)

(describe "OTLP-shaped traces"
  (it "groups spans by resource and scope and preserves trace details"
    (let* ((records nil)
           (provider
             (make-tracer-provider
              :resource (make-resource
                         :attributes '(("service.name" . "trace-api")))
              :id-generator
              (fixed-id-generator
               (list "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
                     "bbbbbbbbbbbbbbbb"
                     "cccccccccccccccc"))
              :exporter (lambda (record) (push record records))))
           (tracer (make-tracer provider "checkout"
                                :version "1"
                                :schema-url "https://example.invalid/schema"))
           (root (start-span tracer "request"
                             :parent nil
                             :kind :server
                             :start-time 10)))
      (call-with-span
       root
       (lambda (ignored-root)
         (declare (ignore ignored-root))
         (let ((child (start-span tracer "query"
                                  :kind :client
                                  :start-time 11)))
           (span-add-event child "cache.lookup"
                           :timestamp 12
                           :attributes '(("cache.hit" . t)))
           (span-add-link child (span-context root)
                          :attributes '(("link.reason" . "derived")))
           (span-add-link
            child
            (make-instrumentation-context
             :trace-id "dddddddddddddddddddddddddddddddd"
             :span-id "eeeeeeeeeeeeeeee"
             :trace-flags 1
             :remote-p t)
            :attributes '(("link.reason" . "remote")))
           (span-set-status child :ok)
           (end-span child :end-time 13))))
      (end-span root :end-time 15 :status :ok)
      (let* ((document (observability-kit/otlp:traces->otlp records))
             (resource-spans (string-alist-value "resource-spans" document))
             (resource-span (first resource-spans))
             (scope-spans (first (string-alist-value "scope-spans"
                                                     resource-span)))
             (spans (string-alist-value "spans" scope-spans))
             (root-document (find "request" spans
                                  :key (lambda (span)
                                         (string-alist-value "name" span))
                                  :test #'string=))
             (child-document (find "query" spans
                                   :key (lambda (span)
                                          (string-alist-value "name" span))
                                   :test #'string=)))
        (expect (length records) :to-equal 2)
        (expect (length resource-spans) :to-equal 1)
        (expect (string-alist-value "attributes"
                                    (string-alist-value "resource"
                                                         resource-span))
                :to-equal '((("key" . "service.name")
                             ("value" . "trace-api"))))
        (expect (string-alist-value "name"
                                    (string-alist-value "scope" scope-spans))
                :to-equal "checkout")
        (expect (string-alist-value "version"
                                    (string-alist-value "scope" scope-spans))
                :to-equal "1")
        (expect (string-alist-value "schema-url"
                                    (string-alist-value "scope" scope-spans))
                :to-equal "https://example.invalid/schema")
        (expect (string-alist-value "kind" child-document) :to-equal "CLIENT")
        (expect (string-alist-value "parent-span-id" child-document)
                :to-equal "bbbbbbbbbbbbbbbb")
        (expect (string-alist-value "status" child-document)
                :to-equal '(("code" . "OK") ("message")) )
        (expect (length (string-alist-value "events" child-document))
                :to-equal 1)
        (expect (length (string-alist-value "links" child-document))
                :to-equal 2)
        (let ((remote-link
                (find t (string-alist-value "links" child-document)
                      :key (lambda (link)
                             (string-alist-value "remote" link)))))
          (expect remote-link :to-be-truthy)
          (expect (string-alist-value "trace-id" remote-link)
                  :to-equal "dddddddddddddddddddddddddddddddd"))
        (expect (string-alist-value "end-time" root-document) :to-equal 15)
        (setf (cdr (assoc "name" child-document :test #'string=)) "changed")
        (expect (span-record-name (second records)) :to-equal "query")
        (expect (observability-kit/otlp::%trace-record-before-p
                 (first records) (first records))
                :to-be-falsy)))
    (expect (observability-kit/otlp:traces->otlp nil)
            :to-equal '(("resource-spans")))
    (signals observability-error
      (observability-kit/otlp:traces->otlp (cons nil nil))))

  (it "accepts single records and rejects invalid trace sources"
    (let* ((records nil)
           (provider (make-tracer-provider
                      :id-generator
                      (fixed-id-generator
                       (list (make-string 32 :initial-element #\f)
                             (make-string 16 :initial-element #\f)
                             (make-string 32 :initial-element #\a)
                             (make-string 16 :initial-element #\a)))
                      :exporter (lambda (record) (push record records))))
           (tracer-z (make-tracer provider "z"))
           (tracer-a (make-tracer provider "a"))
           (span-z (start-span tracer-z "z"))
           (span-a (start-span tracer-a "a")))
      (end-span span-z)
      (end-span span-a)
      (let ((record-z (second records))
            (record-a (first records)))
        (expect (observability-kit/otlp::%trace-record-before-p record-z record-a)
                :to-be-falsy)
        (expect (observability-kit/otlp::%trace-record-before-p record-a record-z)
                :to-be-truthy)
        (expect (observability-kit/otlp:span-record->otlp record-z)
                :to-be-truthy)
        (expect (length (string-alist-value
                         "resource-spans"
                         (observability-kit/otlp:traces->otlp record-z)))
                :to-equal 1)
        (expect (length (string-alist-value
                         "resource-spans"
                         (observability-kit/otlp:traces->otlp
                          (list record-z record-a))))
                :to-equal 2)
        (signals type-error
          (observability-kit/otlp:span-record->otlp nil))
        (signals observability-error
          (observability-kit/otlp:traces->otlp :bad))
        (signals observability-error
          (observability-kit/otlp:traces->otlp (list :bad)))))))

(describe "OTLP-shaped logs"
  (it "groups log records and carries correlation fields"
    (let* ((resource (make-resource
                      :attributes '(("service.name" . "log-api"))))
           (context (make-instrumentation-context
                     :trace-id "trace-log"
                     :span-id "span-log"))
           (correlated (make-log-record
                        :timestamp 100
                        :observed-timestamp 102
                        :severity :info
                        :body "hello"
                        :event-name "request.completed"
                        :context context
                        :resource resource
                        :scope-name "app"))
           (uncorrelated (make-log-record
                          :timestamp 101
                          :severity :error
                          :body "failed"
                          :context nil
                          :resource resource
                          :scope-name "app"))
           (document (observability-kit/otlp:logs->otlp
                      (list correlated uncorrelated)))
           (resource-logs (string-alist-value "resource-logs" document))
           (scope-logs (first (string-alist-value "scope-logs"
                                                  (first resource-logs))))
           (logs (string-alist-value "logs" scope-logs)))
      (expect (length resource-logs) :to-equal 1)
      (expect (length logs) :to-equal 2)
      (expect (string-alist-value "severity-text" (first logs))
              :to-equal "INFO")
      (expect (string-alist-value "observed-timestamp" (first logs))
              :to-equal 102)
      (expect (string-alist-value "event-name" (first logs))
              :to-equal "request.completed")
      (expect (string-alist-value "trace-id"
                                  (string-alist-value "context" (first logs)))
              :to-equal "trace-log")
      (expect (string-alist-value "context" (second logs)) :to-equal nil)
      (expect (string-alist-value "body" (second logs)) :to-equal "failed")))

  (it "accepts single records and validates log sources"
    (let* ((one (make-log-record :timestamp 200
                                 :severity :info
                                 :body "one"
                                 :scope-name "z"))
           (two (make-log-record :timestamp 201
                                 :severity :warn
                                 :body "two"
                                 :scope-name "a")))
      (expect (observability-kit/otlp:log-record->otlp one)
              :to-be-truthy)
      (expect (length (string-alist-value
                       "resource-logs"
                       (observability-kit/otlp:logs->otlp one)))
              :to-equal 1)
      (expect (length (string-alist-value
                       "resource-logs"
                       (observability-kit/otlp:logs->otlp
                        (list one two))))
              :to-equal 2)
      (expect (observability-kit/otlp:logs->otlp nil)
              :to-equal '(("resource-logs")))
      (signals type-error
        (observability-kit/otlp:log-record->otlp nil))
      (signals observability-error
        (observability-kit/otlp:logs->otlp :bad))
      (signals observability-error
        (observability-kit/otlp:logs->otlp (list :bad))))))
