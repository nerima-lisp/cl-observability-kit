(in-package #:observability-kit.test)

(defun metric-snapshot-by-name (snapshots name)
  (find name snapshots :key #'metric-snapshot-name :test #'string=))

(describe "meter providers and readers"
  (it "creates scoped meters and collects synchronous and observable instruments"
    (let* ((provider
             (make-meter-provider
              :resource (make-resource
                         :attributes '(("service.name" . "metrics-api")))
              :registry-options '(:default-cardinality-limit 4)))
           (meter (make-meter provider "orders" :version "1"))
           (counter (define-up-down-counter
                      meter requests_total
                      :label-names '("route")))
           (callback-called nil)
           (observable
             (define-observable-gauge
                 meter queue_depth
                 :label-names '("route")
                 :callback
                 (lambda (observe)
                   (setf callback-called t)
                   (funcall observe 3 :labels '("route" "/orders"))))))
      (expect (eq meter (make-meter provider "orders" :version "1"))
              :to-be-truthy)
      (expect (metric-kind counter) :to-equal :up-down-counter)
      (expect (up-down-counter-p counter) :to-be-truthy)
      (expect (observable-gauge-p observable) :to-be-truthy)
      (expect (metric-inc counter 5 :labels '("route" "/orders"))
              :to-equal 5)
      (expect (metric-inc counter -2 :labels '("route" "/orders"))
              :to-equal 3)
      (let* ((snapshots (metric-snapshot provider))
             (counter-snapshot (metric-snapshot-by-name snapshots
                                                        "requests_total"))
             (observable-snapshot (metric-snapshot observable))
             (counter-sample
               (first (metric-snapshot-samples counter-snapshot)))
             (observable-sample
               (first (metric-snapshot-samples observable-snapshot))))
        (expect (length snapshots) :to-equal 2)
        (expect (metric-sample-value counter-sample) :to-equal 3)
        (expect (metric-sample-value observable-sample) :to-equal 3)
        (expect (resource-attribute
                 (metric-snapshot-resource counter-snapshot)
                 "service.name")
                :to-equal "metrics-api")
        (expect (metric-snapshot-scope-name counter-snapshot)
                :to-equal "orders")
        (expect (metric-snapshot-scope-version counter-snapshot)
                :to-equal "1")
        (expect (metric-snapshot-scope-schema-url counter-snapshot)
                :to-equal nil)
        (expect callback-called :to-be-truthy))
      (expect (metric-snapshot-type (metric-snapshot observable))
              :to-equal :observable-gauge)))

  (it "keeps reader exports detached and isolates exporter failures"
    (let* ((provider (make-meter-provider))
           (meter (make-meter provider "reader"))
           (counter (define-counter meter requests_total))
           (exported-batches nil)
           (flush-count 0)
           (shutdown-count 0)
           (reader
             (make-metric-reader
              provider
              :exporter (lambda (snapshots)
                          (push snapshots exported-batches))
              :flush (lambda () (incf flush-count))
              :shutdown (lambda () (incf shutdown-count)))))
      (metric-inc counter 2)
      (multiple-value-bind (snapshots collected-p)
          (collect-metric-reader reader)
        (expect collected-p :to-be-truthy)
        (expect (length snapshots) :to-equal 1)
        (expect (metric-sample-value
                 (first (metric-snapshot-samples (first snapshots))))
                :to-equal 2))
      (expect (length exported-batches) :to-equal 1)
      (metric-inc counter 3)
      (expect (metric-sample-value
               (first (metric-snapshot-samples
                       (first (first exported-batches)))))
              :to-equal 2)
      (expect (force-flush-metric-reader reader) :to-be-truthy)
      (expect flush-count :to-equal 1)
      (expect (force-flush-meter-provider provider) :to-be-truthy)
      (expect flush-count :to-equal 2)
      (expect (length (meter-provider-readers provider)) :to-equal 1)
      (shutdown-meter-provider provider)
      (shutdown-meter-provider provider)
      (expect shutdown-count :to-equal 1)
      (expect (meter-provider-shutdown-p provider) :to-be-truthy)
      (expect (metric-reader-shutdown-p reader) :to-be-truthy)
      (expect (force-flush-meter-provider provider) :to-be-falsy)
      (signals observability-error
        (make-meter provider "after-shutdown"))
      (signals observability-error
        (make-metric-reader provider))

      (let* ((failing-provider (make-meter-provider))
             (failing-meter (make-meter failing-provider "failing"))
             (failing-counter (define-counter failing-meter failures_total))
             (failure-errors nil)
             (failing-reader
               (make-metric-reader
                failing-provider
                :exporter (lambda (snapshots)
                            (declare (ignore snapshots))
                            (error "export failed"))
                :error-handler (lambda (condition)
                                 (push condition failure-errors)))))
        (metric-inc failing-counter)
        (multiple-value-bind (snapshots collected-p)
            (collect-metric-reader failing-reader)
          (expect snapshots :to-be-falsy)
          (expect collected-p :to-be-falsy))
        (expect (metric-reader-last-error failing-reader) :to-be-truthy)
        (expect (length failure-errors) :to-equal 1)))))

  (it "validates reader callbacks and exposes detached lifecycle state"
    (let* ((registry (make-metric-registry))
           (meter-provider (make-meter-provider))
           (meter (make-meter meter-provider "single"))
           (metric (define-counter meter single_total))
           (reader (make-metric-reader
                    metric
                    :exporter 'list
                    :flush 'values
                    :shutdown 'values
                    :error-handler 'list)))
      (expect (eq (metric-reader-source reader) metric) :to-be-truthy)
      (expect (metric-reader-shutdown-p reader) :to-be-falsy)
      (expect (metric-reader-last-error reader) :to-be-falsy)
      (expect (metric-reader-last-snapshots reader) :to-be-falsy)
      (make-metric-reader registry)
      (make-metric-reader meter)
      (metric-inc metric 4)
      (multiple-value-bind (snapshots collected-p)
          (collect-metric-reader reader :export-p nil)
        (expect collected-p :to-be-truthy)
        (expect (length snapshots) :to-equal 1)
        (expect (length (metric-reader-last-snapshots reader))
                :to-equal 1))
      (expect (metric-reader-force-flush reader) :to-be-truthy)
      (expect (metric-reader-shutdown reader) :to-be-truthy)
      (expect (metric-reader-shutdown-p reader) :to-be-truthy)
      (multiple-value-bind (snapshots collected-p)
          (collect-metric-reader reader)
        (expect snapshots :to-be-falsy)
        (expect collected-p :to-be-falsy))
      (dolist (invalid (list
                        (lambda () (make-metric-reader metric :exporter 0))
                        (lambda () (make-metric-reader metric :flush 0))
                        (lambda () (make-metric-reader metric :shutdown 0))
                        (lambda () (make-metric-reader metric :error-handler 0))))
        (signals observability-error (funcall invalid)))
      (signals type-error (make-metric-reader :not-a-source))))

  (it "isolates reader lifecycle callback failures"
    (let* ((provider (make-meter-provider))
           (meter (make-meter provider "reader-errors"))
           (metric (define-counter meter errors_total))
           (handler-calls 0)
           (handler (lambda (condition)
                      (declare (ignore condition))
                      (incf handler-calls)
                      (error "error handler failed")))
           (exporter-reader
             (make-metric-reader
              metric
              :exporter (lambda (snapshots)
                          (declare (ignore snapshots))
                          (error "exporter failed"))
              :error-handler handler))
           (flush-reader
             (make-metric-reader
              metric
              :flush (lambda () (error "flush failed"))
              :error-handler handler))
           (shutdown-reader
             (make-metric-reader
              metric
              :shutdown (lambda () (error "shutdown failed"))
              :error-handler handler)))
      (metric-inc metric)
      (multiple-value-bind (snapshots collected-p)
          (collect-metric-reader exporter-reader)
        (expect snapshots :to-be-falsy)
        (expect collected-p :to-be-falsy))
      (expect (metric-reader-last-error exporter-reader) :to-be-truthy)
      (expect (force-flush-metric-reader flush-reader) :to-be-falsy)
      (expect (metric-reader-last-error flush-reader) :to-be-truthy)
      (expect (shutdown-metric-reader shutdown-reader) :to-be-truthy)
      (expect (metric-reader-last-error shutdown-reader) :to-be-truthy)
      (expect (>= handler-calls 3) :to-be-truthy)))

  (it "manages provider resources, meters, validation, and callbacks"
    (let* ((provider
             (make-meter-provider
              :resource (make-resource :attributes '(("service.name" . "sdk")))
              :registry-options '(:default-cardinality-limit 3)
              :flush 'values
              :shutdown 'values
              :error-handler 'list))
           (meter-a (make-meter provider "a" :version "1" :schema-url "https://a"))
           (meter-z2 (make-meter provider "z" :version "2"))
           (meter-z1 (make-meter provider "z" :version "1"))
           (counter-z2 (define-counter meter-z2 shared_total))
           (counter-z1 (define-counter meter-z1 shared_total)))
      (expect (resource-attribute (meter-provider-resource provider)
                                  "service.name")
              :to-equal "sdk")
      (expect (mapcar #'meter-name (meter-provider-meters provider))
              :to-equal '("a" "z" "z"))
      (expect (mapcar #'meter-version (meter-provider-meters provider))
              :to-equal '("1" "1" "2"))
      (expect (eq (meter-provider meter-a) provider) :to-be-truthy)
      (expect (metric-registry-p (meter-registry meter-a)) :to-be-truthy)
      (expect (meter-name meter-z1) :to-equal "z")
      (expect (meter-version meter-z2) :to-equal "2")
      (metric-inc counter-z2 2)
      (metric-inc counter-z1 1)
      (expect (mapcar #'metric-snapshot-scope-version
                      (metric-snapshot provider))
              :to-equal '("1" "2"))
      (expect (meter-schema-url meter-a) :to-equal "https://a")
      (expect (meter-provider-last-error provider) :to-be-falsy)
      (expect (meter-provider-readers provider) :to-be-falsy)
      (expect (force-flush-meter-provider provider) :to-be-truthy)
      (expect (shutdown-meter-provider provider) :to-be-truthy)
      (expect (meter-provider-shutdown-p provider) :to-be-truthy)
      (dolist (invalid (list
                        (lambda () (make-meter-provider :flush 0))
                        (lambda () (make-meter-provider :shutdown 0))
                        (lambda () (make-meter-provider :error-handler 0))
                        (lambda () (make-meter-provider :readers '(1 . 2)))
                        (lambda () (make-meter-provider
                                    :registry-options '(:default-cardinality-limit . 3)))
                        (lambda () (make-meter-provider :readers '(1)))))
        (handler-case
            (progn (funcall invalid)
                   (error "invalid provider option was accepted"))
          (observability-error () t)
          (type-error () t))))

  (it "records provider flush and shutdown failures"
    (let* ((flush-handler-called nil)
           (flush-provider
             (make-meter-provider
              :flush (lambda () (error "provider flush failed"))
              :error-handler (lambda (condition)
                               (declare (ignore condition))
                               (setf flush-handler-called t)
                               (error "provider handler failed")))))
      (expect (force-flush-meter-provider flush-provider) :to-be-falsy)
      (expect (meter-provider-last-error flush-provider) :to-be-truthy)
      (expect flush-handler-called :to-be-truthy)
      (let* ((shutdown-handler-called nil)
             (shutdown-provider
               (make-meter-provider
                :shutdown (lambda () (error "provider shutdown failed"))
                :error-handler (lambda (condition)
                                 (declare (ignore condition))
                                 (setf shutdown-handler-called t)
                                 (error "provider handler failed")))))
        (expect (shutdown-meter-provider shutdown-provider) :to-be-truthy)
        (expect shutdown-handler-called :to-be-truthy)
        (expect (meter-provider-last-error shutdown-provider) :to-be-truthy)
        (expect (shutdown-meter-provider shutdown-provider) :to-be-truthy)))))

  (it "records provider flush failures when no readers are registered"
    (let ((provider
            (make-meter-provider
             :flush (lambda ()
                      (error "provider flush failed")))))
      (expect (force-flush-meter-provider provider) :to-be-falsy)
      (expect (meter-provider-last-error provider) :to-be-truthy)
      (expect (shutdown-meter-provider provider) :to-be-truthy)))

  (it "validates metric scopes and observable definitions"
    (dolist (invalid (list
                      (lambda () (make-metric-registry :scope-name 1))
                      (lambda () (make-metric-registry :scope-version ""))
                      (lambda () (make-metric-registry :scope-schema-url 1))))
      (signals observability-error (funcall invalid)))
    (let* ((registry
             (make-metric-registry
              :scope-name "scope"
              :scope-version "1"
              :scope-schema-url "https://schema"))
           (provider (make-meter-provider))
           (meter (make-meter provider "observable"))
           (observable
             (define-observable-up-down-counter
                 meter balance
                 :callback (lambda (observe)
                             (funcall observe -2))))
           (symbol-observable
             (define-observable-gauge meter symbol_observable
                                       :callback 'identity)))
      (expect (metric-registry-scope-name registry) :to-equal "scope")
      (expect (metric-registry-scope-version registry) :to-equal "1")
      (expect (metric-registry-scope-schema-url registry) :to-equal "https://schema")
      (expect (observable-up-down-counter-p observable) :to-be-truthy)
      (expect (observable-gauge-p symbol-observable) :to-be-truthy))
    (signals type-error (define-counter :not-owner invalid_total))
    (let ((meter (make-meter (make-meter-provider) "callbacks")))
      (signals observability-error
        (define-counter
            meter invalid_sync_callback
            :callback (lambda (observe)
                        (declare (ignore observe)))))
      (signals observability-error
        (define-observable-gauge meter missing_observable_callback))
      (signals observability-error
        (define-observable-counter
            meter invalid_observable_callback
            :callback 0))))

  (it "validates observable snapshots and preserves scope metadata"
    (let* ((clean-provider
             (make-meter-provider
              :resource (make-resource :attributes '(("service.name" . "clean")))))
           (clean-meter
             (make-meter clean-provider "clean" :version "1"
                         :schema-url "https://schema"))
           (clean-counter (define-counter clean-meter clean_total)))
      (metric-inc clean-counter 3)
      (let ((snapshot (first (metric-snapshot clean-meter))))
        (expect (metric-snapshot-scope-name snapshot) :to-equal "clean")
        (expect (metric-snapshot-scope-version snapshot) :to-equal "1")
        (expect (metric-snapshot-scope-schema-url snapshot) :to-equal "https://schema")
        (expect (resource-attribute (metric-snapshot-resource snapshot)
                                    "service.name")
                :to-equal "clean")))
    (let* ((provider
             (make-meter-provider
              :registry-options '(:default-cardinality-limit 1)))
           (meter (make-meter provider "observable-edge"))
           (negative
             (define-observable-counter
                 meter negative_total
                 :callback (lambda (observe)
                             (funcall observe -1))))
           (too-many
             (define-observable-gauge
                 meter too_many
                 :label-names '("route")
                 :callback (lambda (observe)
                             (funcall observe 1 :labels '("route" "/one"))
                             (funcall observe 2 :labels '("route" "/two"))))))
      (signals metric-operation-error (metric-snapshot negative))
      (signals metric-cardinality-exceeded (metric-snapshot too-many))))

  (it "registers provider readers and isolates reader and provider failures"
    (let* ((handler-calls 0)
           (provider
             (make-meter-provider
              :flush (lambda () (error "provider flush failed"))
              :shutdown (lambda () (error "provider shutdown failed"))
              :error-handler (lambda (condition)
                               (declare (ignore condition))
                               (incf handler-calls))))
           (meter (make-meter provider "reader"))
           (counter (define-counter meter reader_total))
           (reader
             (make-metric-reader
              provider
              :flush (lambda () (error "reader flush failed"))
              :shutdown (lambda () (error "reader shutdown failed")))))
      (metric-inc counter 1)
      (expect (member reader (meter-provider-readers provider)) :to-be-truthy)
      (expect (force-flush-meter-provider provider) :to-be-falsy)
      (expect (meter-provider-last-error provider) :to-be-truthy)
      (expect (shutdown-meter-provider provider) :to-be-truthy)
      (expect (meter-provider-last-error provider) :to-be-truthy)
      (expect (>= handler-calls 2) :to-be-truthy)))
