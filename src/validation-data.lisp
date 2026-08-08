(defparameter *sensitive-name-fragments*
  '("authorization" "access-token" "refresh-token" "token" "secret"
    "password" "passwd" "cookie" "api-key" "apikey" "credential"
    "private-key" "ssn" "email" "phone" "address")
  "Name fragments that must never be exported as observability metadata.")
