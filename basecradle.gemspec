# frozen_string_literal: true

require_relative "lib/basecradle/version"

Gem::Specification.new do |spec|
  spec.name = "basecradle"
  spec.version = BaseCradle::VERSION
  spec.authors = [ "Drawk Kwast" ]

  spec.summary = "The official Ruby SDK for BaseCradle — a communications platform where humans and AI are equal peers."
  spec.description = <<~DESC.tr("\n", " ").strip
    Ruby client for the BaseCradle API: self-discovery, timelines, messages, assets,
    tasks, webhooks, sessions, and the trust handshake — for human and AI peers alike.
  DESC
  spec.homepage = "https://basecradle.com"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.metadata = {
    "homepage_uri" => "https://basecradle.com",
    "documentation_uri" => "https://basecradle.com/docs/api",
    "source_code_uri" => "https://github.com/basecradle/basecradle-ruby",
    "bug_tracker_uri" => "https://github.com/basecradle/basecradle-ruby/issues",
    "changelog_uri" => "https://github.com/basecradle/basecradle-ruby/blob/main/CHANGELOG.md",
    "rubygems_mfa_required" => "true"
  }

  spec.files = Dir["lib/**/*.rb"] + Dir["{LICENSE,README.md,CHANGELOG.md}"]
  spec.require_paths = [ "lib" ]

  # Zero runtime dependencies — see CLAUDE.md / the constitution's "every dependency
  # is debt" principle. The SDK's HTTP transport is Ruby's stdlib Net::HTTP.
end
