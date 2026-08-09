(in-package #:observability-kit.test)

(defvar *weave-health-fixture-results* nil)

(describe-each ((:pass :healthy)
                (:fail :unhealthy)
                (:cancelled :unhealthy))
    "maps ~A result status to ~A health status"
    (result-status expected-status)
  (around-each (next)
    (let ((*weave-health-fixture-results* nil))
      (unwind-protect
           (funcall next)
        (setf *weave-health-fixture-results* nil))))
  (it "classifies each generated result independently"
    (push (observability-kit::make-health-result
           :name "fixture"
           :kind :readiness
           :status result-status)
          *weave-health-fixture-results*)
    (expect (length *weave-health-fixture-results*) :to-be 1)
    (expect (health-status *weave-health-fixture-results*)
            :to-equal expected-status)))
