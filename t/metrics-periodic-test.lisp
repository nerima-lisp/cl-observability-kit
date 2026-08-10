(in-package #:observability-kit.test)

(describe "periodic metric readers"
  (it "collects on an interval and shuts down without leaking the worker"
    (let* ((provider (make-meter-provider))
           (meter (make-meter provider "periodic"))
           (counter (define-counter meter ticks_total))
           (batches nil)
           (reader
             (make-periodic-metric-reader
              provider
              :interval 0.01d0
              :exporter (lambda (snapshots)
                          (push snapshots batches)))))
      (metric-inc counter 4)
      (loop repeat 100
            while (null batches)
            do (sleep 0.005d0))
      (expect batches :to-be-truthy)
      (expect (metric-sample-value
               (first (metric-snapshot-samples
                       (first (first batches)))))
              :to-equal 4)
      (expect (periodic-metric-reader-running-p reader) :to-be-truthy)
      (expect (shutdown-periodic-metric-reader reader) :to-be-truthy)
      (expect (periodic-metric-reader-shutdown-p reader) :to-be-truthy)
      (expect (periodic-metric-reader-running-p reader) :to-be-falsy)
      (expect (metric-reader-shutdown-p
               (periodic-metric-reader-reader reader))
              :to-be-truthy)
      (expect (shutdown-periodic-metric-reader reader) :to-be-truthy)))

  (it "supports manual collection before starting"
    (let* ((provider (make-meter-provider))
           (meter (make-meter provider "manual"))
           (counter (define-counter meter manual_total))
           (reader (make-periodic-metric-reader
                    provider :interval 1 :start nil)))
      (metric-inc counter 7)
      (expect (periodic-metric-reader-running-p reader) :to-be-falsy)
      (multiple-value-bind (snapshots collected-p)
          (collect-periodic-metric-reader reader)
        (expect collected-p :to-be-truthy)
        (expect (metric-sample-value
                 (first (metric-snapshot-samples (first snapshots))))
                :to-equal 7))
      (expect (start-periodic-metric-reader reader) :to-be-truthy)
      (expect (periodic-metric-reader-running-p reader) :to-be-truthy)
      (shutdown-periodic-metric-reader reader))))

  (it "exposes reader state and forwards manual flush operations"
    (let* ((provider (make-meter-provider))
           (meter (make-meter provider "manual-state"))
           (counter (define-counter meter manual_state_total))
           (flushes 0)
           (reader (make-periodic-metric-reader
                    provider
                    :interval 2
                    :start nil
                    :flush (lambda () (incf flushes)))))
      (metric-inc counter 3)
      (expect (periodic-metric-reader-interval reader)
              :to-equal
              2.0d0)
      (expect (periodic-metric-reader-reader reader)
              :to-be-truthy)
      (expect (periodic-metric-reader-last-error reader)
              :to-be-falsy)
      (expect (collect-periodic-metric-reader reader :export-p nil)
              :to-be-truthy)
      (expect (force-flush-periodic-metric-reader reader)
              :to-be-truthy)
      (expect flushes :to-equal 1)
      (shutdown-periodic-metric-reader reader)))

  (it "validates lifecycle transitions and interval settings"
    (let ((provider (make-meter-provider)))
      (signals observability-error
        (make-periodic-metric-reader provider :interval 0))
      (signals observability-error
        (make-periodic-metric-reader provider :interval -1))
      (signals observability-error
        (make-periodic-metric-reader provider :interval 1 :start :yes))
      (let ((reader (make-periodic-metric-reader
                     provider :interval 1 :start nil)))
        (shutdown-metric-reader (periodic-metric-reader-reader reader))
        (signals observability-error
          (start-periodic-metric-reader reader))
        (shutdown-periodic-metric-reader reader))
      (let ((reader (make-periodic-metric-reader
                     provider :interval 1 :start nil)))
        (shutdown-periodic-metric-reader reader)
        (signals observability-error
          (start-periodic-metric-reader reader)))))
