# frozen_string_literal: true

require "rake/testtask"

# The offline default suite. Every test except the live spec drift-guard, which
# lives under test/live/ and opts back into the network explicitly.
Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/**/*_test.rb"].exclude("test/live/**/*")
  t.warning = false
end

namespace :test do
  # The spec drift-guard — the ONE networked test. Excluded from the default run
  # (offline runs stay green); CI runs it as its own job. Populated by the
  # drift-guard issue; defined here so `rake test:live` always exists.
  Rake::TestTask.new(:live) do |t|
    t.libs << "test"
    t.libs << "lib"
    t.test_files = FileList["test/live/**/*_test.rb"]
    t.warning = false
  end
end

require "rubocop/rake_task"
RuboCop::RakeTask.new

task default: %i[rubocop test]
