(require "asdf")

(defparameter *script-directory*
  (uiop:pathname-directory-pathname
   (or *load-truename* *default-pathname-defaults*)))

(load (merge-pathnames "bootstrap.lisp" *script-directory*))
(observability-kit.bootstrap:initialize-source-registry)
(asdf:load-system "cl-observability-kit/prometheus")
(asdf:load-system "cl-observability-kit/otlp")

(defpackage #:observability-kit.performance-benchmark
  (:use #:cl #:observability-kit)
  (:import-from #:observability-kit/prometheus
                #:render-prometheus)
  (:import-from #:observability-kit/otlp
                #:registry->otlp))

(in-package #:observability-kit.performance-benchmark)

(defparameter *sink* nil)

(defun %measure (name iterations thunk)
  (funcall thunk (min 1000 iterations))
  #+sbcl (sb-ext:gc :full t)
  (let ((start-time (get-internal-real-time))
        (start-bytes #+sbcl (sb-ext:get-bytes-consed) #-sbcl 0))
    (funcall thunk iterations)
    (let* ((elapsed (- (get-internal-real-time) start-time))
           (seconds (/ elapsed (float internal-time-units-per-second)))
           (bytes (- #+sbcl (sb-ext:get-bytes-consed) #-sbcl 0
                     start-bytes)))
      (format t
              "benchmark=~A iterations=~D seconds=~,6F ns/op=~,1F bytes/op=~,1F~%"
              name
              iterations
              seconds
              (* 1d9 (/ seconds iterations))
              (/ bytes iterations)))))

(defun %label (method route)
  (list (cons "method" method)
        (cons "route" route)))

(defun %run ()
  (let* ((registry (make-metric-registry))
         (counter (define-counter registry requests))
         (labeled-counter
           (define-counter registry route_count
                           :label-names '("method" "route")))
         (histogram
           (define-histogram registry request_duration
                             :label-names '("method")))
         (render-registry (make-metric-registry))
         (render-counter (define-counter render-registry rendered_requests))
         (render-gauge
           (define-gauge render-registry active_requests
                         :label-names '("method" "route")))
         (render-histogram
           (define-histogram render-registry request_latency
                             :label-names '("method")))
         (labels (%label "GET" "/items"))
         (method-label (list (cons "method" "GET"))))
    (dotimes (index 16)
      (let ((route (format nil "/items/~D" index)))
        (metric-inc render-counter)
        (metric-set render-gauge index :labels (%label "GET" route))
        (metric-observe render-histogram (/ index 10) :labels method-label)))
    (format t "implementation=~A version=~A~%"
            (lisp-implementation-type)
            (lisp-implementation-version))
    (%measure "metric-inc/no-labels" 100000
              (lambda (iterations)
                (dotimes (ignore iterations)
                  (setf *sink* (metric-inc counter)))))
    (%measure "metric-inc/two-labels" 100000
              (lambda (iterations)
                (dotimes (ignore iterations)
                  (setf *sink* (metric-inc labeled-counter :labels labels)))))
    (%measure "metric-observe/one-label" 100000
              (lambda (iterations)
                (dotimes (ignore iterations)
                  (setf *sink* (metric-observe histogram 0.125d0
                                                 :labels method-label)))))
    (%measure "metric-snapshot/registry" 1000
              (lambda (iterations)
                (dotimes (ignore iterations)
                  (setf *sink* (metric-snapshot render-registry)))))
    (let ((rendered nil))
      (%measure "render-prometheus/registry" 1000
                (lambda (iterations)
                  (dotimes (ignore iterations)
                    (setf rendered (render-prometheus render-registry)))))
      (unless (and (stringp rendered)
                   (plusp (length rendered))
                   (search "# HELP " rendered)
                   (search "_bucket{" rendered)
                   (search "le=\"+Inf\"" rendered))
        (error "Prometheus benchmark did not produce the expected non-empty exposition.")))
    (let ((otlp-output nil))
      (%measure "registry->otlp/registry" 1000
                (lambda (iterations)
                  (dotimes (ignore iterations)
                    (setf otlp-output (registry->otlp render-registry)))))
      (unless (and (listp otlp-output) otlp-output)
        (error "OTLP benchmark did not produce a non-empty list.")))
    (%measure "capture-context/three-attributes" 100000
              (let ((context
                      (make-instrumentation-context
                       :trace-id "trace"
                       :span-id "span"
                       :attributes '(("component" . "api")
                                     ("region" . "test")
                                     ("version" . "1")))))
                (lambda (iterations)
                  (dotimes (ignore iterations)
                    (setf *sink* (capture-instrumentation-context context))))))
    nil))

(handler-case
    (progn
      (%run)
      (finish-output)
      (uiop:quit 0))
  (error (condition)
    (format *error-output* "Performance benchmark failed (~S): ~A~%"
            (type-of condition)
            condition)
    (uiop:print-condition-backtrace condition :stream *error-output*)
    (uiop:quit 1)))
