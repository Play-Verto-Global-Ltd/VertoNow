# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn,
  # A respondent's self-invented code. Only ever stored as an HMAC (see
  # Survey#respondent_code_digest), so it must not survive in a log either —
  # otherwise the logs would hold the one copy of the plaintext the database
  # deliberately doesn't.
  :respondent_code,
  # A respondent's answers and contact-form fields. PlayerController reads the
  # JSON body itself, but Rails also parses an application/json body into
  # params for the request log line — so every free-text answer, every "Other"
  # write-in and every contact field used to be printed, verbatim, into the
  # request log on each /progress and /submit. The moderator holds free text
  # out of the database until it is screened; a log copy would undo that.
  :answers, :contact,
  # How long a respondent spent on each question, and the response-integrity
  # signals that ride the same saves. Behavioural data about one person: the
  # request log line already carries their IP address, and a log is not where
  # the Privacy Notice says these are kept ("stored with your response").
  :dwell, :integrity
]
