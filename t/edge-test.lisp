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

(describe "metric API boundaries"
  (it "validates registry definitions and exposes immutable metadata"
    (let* ((registry (make-metric-registry
                      :default-cardinality-limit 2
                      :max-label-value-length 4))
           (counter (define-counter registry edge_requests_total
                      :help "Requests"
                      :unit "count"
                      :label-names '(route)))
           (gauge (define-gauge registry edge_in_flight))
           (histogram (define-histogram registry edge_latency
                         :buckets '(1 2))))
      (expect (metric-name counter) :to-equal "edge_requests_total")
      (expect (metric-help counter) :to-equal "Requests")
      (expect (metric-unit counter) :to-equal "count")
      (expect (metric-label-names counter) :to-equal '("route"))
      (expect (metric-kind counter) :to-equal :counter)
      (expect (counter-p counter) :to-be-truthy)
      (expect (gauge-p gauge) :to-be-truthy)
      (expect (histogram-p histogram) :to-be-truthy)
      (expect (counter-p nil) :to-be-falsy)
      (expect (gauge-p nil) :to-be-falsy)
      (expect (histogram-p nil) :to-be-falsy)
      (expect (gauge-p counter) :to-be-falsy)
      (expect (histogram-p gauge) :to-be-falsy)
      (let ((help (metric-help counter))
            (labels (metric-label-names counter)))
        (setf (char help 0) #\X)
        (setf (car labels) "changed")
        (expect (metric-help counter) :to-equal "Requests")
        (expect (metric-label-names counter) :to-equal '("route")))
      (expect (mapcar #'metric-name (metric-registry-metrics registry))
              :to-equal '("edge_in_flight" "edge_latency" "edge_requests_total"))
      (signals observability-error
        (make-metric-registry :default-cardinality-limit 0))
      (signals observability-error
        (make-metric-registry :max-label-value-length 0))
      (signals observability-error
        (observability-kit::%parse-keyword-options
         (list :a) '(:a) "edge"))
      (signals observability-error
        (observability-kit::%parse-keyword-options
         (list 'a 1) '(:a) "edge"))
      (signals observability-error
        (observability-kit::%parse-keyword-options
         (list :unknown 1) '(:a) "edge"))
      (signals observability-error
        (observability-kit::%parse-keyword-options
         (list :a) '(:a) "edge"))
      (signals observability-error
        (observability-kit::%parse-keyword-options
         (list :a 1 :a 2) '(:a) "edge"))
      (signals observability-error
        (observability-kit::%parse-keyword-options
         (cons :a (cons 1 :tail)) '(:a) "edge"))
      (signals observability-error
        (define-counter registry edge_bad_help :help 1))
      (signals observability-error
        (define-counter registry edge_bad_unit :unit 1))
      (signals observability-error
        (define-histogram registry edge_bad_buckets :buckets '(2 1)))
      (signals observability-error
        (define-histogram registry edge_bad_buckets_list :buckets '(1 . 2)))
      (signals observability-error
        (define-counter registry edge_bad_limit :cardinality-limit 0))
      (signals invalid-label-name
        (define-counter registry edge_bad_labels :label-names '("bad-name")))
      (signals invalid-label-name
        (define-counter registry edge_duplicate_labels :label-names '(route route)))
      (define-counter registry edge_requests_total
        :help "Requests"
        :unit "count"
        :label-names '(route))
      (signals metric-definition-conflict
        (define-gauge registry edge_requests_total))
      (define-counter registry edge_conflict_help :help "one")
      (signals metric-definition-conflict
        (define-counter registry edge_conflict_help :help "two"))
      (define-counter registry edge_conflict_unit :unit "count")
      (signals metric-definition-conflict
        (define-counter registry edge_conflict_unit :unit "bytes"))
      (define-counter registry edge_conflict_labels :label-names '(route))
      (signals metric-definition-conflict
        (define-counter registry edge_conflict_labels :label-names '(method)))
      (signals program-error
        (macroexpand-1 '(define-counter registry edge_bad_option :unknown t)))))

  (it "keeps updates exact and enforces labels and cardinality"
    (let* ((registry (make-metric-registry
                      :default-cardinality-limit 2
                      :max-label-value-length 4))
           (counter (define-counter registry edge_total
                      :label-names '(method)))
           (gauge (define-gauge registry edge_gauge))
           (histogram (define-histogram registry edge_histogram
                         :buckets '(1 2))))
      (expect (metric-inc counter 2 :labels '(method "GET")) :to-equal 2)
      (expect (metric-inc counter :labels '((method . "GET"))) :to-equal 3)
      (expect (metric-inc gauge -1) :to-equal -1)
      (expect (metric-set gauge 3/2) :to-equal 3/2)
      (expect (metric-set gauge 1.5d0) :to-equal 1.5d0)
      (expect (metric-observe histogram 3/2) :to-equal 3/2)
      #+sbcl
      (signals metric-operation-error
        (metric-set gauge sb-ext:double-float-positive-infinity))
      (signals metric-operation-error (metric-set gauge "not-real"))
      (signals type-error (metric-snapshot :not-a-metric))
      (signals metric-operation-error (metric-inc counter -1 :labels '(method "GET")))
      (signals metric-operation-error (metric-set counter 1 :labels '(method "GET")))
      (signals metric-operation-error (metric-observe counter 1 :labels '(method "GET")))
      (signals metric-operation-error (metric-set histogram 1))
      (signals metric-operation-error (metric-inc histogram))
      (signals metric-operation-error (metric-observe gauge 1))
      (signals metric-operation-error (metric-inc counter :unknown t :labels '(method "GET")))
      (signals metric-operation-error (metric-inc counter :labels))
      (signals metric-operation-error
        (metric-inc counter :labels '(method "GET") :labels '(method "GET")))
      (signals invalid-label-set
        (metric-inc counter :labels '(method)))
      (signals invalid-label-set
        (metric-inc counter :labels '(method "GET" extra)))
      (signals invalid-label-set
        (metric-inc counter :labels '((method "GET") (method "POST"))))
      (signals invalid-label-set
        (metric-inc counter :labels '((other . "GET"))))
      (signals invalid-label-value
        (metric-inc counter :labels '(method "12345")))
      (signals invalid-label-set
        (metric-inc counter :labels (edge-circular-list)))
      (signals invalid-label-set
        (metric-inc counter :labels '((method "GET") . tail)))
      (expect (metric-inc counter :labels '(method "POST")) :to-equal 1)
      (signals metric-cardinality-exceeded
        (metric-inc counter :labels '(method "PUT")))
      (signals invalid-label-name
        (define-counter registry edge_sensitive :label-names '(authorization)))
      (signals invalid-label-name
        (define-counter registry edge_reserved :label-names '("__internal")))
      (signals invalid-metric-name
        (define-counter registry edge-bad-name))
      (signals invalid-metric-name
        (define-counter registry authorization_total)))))

(describe "health API boundaries"
  (it "normalizes registration, replacement, and selection"
    (let ((registry (make-health-registry
                     :default-timeout nil
                     :cancellation-grace-period 0.01d0)))
      (signals observability-error
        (make-health-registry :default-timeout 0))
      (signals observability-error
        (make-health-registry :cancellation-grace-period 0))
      (signals health-error
        (register-health-check registry "authorization" #'edge-health-pass))
      (signals health-error
        (observability-kit::%normalize-health-name "bad name"))
      (signals health-error
        (register-health-check registry "" #'edge-health-pass))
      (let ((symbol-check
              (register-health-check registry "_symbol" 'edge-health-pass)))
        (expect (eq (health-check-function symbol-check) 'edge-health-pass)
                :to-be-truthy)
        (expect (unregister-health-check registry "_symbol") :to-be-truthy))
      (signals observability-error
        (register-health-check registry "_unbound" (gensym "UNBOUND-CHECK-")))
      (signals observability-error
        (register-health-check registry "_number" 42))
      (expect (observability-kit::%normalize-health-name "_probe-1.0")
              :to-equal "_probe-1.0")
      (signals health-error
        (register-health-check registry "ok" #'edge-health-pass :kind :unknown))
      (signals observability-error
        (register-health-check registry "ok" nil))
      (signals observability-error
        (register-health-check registry "ok" #'edge-health-pass :timeout 0))
      (signals observability-error
        (register-health-check registry "ok" #'edge-health-pass
                               :cancellation-grace-period nil))
      (let ((startup (register-health-check registry 'boot #'edge-health-pass
                                             :kind "startup"))
            (readiness (register-health-check registry "database" #'edge-health-fail))
            (liveness (register-health-check registry "process" #'edge-health-pass
                                             :kind :liveness)))
        (expect (health-check-name startup) :to-equal "boot")
        (expect (health-check-kind readiness) :to-equal :readiness)
        (expect (health-check-timeout startup) :to-be-falsy)
        (expect (mapcar #'health-check-name (health-registry-checks registry))
                :to-equal '("process" "database" "boot"))
        (signals health-error
          (register-health-check registry "database" #'edge-health-pass))
        (let ((replacement (register-health-check registry "database" #'edge-health-pass
                                                   :replace t)))
          (expect (functionp (health-check-function replacement)) :to-be-truthy))
        (expect (unregister-health-check registry "database") :to-be-truthy)
        (expect (unregister-health-check registry "database") :to-be-falsy)
        (expect (unregister-health-check registry "process" :kind :readiness)
                :to-be-falsy)
        (let ((results (run-health-checks registry :kinds '(:startup :liveness :startup))))
          (expect (length results) :to-equal 2)
          (expect (mapcar #'health-result-kind results) :to-equal '(:liveness :startup))
          (expect (health-status results) :to-equal :healthy))
        (signals observability-error
          (run-health-checks registry :kind :liveness :kinds '(:startup)))
        (signals observability-error
          (run-health-checks registry :kinds '(:startup . :liveness)))
        (expect (health-status registry :kind :readiness) :to-equal :unknown)
        )))

  (it "isolates failures and distinguishes status inputs"
    (let ((registry (make-health-registry :default-timeout 0.2d0)))
      (register-health-check registry "pass" #'edge-health-pass :kind :liveness)
      (register-health-check registry "fail" #'edge-health-fail :kind :readiness)
      (register-health-check registry "signal" #'edge-health-signal :kind :startup)
      (let* ((results (run-health-checks registry))
             (pass (first results))
             (fail (second results))
             (signal (third results)))
        (expect (mapcar #'health-result-status results) :to-equal '(:pass :fail :fail))
        (expect (health-status pass) :to-equal :healthy)
        (expect (health-status fail) :to-equal :unhealthy)
        (expect (health-status results :kind :liveness) :to-equal :healthy)
        (expect (health-status results :kind "readiness") :to-equal :unhealthy)
        (expect (health-status registry) :to-equal :unhealthy)
        (expect (length (health-registry-last-results registry)) :to-equal 3)
        (expect (health-result-condition signal) :to-be-truthy))
      (expect (health-status nil) :to-equal :unknown)
      (signals observability-error (health-status '(:not-a-result)))
      (signals observability-error (health-status (cons nil nil)))
      (signals observability-error (health-status (edge-circular-list)))
      (signals observability-error (health-status :not-a-health-object)))))

  (it "does not start checks after parent cancellation"
    (let* ((registry (make-health-registry
                      :default-timeout nil
                      :cancellation-grace-period 0.05d0))
           (parent (make-cancellation-token)))
      (cancel-cancellation-token parent :shutdown)
      (register-health-check
       registry "cooperative"
       (lambda (token)
         (declare (ignore token))
         (error "cancelled check should not execute"))
       :kind :readiness)
      (let ((result (first (run-health-checks registry
                                              :cancellation-token parent))))
        (expect (health-result-status result) :to-equal :cancelled)
        (expect (cancellation-requested-p parent) :to-be-truthy)
        (expect (cancellation-reason parent) :to-equal :shutdown)
        (let ((child (make-cancellation-token :parent parent)))
          (expect (cancellation-reason child) :to-equal :shutdown))
      (expect (cancellation-reason (make-cancellation-token))
              :to-be-falsy))))

  (it "stops timed-out and cooperatively cancelled checks"
    (let ((registry (make-health-registry
                     :default-timeout nil
                     :cancellation-grace-period 0.01d0)))
      (register-health-check registry "slow" #'edge-health-slow
                             :kind :readiness
                             :timeout 0.005d0)
      (register-health-check registry "cancel" #'edge-health-cancel
                             :kind :liveness
                             :timeout 0.2d0)
      (let ((results (run-health-checks registry)))
        (expect (mapcar #'health-result-status results)
                :to-equal '(:cancelled :timeout)))
      (let* ((check (register-health-check registry "_unstop" #'edge-health-pass))
             (always-alive
               (observability-kit::%make-health-thread-controller
                (lambda (thread &rest arguments)
                  (declare (ignore thread arguments))
                  nil)
                (lambda (thread)
                  (declare (ignore thread))
                  t)
                (lambda (thread)
                  (declare (ignore thread))
                  nil)))
             (never-alive
               (observability-kit::%make-health-thread-controller
                (lambda (thread &rest arguments)
                  (declare (ignore thread arguments))
                  nil)
                (lambda (thread)
                  (declare (ignore thread))
                  nil)
                (lambda (thread)
                  (declare (ignore thread))
                  nil))))
        (expect (typep
                 (observability-kit::%stop-health-thread
                  :fake-thread (make-cancellation-token) check :forced always-alive)
                 'health-error)
                :to-be-truthy)
        (expect (observability-kit::%stop-health-thread
                 :fake-thread (make-cancellation-token) check :forced never-alive)
                :to-be-falsy))))

(describe "instrumentation context boundaries"
  (it "validates ids, flags, attributes, and detached copies"
    (signals observability-error
      (make-instrumentation-context :trace-id 1))
    (signals observability-error
      (make-instrumentation-context :span-id ""))
    (signals observability-error
      (make-instrumentation-context :trace-flags 256))
    (signals observability-error
      (make-instrumentation-context :trace-flags "invalid"))
    (signals unsafe-attribute-name
      (make-instrumentation-context :attributes '(("access-token" . "hidden"))))
    (signals unsafe-attribute-name
      (make-instrumentation-context :attributes '(("a" . (list 1)))))
    (signals unsafe-attribute-name
      (make-instrumentation-context :attributes '((a . 1) (a . 2))))
    (signals unsafe-attribute-name
      (make-instrumentation-context
       :attributes (list (cons "a" (make-string 1025 :initial-element #\x)))))
    (expect (observability-kit::%normalize-attributes '((a . 1)))
            :to-equal '(("a" . 1)))
    (expect (observability-kit::%normalize-attributes
             '((a . "value")) :max-value-length 5)
            :to-equal '(("a" . "value")))
    (let* ((context (make-instrumentation-context
                     :trace-id "trace"
                     :span-id "span"
                     :trace-flags 0
                     :attributes '((b . 2) (a . "one"))
                     :baggage '((tenant . public))))
           (copy (capture-instrumentation-context context)))
      (expect (instrumentation-context-trace-id context) :to-equal "trace")
      (expect (instrumentation-context-span-id context) :to-equal "span")
      (expect (instrumentation-context-trace-flags context) :to-equal 0)
      (expect (instrumentation-context-attributes context)
              :to-equal '( ("a" . "one") ("b" . 2)))
      (expect (instrumentation-context-baggage context)
              :to-equal '(("tenant" . public)))
      (expect (context-attribute context 'a) :to-equal "one")
      (expect (context-attribute context 'missing :default) :to-equal :default)
      (signals type-error
        (context-attribute nil 'missing :default))
      (expect (instrumentation-context-p (context-with-attribute context 'c 3))
              :to-be-truthy)
      (expect (instrumentation-context-p
               (context-with-attributes context '((d . 4) (a . "new"))))
              :to-be-truthy)
      (expect (capture-instrumentation-context nil) :to-be-falsy)
      (expect (call-with-captured-instrumentation-context
               context (lambda () (instrumentation-context-trace-id
                                    (current-instrumentation-context))))
              :to-equal "trace")
      (signals type-error
        (call-with-captured-instrumentation-context context nil))
      (expect (with-instrumentation-context (context)
                (instrumentation-context-trace-id (current-instrumentation-context)))
              :to-equal "trace")
      (expect (with-captured-instrumentation-context (copy)
                (instrumentation-context-span-id (current-instrumentation-context)))
              :to-equal "span"))))

(describe "validation boundaries"
  (it "handles metric names, real values, and label ordering"
    (expect (observability-kit::%valid-name-p ":edge" :metric-p t)
            :to-be-truthy)
    (expect (observability-kit::%valid-name-p ":edge")
            :to-be-falsy)
    (signals invalid-metric-name
      (observability-kit::%validate-metric-name "__edge"))
    (expect (observability-kit::%proper-list-p (edge-circular-list))
            :to-be-falsy)
    (expect (observability-kit::%proper-list-p (cons :edge :tail))
            :to-be-falsy)
    (expect (observability-kit::%labels-less-p
             '(("a" . "x")) '(("b" . "x")))
            :to-be-truthy)
    (expect (observability-kit::%labels-less-p
             '(("b" . "x")) '(("a" . "x")))
            :to-be-falsy)
    (expect (observability-kit::%labels-less-p nil '(("a" . "x")))
            :to-be-truthy)
    (expect (observability-kit::%labels-less-p
             '(("a" . "x")) '(("a" . "y")))
            :to-be-truthy)
    (expect (observability-kit::%labels-less-p
             '(("a" . "y")) '(("a" . "x")))
            :to-be-falsy)
    (expect (observability-kit::%labels-less-p
             '(("a" . "x")) '(("a" . "x")))
            :to-be-falsy)
    (signals observability-error
      (observability-kit::%validate-real "not-real" "edge"))
    (expect (observability-kit::%finite-real-p #c(1 2)) :to-be-falsy)
    (signals observability-error
      (observability-kit::%validate-positive-integer 1.5 "edge"))
    #+sbcl
    (progn
      (signals observability-error
        (observability-kit::%validate-finite-real
         sb-ext:double-float-positive-infinity "edge"))
      (expect (observability-kit::%finite-real-p
               (sb-int:with-float-traps-masked (:invalid)
                 (/ 0.0d0 0.0d0)))
              :to-be-falsy))))

(describe "optional exporter boundaries"
  (it "renders exact numbers, source shapes, and defensive errors"
    (let* ((registry (make-metric-registry))
           (gauge (define-gauge registry edge_numbers
                    :help "Line\nhelp"
                    :label-names '(route)))
           (histogram (define-histogram registry edge_export_histogram
                         :label-names '(route)
                         :buckets '(1 2))))
      (metric-set gauge 1/3 :labels '(route "a"))
      (metric-set gauge -1/2 :labels '(route "b"))
      (metric-observe histogram 1 :labels '(route "a"))
      (metric-observe histogram 3 :labels '(route "a"))
      (let ((text (observability-kit/prometheus:render-prometheus registry)))
        (expect (search "edge_numbers{route=\"a\"}" text) :to-be-truthy)
        (expect (search "0.333" text) :to-be-truthy)
        (expect (search "-0.5" text) :to-be-truthy)
        (expect (search "edge_export_histogram_bucket" text) :to-be-truthy))
      (expect (observability-kit/prometheus:render-prometheus nil) :to-equal "")
      (expect (observability-kit/prometheus:render-prometheus
               (metric-snapshot gauge))
              :to-be-truthy)
      (expect (observability-kit/prometheus:render-prometheus
               (list (second (metric-snapshot registry))
                     (first (metric-snapshot registry))))
              :to-be-truthy)
      (signals observability-error
        (observability-kit/prometheus:render-prometheus
         (let ((snapshot (first (metric-snapshot registry))))
           (list snapshot snapshot))))
      (expect (observability-kit/prometheus::%sorted-labels
               '(("b" . "x") ("a" . "y") ("a" . "x")))
              :to-equal '(("a" . "x") ("a" . "y") ("b" . "x")))
      (expect (observability-kit/prometheus::%escaped-string "plain")
              :to-equal "plain")
      (expect (with-output-to-string (stream)
                (observability-kit/prometheus::%write-escaped-string
                 "plain" stream))
              :to-equal "plain")
      (expect (observability-kit/prometheus::%number-string 3/2)
              :to-equal "1.5")
      (expect (observability-kit/prometheus::%number-string 1.5d0)
              :to-equal "1.5000000000000000")
      (expect (observability-kit/prometheus::%normalize-float-number "1.0d0")
              :to-equal "1.0e0")
      (expect (observability-kit/prometheus::%number-string
               observability-kit::+infinity+)
              :to-equal "+Inf")
      (signals observability-error
        (observability-kit/prometheus:render-prometheus '(not-a-snapshot)))
      (signals observability-error
        (observability-kit/prometheus:render-prometheus (cons nil nil)))
      (signals observability-error
        (observability-kit/prometheus:render-prometheus
         (list (observability-kit::make-metric-snapshot
                :name "bad" :help "bad" :type :gauge :samples (list nil)))))
      (signals observability-error
        (observability-kit/prometheus:render-prometheus
         (list (observability-kit::make-metric-snapshot
                :name "bad" :help "bad" :type :gauge
                :samples (list (edge-sample "bad" :gauge :value 'not-a-number))))))
      (let ((le-metric (define-histogram registry edge_le
                         :label-names '(le)
                         :buckets '(1))))
        (metric-observe le-metric 1 :labels '(le "input"))
        (signals observability-error
          (observability-kit/prometheus:render-prometheus le-metric)))))

  (it "keeps OTLP-shaped output deterministic and transport neutral"
    (let* ((registry (make-metric-registry))
           (histogram (define-histogram registry edge_otlp_histogram
                         :label-names '(route)
                         :buckets '(1 2))))
      (metric-observe histogram 1 :labels '(route "a"))
      (metric-observe histogram 3 :labels '(route "a"))
      (let ((document (observability-kit/otlp:registry->otlp
                       registry :scope-name "scope" :scope-version "1")))
        (expect (observability-kit/otlp:metric-snapshot->otlp
                 (first (metric-snapshot registry)))
                :to-be-truthy)
        (expect (observability-kit/otlp:snapshot->otlp histogram) :to-be-truthy)
        (expect (observability-kit/otlp:snapshot->otlp (metric-snapshot histogram))
                :to-be-truthy)
        (expect (observability-kit/otlp:registry->otlp histogram) :to-be-truthy)
        (expect (observability-kit/otlp:registry->otlp
                 (metric-snapshot histogram))
                :to-be-truthy)
        (expect (observability-kit/otlp:registry->otlp nil) :to-be-truthy)
        (expect (observability-kit/otlp:registry->otlp
                 (list (first (metric-snapshot registry))))
                :to-be-truthy)
        (expect document :to-be-truthy)
        (let ((data-point
                (observability-kit/otlp::%data-point
                 (edge-sample "edge" :gauge :value 1)
                 :count 2
                 :sum 3)))
          (expect (cdr (assoc "count" data-point :test #'string=)) :to-equal 2)
          (expect (cdr (assoc "sum" data-point :test #'string=)) :to-equal 3)))
      (signals observability-error
        (observability-kit/otlp:snapshot->otlp :not-a-metric))
      (signals observability-error
        (observability-kit/otlp:registry->otlp registry :scope-name 1))
      (signals observability-error
        (observability-kit/otlp:registry->otlp registry :scope-version 1))
      (signals observability-error
        (observability-kit/otlp:registry->otlp '(not-a-snapshot)))
      (signals observability-error
        (observability-kit/otlp:registry->otlp (cons nil nil)))
      (signals observability-error
        (observability-kit/otlp:metric-snapshot->otlp
         (observability-kit::make-metric-snapshot
          :name "bad" :help "bad" :type :unknown :samples nil))))))

(describe "log-kit function boundary"
  (it "supports direct field extraction and callback composition"
    (let ((context (make-instrumentation-context :trace-id "trace")))
      (expect (observability-kit/log-kit:instrumentation-context-log-fields context)
              :to-equal '(:observability-trace-id "trace"
                          :observability-span-id nil
                          :observability-trace-flags nil
                          :observability-attributes nil
                          :observability-baggage nil))
      (expect (observability-kit/log-kit:call-with-log-kit-context
               context (lambda () :called))
              :to-equal :called)
      (signals type-error
        (observability-kit/log-kit:instrumentation-context-log-fields nil))
      (signals type-error
        (observability-kit/log-kit:call-with-log-kit-context context nil)))))
