(in-package #:observability-kit.test)

(describe "Prometheus exposition"
  (it "escapes text, sorts metrics and labels, and renders histograms"
    (let* ((slash (string #\\))
           (quote (string #\"))
           (newline (string #\Newline))
           (return (string #\Return))
           (label-value (concatenate 'string
                                     "a" slash "b" quote "c" newline return))
           (escaped-label (concatenate 'string
                                       "a" slash slash "b"
                                       slash quote "c"
                                       slash "n" slash "r"))
           (help (concatenate 'string
                              "line" slash "one" newline "two" return "three"))
           (escaped-help (concatenate 'string
                                      "line" slash slash "one"
                                      slash "n" "two" slash "r" "three"))
           (registry (make-metric-registry))
           (zeta (define-gauge registry zeta
                   :help help
                   :unit "items"
                   :label-names '("route" "method")))
           (alpha (define-counter registry alpha_total :help "Alpha"))
           (histogram (define-histogram registry latency_seconds
                         :help "Latency"
                         :buckets '(1 2))))
      (metric-set zeta 1
                  :labels (list "route" label-value "method" "GET"))
      (metric-inc alpha 2)
      (metric-observe histogram 1)
      (metric-observe histogram 3)
      (let ((text (observability-kit/prometheus:render-prometheus registry)))
        (expect (search (concatenate 'string "# HELP zeta " escaped-help)
                        text)
                :to-be-truthy)
        (expect (search (concatenate 'string
                                     "zeta{method=\"GET\",route=\""
                                     escaped-label "\"} 1")
                        text)
                :to-be-truthy)
        (expect (search "# UNIT zeta items" text) :to-be-truthy)
        (expect (search "latency_seconds_bucket{le=\"1\"} 1" text)
                :to-be-truthy)
        (expect (search "latency_seconds_bucket{le=\"2\"} 1" text)
                :to-be-truthy)
        (expect (search "latency_seconds_bucket{le=\"+Inf\"} 2" text)
                :to-be-truthy)
        (expect (search "latency_seconds_sum 4" text) :to-be-truthy)
        (expect (search "latency_seconds_count 2" text) :to-be-truthy)
        (let ((alpha-position (search "# HELP alpha_total" text))
              (zeta-position (search "# HELP zeta" text)))
          (expect (< alpha-position zeta-position) :to-be-truthy))
        (expect
         (with-output-to-string (stream)
           (observability-kit/prometheus:render-prometheus
            registry :stream stream))
         :to-equal text)
        (let ((snapshot (first (metric-snapshot registry))))
          (signals observability-error
            (observability-kit/prometheus:render-prometheus
             (cons snapshot snapshot))))))))

(describe "export safety boundaries"
  (it "rejects sensitive label and context names before export"
    (let ((registry (make-metric-registry)))
      (signals invalid-metric-name
        (define-counter registry authorization_total
                        :label-names '("authorization")))
      (signals unsafe-attribute-name
        (make-instrumentation-context
         :attributes '(("access-token" . "secret"))))
      (let ((metric (define-counter registry safe_total
                      :label-names '("route"))))
        (metric-inc metric 1 :labels '("route" "/health"))
        (let ((text (observability-kit/prometheus:render-prometheus registry)))
          (expect (null (search "authorization" text)) :to-be-truthy)
          (expect (null (search "secret" text)) :to-be-truthy))))))

(describe "exporter fuzz boundaries"
  (it-fuzz "renders generated label values without crashing"
      ((label-value
         (gen-string
          :min-length 0
          :max-length 12
          :alphabet (concatenate 'string
                                 "abc_/"
                                 (string #\\)
                                 (string #\")
                                 (string #\Newline)
                                 (string #\Return)))))
      (:trials 40 :timeout-per-trial 1)
    (let* ((registry (make-metric-registry))
           (metric (define-gauge registry fuzz_value
                     :label-names '("route"))))
      (metric-set metric 1 :labels (list "route" label-value))
      (let ((text (observability-kit/prometheus:render-prometheus registry)))
        (expect (search "# TYPE fuzz_value gauge" text) :to-be-truthy)
        (expect (search "fuzz_value{route=\"" text) :to-be-truthy)
        (expect (search "\"} 1" text) :to-be-truthy)
        (expect (= 3 (count #\Newline text)) :to-be-truthy)
        (expect (= 0 (count #\Return text)) :to-be-truthy)
        (expect (= (+ 2 (count #\" label-value))
                   (count #\" text))
                :to-be-truthy)
        (expect (= (+ (count #\" label-value)
                      (* 2 (count #\\ label-value))
                      (count #\Newline label-value)
                      (count #\Return label-value))
                   (count #\\ text))
                :to-be-truthy)))))
