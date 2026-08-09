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
