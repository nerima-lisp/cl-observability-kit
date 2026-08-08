(defun %validate-context-id (value what)
  (when value
    (unless (and (stringp value) (plusp (length value)) (<= (length value) 256))
      (error 'observability-error
             :message (format nil
                              "~A must be a non-empty string of at most 256 characters."
                              what))))
  (%copy-observability-value value))

(defun %validate-trace-flags (value)
  (when value
    (unless (and (integerp value) (<= 0 value 255))
      (error 'observability-error
             :message (format nil
                              "TRACE-FLAGS must be an integer from 0 through 255, got ~S."
                              value))))
  value)

(defun make-instrumentation-context (&key trace-id span-id trace-flags
                                          attributes baggage)
  "Create immutable instrumentation metadata without starting a span.

TRACE-ID and SPAN-ID are opaque identifiers.  ATTRIBUTES and BAGGAGE are
validated, sorted alists; sensitive names are rejected before a context can
be exported or handed to another integration."
  (%make-instrumentation-context
   (%validate-context-id trace-id "TRACE-ID")
   (%validate-context-id span-id "SPAN-ID")
   (%validate-trace-flags trace-flags)
   (%normalize-attributes attributes)
   (%normalize-attributes baggage)))

(defun instrumentation-context-trace-id (context)
  (check-type context instrumentation-context)
  (%copy-observability-value (%instrumentation-context-trace-id context)))

(defun instrumentation-context-span-id (context)
  (check-type context instrumentation-context)
  (%copy-observability-value (%instrumentation-context-span-id context)))

(defun instrumentation-context-trace-flags (context)
  (check-type context instrumentation-context)
  (%instrumentation-context-trace-flags context))

(defun instrumentation-context-attributes (context)
  (check-type context instrumentation-context)
  (%copy-alist (%instrumentation-context-attributes context)))

(defun instrumentation-context-baggage (context)
  (check-type context instrumentation-context)
  (%copy-alist (%instrumentation-context-baggage context)))

(defun context-attribute (context name &optional default)
  "Return the value for NAME in CONTEXT attributes, or DEFAULT.

  NAME is validated with the same sensitive-name policy as context creation."
  (check-type context instrumentation-context)
  (let ((normalized (%validate-attribute-name name)))
    (let ((pair (assoc normalized
                       (%instrumentation-context-attributes context)
                       :test #'string=)))
      (if pair (%copy-observability-value (cdr pair)) default))))

(defun context-with-attribute (context name value)
  "Return CONTEXT with one validated attribute override."
  (check-type context instrumentation-context)
  (let* ((normalized (%validate-attribute-name name))
         (attributes (remove normalized
                              (%instrumentation-context-attributes context)
                              :key #'car
                              :test #'string=)))
    (%make-instrumentation-context
     (%instrumentation-context-trace-id context)
     (%instrumentation-context-span-id context)
     (%instrumentation-context-trace-flags context)
     (%normalize-attributes (acons normalized value attributes))
     (%copy-alist (%instrumentation-context-baggage context)))))

(defun context-with-attributes (context attributes)
  "Return CONTEXT with validated ATTRIBUTES merged over existing values.

Entries supplied by ATTRIBUTES take precedence over existing entries."
  (check-type context instrumentation-context)
  (let* ((incoming (%normalize-attributes (%label-input-alist attributes)))
         (existing
           (remove-if (lambda (pair)
                        (assoc (car pair) incoming :test #'string=))
                      (%instrumentation-context-attributes context))))
    (%make-instrumentation-context
     (%instrumentation-context-trace-id context)
     (%instrumentation-context-span-id context)
     (%instrumentation-context-trace-flags context)
     (%normalize-attributes (append incoming existing))
     (%copy-alist (%instrumentation-context-baggage context)))))

(defun current-instrumentation-context (&optional default)
  "Return the dynamically scoped context, or DEFAULT when none is bound."
  (or *instrumentation-context* default))

(defun capture-instrumentation-context (&optional (context *instrumentation-context*))
  "Return a detached copy of CONTEXT, or NIL when no context is active."
  (when context
    (check-type context instrumentation-context)
    (%make-instrumentation-context
     (%instrumentation-context-trace-id context)
     (%instrumentation-context-span-id context)
     (%instrumentation-context-trace-flags context)
     (%copy-alist (%instrumentation-context-attributes context))
     (%copy-alist (%instrumentation-context-baggage context)))))

(defun call-with-captured-instrumentation-context (context function)
  "Call FUNCTION with a detached CONTEXT dynamically bound."
  (check-type function function)
  (let ((*instrumentation-context* (capture-instrumentation-context context)))
    (funcall function)))
