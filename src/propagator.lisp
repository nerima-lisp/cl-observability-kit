#.(progn
    (in-package #:observability-kit)
    nil)

;;;; Composable context propagation

(defstruct (propagator
            (:constructor %make-propagator (inject extract))
            (:conc-name %propagator-))
  inject
  extract)

(defun %propagator-callback-p (callback)
  (or (functionp callback)
      (and (symbolp callback) (fboundp callback))))

(defun %validate-propagator-callback (callback name)
  (unless (%propagator-callback-p callback)
    (error 'propagation-error
           :message (format nil
                            "~A must be a function designator, got ~S."
                            name callback)))
  callback)

(defun make-propagator (&rest option-list)
  "Create a context PROPAGATOR from INJECT and EXTRACT callbacks.

INJECT receives an instrumentation context and a detached header alist and
must return a header alist.  EXTRACT receives a detached header alist and
returns an instrumentation context or NIL."
  (let* ((options (%parse-keyword-options option-list
                                          '(:inject :extract)
                                          "MAKE-PROPAGATOR"))
         (inject (%validate-propagator-callback
                  (%option-value options :inject nil)
                  "Propagator INJECT callback"))
         (extract (%validate-propagator-callback
                   (%option-value options :extract nil)
                   "Propagator EXTRACT callback")))
    (%make-propagator inject extract)))

(defun make-w3c-propagator ()
  "Create a propagator for W3C Trace Context and Baggage headers."
  (%make-propagator #'inject-trace-context #'extract-trace-context))

(defun make-composite-propagator (&rest propagators)
  "Create a propagator that composes PROPAGATORS in order.

Injection feeds each propagator's result into the next one.  Extraction
returns the first non-NIL context returned by a member propagator."
  (unless (proper-list-p propagators)
    (error 'propagation-error
           :message "Composite propagators must be supplied as a proper list."))
  (dolist (propagator propagators)
    (unless (propagator-p propagator)
      (error 'propagation-error
             :message (format nil
                              "Composite members must be PROPAGATOR objects, got ~S."
                              propagator))))
  (%make-propagator
   (lambda (context headers)
     (reduce (lambda (current propagator)
               (funcall (%propagator-inject propagator) context current))
             propagators
             :initial-value headers))
   (lambda (headers)
     (loop for propagator in propagators
           for context = (funcall (%propagator-extract propagator) headers)
           when context
             return context))))

(defun propagator-inject (propagator context headers)
  "Inject CONTEXT into HEADERS using PROPAGATOR.

Both the input and callback result are detached header alists."
  (check-type propagator propagator)
  (%header-list
   (funcall (%propagator-inject propagator)
            context
            (%header-list headers))))

(defun propagator-extract (propagator headers)
  "Extract an instrumentation context from HEADERS using PROPAGATOR."
  (check-type propagator propagator)
  (funcall (%propagator-extract propagator)
           (%header-list headers)))
