# frozen_string_literal: true

require "test_helper"

# The catalog below mirrors the API docs (Errors → Error Codes) and is pinned to the SDK's
# registry, so a mapping removed, or added without a test, fails here. A code the platform
# *documents* after this release is the live drift-guard's to catch: it holds the docs' Error
# Codes table to the same registry (test/live/drift_guard_live_test.rb). Until the code is
# mapped, it reads as a bare BaseCradle::Error.
class ErrorsTest < Minitest::Test
  include TestSupport

  ERROR_CATALOG = {
    "unauthorized" => BaseCradle::UnauthorizedError,
    "invalid_credentials" => BaseCradle::InvalidCredentialsError,
    "invalid_signature" => BaseCradle::InvalidSignatureError,
    "account_suspended" => BaseCradle::AccountSuspendedError,
    "not_a_viewer" => BaseCradle::NotAViewerError,
    "not_timeline_owner" => BaseCradle::NotTimelineOwnerError,
    "timeline_locked" => BaseCradle::TimelineLockedError,
    "not_task_author" => BaseCradle::NotTaskAuthorError,
    "not_an_admin" => BaseCradle::NotAnAdminError,
    "task_not_pending" => BaseCradle::TaskNotPendingError,
    "not_found" => BaseCradle::NotFoundError,
    "validation_failed" => BaseCradle::ValidationError,
    "current_password_incorrect" => BaseCradle::CurrentPasswordIncorrectError,
    "password_confirmation_mismatch" => BaseCradle::PasswordConfirmationMismatchError,
    "rate_limited" => BaseCradle::RateLimitedError,
    "invalid_cursor" => BaseCradle::InvalidCursorError,
    "invalid_filter" => BaseCradle::InvalidFilterError,
    "endpoint_disabled" => BaseCradle::EndpointDisabledError,
    "payload_too_large" => BaseCradle::PayloadTooLargeError,
    "binary_payload" => BaseCradle::BinaryPayloadError
  }.freeze

  def test_the_catalog_is_exactly_the_registry
    # Every mapped code has a row here, and every row is mapped — no count to keep in step.
    assert_equal BaseCradle::CODE_TO_ERROR.keys.sort, ERROR_CATALOG.keys.sort
  end

  def test_every_known_code_maps_to_its_class
    ERROR_CATALOG.each do |code, klass|
      error = BaseCradle::Error.from_response(status: 400, problem: problem(code, 400))

      assert_instance_of klass, error
      assert_equal code, error.code
    end
  end

  def test_problem_document_is_exposed
    doc = problem("not_a_viewer", 403, detail: "You are not a viewer of this timeline.")

    error = BaseCradle::Error.from_response(status: 403, problem: doc)

    assert_equal 403, error.status
    assert_equal "not_a_viewer", error.code
    assert_equal "You are not a viewer of this timeline.", error.detail
    assert_equal FAKE_INSTANCE, error.instance
    assert_equal doc, error.problem
    assert_equal "You are not a viewer of this timeline.", error.message
  end

  def test_unknown_code_falls_back_to_base_error
    error = BaseCradle::Error.from_response(status: 418, problem: problem("teapot_engaged", 418))

    assert_instance_of BaseCradle::Error, error
    assert_equal "teapot_engaged", error.code
  end

  def test_non_problem_body_falls_back_to_status_only
    error = BaseCradle::Error.from_response(status: 502, problem: "<html>Bad Gateway</html>")

    assert_instance_of BaseCradle::Error, error
    assert_equal 502, error.status
    assert_nil error.code
    assert_match(/HTTP 502/, error.message)
  end

  def test_validation_error_carries_field_errors
    doc = problem("validation_failed", 422, errors: { "name" => [ "can't be blank" ] })

    error = BaseCradle::Error.from_response(status: 422, problem: doc)

    assert_instance_of BaseCradle::ValidationError, error
    assert_equal({ "name" => [ "can't be blank" ] }, error.errors)
  end

  def test_rate_limited_error_carries_retry_after
    error = BaseCradle::Error.from_response(
      status: 429, problem: problem("rate_limited", 429), retry_after: 30
    )

    assert_instance_of BaseCradle::RateLimitedError, error
    assert_equal 30, error.retry_after
  end

  def test_hierarchy_lets_callers_catch_broadly
    assert_operator BaseCradle::UnauthorizedError, :<, BaseCradle::AuthenticationError
    assert_operator BaseCradle::AuthenticationError, :<, BaseCradle::Error
    assert_operator BaseCradle::NotAViewerError, :<, BaseCradle::ForbiddenError
    assert_operator BaseCradle::NotTaskAuthorError, :<, BaseCradle::ForbiddenError
    assert_operator BaseCradle::TaskNotPendingError, :<, BaseCradle::ConflictError
    assert_operator BaseCradle::ConflictError, :<, BaseCradle::Error
    assert_operator BaseCradle::InvalidCursorError, :<, BaseCradle::InvalidRequestError
    assert_operator BaseCradle::CurrentPasswordIncorrectError, :<, BaseCradle::ValidationError
    assert_operator BaseCradle::Error, :<, StandardError
  end
end
