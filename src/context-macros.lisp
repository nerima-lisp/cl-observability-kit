(defmacro with-instrumentation-context ((context) &body body)
  "Execute BODY with CONTEXT as the current instrumentation context."
  `(let ((*instrumentation-context* (progn
                                      (check-type ,context instrumentation-context)
                                      ,context)))
     ,@body))

(defmacro with-captured-instrumentation-context ((context) &body body)
  "Execute BODY with a detached copy of CONTEXT dynamically bound."
  `(call-with-captured-instrumentation-context
    ,context
    (lambda () ,@body)))
