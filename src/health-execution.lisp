#.(progn
    (in-package #:observability-kit)
    nil)

(defun %normalize-health-kinds (kind kinds)
  (when (and kind kinds)
    (error 'observability-error
           :message "RUN-HEALTH-CHECKS accepts KIND or KINDS, not both."))
  (when (and kinds (not (proper-list-p kinds)))
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

(defun %invoke-health-check (check token)
  "Invoke CHECK and convert a signalled condition into a result tuple."
  (block invoke
    (handler-bind
        ((condition
           (lambda (caught-condition)
             (return-from invoke
               (values :fail nil caught-condition)))))
      (let ((value (funcall (health-check-function check) token)))
        (values (if value :pass :fail) value nil)))))

(defun %health-cancellation-condition (check status)
  (case status
    (:timeout
     (make-condition 'health-check-timeout
                     :check-name (health-check-name check)
                     :kind (health-check-kind check)))
    (:cancelled
     (make-condition 'health-check-cancelled
                     :check-name (health-check-name check)
                     :kind (health-check-kind check)))))

(defun %health-result-for-status (check status clock started
                                  &key value condition)
  (make-health-result
   :name (health-check-name check)
   :kind (health-check-kind check)
   :status status
   :value value
   :condition condition
   :duration (%health-duration-since clock started)))

(defun %health-thread-name (check)
  (format nil "health-~A-~A"
          (string-downcase (symbol-name (health-check-kind check)))
          (health-check-name check)))

(defun %health-result-after-thread
    (check thread child-token status value condition clock started)
  (case status
    ((:pass :fail)
     (%health-result-for-status check status clock started
                                :value value
                                :condition condition))
    ((:timeout :cancelled)
     (%health-result-for-status
      check status clock started
      :condition (or (%stop-health-thread thread child-token check status)
                     (%health-cancellation-condition check status))))))

(defun %cancelled-health-result (check clock started)
  (%health-result-for-status
   check :cancelled clock started
   :condition (%health-cancellation-condition check :cancelled)))

(defun %run-health-check (check parent-token clock continuation)
  "Run CHECK and pass one isolated result to CONTINUATION.

The continuation is the only exit from the worker boundary. Keeping it
explicit makes the ordered registry reduction independent from the check
implementation and keeps timeout cleanup on the same path as normal results."
  (let* ((started (%health-monotonic-time clock))
         (child-token (make-cancellation-token :parent parent-token)))
    (if (cancellation-requested-p parent-token)
        (funcall continuation
                 (%cancelled-health-result check clock started))
        (let ((thread
                (%start-health-thread
                 (lambda ()
                   (%invoke-health-check check child-token))
                 (%health-thread-name check))))
          (multiple-value-bind (status value condition)
              (%wait-for-health-thread
               thread child-token clock (health-check-timeout check))
            (funcall continuation
                     (%health-result-after-thread
                      check thread child-token status value condition
                      clock started)))))))

(defun %store-health-results (registry results)
  (cl-concurrent-kit:with-lock-held ((%health-registry-lock registry))
    (setf (%health-registry-last-results registry) (copy-list results)))
  results)

(defun %run-health-check-sequence (checks parent clock continuation)
  "Run CHECKS in order and pass their results to CONTINUATION."
  (if (null checks)
      (funcall continuation nil)
      (%run-health-check
       (first checks)
       parent
       clock
       (lambda (result)
         (%run-health-check-sequence
          (rest checks)
          parent
          clock
          (lambda (remaining-results)
            (funcall continuation
                     (cons result remaining-results))))))))

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
         (clock (health-registry-clock registry))
         (checks (%selected-health-checks registry normalized-kinds)))
    (%run-health-check-sequence
     checks
     parent
     clock
     (lambda (results)
       (%store-health-results registry results)))))
