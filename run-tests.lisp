(require "asdf")

(defparameter *script-directory*
  (uiop:pathname-directory-pathname
   (or *load-truename* *default-pathname-defaults*)))

(load (merge-pathnames "scripts/bootstrap.lisp" *script-directory*))
(observability-kit.bootstrap:initialize-source-registry)
(asdf:load-system "cl-weave")

(let ((success
        (handler-case
            (let ((root (observability-kit.bootstrap:initialize-source-registry)))
              (declare (ignore root))
              (asdf:load-system "cl-observability-kit/test")
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
