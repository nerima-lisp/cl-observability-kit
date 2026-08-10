#.(progn
    (in-package #:observability-kit)
    nil)

;;;; Interoperability propagators

;;; The W3C propagator is the default.  These adapters cover the established
;;; wire formats that are commonly found at service boundaries while keeping
;;; the core package independent from a transport or HTTP library.

(defun %adapter-trace-id (value)
  (let ((value (and (stringp value)
                    (string-downcase
                     (string-trim '(#\Space #\Tab) value)))))
    (cond
      ((%hex-id-p value 32) value)
      ((%hex-id-p value 16)
       (concatenate 'string
                    "0000000000000000"
                    value))
      (t nil))))

(defun %adapter-context (trace-id span-id flags)
  (when (and trace-id
             (%hex-id-p span-id 16)
             (or (null flags)
                 (and (integerp flags)
                      (<= 0 flags 255))))
    (make-instrumentation-context
     :trace-id trace-id
     :span-id (string-downcase span-id)
     :trace-flags flags)))

(defun %adapter-context-fields (context)
  (check-type context instrumentation-context)
  (let ((trace-id (instrumentation-context-trace-id context))
        (span-id (instrumentation-context-span-id context))
        (flags (instrumentation-context-trace-flags context)))
    (unless (%hex-id-p trace-id 32)
      (error 'propagation-error
             :message "The context has no valid 128-bit trace-id."))
    (unless (%hex-id-p span-id 16)
      (error 'propagation-error
             :message "The context has no valid span-id."))
    (unless (or (null flags)
                (and (integerp flags) (<= 0 flags 255)))
      (error 'propagation-error
             :message "The context has invalid trace flags."))
    (values (string-downcase trace-id)
            (string-downcase span-id)
            flags)))

(defun %replace-adapter-headers (headers names injected)
  (append injected
          (remove-if (lambda (pair)
                       (member (car pair) names :test #'string-equal))
                     (%header-list headers))))

;;;; B3 single and multi

(defun %b3-sampled-flags (value)
  (when (stringp value)
    (cond
      ((member (string-downcase value) '("1" "d") :test #'string=) 1)
      ((string= (string-downcase value) "0") 0)
      (t nil))))

(defun %b3-single-context (value)
  (when (stringp value)
    (let* ((trimmed (string-downcase
                     (string-trim '(#\Space #\Tab) value)))
           (parts (%split-propagation-string trimmed #\-)))
      (when (or (= (length parts) 2)
                (= (length parts) 3)
                (= (length parts) 4))
        (destructuring-bind (trace-id span-id &optional sampled parent-span-id)
            parts
          (let ((normalized-trace-id (%adapter-trace-id trace-id)))
            (when (and normalized-trace-id
                       (%hex-id-p span-id 16)
                       (or (null parent-span-id)
                           (%hex-string-p parent-span-id 16))
                       (or (null sampled)
                           (integerp (%b3-sampled-flags sampled))))
              (%adapter-context normalized-trace-id
                                span-id
                                (%b3-sampled-flags sampled)))))))))

(defun %b3-multi-context (headers)
  (let* ((trace-id (%adapter-trace-id
                    (%propagation-header headers "x-b3-traceid")))
         (span-id (%propagation-header headers "x-b3-spanid"))
         (sampled (%propagation-header headers "x-b3-sampled"))
         (flags (%propagation-header headers "x-b3-flags"))
         (fallback-sampling-flags
           (and (stringp flags)
                (string= (string-downcase flags) "1")
                1))
         (sampling-flags (or (%b3-sampled-flags sampled)
                             fallback-sampling-flags))
         (valid-sampling-p
           (or (null sampled)
               (integerp (%b3-sampled-flags sampled))
               (integerp fallback-sampling-flags))))
    (when (and trace-id
               (%hex-id-p span-id 16)
               valid-sampling-p)
      (%adapter-context trace-id span-id sampling-flags))))

(defun %b3-extract (headers)
  (let ((normalized (%header-list headers)))
    ;; B3 extraction accepts both forms.  A valid single-header value wins
    ;; over multi-header values when a carrier contains both.
    (or (%b3-single-context (%propagation-header normalized "b3"))
        (%b3-multi-context normalized))))

(defun %inject-b3-single (context headers)
  (let ((injected nil))
    (when context
      (multiple-value-bind (trace-id span-id flags)
          (%adapter-context-fields context)
        (setf injected
              (list (cons "b3"
                          (if (integerp flags)
                              (format nil "~A-~A-~A"
                                      trace-id
                                      span-id
                                      (if (logbitp 0 flags) "1" "0"))
                              (format nil "~A-~A" trace-id span-id))))))
    (%replace-adapter-headers headers '("b3") injected))))

(defun %inject-b3-multi (context headers)
  (let ((injected nil))
    (when context
      (multiple-value-bind (trace-id span-id flags)
          (%adapter-context-fields context)
        (setf injected
              (append (list (cons "x-b3-traceid" trace-id)
                            (cons "x-b3-spanid" span-id))
                      (when (integerp flags)
                        (list (cons "x-b3-sampled"
                                    (if (logbitp 0 flags) "1" "0"))))))))
    (%replace-adapter-headers
     headers
     '("x-b3-traceid" "x-b3-spanid" "x-b3-sampled" "x-b3-flags")
     injected)))

(defun make-b3-propagator ()
  "Create a B3 propagator that injects the single-header form.

Extraction accepts both B3 single and B3 multi carriers, with the single
header taking precedence when it is valid."
  (%make-propagator #'%inject-b3-single #'%b3-extract))

(defun make-b3-multi-propagator ()
  "Create a B3 propagator that injects the multi-header form.

Extraction accepts both B3 single and B3 multi carriers."
  (%make-propagator #'%inject-b3-multi #'%b3-extract))

;;;; Jaeger and AWS X-Ray compatibility

(defun %jaeger-context (value)
  (when (stringp value)
    (let ((parts (%split-propagation-string
                  (string-downcase
                   (string-trim '(#\Space #\Tab) value))
                  #\:)))
      (when (= (length parts) 4)
        (destructuring-bind (trace-id span-id parent-span-id flags) parts
          (let ((normalized-trace-id (%adapter-trace-id trace-id)))
            (when (and normalized-trace-id
                       (%hex-id-p span-id 16)
                       (%hex-string-p parent-span-id 16)
                       (%hex-string-p flags 2))
              (let ((parsed-flags (parse-integer flags :radix 16)))
                ;; Jaeger uses bit 1 for sampled and bit 2 for debug.  The
                ;; instrumentation context exposes the W3C sampled bit only.
                (%adapter-context
                 normalized-trace-id
                 span-id
                 (if (or (logbitp 0 parsed-flags)
                         (logbitp 1 parsed-flags))
                     1
                     0))))))))))

(defun %inject-jaeger (context headers)
  (let ((injected nil))
    (when context
      (multiple-value-bind (trace-id span-id flags)
          (%adapter-context-fields context)
        (when (integerp flags)
          (setf injected
                (list
                 (cons "uber-trace-id"
                       (format nil "~A:~A:0000000000000000:~2,'0X"
                               trace-id
                               span-id
                               (if (logbitp 0 flags) 1 0))))))))
    (%replace-adapter-headers headers '("uber-trace-id") injected)))

(defun make-jaeger-propagator ()
  "Create the deprecated Jaeger `uber-trace-id` compatibility propagator."
  (%make-propagator #'%inject-jaeger
                    (lambda (headers)
                      (%jaeger-context
                       (%propagation-header (%header-list headers)
                                            "uber-trace-id")))))

(defun %xray-fields (value)
  (let ((fields nil))
    (when (stringp value)
      (dolist (part (%split-propagation-string value #\;))
        (let ((separator (position #\= part)))
          (when separator
            (let ((name (string-downcase
                         (string-trim '(#\Space #\Tab)
                                      (subseq part 0 separator))))
                  (field-value (string-trim
                                '(#\Space #\Tab)
                                (subseq part (1+ separator)))))
              (when (plusp (length name))
                (setf (getf fields (intern (string-upcase name) :keyword))
                      field-value)))))))
    fields))

(defun %xray-root-trace-id (root)
  (when (stringp root)
    (let ((parts (%split-propagation-string
                  (string-downcase
                   (string-trim '(#\Space #\Tab) root))
                  #\-)))
      (when (and (= (length parts) 3)
                 (string= (first parts) "1")
                 (%hex-string-p (second parts) 8)
                 (%hex-string-p (third parts) 24))
        (%adapter-trace-id (concatenate 'string (second parts) (third parts)))))))

(defun %xray-context (value)
  (let* ((fields (%xray-fields value))
         (trace-id (%xray-root-trace-id (getf fields :ROOT)))
         (span-id (getf fields :PARENT))
         (sampled (getf fields :SAMPLED)))
    (when (and trace-id
               (%hex-id-p span-id 16)
               (or (null sampled)
                   (and (stringp sampled)
                        (member (string-downcase sampled) '("0" "1" "?")
                                :test #'string=))))
      (%adapter-context trace-id
                        span-id
                        (cond
                          ((and (stringp sampled)
                                (string= (string-downcase sampled) "1"))
                           1)
                          ((and (stringp sampled)
                                (string= (string-downcase sampled) "0"))
                           0)
                          (t nil))))))

(defun %inject-xray (context headers)
  (let ((injected nil))
    (when context
      (multiple-value-bind (trace-id span-id flags)
          (%adapter-context-fields context)
        (setf injected
              (list
               (cons "x-amzn-trace-id"
                     (if (integerp flags)
                         (format nil "Root=1-~A-~A;Parent=~A;Sampled=~A"
                                 (subseq trace-id 0 8)
                                 (subseq trace-id 8)
                                 span-id
                                 (if (logbitp 0 flags) "1" "0"))
                         (format nil "Root=1-~A-~A;Parent=~A"
                                 (subseq trace-id 0 8)
                                 (subseq trace-id 8)
                                 span-id))))))
    (%replace-adapter-headers headers '("x-amzn-trace-id") injected))))

(defun make-xray-propagator ()
  "Create an AWS X-Ray `x-amzn-trace-id` compatibility propagator."
  (%make-propagator #'%inject-xray
                    (lambda (headers)
                      (%xray-context
                       (%propagation-header (%header-list headers)
                                            "x-amzn-trace-id")))))
