#.(progn
    (in-package #:observability-kit)
    nil)

;;;; W3C Trace Context and Baggage

(defun %propagation-error (message &optional header)
  (if header
      (error 'invalid-traceparent :header header :message message)
      (error 'propagation-error :message message)))

(defun %hex-string-p (value length)
  (and (stringp value)
       (= (length value) length)
       (every (lambda (character)
                (not (null (digit-char-p character 16))))
              value)))

(defun %hex-id-p (value length)
  (and (%hex-string-p value length)
       (not (every (lambda (character) (char= character #\0)) value))))

(defun %traceparent-context (context)
  (check-type context instrumentation-context)
  (let ((trace-id (instrumentation-context-trace-id context))
        (span-id (instrumentation-context-span-id context))
        (flags (or (instrumentation-context-trace-flags context) 0)))
    (unless (%hex-id-p trace-id 32)
      (%propagation-error "The context has no valid W3C trace-id."))
    (unless (%hex-id-p span-id 16)
      (%propagation-error "The context has no valid W3C span-id."))
    (unless (and (integerp flags) (<= 0 flags 255))
      (%propagation-error "The context has invalid W3C trace flags."))
    (values (string-downcase trace-id)
            (string-downcase span-id)
            flags)))

(defun format-traceparent (context)
  "Format CONTEXT as a W3C `traceparent` header value.

The current implementation emits version 00 and requires canonical 32
character trace IDs and 16 character span IDs."
  (multiple-value-bind (trace-id span-id flags)
      (%traceparent-context context)
    (string-downcase
     (format nil "00-~A-~A-~2,'0X" trace-id span-id flags))))

(defun parse-traceparent (header)
  "Parse a W3C `traceparent` value into an instrumentation context.

Only version 00 is accepted.  Invalid input signals INVALID-TRACEPARENT;
the extraction boundary is intentionally tolerant and returns NIL instead."
  (unless (stringp header)
    (%propagation-error "TRACEPARENT must be a string." header))
  (let ((value (string-trim '(#\Space #\Tab) header)))
    (unless (and (= (length value) 55)
                 (string= (subseq value 0 2) "00")
                 (char= (char value 2) #\-)
                 (char= (char value 35) #\-)
                 (char= (char value 52) #\-)
                 (%hex-id-p (subseq value 3 35) 32)
                 (%hex-id-p (subseq value 36 52) 16)
                 (%hex-string-p (subseq value 53 55) 2)
                 (not (string= (subseq value 53 55) "ff")))
      (%propagation-error "The W3C traceparent header is invalid." header))
    (make-instrumentation-context
     :trace-id (string-downcase (subseq value 3 35))
     :span-id (string-downcase (subseq value 36 52))
     :trace-flags (parse-integer (subseq value 53 55) :radix 16))))

(defun %baggage-key-p (key)
  (and (stringp key)
       (plusp (length key))
       (<= (length key) 256)
       (every (lambda (character)
                (let ((code (char-code character)))
                  (or (and (<= (char-code #\a) code)
                           (<= code (char-code #\z)))
                      (and (<= (char-code #\0) code)
                           (<= code (char-code #\9)))
                      (member character '(#\_ #\- #\* #\/)))))
              key)))

(defun %utf8-octets (string)
  (loop for character across string
        for code = (char-code character)
        append (cond
                 ((<= code #x7f) (list code))
                 ((<= code #x7ff)
                  (list (+ #xc0 (ash code -6))
                        (+ #x80 (logand code #x3f))))
                 ((<= code #xffff)
                  (list (+ #xe0 (ash code -12))
                        (+ #x80 (logand (ash code -6) #x3f))
                        (+ #x80 (logand code #x3f))))
                 (t
                  (list (+ #xf0 (ash code -18))
                        (+ #x80 (logand (ash code -12) #x3f))
                        (+ #x80 (logand (ash code -6) #x3f))
                        (+ #x80 (logand code #x3f)))))))

(defun %baggage-unreserved-p (byte)
  (or (and (<= (char-code #\A) byte) (<= byte (char-code #\Z)))
      (and (<= (char-code #\a) byte) (<= byte (char-code #\z)))
      (and (<= (char-code #\0) byte) (<= byte (char-code #\9)))
      (member byte (mapcar #'char-code '(#\- #\_ #\. #\~)))))

(defun %percent-encode (value)
  (with-output-to-string (stream)
    (dolist (byte (%utf8-octets value))
      (if (%baggage-unreserved-p byte)
          (write-char (code-char byte) stream)
          (progn
            (write-char #\% stream)
            (write-char (digit-char (ash byte -4) 16) stream)
            (write-char (digit-char (logand byte #xf) 16) stream))))))

(defun %utf8-continuation-p (byte)
  (<= #x80 byte #xbf))

(defun %percent-decode (value)
  (let ((octets nil))
    (loop for index from 0 below (length value)
          for character = (char value index)
          do (cond
               ((char= character #\%)
                (when (> (+ index 2) (1- (length value)))
                  (%propagation-error "A baggage value contains an incomplete percent escape."))
                (let ((high (digit-char-p (char value (1+ index)) 16))
                      (low (digit-char-p (char value (+ index 2)) 16)))
                  (unless (and high low)
                    (%propagation-error "A baggage value contains an invalid percent escape."))
                  (push (+ (ash high 4) low) octets)
                  (incf index 2)))
               ((<= (char-code character) #x7f)
                (push (char-code character) octets))
               (t
                (%propagation-error "Baggage values must use ASCII or percent-encoded UTF-8."))))
    (let ((bytes (coerce (nreverse octets) 'vector)))
      (with-output-to-string (stream)
        (loop with index = 0
              while (< index (length bytes))
              for first = (aref bytes index)
              do (cond
                   ((<= first #x7f)
                    (write-char (code-char first) stream)
                    (incf index))
                   ((<= #xc2 first #xdf)
                    (when (or (>= (1+ index) (length bytes))
                              (not (%utf8-continuation-p
                                    (aref bytes (1+ index)))))
                      (%propagation-error "A baggage value contains invalid UTF-8."))
                    (write-char
                     (code-char (+ (ash (logand first #x1f) 6)
                                   (logand (aref bytes (1+ index)) #x3f)))
                     stream)
                    (incf index 2))
                   ((<= #xe0 first #xef)
                    (when (or (>= (+ index 2) (length bytes))
                              (not (%utf8-continuation-p
                                    (aref bytes (1+ index))))
                              (not (%utf8-continuation-p
                                    (aref bytes (+ index 2)))))
                      (%propagation-error "A baggage value contains invalid UTF-8."))
                    (write-char
                     (code-char (+ (ash (logand first #x0f) 12)
                                   (ash (logand (aref bytes (1+ index)) #x3f) 6)
                                   (logand (aref bytes (+ index 2)) #x3f)))
                     stream)
                    (incf index 3))
                   ((<= #xf0 first #xf4)
                    (when (or (>= (+ index 3) (length bytes))
                              (not (%utf8-continuation-p
                                    (aref bytes (1+ index))))
                              (not (%utf8-continuation-p
                                    (aref bytes (+ index 2))))
                              (not (%utf8-continuation-p
                                    (aref bytes (+ index 3)))))
                      (%propagation-error "A baggage value contains invalid UTF-8."))
                    (write-char
                     (code-char (+ (ash (logand first #x07) 18)
                                   (ash (logand (aref bytes (1+ index)) #x3f) 12)
                                   (ash (logand (aref bytes (+ index 2)) #x3f) 6)
                                   (logand (aref bytes (+ index 3)) #x3f)))
                     stream)
                    (incf index 4))
                   (t
                    (%propagation-error "A baggage value contains invalid UTF-8."))))))))

(defun %split-propagation-string (string delimiter)
  (let ((parts nil)
        (start 0))
    (loop for end = (position delimiter string :start start)
          do (if end
                 (progn
                   (push (subseq string start end) parts)
                   (setf start (1+ end)))
                 (return (nreverse (cons (subseq string start) parts)))))))

(defun format-baggage (context)
  "Format CONTEXT's baggage as a W3C `baggage` header value, or NIL."
  (check-type context instrumentation-context)
  (let ((members nil))
    (dolist (pair (instrumentation-context-baggage context))
      (let ((key (string-downcase (car pair)))
            (value (if (stringp (cdr pair))
                       (cdr pair)
                       (if (null (cdr pair)) "" (princ-to-string (cdr pair))))))
        (unless (%baggage-key-p key)
          (%propagation-error (format nil "Baggage key ~S is not valid." key)))
        (push (format nil "~A=~A" key (%percent-encode value)) members)))
    (when members
      (format nil "~{~A~^, ~}" (nreverse members)))))

(defun parse-baggage (header)
  "Parse a W3C `baggage` header into a normalized alist.

Metadata after a member's semicolon is ignored.  Duplicate keys use the
last member, which makes merging multiple header values deterministic."
  (when header
    (unless (stringp header)
      (%propagation-error "BAGGAGE must be a string."))
    (let ((result nil))
      (dolist (raw-member (%split-propagation-string header #\,))
        (let* ((member (string-trim '(#\Space #\Tab) raw-member))
               (metadata (position #\; member))
               (value-part (if metadata (subseq member 0 metadata) member))
               (equals (position #\= value-part)))
          (unless (or (zerop (length member)) equals)
            (%propagation-error "A baggage member must contain a key and value."))
          (unless (zerop (length member))
            (let ((key (string-downcase
                        (string-trim '(#\Space #\Tab)
                                     (subseq value-part 0 equals))))
                  (value (string-trim '(#\Space #\Tab)
                                      (subseq value-part (1+ equals)))))
              (unless (%baggage-key-p key)
                (%propagation-error (format nil "Baggage key ~S is not valid." key)))
              (setf result
                    (acons key
                           (%percent-decode value)
                           (remove key result :key #'car :test #'string=)))))))
      (%normalize-attributes result))))

(defun %header-list (headers)
  (unless (or (null headers) (proper-list-p headers))
    (%propagation-error "Headers must be a proper alist."))
  (mapcar (lambda (pair)
            (unless (consp pair)
              (%propagation-error "Each header must be a key/value pair."))
            (let ((name (%designator-string (car pair)))
                  (value (if (and (consp (cdr pair)) (null (cddr pair)))
                             (cadr pair)
                             (cdr pair))))
              (unless (and name (plusp (length name)) (stringp value))
                (%propagation-error "Header names and values must be non-empty names and strings."))
              (cons name (%copy-observability-value value))))
          headers))

(defun %propagation-header (headers name)
  (cdr (find name headers :key #'car :test #'string-equal)))

(defun %without-propagation-headers (headers)
  (remove-if (lambda (pair)
               (member (car pair) '("traceparent" "tracestate" "baggage")
                       :test #'string-equal))
             headers))

(defun inject-trace-context (context headers)
  "Return HEADERS with W3C propagation fields for CONTEXT injected.

HEADERS is a string-keyed alist.  Existing traceparent, tracestate, and
baggage entries are replaced; unrelated entries are copied unchanged."
  (let ((base (%without-propagation-headers (%header-list headers))))
    (if (null context)
        base
        (let ((propagated (list (cons "traceparent" (format-traceparent context))))
              (tracestate (instrumentation-context-tracestate context))
              (baggage (format-baggage context)))
          (when tracestate
            (push (cons "tracestate" tracestate) propagated))
          (when baggage
            (push (cons "baggage" baggage) propagated))
          (append (nreverse propagated) base)))))

(defun extract-trace-context (headers)
  "Extract a W3C context from HEADERS, or return NIL for absent/invalid input.

Malformed traceparent values are ignored at this untrusted boundary.  A
malformed optional baggage or tracestate value is ignored while preserving a
valid traceparent context."
  (let* ((normalized (%header-list headers))
         (traceparent (%propagation-header normalized "traceparent")))
    (when traceparent
      (handler-case
          (let* ((context (parse-traceparent traceparent))
                 (tracestate (let ((value (%propagation-header normalized "tracestate")))
                               (when value
                                 (handler-case
                                     (%validate-tracestate value)
                                   (observability-error () nil)))))
                 (baggage (let ((value (%propagation-header normalized "baggage")))
                            (when value
                              (handler-case
                                  (parse-baggage value)
                                (propagation-error () nil))))))
            (make-instrumentation-context
             :trace-id (instrumentation-context-trace-id context)
             :span-id (instrumentation-context-span-id context)
             :trace-flags (instrumentation-context-trace-flags context)
             :baggage baggage
             :tracestate tracestate
             :remote-p t))
        (propagation-error () nil)))))
