#+sbcl
(progn
  ;; Use SBCL's direct contrib loader.  REQUIRE delegates to ASDF in the Nix
  ;; shell and can deadlock while it reconciles duplicate registry entries.
  (funcall (symbol-function
            (find-symbol "MODULE-PROVIDE-CONTRIB" "SB-IMPL"))
           :sb-cover)
  (let ((policy (find-symbol "STORE-COVERAGE-DATA" "SB-COVER")))
    (unless policy
      (error "SB-COVER compiler policy is not available."))
    (proclaim `(optimize (,policy 3)))))

(require "asdf")

(defparameter *script-directory*
  (uiop:pathname-directory-pathname
   (or *load-truename* *default-pathname-defaults*)))

(defparameter *coverage-timeout-seconds* 120
  "Maximum time allowed for one complete coverage run.")

(load (merge-pathnames "scripts/bootstrap.lisp" *script-directory*))
(load (merge-pathnames "scripts/test-plan.lisp" *script-directory*))

(let* ((root (observability-kit.bootstrap:initialize-source-registry))
       (report-directory (merge-pathnames "coverage-report/" root))
       (coverage-output (merge-pathnames "coverage.sexp" root))
       (coverage-excluded-files
         '("package.lisp"
           "validation-data.lisp"
           "metrics-declarations.lisp"
           "metrics-macros.lisp"
           "health-declarations.lisp"
           "health-macros.lisp"
           "context-declarations.lisp"
           "context-macros.lisp"
           "resource-declarations.lisp"
           "trace-declarations.lisp"
           "trace-macros.lisp"
           "log-declarations.lisp"
           "log-kit-macros.lisp"
           "package-prometheus.lisp"
           "prometheus-data.lisp"
           "package-otlp.lisp"
           "package-log-kit.lisp"))
       (coverage-source-pathnames
         (observability-kit.bootstrap:source-files root))
       (coverage-exclude-pathnames
         (mapcar (lambda (file)
                   (merge-pathnames file (merge-pathnames "src/" root)))
                 coverage-excluded-files))
       (success
         (handler-case
             (sb-ext:with-timeout *coverage-timeout-seconds*
               (progn
               ;; Remove prior outputs so a failed run cannot validate stale
               ;; coverage data or an old HTML report.
               (when (probe-file coverage-output)
                 (delete-file coverage-output))
               (when (probe-file report-directory)
                 (uiop:delete-directory-tree report-directory :validate t))
               (ensure-directories-exist report-directory)
               (unless coverage-source-pathnames
                 (error "Coverage source selection is empty."))
               (unless (every #'probe-file coverage-exclude-pathnames)
                 (error "Coverage exclusion list contains a missing source file."))
               (format t "~&Coverage source policy: ~D source files, ~D excluded.~%"
                       (length coverage-source-pathnames)
                       (length coverage-exclude-pathnames))
               ;; Compile implementation systems under SB-COVER before loading
               ;; the test system.  This is cl-weave's coverage contract:
               ;; coverage instrumentation must precede test-system loading.
               (dolist (system '("cl-observability-kit"
                                  "cl-observability-kit/prometheus"
                                  "cl-observability-kit/otlp"
                                  "cl-observability-kit/log-kit"))
                 (asdf:load-system system :force t))
               (asdf:load-system "cl-observability-kit/test")
               (observability-kit.test-plan:assert-runnable-test-plan)
               (uiop:symbol-call '#:cl-weave '#:reset-coverage)
               (let ((result
                       (uiop:symbol-call '#:cl-weave '#:run-all
                          :reporter :spec
                          :pass-with-no-tests nil
                          :coverage t
                          :coverage-output coverage-output
                          :coverage-report-directory report-directory
                          :coverage-include-pathnames
                          coverage-source-pathnames
                          :coverage-exclude-pathnames coverage-exclude-pathnames
                          :coverage-minimum-expression 100
                          :coverage-minimum-branch 100
                          :coverage-reset nil)))
                 (when result
                   (observability-kit.test-plan:assert-non-empty-file
                    coverage-output
                    "Coverage data")
                   (observability-kit.test-plan:assert-non-empty-file
                    (merge-pathnames "cover-index.html" report-directory)
                    "Coverage report"))
                 result)))
           (error (condition)
             (format *error-output* "~&Coverage runner failed (~S): ~A~%"
                     (type-of condition)
                     condition)
             (uiop:print-condition-backtrace condition :stream *error-output*)
             nil))))
  (finish-output)
  (uiop:quit (if success 0 1)))
