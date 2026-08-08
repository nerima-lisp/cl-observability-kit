(in-package #:asdf-user)

(asdf:defsystem "cl-observability-kit"
  :description "A small, deterministic observability substrate for Common Lisp."
  :long-description "Metrics, health checks, readiness semantics, and instrumentation context without transport or route ownership."
  :author "Project contributors"
  :maintainer "Project contributors"
  :license "MIT"
  :version "1.0.0"
  :pathname "src"
  :depends-on ((:version "cl-concurrent-kit" "0.6.1"))
  ;; Package selection belongs to the ASDF system boundary rather than to
  ;; individual source files. This keeps loading order declarative.
  :around-compile (lambda (next)
                    (let ((*package*
                           (or (find-package "OBSERVABILITY-KIT") *package*)))
                      (funcall next)))
  :serial t
  :components ((:file "package")
               (:file "conditions")
               (:file "validation-data")
               (:file "validation")
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
               (:file "health-execution")
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
  :around-compile (lambda (next)
                    (let ((*package*
                           (or (find-package "OBSERVABILITY-KIT/PROMETHEUS") *package*)))
                      (funcall next)))
  :serial t
  :components ((:file "prometheus")))

(asdf:defsystem "cl-observability-kit/otlp"
  :description "A transport-neutral OTLP-shaped document adapter."
  :author "Project contributors"
  :license "MIT"
  :version "1.0.0"
  :depends-on ("cl-observability-kit")
  :pathname "src"
  :around-compile (lambda (next)
                    (let ((*package*
                           (or (find-package "OBSERVABILITY-KIT/OTLP") *package*)))
                      (funcall next)))
  :serial t
  :components ((:file "otlp")))

(asdf:defsystem "cl-observability-kit/log-kit"
  :description "Optional instrumentation-context bridge for cl-log-kit."
  :author "Project contributors"
  :license "MIT"
  :version "1.0.0"
  :depends-on ("cl-observability-kit"
               (:version "cl-log-kit" "2.2.0"))
  :pathname "src"
  :around-compile (lambda (next)
                    (let ((*package*
                           (or (find-package "OBSERVABILITY-KIT/LOG-KIT") *package*)))
                      (funcall next)))
  :serial t
  :components ((:file "log-kit-macros")
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
               (:file "core-test")
               (:file "prometheus-test")
               (:file "integration-test")
               (:file "edge-test"))
  :perform (asdf:test-op (operation component)
             (declare (ignore operation component))
             (unless (uiop:symbol-call '#:cl-weave '#:run-all
                                       :reporter :spec
                                       :pass-with-no-tests nil)
               (error "cl-observability-kit tests failed."))))
