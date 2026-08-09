(in-package #:observability-kit.test)

(describe "HTTP semantic conventions"
  (it "normalizes request and response attributes"
    (let ((request (http-request-attributes
                    :get
                    :route "/orders/:id"
                    :url "https://example.test/orders/42"
                    :scheme :https
                    :server-address "example.test"
                    :server-port 443
                    :client-address "192.0.2.10"
                    :client-port 51000
                    :user-agent "observability-test"
                    :request-body-size 12
                    :protocol-version "2"))
          (response (http-response-attributes 201 :body-size 48)))
      (expect (cdr (assoc "http.request.method" request :test #'string=))
              :to-equal "GET")
      (expect (cdr (assoc "url.scheme" request :test #'string=))
              :to-equal "https")
      (expect (cdr (assoc "server.port" request :test #'string=))
              :to-equal 443)
      (expect (cdr (assoc "http.request.body.size" request :test #'string=))
              :to-equal 12)
      (expect (cdr (assoc "http.response.status_code" response :test #'string=))
              :to-equal 201)
      (expect (cdr (assoc "http.response.body.size" response :test #'string=))
              :to-equal 48)))

  (it "adds request and response attributes to a span"
    (let ((records nil))
      (let* ((provider (make-tracer-provider
                        :exporter (lambda (record) (push record records))))
             (tracer (make-tracer provider "http-test"))
             (span (start-span tracer "request" :parent nil)))
        (expect (span-set-http-request span :post :route "/items")
                :to-equal span)
        (expect (span-set-http-response span 204) :to-equal span)
        (end-span span)
        (let ((attributes (span-record-attributes (first records))))
          (expect (cdr (assoc "http.request.method" attributes :test #'string=))
                  :to-equal "POST")
          (expect (cdr (assoc "http.route" attributes :test #'string=))
                  :to-equal "/items")
          (expect (cdr (assoc "http.response.status_code" attributes :test #'string=))
                  :to-equal 204)))))

  (it "rejects invalid methods, statuses, and unsafe text"
    (signals invalid-http-method
      (http-request-attributes 42))
    (signals invalid-http-method
      (http-request-attributes ""))
    (signals invalid-http-method
      (http-request-attributes (make-string 33 :initial-element #\A)))
    (signals invalid-http-method
      (http-request-attributes "bad method"))
    (signals http-error
      (http-request-attributes :get :route ""))
    (signals http-error
      (http-request-attributes
       :get :url (make-string 4097 :initial-element #\x)))
    (signals http-error
      (http-request-attributes
       :get :url (format nil "https://example.test/~C" #\Linefeed)))
    (signals invalid-http-status
      (http-response-attributes 99))
    (signals invalid-http-status
      (http-response-attributes "200"))
    (signals http-error
      (http-request-attributes :get :server-port 70000))
    (signals http-error
      (http-request-attributes :get :server-port "443"))
    (signals http-error
      (http-response-attributes 200 :response-body-size -1))
    (signals http-error
      (http-response-attributes 200 :response-body-size "1"))
    (signals http-error
      (http-request-attributes :get :url (format nil "https://example.test/~C" #\Return)))
    (signals http-error
      (http-response-attributes 200 :body-size 1 :response-body-size 2))))
