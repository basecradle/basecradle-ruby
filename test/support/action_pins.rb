# frozen_string_literal: true

# One rule for every workflow job that holds a credential (#284, #286): each action it runs
# is pinned to a full commit SHA, never a tag or branch, so code someone else can move never
# runs beside the credential. release_workflow_test.rb holds release.yml to it and
# dependency_security_scan_workflow_test.rb holds the scan to it; a job that gains a
# credential later snaps onto the same check. ci_workflow_test.rb holds ci.yml to it too
# (#311): its jobs hold no secret, but a push to main saves the bundle cache main's later
# runs restore, and they run the Ruby every change is tested on.
#
# Forty lowercase hex characters: GitHub resolves a *short* SHA too, and anyone can name a
# branch or tag after one, so only the full canonical form is a ref nobody can move. A local
# action (`./…`) or a `docker://` image would need its own rule; neither is used, so either
# reads as unpinned and asks for one.
module ActionPins
  PINNED = %r{\A[\w.-]+/[\w.-]+(/[^@]+)?@[0-9a-f]{40}\z}

  # The `uses:` refs in +job+ that are not pinned to a full commit SHA: each step's action,
  # and the job's own `uses:` when it calls a reusable workflow, which has no steps here and
  # runs with whatever secrets the job hands it.
  def self.unpinned(job)
    [ job["uses"], *Array(job["steps"]).map { |step| step["uses"] } ].compact.grep_v(PINNED)
  end

  # The failure message, said once: why the pin matters, given what +holder+ holds.
  def self.message(job, unpinned, holder)
    "the #{job} job runs #{unpinned.join(', ')} by a movable ref. #{holder}, so a tag or " \
      "branch moved by the action's owner — or by whoever compromises it — runs with that " \
      "power. Pin each to its full 40-character commit SHA with the version in a comment " \
      "(`uses: owner/repo@<sha> # vX.Y.Z`); Dependabot keeps that form current."
  end
end
