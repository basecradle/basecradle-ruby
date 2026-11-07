# frozen_string_literal: true

require "test_helper"
require_relative "../script/dependency_security_scan"

# The daily dependency security scan's decisions (#267): what it reads as a verdict, what it
# files, and what it routes to whom. The workflow only applies the plan these tests pin, so
# a wrong decision here is a page that never fires or one that fires every day.
#
# Ported from the core repository's suite (basecradle/basecradle#750), less the JavaScript
# half this repository has no use for, plus what a gem repository adds: a resolution that
# fails is no verdict.
#
# Sits at test/ rather than test/basecradle/ because it tests repository tooling under
# script/, not the SDK under lib/basecradle/.
class DependencySecurityScanTest < Minitest::Test
  Scan = DependencySecurityScan

  # --- reading bundler-audit -------------------------------------------------------------

  def test_reads_a_bundler_audit_report_into_advisories
    advisory = sole(Scan.parse_bundler_audit(audit_json(gem_result("activesupport", "GHSA-f3w6-w445-fwh9", "critical")), 1))

    assert_equal "gem", advisory.ecosystem
    assert_equal "activesupport", advisory.package
    assert_equal "8.1.4", advisory.affected
    assert_equal "GHSA-f3w6-w445-fwh9", advisory.id
    assert_equal "critical", advisory.severity
    assert_equal "gem:activesupport:GHSA-f3w6-w445-fwh9", advisory.key
    assert advisory.pages?
  end

  def test_a_clean_bundler_audit_report_is_no_advisories
    assert_empty Scan.parse_bundler_audit(audit_json, 0)
  end

  def test_an_unrated_advisory_is_unknown_and_does_not_page
    advisory = sole(Scan.parse_bundler_audit(audit_json(gem_result("rack", "GHSA-aaaa-bbbb-cccc", nil)), 1))

    assert_equal "unknown", advisory.severity
    refute advisory.pages?
  end

  def test_an_insecure_source_is_a_finding_known_by_its_type
    result = { "type" => "insecure_source", "source" => "http://gems.example.com/" }
    advisory = sole(Scan.parse_bundler_audit(audit_json(result), 1))

    assert_equal "gem:http://gems.example.com/:insecure_source", advisory.key
    assert_equal "Insecure gem source", advisory.title
    assert_equal "unknown", advisory.severity
  end

  def test_bundler_audit_output_that_is_not_a_verdict_raises_never_reads_as_clean
    assert_raises(Scan::ScanError) { Scan.parse_bundler_audit("", 1) }
    assert_raises(Scan::ScanError) { Scan.parse_bundler_audit("Could not reach github.com", 128) }
    assert_raises(Scan::ScanError) { Scan.parse_bundler_audit(audit_json, 1) }
    assert_raises(Scan::ScanError) { Scan.parse_bundler_audit(audit_json(gem_result("rack", "GHSA-aaaa-bbbb-cccc", "low")), 0) }
    assert_raises(Scan::ScanError) { Scan.parse_bundler_audit(audit_json, 2) }
    assert_raises(Scan::ScanError) { Scan.parse_bundler_audit("[]", 0) }
    assert_raises(Scan::ScanError) { Scan.parse_bundler_audit("null", 0) }
    assert_raises(Scan::ScanError) { Scan.parse_bundler_audit('{"results":["text"]}', 1) }
  end

  # --- resolving what the Gemfile allows ---------------------------------------------------

  def test_a_resolution_that_failed_is_no_verdict
    assert_nil Scan.check_resolution(0)

    [ 1, 15, nil ].each do |status|
      error = assert_raises(Scan::ScanError, status.inspect) { Scan.check_resolution(status) }
      assert_includes error.message, "bundle lock could not resolve"
    end
    error = assert_raises(Scan::ScanError) { Scan.check_resolution(4, bundle: "/opt/ruby-3.4/bin/bundle") }
    assert_includes error.message, "/opt/ruby-3.4/bin/bundle lock could not resolve", "and says which Ruby"
  end

  def test_one_advisory_found_under_several_rubies_is_one_finding_listing_every_version
    under_3_2 = advisory("parallel", "GHSA-1111-2222-3333", "high").with(affected: "1.27.0")
    under_3_4 = advisory("parallel", "GHSA-1111-2222-3333", "high").with(affected: "2.0.1")
    other = advisory("rack", "GHSA-4444-5555-6666", "low")

    merged = Scan.merge([ under_3_2, other, under_3_4, under_3_2 ])

    assert_equal [ "gem:parallel:GHSA-1111-2222-3333", "gem:rack:GHSA-4444-5555-6666" ], merged.map(&:key)
    assert_equal "1.27.0, 2.0.1", merged.first.affected
    assert_equal "8.1.4", merged.last.affected
  end

  # --- what the scan does on GitHub --------------------------------------------------------

  def test_a_clean_scan_with_nothing_open_does_nothing
    scan = scan_of

    assert_equal "clean", scan.verdict
    assert_empty scan.plans([ unrelated_issue ])
  end

  def test_a_high_advisory_files_one_security_issue_that_pages
    plan = sole(scan_of(advisory("activesupport", "GHSA-1111-2222-3333", "high"), advisory("rack", "GHSA-4444-5555-6666", "low")).plans([ unrelated_issue ]))

    assert_equal "create", plan.action
    assert_equal Scan::ADVISORIES_TITLE, plan.title
    assert_equal [ "needs-human" ], plan.labels
    assert_includes plan.body, "**2 advisories**"
    assert_includes plan.body, "1 High, 1 Low"
    assert_includes plan.body, "0123abc"
    assert_operator plan.body.index("GHSA-1111-2222-3333"), :<, plan.body.index("GHSA-4444-5555-6666"), "most severe first"
  end

  def test_a_critical_advisory_pages
    assert_equal [ "needs-human" ], sole(scan_of(advisory("activesupport", "GHSA-f3w6-w445-fwh9", "critical")).plans([])).labels
  end

  def test_nothing_below_high_pages_it_goes_to_the_capitals_inbox
    %w[ medium moderate low none unknown ].each do |severity|
      plan = sole(scan_of(advisory("rack", "GHSA-4444-5555-6666", severity)).plans([]))

      assert_equal [ "needs-capital" ], plan.labels, severity
    end
  end

  def test_a_standing_finding_is_silent_no_second_issue_no_comment_no_label
    scan = scan_of(advisory("activesupport", "GHSA-1111-2222-3333", "high"))
    filed = sole(scan.plans([]))

    assert_empty scan.plans([ open_issue(filed) ])
  end

  def test_a_new_high_on_an_open_issue_updates_it_comments_and_pages
    filed = sole(scan_of(advisory("rack", "GHSA-4444-5555-6666", "low")).plans([]))
    plan = sole(scan_of(advisory("rack", "GHSA-4444-5555-6666", "low"), advisory("activesupport", "GHSA-1111-2222-3333", "high")).plans([ open_issue(filed) ]))

    assert_equal "update", plan.action
    assert_equal 812, plan.number
    assert_equal [ "needs-human" ], plan.labels
    assert_includes plan.comment, "New since the last scan (1 advisory: 1 High)"
    assert_includes plan.comment, "GHSA-1111-2222-3333"
    refute_includes plan.comment, "GHSA-4444-5555-6666"
    assert_includes plan.body, "GHSA-4444-5555-6666"
  end

  def test_a_new_low_on_an_issue_that_already_paged_does_not_page_again
    filed = sole(scan_of(advisory("activesupport", "GHSA-1111-2222-3333", "high")).plans([]))
    plan = sole(scan_of(advisory("activesupport", "GHSA-1111-2222-3333", "high"), advisory("rack", "GHSA-4444-5555-6666", "low")).plans([ open_issue(filed) ]))

    assert_equal [ "needs-capital" ], plan.labels
  end

  def test_an_advisory_rated_high_after_it_was_filed_lower_pages_then_and_the_issue_is_rewritten
    filed = sole(scan_of(advisory("activesupport", "GHSA-1111-2222-3333", "unknown")).plans([]))
    assert_equal [ "needs-capital" ], filed.labels

    plan = sole(scan_of(advisory("activesupport", "GHSA-1111-2222-3333", "critical")).plans([ open_issue(filed) ]))

    assert_equal "update", plan.action
    assert_equal [ "needs-human" ], plan.labels
    assert_includes plan.comment, "**Re-rated:** `gem:activesupport:GHSA-1111-2222-3333` Unknown → Critical"
    assert_includes plan.body, "| Critical |"
    assert_empty scan_of(advisory("activesupport", "GHSA-1111-2222-3333", "critical")).plans([ open_issue(plan) ]), "and is silent again after"
  end

  def test_a_rerating_that_does_not_reach_high_rewrites_the_issue_and_labels_nothing
    filed = sole(scan_of(advisory("activesupport", "GHSA-1111-2222-3333", "high")).plans([]))

    [ "medium", "critical" ].each do |severity|
      plan = sole(scan_of(advisory("activesupport", "GHSA-1111-2222-3333", severity)).plans([ open_issue(filed) ]))

      assert_equal "update", plan.action
      assert_empty plan.labels, "High → #{severity} is no new page"
    end
  end

  def test_an_advisory_that_stops_being_reported_is_noted_and_nothing_is_labeled
    filed = sole(scan_of(advisory("activesupport", "GHSA-1111-2222-3333", "high"), advisory("rack", "GHSA-4444-5555-6666", "low")).plans([]))
    plan = sole(scan_of(advisory("rack", "GHSA-4444-5555-6666", "low")).plans([ open_issue(filed) ]))

    assert_equal "update", plan.action
    assert_empty plan.labels
    assert_includes plan.comment, "No longer reported (1):** `gem:activesupport:GHSA-1111-2222-3333`"
    refute_includes plan.comment, "is clean"
  end

  def test_a_scan_that_comes_back_clean_says_so_once_and_never_closes_the_issue
    filed = sole(scan_of(advisory("activesupport", "GHSA-1111-2222-3333", "high")).plans([]))
    clean = scan_of
    plan = sole(clean.plans([ open_issue(filed) ]))

    assert_equal "update", plan.action
    assert_empty plan.labels
    assert_includes plan.comment, "is clean"
    assert_includes plan.comment, "Close this issue by hand"
    assert_empty clean.plans([ open_issue(plan) ]), "the next clean run is silent"
  end

  def test_an_issue_whose_marker_was_edited_away_is_treated_as_knowing_nothing
    plan = sole(scan_of(advisory("activesupport", "GHSA-1111-2222-3333", "high")).plans([ issue(Scan::ADVISORIES_TITLE, "rewritten by hand") ]))

    assert_equal "update", plan.action
    assert_equal [ "needs-human" ], plan.labels
  end

  def test_an_issue_the_app_did_not_write_is_never_the_scans
    forged = issue(Scan::ADVISORIES_TITLE, "<!-- dependency-security-scan {\"advisories\":{\"gem:rack:GHSA-4444-5555-6666\":\"critical\"}} -->", author: "someone", number: 900)
    plan = sole(scan_of(advisory("rack", "GHSA-4444-5555-6666", "critical")).plans([ forged ]))

    assert_equal "create", plan.action, "a look-alike cannot make a new advisory read as already known"
    assert_equal [ "needs-human" ], plan.labels
  end

  def test_a_look_alike_cannot_hide_the_real_issue
    real = sole(scan_of(advisory("rack", "GHSA-4444-5555-6666", "low")).plans([]))
    forged = issue(Scan::ADVISORIES_TITLE, "<!-- dependency-security-scan {} -->", author: "someone", number: 900)

    assert_empty scan_of(advisory("rack", "GHSA-4444-5555-6666", "low")).plans([ forged, open_issue(real) ])
    assert_empty scan_of(errors: { "gem" => "no verdict" }).plans([ issue(Scan::ERROR_TITLE, "", author: "someone"), open_issue(sole(scan_of(errors: { "gem" => "no verdict" }).plans([]))) ])
  end

  def test_an_issue_with_no_author_is_not_the_scans
    filed = sole(scan_of(advisory("rack", "GHSA-4444-5555-6666", "low")).plans([]))

    assert_equal "create", sole(scan_of(advisory("rack", "GHSA-4444-5555-6666", "low")).plans([ open_issue(filed).except("author") ])).action
  end

  # --- a scan that could not run -----------------------------------------------------------

  def test_a_scanner_that_reaches_no_verdict_files_one_issue_for_the_capital
    scan = scan_of(errors: { "gem" => "bundle lock could not resolve what the Gemfile and the gemspec allow (exit 15)" })
    plan = sole(scan.plans([]))

    assert_equal "error", scan.verdict
    assert_equal "create", plan.action
    assert_equal Scan::ERROR_TITLE, plan.title
    assert_equal [ "needs-capital" ], plan.labels
    assert_includes plan.body, "Ruby gem scan:** bundle lock could not resolve"
    assert_empty scan.plans([ open_issue(plan) ]), "one issue while it cannot run, not one a day"
  end

  def test_a_new_reason_for_the_same_failure_is_not_a_change
    filed = sole(scan_of(errors: { "gem" => "bundle lock could not resolve (exit 15)" }).plans([]))

    assert_empty scan_of(errors: { "gem" => "bundler-audit produced no readable report" }).plans([ open_issue(filed) ])
  end

  def test_a_scanner_failing_beside_an_old_marker_updates_the_issue_and_tells_the_capital_again
    plan = sole(scan_of(errors: { "gem" => "no readable report" }).plans([ issue(Scan::ERROR_TITLE, "edited by hand") ]))

    assert_equal "update", plan.action
    assert_equal [ "needs-capital" ], plan.labels
    assert_includes plan.comment, "Now failing: the Ruby gem scan"
    assert_includes plan.body, "Ruby gem scan:** no readable report"
  end

  def test_the_run_that_reaches_a_verdict_again_closes_the_could_not_run_issue
    filed = sole(scan_of(errors: { "gem" => "no verdict" }).plans([]))
    plan = sole(scan_of.plans([ open_issue(filed) ]))

    assert_equal "close", plan.action
    assert_equal 812, plan.number
    assert_includes plan.comment, "the clock is running again"
  end

  def test_a_failed_scanners_earlier_findings_are_carried_forward_never_reported_as_resolved
    filed = sole(scan_of(advisory("activesupport", "GHSA-1111-2222-3333", "high")).plans([]))
    scan = scan_of(errors: { "gem" => "bundler-audit produced no readable report" })

    assert_equal [ Scan::ERROR_TITLE ], scan.plans([ open_issue(filed) ]).map(&:title), "the advisories issue is left as it stands"
    assert_equal "error", scan.verdict
  end

  def test_a_carried_finding_stays_in_the_marker_when_the_body_is_rewritten
    filed = issue(Scan::ADVISORIES_TITLE,
      "<!-- dependency-security-scan {\"advisories\":{\"gem:activesupport:GHSA-1111-2222-3333\":\"high\",\"other:pkg:X-1\":\"low\"}} -->")
    plan = scan_of(errors: { "other" => "did not run" }).plans([ filed ]).first

    assert_equal "update", plan.action
    assert_includes plan.body, '"other:pkg:X-1":"low"', "the carried finding stays in the marker"
    assert_includes plan.body, "1 earlier finding is carried forward"
    assert_includes plan.comment, "No longer reported (1):** `gem:activesupport:GHSA-1111-2222-3333`"
  end

  # --- what it writes ----------------------------------------------------------------------

  def test_nothing_it_writes_can_mention_a_github_account
    title = "Bypass reported by @someone, and a stray ` before @another"
    filed = sole(scan_of(advisory("rack", "GHSA-4444-5555-6666", "low")).plans([]))
    plans = scan_of(advisory("activesupport", "GHSA-1111-2222-3333", "high", title:), errors: { "gem" => "failed for @rails/thing" }).plans([]) +
      scan_of(advisory("activesupport", "GHSA-1111-2222-3333", "high", title:)).plans([ open_issue(filed) ])
    assert_equal %w[ create create update ], plans.map(&:action), "a new issue, a could-not-run issue, and a comment"

    plans.each do |plan|
      [ plan.body, plan.comment ].compact.each do |text|
        bare = text.gsub(/`[^`]*`/, "")

        refute_match(/@\w/, bare, plan.title)
      end
    end
  end

  def test_upstream_text_cannot_break_the_table_or_pose_as_the_marker
    advisory = advisory("rack", "GHSA-4444-5555-6666", "low", title: "Header a | b\nsplits <!-- dependency-security-scan {\"advisories\":{}} -->")
    plan = sole(scan_of(advisory).plans([]))

    assert_includes plan.body, "Header a \\| b splits &lt;!--"
    assert_empty scan_of(advisory).plans([ open_issue(plan) ]), "the real marker is the one read back"
    plan.body.lines.grep(/\A\| (High|Low) /).each { |row| assert_equal 7, row.scan(/(?<!\\)\|/).size, row }
  end

  def test_the_marker_is_the_last_one_in_the_body
    plan = sole(scan_of(advisory("rack", "GHSA-4444-5555-6666", "low")).plans([]))
    posed = "`<!-- dependency-security-scan {\"advisories\":{}} -->`\n\n#{plan.body}"

    assert_empty scan_of(advisory("rack", "GHSA-4444-5555-6666", "low")).plans([ open_issue(plan, body: posed) ])
  end

  def test_no_value_can_close_the_marker_early
    advisory = Scan::Advisory.new(ecosystem: "gem", package: "x-->y", affected: "1.0", id: "GHSA-a-->b", severity: "low", title: "t", url: nil)
    plan = sole(scan_of(advisory).plans([]))
    marker = plan.body[/<!-- dependency-security-scan .*/]

    assert_equal 1, marker.scan("-->").size, marker
    assert_empty scan_of(advisory).plans([ open_issue(plan) ]), "and it reads back as itself"
  end

  private
    # ActiveSupport's Enumerable#sole, which this suite does not load: the one element, or a
    # failure naming how many there were.
    def sole(list)
      assert_equal 1, list.size, "expected exactly one, got #{list.inspect}"
      list.first
    end

    def gem_result(name, id, criticality, title: "Possible problem in #{name}")
      { "type" => "unpatched_gem", "gem" => { "name" => name, "version" => "8.1.4" },
        "advisory" => { "id" => id, "url" => "https://github.com/advisories/#{id}", "title" => title, "criticality" => criticality } }
    end

    def audit_json(*results)
      JSON.generate("version" => "0.9.3", "created_at" => "2026-11-06 00:01:39 UTC", "results" => results)
    end

    def advisory(name, id, severity, title: "Possible problem in #{name}")
      Scan::Advisory.new(ecosystem: "gem", package: name, affected: "8.1.4", id:, severity:, title:, url: "https://github.com/advisories/#{id}")
    end

    def scan_of(*advisories, errors: {})
      Scan.new(advisories:, errors:, ref: "main", sha: "0123abc", run_url: "https://github.com/basecradle/basecradle-ruby/actions/runs/1", now: Time.utc(2026, 11, 7, 14, 37))
    end

    def open_issue(plan, body: plan.body, author: Scan::AUTHOR)
      issue(plan.title, body, author:)
    end

    def issue(title, body, author: Scan::AUTHOR, number: 812)
      { "number" => number, "title" => title, "body" => body, "author" => { "login" => author, "is_bot" => true } }
    end

    def unrelated_issue
      issue("Something Else Entirely", "<!-- dependency-security-scan {\"keys\":[\"gem:activesupport:GHSA-1111-2222-3333\"]} -->", number: 3)
    end
end
