#.(progn
    (in-package #:observability-kit/prometheus)
    nil)

(defun %sorted-labels (labels)
  (sort (copy-list labels)
        (lambda (left right)
          (or (string< (car left) (car right))
              (and (string= (car left) (car right))
                   (string< (cdr left) (cdr right)))))))

(defun %write-escaped-string (string stream &key escape-help-p)
  (loop for character across string
        do (cond
             ((char= character #\\)
              (write-char #\\ stream)
              (write-char #\\ stream))
             ((and (not escape-help-p) (char= character #\"))
              (write-char #\\ stream)
              (write-char #\" stream))
             ((char= character #\Newline)
              (write-char #\\ stream)
              (write-char #\n stream))
             ((char= character #\Return)
              (write-char #\\ stream)
              (write-char #\r stream))
             (t
              (write-char character stream))))
  stream)

(defun %escaped-string (string &key escape-help-p)
  (with-output-to-string (stream)
    (%write-escaped-string string stream :escape-help-p escape-help-p)))

(defun %factor-count (number factor)
  (let ((count 0))
    (loop while (zerop (mod number factor))
          do (incf count)
             (setf number (/ number factor)))
    (values count number)))

(defun %terminating-rational-string (value)
  (let* ((negative (minusp value))
         (numerator (abs (numerator value)))
         (denominator (denominator value)))
    (multiple-value-bind (twos remaining-after-twos)
        (%factor-count denominator 2)
      (multiple-value-bind (fives remaining)
          (%factor-count remaining-after-twos 5)
        (when (= remaining 1)
          (let* ((scale (max twos fives))
                 (scaled (* numerator
                            (expt 2 (- scale twos))
                            (expt 5 (- scale fives))))
                 (digits (princ-to-string scaled))
                 (sign (if negative "-" "")))
            (let ((split (- (length digits) scale)))
              (if (plusp split)
                  (concatenate 'string sign
                               (subseq digits 0 split)
                               "."
                               (subseq digits split))
                  (concatenate 'string sign
                               "0."
                               (make-string (- split)
                                            :initial-element #\0)
                               digits)))))))))

(defun %normalize-float-number (string)
  (let ((trimmed (string-trim '(#\Space #\Tab #\Newline #\Return)
                              string)))
    (with-output-to-string (stream)
      (loop for character across trimmed
            do (write-char (if (member character '(#\d #\D))
                               #\e
                               character)
                            stream)))))

(defun %number-string (value)
  (cond
    ((eq value +infinity+) "+Inf")
    ((integerp value) (princ-to-string value))
    ((rationalp value)
     (or (%terminating-rational-string value)
         ;; Prometheus has no rational literal.  The conversion is confined
         ;; to this text boundary; the core snapshot remains exact.
         (%normalize-float-number
          (format nil "~,17G" (coerce value 'double-float)))))
    ((floatp value)
     (%normalize-float-number (format nil "~,17G" value)))
    (t
     (%export-error "Metric value ~S is not a supported real number." value))))
