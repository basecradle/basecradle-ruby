# frozen_string_literal: true

source "https://rubygems.org"

# Runtime dependencies (none) are declared in the gemspec.
gemspec

group :development, :test do
  # Dev-only, and bounded: the ActiveSupport probe pins one specific monkey-patch
  # shape (Object#as_json == instance_values, Enumerable#as_json calls to_a), and
  # Gemfile.lock is gitignored, so a new major must be an explicit edit here.
  gem "activesupport", ">= 7.0", "< 9", require: false
  gem "minitest", "~> 6.0"
  gem "rake", "~> 13.0"
  gem "rubocop-rails-omakase", require: false
  gem "webmock", "~> 3.0"
end
