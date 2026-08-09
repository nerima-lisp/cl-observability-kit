(in-package #:observability-kit.test)

(defun sample-of (snapshot)
  (let ((samples (metric-snapshot-samples snapshot)))
    (expect (length samples) :to-equal 1)
    (first samples)))

(defun result-of (results name)
  (find name results :key #'health-result-name :test #'string=))

(describe "metric aggregation"
  (it "supports counters, gauges, and exact histogram values"
    (let* ((registry (make-metric-registry))
           (counter (define-counter registry requests_total
                      :help "Requests" :unit "requests"))
           (gauge (define-gauge registry queue_depth))
           (histogram (define-histogram registry request_latency
                        :buckets '(1 5))))
      (signals observability-error
        (define-histogram registry invalid_buckets :buckets 1))
      (expect (metric-kind counter) :to-equal :counter)
      (expect (metric-inc counter 2) :to-equal 2)
      (expect (metric-inc counter 3) :to-equal 5)
      (expect (metric-sample-value
               (sample-of (metric-snapshot counter)))
              :to-equal 5)

      (metric-set gauge 1/3)
      (expect (metric-inc gauge 2) :to-equal 7/3)
      (expect (metric-sample-value
               (sample-of (metric-snapshot gauge)))
              :to-equal 7/3)

      (expect (metric-observe histogram 1/3) :to-equal 1/3)
      (metric-observe histogram 6)
      (let* ((sample (sample-of (metric-snapshot histogram)))
             (buckets (metric-sample-buckets sample)))
        (expect (metric-sample-count sample) :to-equal 2)
        (expect (metric-sample-sum sample) :to-equal 19/3)
        (expect (mapcar #'cdr buckets) :to-equal '(1 1 2)))))

  (it-property "keeps counter increments exact"
      ((left (gen-integer :min 0 :max 100))
       (right (gen-integer :min 0 :max 100)))
    (let* ((registry (make-metric-registry))
           (counter (define-counter registry property_total)))
      (expect (metric-inc counter left) :to-equal left)
      (expect (metric-inc counter right) :to-equal (+ left right))))

  (it-property "applies generated gauge updates exactly"
      ((updates
         (gen-list
          (gen-tuple (gen-member '(:increment :set))
                     (gen-integer :min -100 :max 100))
          :min-length 1
          :max-length 12)))
    (let* ((registry (make-metric-registry))
           (gauge (define-gauge registry property_gauge))
           (expected 0))
      (dolist (update updates)
        (destructuring-bind (operation value) update
          (ecase operation
            (:increment
             (incf expected value)
             (expect (metric-inc gauge value) :to-equal expected))
            (:set
             (setf expected value)
             (expect (metric-set gauge value) :to-equal expected)))))
      (expect (metric-sample-value
               (sample-of (metric-snapshot gauge)))
              :to-equal expected)))

  (it "normalizes labels and keeps label sets bounded"
    (let* ((registry (make-metric-registry :max-label-value-length 8))
           (metric (define-counter registry http_requests_total
                     :label-names '("route" "method"))))
      (metric-inc metric 1
                  :labels '(("route" . "/health") ("method" . "GET")))
      (metric-inc metric :labels '("method" "GET" "route" "/health"))
      (let* ((snapshot (metric-snapshot metric))
             (sample (sample-of snapshot)))
        (expect (metric-snapshot-label-names snapshot)
                :to-equal '("method" "route"))
        (expect (metric-sample-labels sample)
                :to-equal '(("method" . "GET") ("route" . "/health")))
        (expect (metric-sample-value sample) :to-equal 2))
      (signals invalid-label-name
        (define-counter registry invalid_labels
                        :label-names '("bad-name")))
      (signals invalid-label-name
        (define-counter registry non_list_labels
                        :label-names "route"))
      (signals invalid-label-name
        (define-counter registry dotted_label_names
                        :label-names (cons "route" "method")))
      (signals program-error
        (macroexpand-1
         '(define-counter registry conflicting_label_options
           :label-names ("route")
           :labels nil)))
      (signals invalid-label-value
        (metric-inc metric 1
                    :labels '(("method" . "GET") ("route" . 42))))
      (signals invalid-label-set
        (metric-inc metric 1 :labels '(("method" . "GET"))))
      (signals invalid-label-set
        (metric-inc metric 1 :labels (cons "route" "/health")))
      (signals invalid-label-name
        (define-counter registry protected_labels
                        :label-names '("authorization")))))

  (it "rejects new label series after the cardinality limit"
    (let* ((registry (make-metric-registry))
           (metric (define-gauge registry worker_load
                     :label-names '("worker")
                     :cardinality-limit 2)))
      (metric-set metric 1 :labels '("worker" "one"))
      (metric-set metric 2 :labels '("worker" "two"))
      (metric-set metric 3 :labels '("worker" "one"))
      (signals metric-cardinality-exceeded
        (metric-set metric 4 :labels '("worker" "three")))))

  (it "returns deterministic and detached registry snapshots"
    (let* ((registry (make-metric-registry))
           (zeta (define-gauge registry zeta :label-names '("zone")))
           (alpha (define-counter registry alpha)))
      (metric-set zeta 2 :labels '("zone" "b"))
      (metric-set zeta 1 :labels '("zone" "a"))
      (metric-inc alpha 4)
      (let ((snapshots (metric-snapshot registry)))
        (expect (mapcar #'metric-snapshot-name snapshots)
                :to-equal '("alpha" "zeta"))
        (expect (mapcar #'metric-sample-labels
                        (metric-snapshot-samples (second snapshots)))
                :to-equal '((("zone" . "a")) (("zone" . "b")))))
        (let ((detached (metric-snapshot zeta)))
          (metric-set zeta 7 :labels '("zone" "a"))
          (expect (metric-sample-value
                   (first (metric-snapshot-samples detached)))
                  :to-equal 1))))

  (it "does not share mutable strings across API boundaries"
    (let* ((registry (make-metric-registry))
           (name (copy-seq "route"))
           (value (copy-seq "/health"))
           (context-value (copy-seq "blue"))
           (help (copy-seq "Request count"))
           (unit (copy-seq "requests"))
           (metric (define-counter registry requests_total
                     :help help
                     :unit unit
                     :label-names (list name)))
           (context (make-instrumentation-context
                     :attributes (list (cons "deployment" context-value)))))
      (metric-inc metric :labels (list (cons name value)))
      (setf (char name 0) #\x
            (char value 0) #\x
            (char context-value 0) #\x
            (char help 0) #\x
            (char unit 0) #\x)
      (expect (string= "Request count" (metric-help metric)))
      (expect (string= "requests" (metric-unit metric)))
      (let* ((snapshot (first (metric-snapshot registry)))
             (sample (first (metric-snapshot-samples snapshot))))
        (expect (= 1 (metric-sample-value sample)))
        (expect (string= "/health" (cdr (first (metric-sample-labels sample))))))
      (expect (string= "blue" (context-attribute context "deployment")))))

  (it "keeps snapshot accessors detached"
    (let* ((registry (make-metric-registry))
           (histogram (define-histogram registry snapshot_boundary
                         :help "Latency"
                         :unit "seconds"
                         :label-names '(route)
                         :buckets '(1 2))))
      (metric-observe histogram 1 :labels '(route "/health"))
      (let* ((snapshot (metric-snapshot histogram))
             (name (metric-snapshot-name snapshot))
             (help (metric-snapshot-help snapshot))
             (unit (metric-snapshot-unit snapshot))
             (label-names (metric-snapshot-label-names snapshot))
             (samples (metric-snapshot-samples snapshot))
             (sample (first samples))
             (labels (metric-sample-labels sample))
             (buckets (metric-sample-buckets sample)))
        (setf (char name 0) #\X
              (char help 0) #\X
              (char unit 0) #\X
              (char (first label-names) 0) #\X
              (char (car (first labels)) 0) #\X
              (char (cdr (first labels)) 0) #\X
              (cdr (first buckets)) 99
              (cdr samples) nil)
        (expect (metric-snapshot-name snapshot) :to-equal "snapshot_boundary")
        (expect (metric-snapshot-help snapshot) :to-equal "Latency")
        (expect (metric-snapshot-unit snapshot) :to-equal "seconds")
        (expect (metric-snapshot-label-names snapshot) :to-equal '("route"))
        (expect (length (metric-snapshot-samples snapshot)) :to-equal 1)
        (expect (metric-sample-labels
                 (first (metric-snapshot-samples snapshot)))
                :to-equal '(("route" . "/health")))
        (expect (cdr (first (metric-sample-buckets
                             (first (metric-snapshot-samples snapshot)))))
                :to-equal 1))))

  (it "keeps concurrent counter updates lossless"
    (let* ((registry (make-metric-registry))
           (counter (define-counter registry concurrent_total))
           (threads
             (loop repeat 4
                   collect
                   (cl-concurrent-kit:make-thread
                    (lambda ()
                      (loop repeat 1000
                        do (metric-inc counter)))))))
      (dolist (thread threads)
        (cl-concurrent-kit:join-thread thread))
      (expect (metric-sample-value
               (sample-of (metric-snapshot counter)))
              :to-equal 4000))))

  (it "keeps concurrent gauge and histogram updates exact"
    (let* ((registry (make-metric-registry))
           (gauge (define-gauge registry concurrent_gauge))
           (histogram (define-histogram registry concurrent_histogram))
           (threads
             (loop repeat 4
                   collect
                   (cl-concurrent-kit:make-thread
                    (lambda ()
                      (loop repeat 1000
                            do (progn
                                 (metric-inc gauge)
                                 (metric-observe histogram 1))))))))
      (dolist (thread threads)
        (cl-concurrent-kit:join-thread thread))
      (let ((gauge-sample (sample-of (metric-snapshot gauge)))
            (histogram-sample (sample-of (metric-snapshot histogram))))
        (expect (metric-sample-value gauge-sample) :to-equal 4000)
        (expect (metric-sample-count histogram-sample) :to-equal 4000)
        (expect (metric-sample-sum histogram-sample) :to-equal 4000))))

  (it "keeps cardinality bounded under concurrent series creation"
    (let* ((registry (make-metric-registry :default-cardinality-limit 2))
           (counter (define-counter registry concurrent_labels_total
                      :label-names '(worker)))
           (threads
             (loop for worker in '("a" "b" "c" "d")
                   collect
                   (let ((label worker))
                     (cl-concurrent-kit:make-thread
                      (lambda ()
                        (handler-case
                            (metric-inc counter
                                        :labels (list 'worker label))
                          (metric-cardinality-exceeded () nil))))))))
      (dolist (thread threads)
        (cl-concurrent-kit:join-thread thread))
      (expect (length (metric-snapshot-samples (metric-snapshot counter)))
              :to-equal 2)))

(describe "health checks"
  (it "isolates failures and reports an aggregate status"
    (let ((registry (make-health-registry)))
      (register-health-check
       registry "healthy" (lambda (token) (declare (ignore token)) t))
      (register-health-check
       registry "unhealthy" (lambda (token) (declare (ignore token)) nil))
      (register-health-check
       registry "broken"
       (lambda (token)
         (declare (ignore token))
         (error "isolated check failure")))
      (let ((results (run-health-checks registry)))
        (expect (length results) :to-equal 3)
        (expect (health-result-status (result-of results "healthy"))
                :to-equal :pass)
        (expect (health-result-status (result-of results "unhealthy"))
                :to-equal :fail)
        (expect (health-result-status (result-of results "broken"))
                :to-equal :fail)
        (expect (health-result-condition (result-of results "broken"))
                :to-be-truthy)
        (expect (health-status results) :to-equal :unhealthy)
        (expect (health-status registry) :to-equal :unhealthy))))

  (it "keeps liveness and readiness filters distinct"
    (let ((registry (make-health-registry)))
      (register-health-check
       registry "process" (lambda (token) (declare (ignore token)) t)
       :kind :liveness)
      (register-health-check
       registry "dependencies" (lambda (token) (declare (ignore token)) t)
       :kind :readiness)
      (register-health-check
       registry "startup" (lambda (token) (declare (ignore token)) t)
       :kind :startup)
      (let ((results (run-health-checks registry :kind :liveness)))
        (expect (length results) :to-equal 1)
        (expect (health-result-kind (first results)) :to-equal :liveness)
        (expect (health-status registry :kind :liveness)
                :to-equal :healthy)
        (expect (health-status registry :kind :readiness)
                :to-equal :unknown)
        (expect (health-status registry :kind :startup)
                :to-equal :unknown))
      (let ((results (run-health-checks registry :kind :readiness)))
        (expect (length results) :to-equal 1)
        (expect (health-result-kind (first results)) :to-equal :readiness)
        (expect (health-status registry :kind :readiness)
                :to-equal :healthy))
      (let ((results (run-health-checks registry :kind :startup)))
        (expect (length results) :to-equal 1)
        (expect (health-result-kind (first results)) :to-equal :startup)
        (expect (health-status registry :kind :startup)
                :to-equal :healthy)
        (expect (health-status registry :kind :readiness)
                :to-equal :unknown))))

  (it "cancels a run before starting its checks"
    (let* ((registry (make-health-registry))
           (token (make-cancellation-token)))
      (register-health-check
       registry "cancelled" (lambda (check-token)
                               (declare (ignore check-token))
                               (error "must not run")))
      (cancel-cancellation-token token :shutdown)
      (let ((result (first (run-health-checks registry
                                              :cancellation-token token))))
        (expect (health-result-status result) :to-equal :cancelled)
        (expect (typep (health-result-condition result)
                       'health-check-cancelled)
                :to-be-truthy))))

  (it "enforces a timeout for a non-cooperative check on SBCL"
    (let ((finished nil)
          (registry (make-health-registry :default-timeout 0.02d0
                                          :cancellation-grace-period 0.01d0)))
      (register-health-check
       registry "slow" (lambda (token)
                          (declare (ignore token))
                          (sleep 1)
                          (setf finished t)
                          t))
      (let ((result (first (run-health-checks registry))))
        (expect (health-result-status result) :to-equal :timeout)
        (expect (health-result-condition result) :to-be-truthy)
        #+sbcl
        (progn
          (sleep 0.05)
          (expect finished :to-equal nil))))))

(describe "instrumentation context"
  (it "validates, sorts, and immutably extends context metadata"
    (let* ((context
             (make-instrumentation-context
              :trace-id "trace-1"
              :span-id "span-1"
              :trace-flags 1
              :attributes '(("service" . "api") ("region" . "test"))
              :baggage '(("tenant" . "public"))))
           (extended (context-with-attributes
                      context
                      '(("version" . "2") ("service" . "worker"))))
           (overridden (context-with-attribute context "service" "job")))
      (expect (instrumentation-context-attributes context)
              :to-equal '(("region" . "test") ("service" . "api")))
      (expect (instrumentation-context-baggage context)
              :to-equal '(("tenant" . "public")))
      (expect (context-attribute extended "service") :to-equal "worker")
      (expect (context-attribute extended "version") :to-equal "2")
      (expect (context-attribute overridden "service") :to-equal "job")
      (expect (context-attribute context "version") :to-be nil)
      (signals unsafe-attribute-name
        (make-instrumentation-context
         :attributes '(("api-token" . "secret"))))
      (signals unsafe-attribute-name
        (context-with-attribute context 42 "value"))))

  (it "supports dynamic scope and detached capture"
    (let* ((context (make-instrumentation-context :trace-id "trace-2"))
           (captured
             (with-instrumentation-context (context)
               (expect (current-instrumentation-context) :to-be context)
               (capture-instrumentation-context))))
      (expect (current-instrumentation-context :missing) :to-be :missing)
      (expect (instrumentation-context-trace-id captured) :to-equal "trace-2")
      (expect (eq captured context) :to-be nil)
      (let ((seen nil))
        (with-captured-instrumentation-context (context)
          (setf seen (current-instrumentation-context)))
        (expect (instrumentation-context-trace-id seen) :to-equal "trace-2")))))
