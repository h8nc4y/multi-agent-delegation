# Ledger Template for Parallel Delegation (ledger-as-spec)

When a review pass produces many findings, record them in a ledger like this.
A precise ledger entry doubles as the delegation spec — you hand entries to
subagents verbatim, one repository per agent.

All names below are synthetic placeholders.

## Ledger file shape

```markdown
# Fix ledger — <project-or-repo-name>

Verify baseline: <full-test-command> (all green as of <commit-ish>)

## <repo-or-module A>

- [ ] src/parser.py:142 — file handle leaked when header parse fails
      fix: wrap open() in try/finally or use a with-block
      confidence: high
      verify: <test-command> tests/test_parser.py

- [ ] src/export.py:88 — zip entry names collide on duplicate titles
      fix: pass strict name de-duplication flag; add regression test
      confidence: medium
      verify: <test-command> tests/test_export.py

## <repo-or-module B>

- [ ] app/cli.py:31 — EOFError crashes interactive prompt when stdin closed
      fix: catch EOFError and exit with a calm message
      confidence: high
      verify: <test-command> tests/test_cli.py
```

Entry fields:

- `<file>:<line>` — anchor the finding to one place.
- one-line defect/symptom — what is wrong, observable.
- `fix:` — the minimal proposed change (small enough to review at a glance).
- `confidence:` — high/medium/low; low-confidence entries deserve a comment
  from the agent instead of a blind fix.
- `verify:` — the command that must pass; this becomes the agent's measured
  evidence.

## Fan-out delegation prompt (per repository)

Combine the mandatory clauses from
[delegation-prompt-template.md](delegation-prompt-template.md) with the four
ledger-mode clauses:

```text
Task: implement the unchecked ledger entries for <repo> listed below.

[MANDATORY] Re-delegation to other agents is forbidden. Execute the work
yourself with your file-edit and shell tools.

Rules for this fan-out:
1. Do NOT merge. Stop at commit / branch / pull-request stage.
2. Leave your worktree in place (no cleanup) so the orchestrator can inspect.
3. Tick the ledger entries you completed ([ ] -> [x]) in <ledger-path>
   (this repository's own ledger; no other agent writes it).
4. Report measured results only: paste the actual output of each verify
   command you ran. No assumptions.

Isolation:
- Work in an isolated git worktree on branch <branch-name>, never on the
  orchestrator's checkout.
- You own only <repo>. Do not touch any other repository.

Ledger entries assigned to you:
<paste the unchecked entries for this repo here>
```

## Orchestrator-side rules

- One repository = one agent; parallel agents never share a repository.
- One writer per ledger file: keep one ledger per repository (each agent
  ticks only its own), or have agents report completed entries and tick a
  central ledger yourself. Two agents must never write the same ledger file.
- Merge only after independent verification (re-run tests or inspect the
  diff yourself).
- For a repository without a remote: have the agent leave the branch in
  place, then fast-forward merge it yourself.
- Track completion by the ledger, not by completion notices: entries ticked
  `[x]` must match changes you actually verified.

## Why this works (measured)

In one measured session, 14 agents fanned out in parallel over a
multi-repository backlog of roughly 40 ledger entries returned with zero
no-ops and all test suites green — landing 17 pull requests plus 4 local
merges in a single pass. The precision of the entries (file:line + minimal
fix + verify command) is what removes the ambiguity that makes subagents
idle or improvise.
