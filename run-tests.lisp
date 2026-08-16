#+sbcl
(require :sb-cover)

(require "asdf")

(defparameter *script-directory*
  (uiop:pathname-directory-pathname
   (or *load-truename* *default-pathname-defaults*)))

(load (merge-pathnames "scripts/bootstrap.lisp" *script-directory*))
(defparameter *project-root* (observability-kit.bootstrap:project-root))
(observability-kit.bootstrap:initialize-source-registry
 :root *project-root*
 :ignore-inherited-configuration t)
(format t "~&Loading cl-weave...~%")
(finish-output)
(asdf:load-system "cl-weave")
(format t "~&Loading test plan...~%")
(finish-output)
(load (merge-pathnames "scripts/test-plan.lisp" *script-directory*))

(let ((success
        (handler-case
            (progn
              (format t "~&Loading cl-observability-kit/test...~%")
              (finish-output)
              (asdf:load-system "cl-observability-kit/test")
              (observability-kit.test-plan:assert-runnable-test-plan)
              (format t "~&Running test plan...~%")
              (finish-output)
              (cl-weave:run-all
               :reporter :spec
               :pass-with-no-tests nil))
          (error (condition)
            (format *error-output* "~&Test runner failed (~S): ~A~%"
                    (type-of condition)
                    condition)
            (uiop:print-condition-backtrace condition :stream *error-output*)
            nil))))
  (finish-output)
  (uiop:quit (if success 0 1)))
