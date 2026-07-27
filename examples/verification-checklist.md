# Completion Verification Checklist

Run this checklist every time a subagent reports completion, before acting on
the report or passing "done" upstream. A completion notice is a claim, not
evidence.

## 0. Existing WIP and writer ownership

- [ ] The agent recorded its initial branch and `git status --porcelain`
      before editing.
- [ ] The agent was the exclusive writer for its checkout, or used an
      orchestrator-assigned isolated worktree and task branch.
- [ ] The agent did not stash, reset, delete, or absorb unassigned
      pre-existing WIP.
- [ ] If ownership was unclear or another writer was present, the agent
      stopped without editing, committing, pushing, or merging.

## 1. Artifact existence (always)

- [ ] Every artifact path from the acceptance criteria exists.
- [ ] Modification times moved for files that were supposed to change.
- [ ] For file-changing tasks, the working tree shows the expected diff:

  ```bash
  git -C <repo> --no-optional-locks status --porcelain
  ```

  - Empty output for a task that should have changed files = no-op. Go to
    the recovery step in SKILL.md section 3.
  - Unexpected extra paths = scope violation. Inspect before merging.

## 2. Content spot-check

- [ ] Open at least one changed file and confirm the change matches the spec
      (not just that the file was touched).
- [ ] Encoding and line endings survived (UTF-8 without BOM, LF), if the
      task had format constraints.

## 3. Claimed results vs measured results

- [ ] The report includes a changed-file list. It matches the porcelain
      output.
- [ ] The report includes actual test/lint output. Re-run the stated
      verify command yourself, or inspect the diff deeply enough to trust it:

  ```bash
  <test-or-lint-command>
  ```

- [ ] Anything the report marks "unverified" is either verified now or
      carried forward as unverified in your own report.

## 4. No-op recovery (when step 1 fails)

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
