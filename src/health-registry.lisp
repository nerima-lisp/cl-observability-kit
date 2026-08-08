(defun health-registry-checks (registry)
  "Return REGISTRY's checks in deterministic kind/name order."
  (check-type registry health-registry)
  (cl-concurrent-kit:with-lock-held ((%health-registry-lock registry))
    (sort (loop for check being the hash-values of (%health-registry-checks registry)
                collect check)
          (lambda (left right)
            (or (string< (symbol-name (health-check-kind left))
                         (symbol-name (health-check-kind right)))
                (and (string= (symbol-name (health-check-kind left))
                              (symbol-name (health-check-kind right)))
                     (string< (health-check-name left)
                              (health-check-name right))))))))

(defun health-registry-last-results (registry)
  "Return a copy of the most recently completed run's results, or NIL."
  (check-type registry health-registry)
  (cl-concurrent-kit:with-lock-held ((%health-registry-lock registry))
    (copy-list (%health-registry-last-results registry))))

(defun register-health-check (registry name function &rest option-list)
  "Register a check whose FUNCTION accepts one CANCELLATION-TOKEN argument.

The function returns a true value for success and NIL for a normal health
failure.  Signalled conditions are isolated and recorded as failures.  A
compatible registration is replaced only when REPLACE is true."
  (check-type registry health-registry)
  (let* ((options (%parse-keyword-options
                   option-list
                   '(:kind :timeout :cancellation-grace-period :replace)
                   "REGISTER-HEALTH-CHECK"))
         (kind (%option-value options :kind :readiness))
         (timeout (%option-value options :timeout nil))
         (cancellation-grace-period
           (%option-value options :cancellation-grace-period nil))
         (replace (%option-value options :replace nil))
         (timeout-supplied-p (%option-supplied-p options :timeout))
         (grace-supplied-p (%option-supplied-p options :cancellation-grace-period))
         (normalized-name (%normalize-health-name name))
         (normalized-kind (%normalize-health-kind kind))
         (normalized-function (%validate-health-function function))
         (normalized-timeout
           (if timeout-supplied-p
               (%validate-health-duration timeout "Health check timeout" :allow-nil t)
               (%health-registry-default-timeout registry)))
         (normalized-grace
           (if grace-supplied-p
               (%validate-health-duration cancellation-grace-period
                                          "Health check cancellation grace period")
               (%health-registry-cancellation-grace-period registry)))
         (key (list normalized-kind normalized-name)))
    (let ((check (%make-health-check normalized-name normalized-kind
                                     normalized-function normalized-timeout
                                     normalized-grace)))
      (cl-concurrent-kit:with-lock-held ((%health-registry-lock registry))
        (when (and (gethash key (%health-registry-checks registry))
                   (not replace))
          (error 'health-error
                 :check-name normalized-name
                 :kind normalized-kind
                 :message (format nil
                                  "Health check ~S/~S is already registered."
                                  normalized-kind normalized-name)))
        (setf (gethash key (%health-registry-checks registry)) check))
      check)))

(defun unregister-health-check (registry name &rest option-list)
  "Remove and return a registered check, or NIL when it was absent."
  (check-type registry health-registry)
  (let* ((options (%parse-keyword-options option-list '(:kind)
                                          "UNREGISTER-HEALTH-CHECK"))
         (kind (%option-value options :kind :readiness))
         (key (list (%normalize-health-kind kind)
                    (%normalize-health-name name))))
    (cl-concurrent-kit:with-lock-held ((%health-registry-lock registry))
      (multiple-value-bind (check present-p)
          (gethash key (%health-registry-checks registry))
        (when present-p
          (remhash key (%health-registry-checks registry)))
        (and present-p check)))))
