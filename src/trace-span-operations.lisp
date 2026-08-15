#.(progn
    (in-package #:observability-kit)
    nil)

(defun %ensure-span-open (span operation)
  (when (%span-ended-p span)
    (error 'span-operation-error :span span :operation operation
           :message (format nil "Cannot ~A an ended span." operation))))

(defun span-update-name (span name)
  "Update SPAN's name while it is open and return SPAN."
  (check-type span span)
  (let ((normalized (%normalize-span-name name)))
    (cl-concurrent-kit:with-lock-held ((%span-lock span))
      (%ensure-span-open span "update its name")
      (when (%span-recording-p span)
        (setf (%span-name span) normalized))))
  span)

(defun %set-span-attribute (span name value &key allow-sensitive-names)
  (check-type span span)
  (let* ((normalized (%validate-attribute-name
                      name
                      :allow-sensitive-names allow-sensitive-names))
         (normalized-value (car (%normalize-attributes
                                 (list (cons normalized value))
                                 :allow-sensitive-names allow-sensitive-names))))
    (cl-concurrent-kit:with-lock-held ((%span-lock span))
      (%ensure-span-open span "set an attribute")
      (when (%span-recording-p span)
        (setf (%span-attributes span)
              (cons normalized-value
                    (remove normalized (%span-attributes span)
                            :key #'car :test #'string=))))))
  span)

(defun span-set-attribute (span name value)
  "Set one validated attribute on SPAN and return SPAN."
  (%set-span-attribute span name value))

(defun span-event-name (event)
  (check-type event span-event)
  (%copy-observability-value (%span-event-name event)))

(defun span-event-timestamp (event)
  (check-type event span-event)
  (%span-event-timestamp event))

(defun span-event-attributes (event)
  (check-type event span-event)
  (%copy-alist (%span-event-attributes event)))

(defun %copy-span-event (event)
  (%make-span-event (span-event-name event)
                    (span-event-timestamp event)
                    (span-event-attributes event)))

(defun span-events (span)
  (check-type span span)
  (cl-concurrent-kit:with-lock-held ((%span-lock span))
    (mapcar #'%copy-span-event (reverse (%span-events span)))))

(defun span-add-event (span name &rest option-list)
  "Append an event to SPAN in timestamp order."
  (check-type span span)
  (let* ((options (%parse-keyword-options option-list '(:attributes :timestamp)
                                          "SPAN-ADD-EVENT"))
         (normalized-name (%normalize-span-name name))
         (attributes (%normalize-attributes (%option-value options :attributes nil))))
    (cl-concurrent-kit:with-lock-held ((%span-lock span))
      (%ensure-span-open span "add an event")
      (when (%span-recording-p span)
        (let ((timestamp
                (if (%option-supplied-p options :timestamp)
                    (%validate-trace-time (%option-value options :timestamp nil)
                                          "Span event timestamp")
                    (cl-boundary-kit:clock-now (%tracer-provider-clock
                                                (%span-provider span))))))
          (push (%make-span-event normalized-name timestamp attributes)
                (%span-events span)))))
  span))

(defun %context-for-link (context)
  (cond
    ((span-p context) (span-context context))
    ((instrumentation-context-p context) (capture-instrumentation-context context))
    (t (error 'tracing-error
              :message "Span links require a span or instrumentation context."))))

(defun span-link-context (link)
  (check-type link span-link)
  (capture-instrumentation-context (%span-link-context link)))

(defun span-link-attributes (link)
  (check-type link span-link)
  (%copy-alist (%span-link-attributes link)))

(defun %copy-span-link (link)
  (%make-span-link (span-link-context link)
                   (span-link-attributes link)))

(defun span-links (span)
  (check-type span span)
  (cl-concurrent-kit:with-lock-held ((%span-lock span))
    (mapcar #'%copy-span-link (reverse (%span-links span)))))

(defun span-add-link (span context &rest option-list)
  "Append a link to another span or detached instrumentation context."
  (check-type span span)
  (let* ((options (%parse-keyword-options option-list '(:attributes)
                                          "SPAN-ADD-LINK"))
         (linked-context (%context-for-link context))
         (attributes (%normalize-attributes (%option-value options :attributes nil))))
    (cl-concurrent-kit:with-lock-held ((%span-lock span))
      (%ensure-span-open span "add a link")
      (when (%span-recording-p span)
        (push (%make-span-link linked-context attributes) (%span-links span)))))
  span)

(defun span-set-status (span status &rest option-list)
  "Set SPAN status to :UNSET, :OK, or :ERROR and return SPAN."
  (check-type span span)
  (let* ((options (%parse-keyword-options option-list '(:message) "SPAN-SET-STATUS"))
         (normalized (%normalize-span-status status))
         (message (%normalize-span-status-message (%option-value options :message nil))))
    (cl-concurrent-kit:with-lock-held ((%span-lock span))
      (%ensure-span-open span "set status")
      (when (%span-recording-p span)
        (setf (%span-status span) normalized
              (%span-status-message span) message))))
  span)

(defun span-record-exception (span condition &rest option-list)
  "Record CONDITION as an exception event and mark SPAN as :ERROR."
  (check-type span span)
  (check-type condition condition)
  (let* ((options (%parse-keyword-options option-list '(:timestamp)
                                          "SPAN-RECORD-EXCEPTION"))
         (type (string-downcase (symbol-name (type-of condition))))
         (message (princ-to-string condition))
         (message (if (> (length message) 1024) (subseq message 0 1024) message)))
    (span-set-status span :error :message message)
    (span-add-event span "exception"
                    :timestamp (if (%option-supplied-p options :timestamp)
                                   (%option-value options :timestamp nil)
                                   (cl-boundary-kit:clock-now
                                    (%tracer-provider-clock (%span-provider span))))
                    :attributes (list (cons "exception.type" type)
                                      (cons "exception.message" message))))
  span)
