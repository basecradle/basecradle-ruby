# frozen_string_literal: true

# The gemspec's `required_ruby_version` is the Ruby floor and the one source of truth for it
# (#281, #318). Its copies (the README, .rubocop.yml, ci.yml's matrix, release.yml's
# rehearsal) are held equal to it by ci_workflow_test.rb and release_workflow_test.rb, and
# the scan's setups by dependency_security_scan_workflow_test.rb through the matrix. This
# reads the floor once, for all of them.
module RubyFloor
  GEMSPEC = File.expand_path("../../basecradle.gemspec", __dir__)

  # The floor as a Gem::Version. Raises when the requirement is anything but one `>=`,
  # because every check that compares against it assumes that shape.
  def self.version
    requirement = Gem::Specification.load(GEMSPEC).required_ruby_version
    unless requirement.requirements.map(&:first) == [ ">=" ]
      raise "basecradle.gemspec's required_ruby_version is #{requirement}; the floor checks read " \
            "a single `>=` floor. Teach test/support/ruby_floor.rb the new shape before changing that one."
    end
    requirement.requirements.first.last
  end
end
