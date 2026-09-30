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
  "ItemsResource" => BaseCradle::ItemsResource.new(client),
  "TimelineMessages" => BaseCradle::TimelineMessages.new(client, TIMELINE_UUID),
  "TimelineAssets" => BaseCradle::TimelineAssets.new(client, TIMELINE_UUID),
  "TimelineTasks" => BaseCradle::TimelineTasks.new(client, TIMELINE_UUID),
  "TimelineWebhookEndpoints" => BaseCradle::TimelineWebhookEndpoints.new(client, TIMELINE_UUID),
  "TimelineWebhookEvents" => BaseCradle::TimelineWebhookEvents.new(client, TIMELINE_UUID),
  "Paginator" => BaseCradle::Paginator.new(client, "/timelines", envelope_key: "timelines",
                                                                 model: BaseCradle::Timeline)
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

puts JSON.generate(
  # The control: the same Holder around a harmless string. It MUST serialize its ivar —
  # that is how we know ActiveSupport's instance_values walk is live in this process and
  # the subjects above were genuinely exposed to it.
  "control" => observe { { "holder" => Holder.new("held-in-the-clear") }.to_json },
  # Every lazy collection class the SDK defines, found the same reflective way the
  # offline test finds them (Hash descendants excluded: WebhookEventHeaders *is* a
  # record). The parent asserts the hand-written subject list above covers all of them,
  # so a resource added later cannot quietly skip the real-ActiveSupport half.
  "enumerable_classes" => BaseCradle.constants.map { |name| BaseCradle.const_get(name) }
                                    .select { |const| const.is_a?(Class) && const.include?(Enumerable) }
                                    .reject { |klass| klass <= Hash }
                                    .map { |klass| klass.name.split("::").last }.sort,
  "subjects" => report
)
