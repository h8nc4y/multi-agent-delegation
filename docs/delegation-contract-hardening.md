# Delegation contract hardening

## 目的と分類

- **分類**：Class M。
- **目的**：委譲先が編集前に未割当 WIP と他 writer の有無を確認し、排他的な checkout または隔離 worktree を所有できない場合は変更せず司令塔へ返す。
- **影響**：`SKILL.md` の必須委譲句、日本語版、委譲テンプレート、完了確認 checklist、README、validator、Windows CIを同じ契約へ同期する。
- **非影響**：scanner の実行境界は変更しない。

## 背景

一般委譲テンプレートは対象 repository と branch を指定する一方、同じ checkout を別の agent が編集中か、未割当 WIP が残っているかを編集前に確認する契約を必須化していなかった。
ledger mode では「1 repository = 1 agent」と隔離 worktree を要求するが、単独委譲のテンプレートには同等の fail-closed 境界がない。

複数 writer が同じ checkout を共有すると、変更の上書き、別 task の commit への混入、検証対象と実際の diff の不一致が起こり得る。
委譲先は編集前に競合を検出し、変更せず司令塔へ返す。

## 要件

1. 必須委譲句に checkout ownership を追加する。
2. 委譲先は最初に branch と `git status --porcelain` を確認する。
3. 明示的に割り当てられていない既存 WIP、同じ checkout の別 writer、または ownership 不明を検出した場合は、編集、commit、push、merge を行わず司令塔へ報告する。
4. 同一 thread で resume した agent は、自身へ明示的に割り当て済みの WIP を継続できる。
5. 並列 writer が必要な場合は、agent ごとに隔離 worktree と task branch を割り当てる。
6. 未割当の既存 WIP を stash、reset、checkout、削除、または自分の commit へ混入しない。
7. 契約は英語正本、日本語版、synthetic template、verification checklist で一致させる。
8. validator は上記の正本と利用者向け artifact の必須句を fail closed で検査する。

## Test plan

- **RED**：現行 validator が checkout ownership 句を持たない artifact を通すことを確認する。
- **validator**：新しい必須句が欠落した artifact を current tree で拒否し、同期後は通す。
- **negative fixtures**：exclusive assignment、conflict stop、same-thread resume、absolute pathの意味反転をmemory上で拒否する。
- **regression**：PowerShell 7とWindows PowerShell 5.1で`validate-oss-readiness.ps1`を実行する。
- **scanner**：PowerShell 7 と Windows PowerShell 5.1 の scanner self-test、および repository scan。
- **hygiene**：`git diff --check`、UTF-8 / LF、Gitleaks、Semgrep。
- **review**：source freeze 後の独立 review で P1 / P2 / P3 が 0。

## Handoff

- **状態**：初回独立レビューのP1 1件、P2 3件、P3 1件を修正し、最終freezeの独立cross-reviewでP0 / P1 / P2 / P3すべて0、clearance YESを確認した。PR #8をmerge commit `41c7936`で`main`へ統合済み。
- **RED**：旧契約を通す baseline から新しい assertions だけを追加した状態で validator を実行し、SKILL、翻訳、bilingual template、checklist、README の5 artifact不足を exit 1 で確認した。
- **契約検証**：部分regexを15個のexact semantic blockへ置換し、意味を反転する17件のin-memory synthetic mutationをPowerShell 7とWindows PowerShell 5.1の両hostで拒否した。
- **host互換性**：独立レビューでWindows PowerShell 5.1のBOMなしUTF-8 MarkdownがANSI decodeされる問題を検出したため、validatorの内容読込とfrontmatter読込を明示的なUTF-8へ変更し、PowerShell 7とWindows PowerShell 5.1のreadinessを再実行して成功した。
- **CI**：Windows jobへWindows PowerShell 5.1のreadiness stepを追加し、validatorでjob shapeとstep契約を固定した。PR #8のGitHub Actions run `30237036286`ではWindows、Ubuntu、macOSの3 jobがすべて成功し、Windows PowerShell 5.1のreadiness stepも成功した。
- **scanner regression**：修正後のPowerShell 7 self-testは184.21秒、Windows PowerShell 5.1 self-testは158.10秒で成功し、repository scanも19.75秒で成功した。
- **security scan**：修正後のGitleaksはworking tree 676.08 KB、履歴20 commits、最終staged差分31.07 KBで0 findingsだった。commit時のglobal Gitleaks hookも成功した。
- **Semgrep**：local 5 rulesはexit 0だったが、対象言語fileがないためtargets 0であり、PowerShellとMarkdownのcoverageには数えない。
- **hygiene**：変更fileのUTF-8 / LF / NUL不在と `git diff --check` は成功した。
- **外部境界**：公開GitHub repositoryのPR #8作成とmerge以外に、外部 agent 送信、secret / OAuth / credential、実データ、production、deploy、費用は使用していない。
- **残作業**：なし。
  `main`の一致、clean tree、readinessは後続のcloseoutで確認済み。
- **closeout（2026-07-29）**：現在の`main`は
  `ca24dc70258a7a8f76a36fcc595ab0b64c4c33fe`で`origin/main`と一致し、
  tracked treeはclean、最新のmain run `30428993743`はsuccessだった。
  PowerShell 7 / Windows PowerShell 5.1のlocal readinessもexit 0だった。
