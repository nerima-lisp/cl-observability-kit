#.(progn
    (in-package #:observability-kit)
    nil)

(defun %pair-value (pair)
  (if (and (consp (cdr pair)) (null (cddr pair)))
      (cadr pair)
      (cdr pair)))

(defun %label-input-alist (labels)
  (cond
    ((null labels) nil)
    ((and (proper-list-p labels) (every #'consp labels))
     (mapcar (lambda (pair) (cons (car pair) (%pair-value pair))) labels))
    ((proper-list-p labels)
     (unless (evenp (length labels))
       (error 'invalid-label-set
              :labels labels
              :reason :odd-plist
              :message "Labels must be an alist or an even property list."))
     (loop for (name value) on labels by #'cddr
           collect (cons name value)))
    (t
     (error 'invalid-label-set
            :labels labels
            :reason :not-a-list
            :message "Labels must be an alist or property list."))))

(defun %normalize-labels (defined-names labels max-value-length)
  (let ((provided (%label-input-alist labels))
        (seen (make-hash-table :test #'equal))
        (normalized nil))
    (dolist (pair provided)
      (let ((name (%validate-label-name (car pair))))
        (when (gethash name seen)
          (error 'invalid-label-set
                 :labels labels
                 :reason :duplicate
                 :message (format nil "Label ~S was supplied more than once." name)))
        (setf (gethash name seen) t)
        (unless (member name defined-names :test #'string=)
          (error 'invalid-label-set
                 :labels labels
                 :reason :unknown
                 :message (format nil "Label ~S is not part of the metric definition." name)))
        (push (cons name (%validate-label-value name (cdr pair) max-value-length))
              normalized)))
    (dolist (name defined-names)
      (unless (gethash name seen)
        (error 'invalid-label-set
               :labels labels
               :reason :missing
               :message (format nil "Label ~S is required." name))))
    (sort normalized #'string< :key #'car)))

(defun %validate-attribute-name (name)
  (let ((normalized (%designator-string name)))
    (unless (and normalized (plusp (length normalized)))
      (error 'unsafe-attribute-name
             :name name
             :message "Attribute names must be non-empty strings or symbols."))
    (when (%sensitive-name-p normalized)
      (error 'unsafe-attribute-name
             :name name
             :message (format nil
                              "Attribute name ~S is reserved for sensitive data."
                              name)))
    normalized))

(defun %normalize-attributes (attributes &key max-value-length)
  (let ((provided (%label-input-alist attributes))
        (max-value-length (or max-value-length 1024))
        (seen (make-hash-table :test #'equal))
        (normalized nil))
    (dolist (pair provided)
      (let ((name (%validate-attribute-name (car pair)))
            (value (cdr pair)))
        (when (gethash name seen)
          (error 'unsafe-attribute-name
                 :name name
                 :message (format nil "Attribute ~S was supplied more than once." name)))
        (setf (gethash name seen) t)
        (unless (or (null value) (stringp value) (numberp value)
                    (keywordp value) (symbolp value))
          (error 'unsafe-attribute-name
                 :name name
                 :message (format nil "Attribute ~S has an unsupported value type." name)))
        (when (and (stringp value) (> (length value) max-value-length))
          (error 'unsafe-attribute-name
                 :name name
                 :message (format nil "Attribute ~S is too long." name)))
        (push (cons name (%copy-observability-value value)) normalized)))
    (sort normalized #'string< :key #'car)))
