(in-package #:asdf-user)

(asdf:defsystem "cl-observability-kit"
  :description "A small, deterministic observability substrate for Common Lisp."
  :long-description "Metrics, health checks, readiness semantics, and instrumentation context without transport or route ownership."
  :author "Project contributors"
  :maintainer "Project contributors"
  :license "MIT"
  :version "1.0.0"
  :pathname "src"
  :depends-on ((:version "cl-concurrent-kit" "0.6.1")
               (:version "cl-boundary-kit" "2.3.0"))
  :serial t
  :components ((:file "package")
               (:file "conditions")
               (:file "validation-data")
               (:file "validation")
               (:file "validation-values")
               (:file "validation-numbers")
               (:file "options")
               (:file "metrics-declarations")
               (:file "metrics-model")
               (:file "metrics-macros")
               (:file "metrics-definition")
               (:file "metrics-operation")
               (:file "metrics-snapshot")
               (:file "health-declarations")
               (:file "health-model")
               (:file "health-registry")
               (:file "health-thread")
               (:file "health-execution")
               (:file "health-status")
               (:file "health-macros")
               (:file "context-declarations")
               (:file "context")
               (:file "context-macros"))
  :in-order-to ((asdf:test-op (asdf:test-op "cl-observability-kit/test"))))

(asdf:defsystem "cl-observability-kit/prometheus"
  :description "Prometheus text exposition for cl-observability-kit snapshots."
  :author "Project contributors"
  :license "MIT"
  :version "1.0.0"
  :depends-on ("cl-observability-kit")
  :pathname "src"
  :serial t
  :components ((:file "package-prometheus")
               (:file "prometheus-source")
               (:file "prometheus-format")
               (:file "prometheus-samples")
               (:file "prometheus")))

(asdf:defsystem "cl-observability-kit/otlp"
  :description "A transport-neutral OTLP-shaped document adapter."
  :author "Project contributors"
  :license "MIT"
  :version "1.0.0"
  :depends-on ("cl-observability-kit")
  :pathname "src"
  :serial t
  :components ((:file "package-otlp")
               (:file "otlp")))

(asdf:defsystem "cl-observability-kit/log-kit"
  :description "Optional instrumentation-context bridge for cl-log-kit."
  :author "Project contributors"
  :license "MIT"
  :version "1.0.0"
  :depends-on ("cl-observability-kit"
               (:version "cl-log-kit" "2.2.0"))
  :pathname "src"
  :serial t
  :components ((:file "package-log-kit")
               (:file "log-kit-macros")
               (:file "log-kit")))

(asdf:defsystem "cl-observability-kit/test"
  :description "Tests for cl-observability-kit and its optional adapters."
  :author "Project contributors"
  :license "MIT"
  :depends-on ("cl-observability-kit/prometheus"
               "cl-observability-kit/otlp"
               "cl-observability-kit/log-kit"
               (:version "cl-weave" "1.3.0"))
  :pathname "t"
  :serial t
  :components ((:file "package")
               (:file "weave-integration-test")
               (:file "edge-fixtures")
               (:file "core-test")
               (:file "prometheus-test")
               (:file "integration-test")
               (:file "edge-test")
               (:file "health-edge-test"))
  :perform (asdf:test-op (operation component)
             (declare (ignore operation component))
             (let* ((suite (uiop:symbol-call '#:cl-weave '#:root-suite))
                    (plan (uiop:symbol-call '#:cl-weave '#:collect-test-plan suite)))
               (unless (and plan
                            (every (lambda (entry)
                                     (eq :run
                                         (uiop:symbol-call
                                          '#:cl-weave
                                          '#:test-plan-entry-status
                                          entry)))
                                   plan))
                 (error "cl-observability-kit test plan is empty or contains non-runnable tests."))
               (format t "~&Test plan: ~D runnable tests.~%" (length plan))
               (unless (uiop:symbol-call '#:cl-weave '#:run-all
                                         :reporter :spec
                                         :pass-with-no-tests nil)
                 (error "cl-observability-kit tests failed.")))))
