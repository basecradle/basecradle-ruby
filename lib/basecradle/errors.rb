# frozen_string_literal: true

module BaseCradle
  # Root of every exception this SDK raises. Rescue +BaseCradle::Error+ to catch
  # everything.
  #
  # For errors that came from an API response, the problem document is exposed:
  # +status+, +code+, +title+, +detail+, +instance+, and +problem+ (the full parsed
  # document). For errors that never reached the API (missing token, connection
  # failure), those are +nil+.
  class Error < StandardError
    attr_reader :status, :code, :title, :detail, :instance, :problem

    def initialize(message = nil, status: nil, code: nil, title: nil, detail: nil, instance: nil,
                   problem: nil)
      super(message)
      @status = status
      @code = code
      @title = title
      @detail = detail
      @instance = instance
      @problem = problem
    end
  end

  # No token was provided and BASECRADLE_TOKEN is not set.
  class MissingTokenError < Error; end

  # The request never got an API response (DNS failure, refused connection, timeout).
  # The underlying exception is preserved as +cause+.
  class APIConnectionError < Error; end

  # --- 401: authentication ---------------------------------------------------------------

  # Authentication failed (HTTP 401).
  class AuthenticationError < Error; end

  # +unauthorized+ — the Bearer token is missing or invalid.
  class UnauthorizedError < AuthenticationError; end

  # +invalid_credentials+ — sign-in failed: the email address or password is wrong.
  class InvalidCredentialsError < AuthenticationError; end

  # +invalid_signature+ — webhook ingest: the signature is missing or does not match.
  class InvalidSignatureError < AuthenticationError; end

  # --- 403: account / permissions --------------------------------------------------------

  # +account_suspended+ — credentials were valid but the account is suspended.
  class AccountSuspendedError < Error; end

  # Authenticated but not allowed (HTTP 403).
  class ForbiddenError < Error; end

  # +not_a_viewer+ — you are not a viewer (owner or participant) of the timeline.
  class NotAViewerError < ForbiddenError; end

  # +not_timeline_owner+ — the action requires being the timeline's owner.
  class NotTimelineOwnerError < ForbiddenError; end

  # +timeline_locked+ — the timeline is locked and not accepting new content.
  class TimelineLockedError < ForbiddenError; end

  # --- 404 --------------------------------------------------------------------------------

  # +not_found+ — no record exists for the given UUID (or it is hidden from you).
  class NotFoundError < Error; end

  # --- 422: validation --------------------------------------------------------------------

  # A submitted record failed validation (HTTP 422). +errors+ maps attribute name to a
  # list of messages (empty when the API sent none).
  class ValidationError < Error
    attr_reader :errors

    def initialize(message = nil, errors: nil, **kwargs)
      super(message, **kwargs)
      @errors = errors || {}
    end
  end

  # +current_password_incorrect+ — password change: the current password is incorrect.
  class CurrentPasswordIncorrectError < ValidationError; end

  # +password_confirmation_mismatch+ — the new password and its confirmation differ.
  class PasswordConfirmationMismatchError < ValidationError; end

  # --- 429 --------------------------------------------------------------------------------

  # +rate_limited+ — too many requests in the window. +retry_after+ is the number of
  # seconds to wait (from the +Retry-After+ header), or +nil+ if the header was absent.
  class RateLimitedError < Error
    attr_reader :retry_after

    def initialize(message = nil, retry_after: nil, **kwargs)
      super(message, **kwargs)
      @retry_after = retry_after
    end
  end

  # --- 400: malformed requests ------------------------------------------------------------

  # The request was malformed (HTTP 400).
  class InvalidRequestError < Error; end

  # +invalid_cursor+ — the +before+ pagination cursor is not a valid record UUID.
  class InvalidCursorError < InvalidRequestError; end

  # +invalid_filter+ — a list filter value is malformed.
  class InvalidFilterError < InvalidRequestError; end

  # --- webhook ingest ----------------------------------------------------------------------

  # +endpoint_disabled+ — webhook ingest: the endpoint is not accepting deliveries.
  class EndpointDisabledError < Error; end

  # +payload_too_large+ — webhook ingest: the request body exceeds the maximum size.
  class PayloadTooLargeError < Error; end

  # --- the code => class registry ----------------------------------------------------------

  # Every API error is an RFC 9457 application/problem+json document with a stable,
  # machine-readable +code+. Each code maps to its own exception class.
  CODE_TO_ERROR = {
    "unauthorized" => UnauthorizedError,
    "invalid_credentials" => InvalidCredentialsError,
    "invalid_signature" => InvalidSignatureError,
    "account_suspended" => AccountSuspendedError,
    "not_a_viewer" => NotAViewerError,
    "not_timeline_owner" => NotTimelineOwnerError,
    "timeline_locked" => TimelineLockedError,
    "not_found" => NotFoundError,
    "validation_failed" => ValidationError,
    "current_password_incorrect" => CurrentPasswordIncorrectError,
    "password_confirmation_mismatch" => PasswordConfirmationMismatchError,
    "rate_limited" => RateLimitedError,
    "invalid_cursor" => InvalidCursorError,
    "invalid_filter" => InvalidFilterError,
    "endpoint_disabled" => EndpointDisabledError,
    "payload_too_large" => PayloadTooLargeError
  }.freeze

  class Error
    # Build the right exception for a non-2xx API response.
    #
    # +problem+ is the parsed problem+json document (a Hash) or +nil+. Unknown codes
    # fall back to +BaseCradle::Error+ (the API is additive-only; a new error code must
    # never crash the SDK), and non-problem+json bodies produce a bare +Error+ carrying
    # just the HTTP status.
    def self.from_response(status:, problem:, retry_after: nil)
      unless problem.is_a?(Hash) && problem.key?("code")
        return new("API request failed with HTTP #{status}", status: status,
                                                              problem: problem.is_a?(Hash) ? problem : nil)
      end

      code = problem["code"]
      detail = problem["detail"]
      title = problem["title"]
      message = detail || title || "API request failed with HTTP #{status}"
      common = {
        status: problem.fetch("status", status),
        code: code,
        title: title,
        detail: detail,
        instance: problem["instance"],
        problem: problem
      }

      error_class = CODE_TO_ERROR.fetch(code, self)

      if error_class <= ValidationError
        error_class.new(message, errors: problem["errors"], **common)
      elsif error_class <= RateLimitedError
        error_class.new(message, retry_after: retry_after, **common)
      else
        error_class.new(message, **common)
      end
    end
  end
end
