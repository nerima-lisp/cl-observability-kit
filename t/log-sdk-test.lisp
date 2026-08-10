(in-package #:observability-kit.test)

(describe "log provider SDK"
  (it "runs processors and exporters with detached records and lifecycle callbacks"
    (let ((events nil)
          (processor-record nil)
          (exported-record nil))
      (let* ((processor
               (make-log-processor
                :on-emit
                (lambda (record)
                  (setf processor-record record)
                  (push :processor events))
                :force-flush
                (lambda (provider)
                  (expect (log-provider-p provider) :to-be-truthy)
                  (push :processor-flush events))
                :shutdown
                (lambda (provider)
                  (expect (log-provider-p provider) :to-be-truthy)
                  (push :processor-shutdown events))))
             (provider
               (make-log-provider
                :resource
                (make-resource :attributes '(("service.name" . "logs-api")))
                :processors (list processor)
                :exporter
                (lambda (record)
                  (setf exported-record record)
                  (push :exporter events))))
             (logger-a (make-logger provider "orders" :version "1"))
             (logger-b (make-logger provider "orders" :version "1"))
             (record
               (emit-log logger-a
                         :timestamp 123
                         :observed-timestamp 124
                         :severity :error
                         :body "request failed"
                         :event-name "request.failed"
                         :attributes '(("http.status_code" . 500))
                         :context nil)))
        (expect (eq logger-a logger-b) :to-be-truthy)
        (expect (eq processor-record exported-record) :to-be-truthy)
        (expect (log-record-scope-name record) :to-equal "orders")
        (expect (log-record-scope-version record) :to-equal "1")
        (expect (log-record-observed-timestamp record) :to-equal 124)
        (expect (log-record-event-name record) :to-equal "request.failed")
        (expect (resource-attribute (log-record-resource record)
                                    "service.name")
                :to-equal "logs-api")
        (expect (force-flush-log-provider provider) :to-be-truthy)
        (shutdown-log-provider provider)
        (shutdown-log-provider provider)
        (expect (force-flush-log-provider provider) :to-be-falsy)
        (expect (reverse events)
                :to-equal '(:processor
                            :exporter
                            :processor-flush
                            :processor-shutdown))
        (expect (log-provider-shutdown-p provider) :to-be-truthy))))

  (it "isolates processor and exporter failures and rejects post-shutdown use"
    (let ((processor-errors nil)
          (provider-errors nil)
          (export-count 0))
      (let* ((provider
               (make-log-provider
                :error-handler
                (lambda (condition argument)
                  (push (list condition argument) provider-errors))
                :exporter
                (lambda (record)
                  (declare (ignore record))
                  (incf export-count)
                  (error "log export failed"))))
             (processor
               (make-log-processor
                :on-emit
                (lambda (record)
                  (declare (ignore record))
                  (error "log processor failed"))
                :error-handler
                (lambda (condition argument)
                  (push (list condition argument) processor-errors))))
             (logger (make-logger provider "failing-logger")))
        (register-log-processor provider processor)
        (emit-log logger :body "still delivered")
        (expect export-count :to-equal 1)
        (expect (length processor-errors) :to-equal 1)
        (expect (length provider-errors) :to-equal 2)
        (expect (log-provider-last-error provider) :to-be-truthy)
        (shutdown-log-provider provider)
        (signals log-provider-shutdown
          (make-logger provider "after-shutdown"))
        (signals log-provider-shutdown
          (emit-log logger :body "rejected"))
        (signals log-provider-shutdown
          (register-log-processor provider processor)))))

  (it "isolates lifecycle callback and error-handler failures"
    (let* ((handler (lambda (condition argument)
                      (declare (ignore condition argument))
                      (error "log error handler failed")))
           (processor
             (make-log-processor
              :force-flush (lambda (provider)
                             (declare (ignore provider))
                             (error "processor flush failed"))
              :shutdown (lambda (provider)
                          (declare (ignore provider))
                          (error "processor shutdown failed"))
              :error-handler handler))
           (provider
             (make-log-provider
              :processors (list processor)
              :flush (lambda (provider)
                       (declare (ignore provider))
                       (error "provider flush failed"))
              :shutdown (lambda (provider)
                          (declare (ignore provider))
                          (error "provider shutdown failed"))
              :error-handler handler)))
      (expect (force-flush-log-provider provider) :to-be-falsy)
      (expect (log-provider-last-error provider) :to-be-truthy)
      (shutdown-log-provider provider)
      (expect (log-provider-last-error provider) :to-be-truthy)))

  (it "exposes provider metadata and validates log contracts"
    (let* ((processor
             (make-log-processor
              :on-emit 'identity
              :force-flush 'values
              :shutdown 'values
              :error-handler 'list))
           (provider
             (make-log-provider
              :resource (make-resource :attributes '( ("service.name" . "logs")))
              :processors (list processor)))
           (logger-v2
             (make-logger provider "orders" :version "2"
                          :schema-url "https://schema.example/logs"))
           (logger-v1 (make-logger provider "orders" :version "1")))
      (expect (resource-attribute (log-provider-resource provider) "service.name")
              :to-equal "logs")
      (expect (log-provider-processors provider) :to-equal (list processor))
      (expect (log-provider-shutdown-p provider) :to-be-falsy)
      (expect (log-provider-last-error provider) :to-be-falsy)
      (expect (mapcar #'logger-version (log-provider-loggers provider))
              :to-equal '("1" "2"))
      (expect (eq (logger-provider logger-v2) provider) :to-be-truthy)
      (expect (logger-name logger-v2) :to-equal "orders")
      (expect (logger-version logger-v2) :to-equal "2")
      (expect (logger-schema-url logger-v2)
              :to-equal "https://schema.example/logs")
      (expect (eq (log-processor-on-emit processor) 'identity)
              :to-be-truthy)
      (expect (eq (log-processor-force-flush processor) 'values)
              :to-be-truthy)
      (expect (eq (log-processor-shutdown processor) 'values)
              :to-be-truthy)
      (expect (eq (log-processor-error-handler processor) 'list)
              :to-be-truthy)
      (signals observability-error
        (make-log-processor :on-emit 10))
      (signals observability-error
        (make-log-provider :processors (cons processor :tail)))
      (signals logging-error
        (make-logger provider ""))
      (signals logging-error
        (make-logger provider (make-string 257 :initial-element #\x)))
      (signals logging-error
        (make-logger provider "invalid-version" :version 10))
      (signals logging-error
        (make-logger provider "invalid-schema" :schema-url 10))
      (shutdown-log-provider provider))))
