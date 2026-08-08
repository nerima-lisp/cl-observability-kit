(in-package #:asdf-user)

(asdf:defsystem "cl-observability-kit"
  :description "A small, deterministic observability substrate for Common Lisp."
  :long-description "Metrics, health checks, readiness semantics, and instrumentation context without transport or route ownership."
  :author "Project contributors"
  :maintainer "Project contributors"
  :license "MIT"
  :version "0.1.0"
  :pathname "src"
  :depends-on ("cl-concurrent-kit")
  :serial t
  :components ((:file "package")
               (:file "conditions")
               (:file "validation")
               (:file "metrics")
               (:file "health")
               (:file "context"))
  :in-order-to ((asdf:test-op (asdf:test-op "cl-observability-kit/test"))))

(asdf:defsystem "cl-observability-kit/prometheus"
  :description "Prometheus text exposition for cl-observability-kit snapshots."
  :author "Project contributors"
  :license "MIT"
  :version "0.1.0"
  :depends-on ("cl-observability-kit")
  :pathname "src"
  :serial t
  :components ((:file "prometheus")))

(asdf:defsystem "cl-observability-kit/otlp"
  :description "A transport-neutral OTLP-shaped document adapter."
  :author "Project contributors"
  :license "MIT"
  :version "0.1.0"
  :depends-on ("cl-observability-kit")
  :pathname "src"
  :serial t
  :components ((:file "otlp")))

(asdf:defsystem "cl-observability-kit/log-kit"
  :description "Optional instrumentation-context bridge for cl-log-kit."
  :author "Project contributors"
  :license "MIT"
  :version "0.1.0"
  :depends-on ("cl-observability-kit" "cl-log-kit")
  :pathname "src"
  :serial t
  :components ((:file "log-kit")))

(asdf:defsystem "cl-observability-kit/test"
  :description "Tests for cl-observability-kit and its optional adapters."
  :author "Project contributors"
  :license "MIT"
  :depends-on ("cl-observability-kit/prometheus"
               "cl-observability-kit/otlp"
               "cl-observability-kit/log-kit"
               "cl-weave")
  :pathname "t"
  :serial t
  :components ((:file "package")
               (:file "core-test")
               (:file "prometheus-test")
               (:file "integration-test"))
  :perform (asdf:test-op (operation component)
             (declare (ignore operation component))
             (unless (uiop:symbol-call '#:observability-kit.test '#:run-tests)
               (error "cl-observability-kit tests failed."))))
