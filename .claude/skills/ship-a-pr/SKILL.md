---
name: ship-a-pr
description: The procedure for landing a change in this repo from the headless fleet box — branch, local suite, proof runs (mutation probes and deliberate-break commits), self-review, push as the bot, open the PR, arm auto-merge and confirm it will actually fire, then delete the local branch behind a containment proof. Use whenever you open, arm, or clean up after a PR here, run mutation or deliberate-break probes, or a local branch refuses `git branch -d`. The invariants (nobody pushes to `main`; one concern per PR; never park on CI; a closing keyword only for ordinary in-repo issues; never force-delete a branch without proof; self-review is mandatory; no `Co-Authored-By` trailer) live in CLAUDE.md → Conventions and Fleet Identity and govern at all times.
---

# Shipping a PR

The invariants live in `CLAUDE.md` → Conventions ("Workflow", "A wake on this box is headless") and Fleet Identity. This skill is the procedure behind them. Auth (the bot author, `GH_TOKEN`, pushing) is the `bot-auth-setup` skill.

## 1. Branch and build

```bash
git fetch origin main && git switch main && git merge --ff-only FETCH_HEAD
git switch -c <branch>
bundle exec rake    # rubocop + the offline suite; run it before every push
```

CI is the 3.2 · 3.3 · 3.4 matrix plus `actionlint`; the local run is the fast first check, not a substitute.

## 2. Proof runs — when the rigor asks for them

Critical work is probed against its own deliberate break: edit the subject, run the tests, restore, repeat.

- **Commit before every probe.** The restore is `git checkout -- <path>`, which restores `HEAD` — any *uncommitted* work under that path is wiped without an error. That covers a one-off probe as much as a scripted harness: re-commit whenever `lib/` or `test/` holds new work and a probe is next. `git diff --stat` before a probe shows what is at risk.
- **Make a harness prove each edit applied** — `abort "PATCH MISS"` when the string it replaces is absent. Two tells that a restore ate your work: probes 2..N failing with exactly probe 1's count and line numbers, and a failure quoting message text you know you changed.
- **Re-run after self-review.** Every fix a review finding produced gets its own mutation (revert the exact line it changed) and a re-run before the PR opens. Review findings are by definition the cases you did not think of, so their fixes are the ones that ship unpinned — including fixes that quietly narrow a guard while every assertion stays green.

## 3. Self-review, commit, push, open

1. `/code-review` on the diff; apply the findings (then step 2's re-run, if probes are in play).
2. Commit with **no `Co-Authored-By` trailer** — check the message before pushing; once auto-merge fires there is no window to amend.
3. Push: `GH_TOKEN="$(gh-app-token)" git push origin <branch>`.
4. Open: `gh pr create --head <branch> …` — the clone is shallow and single-branch, so the push records no remote-tracking ref and `--head` is required. A closing keyword only for an ordinary in-repo issue; never for a handoff or release issue. The PR body ends with the Claude Code line.

## 4. Arm auto-merge and confirm it will fire

```bash
gh pr merge <n> --auto --squash
gh pr view <n> --json state,autoMergeRequest,mergeStateStatus
```

- **`autoMergeRequest` is null** → arming did not take: say so on the issue, never exit quietly.
- **`mergeStateStatus` is `BEHIND`** → armed auto-merge **never fires**: the "Protect main" ruleset requires the branch up to date, and arming still reports success. Run `gh pr update-branch <n>` (server-side — the local clone cannot see the other PR's branch); the CI re-run then lets auto-merge fire. Expect this whenever a second PR merges first.
- **Deliberate-break commits: arm only after the revert is pushed.** Some breaks make the required `CI` check report `skipped` rather than red, and branch protection passes a skipped required check — an armed PR would merge the break. Push the break, wait for its run, push the revert, wait again: `ci.yml` cancels in-progress PR runs, so pushing early loses the run the DoD asks for. Note the late arming in the PR body and on the issue, then arm on the clean head and confirm as above.

The merge wakes no one. For a handoff or release issue, check back between other work at the polling floor, confirm the merge, verify live, and close by hand before the turn ends.

## 5. Clean up the branch

- **Remote:** deleted automatically on merge (`delete_branch_on_merge`). `git push origin --delete <branch>` is only for a branch whose PR never merged; on a merged one it fails with `remote ref does not exist`.
- **Local:** `git branch -d <branch>` first. It refuses a squash-merged branch ("not fully merged" — the squash commit has a different hash), so prove the branch's **own** changes are on `main`, then `git branch -D <branch>`:
  - `git diff main..<branch>` is 0 lines — when `main` has not moved past the branch; or
  - `git diff <branch> main -- <files the branch touched>` is empty; or
  - when two PRs were in flight, both diffs carry the *other* PR's changes (and `gh pr update-branch` advanced only the remote). Reverse-apply the branch's own patch to `main` instead — a clean check means `main` already contains it:

    ```bash
    git switch main
    git diff "$(git merge-base main <branch>)" <branch> > ~/scratch/branch.patch
    git apply --check -R ~/scratch/branch.patch && rm ~/scratch/branch.patch
    ```

    Use the branch's actual base if `merge-base` cannot find it in this shallow clone.

  Never fall back to a bare `-D` because a test did not fit — a non-empty proof means unshipped work.
