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

On macOS, Linux, or any POSIX shell with PowerShell 7 (`pwsh`) installed:

```bash
pwsh -NoProfile -File ./scripts/validate-oss-readiness.ps1
pwsh -NoProfile -File ./scripts/test-scan-private-markers.ps1
pwsh -NoProfile -File ./scripts/scan-private-markers.ps1
```

Also run Git whitespace checks on your working changes before publishing:

```bash
git diff --check
```

The GitHub Actions workflow runs the same validation, scan self-test,
private-marker scan, and whitespace check on pull requests and pushes to
`main`.

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
