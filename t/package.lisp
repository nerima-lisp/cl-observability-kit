(defpackage #:observability-kit.test
  (:use #:cl #:cl-weave #:observability-kit)
  (:shadowing-import-from #:cl-weave #:describe)
  (:export #:run-tests))

(in-package #:observability-kit.test)

(defun run-tests ()
  (run-all :reporter :spec :pass-with-no-tests nil))
