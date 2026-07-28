# Delegation Prompt Template

Copy this template when delegating a task to a subagent. Replace every
`<placeholder>`. The six mandatory clauses from SKILL.md section 1 are
marked `[MANDATORY]` — do not remove them.

All values below are synthetic placeholders. Never paste secrets, tokens, or
private data into a delegation prompt.

## English template

```text
Task: <one-line objective>

[MANDATORY] Re-delegation to other agents is forbidden. Execute the work
yourself with your file-edit and shell tools (Read/Edit/Write/Bash or this
environment's equivalents).

Target checkout / worktree (absolute path): <exclusive-checkout-path>
(assigned exclusively to you)
Work branch: <branch-name> (use or create it only in the assigned checkout /
worktree; do not commit to the default branch)

Checkout ownership [MANDATORY]:
- Before editing, report the current branch and run
  `git status --porcelain`.
- You must be the exclusive writer for this checkout. If existing WIP is
  present and was not explicitly assigned to you, another writer is using the
  checkout, or ownership is unclear, stop and report the conflict. Do not
  edit, commit, push, or merge.
- Do not stash, reset, delete, or absorb unassigned pre-existing WIP. Continue
  only in the exclusive checkout or isolated worktree and task branch assigned
  to you.

Completion verification baseline [MANDATORY]:
- Before editing, record the current branch, the full OID from
  `git rev-parse --verify HEAD`, and all output from
  `git --no-optional-locks status --porcelain=v1 --untracked-files=all`.
- For non-Git artifacts and explicitly assigned dirty-resume artifacts, also
  record pre-edit existence, byte size, and SHA-256. Do not read or hash
  unassigned WIP; stop on that ownership conflict.
- Baseline collection is read-only. Do not use `git write-tree`, `update-index`,
  stash, reset, checkout, or another command that changes Git or file state.

Deliverables and acceptance criteria [MANDATORY] (use absolute artifact
paths):
- <artifact-path-1> — exists and contains <required-content-summary>
- <artifact-path-2> — updated so that <acceptance-condition>
- All of: <test-or-lint-command> passes.

Format constraints [MANDATORY]:
- Encoding: UTF-8 without BOM, LF line endings.
- <append-only | do-not-overwrite | other constraint>

Completion report [MANDATORY]:
- Include the list of changed files (paths).
- Include the actual output of <verify-command> (measured, not assumed).
- Include the final branch and full HEAD OID, baseline-to-final
  `git diff --name-status`, current porcelain with all untracked files, and
  artifact content/state evidence. For an existing baseline HEAD, include the
  exit result of `git merge-base --is-ancestor <baseline> <final>`; exit 0 is
  required. A clean committed task is not a no-op merely because final
  porcelain is empty, but divergent history is never valid completion.
- Anything you could not verify must be labeled "unverified".

Scope guard:
- Edit only inside <exclusive-checkout-path>.
- Do not touch secrets, tokens, or real user data. Transmit nothing
  externally.
- No destructive commands (bulk deletion, force push).
```

## 日本語テンプレート

```text
タスク: <目的を1行で>

【必須】他エージェントへの再委譲禁止。あなた自身が Read/Edit/Write/Bash
（またはこの環境の同等ツール）を実行すること。

対象 checkout / worktree（絶対パス）: <exclusive-checkout-path>
（あなた専用として割当済み）
作業ブランチ: <branch-name>（割当済み checkout / worktree 内だけで使用または
作成し、デフォルトブランチへ直接コミットしない）

checkout の所有権【必須】:
- 編集前に現在 branch を報告し、`git status --porcelain` を実行する。
- この checkout の排他的 writer であること。明示的に割り当てられていない既存 WIP、
  同じ checkout の別 writer、または所有権不明を検出した場合は停止して競合を報告し、
  編集、commit、push、merge を行わない。
- 未割当の既存 WIP を stash、reset、削除、自分の commit へ混入しない。割り当て
  られた排他的 checkout または隔離 worktree と task branch でのみ続行する。

完了検証baseline【必須】:
- 編集前に現在branch、`git rev-parse --verify HEAD`の完全OID、
  `git --no-optional-locks status --porcelain=v1 --untracked-files=all`の全出力を記録する。
- non-Git成果物と明示的に割り当て済みのdirty resume成果物では、編集前の実在、
  byte size、SHA-256も記録する。未割当WIPは開いたりhash化したりせず、競合として停止する。
- baseline取得はread-onlyとし、`git write-tree`、`update-index`、stash、reset、
  checkoutなどGit stateやfileを変更するcommandを使わない。

成果物と受け入れ条件【必須】（成果物も絶対パスで指定）:
- <artifact-path-1> — 存在し、<required-content-summary> を含む
- <artifact-path-2> — <acceptance-condition> を満たすよう更新されている
- <test-or-lint-command> がすべて通る。

書式制約【必須】:
- エンコーディング: UTF-8 BOMなし・LF 改行。
- <追記のみ | 上書き禁止 | その他の制約>

完了報告【必須】:
- 変更ファイル一覧（パス）を含めること。
- <verify-command> の実際の出力を含めること（実測のみ。推測は書かない）。
- 最終branchと完全HEAD OID、baseline→finalの`git diff --name-status`、untrackedを
  全件含む現在porcelain、成果物の内容/state証拠を含めること。baseline HEADが存在する
  場合は`git merge-base --is-ancestor <baseline> <final>`のexit結果も含め、exit 0を
  必須とする。commit済みでcleanなtaskを最終porcelainが空という理由だけで空振りに
  しないが、divergent historyを完了扱いしない。
- 検証できなかった項目は「未検証」と明記すること。

スコープ制約:
- 編集は <exclusive-checkout-path> 内に限定する。
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
| Exclusive checkout ownership | Concurrent writers overwriting or absorbing pre-existing WIP into the wrong task. |
| Baseline-aware completion evidence | Pre-existing artifacts faking success, or clean committed work being mislabeled a no-op. |
