(in-package #:observability-kit)

(defstruct (cancellation-token
            (:constructor %make-cancellation-token
                (lock cancelled-p reason parent))
            (:conc-name %cancellation-token-))
  lock
  cancelled-p
  reason
  parent)

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

(defstruct (health-registry
            (:constructor %make-health-registry
                (lock checks default-timeout cancellation-grace-period last-results))
            (:conc-name %health-registry-))
  lock
  checks
  default-timeout
  cancellation-grace-period
  last-results)

(defstruct (health-check
            (:constructor %make-health-check
                (name kind function timeout cancellation-grace-period))
            (:conc-name health-check-))
  name
  kind
  function
  timeout
  cancellation-grace-period)

(defstruct health-result
  name
  kind
  status
  value
  condition
  duration)

(defun %validate-health-duration (value what &key allow-nil)
  (unless (and allow-nil (null value))
    (unless (and (realp value) (%finite-real-p value) (plusp value))
      (error 'observability-error
             :message (format nil "~A must be a positive finite number, got ~S."
                              what value))))
  value)

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

(defun make-health-registry (&key (default-timeout 5.0d0)
                                  (cancellation-grace-period 0.1d0))
  "Create a registry for independent LIVENESS, READINESS, and STARTUP checks.

DEFAULT-TIMEOUT may be NIL to disable the per-check deadline.  A positive
CANCELLATION-GRACE-PERIOD is used before the SBCL worker is forcefully
terminated if it ignores cancellation."
  (%validate-health-duration default-timeout "Default health timeout" :allow-nil t)
  (%validate-health-duration cancellation-grace-period
                             "Health cancellation grace period")
  (%make-health-registry
   (cl-concurrent-kit:make-lock :name "observability-health")
   (make-hash-table :test #'equal)
   default-timeout
   cancellation-grace-period
   nil))

(defun health-registry-checks (registry)
  "Return REGISTRY's checks in deterministic kind/name order."
  (check-type registry health-registry)
  (cl-concurrent-kit:with-lock-held ((%health-registry-lock registry))
    (sort (loop for check being the hash-values of (%health-registry-checks registry)
                collect check)
          (lambda (left right)
            (or (string< (symbol-name (health-check-kind left))
                         (symbol-name (health-check-kind right)))
                (and (string= (symbol-name (health-check-kind left))
                              (symbol-name (health-check-kind right)))
                     (string< (health-check-name left)
                              (health-check-name right))))))))

(defun health-registry-last-results (registry)
  "Return a copy of the most recently completed run's results, or NIL."
  (check-type registry health-registry)
  (cl-concurrent-kit:with-lock-held ((%health-registry-lock registry))
    (copy-list (%health-registry-last-results registry))))

(defun register-health-check (registry name function
                              &key (kind :readiness)
                                (timeout nil timeout-supplied-p)
                                (cancellation-grace-period nil grace-supplied-p)
                                replace)
  "Register a check whose FUNCTION accepts one CANCELLATION-TOKEN argument.

The function returns a true value for success and NIL for a normal health
failure.  Signalled conditions are isolated and recorded as failures.  A
compatible registration is replaced only when REPLACE is true."
  (check-type registry health-registry)
  (let* ((normalized-name (%normalize-health-name name))
         (normalized-kind (%normalize-health-kind kind))
         (normalized-function (%validate-health-function function))
         (normalized-timeout
           (if timeout-supplied-p
               (%validate-health-duration timeout "Health check timeout" :allow-nil t)
               (%health-registry-default-timeout registry)))
         (normalized-grace
           (if grace-supplied-p
               (%validate-health-duration cancellation-grace-period
                                          "Health check cancellation grace period")
               (%health-registry-cancellation-grace-period registry)))
         (key (list normalized-kind normalized-name)))
    (let ((check (%make-health-check normalized-name normalized-kind
                                     normalized-function normalized-timeout
                                     normalized-grace)))
      (cl-concurrent-kit:with-lock-held ((%health-registry-lock registry))
        (when (and (gethash key (%health-registry-checks registry))
                   (not replace))
          (error 'health-error
                 :check-name normalized-name
                 :kind normalized-kind
                 :message (format nil
                                  "Health check ~S/~S is already registered."
                                  normalized-kind normalized-name)))
        (setf (gethash key (%health-registry-checks registry)) check))
      check)))

(defun unregister-health-check (registry name &key (kind :readiness))
  "Remove and return a registered check, or NIL when it was absent."
  (check-type registry health-registry)
  (let ((key (list (%normalize-health-kind kind)
                   (%normalize-health-name name))))
    (cl-concurrent-kit:with-lock-held ((%health-registry-lock registry))
      (multiple-value-bind (check present-p)
          (gethash key (%health-registry-checks registry))
        (when present-p
          (remhash key (%health-registry-checks registry)))
        (and present-p check)))))

(defun %normalize-health-kinds (kind kinds)
  (when (and kind kinds)
    (error 'observability-error
           :message "RUN-HEALTH-CHECKS accepts KIND or KINDS, not both."))
  (when (and kinds (not (%proper-list-p kinds)))
    (error 'observability-error
           :message "Health check kinds must be supplied as a list."))
  (cond
    (kind (list (%normalize-health-kind kind)))
    (kinds (remove-duplicates (mapcar #'%normalize-health-kind kinds)))
    (t nil)))

(defun %selected-health-checks (registry kinds)
  (let ((checks (health-registry-checks registry)))
    (if kinds
        (remove-if-not (lambda (check)
                         (member (health-check-kind check) kinds))
                       checks)
        checks)))

(defparameter +health-join-marker+ (gensym "HEALTH-JOIN-MARKER-"))

(defun %health-deadline (timeout)
  (and timeout
       (+ (get-internal-real-time)
          (ceiling (* timeout internal-time-units-per-second)))))

(defun %stop-health-thread (thread token check reason)
  (cancel-cancellation-token token reason)
  (let ((grace (health-check-cancellation-grace-period check))
        (termination-condition nil))
    (ignore-errors
      (cl-concurrent-kit:join-thread thread
                                     :default +health-join-marker+
                                     :timeout grace))
    (when (cl-concurrent-kit:thread-alive-p thread)
      #+sbcl
      (handler-case
          (sb-thread:terminate-thread thread)
        (condition (condition)
          (setf termination-condition
                (make-condition 'health-error
                                :check-name (health-check-name check)
                                :kind (health-check-kind check)
                                :message (format nil
                                                 "Unable to terminate health check ~S: ~A."
                                                 (health-check-name check)
                                                 condition)))))
      #-sbcl
      (setf termination-condition
            (make-condition 'health-error
                            :check-name (health-check-name check)
                            :kind (health-check-kind check)
                            :message "This implementation cannot enforce health check termination."))
      (ignore-errors
        (cl-concurrent-kit:join-thread thread
                                       :default +health-join-marker+
                                       :timeout grace)))
    (when (cl-concurrent-kit:thread-alive-p thread)
      (or termination-condition
          (make-condition 'health-error
                          :check-name (health-check-name check)
                          :kind (health-check-kind check)
                          :message (format nil
                                           "Health check ~S did not stop after cancellation."
                                           (health-check-name check)))))))

(defun %wait-for-health-thread (thread token timeout)
  (let ((deadline (%health-deadline timeout)))
    (loop
      (when (cancellation-requested-p token)
        (return-from %wait-for-health-thread
          (values :cancelled nil nil)))
      (let* ((now (get-internal-real-time))
             (remaining (and deadline
                             (/ (- deadline now)
                                internal-time-units-per-second))))
        (when (and remaining (not (plusp remaining)))
          (return-from %wait-for-health-thread
            (values :timeout nil nil)))
        (let ((wait (if remaining
                        (max 0.001d0 (min 0.05d0 remaining))
                        0.05d0)))
          (multiple-value-bind (status value condition)
              (cl-concurrent-kit:join-thread
               thread :default +health-join-marker+ :timeout wait)
            (unless (eq status +health-join-marker+)
              (return-from %wait-for-health-thread
                (values status value condition)))))))))

(defun %health-duration-since (started)
  (/ (- (get-internal-real-time) started)
     internal-time-units-per-second))

(defun %run-health-check (check parent-token)
  (let* ((started (get-internal-real-time))
         (child-token (make-cancellation-token :parent parent-token))
         (thread nil))
    (if (cancellation-requested-p parent-token)
        (make-health-result
         :name (health-check-name check)
         :kind (health-check-kind check)
         :status :cancelled
         :condition (make-condition 'health-check-cancelled
                                    :check-name (health-check-name check)
                                    :kind (health-check-kind check))
         :duration (%health-duration-since started))
        (handler-case
            (progn
              (setf thread
                    (cl-concurrent-kit:make-thread
                     (lambda ()
                       (handler-case
                           (let ((value (funcall (health-check-function check)
                                                 child-token)))
                             (values (if value :pass :fail) value nil))
                         (condition (condition)
                           (values :fail nil condition))))
                     :name (format nil "health-~A-~A"
                                   (string-downcase
                                    (symbol-name (health-check-kind check)))
                                   (health-check-name check))))
              (multiple-value-bind (status value condition)
                  (%wait-for-health-thread
                   thread child-token (health-check-timeout check))
                (case status
                  ((:pass :fail)
                   (make-health-result
                    :name (health-check-name check)
                    :kind (health-check-kind check)
                    :status status
                    :value value
                    :condition condition
                    :duration (%health-duration-since started)))
                  (:timeout
                   (let ((stop-condition
                           (%stop-health-thread thread child-token check :timeout)))
                     (make-health-result
                      :name (health-check-name check)
                      :kind (health-check-kind check)
                      :status :timeout
                      :condition (or stop-condition
                                     (make-condition 'health-check-timeout
                                                     :check-name (health-check-name check)
                                                     :kind (health-check-kind check)))
                      :duration (%health-duration-since started))))
                  (:cancelled
                   (let ((stop-condition
                           (%stop-health-thread thread child-token check :cancelled)))
                     (make-health-result
                      :name (health-check-name check)
                      :kind (health-check-kind check)
                      :status :cancelled
                      :condition (or stop-condition
                                     (make-condition 'health-check-cancelled
                                                     :check-name (health-check-name check)
                                                     :kind (health-check-kind check)))
                      :duration (%health-duration-since started)))))))
          (condition (condition)
            (make-health-result
             :name (health-check-name check)
             :kind (health-check-kind check)
             :status :fail
             :condition condition
             :duration (%health-duration-since started)))))))

(defun run-health-checks (registry &key kind kinds cancellation-token)
  "Run selected checks and return isolated HEALTH-RESULT structures.

KIND or KINDS filters the run.  Every check receives a child token.  A
  timeout first requests cancellation, waits the configured grace period, and
  then terminates a still-running SBCL worker before its result is returned."
  (check-type registry health-registry)
  (when cancellation-token
    (check-type cancellation-token cancellation-token))
  (let* ((normalized-kinds (%normalize-health-kinds kind kinds))
         (parent (or cancellation-token (make-cancellation-token)))
         (checks (%selected-health-checks registry normalized-kinds))
         (results
           (mapcar (lambda (check)
                     (handler-case
                         (%run-health-check check parent)
                       (condition (condition)
                         (make-health-result
                          :name (health-check-name check)
                          :kind (health-check-kind check)
                          :status :fail
                          :condition condition
                          :duration 0))))
                   checks)))
    (cl-concurrent-kit:with-lock-held ((%health-registry-lock registry))
      (setf (%health-registry-last-results registry) (copy-list results)))
    results))

(defun %health-status-for-result (result)
  (if (eq (health-result-status result) :pass)
      :healthy
      :unhealthy))

(defun %health-status-for-results (results)
  (cond
    ((null results) :unknown)
    ((some (lambda (result)
             (not (eq (health-result-status result) :pass)))
           results)
     :unhealthy)
    (t :healthy)))

(defun health-status (object &key kind)
  "Return :HEALTHY, :UNHEALTHY, or :UNKNOWN for results or a registry.

For a registry, this reports the last completed run and never starts checks.
Use RUN-HEALTH-CHECKS explicitly when a fresh observation is required."
  (cond
    ((health-result-p object)
     (%health-status-for-result object))
    ((health-registry-p object)
     (let* ((results (health-registry-last-results object))
            (normalized-kind (and kind (%normalize-health-kind kind))))
       (%health-status-for-results
        (if normalized-kind
            (remove-if-not (lambda (result)
                             (eq (health-result-kind result) normalized-kind))
                           results)
            results))))
    ((%proper-list-p object)
     (unless (every #'health-result-p object)
       (error 'observability-error
              :message "HEALTH-STATUS received a list containing a non-result."))
     (let ((results (if kind
                        (let ((normalized-kind (%normalize-health-kind kind)))
                          (remove-if-not (lambda (result)
                                           (eq (health-result-kind result)
                                               normalized-kind))
                                         object))
                        object)))
       (%health-status-for-results results)))
    (t
     (error 'observability-error
            :message (format nil "Cannot determine health status for ~S." object)))))
