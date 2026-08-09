#.(progn
    (in-package #:observability-kit)
    nil)

(define-condition observability-error (error)
  ((message :initarg :message :reader observability-error-message))
  (:report (lambda (condition stream)
             (write-string (observability-error-message condition) stream))))

(define-condition validation-error (observability-error)
  ())

(define-condition invalid-metric-name (validation-error)
  ((name :initarg :name :reader invalid-metric-name-name))
  (:default-initargs :message "Invalid metric name."))

(define-condition invalid-label-name (validation-error)
  ((name :initarg :name :reader invalid-label-name-name))
  (:default-initargs :message "Invalid label name."))

(define-condition invalid-label-value (validation-error)
  ((name :initarg :name :reader invalid-label-value-name)
   (value :initarg :value :reader invalid-label-value-value))
  (:default-initargs :message "Invalid label value."))

(define-condition invalid-label-set (validation-error)
  ((labels :initarg :labels :reader invalid-label-set-labels)
   (reason :initarg :reason :reader invalid-label-set-reason))
  (:default-initargs :message "Labels do not match the metric definition."))

(define-condition unsafe-attribute-name (validation-error)
  ((name :initarg :name :reader unsafe-attribute-name-name))
  (:default-initargs :message "The attribute name is reserved for sensitive data."))

(define-condition metric-definition-conflict (observability-error)
  ((name :initarg :name :reader metric-definition-conflict-name)
   (existing :initarg :existing :reader metric-definition-conflict-existing))
  (:default-initargs :message "A metric with the same name has an incompatible definition."))

(define-condition metric-cardinality-exceeded (observability-error)
  ((name :initarg :name :reader metric-cardinality-exceeded-name)
   (limit :initarg :limit :reader metric-cardinality-exceeded-limit)
   (labels :initarg :labels :reader metric-cardinality-exceeded-labels))
  (:default-initargs :message "The metric label cardinality limit was reached."))

(define-condition metric-operation-error (observability-error)
  ((metric :initarg :metric :reader metric-operation-error-metric)
   (operation :initarg :operation :reader metric-operation-error-operation))
  (:default-initargs :message "The operation is not valid for this metric."))

(define-condition health-error (observability-error)
  ((check-name :initarg :check-name :reader health-error-check-name)
   (kind :initarg :kind :reader health-error-kind)))

(define-condition health-check-timeout (health-error)
  ()
  (:default-initargs :message "The health check exceeded its timeout."))

(define-condition health-check-cancelled (health-error)
  ()
  (:default-initargs :message "The health check was cancelled."))
