#.(progn
    (in-package #:observability-kit/otlp)
    nil)

(defun %otlp-error (format-control &rest arguments)
  (error 'observability-error
         :message (apply #'format nil format-control arguments)))

(defun %attributes (labels)
  (mapcar (lambda (pair)
            (list (cons "key"
                        (observability-kit::%copy-observability-value
                         (car pair)))
                  (cons "value"
                        (observability-kit::%copy-observability-value
                         (cdr pair)))))
          labels))

(defun %scope-document (name version schema-url)
  (remove nil
          (list (and name (cons "name"
                                (observability-kit::%copy-observability-value name)))
                (and version (cons "version"
                                   (observability-kit::%copy-observability-value
                                    version)))
                (and schema-url (cons "schema-url"
                                      (observability-kit::%copy-observability-value
                                       schema-url))))))

(defun %resource-document (resource)
  (list (cons "attributes" (%attributes (resource-attributes resource)))))

(defun %group-key-string (key)
  (with-output-to-string (stream)
    (write key :stream stream :readably t)))
