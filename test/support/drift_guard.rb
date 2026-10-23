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
#
# Endpoints are half of the surface. The other half is the error codes: a code the platform
# documents with no typed class here reaches callers as a bare BaseCradle::Error, and no
# endpoint check notices (binary_payload did exactly that). So the prose docs' Error Codes
# table is held to BaseCradle::CODE_TO_ERROR the same way.
module DriftGuard
  LIVE_SPEC_URL = "https://basecradle.com/docs/api.yaml"
  LIVE_DOCS_URL = "https://basecradle.com/docs/api.md"

  # Every (METHOD, path) the live API exposes → the SDK feature that covers it. This is
  # the contract the drift-guard enforces, and documentation of what implements what.
  COVERAGE = {
    # Authentication
    [ "POST", "/session" ] => "BaseCradle::Client.login",
    [ "DELETE", "/session" ] => "bc.sign_out",
    # Dashboard — self-discovery
    [ "GET", "/users/dashboard" ] => "bc.me",
    # Not in the spec today (a format of the path above); listed so the map names its reader.
    [ "GET", "/users/dashboard.md" ] => "bc.dashboard_md",
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
    # Password — self-credential management
    [ "PATCH", "/users/password" ] => "bc.change_password",
    # Contact messages — admin-only
    [ "GET", "/contact_messages" ] => "bc.contact_messages (iteration) / .filter",
    [ "GET", "/contact_messages/{id}" ] => "bc.contact_messages.get",
    [ "PATCH", "/contact_messages/{contact_message_id}/status" ] => "contact_message.set_status",
    [ "POST", "/contact_messages/{contact_message_id}/notes" ] => "contact_message.add_note",
    # Notes — admin-only
    [ "GET", "/notes" ] => "bc.notes (iteration)",
    [ "GET", "/notes/{id}" ] => "bc.notes.get",
    # Webhook ingest — intentionally not covered: the ingest URL is for *external senders*,
    # not authenticated peers. The SDK's job is handing it out (endpoint.content.ingest_url),
    # not POSTing to it.
    [ "POST", "/webhooks/{ingest_token}" ] => "intentionally not covered (external senders only)"
  }.freeze

  HTTP_METHODS = %w[get post put patch delete head options].freeze

  ERROR_CODES_HEADING = "### Error Codes"
  ERROR_CODES_HEADER_ROW = "| Code | Status | When |"
  ERROR_CODES_SEPARATOR = /\A\|(?: *:?-+:? *\|){3}\z/
  # A row: the code in backticks, optionally followed by its `{:#error-…}` anchor, then a
  # three-digit status and a non-empty description. The description may hold an escaped
  # `\|` but no bare pipe, so a row that grows a column fails rather than parsing.
  ERROR_CODE_ROW = /\A\| `([a-z0-9_]+)`(?:\{:#[^}]*\})? \| [0-9]{3} \| (?:[^|\\\s]|\\.)(?:[^|\\]|\\.)* \|\z/
  # The section ends at the next heading of the same or a higher level, outside a code fence.
  SECTION_END = /\A\#{1,3} /
  FENCE = /\A {0,3}(```|~~~)/

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

  # Every code in the prose docs' "### Error Codes" table.
  #
  # The prose docs, not the spec: the table is the platform's one complete list, while the
  # spec's problem+json examples can only carry codes some contract test exercises.
  #
  # A constrained parser for the table's current shape. Unlike the spec, the table is
  # hand-written, so the guards are stricter than endpoint_pairs's: every table line in the
  # section must parse, or the whole read fails. A row reshaped so it no longer matches
  # would otherwise drop out silently, and its code would never be checked.
  def documented_error_codes(docs_text)
    lines = docs_text.lines.map(&:rstrip)
    starts = lines.each_index.select { |i| lines[i] == ERROR_CODES_HEADING }
    unless starts.size == 1
      raise "Found #{starts.size} '#{ERROR_CODES_HEADING}' headings in the docs, expected " \
            "exactly 1 — the docs format has likely changed and this parser needs updating. " \
            "Never ignore this."
    end

    # Every line in the section, outside a code fence, that holds a pipe — indented, or
    # missing GFM's optional leading pipe. The row pattern is anchored at a leading `|`, so
    # such a row fails loudly instead of being skipped. Collecting too much is the safe
    # direction: an extra line can only fail the read, never pass it.
    table_lines = []
    in_fence = false
    lines.drop(starts.first + 1).each do |line|
      if line.match?(FENCE)
        in_fence = !in_fence
      elsif in_fence
        next
      elsif line.match?(SECTION_END)
        break
      elsif line.include?("|")
        table_lines << line
      end
    end

    # Format-drift guards: if the table changes shape, fail loudly here rather than letting
    # the comparison pass vacuously or on a partial read.
    if table_lines.size < 2 || table_lines.first != ERROR_CODES_HEADER_ROW
      raise "The Error Codes table does not start with #{ERROR_CODES_HEADER_ROW.inspect} — " \
            "the docs format has likely changed and this parser needs updating. Never ignore this."
    end
    unless table_lines[1].match?(ERROR_CODES_SEPARATOR)
      raise "The Error Codes table's second line is #{table_lines[1].inspect}, not a separator " \
            "row — the docs format has likely changed and this parser needs updating. " \
            "Never ignore this."
    end
    codes = table_lines.drop(2).to_set do |line|
      match = line.match(ERROR_CODE_ROW)
      unless match
        raise "Unparseable Error Codes row #{line.inspect} — the docs format has likely " \
              "changed and this parser needs updating. Never ignore this."
      end
      match[1]
    end

    if codes.size < 15
      raise "Parsed only #{codes.size} error codes from the docs — the docs format has " \
            "likely changed and this parser needs updating. Never ignore this."
    end
    unless codes.include?("not_found")
      raise "not_found is missing from the parsed error codes — the docs format has likely " \
            "changed and this parser needs updating. Never ignore this."
    end
    codes
  end

  # The error codes the docs list that the SDK has no typed exception for.
  def untyped(documented, registry)
    documented - registry.keys
  end
end
