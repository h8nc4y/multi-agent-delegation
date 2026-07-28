# Completion Verification Checklist

Run this checklist every time a subagent reports completion, before acting on
the report or passing "done" upstream. A completion notice is a claim, not
evidence.

## 0. Existing WIP and writer ownership

- [ ] Before editing, the agent recorded its initial branch, full
      `git rev-parse --verify HEAD` OID (or explicit unborn state), and all
      output from
      `git --no-optional-locks status --porcelain=v1 --untracked-files=all`.
- [ ] For non-Git artifacts and explicitly assigned dirty-resume artifacts,
      the pre-edit baseline includes existence, byte size, and SHA-256.
- [ ] Baseline collection used read-only commands only. It did not use
      `git write-tree`, `update-index`, stash, reset, checkout, or another
      state-changing shortcut.
- [ ] The agent was the exclusive writer for its checkout, or used an
      orchestrator-assigned isolated worktree and task branch.
- [ ] The agent did not stash, reset, delete, or absorb unassigned
      pre-existing WIP.
- [ ] If ownership was unclear or another writer was present, the agent
      stopped without editing, committing, pushing, or merging.

## 1. Baseline-to-final delta (always)

- [ ] The orchestrator independently recorded the final branch and full HEAD
      OID, then measured both committed and current state:

  ```bash
  git -C <repo> --no-optional-locks merge-base --is-ancestor <baseline> <final>
  git -C <repo> --no-optional-locks diff --name-status <baseline>..<final> --
  git -C <repo> --no-optional-locks status --porcelain=v1 --untracked-files=all
  ```

- [ ] For an existing baseline HEAD, `merge-base --is-ancestor` exited 0.
      Matching branch names or an assigned-only diff did not substitute for
      ancestry; rewritten or divergent history is a scope violation.
- [ ] Every acceptance artifact was opened and checked for required content;
      final existence, byte size, and SHA-256 were independently measured.
- [ ] Unchanged HEAD, porcelain, and initial-to-final assigned artifact state
      are classified as a no-op even if the artifact already existed.
- [ ] Empty final porcelain is accepted when HEAD changed, the
      baseline is an ancestor of final HEAD, the baseline-to-final diff contains
      only assigned paths, and artifact content passes acceptance.
- [ ] For an explicitly assigned dirty resume, initial and final artifact
      states were compared; identical porcelain path text alone was not treated
      as proof of either a no-op or a change.
- [ ] For a non-Git file-changing task, final existence, byte size, and SHA-256
      differ from the pre-edit baseline and content passes acceptance.
- [ ] Any unassigned path in initial/final porcelain or the committed diff is a
      scope violation. The agent did not alter, stage, commit, delete, or absorb
      unassigned WIP.

## 2. Content spot-check

- [ ] Open at least one changed file and confirm the change matches the spec
      (not just that the file was touched).
- [ ] Artifact existence or modification time alone was not used as completion
      evidence.
- [ ] Encoding and line endings survived (UTF-8 without BOM, LF), if the
      task had format constraints.

## 3. Claimed results vs measured results

- [ ] The report includes a changed-file list. It matches the union of
      baseline-to-final committed paths and current assigned working changes.
- [ ] The report includes actual test/lint output. Re-run the stated
      verify command yourself, or inspect the diff deeply enough to trust it:

  ```bash
  <test-or-lint-command>
  ```

- [ ] Anything the report marks "unverified" is either verified now or
      carried forward as unverified in your own report.

## 4. No-op recovery (when step 1 classifies a no-op)

- [ ] Resume the SAME agent (same agent id / same thread), do not spawn a
      fresh one. Re-instruct: "Re-delegation forbidden. Start the work
      yourself now, and report the changed-file list."
- [ ] Second no-op → stop delegating; the orchestrator implements directly.
- [ ] Record the incident (which agent, which task shape) so the next
      delegation prompt can be tightened.

## 5. Ledger mode extras (parallel fan-out)

- [ ] Ledger entries ticked `[x]` by the agent match the changes you actually
      verified.
- [ ] The agent stopped at commit/branch/PR as instructed (did not merge).
- [ ] The worktree was left in place for inspection.
- [ ] Merge is performed by the orchestrator only, after this checklist
      passes.

## Report wording

- Verified: state the command and its measured result.
- Not verified: write "unverified" (未検証) explicitly. Never upgrade a claim
  to a fact just because the notice sounded confident.
