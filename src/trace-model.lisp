#.(progn
    (in-package #:observability-kit)
    nil)

(defun %validate-tracer-clock (clock)
  (handler-case
      (progn
        (cl-boundary-kit:clock-now clock)
        (cl-boundary-kit:clock-monotonic clock)
        clock)
    (error ()
      (error 'tracing-error
             :message (format nil
                              "Tracer clock must implement the cl-boundary-kit clock protocol, got ~S."
                              clock)))))

(defun %normalize-span-name (name)
  (let ((normalized (%designator-string name)))
    (unless (and normalized (plusp (length normalized)) (<= (length normalized) 256))
      (error 'invalid-span-name
             :name name
             :message "Span names must be non-empty strings or symbols of at most 256 characters."))
    normalized))

(defun %normalize-span-kind (kind)
  (let ((normalized (%designator-string kind)))
    (unless (member normalized '("internal" "server" "client" "producer" "consumer")
                    :test #'string=)
      (error 'tracing-error
             :message (format nil
                              "Span kind must be INTERNAL, SERVER, CLIENT, PRODUCER, or CONSUMER; got ~S."
                              kind)))
    (intern (string-upcase normalized) :keyword)))

(defun %normalize-span-status (status)
  (let ((normalized (%designator-string status)))
    (unless (member normalized '("unset" "ok" "error") :test #'string=)
      (error 'tracing-error
             :message (format nil
                              "Span status must be UNSET, OK, or ERROR; got ~S."
                              status)))
    (intern (string-upcase normalized) :keyword)))

(defun %normalize-span-status-message (message)
  (when message
    (unless (and (stringp message) (<= (length message) 1024))
      (error 'tracing-error
             :message "Span status messages must be strings of at most 1024 characters.")))
  (%copy-observability-value message))

(defun %validate-trace-time (value what)
  (unless (and (realp value) (%finite-real-p value))
    (error 'tracing-error
           :message (format nil "~A must be a finite real number, got ~S." what value)))
  value)

(defun %validate-trace-units (value)
  (unless (and (realp value) (%finite-real-p value) (plusp value))
    (error 'tracing-error
           :message (format nil
                            "Tracer monotonic units per second must be a positive finite number, got ~S."
                            value)))
  value)

(defun %make-default-id-generator ()
  (let ((state (make-random-state t))
        (digits "0123456789abcdef"))
    (lambda (length)
      (coerce (loop repeat length
                    collect (char digits (random (length digits) state)))
              'string))))

(defun %validate-id-generator (generator)
  (unless (or (functionp generator)
              (and (symbolp generator) (fboundp generator)))
    (error 'tracing-error
           :message (format nil "ID generator must be a function designator, got ~S."
                            generator)))
  generator)

(defun %validate-trace-callback (callback what)
  (when callback
    (unless (or (functionp callback)
                (and (symbolp callback) (fboundp callback)))
      (error 'tracing-error
             :message (format nil
                              "~A must be a function designator, got ~S."
                              what callback))))
  callback)

(defun %valid-generated-trace-id-p (value length)
  (and (stringp value)
       (= (length value) length)
       (loop for character across value
             always (digit-char-p character 16))
       (loop for character across value
             thereis (not (char= (char-downcase character) #\0)))))

(defun %generate-trace-id (generator length)
  (let ((value (funcall generator length)))
    (unless (%valid-generated-trace-id-p value length)
      (error 'tracing-error
             :message (format nil
                              "ID generator must return a non-zero hexadecimal string of exactly ~D characters, got ~S."
                              length value)))
    (%copy-observability-value value)))

(defun %normalize-sampler (sampler)
  (cond
    ((null sampler) :always-on)
    ((member sampler '(:always-on :always-off) :test #'eq) sampler)
    ((or (functionp sampler)
         (and (symbolp sampler) (fboundp sampler))) sampler)
    (t
     (error 'tracing-error
            :message (format nil
                             "Sampler must be :ALWAYS-ON, :ALWAYS-OFF, or a function designator, got ~S."
                             sampler)))))

(defconstant +trace-id-ratio-modulus+ (expt 2 64))

(defvar *sampler-trace-id* nil)

(defun %validate-sampler-ratio (ratio)
  (unless (and (realp ratio)
               (%finite-real-p ratio)
               (<= 0 ratio 1))
    (error 'tracing-error
           :message (format nil
                            "Trace ID ratio must be a finite real number between 0 and 1, got ~S."
                            ratio)))
  (coerce ratio 'double-float))

(defun %trace-id-ratio-value (trace-id)
  (let ((source (or trace-id ""))
        (value 0))
    (unless (stringp source)
      (error 'tracing-error
             :message (format nil
                              "Trace ID ratio samplers require a trace ID string, got ~S."
                              source)))
    (let ((start (max 0 (- (length source) 16))))
      (loop for character across (subseq source start)
            for digit = (position (char-downcase character)
                                  "0123456789abcdef"
                                  :test #'char=)
            do (setf value
                     (mod (if digit
                              (+ (* value 16) digit)
                              (+ (* value 131) (char-code character)))
                          +trace-id-ratio-modulus+))))
    value))

(defun %trace-id-ratio-sampled-p (ratio trace-id)
  (let ((normalized-ratio (%validate-sampler-ratio ratio)))
    (cond
      ((zerop normalized-ratio) nil)
      ((= normalized-ratio 1d0) t)
      (t
       (< (%trace-id-ratio-value trace-id)
          (floor (* normalized-ratio +trace-id-ratio-modulus+)))))))

(defun make-trace-id-ratio-sampler (ratio)
  "Return a deterministic sampler that samples RATIO of trace IDs.

The returned function accepts the four arguments used by custom samplers and
an optional TRACE-ID used by the built-in provider integration.  Direct
callers may pass a trace ID as the fifth argument; provider-created root spans
receive their candidate trace ID through the same optional argument."
  (let ((normalized-ratio (%validate-sampler-ratio ratio)))
    (lambda (parent-context name kind attributes &optional trace-id)
      (declare (ignore parent-context name kind attributes))
      (if (%trace-id-ratio-sampled-p
           normalized-ratio
           (or trace-id *sampler-trace-id*))
          :record-and-sample
          :drop))))

(defun %parent-context-sampled-p (parent-context)
  (and parent-context
       (integerp (instrumentation-context-trace-flags parent-context))
       (logbitp 0 (instrumentation-context-trace-flags parent-context))))

(defun make-parent-based-sampler (root-sampler)
  "Return a sampler that follows the parent decision when a parent exists.

ROOT-SAMPLER is used for root spans and may be a built-in sampler keyword or a
custom sampler function.  A parent with the sampled flag keeps the span
sampled, while an unsampled parent drops it."
  (let ((normalized-root-sampler (%normalize-sampler root-sampler)))
    (lambda (parent-context name kind attributes &optional trace-id)
      (if parent-context
          (if (%parent-context-sampled-p parent-context)
              :record-and-sample
              :drop)
          (%sampler-decision normalized-root-sampler
                             nil name kind attributes trace-id)))))

(defun %sampler-decision (sampler parent-context name kind attributes
                          &optional trace-id)
  (let ((*sampler-trace-id* trace-id)
        (decision
          (cond
            ((eq sampler :always-on) :record-and-sample)
            ((eq sampler :always-off) :drop)
            (t
             (funcall sampler
                      (and parent-context (capture-instrumentation-context parent-context))
                       name kind (%copy-alist attributes))))))
    (cond
      ((member decision '(:drop :record-only :record-and-sample) :test #'eq)
       decision)
      ((eq decision t) :record-and-sample)
      ((null decision) :drop)
      (t
       (error 'tracing-error
              :message (format nil
                               "Sampler must return :DROP, :RECORD-ONLY, :RECORD-AND-SAMPLE, true, or NIL; got ~S."
                               decision))))))

(defun make-span-processor (&rest option-list)
  "Create a span processor.

ON-START receives a recording SPAN.  ON-END receives a detached SPAN-RECORD.
FORCE-FLUSH and SHUTDOWN receive the provider.  ERROR-HANDLER receives the
condition and the callback argument when another processor callback fails."
  (let* ((options (%parse-keyword-options
                   option-list
                   '(:on-start :on-end :force-flush :shutdown :error-handler)
                   "MAKE-SPAN-PROCESSOR"))
         (on-start (%validate-trace-callback
                   (%option-value options :on-start nil)
                   "Span processor ON-START callback"))
         (on-end (%validate-trace-callback
                  (%option-value options :on-end nil)
                  "Span processor ON-END callback"))
         (force-flush (%validate-trace-callback
                       (%option-value options :force-flush nil)
                       "Span processor FORCE-FLUSH callback"))
         (shutdown (%validate-trace-callback
                    (%option-value options :shutdown nil)
                    "Span processor SHUTDOWN callback"))
         (error-handler (%validate-trace-callback
                         (%option-value options :error-handler nil)
                         "Span processor ERROR-HANDLER callback")))
    (%make-span-processor on-start on-end force-flush shutdown error-handler)))

(defun make-tracer-provider (&rest option-list)
  "Create a transport-neutral tracer provider.

EXPORTER receives a detached SPAN-RECORD after a recording span ends.  It is
called outside the span lock and exporter errors are isolated; the latest
error is available from TRACER-PROVIDER-LAST-EXPORT-ERROR.  FLUSH and
SHUTDOWN callbacks, when supplied, receive the provider.  CLOCK follows the
cl-boundary-kit clock protocol, and MONOTONIC-UNITS-PER-SECOND converts the
clock's monotonic units to the duration unit used in records."
  (let* ((options (%parse-keyword-options
                   option-list
                   '(:resource :clock :monotonic-units-per-second :id-generator
                     :sampler :span-processors :exporter :flush :shutdown
                     :export-error-handler)
                   "MAKE-TRACER-PROVIDER"))
         (resource (%option-value options :resource (make-resource)))
         (clock (%option-value options :clock (cl-boundary-kit:make-clock)))
         (units (%option-value options :monotonic-units-per-second
                               internal-time-units-per-second))
         (id-generator (%option-value options :id-generator
                                      (%make-default-id-generator)))
         (sampler (%normalize-sampler (%option-value options :sampler nil)))
         (span-processors (%option-value options :span-processors nil))
         (exporter (%option-value options :exporter nil))
         (flush (%option-value options :flush nil))
         (shutdown (%option-value options :shutdown nil))
         (export-error-handler (%option-value options :export-error-handler nil)))
    (check-type resource resource)
    (%validate-tracer-clock clock)
    (%validate-trace-units units)
    (%validate-id-generator id-generator)
    (unless (proper-list-p span-processors)
      (error 'tracing-error
             :message "Span processors must be supplied as a proper list."))
    (dolist (processor span-processors)
      (check-type processor span-processor))
    (dolist (entry (list (cons :exporter exporter)
                         (cons :flush flush)
                         (cons :shutdown shutdown)
                         (cons :export-error-handler export-error-handler)))
      (when (cdr entry)
        (%validate-id-generator (cdr entry))))
    (%make-tracer-provider
     (cl-concurrent-kit:make-lock :name "observability-tracer-provider")
     (make-hash-table :test #'equal)
     (make-resource :attributes (resource-attributes resource))
     clock
     units
     id-generator
     sampler
     (copy-list span-processors)
     exporter
     flush
     shutdown
     export-error-handler
     nil
     nil)))
