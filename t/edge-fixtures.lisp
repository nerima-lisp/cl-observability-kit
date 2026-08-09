(in-package #:observability-kit.test)

(defun edge-health-pass (token)
  (declare (ignore token))
  t)

(defun edge-health-fail (token)
  (declare (ignore token))
  nil)

(defun edge-health-signal (token)
  (declare (ignore token))
  (error "edge health failure"))

(defun edge-health-cancel (token)
  (cancel-cancellation-token token :inside-check)
  (sleep 0.2d0)
  t)

(defun edge-health-await-cancellation (token)
  (loop until (cancellation-requested-p token)
        do (sleep 0.001d0))
  :stopped)

(defun edge-health-slow (token)
  (declare (ignore token))
  (sleep 0.2d0)
  t)

(defun edge-circular-list ()
  (let ((list (list :cycle)))
    (setf (cdr list) list)
    list))

(defun edge-sample (name type &key (value nil value-supplied-p) (labels nil))
  (declare (ignore name type))
  (observability-kit::%make-metric-sample
   labels
   (when value-supplied-p value)
   nil
   nil
   nil))
