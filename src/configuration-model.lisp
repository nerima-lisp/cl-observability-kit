#.(progn
    (in-package #:observability-kit)
    nil)

"The immutable data model returned by the SDK configuration parser."

(defparameter +sdk-configuration-environment-names+
  '("OTEL_SDK_DISABLED"
    "OTEL_SERVICE_NAME"
    "OTEL_RESOURCE_ATTRIBUTES"
    "OTEL_PROPAGATORS"
    "OTEL_METRIC_EXPORT_INTERVAL"
    "OTEL_METRIC_EXPORT_TIMEOUT"
    "OTEL_TRACES_SAMPLER"
    "OTEL_TRACES_SAMPLER_ARG"
    "OTEL_LOG_LEVEL"))

(defstruct (sdk-configuration
            (:constructor %make-sdk-configuration
                (disabled-p service-name resource-attributes propagator
                 metric-export-interval metric-export-timeout trace-sampler
                 log-level))
            (:conc-name %sdk-configuration-))
  disabled-p
  service-name
  resource-attributes
  propagator
  metric-export-interval
  metric-export-timeout
  trace-sampler
  log-level)

(defun %configuration-error (name message)
  (error 'configuration-error :name name :message message))

(defun sdk-configuration-disabled-p (configuration)
  (check-type configuration sdk-configuration)
  (not (null (%sdk-configuration-disabled-p configuration))))

(defun sdk-configuration-service-name (configuration)
  (check-type configuration sdk-configuration)
  (and (%sdk-configuration-service-name configuration)
       (copy-seq (%sdk-configuration-service-name configuration))))

(defun sdk-configuration-resource-attributes (configuration)
  (check-type configuration sdk-configuration)
  (%copy-alist (%sdk-configuration-resource-attributes configuration)))

(defun sdk-configuration-resource (configuration)
  (check-type configuration sdk-configuration)
  (make-resource :attributes
                 (sdk-configuration-resource-attributes configuration)))

(defun sdk-configuration-propagator (configuration)
  (check-type configuration sdk-configuration)
  (%sdk-configuration-propagator configuration))

(defun sdk-configuration-metric-export-interval (configuration)
  (check-type configuration sdk-configuration)
  (%sdk-configuration-metric-export-interval configuration))

(defun sdk-configuration-metric-export-timeout (configuration)
  (check-type configuration sdk-configuration)
  (%sdk-configuration-metric-export-timeout configuration))

(defun sdk-configuration-trace-sampler (configuration)
  (check-type configuration sdk-configuration)
  (%sdk-configuration-trace-sampler configuration))

(defun sdk-configuration-log-level (configuration)
  (check-type configuration sdk-configuration)
  (%sdk-configuration-log-level configuration))
