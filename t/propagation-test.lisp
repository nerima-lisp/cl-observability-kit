(in-package #:observability-kit.test)

(describe "W3C trace propagation"
  (it "formats, injects, and extracts trace context with baggage"
    (let* ((context
             (make-instrumentation-context
              :trace-id "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
              :span-id "BBBBBBBBBBBBBBBB"
              :trace-flags 1
              :tracestate "vendor=value"
              :baggage '(("tenant" . "acme")
                         ("locale" . "日本語"))))
           (headers
             (inject-trace-context
              context
              '( ("x-request-id" . "request-1")
                 ("traceparent" . "stale") )))
           (extracted (extract-trace-context headers)))
      (expect (format-traceparent context)
              :to-equal
              "00-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-bbbbbbbbbbbbbbbb-01")
      (expect (cdr (assoc "x-request-id" headers :test #'string-equal))
              :to-equal "request-1")
      (expect (cdr (assoc "traceparent" headers :test #'string-equal))
              :to-equal
              "00-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-bbbbbbbbbbbbbbbb-01")
      (expect (cdr (assoc "tracestate" headers :test #'string-equal))
              :to-equal "vendor=value")
      (expect (cdr (assoc "baggage" headers :test #'string-equal))
              :to-equal "locale=%E6%97%A5%E6%9C%AC%E8%AA%9E, tenant=acme")
      (expect (instrumentation-context-trace-id extracted)
              :to-equal "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
      (expect (instrumentation-context-span-id extracted)
              :to-equal "bbbbbbbbbbbbbbbb")
      (expect (instrumentation-context-trace-flags extracted) :to-equal 1)
      (expect (instrumentation-context-tracestate extracted)
              :to-equal "vendor=value")
      (expect (instrumentation-context-baggage extracted)
              :to-equal '(("locale" . "日本語") ("tenant" . "acme")))))

  (it "rejects malformed traceparent and tolerates invalid optional fields"
    (let ((valid "00-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-bbbbbbbbbbbbbbbb-01"))
      (signals invalid-traceparent
        (parse-traceparent
         "00-00000000000000000000000000000000-bbbbbbbbbbbbbbbb-01"))
      (expect (extract-trace-context '(("traceparent" . "not-a-traceparent")))
              :to-equal nil)
      (let ((context
              (extract-trace-context
               `(("traceparent" . ,valid)
                 ("tracestate" . ,(format nil "bad~C~Cstate"
                                             #\Return #\Linefeed))
                 ("baggage" . "bad%ZZ")))))
        (expect (instrumentation-context-trace-id context)
                :to-equal "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        (expect (instrumentation-context-tracestate context) :to-equal nil)
        (expect (instrumentation-context-baggage context) :to-equal nil)))
    (expect (extract-trace-context nil) :to-equal nil))

  (it "parses baggage metadata, duplicates, and detached headers"
    (let ((baggage (parse-baggage "tenant=first, tenant=last;meta=ignored")))
      (expect baggage :to-equal '(("tenant" . "last"))))
    (let* ((context (make-instrumentation-context
                     :trace-id "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
                     :span-id "bbbbbbbbbbbbbbbb"))
           (headers (inject-trace-context context
                                          '(("content-type" . "application/json"))))
           (copy (copy-tree headers)))
      (setf (cdr (assoc "content-type" copy :test #'string-equal)) "changed")
      (expect (cdr (assoc "content-type" headers :test #'string-equal))
              :to-equal "application/json")
      (expect (format-baggage context) :to-equal nil))))

  (it "covers propagation validation and UTF-8 boundaries"
    (let ((valid-trace-id "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
          (valid-span-id "bbbbbbbbbbbbbbbb"))
      (signals propagation-error (parse-traceparent 42))
      (signals propagation-error
        (format-traceparent
         (observability-kit::%make-instrumentation-context
          "00000000000000000000000000000000" valid-span-id 1 nil nil nil)))
      (signals propagation-error
        (format-traceparent
         (observability-kit::%make-instrumentation-context
          42 valid-span-id 1 nil nil nil)))
      (signals propagation-error
        (format-traceparent
         (observability-kit::%make-instrumentation-context
          valid-trace-id "0000000000000000" 1 nil nil nil)))
      (signals propagation-error
        (format-traceparent
         (observability-kit::%make-instrumentation-context
          valid-trace-id valid-span-id 256 nil nil nil)))
      (signals propagation-error
        (format-traceparent
         (observability-kit::%make-instrumentation-context
          valid-trace-id valid-span-id "1" nil nil nil)))
      (signals propagation-error
        (parse-traceparent
         "01-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-bbbbbbbbbbbbbbbb-01"))
      (signals propagation-error
        (parse-traceparent
         "00xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-bbbbbbbbbbbbbbbb-01"))
      (signals propagation-error
        (parse-traceparent
         "00-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaXbbbbbbbbbbbbbbbb-01"))
      (signals propagation-error
        (parse-traceparent
         "00-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-bbbbbbbbbbbbbbbbX01"))
      (signals propagation-error
        (parse-traceparent
         (format nil "00-~A-~A-01"
                 (concatenate 'string "g" (make-string 31 :initial-element #\a))
                 valid-span-id)))
      (signals propagation-error
        (parse-traceparent
         (format nil "00-~A-~A-01"
                 valid-trace-id
                 (concatenate 'string "g" (make-string 15 :initial-element #\b)))))
      (signals propagation-error
        (parse-traceparent
         "00-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-bbbbbbbbbbbbbbbb-ff"))
      (expect (observability-kit::%baggage-key-p 42) :to-be-falsy)
      (expect (observability-kit::%baggage-key-p "") :to-be-falsy)
      (expect (format-baggage
               (observability-kit::%make-instrumentation-context
                valid-trace-id valid-span-id 1 nil
                '(("digit" . "9")) nil))
              :to-equal "digit=9")
      (expect (format-baggage
               (observability-kit::%make-instrumentation-context
                valid-trace-id valid-span-id 1 nil
                '(("punctuation" . ":")) nil))
              :to-equal "punctuation=%3A")
      (expect (format-baggage
               (observability-kit::%make-instrumentation-context
                valid-trace-id valid-span-id 1 nil
                '(("percent" . "%")) nil))
              :to-equal "percent=%25")
      (let ((encoded
              (observability-kit::%make-instrumentation-context
               valid-trace-id valid-span-id 1 nil
               '(("k9_*/-" . "¢😀")) nil)))
        (expect (format-baggage encoded)
                :to-equal "k9_*/-=%C2%A2%F0%9F%98%80")
        (expect (parse-baggage "k9_*/-=%C2%A2%F0%9F%98%80")
                :to-equal '(("k9_*/-" . "¢😀"))))
      (expect (format-baggage
               (observability-kit::%make-instrumentation-context
                valid-trace-id valid-span-id 1 nil
                '(("empty" . nil) ("number" . 42)) nil))
              :to-equal "empty=, number=42")
      (signals propagation-error
        (format-baggage
         (observability-kit::%make-instrumentation-context
          valid-trace-id valid-span-id 1 nil '(("bad!" . "x")) nil)))
      (expect (parse-baggage "currency=%C2%A2, emoji=%F0%9F%98%80")
              :to-equal '(("currency" . "¢") ("emoji" . "😀")))
      (signals propagation-error (parse-baggage 7))
      (signals propagation-error (parse-baggage "bad!=value"))
      (signals propagation-error (parse-baggage "k=%"))
      (signals propagation-error (parse-baggage "k=%ZZ"))
      (signals propagation-error (parse-baggage "k=é"))
      (signals propagation-error (parse-baggage "k=%C2%41"))
      (signals propagation-error (parse-baggage "k=%E2%82"))
      (expect (parse-baggage "k=%E2%82%AC") :to-be-truthy)
      (signals propagation-error (parse-baggage "k=%E2%41%AC"))
      (signals propagation-error (parse-baggage "k=%E2%82%41"))
      (signals propagation-error (parse-baggage "k=%F0%9F%98"))
      (signals propagation-error (parse-baggage "k=%F0%41%98%80"))
      (signals propagation-error (parse-baggage "k=%F0%9F%41%80"))
      (signals propagation-error (parse-baggage "k=%F0%9F%98%41"))
      (signals propagation-error (parse-baggage "k=%FF"))
      (expect (parse-baggage "") :to-equal nil)
      (expect (inject-trace-context nil '(("x" "y")))
              :to-equal '(("x" . "y")))
      (signals propagation-error
        (inject-trace-context nil '(("x" "y" "z"))))
      (signals propagation-error
        (inject-trace-context nil '(("x" . "y") . "tail")))
      (signals propagation-error
        (inject-trace-context nil '("bad")))
      (signals propagation-error
        (inject-trace-context nil '(("" . "x"))))
      (signals propagation-error
        (inject-trace-context nil '(("x" . 1))))))
