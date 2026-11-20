# frozen_string_literal: true

# One rule for every workflow this repository writes itself (#313, #317): each
# actions/checkout step sets `persist-credentials: false`. Unless told not to, checkout leaves
# the job's GITHUB_TOKEN on disk for the rest of the job — v7.0.1 writes it to a credentials
# file under the runner's temp directory that `.git/config` includes — so every later step can
# read it. Nothing after a checkout here uses git credentials: the repository is public. What
# a later step could do with the token differs, so each caller names it: CI's gems, the
# release's write token beside the push credential, the scan's App key. ci_workflow_test.rb,
# release_workflow_test.rb and dependency_security_scan_workflow_test.rb hold their workflows
# to it; a workflow added later snaps onto the same check.
#
# Each caller also refutes that its workflow has no checkout at all, so a renamed action
# flunks rather than passing over nothing. A job that calls a reusable workflow keeps its
# checkouts in another file, out of this check's sight; none of the three does. (The two
# capital stubs, dependabot-auto-merge.yml and needs-human-alert.yml, are only such calls,
# into basecradle/.github; their checkouts are that repository's to hold.)
module CheckoutToken
  CHECKOUT = "actions/checkout@"

  # Every checkout step in +job+. GitHub reads an action's owner and name without regard to
  # case, so `Actions/Checkout@…` is the same action and is read too.
  def self.checkouts(job)
    Array(job["steps"]).select { |step| step["uses"].to_s.downcase.start_with?(CHECKOUT) }
  end

  # The checkout steps in +job+ that keep the token. A `with:` that is not a mapping sets no
  # input at all, so it reads as keeping it.
  def self.keeping(job)
    checkouts(job).reject do |step|
      inputs = step["with"]
      inputs.is_a?(Hash) && inputs["persist-credentials"].to_s == "false"
    end
  end

  # The failure message for a workflow with no checkout step to read.
  def self.none(workflow)
    "#{workflow} has no #{CHECKOUT} step; the checkout-token check reads them."
  end

  # The failure message, said once: why dropping the token matters, given what +holder+ says
  # a later step in that job could do with it.
  def self.message(workflow, job, holder)
    "#{workflow}: a checkout in the #{job} job does not set `persist-credentials: false`, so " \
      "the job's GITHUB_TOKEN stays on disk, readable by every step after it. #{holder}. " \
      "Nothing after a checkout here uses git credentials; add the key under the step's `with:`."
  end
end
