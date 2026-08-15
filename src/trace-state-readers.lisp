(in-package #:observability-kit)

(defun span-name (span)
  (check-type span span)
  (%copy-observability-value (%span-name span)))

(defun span-kind (span)
  (check-type span span)
  (%span-kind span))

(defun span-trace-id (span)
  (check-type span span)
  (%copy-observability-value (%span-trace-id span)))

(defun span-id (span)
  (check-type span span)
  (%copy-observability-value (%span-span-id span)))

(defun span-parent-span-id (span)
  (check-type span span)
  (%copy-observability-value (%span-parent-span-id span)))

(defun span-trace-flags (span)
  (check-type span span)
  (%span-trace-flags span))

(defun span-start-time (span)
  (check-type span span)
  (%span-start-time span))

(defun span-end-time (span)
  (check-type span span)
  (%span-end-time span))

(defun span-duration (span)
  (check-type span span)
  (cl-concurrent-kit:with-lock-held ((%span-lock span))
    (when (%span-end-monotonic span)
      (/ (- (%span-end-monotonic span) (%span-start-monotonic span))
         (%tracer-provider-monotonic-units-per-second (%span-provider span))))))

(defun span-status (span)
  (check-type span span)
  (%span-status span))

(defun span-status-message (span)
  (check-type span span)
  (%copy-observability-value (%span-status-message span)))

(defun span-recording-p (span)
  (check-type span span)
  (%span-recording-p span))

(defun span-sampled-p (span)
  (check-type span span)
  (%span-sampled-p span))

(defun span-ended-p (span)
  (check-type span span)
  (cl-concurrent-kit:with-lock-held ((%span-lock span))
    (%span-ended-p span)))

(defun span-context (span)
  "Return the detached propagation context represented by SPAN."
  (check-type span span)
  (%make-instrumentation-context
   (%span-trace-id span)
   (%span-span-id span)
   (%span-trace-flags span)
   (%copy-alist (%span-context-attributes span))
   (%copy-alist (%span-baggage span))
   (%span-tracestate span)))

(defun span-attributes (span)
  (check-type span span)
  (cl-concurrent-kit:with-lock-held ((%span-lock span))
    (%copy-alist (%span-attributes span))))
