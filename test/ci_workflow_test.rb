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
# Membership in `needs` is only the first door. A single required check can be defused from
# several sides, every one of them a one-line edit no review comment stands in front of, and
# every one ending in the same place — a red repo whose required check is not red. Each gets
# its own test below, in the order a reader meets them in ci.yml (#203):
#
#   * the gate depends on every job the workflow defines
#   * the gate job carries `if: always()`, so a red dependency cannot skip it
#   * the gate's step fails on every unsuccessful dependency result, not just `failure`
#   * the gate's step still runs `exit 1`, and is not `continue-on-error`
#   * no job the gate stands in for — itself included — sets job-level `continue-on-error`
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

  # The `needs.*.result` values the gate step must fail on. `success` is the only other one
  # GitHub can report, so naming these three is naming "anything but success".
  UNSUCCESSFUL_RESULTS = %w[failure cancelled skipped].freeze

  # The entire mechanism by which a dependency's result becomes a red required check.
  FAIL_COMMAND = "exit 1"

  # ci.yml, read strictly. `gate_key` below already takes this stance — it flunks "rather
  # than returning nil and failing obscurely inside a caller" — but the read feeding it did
  # not, and this file's whole subject is a required check that can be green without having
  # checked anything. Three states got past it, in rising order of how badly:
  #
  #   * an empty ci.yml, and a `jobs:` key with nothing under it, each reached a
  #     `NoMethodError` on nil. Those do name this file and this line, so the cost was a
  #     reader's minute, not a silent pass;
  #   * `jobs: {}` reached `gate_key` and flunked about the gate's *name*, for a workflow
  #     that defines nothing at all;
  #   * YAML that Psych's safe mode refuses raised a bare Psych backtrace under ten frames
  #     of psych internals, naming neither ci.yml nor the check it guards.
  #
  # That last construct is an **alias** (`*ref`) or an unquoted date — not an anchor: a bare
  # `&anchor` parses fine. Flunking on one rather than passing `aliases: true` is the
  # conservative side of a real choice, taken because this reader has never met an alias and
  # safe_load refuses them by default; opting in belongs to the PR that first needs one.
  def jobs
    @jobs ||= read_jobs
  end

  # Split out so the guards read as a sequence rather than as nested `begin`s. `flunk`
  # raises `Minitest::Assertion`, which descends from `Exception` and not `StandardError`,
  # so the method-level rescue below cannot swallow any of them.
  def read_jobs
    unless File.exist?(WORKFLOW)
      flunk "ci.yml does not exist at #{WORKFLOW}. Branch protection requires the " \
            "#{GATE_NAME.inspect} context this file produces, so with the file gone every " \
            "PR here waits on a check that can never report."
    end

    document = YAML.safe_load(File.read(WORKFLOW))
    unless document.is_a?(Hash)
      flunk "ci.yml did not parse as a YAML mapping (read as #{document.class}). An empty " \
            "file is the usual cause. Nothing below is checking the workflow that produces " \
            "the #{GATE_NAME.inspect} check."
    end

    job_definitions = document["jobs"]
    unless job_definitions.is_a?(Hash) && !job_definitions.empty?
      flunk "ci.yml defines no jobs (`jobs:` read as #{job_definitions.inspect}). Every " \
            "assertion below reads a job, and a workflow with no jobs produces no " \
            "#{GATE_NAME.inspect} check at all."
    end
    job_definitions
  rescue Psych::Exception, SystemCallError => e
    flunk "ci.yml could not be read: #{e.class} — #{e.message}. Psych's safe mode refuses " \
          "some YAML that is otherwise legal — an alias (`*ref`), an unquoted date — so " \
          "this may be a workflow that runs fine and that this reader cannot see into. " \
          "Either way nothing below is checking the file that produces the " \
          "#{GATE_NAME.inspect} check every PR here is gated on."
  end

  # The gate's job key. Flunks here rather than returning nil and failing obscurely inside
  # a caller. Minitest randomizes order, so every test that needs the gate goes through it.
  def gate_key
    @gate_key ||= begin
      keys = jobs.select { |key, job| (job["name"] || key) == GATE_NAME }.keys
      unless keys.size == 1
        flunk "ci.yml defines #{keys.size} jobs whose check context is #{GATE_NAME.inspect}" \
              "#{" (#{keys.join(', ')})" unless keys.empty?}. Branch protection requires " \
              "exactly one status check by that name; with none, no PR in this repo has a " \
              "required check at all."
      end
      keys.first
    end
  end

  # The whole point of the gate: it stands in for the entire workflow, so it must depend on
  # the entire workflow. Equality, not containment — a `needs` entry naming a job that no
  # longer exists is the same bug from the other side, and GitHub refuses to run a workflow
  # whose `needs` names an undefined job, so CI stops running rather than running wrong.
  def test_the_gate_requires_every_other_job_the_workflow_defines
    defined_jobs = jobs.keys - [ gate_key ]
    needed = needs(jobs.fetch(gate_key))

    assert_equal defined_jobs.sort, needed.sort,
                 "ci.yml's #{GATE_NAME} gate must depend on exactly the other jobs this " \
                 "workflow defines — it is the single required status check, so a job " \
                 "outside its `needs` is advisory whatever it reports. " \
                 "#{diagnose(defined_jobs, needed)}"
  end

  # Depending on every job is worthless if the gate does not run. A job whose `needs` has a
  # failure is *skipped* by default, not failed — so without `always()` the gate is skipped
  # the moment anything under it goes red, the required check reports `skipped`, and branch
  # protection treats a skipped required check as passing. Every PR then merges over red CI,
  # and nothing in the run announces it: the gate is simply grey. ci.yml's own comment names
  # this hazard for *dependencies*; the gate is exposed to it too, and one deleted line is
  # the whole distance.
  def test_the_gate_runs_even_when_a_job_under_it_fails
    condition = jobs.fetch(gate_key)["if"]

    assert_equal "always()", unwrap(condition),
                 "ci.yml's #{GATE_NAME} gate must carry `if: always()` (found " \
                 "#{condition.inspect}). Without it GitHub skips the gate whenever a job " \
                 "in its `needs` fails, the required check reports `skipped`, and branch " \
                 "protection passes a skipped check — so every PR merges over red CI. " \
                 "Anything narrower than a bare `always()` reintroduces that: a condition " \
                 "the gate can fail to satisfy is a required check that can go missing."
  end

  # The gate runs and depends on everything — and then its one step has to actually fail.
  # Three separate edits defuse that step without touching the `needs` list above, so each
  # gets its own assertion: narrowing which results it fires on, replacing what it runs, and
  # making it non-fatal.
  #
  # The condition is compared as the *set* of its top-level `||` disjuncts, never by
  # substring. A condition that merely mentions all three values can still fail open:
  # joining them with `&&` fires only when all three happen in one run, which is to say
  # never, and a leading `!` inverts the whole test. Whitespace is dropped, so a spelling
  # with no space after the comma passes; order is not significant, so any arrangement of
  # the three does.
  def test_the_gate_step_fails_on_every_unsuccessful_dependency_result
    found = disjuncts(unwrap(gate_step["if"]))
    expected = UNSUCCESSFUL_RESULTS.map { |result| "contains(needs.*.result,'#{result}')" }

    assert_equal expected.sort, found.sort,
                 "ci.yml's #{GATE_NAME} gate step must fail on exactly the unsuccessful " \
                 "dependency results #{UNSUCCESSFUL_RESULTS.join(', ')}, as a plain `||` " \
                 "of `contains(needs.*.result, …)` terms. A result it does not name leaves " \
                 "the gate green over a job that did not succeed — `skipped` most " \
                 "dangerously, since a job GitHub never ran cannot have checked anything — " \
                 "and joining the terms with `&&`, or negating them, fails open while " \
                 "still mentioning all three. Read: #{found.inspect}"
  end

  def test_the_gate_step_still_fails_the_run
    command = gate_step["run"].to_s.strip

    assert_equal FAIL_COMMAND, command,
                 "ci.yml's #{GATE_NAME} gate step must run `#{FAIL_COMMAND}` (found " \
                 "#{command.inspect}). The condition above decides *when* the gate should " \
                 "fail; this line is the only thing that makes it fail. A step that exits " \
                 "0 leaves the required check green with every condition and every `needs` " \
                 "entry still correctly in place."
  end

  def test_the_gate_step_is_not_advisory
    refute gate_step["continue-on-error"],
           "ci.yml's #{GATE_NAME} gate step sets `continue-on-error`, so its " \
           "`#{FAIL_COMMAND}` no longer fails the job: the required check reports success " \
           "with a red job underneath. The key is legitimate on the actionlint advisory " \
           "step, which is outside the gate; on the gate's own step it disables the gate."
  end

  # And the last door: `continue-on-error: true` at *job* level. A job carrying it reports
  # `success` into the `needs` context even when its steps failed, so
  # `contains(needs.*.result, 'failure')` is false and the gate passes over a red job —
  # with the `needs` membership the first test pins completely untouched. ci.yml already
  # uses this key on the actionlint advisory *step*, where it is correct and deliberate, so
  # one copy-paste up to job level is the whole distance; only job level is read here.
  #
  # The gate itself is in scope alongside its dependencies: job-level `continue-on-error`
  # on the gate swallows its own `exit 1`, which is the same fail-open one layer up.
  def test_no_job_the_gate_stands_in_for_swallows_its_own_failure
    scoped = ([ gate_key ] + needs(jobs.fetch(gate_key))).uniq
    swallowing = scoped.select { |key| jobs[key] && jobs[key]["continue-on-error"] }

    assert_empty swallowing,
                 "ci.yml sets job-level `continue-on-error` on #{swallowing.join(', ')}. " \
                 "A job with it reports `success` into the `needs` context however its " \
                 "steps exited, so the #{GATE_NAME} gate — the single required status " \
                 "check — goes green with a red job underneath, while staying in `needs` " \
                 "and looking wired up. An advisory *step* inside a job is fine; an " \
                 "advisory job is a job outside CI. If one is ever genuinely wanted, that " \
                 "is a decision to take deliberately, not a key to inherit by copy-paste."
  end

  private
    # `needs:` accepts a bare string as well as a list.
    def needs(job)
      Array(job["needs"])
    end

    # `always()` and `${{ always() }}` are the same expression to GitHub, and a workflow
    # may spell a condition either way, so the wrapper is stripped before comparing. Only
    # the wrapper — the expression inside is compared verbatim, so a *narrowed* condition
    # (`always() && github.event_name == 'pull_request'`) still fails.
    def unwrap(condition)
      condition.to_s.strip.sub(/\A\$\{\{(.*)\}\}\z/m) { ::Regexp.last_match(1) }.strip
    end

    # A condition's top-level `||` terms, whitespace removed so only structure is compared.
    def disjuncts(condition)
      condition.split("||").map { |term| term.gsub(/\s+/, "") }
    end

    # The gate is a one-step job by design — one condition, one `exit 1`. More than
    # one step means the shape these assertions read has changed, so it flunks with an
    # instruction rather than guessing which step is the gate.
    def gate_step
      @gate_step ||= begin
        steps = Array(jobs.fetch(gate_key)["steps"])
        unless steps.size == 1
          flunk "ci.yml's #{GATE_NAME} gate defines #{steps.size} steps; the assertions " \
                "here read the single step that fails the gate and cannot tell which one " \
                "that is. Keep the gate a one-step job, or teach this test which step " \
                "decides."
        end
        steps.first
      end
    end

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
