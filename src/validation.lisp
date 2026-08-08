(in-package #:observability-kit)

(defparameter *sensitive-name-fragments*
  '("authorization" "access-token" "refresh-token" "token" "secret"
    "password" "passwd" "cookie" "api-key" "apikey" "credential"
    "private-key" "ssn" "email" "phone" "address"))

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

(defun %proper-list-p (object)
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
           (setf slow (if (consp slow) (cdr slow) slow))
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
                 (not (uiop:string-prefix-p "__" normalized)))
      (error 'invalid-metric-name
             :name name
             :message (format nil "Invalid metric name ~S." name)))
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
  (unless (%proper-list-p names)
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

(defun %pair-value (pair)
  (if (and (consp (cdr pair)) (null (cddr pair)))
      (cadr pair)
      (cdr pair)))

(defun %label-input-alist (labels)
  (cond
    ((null labels) nil)
    ((and (%proper-list-p labels) (every #'consp labels))
     (mapcar (lambda (pair) (cons (car pair) (%pair-value pair))) labels))
    ((%proper-list-p labels)
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

(defun %normalize-attributes (attributes &key (max-value-length 1024))
  (let ((provided (%label-input-alist attributes))
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

(defun %validate-real (value what)
  (unless (realp value)
    (error 'observability-error
           :message (format nil "~A must be a real number, got ~S." what value)))
  value)

(defun %validate-non-negative-real (value what)
  (%validate-real value what)
  (when (minusp value)
    (error 'observability-error
           :message (format nil "~A must not be negative, got ~S." what value)))
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
