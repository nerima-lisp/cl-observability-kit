#.(progn
    (in-package #:observability-kit/prometheus)
    nil)

(defun %label-less-p (left right)
  (or (string< (car left) (car right))
      (and (string= (car left) (car right))
           (string< (cdr left) (cdr right)))))

(defun %sort-labels (labels)
  (sort labels #'%label-less-p))

(defun %labels-sorted-p (labels)
  (loop for tail on labels
        for left = (first tail)
        for right = (second tail)
        while right
        always (not (%label-less-p right left))))

(defun %sorted-labels (labels)
  (if (%labels-sorted-p labels)
      labels
      (%sort-labels (copy-list labels))))

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

(defun %float-whitespace-p (character)
  (member character '(#\Space #\Tab #\Newline #\Return) :test #'char=))

(defun %normalize-float-number (string)
  (let ((start 0)
        (end (length string)))
    (loop while (and (< start end)
                     (%float-whitespace-p (char string start)))
          do (incf start))
    (loop while (and (< start end)
                     (%float-whitespace-p (char string (1- end))))
          do (decf end))
    (let ((normalized (make-string (- end start))))
      (loop for source-index from start below end
            for target-index from 0
            for character = (char string source-index)
            do (setf (char normalized target-index)
                     (if (or (char= character #\d)
                             (char= character #\D))
                         #\e
                         character)))
      normalized)))

(defun %format-float-number (value)
  (%normalize-float-number (format nil "~,17G" value)))

(defvar *default-histogram-boundary-strings* nil)

(defun %number-string (value)
  (cond
    ((eq value +infinity+) "+Inf")
    ((integerp value) (princ-to-string value))
    ((rationalp value)
     (or (%terminating-rational-string value)
         ;; Prometheus has no rational literal.  The conversion is confined
         ;; to this text boundary; the core snapshot remains exact.
         (%format-float-number (coerce value 'double-float))))
    ((floatp value)
     (or (and *default-histogram-boundary-strings*
              (gethash value *default-histogram-boundary-strings*))
         (%format-float-number value)))
    (t
     (%export-error "Metric value ~S is not a supported real number." value))))

(setf *default-histogram-boundary-strings*
      (let ((cache (make-hash-table :test #'eql)))
        (dolist (boundary observability-kit::*default-histogram-buckets* cache)
          (setf (gethash boundary cache)
                (%format-float-number boundary)))))

(defun %write-number (value stream)
  (cond
    ((eq value +infinity+)
     (write-string "+Inf" stream))
    ((integerp value)
     (princ value stream))
    (t
     (write-string (%number-string value) stream))))
