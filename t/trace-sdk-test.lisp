(in-package #:observability-kit.test)

(describe "span processor lifecycle"
  (it "runs processor callbacks before export and exactly once for lifecycle events"
    (let ((events nil)
          (processor-record nil)
          (exported-record nil))
      (let* ((processor
               (make-span-processor
                :on-start
                (lambda (span)
                  (push (list :start (span-name span)) events))
                :on-end
                (lambda (record)
                  (setf processor-record record)
                  (push (list :processor-end (span-record-name record)) events))
                :force-flush
                (lambda (provider)
                  (expect (tracer-provider-p provider) :to-be-truthy)
                  (push :processor-flush events))
                :shutdown
                (lambda (provider)
                  (expect (tracer-provider-p provider) :to-be-truthy)
                  (push :processor-shutdown events))))
             (provider
               (make-tracer-provider
                :span-processors (list processor)
                :exporter
                (lambda (record)
                  (setf exported-record record)
                  (push :exporter events))))
             (tracer (make-tracer provider "processor-test"))
             (span (start-span tracer "processed" :parent nil)))
        (expect (length (tracer-provider-span-processors provider)) :to-equal 1)
        (end-span span)
        (expect (span-record-p processor-record) :to-be-truthy)
        (expect (eq processor-record exported-record) :to-be-truthy)
        (expect (force-flush-tracer-provider provider) :to-be-truthy)
        (shutdown-tracer-provider provider)
        (shutdown-tracer-provider provider)
        (expect (force-flush-tracer-provider provider) :to-be-falsy)
        (expect (reverse events)
                :to-equal '((:start "processed")
                            (:processor-end "processed")
                            :exporter
                            :processor-flush
                            :processor-shutdown))
        (expect (tracer-provider-shutdown-p provider) :to-be-truthy))))

  (it "rejects malformed generated trace and span IDs"
    (let ((valid-trace-id "0123456789abcdef0123456789abcdef")
          (valid-span-id "fedcba9876543210"))
      (dolist (ids
                (list (list (make-string 32 :initial-element #\0)
                            valid-span-id)
                      (list (make-string 32 :initial-element #\z)
                            valid-span-id)
                      (list (make-string 31 :initial-element #\a)
                            valid-span-id)
                      (list valid-trace-id
                            (make-string 16 :initial-element #\z))
                      (list valid-trace-id
                            (make-string 15 :initial-element #\a))))
        (destructuring-bind (trace-id span-id) ids
          (let* ((provider
                   (make-tracer-provider
                    :id-generator
                    (lambda (length)
                      (if (= length 32) trace-id span-id))))
                 (tracer (make-tracer provider "invalid-id")))
            (signals tracing-error
              (start-span tracer "rejected" :parent nil)))))))

  (it "registers processors and isolates processor callback failures"
    (let ((processor-errors nil)
          (provider-errors nil)
          (exported nil))
      (let* ((provider
             (make-tracer-provider
                :export-error-handler
                (lambda (condition argument)
                  (push (list condition argument) provider-errors))
                :exporter
                (lambda (record)
                  (push record exported))))
             (processor
               (make-span-processor
                :on-start (lambda (span)
                            (declare (ignore span))
                            (error "start processor failure"))
                :on-end (lambda (record)
                          (declare (ignore record))
                          (error "end processor failure"))
                :error-handler (lambda (condition argument)
                                 (push (list condition argument)
                                       processor-errors))))
             (tracer (make-tracer provider "failing-processor")))
        (register-span-processor provider processor)
        (expect (eq (first (tracer-provider-span-processors provider)) processor)
                :to-be-truthy)
        (let ((span (start-span tracer "survives" :parent nil)))
          (end-span span))
        (expect (length exported) :to-equal 1)
        (expect (length processor-errors) :to-equal 2)
        (expect (length provider-errors) :to-equal 2)
        (expect (tracer-provider-last-export-error provider) :to-be-truthy)
        (shutdown-tracer-provider provider)
        (signals tracer-provider-shutdown
          (register-span-processor provider processor))))))

  (it "provides deterministic ratio and parent-based samplers"
    (let* ((zero-trace-id "00000000000000000000000000000000")
           (full-trace-id "ffffffffffffffffffffffffffffffff")
           (zero-ratio (make-trace-id-ratio-sampler 0d0))
           (half-ratio (make-trace-id-ratio-sampler 0.5d0))
           (full-ratio (make-trace-id-ratio-sampler 1d0))
           (sampled-parent
             (make-instrumentation-context
              :trace-id zero-trace-id
              :span-id "0000000000000001"
              :trace-flags 1))
           (unsampled-parent
             (make-instrumentation-context
              :trace-id zero-trace-id
              :span-id "0000000000000001"
              :trace-flags 0))
           (parent-based (make-parent-based-sampler half-ratio)))
      (expect (funcall zero-ratio nil "root" :internal nil zero-trace-id)
              :to-equal :drop)
      (expect (funcall full-ratio nil "root" :internal nil zero-trace-id)
              :to-equal :record-and-sample)
      (expect (funcall half-ratio nil "root" :internal nil zero-trace-id)
              :to-equal :record-and-sample)
      (expect (funcall half-ratio nil "root" :internal nil full-trace-id)
              :to-equal :drop)
      (expect (funcall parent-based nil "root" :internal nil zero-trace-id)
              :to-equal :record-and-sample)
      (expect (funcall parent-based unsampled-parent "child" :internal nil)
              :to-equal :drop)
      (expect (funcall parent-based sampled-parent "child" :internal nil)
              :to-equal :record-and-sample)
      (signals tracing-error (make-trace-id-ratio-sampler -0.1d0))
       (signals tracing-error (make-trace-id-ratio-sampler 1.1d0)))

  (it "exposes and validates span processor contracts"
    (let* ((processor
             (make-span-processor
              :on-start 'identity
              :on-end 'identity
              :force-flush 'values
              :shutdown 'values
              :error-handler 'list))
           (provider
             (make-tracer-provider :span-processors (list processor)))
           (tracer (make-tracer provider "orders" :version "1"
                                :schema-url "https://schema.example/traces"))
           (same-tracer (make-tracer provider "orders" :version "1"
                                     :schema-url "https://schema.example/traces"))
           (sampler (make-trace-id-ratio-sampler 0.5d0)))
      (expect (tracer-provider-span-processors provider)
              :to-equal (list processor))
      (expect (eq tracer same-tracer) :to-be-truthy)
      (expect (tracer-provider-resource provider) :to-be-truthy)
      (expect (tracer-provider-clock provider) :to-be-truthy)
      (expect (tracer-provider-tracers provider) :to-equal (list tracer))
      (expect (tracer-provider-shutdown-p provider) :to-be-falsy)
      (expect (tracer-provider-last-export-error provider) :to-be-falsy)
      (expect (tracer-name tracer) :to-equal "orders")
      (expect (tracer-version tracer) :to-equal "1")
      (expect (tracer-schema-url tracer)
              :to-equal "https://schema.example/traces")
      (expect (functionp (span-processor-on-start processor)) :to-be-truthy)
      (expect (functionp (span-processor-on-end processor)) :to-be-truthy)
      (expect (functionp (span-processor-force-flush processor)) :to-be-truthy)
      (expect (functionp (span-processor-shutdown processor)) :to-be-truthy)
      (expect (functionp (span-processor-error-handler processor)) :to-be-truthy)
      (signals tracing-error
        (make-span-processor :on-start 10))
      (signals tracing-error
        (make-tracer-provider :span-processors (cons processor :tail)))
      (signals tracing-error
        (make-tracer-provider :exporter 10))
      (signals tracing-error
        (funcall sampler nil "root" :internal nil :not-a-trace-id))
      (expect (member (funcall sampler nil "root" :internal nil
                                "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz")
                      '(:drop :record-and-sample))
              :to-be-truthy)
      (shutdown-tracer-provider provider))))

  (it "validates built-in span processor options"
    (signals tracing-error
      (make-simple-span-processor 10))
    (signals observability-error
      (make-simple-span-processor #'identity :unknown t))
    (signals tracing-error
      (make-batch-span-processor #'identity :schedule-delay 0))
    (signals tracing-error
      (make-batch-span-processor #'identity :max-queue-size 0))
    (signals tracing-error
      (make-batch-span-processor #'identity :max-export-batch-size 0))
    (signals tracing-error
      (make-batch-span-processor #'identity :start :maybe)))

  (it "isolates span lifecycle callback and error-handler failures"
    (let* ((handler (lambda (condition argument)
                      (declare (ignore condition argument))
                      (error "span error handler failed")))
           (processor
             (make-span-processor
              :force-flush (lambda (provider)
                             (declare (ignore provider))
                             (error "processor flush failed"))
              :shutdown (lambda (provider)
                          (declare (ignore provider))
                          (error "processor shutdown failed"))
              :error-handler handler))
           (provider
             (make-tracer-provider
              :span-processors (list processor)
              :flush (lambda (provider)
                       (declare (ignore provider))
                       (error "provider flush failed"))
              :shutdown (lambda (provider)
                          (declare (ignore provider))
                          (error "provider shutdown failed"))
              :export-error-handler handler)))
      (expect (force-flush-tracer-provider provider) :to-be-falsy)
      (expect (tracer-provider-last-export-error provider) :to-be-truthy)
      (shutdown-tracer-provider provider)
      (expect (tracer-provider-last-export-error provider) :to-be-truthy)))

  (it "exports sampled spans synchronously with the simple span processor"
    (let ((exports nil)
          (flushes 0)
          (shutdowns 0)
          (errors nil))
      (let* ((processor
               (make-simple-span-processor
                (lambda (records)
                  (push records exports))
                :flush (lambda (provider)
                         (declare (ignore provider))
                         (incf flushes))
                :shutdown (lambda (provider)
                            (declare (ignore provider))
                            (incf shutdowns))
                :error-handler (lambda (condition argument)
                                 (push (list condition argument) errors))))
             (provider (make-tracer-provider
                       :span-processors (list processor)))
             (tracer (make-tracer provider "simple")))
        (end-span (start-span tracer "simple-span" :parent nil))
        (expect (length exports) :to-equal 1)
        (expect (length (first exports)) :to-equal 1)
        (expect (span-record-name (first (first exports)))
                :to-equal "simple-span")
        (expect (force-flush-tracer-provider provider) :to-be-truthy)
        (expect flushes :to-equal 1)
        (shutdown-tracer-provider provider)
        (expect shutdowns :to-equal 1)
        (expect errors :to-be-falsy))))

  (it "batches sampled spans and drains the queue during force flush"
    (let ((batches nil)
          (flushes 0)
          (shutdowns 0))
      (let* ((processor
               (make-batch-span-processor
                (lambda (records)
                  (push records batches))
                :schedule-delay 60d0
                :max-queue-size 8
                :max-export-batch-size 2
                :start nil
                :flush (lambda (provider)
                         (declare (ignore provider))
                         (incf flushes))
                :shutdown (lambda (provider)
                            (declare (ignore provider))
                            (incf shutdowns))))
             (provider (make-tracer-provider
                       :span-processors (list processor)))
             (tracer (make-tracer provider "batch")))
        (dotimes (index 5)
          (end-span (start-span tracer (format nil "batch-~D" index)
                                 :parent nil)))
        (expect (force-flush-tracer-provider provider) :to-be-truthy)
        (expect (reduce #'+ batches :initial-value 0 :key #'length)
                :to-equal 5)
        (expect (every (lambda (batch) (<= (length batch) 2)) batches)
                :to-be-truthy)
        (expect flushes :to-equal 1)
        (shutdown-tracer-provider provider)
        (expect shutdowns :to-equal 1)
        (expect (force-flush-tracer-provider provider) :to-be-falsy))))

  (it "isolates asynchronous batch exporter failures"
    (let ((errors nil)
          (export-count 0))
      (let* ((processor
               (make-batch-span-processor
                (lambda (records)
                  (declare (ignore records))
                  (incf export-count)
                  (error "batch exporter failed"))
                :schedule-delay 60d0
                :start nil
                :error-handler (lambda (condition argument)
                                 (push (list condition argument) errors))))
             (provider (make-tracer-provider
                       :span-processors (list processor)))
             (tracer (make-tracer provider "batch-errors")))
        (end-span (start-span tracer "failed-batch" :parent nil))
        (expect (force-flush-tracer-provider provider) :to-be-truthy)
        (expect export-count :to-equal 1)
        (expect errors :to-be-truthy)
        (expect (tracer-provider-last-export-error provider)
                :to-be-truthy)
        (shutdown-tracer-provider provider))))

  (it "bounds the batch queue and drops spans after capacity"
    (let ((exported 0))
      (let* ((processor
               (make-batch-span-processor
                (lambda (records)
                  (incf exported (length records)))
                :schedule-delay 60d0
                :max-queue-size 2
                :start nil))
             (provider (make-tracer-provider
                       :span-processors (list processor)))
             (tracer (make-tracer provider "bounded-batch")))
        (dotimes (index 5)
          (end-span (start-span tracer (format nil "bounded-~D" index)
                                 :parent nil)))
        (expect (force-flush-tracer-provider provider) :to-be-truthy)
        (expect exported :to-equal 2)
        (shutdown-tracer-provider provider))))
