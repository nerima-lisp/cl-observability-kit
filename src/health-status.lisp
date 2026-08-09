#.(progn
    (in-package #:observability-kit)
    nil)

(defun %health-status-for-result (result)
  (if (eq (health-result-status result) :pass)
      :healthy
      :unhealthy))

(defun %health-status-for-results (results)
  (cond
    ((null results) :unknown)
    ((some (lambda (result)
             (not (eq (health-result-status result) :pass)))
           results)
     :unhealthy)
    (t :healthy)))

(defun health-status (object &key kind)
  "Return :HEALTHY, :UNHEALTHY, or :UNKNOWN for results or a registry.

For a registry, this reports the last completed run and never starts checks.
Use RUN-HEALTH-CHECKS explicitly when a fresh observation is required."
  (cond
    ((health-result-p object)
     (%health-status-for-result object))
    ((health-registry-p object)
     (let* ((results (health-registry-last-results object))
            (normalized-kind (and kind (%normalize-health-kind kind))))
       (%health-status-for-results
        (if normalized-kind
            (remove-if-not (lambda (result)
                             (eq (health-result-kind result) normalized-kind))
                           results)
            results))))
    ((proper-list-p object)
     (unless (every #'health-result-p object)
       (error 'observability-error
              :message "HEALTH-STATUS received a list containing a non-result."))
     (let ((results (if kind
                        (let ((normalized-kind (%normalize-health-kind kind)))
                          (remove-if-not (lambda (result)
                                           (eq (health-result-kind result)
                                               normalized-kind))
                                         object))
                        object)))
       (%health-status-for-results results)))
    (t
     (error 'observability-error
            :message "Cannot determine health status for the supplied object."))))
