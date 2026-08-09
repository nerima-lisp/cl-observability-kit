#.(progn
    (in-package #:observability-kit)
    nil)

(defstruct (cancellation-token
            (:constructor %make-cancellation-token
                (lock cancelled-p reason parent))
            (:conc-name %cancellation-token-))
  lock
  cancelled-p
  reason
  parent)

(defstruct (health-registry
            (:constructor %make-health-registry
                (lock checks default-timeout cancellation-grace-period clock
                 monotonic-units-per-second last-results))
            (:conc-name %health-registry-))
  lock
  checks
  default-timeout
  cancellation-grace-period
  clock
  monotonic-units-per-second
  last-results)

(defstruct (health-check
            (:constructor %make-health-check
                (name kind function timeout cancellation-grace-period))
            (:conc-name health-check-))
  name
  kind
  function
  timeout
  cancellation-grace-period)

(defstruct health-result
  name
  kind
  status
  value
  condition
  duration)

(defstruct (health-thread-controller
            (:constructor %make-health-thread-controller
                (join-thread thread-alive-p terminate-thread))
            (:conc-name %health-thread-controller-))
  "Thread lifecycle operations used by health cancellation enforcement.

Keeping these operations as data makes the stop boundary explicit and lets
the execution logic preserve its cancellation guarantee on each supported
thread implementation."
  join-thread
  thread-alive-p
  terminate-thread)

(defparameter *health-thread-controller*
  (%make-health-thread-controller
   (lambda (thread &rest arguments)
     (apply #'cl-concurrent-kit:join-thread thread arguments))
   #'cl-concurrent-kit:thread-alive-p
   #+sbcl #'sb-thread:terminate-thread
   #-sbcl (lambda (thread)
            (declare (ignore thread))
            nil)))
