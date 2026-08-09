#.(progn
    (in-package #:observability-kit)
    nil)

(defun %validate-health-definition-options (options)
  (unless (proper-list-p options)
    (error 'program-error))
  (handler-case
      (progn
        (%parse-keyword-options
         options
         '(:kind :timeout :cancellation-grace-period :replace)
         "DEFINE-HEALTH-CHECK")
        options)
    (observability-error ()
      (error 'program-error))))

(defmacro define-health-check (registry name (&rest options) lambda-list &body body)
  "Register a named health check whose function accepts one cancellation token.

NAME is a source-level symbol and OPTIONS are checked during macroexpansion;
the resulting registration still evaluates REGISTRY and option values at
runtime."
  (%validate-health-definition-options options)
  (unless (and (symbolp name) (not (keywordp name)))
    (error 'program-error))
  `(register-health-check
    ,registry
    ',name
    (lambda ,lambda-list ,@body)
    ,@options))
