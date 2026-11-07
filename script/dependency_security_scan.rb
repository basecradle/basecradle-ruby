# frozen_string_literal: true

require "json"

# The daily dependency security scan's verdict and its routing. Run by
# `script/dependency-security-scan` from .github/workflows/dependency-security-scan.yml.
#
# Nothing else here audits this repository's dependencies: CI never runs bundler-audit, and
# Dependabot's alerts stayed silent through the advisories that left a Rails security release
# unnoticed in the core repository for 23 hours (basecradle/basecradle#750). This is the
# clock: the gems this repository resolves, every day, against a refreshed advisory database
# (#267). The class is the core's, ported; only what a gem repository forces is different.
#
# This class decides; it calls nothing. It takes the scanner's raw output and the
# repository's open issues, and returns what to do on GitHub: nothing, a new issue, an update
# to the one already open, or closing one. The workflow applies it.
#
# Standard library only, and outside lib/ on purpose: lib/ is what the gem ships, and this
# is repository tooling, never part of the SDK.
class DependencySecurityScan
  ADVISORIES_TITLE = "[SECURITY] Dependency Advisories Against main (Daily Scan)"
  ERROR_TITLE = "Daily Dependency Security Scan Could Not Reach a Verdict"

  # Ruled by @origin, 2026-11-05 (basecradle/basecradle#750): an advisory rated High or
  # Critical pages him; everything else goes to the capital's inbox. An unrated advisory is
  # not known to be High, so it does not page; it pages the day it is rated High.
  PAGING_SEVERITIES = %w[ critical high ].freeze
  PAGING_LABEL = "needs-human"
  INBOX_LABEL = "needs-capital"

  SEVERITY_ORDER = %w[ critical high medium moderate low none unknown ].freeze
  ECOSYSTEM_NAMES = { "gem" => "Ruby gem" }.freeze

  # This repository is public, so anyone can open an issue with either title and a marker of
  # their own. Only the issues the basecradle-ai App wrote are the scan's (as `gh issue list
  # --json author` names it); a look-alike is never read, so it can neither stop a page nor
  # hide the real issue.
  AUTHOR = "app/basecradle-ai"

  # Each issue body carries the state it was written for, so the next run can tell a
  # standing finding (say nothing) from a changed one. The marker is written last, so it is
  # the last one read back: anything earlier in the body that looks like one is not it.
  MARKER = /<!-- dependency-security-scan (\{.*\}) -->/

  class ScanError < StandardError; end

  Advisory = Data.define(:ecosystem, :package, :affected, :id, :severity, :title, :url) do
    # No "@": the key is written into the issue, where a bare @name is a mention, and an
    # insecure source's package is its URL, which can carry one.
    def key
      "#{ecosystem}:#{package.delete("@")}:#{id}"
    end

    def pages?
      PAGING_SEVERITIES.include?(severity)
    end

    def rank
      [ SEVERITY_ORDER.index(severity) || SEVERITY_ORDER.size, ecosystem, package, key ]
    end
  end

  Plan = Data.define(:action, :number, :title, :body, :comment, :labels)

  # `bundle lock`, run first: no lockfile is committed here (see .gitignore), so there is
  # nothing to audit until one is resolved, and a resolution that failed is no verdict.
  def self.check_resolution(exit_status, bundle: "bundle")
    raise ScanError, "#{bundle} lock could not resolve what the Gemfile and the gemspec allow (exit #{exit_status.inspect})" unless exit_status == 0
  end

  # Each Ruby resolves its own versions, so the scan audits one resolution per Ruby. The same
  # advisory found under several is one finding, with every installed version it was found in.
  def self.merge(advisories)
    advisories.group_by(&:key).map { |_, same| same.first.with(affected: same.map(&:affected).uniq.join(", ")) }
  end

  # `bundle-audit check --format json`. Exit 0 means no finding, exit 1 means at least one;
  # anything that does not fit that is not a verdict.
  def self.parse_bundler_audit(output, exit_status)
    report = JSON.parse(output)
    results = report.is_a?(Hash) ? report["results"] : nil
    raise ScanError, "bundler-audit produced no results list (exit #{exit_status})" unless results.is_a?(Array) && results.all?(Hash)
    unless (exit_status == 0 && results.empty?) || (exit_status == 1 && results.any?)
      raise ScanError, "bundler-audit exited #{exit_status} with #{results.size} results"
    end

    results.map do |result|
      advisory = result["advisory"] || {}
      Advisory.new(
        ecosystem: "gem",
        package: (result.dig("gem", "name") || result["source"] || "unknown").to_s,
        affected: result.dig("gem", "version").to_s,
        # An insecure gem source has no advisory id; it is known by the type of finding.
        id: (advisory["id"] || result["type"] || "unknown").to_s,
        severity: (advisory["criticality"] || "unknown").to_s,
        title: (advisory["title"] || "Insecure gem source").to_s,
        url: advisory["url"]
      )
    end
  rescue JSON::ParserError => error
    raise ScanError, "bundler-audit produced no readable report (exit #{exit_status}): #{error.class}"
  end

  attr_reader :advisories, :errors

  # errors: { "gem" => "why that scan reached no verdict" }, one entry per scanner that
  # failed. A failed scanner says nothing about its ecosystem, so its earlier findings are
  # carried forward, never reported as resolved.
  def initialize(advisories:, errors: {}, ref:, sha:, run_url:, now: Time.now.utc)
    @advisories = advisories.sort_by(&:rank)
    @errors = errors
    @ref = ref
    @sha = sha
    @run_url = run_url
    @now = now
  end

  def verdict
    return "error" if errors.any?

    advisories.any? ? "advisories" : "clean"
  end

  # open_issues: the repository's open issues, as `gh issue list --json
  # number,title,body,author` returns them.
  def plans(open_issues)
    ours = open_issues.select { |issue| issue.dig("author", "login") == AUTHOR }
    [ advisories_plan(ours), error_plan(ours) ].compact
  end

  private
    def advisories_plan(open_issues)
      existing = open_issues.find { |issue| issue["title"] == ADVISORIES_TITLE }
      known = existing ? state_in(existing["body"]).fetch("advisories", {}) : {}
      known = {} unless known.is_a?(Hash)
      carried = known.select { |key, _| errors.key?(key.split(":").first) }
      current = carried.merge(advisories.to_h { |advisory| [ advisory.key, advisory.severity ] }).sort.to_h

      added = advisories.reject { |advisory| known.key?(advisory.key) }
      rerated = advisories.select { |advisory| known.key?(advisory.key) && known[advisory.key] != advisory.severity }
      # Rated High or Critical after it was filed as something lower: that pages too.
      escalated = rerated.select { |advisory| advisory.pages? && !PAGING_SEVERITIES.include?(known[advisory.key]) }
      resolved = known.keys - current.keys
      return if added.empty? && rerated.empty? && resolved.empty?

      announced = added + escalated
      labels = announced.any? ? [ label_for(announced) ] : []
      body = advisories_body(current, carried)

      if existing
        Plan.new(action: "update", number: existing["number"], title: ADVISORIES_TITLE, body:,
          comment: change_comment(added, rerated, resolved, known, current, labels), labels:)
      else
        Plan.new(action: "create", number: nil, title: ADVISORIES_TITLE, body:, comment: nil, labels:)
      end
    end

    # One issue while the scan cannot run, never one a day: filed when a scanner first fails,
    # updated when which scanners fail changes, and closed by the run that reaches a verdict
    # again (that run is the verification).
    def error_plan(open_issues)
      existing = open_issues.find { |issue| issue["title"] == ERROR_TITLE }
      failing = errors.keys.sort

      if existing.nil?
        return if failing.empty?

        Plan.new(action: "create", number: nil, title: ERROR_TITLE, body: error_body(failing), comment: nil, labels: [ INBOX_LABEL ])
      elsif failing.empty?
        Plan.new(action: "close", number: existing["number"], title: ERROR_TITLE, body: nil, labels: [],
          comment: "Every scanner reached a verdict on `#{@sha}` (`#{@ref}`), so the clock is running again. Closed by that run: #{@run_url}")
      elsif failing != state_in(existing["body"]).fetch("failing", nil)
        Plan.new(action: "update", number: existing["number"], title: ERROR_TITLE, body: error_body(failing), labels: [ INBOX_LABEL ],
          comment: "Which scans fail has changed. Now failing: the #{names(failing)}. `#{INBOX_LABEL}` applied for the change.\n\n#{error_list}\n\nRun: #{@run_url}")
      end
    end

    def state_in(body)
      state = JSON.parse(body.to_s.scan(MARKER).last&.first || "{}")
      state.is_a?(Hash) ? state : {}
    rescue JSON::ParserError
      {}
    end

    # ">" is written as its JSON escape, so no value can close the comment early; it reads
    # back as itself.
    def marker(state)
      "<!-- dependency-security-scan #{JSON.generate(state).gsub(">", "\\u003e")} -->"
    end

    def label_for(list)
      list.any?(&:pages?) ? PAGING_LABEL : INBOX_LABEL
    end

    def advisories_body(current, carried)
      <<~BODY
        ## What Was Found

        #{headline(carried)}

        - **Where:** the gems `Gemfile` and `basecradle.gemspec` resolve at `#{@sha}` (`#{@ref}`) under each Ruby CI tests, resolved fresh by this run, since no lockfile is committed.
        - **When:** scanned #{@now.strftime("%Y-%m-%d %H:%MZ")}, by the scheduled scan and not by a session: #{@run_url}
        - **Actor:** none. These are public upstream disclosures, not events on our systems.
        - **Class:** a dependency advisory.
        - **Contained so far:** nothing, but the reach is narrow: the gem declares no runtime dependency, so none of this ships to anyone who installs it. These gems run in CI and on contributors' machines.

        #{table(advisories) if advisories.any?}
        #{carried_note(carried)}
        ## What Happens Next

        The response is the `security-scan-bump` skill. No lockfile is committed, so every scan resolves the newest versions the `Gemfile` and the gemspec allow: an advisory here means no fixed version is resolvable yet, because upstream has not released one or a constraint here holds it back. Move that constraint on its own branch; once a fixed version resolves, the next scan notes the advisory as no longer reported. An advisory that does not apply here is dismissed in `.bundler-audit.yml` (`ignore:`). Closing this issue dismisses nothing: while an advisory stands, the next scan files a new issue.

        ## How This Was Routed

        #{routing}

        #{marker("advisories" => current)}
      BODY
    end

    def headline(carried)
      return "This run found no advisory in what it could scan, and could not scan everything." if advisories.empty? && carried.any?
      return "The daily scan of `main` finds no advisory now. Close this issue by hand." if advisories.empty?

      "The daily scan of `main` found **#{count_of(advisories)}** against what `main` resolves: #{tally(advisories)}."
    end

    def routing
      if advisories.empty?
        "Nothing is reported now, so this run applied no label."
      elsif advisories.any?(&:pages?)
        "`#{PAGING_LABEL}` is applied when an advisory rated High or Critical appears, and it pages `@origin` (his ruling, 2026-11-05, basecradle/basecradle#750)."
      else
        "`#{INBOX_LABEL}`: nothing here is rated High or Critical, so nothing paged. Only High and Critical page `@origin` (his ruling, 2026-11-05, basecradle/basecradle#750)."
      end
    end

    def carried_note(carried)
      return "" if carried.empty?

      "\n**Not re-checked this run:** the #{names(errors.keys)} could not run, so #{carried.size} earlier #{carried.size == 1 ? "finding is" : "findings are"} carried forward unlisted, neither confirmed nor cleared.\n"
    end

    def change_comment(added, rerated, resolved, known, current, labels)
      parts = []
      parts << "**New since the last scan (#{count_of(added)}: #{tally(added)}):**\n\n#{table(added)}" if added.any?
      parts << "**Re-rated:** #{rerated.map { |advisory| "`#{advisory.key}` #{known[advisory.key].to_s.capitalize} → #{advisory.severity.capitalize}" }.join(", ")}" if rerated.any?
      parts << "**No longer reported (#{resolved.size}):** #{resolved.map { |key| "`#{key}`" }.join(", ")}" if resolved.any?
      parts << "`#{labels.first}` applied for what is new here." if labels.any?
      parts << "The scan of `main` at `#{@sha}` is clean. Close this issue by hand." if current.empty?
      parts << "Run: #{@run_url}"
      parts.join("\n\n")
    end

    def error_body(failing)
      <<~BODY
        ## What Happened

        The daily dependency security scan of `main` ran and could not reach a verdict, so it says nothing about whether `main` is clean. While this stands, a new advisory goes unseen: nothing else here audits these gems.

        - **Where:** `#{@sha}` (`#{@ref}`), #{@now.strftime("%Y-%m-%d %H:%MZ")}: #{@run_url}

        #{error_list}

        ## What Happens Next

        Read the run's log, fix what stopped the scan, and re-run the workflow by hand (`Dependency Security Scan`, *Run workflow*). One issue is filed while the scan cannot run, not one a day, and the run that reaches a verdict again closes it.

        #{marker("failing" => failing)}
      BODY
    end

    def error_list
      errors.sort.map { |ecosystem, reason| "- **#{ECOSYSTEM_NAMES.fetch(ecosystem, ecosystem)} scan:** #{cell(reason)}" }.join("\n")
    end

    def names(ecosystems)
      ecosystems.sort.map { |ecosystem| "#{ECOSYSTEM_NAMES.fetch(ecosystem, ecosystem)} scan" }.join(" and ")
    end

    def table(list)
      rows = list.map do |advisory|
        link = advisory.url ? "[#{cell(advisory.id)}](#{advisory.url})" : cell(advisory.id)
        "| #{advisory.severity.capitalize} | #{ECOSYSTEM_NAMES.fetch(advisory.ecosystem)} | #{code(advisory.package)} | #{code(advisory.affected)} | #{link} | #{cell(advisory.title)} |"
      end
      [ "| Severity | Ecosystem | Package | Installed | Advisory | Title |", "|---|---|---|---|---|---|", *rows ].join("\n") + "\n"
    end

    def count_of(list)
      "#{list.size} #{list.size == 1 ? "advisory" : "advisories"}"
    end

    def tally(list)
      list.map(&:severity).tally.sort_by { |severity, _| SEVERITY_ORDER.index(severity) || SEVERITY_ORDER.size }
        .map { |severity, count| "#{count} #{severity.capitalize}" }.join(", ")
    end

    # Upstream text, made safe for a table cell: a pipe would split the row, a "<" could open
    # a comment that reads as this scan's own marker, and GitHub reads a bare @name as a
    # mention of whoever holds that account. Backticks go first, so a stray one cannot pair
    # with the span that fences an @name and leave the name bare.
    def cell(text)
      text.to_s.gsub(/\s+/, " ").delete("`").gsub("<", "&lt;").gsub("|", "\\|").gsub(/@[\w\-\/.]+/) { |match| "`#{match}`" }
    end

    # The same, inside a code span, where the pipe is still a cell boundary.
    def code(text)
      text.to_s.empty? ? "" : "`#{text.to_s.gsub(/\s+/, " ").delete("`").gsub("|", "\\|")}`"
    end
end
