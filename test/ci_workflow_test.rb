# frozen_string_literal: true

require "test_helper"
require "yaml"

# Branch protection requires exactly one status check: the context named "CI", produced by
# ci.yml's gate job, which succeeds only when every job in its `needs` list succeeded. That
# list is hand-maintained. A job added to ci.yml and not added to it runs on every PR, goes
# red, and merges anyway — the red job is not the required check, and the gate never waited
# for it. It looks exactly like working CI. (`actionlint` was added to that list in #194 on
# memory alone; this is the pin that would have caught a forgotten edit. Asked for in #200.)
#
# The limit of this file: it proves ci.yml is internally consistent. The other half of the
# gate — that the "Protect main" ruleset requires this workflow's context and no other —
# lives in repo settings, is invisible to any test in the tree, and is not pinned here.
#
# Sits at test/ rather than test/basecradle/ for the same reason changelog_test.rb and
# readme_test.rb do: it tests a repo-level file, not a file under lib/basecradle/.
class CiWorkflowTest < Minitest::Test
  WORKFLOW = File.expand_path("../.github/workflows/ci.yml", __dir__)

  # The gate is found by the *check context* branch protection names, not by its job key:
  # the ruleset requires the context "CI", and for a non-matrix job the context is the
  # job's `name` — which GitHub defaults to the job key when `name:` is omitted. So a
  # rename of either that keeps the context works, while dropping the context entirely —
  # which silently removes the required check from every PR — fails here.
  GATE_NAME = "CI"

  def jobs
    @jobs ||= YAML.safe_load(File.read(WORKFLOW)).fetch("jobs")
  end

  # The gate's job key. Flunks here rather than returning nil and failing obscurely inside
  # a caller. Minitest randomizes order, so every test that needs the gate goes through it.
  def gate_key
    keys = jobs.select { |key, job| (job["name"] || key) == GATE_NAME }.keys
    return keys.first if keys.size == 1

    flunk "ci.yml defines #{keys.size} jobs whose check context is #{GATE_NAME.inspect}" \
          "#{" (#{keys.join(', ')})" unless keys.empty?}. Branch protection requires exactly " \
          "one status check by that name; with none, no PR in this repo has a required " \
          "check at all."
  end

  # The whole point of the gate: it stands in for the entire workflow, so it must depend on
  # the entire workflow. Equality, not containment — a `needs` entry naming a job that no
  # longer exists is the same bug from the other side, and GitHub refuses to run a workflow
  # whose `needs` names an undefined job, so CI stops running rather than running wrong.
  #
  # Membership is all that needs pinning. The gate already fails on a dependency that was
  # *skipped* as well as one that failed or was cancelled (`contains(needs.*.result,
  # 'skipped')`), which is the safe direction — a job that did not run cannot wave a PR
  # through — so that half needs no second assertion.
  def test_the_gate_requires_every_other_job_the_workflow_defines
    defined_jobs = jobs.keys - [ gate_key ]
    # `needs:` accepts a bare string as well as a list.
    needed = Array(jobs.fetch(gate_key)["needs"])

    assert_equal defined_jobs.sort, needed.sort,
                 "ci.yml's #{GATE_NAME} gate must depend on exactly the other jobs this " \
                 "workflow defines — it is the single required status check, so a job " \
                 "outside its `needs` is advisory whatever it reports. " \
                 "#{diagnose(defined_jobs, needed)}"
  end

  private
    # Spells out *which* direction the mismatch runs in, so the failure reads as an
    # instruction rather than an array diff. Set difference hides a repeated entry (which
    # fails the sorted comparison while both differences come back empty), so duplicates
    # are named separately.
    def diagnose(defined_jobs, needed)
      unlisted = defined_jobs - needed
      phantom = needed - defined_jobs
      repeated = needed.tally.select { |_, count| count > 1 }.keys

      detail = []
      unless unlisted.empty?
        detail << "Defined but not in `needs`, so #{unlisted.join(', ')} can go red while " \
                  "the PR still merges green: add #{unlisted.size == 1 ? 'it' : 'them'} to " \
                  "the gate."
      end
      unless phantom.empty?
        detail << "In `needs` but not defined here: #{phantom.join(', ')}. GitHub refuses " \
                  "to run a workflow whose `needs` names an undefined job, so CI does not " \
                  "run at all."
      end
      detail << "Listed in `needs` more than once: #{repeated.join(', ')}." unless repeated.empty?
      detail.join(" ")
    end
end
