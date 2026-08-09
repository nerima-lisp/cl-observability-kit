#.(progn
    (in-package #:observability-kit)
    nil)

(defstruct (resource
            (:constructor %make-resource (attributes))
            (:conc-name %resource-))
  attributes)
