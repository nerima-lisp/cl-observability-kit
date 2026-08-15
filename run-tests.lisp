(defparameter *test-timeout-seconds* 120
  "Maximum runtime for the direct test command, in seconds.")

(require "asdf")

(defparameter *script-directory*
  (uiop:pathname-directory-pathname
   (or *load-truename* *default-pathname-defaults*)))

(load (merge-pathnames "scripts/bootstrap.lisp" *script-directory*))
(observability-kit.bootstrap:initialize-source-registry)
(asdf:load-system "cl-weave")
(load (merge-pathnames "scripts/test-plan.lisp" *script-directory*))

(let ((success
        (handler-case
            #+sbcl
            (sb-ext:with-timeout *test-timeout-seconds*
              (let ((root (observability-kit.bootstrap:initialize-source-registry)))
                (declare (ignore root))
                (asdf:load-system "cl-observability-kit/test")
                (observability-kit.test-plan:assert-runnable-test-plan)
                (cl-weave:run-all
                 :reporter :spec
                 :pass-with-no-tests nil)))
            #-sbcl
            (progn
              (asdf:load-system "cl-observability-kit/test")
              (observability-kit.test-plan:assert-runnable-test-plan)
              (cl-weave:run-all :reporter :spec :pass-with-no-tests nil))
          (error (condition)
            (format *error-output* "~&Test runner failed (~S): ~A~%"
                    (type-of condition)
                    condition)
            (uiop:print-condition-backtrace condition :stream *error-output*)
            nil))))
  (finish-output)
  (uiop:quit (if success 0 1)))
