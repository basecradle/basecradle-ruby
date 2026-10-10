# frozen_string_literal: true

require "test_helper"

# Contact messages and notes: the platform's first admin-only surface. The fixtures are an
# admin's view; the gate itself is the platform's, so the SDK's half of it is mapping the
# 403 to NotAnAdminError — pinned at the bottom.
class ContactMessagesTest < Minitest::Test
  include TestSupport

  CONTACT_MESSAGE_URL = "#{BASE_URL}/contact_messages/#{CONTACT_MESSAGE_UUID}".freeze

  def setup
    @bc = BaseCradle::Client.new(FAKE_TOKEN)
  end

  # --- contact messages: reading -----------------------------------------------------------

  def test_lists_contact_messages_as_flat_records_mirroring_the_wire
    stub_list("/contact_messages", "contact_messages", [ contact_message_payload ])

    message = @bc.contact_messages.first

    assert_instance_of BaseCradle::ContactMessage, message
    assert_equal CONTACT_MESSAGE_UUID, message.uuid
    assert_equal "Nova Digital", message.name
    assert_equal "nova@example.com", message.email_address
    assert_equal "received", message.status
    assert_equal "203.0.113.42", message.ip_address
    refute message.honeypot_filled
    assert_equal 42, message.fill_seconds
    assert_equal "2026-01-02T00:00:06.000Z", message.updated_at
    assert_equal CONTACT_MESSAGE_UUID, BaseCradle.uuid_of(message)
  end

  def test_a_visitor_without_an_account_has_a_nil_user
    stub_list("/contact_messages", "contact_messages", [ contact_message_payload(user: nil) ])

    assert_nil @bc.contact_messages.first.user
  end

  def test_a_signed_in_submitter_is_a_user_in_nested_actor_form
    stub_list("/contact_messages", "contact_messages", [ contact_message_payload(user: NOVA) ])

    user = @bc.contact_messages.first.user

    assert_instance_of BaseCradle::User, user
    assert_equal "nova", user.handle
  end

  # The vendors are the platform's to add and change, so the SDK models none of them:
  # `data` is the wire Hash, answered and skipped slots alike.
  def test_data_is_the_vendors_slots_as_the_platform_sent_them
    stub_list("/contact_messages", "contact_messages", [ contact_message_payload ])

    data = @bc.contact_messages.first.data

    assert_instance_of Hash, data
    assert_equal contact_message_payload["data"], data
    assert_equal 0, data.dig("ipqualityscore", "answer", "fraud_score")
    assert_equal "no token", data.dig("abuseipdb", "skipped")
  end

  def test_notes_are_embedded_in_full_as_notes
    stub_list("/contact_messages", "contact_messages", [ contact_message_payload ])

    notes = @bc.contact_messages.first.notes

    assert_equal 1, notes.size
    assert_instance_of BaseCradle::Note, notes.first
    assert_equal "john", notes.first.user.handle
    assert_equal CONTACT_MESSAGE_UUID, notes.first.notable.uuid
  end

  # The visitor's request headers read through the same rules as a webhook delivery's:
  # the wire's own spelling, case-insensitive lookup, and a render of names only.
  def test_headers_fold_case_on_lookup_and_render_names_only
    stub_list("/contact_messages", "contact_messages", [ contact_message_payload ])

    headers = @bc.contact_messages.first.headers

    assert_instance_of BaseCradle::ContactMessageHeaders, headers
    assert_equal "en-US,en;q=0.9", headers["accept-language"]
    assert_equal contact_message_payload["headers"], headers.to_h
    assert_raises(KeyError) { headers["Cookie"] }
    assert_equal "#<BaseCradle::ContactMessageHeaders Accept-Language, Host, User-Agent>",
                 headers.inspect
  end

  def test_contact_messages_paginate_newest_first
    stub_request(:get, "#{BASE_URL}/contact_messages").to_return(
      status: 200, body: { "contact_messages" => [ contact_message_payload ], "next_cursor" => "C1" }.to_json
    )
    older = "019e7750-66ee-7a11-9c3e-1d2f4a6b8c0e"
    stub_request(:get, "#{BASE_URL}/contact_messages").with(query: { "before" => "C1" }).to_return(
      status: 200,
      body: { "contact_messages" => [ contact_message_payload(uuid: older) ], "next_cursor" => nil }.to_json
    )

    assert_equal [ CONTACT_MESSAGE_UUID, older ], @bc.contact_messages.map(&:uuid)
  end

  def test_filter_by_status_is_lazy_and_leaves_the_original_unfiltered
    filtered = @bc.contact_messages.filter(status: "spam")
    assert_not_requested(:get, /contact_messages/) # building a filter sends nothing

    stub_request(:get, "#{BASE_URL}/contact_messages").with(query: { "status" => "spam" })
      .to_return(status: 200, body: { "contact_messages" => [ contact_message_payload(status: "spam") ],
                                      "next_cursor" => nil }.to_json)
    stub_list("/contact_messages", "contact_messages", [])

    assert_equal [ "spam" ], filtered.map(&:status)
    assert_empty @bc.contact_messages.to_a
  end

  def test_the_status_filter_rides_every_page
    stub_request(:get, "#{BASE_URL}/contact_messages").with(query: { "status" => "closed" })
      .to_return(status: 200, body: { "contact_messages" => [ contact_message_payload(status: "closed") ],
                                      "next_cursor" => "C1" }.to_json)
    stub_request(:get, "#{BASE_URL}/contact_messages")
      .with(query: { "status" => "closed", "before" => "C1" })
      .to_return(status: 200, body: { "contact_messages" => [], "next_cursor" => nil }.to_json)

    assert_equal 1, @bc.contact_messages.filter(status: "closed").count
  end

  def test_get_fetches_one_contact_message_by_uuid
    stub_request(:get, CONTACT_MESSAGE_URL)
      .to_return(status: 200, body: { "contact_message" => contact_message_payload }.to_json)

    message = @bc.contact_messages.get(CONTACT_MESSAGE_UUID)

    assert_instance_of BaseCradle::ContactMessage, message
    assert_equal CONTACT_MESSAGE_UUID, message.uuid
  end

  # --- contact messages: the two verbs -----------------------------------------------------

  def test_update_status_patches_and_the_object_reads_the_answer
    stub_request(:get, CONTACT_MESSAGE_URL)
      .to_return(status: 200, body: { "contact_message" => contact_message_payload }.to_json)
    stub_request(:patch, "#{CONTACT_MESSAGE_URL}/status")
      .with(body: { "contact_message" => { "status" => "closed" } }.to_json)
      .to_return(status: 200, body: { "contact_message" => contact_message_payload(status: "closed") }.to_json)
    message = @bc.contact_messages.get(CONTACT_MESSAGE_UUID)

    assert_same message, message.update_status("closed")
    assert_equal "closed", message.status
    assert_requested(:patch, "#{CONTACT_MESSAGE_URL}/status", times: 1)
  end

  def test_an_unknown_status_is_the_apis_to_refuse
    stub_request(:get, CONTACT_MESSAGE_URL)
      .to_return(status: 200, body: { "contact_message" => contact_message_payload }.to_json)
    stub_request(:patch, "#{CONTACT_MESSAGE_URL}/status").to_return(
      status: 422, headers: { "Content-Type" => "application/problem+json" },
      body: problem("validation_failed", 422, errors: { "status" => [ "is not included in the list" ] }).to_json
    )
    message = @bc.contact_messages.get(CONTACT_MESSAGE_UUID)

    error = assert_raises(BaseCradle::ValidationError) { message.update_status("archived") }
    assert_equal({ "status" => [ "is not included in the list" ] }, error.errors)
    assert_equal "received", message.status # a refused write leaves the record as fetched
  end

  def test_add_note_posts_the_body_and_returns_the_note
    stub_request(:get, CONTACT_MESSAGE_URL)
      .to_return(status: 200, body: { "contact_message" => contact_message_payload(notes: []) }.to_json)
    stub_request(:post, "#{CONTACT_MESSAGE_URL}/notes")
      .with(body: { "note" => { "body" => "Replied by email." } }.to_json)
      .to_return(status: 201, headers: { "Location" => "/notes/#{NOTE_UUID}" },
                 body: { "note" => note_payload(body: "Replied by email.") }.to_json)
    message = @bc.contact_messages.get(CONTACT_MESSAGE_UUID)

    note = message.add_note(body: "Replied by email.")

    assert_instance_of BaseCradle::Note, note
    assert_equal "Replied by email.", note.body
    assert_equal "contact_message", note.notable.type
    assert_empty message.notes # the record as fetched — re-fetch to read it with the note
  end

  def test_a_blank_note_is_a_validation_error
    stub_request(:get, CONTACT_MESSAGE_URL)
      .to_return(status: 200, body: { "contact_message" => contact_message_payload }.to_json)
    stub_request(:post, "#{CONTACT_MESSAGE_URL}/notes").to_return(
      status: 422, headers: { "Content-Type" => "application/problem+json" },
      body: problem("validation_failed", 422, errors: { "body" => [ "can't be blank" ] }).to_json
    )

    error = assert_raises(BaseCradle::ValidationError) do
      @bc.contact_messages.get(CONTACT_MESSAGE_UUID).add_note(body: "")
    end
    assert_equal({ "body" => [ "can't be blank" ] }, error.errors)
  end

  # The notes endpoint takes no Idempotency-Key, so a resend after a lost response could
  # write the note twice — it is never auto-retried, however max_retries is set.
  def test_add_note_is_never_auto_retried
    bc = BaseCradle::Client.new(FAKE_TOKEN, max_retries: 3)
    message = BaseCradle::ContactMessage.new(contact_message_payload, client: bc)
    stub_request(:post, "#{CONTACT_MESSAGE_URL}/notes").to_timeout

    assert_raises(BaseCradle::APIConnectionError) { message.add_note(body: "Replied by email.") }
    assert_requested(:post, "#{CONTACT_MESSAGE_URL}/notes", times: 1)
  end

  def test_a_detached_contact_message_cannot_call_the_api
    detached = BaseCradle::ContactMessage.new(contact_message_payload)

    assert_raises(BaseCradle::Error) { detached.update_status("closed") }
    assert_raises(BaseCradle::Error) { detached.add_note(body: "x") }
  end

  # --- notes -------------------------------------------------------------------------------

  def test_lists_every_note_newest_first_and_paginates
    older = "019e7750-66ee-7d44-a1b2-3c4d5e6f7a8b"
    stub_request(:get, "#{BASE_URL}/notes")
      .to_return(status: 200, body: { "notes" => [ note_payload ], "next_cursor" => "C1" }.to_json)
    stub_request(:get, "#{BASE_URL}/notes").with(query: { "before" => "C1" })
      .to_return(status: 200, body: { "notes" => [ note_payload(uuid: older) ], "next_cursor" => nil }.to_json)

    notes = @bc.notes.to_a

    assert_equal [ NOTE_UUID, older ], notes.map(&:uuid)
    assert(notes.all?(BaseCradle::Note))
  end

  # One shape everywhere a note appears: fetched alone, it is the same record as embedded.
  def test_get_fetches_one_note_in_the_same_shape_it_is_embedded_in
    stub_request(:get, "#{BASE_URL}/notes/#{NOTE_UUID}")
      .to_return(status: 200, body: { "note" => note_payload }.to_json)

    note = @bc.notes.get(NOTE_UUID)
    embedded = BaseCradle::ContactMessage.new(contact_message_payload).notes.first

    assert_equal embedded.to_h, note.to_h
    assert_equal "Looks genuine. Replied by email.", note.body
    assert_instance_of BaseCradle::User, note.user
    assert_equal "2026-01-03T00:00:00.000Z", note.created_at
  end

  # --- the admin gate ------------------------------------------------------------------------

  def test_a_non_admin_gets_not_an_admin_on_every_surface
    forbidden = { status: 403, headers: { "Content-Type" => "application/problem+json" },
                  body: problem("not_an_admin", 403, title: "Admin Action Required").to_json }
    stub_request(:get, /#{BASE_URL}\/(contact_messages|notes)/).to_return(forbidden)
    stub_request(:patch, "#{CONTACT_MESSAGE_URL}/status").to_return(forbidden)
    stub_request(:post, "#{CONTACT_MESSAGE_URL}/notes").to_return(forbidden)
    message = BaseCradle::ContactMessage.new(contact_message_payload, client: @bc)

    [
      -> { @bc.contact_messages.first },
      -> { @bc.contact_messages.get(CONTACT_MESSAGE_UUID) },
      -> { message.update_status("closed") },
      -> { message.add_note(body: "x") },
      -> { @bc.notes.first },
      -> { @bc.notes.get(NOTE_UUID) }
    ].each do |call|
      error = assert_raises(BaseCradle::NotAnAdminError) { call.call }
      assert_kind_of BaseCradle::ForbiddenError, error
      assert_equal "not_an_admin", error.code
      assert_equal "Admin Action Required", error.title
    end
  end

  def test_an_unknown_status_filter_is_an_invalid_filter_error
    stub_request(:get, "#{BASE_URL}/contact_messages").with(query: { "status" => "archived" }).to_return(
      status: 400, headers: { "Content-Type" => "application/problem+json" },
      body: problem("invalid_filter", 400).to_json
    )

    assert_raises(BaseCradle::InvalidFilterError) { @bc.contact_messages.filter(status: "archived").first }
  end

  private

  def stub_list(path, key, rows)
    stub_request(:get, "#{BASE_URL}#{path}")
      .to_return(status: 200, body: { key => rows, "next_cursor" => nil }.to_json)
  end
end
