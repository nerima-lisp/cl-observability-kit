#.(progn (in-package #:observability-kit) nil)

;;; Public provider and processor readers.

(defun tracer-provider-resource (provider)
  (check-type provider tracer-provider)
  (cl-concurrent-kit:with-lock-held ((%tracer-provider-lock provider))
    (make-resource :attributes
                   (resource-attributes (%tracer-provider-resource provider)))))

(defun tracer-provider-clock (provider)
  (check-type provider tracer-provider)
  (%tracer-provider-clock provider))

(defun tracer-name (tracer)
  (check-type tracer tracer)
  (%copy-observability-value (%tracer-name tracer)))

(defun tracer-version (tracer)
  (check-type tracer tracer)
  (%copy-observability-value (%tracer-version tracer)))

(defun tracer-schema-url (tracer)
  (check-type tracer tracer)
  (%copy-observability-value (%tracer-schema-url tracer)))

(defun %tracer-before-p (left right)
  (or (string< (tracer-name left) (tracer-name right))
      (and (string= (tracer-name left) (tracer-name right))
           (string< (or (tracer-version left) "")
                    (or (tracer-version right) "")))))

(defun tracer-provider-tracers (provider)
  (check-type provider tracer-provider)
  (cl-concurrent-kit:with-lock-held ((%tracer-provider-lock provider))
    (sort (loop for tracer being the hash-values of (%tracer-provider-tracers provider)
                collect tracer)
          #'%tracer-before-p)))

(defun tracer-provider-shutdown-p (provider)
  (check-type provider tracer-provider)
  (cl-concurrent-kit:with-lock-held ((%tracer-provider-lock provider))
    (%tracer-provider-shutdown-p provider)))

(defun tracer-provider-last-export-error (provider)
  (check-type provider tracer-provider)
  (cl-concurrent-kit:with-lock-held ((%tracer-provider-lock provider))
    (%tracer-provider-last-export-error provider)))

(defun tracer-provider-span-processors (provider)
  (check-type provider tracer-provider)
  (cl-concurrent-kit:with-lock-held ((%tracer-provider-lock provider))
    (copy-list (%tracer-provider-span-processors provider))))

(defun span-processor-on-start (processor)
  (check-type processor span-processor)
  (%span-processor-on-start processor))

(defun span-processor-on-end (processor)
  (check-type processor span-processor)
  (%span-processor-on-end processor))

(defun span-processor-force-flush (processor)
  (check-type processor span-processor)
  (%span-processor-force-flush processor))

(defun span-processor-shutdown (processor)
  (check-type processor span-processor)
  (%span-processor-shutdown processor))

(defun span-processor-error-handler (processor)
  (check-type processor span-processor)
  (%span-processor-error-handler processor))

(defun register-span-processor (provider processor)
  "Register PROCESSOR for future spans and return it."
  (check-type provider tracer-provider)
  (check-type processor span-processor)
  (cl-concurrent-kit:with-lock-held ((%tracer-provider-lock provider))
    (when (%tracer-provider-shutdown-p provider)
      (error 'tracer-provider-shutdown :provider provider))
    (setf (%tracer-provider-span-processors provider)
          (append (%tracer-provider-span-processors provider)
                  (list processor))))
  processor)
