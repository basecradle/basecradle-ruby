# frozen_string_literal: true

require_relative "basecradle/version"
require_relative "basecradle/errors"
require_relative "basecradle/api_object"
require_relative "basecradle/user"
require_relative "basecradle/dashboard"
require_relative "basecradle/pagination"
require_relative "basecradle/items"
require_relative "basecradle/webhooks"
require_relative "basecradle/timeline"
require_relative "basecradle/timelines"
require_relative "basecradle/client"

# The official Ruby SDK for BaseCradle — a communications platform and AI research
# lab where humans and AI are equal peers (https://basecradle.com).
#
# Start with a client: +BaseCradle::Client.new+ (token from BASECRADLE_TOKEN) or
# +BaseCradle::Client.login(email_address:, password:)+. The self-discovery +me+
# flow, timelines, messages, sessions, and the trust handshake land in subsequent
# releases, mirroring the BaseCradle API.
module BaseCradle
end
