#.(progn
    (in-package #:observability-kit)
    nil)

(defun %validate-real (value what)
  (unless (realp value)
    (error 'observability-error
           :message (format nil "~A must be a real number, got ~S." what value)))
  value)

(defun %finite-float-p (value)
  (and (= value value)
       #+sbcl (not (sb-ext:float-infinity-p value))
       #-sbcl t))

(defun %finite-real-p (value)
  (and (realp value)
       (or (not (floatp value))
           (%finite-float-p value))))

(defun %validate-finite-real (value what)
  (%validate-real value what)
  (unless (%finite-real-p value)
    (error 'observability-error
           :message (format nil "~A must be finite, got ~S." what value)))
  value)

(defun %validate-positive-integer (value what)
  (unless (and (integerp value) (plusp value))
    (error 'observability-error
           :message (format nil "~A must be a positive integer, got ~S." what value)))
  value)

(defun %copy-alist (alist)
  (mapcar (lambda (pair)
            (cons (%copy-observability-value (car pair))
                  (%copy-observability-value (cdr pair))))
          alist))

(defun %labels-less-p (left right)
  (loop for left-pair in left
        for right-pair in right
        do (cond
             ((string< (car left-pair) (car right-pair)) (return t))
             ((string< (car right-pair) (car left-pair)) (return nil))
             ((string< (cdr left-pair) (cdr right-pair)) (return t))
             ((string< (cdr right-pair) (cdr left-pair)) (return nil)))
        finally (return (< (length left) (length right)))))
