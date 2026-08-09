#.(progn
    (in-package #:observability-kit)
    nil)

(defun make-cancellation-token (&key parent)
  "Create a cancellation token, optionally inheriting PARENT cancellation.

Cancellation is monotonic.  A check receives a child token, so cancelling a
run does not mutate a token owned by its caller."
  (when parent
    (check-type parent cancellation-token))
  (%make-cancellation-token (cl-concurrent-kit:make-lock :name "observability-cancellation")
                            nil nil parent))

(defun cancel-cancellation-token (token &optional (reason :cancelled))
  "Request cancellation of TOKEN and return TOKEN.

The request is cooperative for check code.  RUN-HEALTH-CHECKS also enforces
the request at the configured cancellation boundary when a worker remains
alive."
  (check-type token cancellation-token)
  (cl-concurrent-kit:with-lock-held ((%cancellation-token-lock token))
    (unless (%cancellation-token-cancelled-p token)
      (setf (%cancellation-token-cancelled-p token) t
            (%cancellation-token-reason token) reason)))
  token)

(defun cancellation-requested-p (token)
  "Return true when TOKEN or one of its parents has been cancelled."
  (check-type token cancellation-token)
  (multiple-value-bind (cancelled parent)
      (cl-concurrent-kit:with-lock-held ((%cancellation-token-lock token))
        (values (%cancellation-token-cancelled-p token)
                (%cancellation-token-parent token)))
    (or cancelled
        (and parent (cancellation-requested-p parent)))))

(defun cancellation-reason (token)
  "Return TOKEN's local cancellation reason or its parent's reason."
  (check-type token cancellation-token)
  (multiple-value-bind (cancelled reason parent)
      (cl-concurrent-kit:with-lock-held ((%cancellation-token-lock token))
        (values (%cancellation-token-cancelled-p token)
                (%cancellation-token-reason token)
                (%cancellation-token-parent token)))
    (cond
      (cancelled reason)
      (parent (cancellation-reason parent))
      (t nil))))

(defun %validate-health-duration (value what &key allow-nil)
  (unless (and allow-nil (null value))
    (unless (and (realp value) (%finite-real-p value) (plusp value))
      (error 'observability-error
             :message (format nil "~A must be a positive finite number, got ~S."
                              what value))))
  value)

(defun %validate-health-clock (clock)
  (handler-case
      (progn
        (cl-boundary-kit:clock-now clock)
        (cl-boundary-kit:clock-monotonic clock)
        clock)
    (error ()
      (error 'observability-error
             :message (format nil
                              "Health clock must implement the cl-boundary-kit clock protocol, got ~S."
                              clock)))))

(defun %normalize-health-name (name)
  (let ((normalized (%designator-string name)))
    (unless (and normalized
                 (plusp (length normalized))
                 (or (%ascii-letter-p (char normalized 0))
                     (char= (char normalized 0) #\_))
                 (loop for character across normalized
                       always (or (%ascii-letter-p character)
                                  (%ascii-digit-p character)
                                  (member character '(#\_ #\- #\.)))))
      (error 'health-error
             :check-name name
             :kind nil
             :message (format nil "Invalid health check name ~S." name)))
    (when (%sensitive-name-p normalized)
      (error 'health-error
             :check-name name
             :kind nil
             :message (format nil "Health check name ~S is reserved for sensitive data."
                              name)))
    normalized))

(defun %normalize-health-kind (kind)
  (let ((normalized (%designator-string kind)))
    (unless (member normalized '("liveness" "readiness" "startup") :test #'string=)
      (error 'health-error
             :check-name nil
             :kind kind
             :message (format nil
                              "Health check kind must be LIVENESS, READINESS, or STARTUP; got ~S."
                              kind)))
    (intern (string-upcase normalized) :keyword)))

(defun %validate-health-function (function)
  (unless (or (functionp function)
              (and (symbolp function) (fboundp function)))
    (error 'observability-error
           :message (format nil "Health check function must be a function designator, got ~S."
                            function)))
  function)

(defun make-health-registry (&rest option-list)
  "Create a registry for independent LIVENESS, READINESS, and STARTUP checks.

DEFAULT-TIMEOUT may be NIL to disable the per-check deadline.  A positive
  CANCELLATION-GRACE-PERIOD is used before the SBCL worker is forcefully
  terminated if it ignores cancellation.  CLOCK supplies wall and monotonic
  time through cl-boundary-kit's public clock protocol.  MONOTONIC-UNITS-PER-SECOND
  names the number of monotonic clock units in one second; it defaults to
  INTERNAL-TIME-UNITS-PER-SECOND for the standard clock."
  (let* ((options (%parse-keyword-options
                   option-list
                   '(:default-timeout :cancellation-grace-period :clock
                     :monotonic-units-per-second)
                   "MAKE-HEALTH-REGISTRY"))
         (default-timeout (%option-value options :default-timeout 5.0d0))
         (cancellation-grace-period
           (%option-value options :cancellation-grace-period 0.1d0))
         (clock (%option-value options :clock (cl-boundary-kit:make-clock)))
         (monotonic-units-per-second
           (%option-value options :monotonic-units-per-second
                          internal-time-units-per-second)))
    (%validate-health-duration default-timeout "Default health timeout" :allow-nil t)
    (%validate-health-duration cancellation-grace-period
                               "Health cancellation grace period")
    (%validate-health-duration monotonic-units-per-second
                               "Health monotonic clock units per second")
    (%validate-health-clock clock)
    (%make-health-registry
     (cl-concurrent-kit:make-lock :name "observability-health")
     (make-hash-table :test #'equal)
     default-timeout
     cancellation-grace-period
     clock
     monotonic-units-per-second
     nil)))

(defun health-registry-clock (registry)
  "Return the clock used for health deadlines and result durations."
  (check-type registry health-registry)
  (%health-registry-clock registry))

(defun health-registry-monotonic-units-per-second (registry)
  "Return the monotonic clock units that make up one second."
  (check-type registry health-registry)
  (%health-registry-monotonic-units-per-second registry))
