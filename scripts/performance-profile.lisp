(require "asdf")

(defparameter *script-directory*
  (uiop:pathname-directory-pathname
   (or *load-truename* *default-pathname-defaults*)))

(load (merge-pathnames "bootstrap.lisp" *script-directory*))
(observability-kit.bootstrap:initialize-source-registry)
(asdf:load-system "cl-observability-kit/prometheus")
(require :sb-sprof)

(defpackage #:observability-kit.performance-profile
  (:use #:cl #:observability-kit)
  (:import-from #:observability-kit/prometheus
                #:render-prometheus))

(in-package #:observability-kit.performance-profile)

(defparameter *sink* nil)

(defun %profile-rendering ()
  (let* ((registry (make-metric-registry))
         (counter (define-counter registry rendered_requests))
         (gauge (define-gauge registry active_requests
                              :label-names '("method" "route")))
         (histogram (define-histogram registry request_latency
                                  :label-names '("method"))))
    (dotimes (index 16)
      (let ((route (format nil "/items/~D" index)))
        (metric-inc counter)
        (metric-set gauge index
                    :labels (list (cons "method" "GET")
                                  (cons "route" route)))
        (metric-observe histogram (/ index 10)
                        :labels (list (cons "method" "GET")))))
    (format t "profile=render-prometheus mode=alloc iterations=10000~%")
    (sb-sprof:with-profiling (:mode :alloc
                               :max-samples 10000
                               :report :flat
                               :reset t)
      (dotimes (ignore 10000)
        (setf *sink* (render-prometheus registry))))))

(handler-case
    (progn
      (%profile-rendering)
      (finish-output)
      (uiop:quit 0))
  (error (condition)
    (format *error-output* "Performance profile failed (~S): ~A~%"
            (type-of condition)
            condition)
    (uiop:print-condition-backtrace condition :stream *error-output*)
    (uiop:quit 1)))
