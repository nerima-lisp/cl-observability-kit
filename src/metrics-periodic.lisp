#.(progn
    (in-package #:observability-kit)
    nil)

(defstruct (periodic-metric-reader
            (:constructor %make-periodic-metric-reader
                (reader interval lock thread running-p shutdown-p last-error))
            (:conc-name %periodic-metric-reader-))
  reader
  interval
  lock
  thread
  running-p
  shutdown-p
  last-error)

(defun %periodic-record-error (periodic condition)
  (cl-concurrent-kit:with-lock-held
      ((%periodic-metric-reader-lock periodic))
    (setf (%periodic-metric-reader-last-error periodic) condition))
  nil)

(defun %periodic-active-p (periodic)
  (cl-concurrent-kit:with-lock-held
      ((%periodic-metric-reader-lock periodic))
    (and (%periodic-metric-reader-running-p periodic)
         (not (%periodic-metric-reader-shutdown-p periodic)))))

(defun %periodic-sleep-until-next-collection (periodic)
  (let ((remaining (%periodic-metric-reader-interval periodic)))
    (loop while (and (plusp remaining)
                     (%periodic-active-p periodic)
                     (not (metric-reader-shutdown-p
                           (%periodic-metric-reader-reader periodic))))
          for delay = (min 0.05d0 remaining)
          do (sleep delay)
             (decf remaining delay))))

(defun %run-periodic-metric-reader (periodic)
  (handler-case
      (unwind-protect
           (loop while (%periodic-active-p periodic)
                 do (collect-metric-reader
                     (%periodic-metric-reader-reader periodic))
                    (%periodic-sleep-until-next-collection periodic))
        (cl-concurrent-kit:with-lock-held
            ((%periodic-metric-reader-lock periodic))
          (setf (%periodic-metric-reader-running-p periodic) nil)))
    (error (condition)
      (%periodic-record-error periodic condition)
      (cl-concurrent-kit:with-lock-held
          ((%periodic-metric-reader-lock periodic))
        (setf (%periodic-metric-reader-running-p periodic) nil)))))

(defun %periodic-reader-options (options)
  (loop for key in '(:exporter :flush :shutdown :error-handler)
        when (%option-supplied-p options key)
          append (list key (%option-value options key nil))))

(defun make-periodic-metric-reader (source &rest option-list)
  "Create a metric reader that collects SOURCE at a fixed interval.

The underlying reader owns exporter, flush, shutdown, and error-handler
callbacks.  START defaults to true; shutdown is idempotent and joins the
worker before returning.  The worker uses short sleep slices so shutdown does
not have to wait for an entire interval."
  (let* ((options (%parse-keyword-options
                   option-list
                   '(:interval :start :exporter :flush :shutdown
                     :error-handler)
                   "MAKE-PERIODIC-METRIC-READER"))
         (interval (%option-value options :interval 60.0d0))
         (start (%option-value options :start t)))
    (unless (and (realp interval) (plusp interval))
      (error 'observability-error
             :message "Periodic metric reader interval must be a positive real."))
    (unless (member start '(nil t) :test #'eq)
      (error 'observability-error
             :message "Periodic metric reader start must be true or false."))
    (let ((periodic
            (%make-periodic-metric-reader
             (apply #'make-metric-reader
                    source
                    (%periodic-reader-options options))
             (coerce interval 'double-float)
             (cl-concurrent-kit:make-lock
              :name "observability-periodic-metric-reader")
             nil nil nil nil)))
      (when start
        (start-periodic-metric-reader periodic))
      periodic)))

(defun periodic-metric-reader-reader (periodic)
  (check-type periodic periodic-metric-reader)
  (%periodic-metric-reader-reader periodic))

(defun periodic-metric-reader-interval (periodic)
  (check-type periodic periodic-metric-reader)
  (%periodic-metric-reader-interval periodic))

(defun periodic-metric-reader-running-p (periodic)
  (check-type periodic periodic-metric-reader)
  (cl-concurrent-kit:with-lock-held
      ((%periodic-metric-reader-lock periodic))
    (%periodic-metric-reader-running-p periodic)))

(defun periodic-metric-reader-shutdown-p (periodic)
  (check-type periodic periodic-metric-reader)
  (cl-concurrent-kit:with-lock-held
      ((%periodic-metric-reader-lock periodic))
    (%periodic-metric-reader-shutdown-p periodic)))

(defun periodic-metric-reader-last-error (periodic)
  (check-type periodic periodic-metric-reader)
  (cl-concurrent-kit:with-lock-held
      ((%periodic-metric-reader-lock periodic))
    (%periodic-metric-reader-last-error periodic)))

(defun start-periodic-metric-reader (periodic)
  "Start PERIODIC unless it is already running or shut down."
  (check-type periodic periodic-metric-reader)
  (when (metric-reader-shutdown-p
         (%periodic-metric-reader-reader periodic))
    (error 'observability-error
           :message "Cannot start a shut down periodic metric reader."))
  (cl-concurrent-kit:with-lock-held
      ((%periodic-metric-reader-lock periodic))
    (when (%periodic-metric-reader-shutdown-p periodic)
      (error 'observability-error
             :message "Cannot start a shut down periodic metric reader."))
    (unless (%periodic-metric-reader-running-p periodic)
      (setf (%periodic-metric-reader-running-p periodic) t)
      (handler-case
          (setf (%periodic-metric-reader-thread periodic)
                (cl-concurrent-kit:make-thread
                 (lambda () (%run-periodic-metric-reader periodic))
                 :name "observability-periodic-metric-reader"))
        (error (condition)
          (setf (%periodic-metric-reader-running-p periodic) nil
                (%periodic-metric-reader-last-error periodic) condition)
          (error condition))))
  periodic))

(defun collect-periodic-metric-reader (periodic &key (export-p t))
  "Collect PERIODIC immediately through its underlying metric reader."
  (check-type periodic periodic-metric-reader)
  (collect-metric-reader (%periodic-metric-reader-reader periodic)
                         :export-p export-p))

(defun force-flush-periodic-metric-reader (periodic)
  "Collect and flush PERIODIC through its underlying metric reader."
  (check-type periodic periodic-metric-reader)
  (force-flush-metric-reader (%periodic-metric-reader-reader periodic)))

(defun shutdown-periodic-metric-reader (periodic)
  "Stop PERIODIC, join its worker, and shut down its underlying reader."
  (check-type periodic periodic-metric-reader)
  (let ((thread nil))
    (cl-concurrent-kit:with-lock-held
        ((%periodic-metric-reader-lock periodic))
      (unless (%periodic-metric-reader-shutdown-p periodic)
        (setf (%periodic-metric-reader-shutdown-p periodic) t
              (%periodic-metric-reader-running-p periodic) nil
              thread (%periodic-metric-reader-thread periodic))))
    (when thread
      (cl-concurrent-kit:join-thread thread))
    (shutdown-metric-reader (%periodic-metric-reader-reader periodic))
    t))
