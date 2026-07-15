# Delegation Prompt Template

Copy this template when delegating a task to a subagent. Replace every
`<placeholder>`. The four mandatory clauses from SKILL.md section 1 are
marked `[MANDATORY]` — do not remove them.

All values below are synthetic placeholders. Never paste secrets, tokens, or
private data into a delegation prompt.

## English template

```text
Task: <one-line objective>

[MANDATORY] Re-delegation to other agents is forbidden. Execute the work
yourself with your file-edit and shell tools (Read/Edit/Write/Bash or this
environment's equivalents).

Target repository: <repo-root-path>
Work branch: <branch-name> (create it; do not commit to the default branch)

Deliverables and acceptance criteria [MANDATORY]:
- <artifact-path-1> — exists and contains <required-content-summary>
- <artifact-path-2> — updated so that <acceptance-condition>
- All of: <test-or-lint-command> passes.

Format constraints [MANDATORY]:
- Encoding: UTF-8 without BOM, LF line endings.
- <append-only | do-not-overwrite | other constraint>

Completion report [MANDATORY]:
- Include the list of changed files (paths).
- Include the actual output of <verify-command> (measured, not assumed).
- Anything you could not verify must be labeled "unverified".

Scope guard:
- Edit only inside <repo-root-path>.
- Do not touch secrets, tokens, or real user data. Transmit nothing
  externally.
- No destructive commands (bulk deletion, force push).
```

## 日本語テンプレート

```text
タスク: <目的を1行で>

【必須】他エージェントへの再委譲禁止。あなた自身が Read/Edit/Write/Bash
（またはこの環境の同等ツール）を実行すること。

対象リポジトリ: <repo-root-path>
作業ブランチ: <branch-name>（新規作成。デフォルトブランチへ直接コミットしない）

成果物と受け入れ条件【必須】:
- <artifact-path-1> — 存在し、<required-content-summary> を含む
- <artifact-path-2> — <acceptance-condition> を満たすよう更新されている
- <test-or-lint-command> がすべて通る。

書式制約【必須】:
- エンコーディング: UTF-8 BOMなし・LF 改行。
- <追記のみ | 上書き禁止 | その他の制約>

完了報告【必須】:
- 変更ファイル一覧（パス）を含めること。
- <verify-command> の実際の出力を含めること（実測のみ。推測は書かない）。
- 検証できなかった項目は「未検証」と明記すること。

スコープ制約:
- 編集は <repo-root-path> 内に限定する。
- secret / token / 実データに触れない。外部送信しない。
- 破壊的コマンド（一括削除・force push）を使わない。
```

## Why each clause exists

| Clause | Failure it prevents |
| --- | --- |
| Re-delegation forbidden | Subagent spawns a child, idles, and returns a no-op completion notice. |
| Artifact paths + acceptance criteria | "Done" claims that cannot be checked against anything. |
| Changed-file list in report | Forces the subagent to look at its own diff; makes orchestrator verification one command. |
| Format constraints | Silent corruption (BOM, CRLF, overwritten files) that passes casual review. |
| Measured output only | Success-sounding reports written from assumptions instead of executed commands. |
