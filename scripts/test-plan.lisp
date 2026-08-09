(defpackage #:observability-kit.test-plan
  (:use #:cl)
  (:export #:assert-non-empty-file
           #:assert-runnable-test-plan))

(in-package #:observability-kit.test-plan)

(defun assert-runnable-test-plan ()
  "Reject an empty or partially selected CL-WEAVE test plan."
  (let ((plan (cl-weave:collect-test-plan (cl-weave:root-suite))))
    (unless plan
      (error "Test plan selection is empty."))
    (let ((non-runnable
            (remove-if (lambda (entry)
                         (eq :run (cl-weave:test-plan-entry-status entry)))
                       plan)))
      (when non-runnable
        (error "Test plan contains non-runnable entries: ~S"
               (cl-weave:test-plan-facts non-runnable))))
    (format t "~&Test plan: ~D runnable tests.~%" (length plan))
    plan))

(defun assert-non-empty-file (pathname description)
  "Assert that PATHNAME exists and contains bytes for DESCRIPTION."
  (let ((file (probe-file pathname)))
    (unless file
      (error "~A was not produced: ~S" description pathname))
    (with-open-file (stream file :element-type '(unsigned-byte 8))
      (unless (plusp (file-length stream))
        (error "~A is empty: ~S" description pathname)))
    file))
