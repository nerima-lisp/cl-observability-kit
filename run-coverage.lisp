(require "asdf")

#+sbcl
(progn
  (require :sb-cover)
  (let ((policy (find-symbol "STORE-COVERAGE-DATA" "SB-COVER")))
    (unless policy
      (error "SB-COVER compiler policy is not available."))
    (proclaim `(optimize (,policy 3)))))

(defparameter *script-directory*
  (uiop:pathname-directory-pathname
   (or *load-truename* *default-pathname-defaults*)))

(load (merge-pathnames "scripts/bootstrap.lisp" *script-directory*))

(let* ((root (observability-kit.bootstrap:initialize-source-registry))
       (report-directory (merge-pathnames "coverage-report/" root))
       (coverage-output (merge-pathnames "coverage.sexp" root))
       (coverage-excluded-files
         '("package.lisp"
           "conditions.lisp"
           "validation-data.lisp"
           "metrics-declarations.lisp"
           "metrics-macros.lisp"
           "health-declarations.lisp"
           "context-declarations.lisp"
           "context-macros.lisp"
           "log-kit-macros.lisp"))
       (coverage-exclude-pathnames
         (mapcar (lambda (file)
                   (merge-pathnames file (merge-pathnames "src/" root)))
                 coverage-excluded-files))
       (success
         (handler-case
             (progn
               (ensure-directories-exist report-directory)
               ;; SB-COVER clears the source table as well as the execution
               ;; bits.  Reload the implementation systems after the reset
               ;; so optional exporters are part of the same measured run.
               (asdf:load-system "cl-observability-kit/test" :force t)
               (uiop:symbol-call '#:cl-weave '#:reset-coverage)
               (dolist (system '("cl-observability-kit"
                                  "cl-observability-kit/prometheus"
                                  "cl-observability-kit/otlp"
                                  "cl-observability-kit/log-kit"))
                 (asdf:load-system system :force t))
               (uiop:symbol-call
                '#:cl-weave '#:run-all
                :reporter :spec
                :pass-with-no-tests nil
                :coverage t
                :coverage-output coverage-output
                :coverage-report-directory report-directory
                :coverage-include-pathnames
                (observability-kit.bootstrap:source-files root)
                :coverage-exclude-pathnames coverage-exclude-pathnames
                :coverage-minimum-expression 100
                :coverage-minimum-branch 100
                :coverage-reset nil))
           (error (condition)
             (format *error-output* "~&Coverage runner failed (~S): ~A~%"
                     (type-of condition)
                     condition)
             (uiop:print-condition-backtrace condition :stream *error-output*)
             nil))))
  (finish-output)
  (uiop:quit (if success 0 1)))
