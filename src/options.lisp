#.(progn
    (in-package #:observability-kit)
    nil)

(defun %parse-keyword-options (options allowed what)
  "Validate an OPTIONS plist and return it as an ordered alist.

WHAT is included in diagnostics so public constructors can share one parser
without hiding which API rejected a malformed option list."
  (unless (proper-list-p options)
    (error 'observability-error
           :message (format nil "~A options must be a proper property list."
                            what)))
  (let ((remaining options)
        (parsed nil))
    (loop while remaining
          for key = (pop remaining)
          do (unless (keywordp key)
               (error 'observability-error
                      :message (format nil
                                       "~A option names must be keywords, got ~S."
                                       what key)))
             (unless (member key allowed :test #'eq)
               (error 'observability-error
                      :message (format nil
                                       "Unknown ~A option ~S."
                                       what key)))
             (unless remaining
               (error 'observability-error
                      :message (format nil
                                       "~A option ~S is missing a value."
                                       what key)))
             (when (assoc key parsed :test #'eq)
               (error 'observability-error
                      :message (format nil
                                       "~A option ~S was supplied more than once."
                                       what key)))
             (push (cons key (pop remaining)) parsed))
    (nreverse parsed)))

(defun %option-supplied-p (options key)
  (not (null (assoc key options :test #'eq))))

(defun %option-value (options key default)
  (let ((pair (assoc key options :test #'eq)))
    (if pair (cdr pair) default)))
