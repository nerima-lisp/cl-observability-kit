#.(progn
    (in-package #:observability-kit)
    nil)

(defparameter *sensitive-name-fragments*
  '("authorization" "access-token" "refresh-token" "token" "secret"
    "password" "passwd" "cookie" "api-key" "apikey" "credential"
    "private-key" "ssn" "email" "phone" "address")
  "Name fragments that must never be exported as observability metadata.")

(defparameter *log-severity-levels*
  '((:trace "TRACE" . 1)
    (:debug "DEBUG" . 5)
    (:info "INFO" . 9)
    (:warn "WARN" . 13)
    (:error "ERROR" . 17)
    (:fatal "FATAL" . 21))
  "Standard structured-log severity names and their numeric levels.")
