#.(progn
    (in-package #:observability-kit)
    nil)

(defun make-resource (&key attributes)
  "Create immutable process/service/resource metadata.

ATTRIBUTES use the same validation and sensitive-name policy as context and
metric attributes.  Resource values are copied at this boundary so an
exporter can safely retain a resource snapshot."
  (%make-resource (%normalize-attributes attributes)))

(defun resource-attributes (resource)
  (check-type resource resource)
  (%copy-alist (%resource-attributes resource)))

(defun resource-attribute (resource name &optional default)
  (check-type resource resource)
  (let* ((normalized (%validate-attribute-name name))
         (pair (assoc normalized (%resource-attributes resource)
                      :test #'string=)))
    (if pair
        (%copy-observability-value (cdr pair))
        default)))

(defun resource-with-attribute (resource name value)
  (check-type resource resource)
  (let* ((normalized (%validate-attribute-name name))
         (attributes (remove normalized (%resource-attributes resource)
                              :key #'car :test #'string=)))
    (%make-resource
     (%normalize-attributes (acons normalized value attributes)))))

(defun resource-with-attributes (resource attributes)
  (check-type resource resource)
  (let* ((incoming (%normalize-attributes (%label-input-alist attributes)))
         (existing
           (remove-if (lambda (pair)
                        (assoc (car pair) incoming :test #'string=))
                      (%resource-attributes resource))))
    (%make-resource (%normalize-attributes (append incoming existing)))))
