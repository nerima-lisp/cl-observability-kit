#.(progn
    (in-package #:observability-kit)
    nil)

(defun %http-token-character-p (character)
  (or (%ascii-letter-p character)
      (%ascii-digit-p character)
      (find character "!#$%&'*+-.^_`|~" :test #'char=)))

(defun %normalize-http-method (method)
  (let ((normalized (%designator-string method)))
    (unless (and normalized
                 (plusp (length normalized))
                 (<= (length normalized) 32)
                 (every #'%http-token-character-p normalized))
      (error 'invalid-http-method
             :method method
             :message (format nil "HTTP method ~S is invalid." method)))
    (string-upcase normalized)))

(defun %normalize-http-text (value option maximum-length)
  (let ((normalized (%designator-string value)))
    (unless (and normalized
                 (plusp (length normalized))
                 (<= (length normalized) maximum-length)
                 (not (find #\Return normalized))
                 (not (find #\Linefeed normalized)))
      (error 'http-error
             :message (format nil
                              "HTTP option ~S must be a non-empty text value of at most ~D characters without line breaks."
                              option maximum-length)))
    normalized))

(defun %normalize-http-port (value option)
  (unless (and (integerp value) (<= 0 value 65535))
    (error 'http-error
           :message (format nil "HTTP option ~S must be an integer from 0 through 65535."
                            option)))
  value)

(defun %normalize-http-size (value option)
  (unless (and (integerp value) (<= 0 value))
    (error 'http-error
           :message (format nil "HTTP option ~S must be a non-negative integer."
                            option)))
  value)

(defun %http-text-attribute (options key attribute maximum-length &key downcase)
  (when (%option-supplied-p options key)
    (let ((value (%option-value options key nil)))
      (when value
        (let ((normalized (%normalize-http-text value key maximum-length)))
          (cons attribute (if downcase
                             (string-downcase normalized)
                             normalized)))))))

(defun %http-number-attribute (options key attribute &key size-p)
  (when (%option-supplied-p options key)
    (let ((value (%option-value options key nil)))
      (when value
        (cons attribute
              (if size-p
                  (%normalize-http-size value key)
                  (%normalize-http-port value key)))))))

(defun %http-optional-attributes (options specifications)
  (let ((attributes nil))
    (dolist (specification specifications (nreverse attributes))
      (destructuring-bind (key attribute maximum-length downcase-p) specification
        (let ((attribute-pair
                (%http-text-attribute options key attribute maximum-length
                                       :downcase downcase-p)))
          (when attribute-pair
            (push attribute-pair attributes)))))))

(defun %http-numeric-attributes (options specifications)
  (let ((attributes nil))
    (dolist (specification specifications (nreverse attributes))
      (destructuring-bind (key attribute size-p) specification
        (let ((attribute-pair
                (%http-number-attribute options key attribute :size-p size-p)))
          (when attribute-pair
            (push attribute-pair attributes)))))))

(defun http-request-attributes (method &rest option-list)
  "Return normalized HTTP request semantic-convention attributes.

This helper only describes a request. It performs no HTTP I/O and does not
choose a client or server implementation."
  (let* ((options (%parse-keyword-options
                   option-list
                   '(:route :url :scheme :server-address :server-port
                     :client-address :client-port :user-agent
                     :request-body-size :protocol-version)
                   "HTTP-REQUEST-ATTRIBUTES"))
         (attributes (list (cons "http.request.method"
                                 (%normalize-http-method method)))))
    (setf attributes
          (nconc attributes
                 (%http-optional-attributes
                  options
                  '((:route "http.route" 256 nil)
                    (:url "url.full" 4096 nil)
                    (:scheme "url.scheme" 32 t)
                    (:server-address "server.address" 256 nil)
                    (:client-address "client.address" 256 nil)
                    (:user-agent "user_agent.original" 1024 nil)
                    (:protocol-version "network.protocol.version" 32 nil)))
                 (%http-numeric-attributes
                  options
                  '((:server-port "server.port" nil)
                    (:client-port "client.port" nil)
                    (:request-body-size "http.request.body.size" t)))))
    (%normalize-attributes
     attributes
     :allow-sensitive-names '("server.address" "client.address"))))

(defun http-response-attributes (status &rest option-list)
  "Return normalized HTTP response semantic-convention attributes."
  (let* ((options (%parse-keyword-options
                   option-list '(:response-body-size)
                   "HTTP-RESPONSE-ATTRIBUTES"))
         (attributes (list (cons "http.response.status_code"
                                 (progn
                                   (unless (and (integerp status)
                                                (<= 100 status 599))
                                     (error 'invalid-http-status
                                            :status status
                                            :message (format nil
                                                             "HTTP status ~S is invalid."
                                                             status)))
                                   status)))))
    (let ((attribute-pair
            (%http-number-attribute options
                                    :response-body-size
                                    "http.response.body.size"
                                    :size-p t)))
      (when attribute-pair
        (push attribute-pair attributes)))
    (%normalize-attributes attributes)))

(defun span-set-http-request (span method &rest option-list)
  "Set HTTP request semantic-convention attributes on SPAN and return it."
  (dolist (attribute (apply #'http-request-attributes method option-list) span)
    (%set-span-attribute span (car attribute) (cdr attribute)
                         :allow-sensitive-names
                         '("server.address" "client.address"))))

(defun span-set-http-response (span status &rest option-list)
  "Set HTTP response semantic-convention attributes on SPAN and return it."
  (dolist (attribute (apply #'http-response-attributes status option-list) span)
    (span-set-attribute span (car attribute) (cdr attribute))))
