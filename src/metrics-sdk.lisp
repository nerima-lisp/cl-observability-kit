#.(progn
    (in-package #:observability-kit)
    nil)

(defstruct (metric-reader
            (:constructor %make-metric-reader
                (source exporter flush shutdown error-handler lock shutdown-p
                 last-error last-snapshots))
            (:conc-name %metric-reader-))
  source
  exporter
  flush
  shutdown
  error-handler
  lock
  shutdown-p
  last-error
  last-snapshots)

(defun %metric-callback-p (value)
  (or (functionp value)
      (and (symbolp value) (fboundp value))))

(defun %validate-optional-metric-callback (value what)
  (when (and value (not (%metric-callback-p value)))
    (error 'observability-error
           :message (format nil "~A must be a function." what)))
  value)

(defun %metric-reader-source-p (source)
  (or (metric-p source)
      (metric-registry-p source)
      (meter-p source)
      (meter-provider-p source)))

(defun %copy-metric-snapshot (snapshot)
  (make-metric-snapshot
   :name (%copy-observability-value (%metric-snapshot-name snapshot))
   :help (%copy-observability-value (%metric-snapshot-help snapshot))
   :type (%metric-snapshot-type snapshot)
   :unit (%copy-observability-value (%metric-snapshot-unit snapshot))
   :label-names (mapcar #'%copy-observability-value
                        (%metric-snapshot-label-names snapshot))
   :samples (mapcar #'%copy-metric-sample
                    (%metric-snapshot-samples snapshot))
   :resource (metric-snapshot-resource snapshot)
   :scope-name (%copy-observability-value
                (%metric-snapshot-scope-name snapshot))
   :scope-version (%copy-observability-value
                   (%metric-snapshot-scope-version snapshot))
   :scope-schema-url (%copy-observability-value
                      (%metric-snapshot-scope-schema-url snapshot))
   :temporality (%metric-snapshot-temporality snapshot)
   :timestamp (%metric-snapshot-timestamp snapshot)
   :start-time (%metric-snapshot-start-time snapshot)))

(defun %metric-source-snapshots (source)
  (let ((snapshots (metric-snapshot source)))
    (if (listp snapshots)
        snapshots
        (list snapshots))))

(defun register-metric-reader (provider reader)
  "Attach READER to PROVIDER for provider-level flush and shutdown calls."
  (check-type provider meter-provider)
  (check-type reader metric-reader)
  (cl-concurrent-kit:with-lock-held ((%meter-provider-lock provider))
    (when (%meter-provider-shutdown-p provider)
      (error 'observability-error
             :message "Cannot register a metric reader on a shut down meter provider."))
    (pushnew reader (%meter-provider-readers provider) :test #'eq))
  reader)

(defun make-metric-reader (source &rest option-list)
  "Create a pull reader for SOURCE.

EXPORTER receives a detached list of metric snapshots.  Readers never call an
exporter while holding a registry or provider lock; exporter failures are
retained in METRIC-READER-LAST-ERROR and passed to ERROR-HANDLER when one is
configured."
  (unless (%metric-reader-source-p source)
    (error 'type-error
           :datum source
           :expected-type '(or metric metric-registry meter meter-provider)))
  (let* ((options (%parse-keyword-options
                   option-list
                   '(:exporter :flush :shutdown :error-handler)
                   "MAKE-METRIC-READER"))
         (exporter (%validate-optional-metric-callback
                    (%option-value options :exporter nil)
                    "Metric reader exporter"))
         (flush (%validate-optional-metric-callback
                 (%option-value options :flush nil)
                 "Metric reader flush callback"))
         (shutdown (%validate-optional-metric-callback
                    (%option-value options :shutdown nil)
                    "Metric reader shutdown callback"))
         (error-handler (%validate-optional-metric-callback
                         (%option-value options :error-handler nil)
                         "Metric reader error handler"))
         (reader (%make-metric-reader
                  source exporter flush shutdown error-handler
                  (cl-concurrent-kit:make-lock :name "observability-metric-reader")
                  nil nil nil)))
    (when (meter-provider-p source)
      (register-metric-reader source reader))
    reader))

(defun metric-reader-source (reader)
  (check-type reader metric-reader)
  (%metric-reader-source reader))

(defun metric-reader-shutdown-p (reader)
  (check-type reader metric-reader)
  (cl-concurrent-kit:with-lock-held ((%metric-reader-lock reader))
    (%metric-reader-shutdown-p reader)))

(defun metric-reader-last-error (reader)
  (check-type reader metric-reader)
  (cl-concurrent-kit:with-lock-held ((%metric-reader-lock reader))
    (%metric-reader-last-error reader)))

(defun metric-reader-last-snapshots (reader)
  (check-type reader metric-reader)
  (cl-concurrent-kit:with-lock-held ((%metric-reader-lock reader))
    (mapcar #'%copy-metric-snapshot
            (%metric-reader-last-snapshots reader))))

(defun collect-metric-reader (reader &key (export-p t))
  "Collect SOURCE and optionally pass detached snapshots to EXPORTER."
  (check-type reader metric-reader)
  (handler-case
      (progn
        (when (metric-reader-shutdown-p reader)
          (error 'observability-error
                 :message "Cannot collect from a shut down metric reader."))
        (let* ((snapshots (%metric-source-snapshots (%metric-reader-source reader)))
               (detached (mapcar #'%copy-metric-snapshot snapshots)))
          (cl-concurrent-kit:with-lock-held ((%metric-reader-lock reader))
            (setf (%metric-reader-last-snapshots reader)
                  detached))
          (when (and export-p (%metric-reader-exporter reader))
            (funcall (%metric-reader-exporter reader)
                     (mapcar #'%copy-metric-snapshot snapshots)))
          (values detached t)))
    (error (condition)
      (cl-concurrent-kit:with-lock-held ((%metric-reader-lock reader))
        (setf (%metric-reader-last-error reader) condition))
      (when (%metric-reader-error-handler reader)
        (ignore-errors
          (funcall (%metric-reader-error-handler reader) condition)))
      (values nil nil))))

(defun force-flush-metric-reader (reader)
  "Collect READER and invoke its flush callback, returning true on success."
  (check-type reader metric-reader)
  (multiple-value-bind (snapshots collected-p)
      (collect-metric-reader reader)
    (declare (ignore snapshots))
    (and collected-p
         (if (%metric-reader-flush reader)
             (handler-case
                 (progn
                   (funcall (%metric-reader-flush reader))
                   t)
               (error (condition)
                 (cl-concurrent-kit:with-lock-held ((%metric-reader-lock reader))
                   (setf (%metric-reader-last-error reader) condition))
                 (when (%metric-reader-error-handler reader)
                   (ignore-errors
                     (funcall (%metric-reader-error-handler reader) condition)))
                 nil))
             t))))

(defun shutdown-metric-reader (reader)
  "Shut down READER exactly once and isolate shutdown callback failures."
  (check-type reader metric-reader)
  (let ((shutdown nil))
    (cl-concurrent-kit:with-lock-held ((%metric-reader-lock reader))
      (unless (%metric-reader-shutdown-p reader)
        (setf (%metric-reader-shutdown-p reader) t
              shutdown (%metric-reader-shutdown reader))))
    (when shutdown
      (handler-case
          (funcall shutdown)
        (error (condition)
          (cl-concurrent-kit:with-lock-held ((%metric-reader-lock reader))
            (setf (%metric-reader-last-error reader) condition))
          (when (%metric-reader-error-handler reader)
            (ignore-errors
              (funcall (%metric-reader-error-handler reader) condition))))))
    t))
