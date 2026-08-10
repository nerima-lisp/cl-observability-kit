(in-package #:observability-kit.test)

(defun fixed-id-generator (ids)
  (lambda (length)
    (let ((id (pop ids)))
      (unless (and id (= (length id) length))
        (error "No fixed trace identifier remains for length ~D." length))
      id)))

(defun trace-test-id-generator (length)
  (make-string length :initial-element #\a))

(defun trace-test-sampler (&rest arguments)
  (declare (ignore arguments))
  t)

(describe "resources and tracing"
  (it "copies resource attributes and supports immutable updates"
    (let* ((source (copy-seq "checkout-api"))
           (resource (make-resource
                      :attributes `(("service.name" . ,source)
                                    ("service.version" . "1"))))
           (updated (resource-with-attribute resource "deployment.environment" "test"))
           (merged (resource-with-attributes
                    resource
                    '(("service.name" . "payments")
                      ("deployment.environment" . "test")))))
      (setf (char source 0) #\X)
      (expect (resource-attribute resource "service.name") :to-equal "checkout-api")
      (expect (resource-attribute resource "missing" :fallback) :to-equal :fallback)
      (expect (resource-attributes resource)
              :to-equal '(("service.name" . "checkout-api")
                          ("service.version" . "1")))
      (expect (resource-attribute updated "deployment.environment") :to-equal "test")
      (expect (resource-attribute resource "deployment.environment" :missing)
              :to-equal :missing)
      (expect (resource-attribute merged "service.name") :to-equal "payments")
      (expect (resource-attribute merged "deployment.environment") :to-equal "test")
      (expect (resource-attribute resource "deployment.environment") :to-be nil)))

  (it "propagates parent context and exports detached span records"
    (let* ((records nil)
          (flush-count 0)
          (shutdown-count 0)
          (provider
            (make-tracer-provider
             :resource (make-resource :attributes '("service.name" "checkout-api"))
             :id-generator
             (fixed-id-generator
              (list "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
                    "bbbbbbbbbbbbbbbb"
                    "cccccccccccccccc"))
             :exporter (lambda (record) (push record records))
             :flush (lambda (ignored-provider)
                      (declare (ignore ignored-provider))
                      (incf flush-count))
             :shutdown (lambda (ignored-provider)
                         (declare (ignore ignored-provider))
                         (incf shutdown-count))))
          (tracer (make-tracer provider "checkout" :version "1"))
          (root (start-span tracer 'checkout-request
                            :parent nil
                            :kind :server
                            :attributes '("http.request.method" "GET"))))
      (expect (span-name root) :to-equal "checkout-request")
      (call-with-span
       root
       (lambda (active-root)
         (expect (current-span) :to-equal active-root)
         (expect (instrumentation-context-span-id
                  (current-instrumentation-context))
                 :to-equal (span-id root))
         (let ((child (start-span tracer "query" :kind :client)))
           (expect (span-trace-id child) :to-equal (span-trace-id root))
           (expect (span-parent-span-id child) :to-equal (span-id root))
           (span-add-event child "cache.lookup"
                           :timestamp 11
                           :attributes '("cache.hit" t))
           (span-add-link child (span-context root)
                          :attributes '("link.reason" "derived"))
           (span-set-status child :ok)
           (end-span child :end-time 12))))
      (span-set-attribute root "http.response.status_code" 200)
      (end-span root :end-time 13 :status :ok)
      (end-span root :end-time 14)
      (expect (span-ended-p root) :to-be-truthy)
      (expect (length records) :to-equal 2)
      (let ((child-record (second records))
            (root-record (first records)))
        (expect (span-record-name child-record) :to-equal "query")
        (expect (span-record-parent-span-id child-record)
                :to-equal (span-record-span-id root-record))
        (expect (span-record-status child-record) :to-equal :ok)
        (expect (length (span-record-events child-record)) :to-equal 1)
        (expect (length (span-record-links child-record)) :to-equal 1)
        (expect (resource-attribute (span-record-resource root-record)
                                    "service.name")
                :to-equal "checkout-api")
        (expect (span-record-status root-record) :to-equal :ok)
        (expect (span-record-status-message root-record) :to-equal nil))
      (expect (force-flush-tracer-provider provider) :to-be-truthy)
      (expect flush-count :to-equal 1)
      (shutdown-tracer-provider provider)
      (shutdown-tracer-provider provider)
      (expect shutdown-count :to-equal 1)
      (expect (tracer-provider-shutdown-p provider) :to-be-truthy)
      (signals tracer-provider-shutdown
        (start-span tracer "after-shutdown" :parent nil))))

  (it "supports dropped spans and isolates exporter failures"
    (let* ((provider
             (make-tracer-provider
              :sampler :always-off
              :exporter (lambda (ignored-record)
                          (declare (ignore ignored-record))
                          (error "export failure"))))
           (tracer (make-tracer provider "dropper"))
           (span (start-span tracer "dropped" :parent nil)))
      (expect (not (span-recording-p span)) :to-be-truthy)
      (expect (not (span-sampled-p span)) :to-be-truthy)
      (expect (span-update-name span "ignored") :to-equal span)
      (expect (span-name span) :to-equal "dropped")
      (span-set-attribute span "dropped.attribute" "value")
      (span-add-event span "dropped.event")
      (span-add-link span (make-instrumentation-context :trace-id "trace"))
      (span-set-status span :error)
      (end-span span)
      (expect (tracer-provider-last-export-error provider) :to-equal nil))
    (let* ((records nil)
           (provider
             (make-tracer-provider
              :exporter (lambda (record)
                          (push record records)
                          (error "export failure"))))
           (tracer (make-tracer provider "failing-exporter"))
           (span (start-span tracer "recorded" :parent nil)))
      (end-span span)
      (expect (length records) :to-equal 1)
      (expect (tracer-provider-last-export-error provider) :to-be-truthy))))

  (it "updates recording span names and rejects post-end mutation"
    (let* ((records nil)
           (provider (make-tracer-provider
                      :exporter (lambda (record) (push record records))))
           (tracer (make-tracer provider "rename"))
           (span (start-span tracer "before" :parent nil)))
      (expect (span-update-name span "after") :to-equal span)
      (expect (span-name span) :to-equal "after")
      (end-span span)
      (expect (span-record-name (first records)) :to-equal "after")
      (signals span-operation-error
        (span-update-name span "too-late"))))

  (it "records exceptions in with-span cleanup"
    (let* ((records nil)
          (provider (make-tracer-provider
                     :exporter (lambda (record) (push record records))))
          (tracer nil))
      (setf tracer (make-tracer provider "exception-test"))
      (signals simple-error
        (with-span (span tracer "operation" :parent nil)
          (error "boom")))
      (expect (length records) :to-equal 1)
      (expect (span-record-status (first records)) :to-equal :error)
      (expect (length (span-record-events (first records))) :to-equal 1)))

(describe "tracing boundary validation"
  (it "validates provider, sampler, and span inputs"
    (signals tracing-error (make-tracer-provider :clock 42))
    (signals tracing-error (make-tracer-provider :monotonic-units-per-second 0))
    (signals tracing-error
             (make-tracer-provider :monotonic-units-per-second "1000000"))
    (signals tracing-error (make-tracer-provider :id-generator 42))
    (signals tracing-error (make-tracer-provider :sampler :unknown))
    (signals tracing-error (make-tracer-provider :sampler 42))
    (let ((provider (make-tracer-provider)))
      (signals tracing-error
               (make-tracer provider "bad-version"
                            :version (make-string 257 :initial-element #\x)))
      (signals tracing-error
               (make-tracer provider "non-string-version" :version 42))
      (signals tracing-error
               (make-tracer provider "bad-schema"
                            :schema-url (make-string 257 :initial-element #\x)))
      (signals tracing-error (start-span (make-tracer provider "bad-parent")
                                         "bad-parent" :parent 42))
      (signals invalid-span-name (start-span (make-tracer provider "empty")
                                             "" :parent nil))
      (signals invalid-span-name
               (start-span (make-tracer provider "long")
                           (make-string 257 :initial-element #\x)
                           :parent nil))
      (signals tracing-error
               (start-span (make-tracer provider "bad-kind")
                           "bad-kind" :parent nil :kind :unknown))
      (let ((span (start-span (make-tracer provider "valid")
                              "valid" :parent nil :start-time 10)))
        (span-set-status span :ok :message "finished")
        (signals tracing-error (span-set-status span :unknown))
        (signals tracing-error
                 (span-set-status span :ok
                                  :message (make-string 1025 :initial-element #\x)))
        (signals tracing-error
                 (span-set-status span :ok :message 42))
        (signals tracing-error (span-add-event span "bad-time" :timestamp nil))
        (signals tracing-error (end-span span :end-time nil))
        (end-span span)))
    (let* ((provider (make-tracer-provider
                      :id-generator 'trace-test-id-generator))
           (tracer (make-tracer provider "symbol-generator"))
           (span (start-span tracer "symbol-generator" :parent nil)))
      (expect (span-recording-p span) :to-be-truthy)
      (end-span span))
    (let* ((provider (make-tracer-provider
                      :id-generator (lambda (length)
                                      (declare (ignore length))
                                      "bad")))
           (tracer (make-tracer provider "bad-id")))
      (signals tracing-error (start-span tracer "bad-id" :parent nil)))
    (let* ((provider (make-tracer-provider
                      :id-generator (lambda (length)
                                      (declare (ignore length))
                                      42)))
           (tracer (make-tracer provider "bad-id-type")))
      (signals tracing-error (start-span tracer "bad-id-type" :parent nil)))
    (let* ((provider (make-tracer-provider
                      :sampler (lambda (&rest arguments)
                                 (declare (ignore arguments))
                                 :unknown)))
           (tracer (make-tracer provider "bad-sampler")))
      (signals tracing-error (start-span tracer "bad-sampler" :parent nil)))
    (let* ((provider (make-tracer-provider :sampler 'trace-test-sampler))
           (tracer (make-tracer provider "symbol-sampler"))
           (span (start-span tracer "symbol-sampler" :parent nil)))
      (expect (span-sampled-p span) :to-be-truthy)
      (end-span span)))

  (it "supports every sampler decision and provider callback failure"
    (dolist (decision '(:record-and-sample :record-only :drop t nil))
      (let* ((provider (make-tracer-provider
                        :sampler (lambda (&rest arguments)
                                   (declare (ignore arguments))
                                   decision)))
             (tracer (make-tracer provider "decision"))
             (span (start-span tracer "decision" :parent nil)))
        (expect (span-recording-p span)
                :to-equal (not (null (member decision
                                             '(:record-and-sample :record-only t)
                                             :test #'eq))))
        (expect (span-sampled-p span)
                :to-equal (not (null (member decision
                                             '(:record-and-sample t)
                                             :test #'eq))))
        (end-span span)))
    (let* ((errors 0)
           (provider (make-tracer-provider
                      :flush (lambda (ignored-provider)
                               (declare (ignore ignored-provider))
                               (error "flush failure"))
                      :shutdown (lambda (ignored-provider)
                                  (declare (ignore ignored-provider))
                                  (error "shutdown failure"))
                      :export-error-handler
                      (lambda (condition record)
                        (declare (ignore condition record))
                        (incf errors)
                        (error "handler failure")))))
      (expect (force-flush-tracer-provider provider) :to-be-falsy)
      (shutdown-tracer-provider provider)
      (expect errors :to-equal 2)
      (expect (tracer-provider-last-export-error provider) :to-be-truthy)))

  (it "exposes span state and provider boundary operations"
    (let* ((parent-seen nil)
           (provider (make-tracer-provider
                      :sampler (lambda (parent name kind attributes)
                                 (declare (ignore name kind attributes))
                                 (setf parent-seen
                                       (or parent-seen (not (null parent))))
                                 :record-and-sample)))
           (tracer-z (make-tracer provider "z" :version "2"))
           (tracer-a-v0 (make-tracer provider "a" :version "0"))
           (tracer-a (make-tracer provider "a" :version "1"))
           (tracer-a-v2 (make-tracer provider "a" :version "2"))
           (tracer-a-v3 (make-tracer provider "a" :version "3"))
           (root (start-span tracer-z "root" :parent nil :kind :producer))
           (child (start-span tracer-z "child" :parent root :kind :consumer))
           (context-child (start-span tracer-z "context-child"
                                       :parent (span-context root)))
           (status-span (start-span tracer-a "status" :parent nil))
           (exception-span (start-span tracer-a "exception" :parent nil)))
      (expect (tracer-provider-clock provider) :to-be-truthy)
      (expect (mapcar #'tracer-name (tracer-provider-tracers provider))
              :to-equal '("a" "a" "a" "a" "z"))
      (expect (mapcar (lambda (tracer)
                        (list (tracer-name tracer) (tracer-version tracer)))
                      (tracer-provider-tracers provider))
              :to-equal '(("a" "0") ("a" "1") ("a" "2")
                          ("a" "3") ("z" "2")))
      (expect (observability-kit::%tracer-before-p tracer-z tracer-a-v0)
              :to-be-falsy)
      (expect (observability-kit::%tracer-before-p tracer-a-v0 tracer-a-v3)
              :to-be-truthy)
      (expect parent-seen :to-be-truthy)
      (expect (span-kind root) :to-equal :producer)
      (span-set-attribute root "test.attribute" "value")
      (expect (span-attributes root)
              :to-equal '(("test.attribute" . "value")))
      (expect (span-trace-flags root) :to-equal 1)
      (expect (numberp (span-start-time root)) :to-be-truthy)
      (expect (span-end-time root) :to-equal nil)
      (expect (span-duration root) :to-equal nil)
      (expect (span-status root) :to-equal :unset)
      (expect (span-status-message root) :to-equal nil)
      (span-add-event root "clock.event")
      (span-add-link root child)
      (signals tracing-error (span-add-link root 42))
      (expect (length (span-events root)) :to-equal 1)
      (expect (length (span-links root)) :to-equal 1)
      (end-span child :end-time 2)
      (end-span context-child :end-time 3)
      (end-span root :end-time 4 :status :ok :status-message "done")
      (expect (span-ended-p root) :to-be-truthy)
      (expect (span-end-time root) :to-equal 4)
      (expect (numberp (span-duration root)) :to-be-truthy)
      (expect (span-status root) :to-equal :ok)
      (expect (span-status-message root) :to-equal "done")
      (signals span-operation-error (span-set-status root :error))
      (signals span-operation-error (span-add-event root "late"))
      (handler-case
          (error (make-string 1100 :initial-element #\x))
        (simple-error (condition)
          (span-record-exception exception-span condition :timestamp 30)))
      (let* ((event (first (span-events exception-span)))
             (message (cdr (assoc "exception.message"
                                  (span-event-attributes event)
                                  :test #'string=))))
        (expect (length message) :to-equal 1024))
      (end-span status-span :end-time 5 :status :error :status-message "failed")
      (end-span exception-span :end-time 6)
      (shutdown-tracer-provider provider)
      (signals tracer-provider-shutdown
        (make-tracer provider "after-shutdown")))))
