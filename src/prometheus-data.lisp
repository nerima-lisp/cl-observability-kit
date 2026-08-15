(in-package #:observability-kit/prometheus)

(setf *default-histogram-boundary-strings*
      (let ((cache (make-hash-table :test #'eql)))
        (dolist (boundary observability-kit::*default-histogram-buckets* cache)
          (setf (gethash boundary cache)
                (%format-float-number boundary)))))
