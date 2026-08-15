#.(progn (in-package #:observability-kit) nil)

;;; Public provider, processor, and logger readers.

(defun log-provider-resource (provider)
  (check-type provider log-provider)
  (cl-concurrent-kit:with-lock-held ((%log-provider-lock provider))
    (make-resource :attributes
                   (resource-attributes (%log-provider-resource provider)))))

(defun log-provider-loggers (provider)
  (check-type provider log-provider)
  (cl-concurrent-kit:with-lock-held ((%log-provider-lock provider))
    (sort (loop for logger being the hash-values of (%log-provider-loggers provider)
                collect logger)
          (lambda (left right)
            (or (string< (logger-name left) (logger-name right))
                (and (string= (logger-name left) (logger-name right))
                     (string< (or (logger-version left) "")
                              (or (logger-version right) ""))))))))

(defun log-provider-processors (provider)
  (check-type provider log-provider)
  (cl-concurrent-kit:with-lock-held ((%log-provider-lock provider))
    (copy-list (%log-provider-processors provider))))

(defun log-provider-shutdown-p (provider)
  (check-type provider log-provider)
  (cl-concurrent-kit:with-lock-held ((%log-provider-lock provider))
    (%log-provider-shutdown-p provider)))

(defun log-provider-last-error (provider)
  (check-type provider log-provider)
  (cl-concurrent-kit:with-lock-held ((%log-provider-lock provider))
    (%log-provider-last-error provider)))

(defun log-processor-on-emit (processor)
  (check-type processor log-processor)
  (%log-processor-on-emit processor))

(defun log-processor-force-flush (processor)
  (check-type processor log-processor)
  (%log-processor-force-flush processor))

(defun log-processor-shutdown (processor)
  (check-type processor log-processor)
  (%log-processor-shutdown processor))

(defun log-processor-error-handler (processor)
  (check-type processor log-processor)
  (%log-processor-error-handler processor))

(defun logger-provider (logger)
  (check-type logger logger)
  (%logger-provider logger))

(defun logger-name (logger)
  (check-type logger logger)
  (%copy-observability-value (%logger-name logger)))

(defun logger-version (logger)
  (check-type logger logger)
  (%copy-observability-value (%logger-version logger)))

(defun logger-schema-url (logger)
  (check-type logger logger)
  (%copy-observability-value (%logger-schema-url logger)))
