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

(defun %generate-trace-id (generator length)
  (let ((value (funcall generator length)))
    (unless (and (stringp value) (= (length value) length))
      (error 'tracing-error
             :message (format nil
                              "ID generator must return a string of exactly ~D characters, got ~S."
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

(defun %sampler-decision (sampler parent-context name kind attributes)
  (let ((decision
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
                     :sampler :exporter :flush :shutdown :export-error-handler)
                   "MAKE-TRACER-PROVIDER"))
         (resource (%option-value options :resource (make-resource)))
         (clock (%option-value options :clock (cl-boundary-kit:make-clock)))
         (units (%option-value options :monotonic-units-per-second
                               internal-time-units-per-second))
         (id-generator (%option-value options :id-generator
                                      (%make-default-id-generator)))
         (sampler (%normalize-sampler (%option-value options :sampler nil)))
         (exporter (%option-value options :exporter nil))
         (flush (%option-value options :flush nil))
         (shutdown (%option-value options :shutdown nil))
         (export-error-handler (%option-value options :export-error-handler nil)))
    (check-type resource resource)
    (%validate-tracer-clock clock)
    (%validate-trace-units units)
    (%validate-id-generator id-generator)
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
     exporter
     flush
     shutdown
     export-error-handler
     nil
     nil)))
