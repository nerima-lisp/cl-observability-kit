#.(progn
    (in-package #:observability-kit)
    nil)

(defun %health-monotonic-time (clock)
  (cl-boundary-kit:clock-monotonic clock))

(defun %health-deadline (clock timeout)
  (and timeout
       (+ (%health-monotonic-time clock)
          (ceiling (* timeout internal-time-units-per-second)))))

(defun %wait-for-health-thread (thread token clock timeout)
  (let ((deadline (%health-deadline clock timeout)))
    (loop
      (when (cancellation-requested-p token)
        (return-from %wait-for-health-thread
          (values :cancelled nil nil)))
      (let* ((now (%health-monotonic-time clock))
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

(defun %health-duration-since (clock started)
  (/ (- (%health-monotonic-time clock) started)
     internal-time-units-per-second))

(defun %start-health-thread (worker name)
  (cl-concurrent-kit:make-thread worker :name name))

(defun %attempt-health-thread-operation (operation &rest arguments)
  "Call a thread cleanup OPERATION and return any error as a second value."
  (block attempt
    (handler-bind
        ((error
           (lambda (condition)
             (return-from attempt (values nil condition)))))
      (values (apply operation arguments) nil))))

(defun %stop-health-thread (thread token check reason
                            &optional (controller *health-thread-controller*))
  (cancel-cancellation-token token reason)
  (let ((grace (health-check-cancellation-grace-period check))
        (join-thread (%health-thread-controller-join-thread controller))
        (thread-alive-p (%health-thread-controller-thread-alive-p controller))
        (terminate-thread (%health-thread-controller-terminate-thread controller))
        (cleanup-condition nil))
    (multiple-value-bind (ignored condition)
        (%attempt-health-thread-operation
         join-thread thread :default nil :timeout grace)
      (declare (ignore ignored))
      (setf cleanup-condition (or cleanup-condition condition)))
    (when (funcall thread-alive-p thread)
      (multiple-value-bind (ignored condition)
          (%attempt-health-thread-operation terminate-thread thread)
        (declare (ignore ignored))
        (setf cleanup-condition (or cleanup-condition condition)))
      (multiple-value-bind (ignored condition)
          (%attempt-health-thread-operation
           join-thread thread :default nil :timeout grace)
        (declare (ignore ignored))
        (setf cleanup-condition (or cleanup-condition condition)))
      (setf cleanup-condition
            (or cleanup-condition
                (make-condition
                 'health-error
                 :check-name (health-check-name check)
                 :kind (health-check-kind check)
                 :message (format nil
                                 "Health check ~S did not stop after cancellation."
                                  (health-check-name check))))))
    cleanup-condition))
