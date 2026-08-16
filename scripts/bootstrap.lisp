(defpackage #:observability-kit.bootstrap
  (:use #:cl)
  (:export #:initialize-source-registry
           #:project-root
           #:source-files))

(in-package #:observability-kit.bootstrap)

(defparameter *project-directory*
  (uiop:pathname-directory-pathname
   (or *load-truename* *default-pathname-defaults*)))

(defparameter *sibling-systems*
  '("cl-concurrent-kit"
    "cl-boundary-kit"
    "cl-weave"
    "cl-log-kit"
    "cl-date-kit"
    "cl-host-kit"
    "cl-json-kit"))

(defun project-root ()
  (truename (merge-pathnames "../" *project-directory*)))

(defun source-roots (root)
  (remove-if-not
   #'probe-file
   (cons root
         (loop for system in *sibling-systems*
               collect (merge-pathnames
                        (format nil "../~A/" system)
                        root)))))

(defun environment-source-roots ()
  (remove-if-not
   #'probe-file
   (remove-duplicates
    (mapcar #'uiop:ensure-directory-pathname
            (remove nil
                    (uiop:split-native-pathnames-string
                     (or (uiop:getenv "CL_SOURCE_REGISTRY") ""))))
    :test #'equal)))

(defun dependency-source-roots ()
  (remove-duplicates
   (loop for environment-root in (environment-source-roots)
         when (some (lambda (system)
                      (probe-file
                       (merge-pathnames
                        (format nil "~A.asd" system)
                        environment-root)))
                    *sibling-systems*)
           collect environment-root)
   :test #'equal))

(defun initialize-source-registry (&key (root (project-root))
                                   ignore-inherited-configuration)
  (asdf:initialize-source-registry
   (cons :source-registry
         (append
          (mapcar (lambda (path) (list :directory path))
                  (source-roots root))
          (when ignore-inherited-configuration
            (mapcar (lambda (path) (list :directory path))
                    (dependency-source-roots)))
          (list (if ignore-inherited-configuration
                    :ignore-inherited-configuration
                    :inherit-configuration)))))
  root)

(defun source-files (&optional (root (project-root)))
  (sort (directory (merge-pathnames "src/*.lisp" root))
        #'string<
        :key #'namestring))
