#.(progn
    (in-package #:observability-kit.test)
    nil)

(describe "SDK configuration"
  (it "reads process defaults and handles empty and boolean boundaries"
    (let ((configuration (observability-kit:read-sdk-configuration)))
      (expect (realp
               (observability-kit:sdk-configuration-metric-export-interval
                configuration))
              :to-be-truthy)
      (expect (functionp
               (observability-kit:sdk-configuration-trace-sampler
                configuration))
              :to-be-truthy)
      (expect (member (observability-kit:sdk-configuration-log-level configuration)
                      '(:trace :debug :info :warn :error :fatal))
              :to-be-truthy))
    (let ((configuration
            (observability-kit:read-sdk-configuration
             :environment (list (list "OTEL_SDK_DISABLED")))))
      (expect (observability-kit:sdk-configuration-disabled-p configuration)
              :to-be-falsy))
    (signals observability-kit:configuration-error
      (observability-kit:read-sdk-configuration
       :environment '(("OTEL_PROPAGATORS" . ""))))
    (signals observability-kit:configuration-error
      (observability-kit:read-sdk-configuration
       :environment '(("OTEL_RESOURCE_ATTRIBUTES" . "=value"))))
    (signals observability-kit:configuration-error
      (observability-kit:read-sdk-configuration
       :environment '(("OTEL_RESOURCE_ATTRIBUTES" . "authorization=secret"))))
    (dolist (value '("false" ""))
      (let ((configuration
              (observability-kit:read-sdk-configuration
               :environment (list (cons "OTEL_SDK_DISABLED" value)))))
        (expect (observability-kit:sdk-configuration-disabled-p configuration)
                :to-be-falsy))))

  (it "supports public log levels and ignores malformed baggage"
    (dolist (entry '(("trace" . :trace)
                     ("warn" . :warn)
                     ("error" . :error)))
      (let ((configuration
              (observability-kit:read-sdk-configuration
               :environment (list (cons "OTEL_LOG_LEVEL" (car entry))))))
        (expect (observability-kit:sdk-configuration-log-level configuration)
                :to-equal (cdr entry))))
    (let* ((configuration
             (observability-kit:read-sdk-configuration
              :environment '(("OTEL_PROPAGATORS" . "baggage"))))
           (extracted
             (observability-kit:propagator-extract
              (observability-kit:sdk-configuration-propagator configuration)
              '(("baggage" . "malformed")))))
      (expect extracted :to-be-falsy)))

  (it "reads resource, propagation, timing, sampler, and log settings"
    (let* ((configuration
             (observability-kit:read-sdk-configuration
              :environment
              '(("OTEL_SERVICE_NAME" . "orders")
                ("OTEL_RESOURCE_ATTRIBUTES" . "deployment.environment=prod")
                ("OTEL_PROPAGATORS" . "tracecontext")
                ("OTEL_METRIC_EXPORT_INTERVAL" . "2500")
                ("OTEL_METRIC_EXPORT_TIMEOUT" . "750")
                ("OTEL_TRACES_SAMPLER" . "parent_based_always_off")
                ("OTEL_LOG_LEVEL" . "debug"))))
           (resource (observability-kit:sdk-configuration-resource
                      configuration))
           (context
             (observability-kit:make-instrumentation-context
              :trace-id "0123456789abcdef0123456789abcdef"
              :span-id "0123456789abcdef"
              :trace-flags 1))
           (headers
             (observability-kit:propagator-inject
              (observability-kit:sdk-configuration-propagator configuration)
              context
              '(("x-request-id" . "req-1")))))
      (expect (observability-kit:sdk-configuration-disabled-p configuration)
              :to-be-falsy)
      (expect (observability-kit:sdk-configuration-service-name configuration)
              :to-equal "orders")
      (expect (observability-kit:resource-attribute resource "service.name")
              :to-equal "orders")
      (expect (observability-kit:resource-attribute
               resource "deployment.environment")
              :to-equal "prod")
      (expect (observability-kit:sdk-configuration-metric-export-interval
               configuration)
              :to-equal 2.5d0)
      (expect (observability-kit:sdk-configuration-metric-export-timeout
               configuration)
              :to-equal 0.75d0)
      (expect (observability-kit:sdk-configuration-log-level configuration)
              :to-equal :debug)
      (expect (cdr (assoc "traceparent" headers :test #'string=))
              :to-be-truthy)
      (expect (cdr (assoc "baggage" headers :test #'string=))
              :to-be-falsy)
      (let ((sampler (observability-kit:sdk-configuration-trace-sampler
                      configuration)))
        (expect (funcall sampler nil "root" :internal nil)
                :to-equal :drop)
        (expect (funcall sampler context "child" :internal nil)
                :to-equal :record-and-sample))))
  (it "supports disabled and none and rejects malformed structural settings"
    (let ((configuration
            (observability-kit:read-sdk-configuration
             :environment '(("OTEL_SDK_DISABLED" . "true")
                            ("OTEL_PROPAGATORS" . "none")))))
      (expect (observability-kit:sdk-configuration-disabled-p configuration)
              :to-be-truthy)
      (expect (observability-kit:propagator-inject
               (observability-kit:sdk-configuration-propagator configuration)
               nil
               '(("x-request-id" . "req-2")))
              :to-equal '(("x-request-id" . "req-2")))
      (expect (observability-kit:sdk-configuration-metric-export-timeout
               configuration)
              :to-equal 30.0d0)
      (signals observability-kit:configuration-error
        (observability-kit:read-sdk-configuration
         :environment '(("OTEL_PROPAGATORS" . "tracecontext,unknown"))))
      (signals observability-kit:configuration-error
        (observability-kit:read-sdk-configuration
         :environment '(("OTEL_RESOURCE_ATTRIBUTES" . "missing-value"))))
      (signals observability-kit:configuration-error
        (observability-kit:read-sdk-configuration
         :environment '(("OTEL_METRIC_EXPORT_INTERVAL" . "0"))))))

  (it "configures ratio samplers and ignores invalid ratio arguments"
    (let* ((configuration
             (observability-kit:read-sdk-configuration
              :environment '(("OTEL_TRACES_SAMPLER" . "traceidratio")
                             ("OTEL_TRACES_SAMPLER_ARG" . "0"))))
           (sampler (observability-kit:sdk-configuration-trace-sampler configuration))
           (parent-configuration
             (observability-kit:read-sdk-configuration
              :environment '(("OTEL_TRACES_SAMPLER" . "parent_based_traceidratio")
                             ("OTEL_TRACES_SAMPLER_ARG" . "1"))))
           (parent-sampler
             (observability-kit:sdk-configuration-trace-sampler
              parent-configuration))
           (sampled-parent
             (observability-kit:make-instrumentation-context :trace-flags 1))
           (unsampled-parent
             (observability-kit:make-instrumentation-context :trace-flags 0))
           (invalid-argument
             (observability-kit:read-sdk-configuration
              :environment '(("OTEL_TRACES_SAMPLER" . "traceidratio")
                             ("OTEL_TRACES_SAMPLER_ARG" . "not-a-ratio"))))
           (fallback-sampler
             (observability-kit:sdk-configuration-trace-sampler
              invalid-argument)))
      (expect (funcall sampler nil "root" :internal nil
                       "ffffffffffffffffffffffffffffffff")
              :to-equal :drop)
      (expect (funcall parent-sampler nil "root" :internal nil
                       "00000000000000000000000000000000")
              :to-equal :record-and-sample)
      (expect (funcall parent-sampler unsampled-parent "child" :internal nil)
              :to-equal :drop)
      (expect (funcall parent-sampler sampled-parent "child" :internal nil)
              :to-equal :record-and-sample)
      (expect (funcall fallback-sampler nil "root" :internal nil
                       "ffffffffffffffffffffffffffffffff")
              :to-equal :record-and-sample)))

  (it "accepts the official parentbased sampler spellings"
    (let* ((parent-based
             (observability-kit:read-sdk-configuration
              :environment '( ("OTEL_TRACES_SAMPLER" . "parentbased_always_on"))))
           (parent-based-off
             (observability-kit:read-sdk-configuration
              :environment '( ("OTEL_TRACES_SAMPLER"
                               . "parentbased_always_off"))))
           (context
             (observability-kit:make-instrumentation-context :trace-flags 1)))
      (expect (funcall (observability-kit:sdk-configuration-trace-sampler
                        parent-based)
                       nil "root" :internal nil)
              :to-equal :record-and-sample)
      (expect (funcall (observability-kit:sdk-configuration-trace-sampler
                        parent-based-off)
                       nil "root" :internal nil)
              :to-equal :drop)
      (expect (funcall (observability-kit:sdk-configuration-trace-sampler
                        parent-based-off)
                       context "child" :internal nil)
              :to-equal :record-and-sample)))

  (it "configures supported B3 propagators"
    (let* ((configuration
             (observability-kit:read-sdk-configuration
              :environment
              '(("OTEL_PROPAGATORS" . "b3,b3multi"))))
           (context
             (observability-kit:make-instrumentation-context
              :trace-id "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
              :span-id "bbbbbbbbbbbbbbbb"
              :trace-flags 1))
           (headers
             (observability-kit:propagator-inject
              (observability-kit:sdk-configuration-propagator configuration)
              context nil))
           (extracted
             (observability-kit:propagator-extract
              (observability-kit:sdk-configuration-propagator configuration)
              headers)))
      (expect (cdr (assoc "b3" headers :test #'string-equal))
              :to-be-truthy)
      (expect (cdr (assoc "x-b3-traceid" headers :test #'string-equal))
              :to-be-truthy)
      (expect (instrumentation-context-trace-id extracted)
              :to-equal
              "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"))))

  (it "validates explicit environment entry shapes and values"
    (signals observability-kit:configuration-error
      (observability-kit:read-sdk-configuration
       :environment
       (cons '("OTEL_SERVICE_NAME" . "orders") :tail)))
    (signals observability-kit:configuration-error
      (observability-kit:read-sdk-configuration
       :environment (list :not-an-entry)))
    (signals observability-kit:configuration-error
      (observability-kit:read-sdk-configuration
       :environment (list (list "OTEL_SERVICE_NAME" "orders" "extra"))))
    (let ((configuration
            (observability-kit:read-sdk-configuration
             :environment (list (list "OTEL_SERVICE_NAME" "orders")))))
      (expect (observability-kit:sdk-configuration-service-name configuration)
              :to-equal "orders"))
    (signals observability-kit:configuration-error
      (observability-kit:read-sdk-configuration
       :environment (list (cons "" "orders"))))
    (signals observability-kit:configuration-error
      (observability-kit:read-sdk-configuration
       :environment (list (cons "OTEL_SERVICE_NAME" 10))))
    (signals observability-kit:configuration-error
      (observability-kit:read-sdk-configuration
       :environment (list (cons "OTEL_SERVICE_NAME" ""))))
    (signals observability-kit:configuration-error
      (observability-kit:read-sdk-configuration
       :environment (list (cons "OTEL_SERVICE_NAME" "one")
                          (cons "otel_service_name" "two")))))

  (it "configures baggage, boolean, and strategy boundaries"
    (let* ((configuration
             (observability-kit:read-sdk-configuration
              :environment '( ("OTEL_PROPAGATORS" . "baggage")
                              ("OTEL_SDK_DISABLED" . "unexpected")
                              ("OTEL_TRACES_SAMPLER" . "always_on")
                              ("OTEL_LOG_LEVEL" . "fatal"))))
           (context
             (observability-kit:make-instrumentation-context
              :trace-id "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
              :span-id "bbbbbbbbbbbbbbbb"
              :trace-flags 1
              :baggage '(("tenant" . "public"))))
           (headers
             (observability-kit:propagator-inject
              (observability-kit:sdk-configuration-propagator configuration)
              context nil))
           (extracted
             (observability-kit:propagator-extract
              (observability-kit:sdk-configuration-propagator configuration)
              headers)))
      (expect (observability-kit:sdk-configuration-disabled-p configuration)
              :to-be-falsy)
      (expect (observability-kit:sdk-configuration-log-level configuration)
              :to-equal :fatal)
      (expect (cdr (assoc "baggage" headers :test #'string-equal))
              :to-equal "tenant=public")
      (expect (instrumentation-context-baggage extracted)
              :to-equal '(("tenant" . "public")))
      (expect (observability-kit:sdk-configuration-trace-sampler configuration)
              :to-equal :always-on))
    (dolist (sampler-name '("always_off" "parent_based_always_on"))
      (let ((configuration
              (observability-kit:read-sdk-configuration
               :environment
               (list (cons "OTEL_TRACES_SAMPLER" sampler-name)))))
        (if (string= sampler-name "always_off")
            (expect (observability-kit:sdk-configuration-trace-sampler configuration)
                    :to-equal :always-off)
            (expect (functionp
                     (observability-kit:sdk-configuration-trace-sampler configuration))
                    :to-be-truthy))))
    (signals observability-kit:configuration-error
      (observability-kit:read-sdk-configuration
       :environment '( ("OTEL_TRACES_SAMPLER" . "made_up"))))
    (signals observability-kit:configuration-error
      (observability-kit:read-sdk-configuration
       :environment '( ("OTEL_LOG_LEVEL" . "verbose"))))
    (signals observability-kit:configuration-error
      (observability-kit:read-sdk-configuration
       :environment '( ("OTEL_METRIC_EXPORT_INTERVAL" . "not-a-duration"))))
    (signals observability-kit:configuration-error
      (observability-kit:read-sdk-configuration
       :environment '( ("OTEL_RESOURCE_ATTRIBUTES" . "key=value,"))))
    (signals observability-kit:configuration-error
      (observability-kit:read-sdk-configuration
       :environment '( ("OTEL_PROPAGATORS" . "tracecontext,"))))
    (signals observability-kit:configuration-error
      (observability-kit:read-sdk-configuration
       :environment '( ("OTEL_PROPAGATORS" . "b3,b3"))))
    (signals observability-kit:configuration-error
      (observability-kit:read-sdk-configuration
       :environment '( ("OTEL_PROPAGATORS" . "none,baggage")))))
