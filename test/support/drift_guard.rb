# frozen_string_literal: true

require "set"

# The spec drift-guard's shared machinery and coverage map. Required by both the offline
# meta-tests (test/basecradle/drift_guard_test.rb) and the one live network test
# (test/live/drift_guard_live_test.rb).
#
# The platform's OpenAPI spec is generated from its test suite and cannot lie. This gives
# the SDK the reverse guarantee: every live endpoint must appear in COVERAGE, or CI fails.
# When the platform adds an endpoint, the live check fails → file an issue → add SDK
# coverage → extend COVERAGE. That is the intended workflow.
module DriftGuard
  LIVE_SPEC_URL = "https://basecradle.com/docs/api.yaml"

  # Every (METHOD, path) the live API exposes → the SDK feature that covers it. This is
  # the contract the drift-guard enforces, and documentation of what implements what.
  COVERAGE = {
    # Authentication
    [ "POST", "/session" ] => "BaseCradle::Client.login",
    [ "DELETE", "/session" ] => "bc.sign_out",
    # Dashboard — self-discovery
    [ "GET", "/users/dashboard" ] => "bc.me",
    # Timelines
    [ "GET", "/timelines" ] => "bc.timelines (iteration)",
    [ "POST", "/timelines" ] => "bc.timelines.create",
    [ "GET", "/timelines/{id}" ] => "bc.timelines.get",
    [ "DELETE", "/timelines/{id}" ] => "timeline.delete",
    [ "POST", "/timelines/{timeline_id}/lock" ] => "timeline.lock",
    # Participations
    [ "POST", "/timelines/{timeline_id}/participations" ] => "timeline.add_participant",
    [ "DELETE", "/timelines/{timeline_id}/participations/{id}" ] => "timeline.remove_participant",
    # Messages
    [ "GET", "/messages" ] => "bc.messages (iteration) / .filter",
    [ "GET", "/messages/{id}" ] => "bc.messages.get",
    [ "POST", "/timelines/{timeline_id}/messages" ] => "timeline.messages.create",
    # Assets
    [ "GET", "/assets" ] => "bc.assets (iteration) / .filter",
    [ "GET", "/assets/{id}" ] => "bc.assets.get",
    [ "POST", "/timelines/{timeline_id}/assets" ] => "timeline.assets.create",
    # Tasks
    [ "GET", "/tasks" ] => "bc.tasks (iteration) / .filter",
    [ "GET", "/tasks/{id}" ] => "bc.tasks.get",
    [ "POST", "/timelines/{timeline_id}/tasks" ] => "timeline.tasks.create",
    [ "POST", "/tasks/{task_id}/cancellation" ] => "task.cancel",
    # Webhook endpoints
    [ "GET", "/webhook_endpoints" ] => "bc.webhook_endpoints (iteration) / .filter",
    [ "GET", "/webhook_endpoints/{id}" ] => "bc.webhook_endpoints.get",
    [ "POST", "/timelines/{timeline_id}/webhook_endpoints" ] => "timeline.webhook_endpoints.create",
    [ "POST", "/webhook_endpoints/{webhook_endpoint_id}/enablement" ] => "endpoint.enable",
    [ "DELETE", "/webhook_endpoints/{webhook_endpoint_id}/enablement" ] => "endpoint.disable",
    [ "POST", "/webhook_endpoints/{webhook_endpoint_id}/rotation" ] => "endpoint.rotate",
    # Webhook events
    [ "GET", "/webhook_events" ] => "bc.webhook_events (iteration) / .filter",
    [ "GET", "/webhook_events/{id}" ] => "bc.webhook_events.get",
    # Users & trust
    [ "GET", "/users" ] => "bc.users (iteration)",
    [ "GET", "/users/{id}" ] => "bc.users.get",
    [ "POST", "/users/{user_id}/trust" ] => "user.grant_trust",
    [ "DELETE", "/users/{user_id}/trust" ] => "user.revoke_trust",
    # Sessions — self-credential management
    [ "GET", "/users/sessions" ] => "bc.sessions (iteration)",
    [ "DELETE", "/users/sessions" ] => "bc.sessions.revoke_all",
    [ "DELETE", "/users/sessions/{id}" ] => "session.revoke",
    # Webhook ingest — intentionally not covered: the ingest URL is for *external senders*,
    # not authenticated peers. The SDK's job is handing it out (endpoint.content.ingest_url),
    # not POSTing to it.
    [ "POST", "/webhooks/{ingest_token}" ] => "intentionally not covered (external senders only)"
  }.freeze

  HTTP_METHODS = %w[get post put patch delete head options].freeze

  module_function

  # Every (METHOD, path) pair in the spec. A constrained parser for the platform's
  # *generated* spec format (two-space-indented quoted path keys, four-space-indented
  # method keys). The guards below make any format drift loud — this fails rather than
  # silently extracting nothing.
  def endpoint_pairs(spec_text)
    pairs = Set.new
    current_path = nil
    spec_text.each_line do |line|
      if (m = line.match(/^  "(\/[^"]*)":\s*$/))
        current_path = m[1]
      elsif current_path && (m = line.match(/^    (#{HTTP_METHODS.join('|')}):\s*$/o))
        pairs << [ m[1].upcase, current_path ]
      end
    end

    if pairs.size < 30
      raise "Parsed only #{pairs.size} endpoint pairs from the spec — the spec format has " \
            "likely changed and this parser needs updating. Never ignore this."
    end
    unless pairs.include?([ "POST", "/session" ])
      raise "POST /session is missing from the parsed pairs — the spec format has likely " \
            "changed and this parser needs updating. Never ignore this."
    end
    pairs
  end

  # The endpoints the live API has that the coverage map doesn't account for.
  def uncovered(live_pairs, coverage)
    live_pairs - coverage.keys
  end
end
