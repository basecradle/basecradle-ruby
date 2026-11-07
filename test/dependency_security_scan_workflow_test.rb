# frozen_string_literal: true

require "test_helper"
require "yaml"

# The daily dependency security scan's workflow (#267) only runs the tested decisions in
# script/dependency_security_scan.rb and applies their plan. What it can still get wrong is
# who it acts as and when it stays quiet, and each of those fails silently: a label applied
# with GITHUB_TOKEN starts no workflow, so a needs-human page never fires and the run is
# green; a heartbeat pinged on a scan that reached no verdict says yes to a question nobody
# answered. These pin that half.
#
# Sits at test/ beside ci_workflow_test.rb, for the same reason: it tests a repo-level file.
class DependencySecurityScanWorkflowTest < Minitest::Test
  WORKFLOWS = File.expand_path("../.github/workflows", __dir__)
  APP_TOKEN = "${{ steps.app-token.outputs.token }}"

  def test_every_step_that_talks_to_github_acts_as_the_basecradle_ai_app
    talking = steps.select { |step| step["run"].to_s.match?(/\bgh /) }

    assert_equal [ "Read the open issues", "File what the scan found" ], talking.map { |step| step["name"] }
    talking.each { |step| assert_equal APP_TOKEN, step.dig("env", "GH_TOKEN"), step["name"] }
    refute_match(/secrets\.GITHUB_TOKEN|github\.token/, File.read(workflow_path))
  end

  def test_the_app_token_is_minted_from_the_org_secrets_and_scoped_to_issues
    mint = steps.find { |step| step["id"] == "app-token" }

    assert_match %r{\Aactions/create-github-app-token@}, mint["uses"]
    assert_equal({ "app-id" => "${{ secrets.BASECRADLE_AI_APP_ID }}",
                   "private-key" => "${{ secrets.BASECRADLE_AI_APP_PRIVATE_KEY }}",
                   "permission-issues" => "write" }, mint["with"])
  end

  def test_it_runs_daily_and_by_hand_and_never_on_a_pull_request
    triggers = workflow[true] # YAML 1.1 reads the bare key `on` as true

    assert_equal [ "schedule", "workflow_dispatch" ], triggers.keys.sort
    assert_equal [ { "cron" => "37 14 * * *" } ], triggers["schedule"]
    assert_equal({ "contents" => "read" }, workflow["permissions"])
  end

  def test_the_heartbeat_is_pinged_only_on_a_verdict_and_a_missing_secret_is_loud
    ping = steps.find { |step| step.dig("env", "HEARTBEAT_URL") }

    assert_equal "${{ secrets.DEPENDENCY_SCAN_HEARTBEAT_URL }}", ping.dig("env", "HEARTBEAT_URL")
    assert_includes ping["run"], 'test -n "$HEARTBEAT_URL" ||'
    assert_includes ping["run"], '= "error" ]; then'
    assert_operator steps.index(ping), :>, steps.index { |step| step["name"] == "File what the scan found" }, "pinged after the plan is applied"
    refute ping["continue-on-error"]
  end

  def test_the_run_is_red_unless_main_is_clean
    last = steps.last

    assert_equal %(test "$(jq -r '.verdict' "$RUNNER_TEMP/plan.json")" = "clean"), last["run"]
    refute last["if"], "it runs whenever the steps before it succeeded"
  end

  # Each Ruby resolves its own versions, because no lockfile is committed, so a gem only one
  # Ruby resolves is audited only if the scan resolves under that Ruby too. When the matrix
  # gains or drops a Ruby, the scan moves with it.
  def test_the_scan_resolves_under_every_ruby_ci_tests
    matrix = YAML.safe_load_file(File.join(WORKFLOWS, "ci.yml")).dig("jobs", "test", "strategy", "matrix", "ruby-version")
    setups = steps.select { |step| step["uses"].to_s.start_with?("ruby/setup-ruby@") }
    scan = steps.find { |step| step["name"] == "Scan" }

    assert_equal matrix.sort, setups.map { |step| step.dig("with", "ruby-version") }.sort
    setups.each do |setup|
      refute setup.dig("with", "bundler-cache"), "the scan resolves the Gemfile itself, so a failed resolution is filed"
      variable = scan["env"].key("${{ steps.#{setup["id"]}.outputs.ruby-prefix }}")
      assert variable, "the Ruby #{setup.dig("with", "ruby-version")} prefix reaches the scan"
      assert_includes scan["run"], %(--ruby "$#{variable}")
    end
  end

  def test_the_scan_reads_who_wrote_each_open_issue
    read = steps.find { |step| step["name"] == "Read the open issues" }

    assert_includes read["run"], "--json number,title,body,author"
  end

  private
    def workflow_path
      File.join(WORKFLOWS, "dependency-security-scan.yml")
    end

    def workflow
      @workflow ||= YAML.safe_load_file(workflow_path)
    end

    def steps
      workflow.dig("jobs", "scan", "steps")
    end
end
