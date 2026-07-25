# multi-agent-delegation

[![Validate](https://github.com/h8nc4y/multi-agent-delegation/actions/workflows/validate.yml/badge.svg)](https://github.com/h8nc4y/multi-agent-delegation/actions/workflows/validate.yml)

An agent skill for Claude Code and Codex that prevents silent no-op failures
when an orchestrator agent delegates work to subagents — mandatory
delegation-prompt clauses, artifact verification of completion notices,
resume-based recovery, and ledger-as-spec parallel delegation.

## What It Solves

When an orchestrator agent delegates a task to a subagent, two failure modes
waste time and tokens while looking like success:

- **No-op delegation**: the subagent re-delegates to a child agent of its own,
  replies "delegated, waiting for completion", and terminates. The
  orchestrator receives a successful-looking completion notice while the git
  working tree is unchanged.
- **Silent environment failure**: the task "succeeds" in the wrong execution
  environment (WSL vs Git Bash vs PowerShell vs sandbox), for example because
  a dependency CLI is missing there, and nobody notices until much later.

This skill gives the orchestrator a discipline: mandatory clauses for every
delegation prompt, verification of every completion notice against real
artifacts, a resume-based recovery path that keeps the subagent's context,
and a ledger-as-spec pattern for fanning out many fixes to parallel
subagents safely.

## Who It Is For

- Claude Code users who delegate work with the `Agent` tool (subagents).
- Codex users who run delegated tasks or collaborator threads.
- Anyone building multi-agent orchestration who needs completion notices to
  mean something.

## Install

Clone the repository:

```bash
git clone https://github.com/h8nc4y/multi-agent-delegation.git
cd multi-agent-delegation
```

### Claude Code

Claude Code auto-invokes the skill when a task matches the `description`
frontmatter. Install for your user account on shells with POSIX syntax:

```bash
dest="${HOME}/.claude/skills/multi-agent-delegation"
if [ -e "$dest" ]; then
  echo "Install target already exists: $dest"
else
  mkdir -p "$dest"
  cp SKILL.md "$dest/SKILL.md"
fi
```

Install for your user account from PowerShell:

```powershell
$dest = Join-Path $HOME '.claude\skills\multi-agent-delegation'
if (Test-Path -LiteralPath $dest) {
  throw "Install target already exists: $dest"
}
New-Item -ItemType Directory -Path $dest | Out-Null
Copy-Item -LiteralPath .\SKILL.md -Destination (Join-Path $dest 'SKILL.md')
```

Notes:

- If you set `CLAUDE_CONFIG_DIR`, replace `~/.claude` with that directory.
- To scope the skill to a single project instead, copy `SKILL.md` to
  `.claude/skills/multi-agent-delegation/SKILL.md` inside that project's
  repository.

The existence guard is intentional: do not overwrite an already-installed
skill without reviewing the local copy first.

### Codex (agent skills)

Manual Codex-style skill install on shells with POSIX syntax:

```bash
dest="${HOME}/.agents/skills/multi-agent-delegation"
if [ -e "$dest" ]; then
  echo "Install target already exists: $dest"
else
  mkdir -p "$dest"
  cp SKILL.md "$dest/SKILL.md"
fi
```

Manual Codex-style skill install from PowerShell:

```powershell
$dest = Join-Path $HOME '.agents\skills\multi-agent-delegation'
if (Test-Path -LiteralPath $dest) {
  throw "Install target already exists: $dest"
}
New-Item -ItemType Directory -Path $dest | Out-Null
Copy-Item -LiteralPath .\SKILL.md -Destination (Join-Path $dest 'SKILL.md')
```

To scope the skill to a single project instead, copy `SKILL.md` to
`.agents/skills/multi-agent-delegation/SKILL.md` inside that repository —
Codex scans `.agents/skills` from the working directory up to the repository
root (per the official skills documentation).

If your agent reads skills from a different directory, check its
documentation and copy `SKILL.md` into the matching
`skills/multi-agent-delegation/` folder.

## Manual Use

Reach for the skill when you see one of these symptoms:

- A completion notice arrived, but the expected files or git changes do not
  exist.
- A subagent replied that it delegated to another agent and is waiting.
- A delegated task reports success, but the executing environment (WSL /
  Git Bash / PowerShell / sandbox) never actually ran the real work.
- You are about to write a delegation prompt and want the mandatory clauses.
- A review produced dozens of findings and you want to fan them out to
  parallel subagents without losing control of merges.

Follow the procedure in [SKILL.md](SKILL.md): put the mandatory clauses in
the delegation prompt, verify the completion notice against artifacts,
resume the same agent once on a no-op, isolate environment differences, and
use the ledger-as-spec pattern for large fan-outs.

## Synthetic Examples

- [Delegation prompt template](examples/delegation-prompt-template.md)
- [Completion verification checklist](examples/verification-checklist.md)
- [Ledger template for parallel delegation](examples/ledger-template.md)

The examples use placeholders only. Do not replace them with secrets, real
repository paths you cannot publish, or customer data in public issues.

## 日本語概要 (Japanese Overview)

サブエージェントへ委譲したときの「空振り」（子へ再委譲して待機し、成果物ゼロの
まま成功に見える完了通知が返る）と「無言失敗」（実行環境差で成功したフリになる）
を防ぐための、司令塔エージェント向けの規律です。

- 委譲プロンプトの必須文言（再委譲禁止・成果物パスと受け入れ条件・変更ファイル
  一覧の報告・書式制約）
- 完了通知の実在検証（`git status --porcelain` / ファイル実在確認）
- 同一エージェント resume によるリカバリ（新規起動より安くて速い）
- 実行環境差（WSL / Git Bash / PowerShell / sandbox）の切り分け
- 台帳（file:line＋最小修正案＋confidence）をそのまま委譲 spec にする並列委譲

日本語の完全版は [docs/SKILL.ja.md](docs/SKILL.ja.md) にあります。インストールは
上記の手順どおり、`SKILL.md` を Claude Code なら `~/.claude/skills/multi-agent-delegation/`
へ、Codex なら `~/.agents/skills/multi-agent-delegation/` へコピーしてください。

## Safety Notes

- Delegate only tasks confined to the target repository, with no secrets,
  tokens, or real user data involved, and no destructive commands.
- Never paste tokens, credentials, private logs, or customer data into
  delegation prompts, ledgers, or public issues.
- A completion notice is a claim, not evidence. Report unverified items as
  unverified.

## Limitations

- This skill does not make subagents smarter; it makes their failures visible
  and recoverable.
- It assumes the orchestrator can run Git and shell commands to verify
  artifacts. If verification itself is blocked, report that limitation
  explicitly.
- Tool names (`Agent` tool, `SendMessage`) are Claude Code specifics; the
  mapping for other environments is described in SKILL.md, but exact resume
  semantics differ per tool.
- CI measures PowerShell 7 and Windows PowerShell 5.1 on Windows, plus
  PowerShell 7 on Ubuntu 24.04.

## Non-Goals

- No automation scripts that spawn or control agents. This repository is a
  written discipline, not an orchestration framework.
- No claims about specific vendor model behavior beyond the observed failure
  modes documented in the skill.

## Validation

Run the full local validation from the repository root:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\validate-oss-readiness.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-scan-private-markers.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\scan-private-markers.ps1
```

If `pwsh` is available, the same checks can be run with:

```powershell
pwsh -NoProfile -File .\scripts\validate-oss-readiness.ps1
pwsh -NoProfile -File .\scripts\test-scan-private-markers.ps1
pwsh -NoProfile -File .\scripts\scan-private-markers.ps1
```

On Linux with PowerShell 7 (`pwsh`) and trusted `setsid` at
`/usr/bin/setsid` or `/bin/setsid`:

```bash
pwsh -NoProfile -File ./scripts/validate-oss-readiness.ps1
pwsh -NoProfile -File ./scripts/test-scan-private-markers.ps1
pwsh -NoProfile -File ./scripts/scan-private-markers.ps1
```

The scan self-test uses the exact PowerShell host that launched it instead of
silently preferring `pwsh`. It exercises clean and failing scans, synthetic
secret prefixes, index/worktree divergence, intent-to-add files, sensitive
file names, a missing working-tree file, symlink/reparse rejection,
repository-root/probe failures, snapshot mutation, a hostile Git environment,
present-empty removal and preservation, redaction, exact byte transport,
native Git batch bytes without a BOM, caller input-encoding preservation,
outside-artifact prevention, and bounded child-tree/output-pipe termination.
On POSIX it also injects direct-delay and fork-delay `setsid` launchers to
prove that no target runs before a verified process-group release and that a
late group is removed without leaving its private gate directory.
An AST regression requires the raw binary fixture to remain the first eager
production-runner call, including against deferred scriptblocks and
`ScriptBlock.Invoke*()` cases. Function call graphs, scope-qualified calls,
in-source aliases, static function-provider/`Get-Command` references, and later
references to direct or function-indirect stored scriptblocks are followed
before that fixture. `Get-Variable`/`gv` recovery is fail closed unless its
literal target is a uniquely assigned top-level, unqualified or `script:`
variable whose value is exactly `{ $_ }` or `{ $PSItem }` with an unqualified
current-item variable, and that assignment completes before the eager call.
This positive proof propagates through in-source aliases, early
direct/transitive wrappers, and aliases to those wrappers. Unknown or unbound
targets, runtime-created or reassigned scriptblocks, scope-mismatched
assignments, qualified current-item variables, variable mutation, deferred
IEX/unknown/dynamic calls, risk-sensitive command aliases, alias import/remove,
module import/new/`using module` outside the exact module-qualified bootstrap,
Alias:/Function: provider copy/move/rename/remove/clear, external PowerShell
script execution, unbound call-operator targets, wildcards, and omitted names
are rejected. A function-local call-operator target is accepted only when it is
uniquely bound to a literal scriptblock whose body passes the same identity
checks. Shadowed lookup names remain fail closed because their runtime identity
cannot be proven. Target-name function/alias shadowing, invoked risky class
constructors/methods, derived classes with a risky direct or transitive base
constructor, `Invoke-Expression`, and unresolved dynamic calls/lookups fail
conservatively. An unused lookup wrapper and the explicitly proven safe
scriptblock lookup remain allowed. A literal application lookup such as
`Get-Command git -CommandType Application` remains allowed. The only early
`Remove-Item` wrapper exceptions are a fixed `Env:` path and the exact
SHA-256-pinned bounded fixture-cleanup function. The runner module bootstrap is
likewise limited to the SHA-256-pinned source prefix and
`Microsoft.PowerShell.Core\Import-Module` of the sibling runner module. Scanner
entry/helper/isolation failures return one fixed redacted stdout line, empty
stderr, and exit code 2. Workflow validation fixes the top-level triggers,
read-only permission, two job IDs, job-local permission absence, exact steps,
and full-SHA action pins.
Every scanner and Git child process has a finite timeout, and each scan has a
two-minute monotonic deadline. A child operation's budget begins before
environment preparation and process launch; termination and resource cleanup
use a separate bounded kill-wait allowance. The public deadline parameter is
lower-only (`1..120000` milliseconds), so a test can shorten the budget but no
caller can extend production execution. The exported process runner accepts
only canonical integer values for its numeric arguments; fractional,
exponential, aggregate, and overflow inputs are rejected with
`process-limit-invalid` instead of PowerShell's numeric coercion. Invalid
public scan-deadline values are validated inside the scanner entrypoint and
return one fixed stdout line, empty stderr, and exit 2.

For a repository-root scan, the scanner takes a byte-exact index/debug
snapshot, reads every unique regular stage-0 blob through one
`git cat-file --batch` process, and scans a safe current-worktree copy when it
differs or represents an intent-to-add file. This index/worktree union catches
both committed/staged content and unstaged edits. It rejects unmerged,
symlink, gitlink, reparse, malformed, missing-object, oversized, and
aggregate-size-invalid input. It also fails closed when Git probing does not
resolve exactly to the requested root, when a root or ancestor `.git` entry
cannot establish that exact root, or when either raw snapshot changes during
the scan. A non-reparse regular `.git` gitfile for a linked worktree or
submodule is accepted only after the same bounded probe establishes the exact
requested root. Broken, dangling, reparse, and mismatched control metadata return
exit code 2 and exactly `Private marker scan failed closed (integrity:
git-probe).` Nested `.git` directories and leaf files below a true non-Git scan
root are control metadata excluded from fallback traversal; they are not opened
or scanned. On a case-sensitive POSIX filesystem, `.GIT` is an ordinary name
and remains in the fallback scan. Index metadata is capped at 8 MiB and 4,096 entries. NUL-delimited
metadata and batch responses are parsed incrementally and validated against the
exact request order.

Each child starts from a fixed minimal environment instead of a clone of the
scanner process. Windows receives only an OS-derived `SystemRoot`; POSIX
receives no ambient values. Git then receives only explicit non-interactive,
read-only `GIT_*` settings, `GCM_INTERACTIVE=Never`, locale `C`, and empty
global/system config, hooks, attributes, excludes, and template paths. The file
reader receives only fixed PowerShell module-search/cache null-device controls,
telemetry/update opt-outs, and the selected input path. `PATH`, temp,
home/profile, loader/profiler, cloud credential, token, and SSH-agent variables
are not inherited. Because PowerShell 7 prepends default module paths during
startup, the reader reasserts the null-device module path before its first
unqualified command. This prevents external helpers and repository, index,
object, config, execution, prompt, or trace overrides from changing the tracked
scan or writing outside its temporary isolation directory.
The scanner resolves `git` only as a native application, fixes the first PATH
candidate, and requires a rooted regular non-reparse file. A normal Windows
hard link remains a regular file; aliases, functions, scripts, symbolic links,
and junction/reparse targets are not accepted.
Lazy promisor fetches and replacement refs are disabled, and protocol and
credential-helper use is denied, so a missing blob fails locally instead of
starting a remote helper or substituting different content. Git 2.43 emits
one observed English warning when `GIT_NO_LAZY_FETCH=1` returns a missing
promisor object; the batch boundary fixes the child locale to `C` and accepts
only that exact LF/CRLF byte sequence. Any additional stderr still fails the
scan.

Child-process byte streams preserve arbitrary stdin/stdout/stderr bytes and
enforce output caps. Windows starts each process suspended, attaches it to a
kill-on-close Job Object with an explicit inherited-handle list, then resumes
it. Launch-failure cleanup checks Job/process termination, bounded waits, and
every owned pipe/thread/process/Job handle close. Linux starts a new session
through trusted `setsid`. An owner-only gate under fixed `/tmp` records the
new session leader, and the parent verifies `getpgid(pid) == pid` before it
creates the one-shot release file that permits `exec`. Timeout or launch
failure before that point never releases the target; direct-launcher exit is
followed by a bounded late-ready probe and checked process-group termination.
Final cleanup probes the verified group even when the direct launcher has
already exited, then removes only the known gate files and non-recursive
directory. Other POSIX environments without one of the trusted `setsid` paths
fail closed instead of silently falling back to parent-only termination. The
Windows path writes raw pipe handles from C#
after direct `CreateProcessW`; it does not pass bytes through PowerShell's
text `StandardInput` writer or require a PowerShell proxy. The self-test sends
an arbitrary binary fixture first, then compares a native
`git cat-file --batch` response byte-for-byte and confirms that the caller's
`Console.InputEncoding` code page and preamble are unchanged on return.
Both OS paths explicitly dispose completed stream-pump tasks, pipe streams, and
buffers. After the main self-test proves raw byte transport, Windows launches
a dedicated handle-probe script in a fresh instance of the same PowerShell
executable. That host measures a forty-invocation startup window with a bounded
aggregate handle-growth allowance, then applies tighter final and peak limits
to a separate forty-run steady-state window. Both windows run without forcing
GC; isolating earlier self-test tasks avoids attributing unrelated host cleanup
to a per-call leak while still bounding startup and steady-state growth. POSIX
keeps its forty-run no-GC file-descriptor regression.
OSS readiness seals the dedicated Windows probe's canonical UTF-8 source with
SHA-256 and separately checks its loop headers, direct child-runner statements,
result guards, handle updates, and thresholds through the PowerShell AST.
The first-call AST gate also rejects Alias:/Function: mutations through
`Set-Item`, `Set-Content`, `New-Item`, provider copy/move/rename/remove/clear,
alias import/remove, unapproved module loading,
direct/call-operator/dot-sourced PowerShell scripts,
dynamic bootstrap dot-sourcing, composite `.Invoke()` receivers, risky class
casts/static initialization, and literal or dynamic `Get-Variable` recovery of
a risky stored scriptblock.

Explicit non-Git fixture directories use a one-level-at-a-time working-tree
walk. Links and reparse points are rejected before traversal or content reads.
Each content read runs in a bounded child, so a FIFO, device, or replacement
race cannot stop the parent scanner indefinitely. Working-tree enumeration is
also capped at 4,096 entries. Text input is capped at 4 MiB per file and
64 MiB per scan in either mode. A text file is capped at 100,000 lines,
all text at 200,000 lines per scan, detailed findings at 1,024 plus one
aggregate notice, and configured local markers at 256 entries of at most 1,024
characters each. Regex match enumeration is capped at 4,096 matches per line.
A tracked `.private-markers.local` violates its untracked-only contract and
fails the scan without printing its contents.

Also run Git whitespace checks on your working changes before publishing:

```bash
git diff --check
```

The GitHub Actions workflow runs validation, the private-marker self-test and
repository scan, and whitespace checks on Windows and Ubuntu 24.04. Windows
tests both PowerShell 7 and Windows PowerShell 5.1; Ubuntu tests PowerShell 7.
Each job has a 25-minute timeout.

## Contributing

Contributions are welcome when they make the discipline safer, clearer, or
easier to verify. Read [CONTRIBUTING.md](CONTRIBUTING.md) before opening a
pull request.

Keep all examples synthetic. Do not include tokens, credentials, private
repository names, internal absolute paths, or customer data.

For local-only private markers, create an untracked `.private-markers.local`
file with one literal marker per line, or set
`MULTI_AGENT_DELEGATION_PRIVATE_MARKERS` with newline-separated markers. The
scanner reads these values but does not print the matched marker.

## Security

If you find unsafe guidance or accidental private-data exposure, follow
[SECURITY.md](SECURITY.md) and use private reporting for sensitive details.

## License

MIT. See [LICENSE](LICENSE).
