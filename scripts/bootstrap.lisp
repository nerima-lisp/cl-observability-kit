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

(defun initialize-source-registry (&optional (root (project-root)))
  (asdf:initialize-source-registry
   (cons :source-registry
         (append (mapcar (lambda (path) (list :tree path))
                         (source-roots root))
                 (list :inherit-configuration))))
  root)

(defun source-files (&optional (root (project-root)))
  (sort (directory (merge-pathnames "src/*.lisp" root))
        #'string<
        :key #'namestring))
