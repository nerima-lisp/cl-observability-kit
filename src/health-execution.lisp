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

(defun %health-deadline (timeout)
  (and timeout
       (+ (get-internal-real-time)
          (ceiling (* timeout internal-time-units-per-second)))))

(defun %stop-health-thread (thread token check reason
                            &optional (controller *health-thread-controller*))
  (cancel-cancellation-token token reason)
  (let ((grace (health-check-cancellation-grace-period check))
        (join-thread (%health-thread-controller-join-thread controller))
        (thread-alive-p (%health-thread-controller-thread-alive-p controller))
        (terminate-thread (%health-thread-controller-terminate-thread controller)))
    (ignore-errors
      (funcall join-thread thread :default nil :timeout grace))
    (when (funcall thread-alive-p thread)
      (ignore-errors (funcall terminate-thread thread))
      (ignore-errors
        (funcall join-thread thread :default nil :timeout grace)))
    (when (funcall thread-alive-p thread)
      (make-condition 'health-error
                      :check-name (health-check-name check)
                      :kind (health-check-kind check)
                      :message (format nil
                                       "Health check ~S did not stop after cancellation."
                                       (health-check-name check))))))

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
               thread :default nil :timeout wait)
            (unless (null status)
              (return-from %wait-for-health-thread
                (values status value condition)))))))))

(defun %health-duration-since (started)
  (/ (- (get-internal-real-time) started)
     internal-time-units-per-second))

(defun %run-health-check (check parent-token)
  (let* ((started (get-internal-real-time))
         (child-token (make-cancellation-token :parent parent-token)))
    (if (cancellation-requested-p parent-token)
        (make-health-result
         :name (health-check-name check)
         :kind (health-check-kind check)
         :status :cancelled
         :condition (make-condition 'health-check-cancelled
                                    :check-name (health-check-name check)
                                    :kind (health-check-kind check))
         :duration (%health-duration-since started))
        (let ((thread
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
                               (health-check-name check)))))
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
                  :duration (%health-duration-since started))))))))))

(defun %run-health-check-cps (check parent-token continuation)
  "Run CHECK and pass one isolated result to CONTINUATION.

Keeping the continuation boundary explicit makes failure isolation and the
ordered registry reduction independent from the check implementation."
  (funcall continuation (%run-health-check check parent-token)))

(defun %store-health-results (registry results)
  (cl-concurrent-kit:with-lock-held ((%health-registry-lock registry))
    (setf (%health-registry-last-results registry) (copy-list results)))
  results)

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
         (checks (%selected-health-checks registry normalized-kinds)))
    (labels ((proceed (remaining reversed)
               (if (null remaining)
                   (%store-health-results registry (nreverse reversed))
                   (%run-health-check-cps
                    (first remaining)
                     parent
                     (lambda (result)
                       (proceed (rest remaining) (cons result reversed)))))))
      (proceed checks nil))))

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
            :message "Cannot determine health status for the supplied object."))))
