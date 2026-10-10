# frozen_string_literal: true

# The ActiveSupport half of the serialization guard, run in its OWN process by
# test/basecradle/active_support_test.rb, which passes the fake token as ARGV[0].
#
# Why a separate process: ActiveSupport's core_ext monkey-patches Object, Enumerable,
# Hash and Array, and nothing can unload it again. Requiring it inside the suite would
# silently change the environment every other test runs under — including the tests that
# exist to pin plain-Ruby behaviour. So the dangerous environment is built here, once,
# and the observations are handed back as JSON on the LAST line of stdout.
#
# It asserts nothing — the parent test does all the judging.

require "json"
require "pp"
require "yaml"

# Same rule as the suite: never the live API. WebMock's minitest integration is not
# wanted here (there is no Minitest in this process), but its Net::HTTP adapter and the
# net-connect block are, so a transport that ever stopped funnelling through
# Client.perform still cannot reach the network.
require "webmock"
WebMock.enable!
WebMock.disable_net_connect!

require "basecradle"

# Loaded the way a Rails app loads it: this is the patch that makes Object#as_json
# instance_values, and gives Enumerable its own as_json/to_json.
require "active_support/json"
require "active_support/core_ext/object/json"

TOKEN = ARGV.fetch(0)
TIMELINE_UUID = "019e7750-66ee-7f53-829f-13a8a710b6da"

# A value that must never appear in a render: the credential an inbound sender put in its
# own header, and a record field. Distinct from TOKEN, which is *our* credential — a
# render can leak either, and only one of them is ours to rotate.
SENDER_SECRET = "Bearer sender-authorization-value"
RECORD_SECRET = "the-body-text-of-this-message"

# A request must never be attempted in the first place: serializing a lazy collection
# used to call to_a and page the whole resource. The one send path both Client#request
# and Client.login funnel through raises loudly, so a network attempt shows up in the
# report as an outcome of its own rather than as a WebMock error from further down.
BaseCradle::Client.define_singleton_method(:perform) { |*| raise "HTTP issued" }

# A plain object holding something, with no serialization of its own — what ActiveSupport
# walks with instance_values. The control proves the dangerous path is live in this
# process; the client-holding one proves the refusal still fires one hop down.
class Holder
  def initialize(held)
    @held = held
  end
end

def observe
  { "outcome" => "returned", "value" => JSON.generate(yield) }
rescue StandardError => e
  { "outcome" => e.class.name, "message" => e.message }
end

client = BaseCradle::Client.new(TOKEN)

subjects = {
  "Client" => client,
  "TimelinesResource" => client.timelines,
  "MessagesResource" => client.messages,
  "AssetsResource" => client.assets,
  "TasksResource" => client.tasks,
  "WebhookEndpointsResource" => client.webhook_endpoints,
  "WebhookEventsResource" => client.webhook_events,
  "SessionsResource" => client.sessions,
  "UsersResource" => client.users,
  "ContactMessagesResource" => client.contact_messages,
  "NotesResource" => client.notes,
  "ItemsResource" => BaseCradle::ItemsResource.new(client),
  "TimelineMessages" => BaseCradle::TimelineMessages.new(client, TIMELINE_UUID),
  "TimelineAssets" => BaseCradle::TimelineAssets.new(client, TIMELINE_UUID),
  "TimelineTasks" => BaseCradle::TimelineTasks.new(client, TIMELINE_UUID),
  "TimelineWebhookEndpoints" => BaseCradle::TimelineWebhookEndpoints.new(client, TIMELINE_UUID),
  "TimelineWebhookEvents" => BaseCradle::TimelineWebhookEvents.new(client, TIMELINE_UUID),
  "Paginator" => BaseCradle::Paginator.new(client, "/timelines", envelope_key: "timelines",
                                                                 model: BaseCradle::Timeline)
}

# The records: they render by the same names-only rule as everything else, and unlike the
# collections they legitimately *serialize* — a delivery's headers and a message are
# records, and an app is meant to be able to render one as JSON.
#
# They are here because the harness used to exclude them and so never rendered, under real
# ActiveSupport, the one class 0.10.2's fix was written for (#212). The exclusion's reason
# was true of serialization and silently applied to a render question it does not answer.
records = {
  "WebhookEventHeaders" => BaseCradle::WebhookEventHeaders.new(
    { "Content-Type" => "application/json", "Authorization" => SENDER_SECRET }
  ),
  # The shared base, and its other recorded request: a contact-page visitor's headers.
  "RequestHeaders" => BaseCradle::RequestHeaders.new(
    { "Content-Type" => "application/json", "Authorization" => SENDER_SECRET }
  ),
  "ContactMessageHeaders" => BaseCradle::ContactMessageHeaders.new(
    { "Content-Type" => "application/x-www-form-urlencoded", "Cookie" => SENDER_SECRET }
  ),
  # An ApiObject too: #212 gave records their to_s and pretty_print from the shared module,
  # and those are new doors that had never been observed in this environment.
  "Message" => BaseCradle::Message.new(
    { "uuid" => "0199a1f2-4c7e-7c3a-9f11-2b6d5e8a9c04", "body" => RECORD_SECRET },
    client: client
  )
}

report = subjects.transform_values do |subject|
  {
    # render json: { conn: bc } — the hook ActiveSupport reaches for.
    "as_json" => observe { subject.as_json },
    # render json: bc, and logger.info(bc.to_json).
    "to_json" => observe { subject.to_json },
    # nested in the document being rendered or logged.
    "nested" => observe { { "conn" => subject }.to_json },
    # the encoder Rails' renderer actually calls.
    "encode" => observe { ActiveSupport::JSON.encode(subject) },
    # held by an ordinary object with no as_json of its own — one hop further down.
    "held" => observe { { "holder" => Holder.new(subject) }.to_json },
    # Marshal and Psych need no ActiveSupport to walk ivars, so the offline half is
    # where they are pinned — but Rails.cache.write and a Marshal-backed session are
    # the scenarios that made them urgent, and those happen in *this* environment.
    # Reported as "does the output contain the token" rather than as the bytes: a
    # Marshal dump is binary and would fail JSON.generate, turning a reopened hole into
    # an opaque encoding error instead of a plain `true`.
    "marshal" => observe { Marshal.dump(subject).include?(TOKEN) },
    "yaml" => observe { subject.to_yaml.include?(TOKEN) },
    # And one hop down, which is the shape Rails.cache.write(key, model) really has.
    "marshal_held" => observe { Marshal.dump(Holder.new(subject)).include?(TOKEN) },
    "inspect" => subject.inspect,
    "to_s" => subject.to_s
  }
end

record_report = records.transform_values do |record|
  {
    # A record is supposed to serialize. Observed so the parent can assert it still does:
    # the render rule must not have been bought by breaking what these objects are for.
    "as_json" => observe { record.as_json },
    "to_json" => observe { record.to_json },
    # The three render doors, which is what this bucket is really here for.
    "inspect" => record.inspect,
    "to_s" => record.to_s,
    "pretty_print" => PP.pp(record, +"").chomp
  }
end

puts JSON.generate(
  # The control: the same Holder around a harmless string. It MUST serialize its ivar —
  # that is how we know ActiveSupport's instance_values walk is live in this process and
  # the subjects above were genuinely exposed to it.
  "control" => observe { { "holder" => Holder.new("held-in-the-clear") }.to_json },
  # Every lazy collection class the SDK defines, found the same reflective way the offline
  # test finds them. Hash descendants are excluded *here* because they serialize rather
  # than refuse — and they are picked up by "hash_descendant_classes" below, which is the
  # half that was missing: the exclusion used to end the sentence, so the class 0.10.2
  # secured was in neither list. The parent asserts the hand-written subject list covers
  # all of these, so a resource added later cannot quietly skip the real-ActiveSupport half.
  "enumerable_classes" => BaseCradle.constants.map { |name| BaseCradle.const_get(name) }
                                    .select { |const| const.is_a?(Class) && const.include?(Enumerable) }
                                    .reject { |klass| klass <= Hash }
                                    .map { |klass| klass.name.split("::").last }.sort,
  # Every Hash descendant the SDK defines. This is the shape that brought its own render
  # and printed every value (0.10.2), so the parent asserts the records bucket covers all
  # of them — a second one added later cannot skip this environment the way the first did.
  "hash_descendant_classes" => BaseCradle.constants.map { |name| BaseCradle.const_get(name) }
                                         .select { |const| const.is_a?(Class) && const <= Hash }
                                         .map { |klass| klass.name.split("::").last }.sort,
  "sender_secret" => SENDER_SECRET,
  "record_secret" => RECORD_SECRET,
  "subjects" => report,
  "records" => record_report
)
