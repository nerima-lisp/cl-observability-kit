(in-package #:observability-kit.test)

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
        (expect (health-status registry :kind :readiness) :to-equal :unknown))))

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

(describe "health execution boundaries"
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
                  nil)))
             (failing-cleanup
               (observability-kit::%make-health-thread-controller
                (lambda (thread &rest arguments)
                  (declare (ignore thread arguments))
                  (error "cleanup join failed"))
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
                :to-be-falsy)
        (expect (typep
                 (observability-kit::%stop-health-thread
                  :fake-thread (make-cancellation-token) check :forced failing-cleanup)
                 'error)
                :to-be-truthy)
        (let ((controller
                (observability-kit::%make-health-thread-controller
                 (lambda (thread &rest arguments)
                   (declare (ignore thread arguments))
                   nil)
                 (lambda (thread)
                   (declare (ignore thread))
                   nil)
                 (lambda (thread)
                   (declare (ignore thread))
                   nil)))
              (registry (make-health-registry)))
          (let ((timeout-check
                  (register-health-check registry "fallback-timeout"
                                         #'edge-health-await-cancellation
                                         :timeout 0.000001d0))
                (cancelled-check
                  (register-health-check registry "fallback-cancelled"
                                         #'edge-health-cancel
                                         :timeout 1.0d0)))
            (flet ((run-one (check)
                     (let ((result nil))
                       (let ((observability-kit::*health-thread-controller*
                               controller))
                         (observability-kit::%run-health-check
                          check
                          (make-cancellation-token)
                          (health-registry-clock registry)
                          (lambda (value)
                            (setf result value))))
                       result)))
              (let ((timeout-result (run-one timeout-check))
                    (cancelled-result (run-one cancelled-check)))
                (expect (typep (health-result-condition timeout-result)
                               'health-check-timeout)
                        :to-be-truthy)
                (expect (typep (health-result-condition cancelled-result)
                               'health-check-cancelled)
                        :to-be-truthy)))))))))

(describe "health execution composition"
  (it-each ((:pass :healthy)
            (:fail :unhealthy)
            (:timeout :unhealthy)
            (:cancelled :unhealthy))
      "maps ~A health result status to ~A"
      (status expected)
    (let ((result
            (observability-kit::make-health-result
             :name "table"
             :kind :readiness
             :status status)))
      (expect (health-status result) :to-equal expected)))
  (it "delivers health results through an explicit continuation"
    (let* ((registry (make-health-registry :default-timeout nil))
           (check (register-health-check registry "cps"
                                          #'edge-health-pass))
           (token (make-cancellation-token)))
      (with-continuation-result (result next calledp)
          (observability-kit::%run-health-check
           check token (health-registry-clock registry) #'next)
        (expect calledp :to-be-truthy)
        (expect (health-result-name result) :to-equal "cps")
        (expect (health-result-status result) :to-equal :pass)))))
