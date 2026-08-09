#.(progn
    (in-package #:observability-kit)
    nil)

(defun %copy-observability-value (value)
  "Copy mutable string values at an observability API boundary."
  (if (stringp value)
      (copy-seq value)
      value))

(defun %designator-string (value)
  (cond
    ((stringp value) (%copy-observability-value value))
    ((symbolp value) (string-downcase (symbol-name value)))
    (t nil)))

(defun proper-list-p (object)
  "Return true when OBJECT is a finite proper list.

The tortoise-and-hare walk also rejects circular lists without relying on
LISTP, LENGTH, or MAPCAR to signal an implementation-dependent type error."
  (loop with slow = object
        with fast = object
        do (cond
             ((null fast) (return t))
             ((not (consp fast)) (return nil))
             (t (setf fast (cdr fast))))
           (cond
             ((null fast) (return t))
             ((not (consp fast)) (return nil))
             (t (setf fast (cdr fast))))
           (setf slow (cdr slow))
           (when (eq slow fast)
             (return nil))))

(defun %ascii-letter-p (character)
  (or (and (char<= #\A character) (char<= character #\Z))
      (and (char<= #\a character) (char<= character #\z))))

(defun %ascii-digit-p (character)
  (and (char<= #\0 character) (char<= character #\9)))

(defun %valid-name-p (name &key metric-p)
  (and (plusp (length name))
       (let ((first (char name 0)))
         (or (%ascii-letter-p first)
             (char= first #\_)
             (and metric-p (char= first #\:))))
       (loop for character across name
             always (or (%ascii-letter-p character)
                        (%ascii-digit-p character)
                        (char= character #\_)
                        (and metric-p (char= character #\:))))))

(defun %sensitive-name-p (name)
  (let ((downcased (string-downcase name)))
    (some (lambda (fragment)
            (not (null (search fragment downcased :test #'char=))))
          *sensitive-name-fragments*)))

(defun %validate-metric-name (name)
  (let ((normalized (%designator-string name)))
    (unless (and normalized (%valid-name-p normalized :metric-p t)
                 (not (uiop:string-prefix-p "__" normalized))
                 (not (%sensitive-name-p normalized)))
      (error 'invalid-metric-name
             :name name
             :message (format nil
                              "Metric name ~S is invalid or reserved for sensitive data."
                              name)))
    normalized))

(defun %validate-label-name (name)
  (let ((normalized (%designator-string name)))
    (unless (and normalized (%valid-name-p normalized)
                 (not (uiop:string-prefix-p "__" normalized)))
      (error 'invalid-label-name
             :name name
             :message (format nil "Invalid label name ~S." name)))
    (when (%sensitive-name-p normalized)
      (error 'invalid-label-name
             :name name
             :message (format nil "Label name ~S is reserved for sensitive data." name)))
    normalized))

(defun %validate-label-value (name value max-length)
  (unless (and (stringp value) (<= (length value) max-length))
    (error 'invalid-label-value
           :name name
           :value value
           :message (format nil "Label ~S must be a string of at most ~D characters."
                             name max-length)))
  (%copy-observability-value value))

(defun %normalize-label-names (names)
  (unless (proper-list-p names)
    (error 'invalid-label-name
           :name names
           :message "Label names must be supplied as a list."))
  (let ((normalized (mapcar #'%validate-label-name names)))
    (when (/= (length normalized)
              (length (remove-duplicates normalized :test #'string=)))
      (error 'invalid-label-name
             :name names
             :message "Label names must be unique."))
    (sort normalized #'string<)))
