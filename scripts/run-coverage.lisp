(load (merge-pathnames
       "../run-coverage.lisp"
       (uiop:pathname-directory-pathname
        (or *load-truename* *default-pathname-defaults*))))
