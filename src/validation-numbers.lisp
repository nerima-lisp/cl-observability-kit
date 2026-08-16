#.(progn
    (in-package #:observability-kit)
    nil)

(defun %validate-real (value what)
  (unless (realp value)
    (error 'observability-error
           :message (format nil "~A must be a real number, got ~S." what value)))
  value)

(defun %finite-float-p (value)
  ;; `(= value value)` is the classic NaN test, but on x86-64 SBCL leaves the
  ;; :invalid float trap enabled, so comparing a NaN signals
  ;; FLOATING-POINT-INVALID-OPERATION instead of returning NIL: passing a NaN
  ;; metric value raised a raw arithmetic error on Linux while returning a
  ;; clean validation failure on aarch64-darwin, where the trap is masked.
  ;; The bit-pattern predicates never trap, so both platforms agree.
  #+sbcl (and (not (sb-ext:float-nan-p value))
              (not (sb-ext:float-infinity-p value)))
  #-sbcl (= value value))

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
