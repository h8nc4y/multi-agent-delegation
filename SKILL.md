---
name: multi-agent-delegation
description: >-
  Prevent no-op and silent delegation failures when an orchestrator agent hands
  work to subagents. Use when a subagent re-delegates to a child agent and
  idles instead of working, when a completion notice arrives but no artifacts
  exist (git status shows no changes), when execution-environment differences
  (WSL / Git Bash / PowerShell / sandbox) fake success silently, or before
  writing any delegation prompt, especially when multiple writers could share
  one checkout containing WIP. Canonical source for mandatory
  delegation-prompt clauses, artifact verification of completion notices,
  resume-based recovery, and ledger-as-spec parallel delegation. Symptom
  keywords: silent failure, no-op delegation, "delegated and waiting",
  完了通知なのに成果物が無い, 子へ再委譲して待機, 空振り, 無言失敗.
---

# Multi-Agent Delegation Discipline

Discipline for an orchestrator agent that delegates work to subagents, so that
delegation does not end in a no-op (a successful-looking completion notice with
zero artifacts) or a silent failure (an execution-environment difference that
fakes success).

## When To Use

- You delegated a task to a subagent and received a completion notice, but the
  expected files or changes do not exist.
- The completion notice text reads as success, yet `git status --porcelain` or
  an artifact-existence check finds nothing.
- You are about to write a delegation prompt and want the mandatory clauses
  (prevention is cheaper than recovery).
- A review pass produced many findings and you want to fan them out to
  parallel subagents safely (see the ledger-as-spec section).

## Core Rule

A subagent's completion notice is a claim, not evidence. Verify artifacts
before acting on it or reporting it upstream.

## Tool Portability

The principles here are tool-agnostic. Concrete names used below map as
follows:

- Claude Code: the `Agent` tool spawns subagents; `SendMessage` resumes a
  previously spawned agent by its id with context intact.
- Codex and other agent CLIs: spawning is starting a delegated task or thread;
  "resume" means re-instructing the same thread or session so its context is
  retained, instead of starting a new one.
- Verification commands are plain Git and shell, and work in any environment.

## Procedure

### 1. Mandatory clauses in every delegation prompt (prevention)

Include all of these in every delegation prompt:

1. "Re-delegation to other agents is forbidden. Execute the work yourself
   with your file-edit and shell tools (Read/Edit/Write/Bash or this
   environment's equivalents)."
2. The absolute path of the exclusive checkout / worktree, the absolute
   expected artifact path(s), and the acceptance criteria: what must exist for
   the task to count as done.
3. "Your completion report must include the list of changed files."
4. Any format constraints that must not be broken (encoding such as UTF-8
   without BOM, append-only versus overwrite, newline policy).
5. "Checkout ownership: before editing, inspect the current branch and
   `git status --porcelain`. If existing WIP is present and was not explicitly
   assigned to you, another writer is using the same checkout, or ownership is
   unclear, do not edit, commit, push, or merge. Report the conflict to the
   orchestrator. Use an exclusive checkout or isolated worktree and task
   branch before continuing."

Observed failure this prevents: given a large task, a background subagent may
spawn its own child agent, reply that it delegated and will wait, and then
terminate. The orchestrator receives a successful-looking completion notice
while the git working tree is unchanged — and tokens were spent twice, once by
the idle parent and once by the orphaned child.

The ownership clause prevents a different failure: two agents editing one
checkout can overwrite or absorb each other's WIP and make the measured diff
disagree with either completion report. Pre-existing WIP not explicitly
assigned to the delegated agent must not be stashed, reset, deleted, or
included in the delegated task's commit. A resumed agent may continue its own
explicitly assigned WIP in the same thread.

### 2. Verify every completion notice (never trust the text)

- For file-changing tasks, run
  `git -C <repo> --no-optional-locks status --porcelain`
  or check that the artifact paths exist and their modification times moved.
- Do not report "done" upstream based on the notice text alone. Anything you
  could not verify must be reported as unverified.

### 3. Recovery when a delegation no-ops

1. Resume the same agent (same agent id, same thread) rather than spawning a
   fresh one — the retained context makes the retry cheaper and faster.
   Re-instruct it: "Re-delegation is forbidden. Start the work yourself now,
   and report the changed-file list."
2. If the second attempt also returns without artifacts, stop delegating that
   task: the orchestrator implements it directly.

### 4. Isolate environment-difference silent failures

In multi-agent setups, "sent successfully" does not mean "executed where you
think." Pin down the executing environment first:

- Run `uname -a` and `command -v <tool>` (POSIX shells) or `$PSVersionTable`
  and `Get-Command <tool>` (PowerShell) in the executing environment to
  confirm the shell flavor (WSL2 / Git Bash / PowerShell) and the presence of
  required CLIs. Observed failure: a dependency CLI (for example `sqlite3`)
  missing in the executing environment produced a silent fake success.
- For Windows permission errors (Error 5 / EPERM), do not diagnose from the
  message text alone. Separate the failing layer — environment preparation,
  process launch, or child-process runtime — using logs before fixing, and do
  not treat "grant full access" as a universal fix.

### 5. Where to route (model and agent selection)

Choose the delegation target by task profile, not by a fixed role assignment:

- Parallel research and mechanical bulk edits: cheaper or faster
  general-purpose subagents.
- Domain-specialized work (for example frontend implementation): a
  specialized agent, if the environment provides one.
- Anything that needs the orchestrator's full context, judgment calls, or
  merge rights: do not delegate.

### 6. Ledger-as-spec parallel delegation (scaling to many fixes)

When a review pass produces many findings across one or more repositories,
record them in a ledger and delegate ledger entries directly as
self-contained specs. A precise ledger entry is already a delegation spec.

Ledger entry shape (one finding per entry):

```text
- [ ] <file>:<line> — <defect or symptom in one line>
      fix: <minimal proposed change>
      confidence: <high|medium|low>
      verify: <test or command that must pass>
```

Delegation rules for the fan-out:

- One repository = one agent. Parallel agents never share a repository.
- Each agent works in an isolated git worktree and branch, never on the
  orchestrator's own checkout.
- Merging is done only by the orchestrator, after independent verification
  (re-running tests or inspecting the diff).
- State four things explicitly in each delegation prompt, in addition to the
  section 1 clauses:
  1. Do not merge. Stop at the commit / branch / pull-request stage.
  2. Leave the worktree in place (no cleanup), so the orchestrator can
     inspect it.
  3. Tick the ledger entries you completed (`[ ]` to `[x]`) in the ledger
     that belongs to your repository.
  4. Report measured results only (test output you actually ran), never
     assumptions.
- One writer per ledger file: keep one ledger per repository (each agent
  ticks only its own), or keep a central ledger that only the orchestrator
  ticks based on agent reports. Two agents must never write the same ledger
  file.
- For a repository without a remote, "leave the branch in place, orchestrator
  fast-forward merges" is the safe and fast pattern.

Field results from one measured session: 14 agents fanned out in parallel over
a multi-repository fix backlog returned with zero no-ops and all test suites
green — roughly 40 ledger entries landed as 17 pull requests plus 4 local
merges in a single pass. Precise specs also invite agent-side good judgment:
one agent noticed that the wording of its own new test would trip a scanner
rule it was adding, and fixed that unprompted.

## Safety Conditions

- Delegate only when (a) edits are confined to the target repository, (b) the
  task touches no secrets, tokens, or real user data and transmits nothing
  externally, and (c) no destructive commands (bulk deletion, force push) are
  involved. Otherwise the orchestrator does the work directly.
- A delegated writer must have an exclusive checkout or isolated worktree.
  If another writer, unassigned existing WIP, or unclear ownership is
  detected, the agent reports the conflict without modifying Git state or
  files.
- Recovery re-instruction at most once in the normal path (section 3); if
  the resumed attempt also no-ops, the orchestrator takes over. Set a hard
  stop rule: after three attempts at the same failure class, stop and report
  instead of retrying.
- Treat "I executed X" claims in subagent reports as verified or unverified,
  and label them accordingly.

## Completion Checklist

- Artifacts exist exactly as the acceptance criteria describe (path, content,
  encoding).
- The agent recorded its initial branch/status and had exclusive checkout
  ownership before editing; unassigned pre-existing WIP was not altered or
  absorbed.
- The `git status --porcelain` diff matches expectations, with nothing extra.
- The subagent's report and the measured reality agree; any discrepancy has
  been root-caused.
- In ledger mode: ticked ledger entries match the changes that were actually
  verified and merged.

## Reporting

- Where you delegated (model, tool) and why that route fit the task profile.
- Verification method and result (porcelain output summary, artifact paths
  checked).
- Any no-op or environment-difference incident: symptom, isolation result,
  and recovery taken.
- Unverified items marked explicitly as unverified.
