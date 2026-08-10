#.(progn
    (in-package #:observability-kit)
    nil)

(defun %validate-span-exporter (exporter)
  (unless (or (functionp exporter)
              (and (symbolp exporter) (fboundp exporter)))
    (error 'tracing-error
           :message (format nil
                            "Span exporter must be a function or fbound symbol; got ~S."
                            exporter)))
  exporter)

(defun %validate-span-processor-number (value name predicate)
  (unless (funcall predicate value)
    (error 'tracing-error
           :message (format nil "~A must satisfy its validation predicate; got ~S."
                            name value)))
  value)

(defun %validate-span-processor-boolean (value name)
  (unless (or (null value) (eq value t))
    (error 'tracing-error
           :message (format nil "~A must be NIL or T; got ~S." name value)))
  value)

(defun make-simple-span-processor (exporter &rest option-list)
  "Create a synchronous span processor.

EXPORTER is called with a proper list containing each sampled detached
SPAN-RECORD, one record per call.  Optional callbacks are the same as the
generic span processor callbacks: FLUSH and SHUTDOWN receive the provider,
and ERROR-HANDLER receives an error and the callback argument that failed.

Install this processor in a TRACER-PROVIDER's SPAN-PROCESSORS option and leave
the provider's legacy direct EXPORTER option NIL when using this processor,
otherwise both export paths will run."
  (let* ((options (%parse-keyword-options
                   option-list
                   '(:flush :shutdown :error-handler)
                   "make-simple-span-processor"))
         (exporter (%validate-span-exporter exporter))
         (flush (%validate-trace-callback
                 (%option-value options :flush nil)
                 "Simple span processor FLUSH callback"))
         (shutdown (%validate-trace-callback
                    (%option-value options :shutdown nil)
                    "Simple span processor SHUTDOWN callback"))
         (error-handler (%validate-trace-callback
                         (%option-value options :error-handler nil)
                         "Simple span processor ERROR-HANDLER callback"))
         (lock (cl-concurrent-kit:make-lock
                :name "observability-kit simple span processor"))
         (shutdown-p nil))
    (make-span-processor
     :on-end (lambda (record)
               (when (span-record-sampled-p record)
                 (cl-concurrent-kit:with-lock-held (lock)
                   (unless shutdown-p
                     (funcall exporter (list record))))))
     :force-flush (lambda (provider)
                    (cl-concurrent-kit:with-lock-held (lock)
                      (unless shutdown-p
                        (when flush
                          (funcall flush provider)))))
     :shutdown (lambda (provider)
                 (let ((call-shutdown-p nil))
                   (cl-concurrent-kit:with-lock-held (lock)
                     (unless shutdown-p
                       (setf shutdown-p t
                             call-shutdown-p t)))
                   (when (and call-shutdown-p shutdown)
                     (funcall shutdown provider))))
     :error-handler error-handler)))

(defun make-batch-span-processor (exporter &rest option-list)
  "Create an asynchronous, bounded batch span processor.

EXPORTER is called with a proper list of sampled detached SPAN-RECORD
objects.  The list contains at most MAX-EXPORT-BATCH-SIZE records and keeps
completion order.  Records arriving after MAX-QUEUE-SIZE has been reached are
dropped.  The worker exports a partial batch after SCHEDULE-DELAY seconds.

SCHEDULE-DELAY defaults to five seconds, MAX-QUEUE-SIZE to 2048, and
MAX-EXPORT-BATCH-SIZE to 512.  START defaults to true; set it to NIL to start
the worker lazily when the first record is queued.  FLUSH and SHUTDOWN are
optional lifecycle callbacks receiving the provider, and ERROR-HANDLER is an
optional callback receiving an error and the batch (or NIL for a worker
lifecycle error).

Install this processor in a TRACER-PROVIDER's SPAN-PROCESSORS option and leave
the provider's legacy direct EXPORTER option NIL when using this processor,
otherwise both export paths will run."
  (let* ((options (%parse-keyword-options
                   option-list
                   '(:schedule-delay :max-queue-size :max-export-batch-size
                     :start :flush :shutdown :error-handler)
                   "make-batch-span-processor"))
         (exporter (%validate-span-exporter exporter))
         (schedule-delay (%option-value options :schedule-delay 5.0d0))
         (max-queue-size (%option-value options :max-queue-size 2048))
         (max-export-batch-size
           (%option-value options :max-export-batch-size 512))
         (start (%option-value options :start t))
         (flush (%validate-trace-callback
                 (%option-value options :flush nil)
                 "Batch span processor FLUSH callback"))
         (shutdown (%validate-trace-callback
                    (%option-value options :shutdown nil)
                    "Batch span processor SHUTDOWN callback"))
         (error-handler (%validate-trace-callback
                         (%option-value options :error-handler nil)
                         "Batch span processor ERROR-HANDLER callback"))
         (schedule-delay
           (%validate-span-processor-number
            schedule-delay
            "Batch span processor SCHEDULE-DELAY"
            (lambda (value) (and (realp value) (plusp value)))))
         (max-queue-size
           (%validate-span-processor-number
            max-queue-size
            "Batch span processor MAX-QUEUE-SIZE"
            (lambda (value) (and (integerp value) (plusp value)))))
         (max-export-batch-size
           (%validate-span-processor-number
            max-export-batch-size
            "Batch span processor MAX-EXPORT-BATCH-SIZE"
            (lambda (value) (and (integerp value) (plusp value)))))
         (start (%validate-span-processor-boolean start
                                                  "Batch span processor START"))
         (lock (cl-concurrent-kit:make-lock
                :name "observability-kit batch span processor state"))
         (lifecycle-lock (cl-concurrent-kit:make-lock
                          :name "observability-kit batch span processor lifecycle"))
         (condition-variable
           (cl-concurrent-kit:make-condition-variable
            :name "observability-kit batch span processor condition"))
         (queue nil)
         (queue-first-time nil)
         (thread nil)
         (running-p nil)
         (shutdown-p nil)
         (flush-request-p nil)
         (in-flight-p nil)
         (provider nil)
         (processor nil))
    (labels
        ((capture-provider (candidate)
           (when (tracer-provider-p candidate)
             (cl-concurrent-kit:with-lock-held (lock)
               (unless provider
                 (setf provider candidate)))))
         (queue-due-p (now)
           (and queue-first-time
                (>= (/ (- now queue-first-time)
                       internal-time-units-per-second)
                    schedule-delay)))
         (wait-timeout-locked (now)
           (when queue-first-time
             (max 0d0
                  (- schedule-delay
                     (/ (- now queue-first-time)
                        internal-time-units-per-second)))))
         (take-batch-locked ()
           (let ((batch
                   (loop repeat (min max-export-batch-size (length queue))
                         collect (pop queue))))
             (when (null queue)
               (setf queue-first-time nil
                     flush-request-p nil))
             (setf in-flight-p t)
             batch))
         (report-error (condition argument)
           (let ((known-provider nil))
             (cl-concurrent-kit:with-lock-held (lock)
               (setf known-provider provider))
             (if known-provider
                 (%record-span-processor-error
                  known-provider processor condition argument)
                 (when error-handler
                   (handler-case
                       (funcall error-handler condition argument)
                     (error () nil)))))
           nil)
         (run-worker ()
           (unwind-protect
                (loop
                  (multiple-value-bind (batch exit-p)
                      (cl-concurrent-kit:with-lock-held (lock)
                        (loop
                          (when (and shutdown-p (null queue)
                                     (not in-flight-p))
                            (return (values nil t)))
                          (when (and flush-request-p (null queue))
                            (setf flush-request-p nil))
                          (if (and queue
                                   (or flush-request-p
                                       (>= (length queue)
                                           max-export-batch-size)
                                       (queue-due-p (get-internal-real-time))))
                              (return (values (take-batch-locked) nil))
                              (cl-concurrent-kit:condition-wait
                               condition-variable
                               lock
                               :timeout
                               (wait-timeout-locked
                                (get-internal-real-time))))))
                    (if exit-p
                        (return)
                        (when batch
                          (handler-case
                              (funcall exporter batch)
                            (error (condition)
                              (report-error condition batch)))
                          (cl-concurrent-kit:with-lock-held (lock)
                            (setf in-flight-p nil)
                            (cl-concurrent-kit:condition-broadcast
                             condition-variable))))))
             (cl-concurrent-kit:with-lock-held (lock)
               (setf running-p nil
                     in-flight-p nil)
               (cl-concurrent-kit:condition-broadcast condition-variable))))
         (start-worker-locked (&optional during-shutdown-p)
           (unless (or running-p
                       (and shutdown-p (not during-shutdown-p)))
             (setf running-p t)
             (handler-case
                 (setf thread
                       (cl-concurrent-kit:make-thread
                        #'run-worker
                        :name "observability-kit batch span processor"))
               (error (condition)
                 (setf running-p nil)
                 (error condition)))))
         (force-flush (provider-argument)
           (capture-provider provider-argument)
           (cl-concurrent-kit:with-lock-held (lifecycle-lock)
             (cl-concurrent-kit:with-lock-held (lock)
               (unless shutdown-p
                 (setf flush-request-p t)
                 (when queue
                   (start-worker-locked))
                 (cl-concurrent-kit:condition-broadcast condition-variable)
                 (unless (eq thread (cl-concurrent-kit:current-thread))
                   (loop until (and (null queue) (not in-flight-p))
                         do (cl-concurrent-kit:condition-wait
                             condition-variable lock)))))
             (when (and flush (not shutdown-p))
               (funcall flush provider-argument))
             t))
         (shutdown-processor (provider-argument)
           (capture-provider provider-argument)
           (cl-concurrent-kit:with-lock-held (lifecycle-lock)
             (let ((worker nil)
                   (current-p nil))
               (cl-concurrent-kit:with-lock-held (lock)
                 (unless shutdown-p
                   (setf shutdown-p t
                         flush-request-p t)
                   (when queue
                     (start-worker-locked t))
                   (cl-concurrent-kit:condition-broadcast
                    condition-variable))
                 (setf worker thread
                       current-p (eq worker (cl-concurrent-kit:current-thread)))
                 (unless current-p
                   (loop until (and (null queue) (not in-flight-p))
                         do (cl-concurrent-kit:condition-wait
                             condition-variable lock))))
               (when (and worker (not current-p))
                 (cl-concurrent-kit:join-thread worker))
               (when (and shutdown (not current-p))
                 (funcall shutdown provider-argument))
               t))))
      (setf processor
            (make-span-processor
             :on-start (lambda (span)
                         (capture-provider (%span-provider span)))
             :on-end (lambda (record)
                       (when (span-record-sampled-p record)
                         (cl-concurrent-kit:with-lock-held (lock)
                           (unless shutdown-p
                             (when (< (length queue) max-queue-size)
                               (when (null queue)
                                 (setf queue-first-time
                                       (get-internal-real-time)))
                               (setf queue (nconc queue (list record)))
                               (start-worker-locked)
                               (cl-concurrent-kit:condition-notify
                                condition-variable))))))
             :force-flush #'force-flush
             :shutdown #'shutdown-processor
             :error-handler error-handler))
      (when start
        (cl-concurrent-kit:with-lock-held (lock)
          (start-worker-locked)))
      processor)))
