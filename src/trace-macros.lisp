#.(progn
    (in-package #:observability-kit)
    nil)

(defmacro with-span ((variable tracer name &rest options) &body body)
  "Run BODY in a dynamically scoped span and end it on every exit path."
  `(let ((,variable (start-span ,tracer ,name ,@options)))
     (unwind-protect
          (call-with-span
           ,variable
           (lambda (,variable)
             (handler-case
                 (progn ,@body)
               (error (condition)
                 (span-record-exception ,variable condition)
                 (error condition)))))
       (end-span ,variable))))
