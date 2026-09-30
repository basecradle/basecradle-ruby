# frozen_string_literal: true

require "test_helper"
require "yaml"
require "tmpdir"
require "open3"

# ci.yml's actionlint job computes its own file set in shell, which makes it the one CI
# guard in this repo whose *inputs* are derived at run time rather than written down. Two
# ways that has failed open (#210), both one-line-reversible and both green in the tree:
#
#   * actionlint given no paths lints every workflow it can find. So an empty path set does
#     not make the blocking step a no-op — it inverts it into "lint everything, the
#     capital's shared stubs included", as a blocking check on files this repo may not edit
#     (CLAUDE.md → Repo sovereignty). It fails *into* wedging every PR here.
#   * the advisory step is `continue-on-error`, which cannot tell a clean run from one that
#     died on a path that no longer exists — so a stub the capital renames takes the whole
#     step down with it, and the stub still present stops being linted too, silently.
#
# Neither is expressible as an assertion about the YAML: both live in the shell's behaviour.
# So this file *runs* the shell ci.yml actually ships, read out of the file, against a
# throwaway tree with a recording stand-in for actionlint — the same stance the refusal
# messages in serialization_test.rb take, where the remedy a message prescribes is executed
# rather than string-matched. A guard whose test only greps for its own source line is a
# guard that passes when someone rewrites it wrongly.
#
# Sits at test/ rather than test/basecradle/ for the same reason ci_workflow_test.rb does:
# it tests a repo-level file, not one under lib/basecradle/.
class ActionlintJobTest < Minitest::Test
  WORKFLOW = File.expand_path("../.github/workflows/ci.yml", __dir__)

  # The steps are located by name, not by index: reordering the job must stay green, while
  # losing a step must not.
  BLOCKING = "Lint the workflows this repo owns"
  ADVISORY = "Lint the capital's shared stubs (advisory)"

  # The capital's verbatim shared artifacts, which the blocking step must never lint and the
  # advisory step must always account for.
  STUBS = %w[needs-human-alert.yml dependabot-auto-merge.yml].freeze
  OWNED = %w[ci.yml release.yml].freeze

  def teardown
    FileUtils.remove_entry(@tree) if @tree && File.directory?(@tree)
    @tree = nil
  end

  # --- the blocking step: an empty path set must never reach actionlint ---

  def test_the_blocking_step_refuses_an_empty_path_set
    run = run_step(BLOCKING, workflows: [])

    refute run.ran_actionlint?,
           "with no workflow files on disk the blocking step still invoked actionlint, " \
           "and actionlint given no paths lints every workflow it can find — including " \
           "the capital's stubs, as a blocking check on files this repo may not edit. " \
           "It must refuse instead."
    refute_equal 0, run.status, "the refusal must fail the step, not just log"
    assert_includes run.output, "::error::", "the refusal must annotate the run"
  end

  # The reachable shape of the above: a checkout that produced only some of the tree. The
  # stubs are excluded by name, so a run holding nothing but stubs has an empty *owned* set
  # while `.github/workflows` is not empty at all.
  def test_the_blocking_step_refuses_when_every_file_present_is_one_it_must_not_lint
    run = run_step(BLOCKING, workflows: STUBS)

    refute run.ran_actionlint?,
           "the blocking step invoked actionlint with only the capital's stubs on disk. " \
           "They are excluded from its path list, so the list was empty — and an empty " \
           "list is precisely what makes actionlint lint them anyway."
    refute_equal 0, run.status
  end

  def test_the_blocking_step_lints_what_this_repo_owns_and_not_the_stubs
    run = run_step(BLOCKING, workflows: OWNED + STUBS)

    assert_equal OWNED.sort, run.linted,
                 "the blocking step must lint exactly the workflows this repo owns"
    assert_equal 0, run.status
  end

  # --- the advisory step: a stub that is not there must be a finding, not a silence ---

  # The one property of this step that is not in its shell. A step is skipped when an
  # earlier step in the job fails, so without `if: always()` any actionlint finding in the
  # blocking step above silently takes the stubs' check down with it — the same swallowed
  # non-zero the rest of this step is hardened against, arriving from outside it. Safe
  # because the step is `continue-on-error`: it cannot reach the gate either way.
  def test_the_advisory_step_runs_even_when_the_blocking_step_has_failed
    step = advisory_step

    assert_equal "always()", step["if"],
                 "the #{ADVISORY.inspect} step must carry `if: always()` (found " \
                 "#{step["if"].inspect}). Without it a finding in the blocking step above " \
                 "skips this one, and the capital's stubs go unchecked on exactly the runs " \
                 "something was already wrong."
    assert step["continue-on-error"],
           "if: always() is only safe here while the step stays advisory — it must not be " \
           "able to fail the CI gate over a file this repo may not edit."
  end

  def test_the_advisory_step_reports_a_missing_stub_and_still_lints_the_other
    run = run_step(ADVISORY, workflows: OWNED + [ STUBS.last ])

    assert_includes run.output, "needs-human-alert",
                    "a shared stub that is not on disk must be named in the log — " \
                    "`continue-on-error` cannot otherwise tell this from a clean run"
    assert_includes run.output, "::error::"
    assert_equal [ STUBS.last ], run.linted,
                 "the stub that IS present must still be linted; the whole defect was one " \
                 "missing path taking the other down with it"
    refute_equal 0, run.status,
                 "the script must exit non-zero when a stub is missing, even though the " \
                 "other linted clean. The step is `continue-on-error`, so GitHub calls it " \
                 "a success either way — what this pins is that one missing stub reads " \
                 "the same as two in the log, rather than the likely case (a rename hits " \
                 "one artifact at a time) looking like a clean run"
  end

  def test_the_advisory_step_never_runs_actionlint_with_no_paths_either
    run = run_step(ADVISORY, workflows: OWNED)

    refute run.ran_actionlint?,
           "with no stub on disk the advisory step invoked actionlint with an empty path " \
           "list, which lints every workflow in the repo — the blocking step's hazard, in " \
           "the step that exists to keep the stubs out of it"
    refute_equal 0, run.status
  end

  # The blocking step excludes stubs by name *without* extension, so a stub propagated as
  # `.yaml` is skipped there. If this step looked only for `.yml` it would call that stub
  # missing while the file sat on disk, linted by neither step.
  def test_the_advisory_step_finds_a_stub_under_either_extension
    run = run_step(ADVISORY, workflows: OWNED + [ "needs-human-alert.yaml", STUBS.last ])

    assert_equal [ "dependabot-auto-merge.yml", "needs-human-alert.yaml" ], run.linted
    assert_equal 0, run.status, "a stub present under .yaml is present, not missing"
  end

  # Mid-rename both spellings can be on disk. Keeping only one would leave a live workflow
  # that GitHub will execute linted by neither step — blocking skips it by name.
  def test_the_advisory_step_lints_every_spelling_of_a_stub_that_is_on_disk
    run = run_step(ADVISORY, workflows: OWNED + [ "needs-human-alert.yml", "needs-human-alert.yaml", STUBS.last ])

    assert_includes run.linted, "needs-human-alert.yml"
    assert_includes run.linted, "needs-human-alert.yaml"
  end

  private
    Run = Struct.new(:status, :output, :linted) do
      def ran_actionlint? = !linted.nil?
    end

    # The named step's `run:` script, executed against a throwaway `.github/workflows`, with
    # a recording script standing in for actionlint on $RUNNER_TEMP. `bash -e` matches the
    # shell GitHub gives a `run:` block, so a guard that works only without `set -e` fails
    # here too.
    def run_step(name, workflows:)
      @tree = Dir.mktmpdir("actionlint-job-test")
      runner_temp = File.join(@tree, "runner-temp")
      FileUtils.mkdir_p([ File.join(@tree, ".github", "workflows"), runner_temp ])
      workflows.each do |file|
        File.write(File.join(@tree, ".github", "workflows", file), "name: x\non: push\njobs: {}\n")
      end
      recorder = File.join(runner_temp, "actionlint")
      File.write(recorder, %(#!/bin/sh\necho "LINTED:$*"\n))
      File.chmod(0o755, recorder)

      output, status = Open3.capture2e(
        { "RUNNER_TEMP" => runner_temp }, "bash", "-e", "-c", script(name), chdir: @tree
      )
      Run.new(status.exitstatus, output, linted_paths(output))
    end

    # The paths the recorder was handed, basenames only — or nil when it was never called.
    # An invocation with no paths at all reads as `[]`, which is the hazard, not an absence.
    def linted_paths(output)
      line = output[/^LINTED:(.*)$/, 1]
      return nil unless line

      line.split.reject { |argument| argument.start_with?("-") }.map { |path| File.basename(path) }.sort
    end

    def advisory_step = step(ADVISORY)

    def script(name) = step(name).fetch("run")

    def step(name)
      steps = YAML.safe_load(File.read(WORKFLOW)).fetch("jobs").fetch("actionlint").fetch("steps")
      found = steps.find { |candidate| candidate["name"] == name }
      flunk "ci.yml's actionlint job has no step named #{name.inspect}" if found.nil?
      found
    end
end
