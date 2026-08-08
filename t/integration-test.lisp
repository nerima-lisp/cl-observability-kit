(in-package #:observability-kit.test)

(defun string-alist-value (name alist)
  (cdr (assoc name alist :test #'string=)))

(defun otlp-metric-by-name (document name)
  (find name
        (string-alist-value "metrics" document)
        :key (lambda (metric)
               (string-alist-value "name" metric))
        :test #'string=))

(describe "OTLP-shaped export"
  (it "preserves zero and exact Common Lisp values at the adapter boundary"
    (let* ((registry (make-metric-registry))
           (counter (define-counter registry "zero_total"))
           (gauge (define-gauge registry "ratio"))
           (histogram (define-histogram registry "latency"
                         :buckets '(1 2))))
      (declare (ignore counter))
      (metric-set gauge 0)
      (metric-observe histogram 0)
      (let* ((document (observability-kit/otlp:registry->otlp
                        registry :scope-name "example" :scope-version "1"))
             (counter-document (otlp-metric-by-name document "zero_total"))
             (gauge-document (otlp-metric-by-name document "ratio"))
             (histogram-document (otlp-metric-by-name document "latency")))
        (expect (string-alist-value "scope" document)
                :to-equal '( ("name" . "example") ("version" . "1")))
        (expect (mapcar (lambda (metric)
                          (string-alist-value "name" metric))
                        (string-alist-value "metrics" document))
                :to-equal '("latency" "ratio" "zero_total"))
        (let* ((counter-point
                 (first (string-alist-value
                         "data-points" counter-document)))
               (gauge-point
                 (first (string-alist-value
                        "data-points" gauge-document)))
               (histogram-point
                 (first (string-alist-value
                        "data-points" histogram-document))))
          (expect (cdr (assoc "value" counter-point :test #'string=))
                  :to-equal 0)
          (expect (cdr (assoc "value" gauge-point :test #'string=))
                  :to-equal 0)
          (expect (string-alist-value "count" histogram-point) :to-equal 1)
          (expect (string-alist-value "sum" histogram-point) :to-equal 0)
          (expect (string-alist-value "explicit-bounds" histogram-point)
                  :to-equal '(1 2))
          (expect (string-alist-value "bucket-counts" histogram-point)
                  :to-equal '(1 0 0))
          (let ((snapshot (first (metric-snapshot registry))))
            (signals observability-error
              (observability-kit/otlp:registry->otlp
               (cons snapshot snapshot)))))))))

(describe "cl-log-kit integration"
  (it "adds context fields without taking ownership of logging"
    (let ((records nil))
      (let* ((handler
               (log-kit:make-function-handler
                (lambda (record)
                  (push record records))))
             (logger (log-kit:make-logger
                      :handler handler
                      :clock (lambda () 1))))
        (let ((context
                (make-instrumentation-context
                 :trace-id "trace-1"
                 :span-id "span-1"
                 :trace-flags 1
                 :attributes '(("service" . "api"))
                 :baggage '(("tenant" . "public")))))
          (observability-kit/log-kit:with-log-kit-context (context)
            (log-kit:log-info logger "hello" :event "test")))
        (expect (length records) :to-equal 1)
        (let ((fields (log-kit:log-record-fields (first records))))
          (expect (cdr (assoc :event fields)) :to-equal "test")
          (expect (cdr (assoc :observability-trace-id fields))
                  :to-equal "trace-1")
          (expect (cdr (assoc :observability-span-id fields))
                  :to-equal "span-1")
          (expect (cdr (assoc :observability-attributes fields))
                  :to-equal '(("service" . "api")))
          (expect (cdr (assoc :observability-baggage fields))
                  :to-equal '(("tenant" . "public"))))))))

(describe "public quick start"
  (it "uses only the public metric and exporter APIs"
    (let* ((registry (make-metric-registry))
           (requests (define-counter registry "requests_total"
                       :help "Requests"
                       :label-names '("method")))
           (in-flight (define-gauge registry "in_flight")))
      (metric-inc requests 1 :labels '("method" "GET"))
      (metric-set in-flight 2)
      (let ((text (observability-kit/prometheus:render-prometheus registry)))
        (expect (search "requests_total{method=\"GET\"} 1" text)
                :to-be-truthy)
        (expect (search "in_flight 2" text) :to-be-truthy)))))
