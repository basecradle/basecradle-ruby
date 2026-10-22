# frozen_string_literal: true

require "test_helper"
require "yaml"
require "tmpdir"
require "open3"

# Fleet Identity: a commit authored by this repo's bot carries no Co-Authored-By trailer.
# The session's attribution reminder restates the opposite default every session, and armed
# auto-merge squashes onto `main` within minutes, where nothing is ever force-pushed — so
# ci.yml's `trailers` job checks it on the PR (ported from basecradle-python, dispatched
# in this repo's #240).
#
# Every way that check can be wrong is in its shell — which commits it walks, whose it
# reads, how much of each message — so, like actionlint_job_test.rb, this file *runs* the
# shell ci.yml ships, read out of the file, against a throwaway git repository built per
# test. A guard whose test only greps for its own source line passes when someone rewrites
# the guard wrongly.
#
# Membership in the CI gate's `needs` is ci_workflow_test.rb's to pin, not this file's.
#
# Sits at test/ rather than test/basecradle/ for the same reason ci_workflow_test.rb does:
# it tests a repo-level file, not one under lib/basecradle/.
class CommitTrailersJobTest < Minitest::Test
  WORKFLOW = File.expand_path("../.github/workflows/ci.yml", __dir__)
  CHARTER = File.expand_path("../CLAUDE.md", __dir__)
  STEP = "No Co-Authored-By on bot commits"

  HUMAN = [ "John Doe", "john@example.com" ].freeze
  TRAILER = "Co-Authored-By: Nova Digital <nova@example.com>"

  def setup
    @tree = Dir.mktmpdir("commit-trailers-job-test")
    git "init", "-q", "-b", "main"
    File.write(File.join(@tree, "CLAUDE.md"), "Commits are authored by `#{bot}`.\n")
    commit "Seed the repository", author: HUMAN
    @base = rev_parse("HEAD")
    git "switch", "-q", "-c", "feature"
  end

  def teardown
    FileUtils.remove_entry(@tree) if @tree && File.directory?(@tree)
    @tree = nil
  end

  # --- what the job looks at ---

  def test_a_bot_commit_without_a_trailer_passes
    commit "Add a resource", author: bot_author

    run = run_step

    assert_equal 0, run.status, run.output
  end

  def test_a_bot_commit_with_a_trailer_fails_and_names_the_commit
    commit "Add a resource\n\n#{TRAILER}", author: bot_author

    run = run_step

    refute_equal 0, run.status, "a bot commit carrying a Co-Authored-By trailer must fail the step"
    assert_includes run.output, "::error::", "the finding must annotate the run"
    assert_includes run.output, "Add a resource", "the annotation must name the offending commit"
  end

  # git's %(trailers) parses only the final paragraph, so a trailer followed by any further
  # paragraph is invisible to it. The job scans every line of the message instead.
  def test_a_trailer_that_is_not_in_the_last_paragraph_still_fails
    commit "Add a resource\n\n#{TRAILER}\n\nA closing paragraph after the trailer.", author: bot_author

    refute_equal 0, run_step.status,
                 "a trailer with a paragraph after it slipped through — the scan must be " \
                 "line-anchored over the whole message, not git's trailer parser"
  end

  # Under pipefail, `printf "$message" | grep -q` fails open: grep exits on its first match,
  # printf dies of SIGPIPE writing the rest of a message longer than the pipe buffer, and the
  # pipeline's non-zero reads as "no trailer". A pasted log is enough to get there.
  def test_a_trailer_early_in_a_message_longer_than_the_pipe_buffer_still_fails
    commit "Add a resource\n\n#{TRAILER}\n\n#{"A pasted log line.\n" * 20_000}", author: bot_author

    refute_equal 0, run_step.status,
                 "a trailer near the top of a long message slipped through — the message " \
                 "must reach grep without a pipe that pipefail can turn into a pass"
  end

  def test_the_match_ignores_case
    commit "Add a resource\n\n#{TRAILER.downcase}", author: bot_author

    refute_equal 0, run_step.status, "`co-authored-by:` is the same trailer to GitHub"
  end

  def test_every_offending_commit_is_reported_not_just_the_first
    commit "First change\n\n#{TRAILER}", author: bot_author
    commit "Second change\n\n#{TRAILER}", author: bot_author

    run = run_step

    assert_includes run.output, "First change"
    assert_includes run.output, "Second change"
  end

  # --- what it must leave alone ---

  # The rule binds the bot's own commits. A human's co-author line is that human's call.
  def test_a_human_commit_with_a_trailer_passes
    commit "Pair on the README\n\n#{TRAILER}", author: HUMAN

    assert_equal 0, run_step.status, "only commits authored by #{bot} are this rule's business"
  end

  # GitHub's squash-merge writes a self-co-author trailer onto main's commits, which can
  # never be rewritten. A branch that merged main in must not re-litigate them.
  def test_commits_already_on_the_base_branch_are_not_examined
    git "switch", "-q", "main"
    commit "Squash-merged earlier\n\n#{TRAILER}", author: bot_author
    git "update-ref", "refs/remotes/origin/main", "HEAD"
    git "switch", "-q", "feature"
    git "merge", "-q", "--no-edit", "main"
    commit "Add a resource", author: bot_author

    run = run_step

    assert_equal 0, run.status,
                 "a commit reachable from the live base branch was examined — the walk must " \
                 "exclude refs/remotes/origin/<base>, not only the event's base sha\n#{run.output}"
  end

  # --- its own failure modes ---

  # The author filter matches on the identity CLAUDE.md states. If the two drift apart the
  # filter matches nothing and every commit passes, so the drift itself must fail.
  def test_an_identity_the_charter_no_longer_states_fails_instead_of_passing_everything
    File.write(File.join(@tree, "CLAUDE.md"), "Commits are authored by someone else.\n")
    commit "Add a resource", author: bot_author

    run = run_step

    refute_equal 0, run.status
    assert_includes run.output, "::error::"
  end

  def test_the_identity_the_job_checks_is_the_one_this_charter_states
    assert_includes File.read(CHARTER), bot,
                    "ci.yml's trailers job checks commits by #{bot.inspect}, which CLAUDE.md " \
                    "→ Fleet Identity no longer names"
  end

  # The job also runs on pushes to main, where the base range is meaningless and main's own
  # squash commits carry GitHub's trailer. Skipping the job would fail the CI gate, so each
  # step is gated on the event instead.
  def test_every_step_runs_only_on_pull_requests
    steps.each do |step|
      assert_equal "github.event_name == 'pull_request'", step["if"],
                   "step #{(step["name"] || step["uses"]).inspect} must be gated to pull_request " \
                   "events — on a push to main it would read GitHub's own squash trailers"
    end
  end

  private
    Run = Struct.new(:status, :output)

    # The step's `run:` script, with the env ci.yml gives it. `bash -e` matches the shell
    # GitHub gives a `run:` block.
    def run_step
      env = step.fetch("env").slice("BOT").merge(
        "BASE_REF" => "main", "BASE_SHA" => @base, "HEAD_SHA" => rev_parse("HEAD")
      )
      output, status = Open3.capture2e(git_env.merge(env), "bash", "-e", "-c", step.fetch("run"), chdir: @tree)
      Run.new(status.exitstatus, output)
    end

    def bot = step.fetch("env").fetch("BOT")

    def bot_author = [ bot, "290978458+#{bot}@users.noreply.github.com" ]

    def commit(message, author:)
      name, email = author
      File.write(File.join(@tree, "change.txt"), "#{message}\n", mode: "a")
      git "add", "-A"
      # On stdin, not argv: one test's message is longer than an argument may be.
      git "commit", "-q", "-F", "-", stdin: message,
          env: { "GIT_AUTHOR_NAME" => name, "GIT_AUTHOR_EMAIL" => email }
    end

    def rev_parse(ref) = git("rev-parse", ref).strip

    def git(*args, env: {}, stdin: "")
      output, status = Open3.capture2e(git_env.merge(env), "git", *args, chdir: @tree, stdin_data: stdin)
      flunk "git #{args.join(" ")} failed:\n#{output}" unless status.success?
      output
    end

    # Isolated from the machine's git config, so a signing hook or a default branch name
    # set by whoever runs the suite cannot change what is being tested. Every commit is
    # John Doe's unless `commit` names another author — merge commits included.
    def git_env
      {
        "GIT_CONFIG_GLOBAL" => File::NULL, "GIT_CONFIG_NOSYSTEM" => "1",
        "GIT_AUTHOR_NAME" => HUMAN[0], "GIT_AUTHOR_EMAIL" => HUMAN[1],
        "GIT_COMMITTER_NAME" => HUMAN[0], "GIT_COMMITTER_EMAIL" => HUMAN[1]
      }
    end

    def step
      found = steps.find { |candidate| candidate["name"] == STEP }
      flunk "ci.yml's trailers job has no step named #{STEP.inspect}" if found.nil?
      found
    end

    def steps = YAML.safe_load(File.read(WORKFLOW)).fetch("jobs").fetch("trailers").fetch("steps")
end
