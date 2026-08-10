#.(progn
    (in-package #:observability-kit)
    nil)

"Configuration parsing for the process-wide OpenTelemetry-compatible SDK boundary.

The parser deliberately returns data and strategy objects rather than mutating a
global provider.  Applications can use the result to construct the providers
they need while retaining ownership of their lifecycle."

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

(defun %configuration-trim (value)
  (string-trim '(#\Space #\Tab #\Return #\Linefeed) value))

(defun %configuration-designator-string (value name)
  (handler-case
      (let ((string (%designator-string value)))
        (if (plusp (length string))
            string
            (%configuration-error name "Configuration names must not be empty.")))
    (error ()
      (%configuration-error name "Configuration names must be strings or symbols."))))

(defun %configuration-entry-value (pair name)
  (let ((tail (cdr pair)))
    (cond
      ((stringp tail) tail)
      ((null tail) nil)
      ((and (consp tail) (null (cdr tail))) (car tail))
      (t (%configuration-error name
                               "Configuration entries must be name/value pairs.")))))

(defun %configuration-environment (environment supplied-p)
  (if (not supplied-p)
      (loop for name in +sdk-configuration-environment-names+
            for value = (uiop:getenv name)
            when value collect (cons name value))
      (progn
        (unless (proper-list-p environment)
          (%configuration-error :environment
                                "The supplied environment must be a proper alist."))
        (let ((seen (make-hash-table :test #'equal))
              (normalized nil))
          (dolist (pair environment (nreverse normalized))
            (unless (consp pair)
              (%configuration-error :environment
                                    "The supplied environment must be an alist."))
            (let* ((name (%configuration-designator-string
                          (car pair) :environment))
                   (normalized-name (string-upcase name))
                   (value (%configuration-entry-value pair normalized-name)))
              (when (gethash normalized-name seen)
                (%configuration-error normalized-name
                                      "A configuration variable was supplied more than once."))
              (setf (gethash normalized-name seen) t)
              (when (and value (not (stringp value)))
                (%configuration-error normalized-name
                                      "Configuration values must be strings."))
              (push (cons normalized-name value) normalized)))))))

(defun %configuration-value (environment name)
  (cdr (assoc name environment :test #'string=)))

(defun %configuration-nonempty-value (environment name)
  (let ((value (%configuration-value environment name)))
    (when value
      (let ((trimmed (%configuration-trim value)))
        (if (plusp (length trimmed))
            (copy-seq trimmed)
            (%configuration-error name "The configuration value must not be empty."))))))

(defun %configuration-split-list (value name)
  (let ((trimmed (%configuration-trim value)))
    (when (zerop (length trimmed))
      (%configuration-error name "The comma-separated configuration value must not be empty."))
    (let ((start 0)
          (tokens nil))
      (loop
        (let* ((end (position #\, trimmed :start start))
               (token (%configuration-trim
                       (subseq trimmed start end))))
          (when (zerop (length token))
            (%configuration-error name "Comma-separated configuration values cannot be empty."))
          (push token tokens)
          (if end
              (setf start (1+ end))
              (return (nreverse tokens))))))))

(defun %configuration-resource-attributes (environment)
  (let ((raw (%configuration-value environment "OTEL_RESOURCE_ATTRIBUTES")))
    (if (or (null raw)
            (zerop (length (%configuration-trim raw))))
        nil
        (let ((pairs nil))
          (dolist (token (%configuration-split-list raw
                                                    "OTEL_RESOURCE_ATTRIBUTES"))
            (let ((separator (position #\= token)))
              (unless separator
                (%configuration-error
                 "OTEL_RESOURCE_ATTRIBUTES"
                 "Resource attributes must use key=value entries."))
              (let ((name (%configuration-trim (subseq token 0 separator)))
                    (value (%configuration-trim (subseq token (1+ separator)))))
                (when (zerop (length name))
                  (%configuration-error
                   "OTEL_RESOURCE_ATTRIBUTES"
                   "Resource attribute names must not be empty."))
                (push (cons name value) pairs))))
          (handler-case
              (%normalize-attributes (nreverse pairs))
            (validation-error (condition)
              (%configuration-error
               "OTEL_RESOURCE_ATTRIBUTES"
               (observability-error-message condition))))))))

(defun %configuration-resource-attributes-with-service-name
    (environment attributes)
  (let* ((configured-service-name
           (%configuration-nonempty-value environment "OTEL_SERVICE_NAME"))
         (resource-service-name
           (cdr (assoc "service.name" attributes :test #'string=)))
         (service-name (or configured-service-name resource-service-name)))
    (values service-name
            (if configured-service-name
                (%normalize-attributes
                 (cons (cons "service.name" configured-service-name)
                       (remove "service.name" attributes
                               :key #'car :test #'string=)))
                attributes))))

(defun %configuration-boolean (environment name default)
  (let ((value (%configuration-value environment name)))
    (if (null value)
        default
        (let ((token (string-downcase (%configuration-trim value))))
          (cond
            ((string= token "true") t)
            ((or (zerop (length token)) (string= token "false")) nil)
            (t default))))))

(defun %configuration-duration (environment name default-milliseconds)
  (let ((value (%configuration-value environment name)))
    (if (null value)
        (/ default-milliseconds 1000.0d0)
        (let ((milliseconds
                (handler-case
                    (parse-integer (%configuration-trim value)
                                   :junk-allowed nil)
                  (error () nil))))
          (if (and (integerp milliseconds) (> milliseconds 0))
              (/ milliseconds 1000.0d0)
              (%configuration-error
               name
               "Duration configuration values must be positive integer milliseconds."))))))

(defun %configuration-token (value)
  (substitute #\- #\_
              (string-downcase (%configuration-trim value))))

(defun %configuration-propagation-headers (headers names)
  (remove-if-not (lambda (pair)
                   (member (car pair) names :test #'string-equal))
                 (%header-list headers)))

(defun %configuration-inject-propagation-kind (context headers names)
  (let* ((normalized (%header-list headers))
         (base (remove-if (lambda (pair)
                            (member (car pair) names :test #'string-equal))
                          normalized))
         (propagated (%configuration-propagation-headers
                      (and context (inject-trace-context context nil))
                      names)))
    (append propagated base)))

(defun %configuration-extract-baggage (headers)
  (let* ((normalized (%configuration-propagation-headers headers '("baggage")))
         (value (cdr (assoc "baggage" normalized :test #'string-equal))))
    (when value
      (handler-case
          (make-instrumentation-context :baggage (parse-baggage value))
        (propagation-error () nil)))))

(defun %configuration-propagator-for-token (token)
  (cond
    ((string= token "tracecontext")
     (make-propagator
      :inject (lambda (context headers)
                (%configuration-inject-propagation-kind
                 context headers '("traceparent" "tracestate")))
      :extract (lambda (headers)
                 (extract-trace-context headers))))
    ((string= token "baggage")
     (make-propagator
      :inject (lambda (context headers)
                (%configuration-inject-propagation-kind
                 context headers '("baggage")))
      :extract #'%configuration-extract-baggage))
    ((string= token "b3")
     (make-b3-propagator))
    ((string= token "b3multi")
     (make-b3-multi-propagator))
    ((string= token "jaeger")
     (make-jaeger-propagator))
    ((string= token "xray")
     (make-xray-propagator))
    (t
     (%configuration-error "OTEL_PROPAGATORS"
                           "The configured propagator is not supported."))))

(defun %configuration-propagator (environment)
  (let* ((raw (or (%configuration-value environment "OTEL_PROPAGATORS")
                  "tracecontext,baggage"))
         (tokens (mapcar #'%configuration-token
                         (%configuration-split-list raw "OTEL_PROPAGATORS")))
         (seen (make-hash-table :test #'equal)))
    (dolist (token tokens)
      (when (gethash token seen)
        (%configuration-error "OTEL_PROPAGATORS"
                              "A propagator was configured more than once."))
      (setf (gethash token seen) t)
      (unless (member token '("tracecontext" "baggage" "b3" "b3multi"
                              "jaeger" "xray" "none")
                      :test #'string=)
        (%configuration-error
         "OTEL_PROPAGATORS"
         "Supported propagators are tracecontext, baggage, b3, b3multi, jaeger, xray, and none.")))
    (if (member "none" tokens :test #'string=)
        (if (= 1 (length tokens))
            (make-composite-propagator)
            (%configuration-error
             "OTEL_PROPAGATORS"
             "The none propagator cannot be combined with another propagator."))
        (if (and (= 2 (length tokens))
                 (member "tracecontext" tokens :test #'string=)
                 (member "baggage" tokens :test #'string=))
            (make-w3c-propagator)
            (apply #'make-composite-propagator
                   (mapcar #'%configuration-propagator-for-token tokens))))))

(defun %configuration-parent-sampled-p (context)
  (and context
       (let ((flags (instrumentation-context-trace-flags context)))
         (and (integerp flags) (logbitp 0 flags)))))

(defun %configuration-parent-sampler (root-decision)
  (make-parent-based-sampler root-decision))

(defun %configuration-sampler-ratio (environment)
  (let ((raw (%configuration-value environment "OTEL_TRACES_SAMPLER_ARG")))
    (if (or (null raw)
            (zerop (length (%configuration-trim raw))))
        1d0
        (let ((trimmed (%configuration-trim raw)))
          (handler-case
              (let ((*read-eval* nil))
                (multiple-value-bind (value position)
                    (read-from-string trimmed nil nil)
                  (if (and (= position (length trimmed))
                           (realp value)
                           (%finite-real-p value)
                           (<= 0 value 1))
                      (coerce value 'double-float)
                      1d0)))
            (error () 1d0))))))

(defun %configuration-sampler (environment)
  (let* ((configured (%configuration-value environment "OTEL_TRACES_SAMPLER"))
         (raw (if (and configured
                       (plusp (length (%configuration-trim configured))))
                  configured
                  "parent_based_always_on"))
         (sampler (%configuration-token raw))
         (ratio (%configuration-sampler-ratio environment)))
    (cond
      ((string= sampler "always-on") :always-on)
      ((string= sampler "always-off") :always-off)
      ((member sampler '("parent-based-always-on" "parentbased-always-on")
               :test #'string=)
       (%configuration-parent-sampler :always-on))
      ((member sampler '("parent-based-always-off" "parentbased-always-off")
               :test #'string=)
       (%configuration-parent-sampler :always-off))
      ((string= sampler "traceidratio")
       (make-trace-id-ratio-sampler ratio))
      ((member sampler '("parent-based-traceidratio"
                         "parentbased-traceidratio")
               :test #'string=)
       (make-parent-based-sampler
        (make-trace-id-ratio-sampler ratio)))
      (t
       (%configuration-error
        "OTEL_TRACES_SAMPLER"
        "Supported samplers are always_on, always_off, traceidratio, parentbased_always_on, parentbased_always_off, and parentbased_traceidratio.")))))

(defun %configuration-log-level (environment)
  (let ((value (or (%configuration-value environment "OTEL_LOG_LEVEL")
                   "info")))
    (let ((token (%configuration-token value)))
      (cond
        ((string= token "trace") :trace)
        ((string= token "debug") :debug)
        ((string= token "info") :info)
        ((string= token "warn") :warn)
        ((string= token "error") :error)
        ((string= token "fatal") :fatal)
        (t (%configuration-error
            "OTEL_LOG_LEVEL"
            "Supported log levels are trace, debug, info, warn, error, and fatal."))))))

(defun read-sdk-configuration (&key (environment nil environment-supplied-p))
  "Read standard OTEL_* settings from the process environment or an alist.

The returned configuration is detached from the supplied alist and contains a
propagator and sampler strategy ready to pass to provider constructors."
  (let* ((environment (%configuration-environment environment
                                                   environment-supplied-p))
         (disabled-p (%configuration-boolean environment
                                             "OTEL_SDK_DISABLED"
                                             nil))
         (attributes (%configuration-resource-attributes environment)))
    (multiple-value-bind (service-name attributes)
        (%configuration-resource-attributes-with-service-name
         environment attributes)
      (%make-sdk-configuration
       disabled-p
       service-name
       attributes
       (%configuration-propagator environment)
       (%configuration-duration environment "OTEL_METRIC_EXPORT_INTERVAL" 60000)
       (%configuration-duration environment "OTEL_METRIC_EXPORT_TIMEOUT" 30000)
       (%configuration-sampler environment)
       (%configuration-log-level environment)))))
