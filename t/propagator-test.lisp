#.(progn
    (in-package #:observability-kit.test)
    nil)

(describe "Composable propagators"
  (it "composes custom and W3C injectors and extractors"
    (let* ((context
             (make-instrumentation-context
              :trace-id "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
              :span-id "bbbbbbbbbbbbbbbb"
              :trace-flags 1))
           (custom
             (make-propagator
              :inject (lambda (value headers)
                        (declare (ignore value))
                        (acons "x-test" "present" headers))
              :extract (lambda (headers)
                         (when (assoc "x-test" headers :test #'string-equal)
                           (make-instrumentation-context
                            :trace-id "cccccccccccccccccccccccccccccccc"
                            :span-id "dddddddddddddddd")))))
           (composite (make-composite-propagator
                       custom
                       (make-w3c-propagator)))
           (headers (propagator-inject composite context
                                       '(("content-type" . "application/json"))))
           (extracted (propagator-extract composite headers)))
      (expect (cdr (assoc "x-test" headers :test #'string-equal))
              :to-equal
              "present")
      (expect (cdr (assoc "traceparent" headers :test #'string-equal))
              :to-equal
              "00-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-bbbbbbbbbbbbbbbb-01")
      (expect (instrumentation-context-trace-id extracted)
              :to-equal
              "cccccccccccccccccccccccccccccccc")))

  (it "returns the first successful extraction and detaches headers"
    (let* ((first (make-propagator
                   :inject (lambda (context headers)
                             (declare (ignore context))
                             headers)
                   :extract (lambda (headers)
                              (declare (ignore headers))
                              nil)))
           (second (make-propagator
                    :inject (lambda (context headers)
                              (declare (ignore context))
                              headers)
                    :extract (lambda (headers)
                               (when (assoc "x-test" headers
                                            :test #'string-equal)
                                 (make-instrumentation-context
                                  :trace-id "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
                                  :span-id "ffffffffffffffff")))))
           (composite (make-composite-propagator first second))
           (headers '( ("x-test" . "value")))
           (copy (propagator-inject composite nil headers)))
      (setf (cdr (assoc "x-test" copy :test #'string-equal)) "changed")
      (expect (cdr (assoc "x-test" headers :test #'string-equal))
              :to-equal
              "value")
      (expect (instrumentation-context-span-id
               (propagator-extract composite headers))
              :to-equal
              "ffffffffffffffff")))

  (it "validates callback and member boundaries"
    (signals propagation-error
      (make-propagator :inject nil :extract #'extract-trace-context))
    (signals propagation-error
      (make-propagator :inject #'inject-trace-context :extract nil))
    (signals propagation-error
      (make-composite-propagator
       (make-w3c-propagator)
       'not-a-propagator)))

  (it "round-trips B3 single and multi-header context"
    (let* ((context
             (make-instrumentation-context
              :trace-id "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
              :span-id "bbbbbbbbbbbbbbbb"
              :trace-flags 1))
           (single (make-b3-propagator))
           (single-headers
             (propagator-inject single context
                                '(("x-request-id" . "request-1"))))
           (single-extracted (propagator-extract single single-headers))
           (multi (make-b3-multi-propagator))
           (multi-headers (propagator-inject multi context nil))
           (multi-extracted (propagator-extract multi multi-headers)))
      (expect (cdr (assoc "b3" single-headers :test #'string-equal))
              :to-equal
              "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-bbbbbbbbbbbbbbbb-1")
      (expect (cdr (assoc "x-request-id" single-headers :test #'string-equal))
              :to-equal
              "request-1")
      (expect (instrumentation-context-trace-id single-extracted)
              :to-equal
              (instrumentation-context-trace-id context))
      (expect (instrumentation-context-span-id single-extracted)
              :to-equal
              (instrumentation-context-span-id context))
      (expect (instrumentation-context-trace-flags single-extracted)
              :to-equal
              1)
      (expect (cdr (assoc "x-b3-traceid" multi-headers :test #'string-equal))
              :to-equal
              "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
      (expect (cdr (assoc "x-b3-spanid" multi-headers :test #'string-equal))
              :to-equal
              "bbbbbbbbbbbbbbbb")
      (expect (cdr (assoc "x-b3-sampled" multi-headers :test #'string-equal))
              :to-equal
              "1")
      (expect (instrumentation-context-trace-id multi-extracted)
              :to-equal
              (instrumentation-context-trace-id context))))

  (it "extracts unsampled B3 multi-header parents"
    (let ((context
            (propagator-extract
             (make-b3-multi-propagator)
             '(("x-b3-traceid" . "463ac35c9f6413ad")
               ("x-b3-spanid" . "3333333333333333")
               ("x-b3-sampled" . "0")))))
      (expect (instrumentation-context-trace-id context)
              :to-equal
              "0000000000000000463ac35c9f6413ad")
      (expect (instrumentation-context-trace-flags context)
              :to-equal
              0)))

  (it "prefers B3 single headers and pads 64-bit multi-header trace IDs"
    (let* ((single-trace "11111111111111111111111111111111")
           (multi-trace "463ac35c9f6413ad")
           (headers
             `(("b3" . ,(format nil "~A-2222222222222222-0"
                                  single-trace))
               ("x-b3-traceid" . ,multi-trace)
               ("x-b3-spanid" . "3333333333333333")
               ("x-b3-sampled" . "1")))
           (propagator (make-b3-propagator))
           (single-context (propagator-extract propagator headers))
           (multi-context
             (propagator-extract
              propagator
              (cdr headers))))
      (expect (instrumentation-context-trace-id single-context)
              :to-equal
              single-trace)
      (expect (instrumentation-context-trace-flags single-context)
              :to-equal
              0)
      (expect (instrumentation-context-trace-id multi-context)
              :to-equal
              "0000000000000000463ac35c9f6413ad")
      (expect (instrumentation-context-trace-flags multi-context)
              :to-equal
              1)))

  (it "covers unsampled injection and B3 extraction boundaries"
    (let* ((context
             (make-instrumentation-context
              :trace-id "0123456789abcdef0123456789abcdef"
              :span-id "fedcba9876543210"
              :trace-flags 0))
           (b3 (make-b3-propagator))
           (b3-multi (make-b3-multi-propagator)))
      (dolist (propagator (list b3 b3-multi))
        (let ((headers (propagator-inject propagator context nil)))
          (expect headers :to-be-truthy)
          (expect (propagator-extract propagator headers)
                  :to-be-truthy)
          (expect (instrumentation-context-trace-flags
                   (propagator-extract propagator headers))
                  :to-equal
                  0)))
      (expect (instrumentation-context-trace-flags
               (propagator-extract
                b3
                '(("b3" . "aaaaaaaaaaaaaaaa-bbbbbbbbbbbbbbbb-d"))))
              :to-equal
              1)
      (expect (instrumentation-context-trace-flags
               (propagator-extract
                b3-multi
                '(("x-b3-traceid" . "463ac35c9f6413ad")
                  ("x-b3-spanid" . "3333333333333333")
                  ("x-b3-sampled" . "not-sampled")
                  ("x-b3-flags" . "1"))))
              :to-equal
              1)
      (dolist (headers
                '((("b3" . "bad"))
                  (("b3" . "aaaaaaaaaaaaaaaa-bbbbbbbbbbbbbbbb-1-extra"))
                  (("b3" . "aaaaaaaaaaaaaaaa-bad-1"))
                  (("b3" . "bad-bbbbbbbbbbbbbbbb-1"))
                  (("b3" . "aaaaaaaaaaaaaaaa-bbbbbbbbbbbbbbbb-x"))
                  (("x-b3-traceid" . "bad")
                   ("x-b3-spanid" . "3333333333333333")
                   ("x-b3-sampled" . "1"))
                  (("x-b3-traceid" . "463ac35c9f6413ad")
                   ("x-b3-spanid" . "bad")
                   ("x-b3-sampled" . "1"))
                  (("x-b3-traceid" . "463ac35c9f6413ad")
                   ("x-b3-spanid" . "3333333333333333")
                   ("x-b3-sampled" . "not-sampled")
                   ("x-b3-flags" . "not-flags"))))
        (expect (propagator-extract b3 headers)
                :to-be-falsy))))
  (it "rejects invalid context fields during B3 injection"
    (let ((bad-trace
            (make-instrumentation-context
             :trace-id "not-a-trace-id"
             :span-id "fedcba9876543210"))
          (bad-span
            (make-instrumentation-context
             :trace-id "0123456789abcdef0123456789abcdef"
             :span-id "not-a-span-id")))
      (dolist (propagator
                (list (make-b3-propagator)
                      (make-b3-multi-propagator)))
        (signals propagation-error
          (propagator-inject propagator bad-trace nil))
          (signals propagation-error
          (propagator-inject propagator bad-span nil)))))
)
