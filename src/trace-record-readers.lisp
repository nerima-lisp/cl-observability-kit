;;;; Detached span-record readers.

#.(progn
    (in-package #:observability-kit)
    nil)

(defun span-record-trace-id (record)
  (check-type record span-record)
  (%copy-observability-value (%span-record-trace-id record)))

(defun span-record-span-id (record)
  (check-type record span-record)
  (%copy-observability-value (%span-record-span-id record)))

(defun span-record-parent-span-id (record)
  (check-type record span-record)
  (%copy-observability-value (%span-record-parent-span-id record)))

(defun span-record-name (record)
  (check-type record span-record)
  (%copy-observability-value (%span-record-name record)))

(defun span-record-kind (record)
  (check-type record span-record)
  (%span-record-kind record))

(defun span-record-start-time (record)
  (check-type record span-record)
  (%span-record-start-time record))

(defun span-record-end-time (record)
  (check-type record span-record)
  (%span-record-end-time record))

(defun span-record-duration (record)
  (check-type record span-record)
  (%span-record-duration record))

(defun span-record-status (record)
  (check-type record span-record)
  (%span-record-status record))

(defun span-record-status-message (record)
  (check-type record span-record)
  (%copy-observability-value (%span-record-status-message record)))

(defun span-record-trace-flags (record)
  (check-type record span-record)
  (%span-record-trace-flags record))

(defun span-record-sampled-p (record)
  (check-type record span-record)
  (%span-record-sampled-p record))

(defun span-record-recording-p (record)
  (check-type record span-record)
  (%span-record-recording-p record))

(defun span-record-attributes (record)
  (check-type record span-record)
  (%copy-alist (%span-record-attributes record)))

(defun span-record-events (record)
  (check-type record span-record)
  (mapcar #'%copy-span-event (%span-record-events record)))

(defun span-record-links (record)
  (check-type record span-record)
  (mapcar #'%copy-span-link (%span-record-links record)))

(defun span-record-resource (record)
  (check-type record span-record)
  (make-resource :attributes
                 (resource-attributes (%span-record-resource record))))

(defun span-record-tracer-name (record)
  (check-type record span-record)
  (%copy-observability-value (%span-record-tracer-name record)))

(defun span-record-tracer-version (record)
  (check-type record span-record)
  (%copy-observability-value (%span-record-tracer-version record)))

(defun span-record-tracer-schema-url (record)
  (check-type record span-record)
  (%copy-observability-value (%span-record-tracer-schema-url record)))
