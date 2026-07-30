# v0.2.0 release preparation

## 目的と分類

- **分類**：Class M。
- **目的**：`v0.1.0`以降の変更を`v0.2.0`候補として整理し、install、validation、security、hardening handoffの正本を同じ公開状態へ揃える。
- **影響**：`CHANGELOG.md`、`README.md`、`SECURITY.md`、完了済みhardening文書。
- **非影響**：runtime、scanner、skill契約、CI workflow、tag、GitHub Release、公開Release操作は変更しない。

## Release candidate

`CHANGELOG.md`の`0.2.0`節は候補内容であり、公開済みReleaseを表さない。

2026-07-30の着手時点ではremote tag `v0.1.0`だけが存在し、`v0.2.0` tagとGitHub Releaseは存在しなかった。

install手順は、変化し得る`main`と、remoteに実在する再現可能なtagを区別する。

validation手順は、候補のexact commitに対するlocal checksとWindows、Ubuntu、macOSのCI証拠を要求する。

## Owner gate

次の4項目はowner確認が済むまで`未確認`として扱う。

1. 公開versionが`v0.2.0`でよいか。
2. tagが指すexact commit。
3. 公開日時。
4. 最終release notes。

準備文書のmergeは、tag作成、GitHub Release作成、公開Release操作を認可しない。

## Test plan

- PowerShell 7とWindows PowerShell 5.1でOSS readinessを実行する。
- PowerShell 7とWindows PowerShell 5.1でprivate-marker scanner self-testを実行する。
- repository private-marker scan、Gitleaks、Semgrep、`git diff --check`を実行する。
- source freeze後に、公開状態、相互リンク、変更scope、owner gateの文言を独立reviewする。
- PRのexact headでWindows、Ubuntu、macOSの3 jobが成功したことを確認する。
- tagとGitHub Releaseが作成されていないことを再確認する。

## Handoff

- **状態**：release candidate文書の初回freeze、独立review、local validation、PR CI、mergeを完了。
  PR #18はcommit `d660855e17455778e888742611c50eee19a2ecfb`を
  merge commit `a9e6038350cc30122abd62e26be4023107b2d74a`として`main`へ統合した。
- **実施済み**：release関連正本のscope確認、stale handoffの修正、候補文面のfocused静的整合、
  P2 1件の修正と再review CLEAR。PowerShell 7とWindows PowerShell 5.1のreadinessおよび
  scanner self-test、PowerShell 7のrepository scanはexit 0だった。
  Gitleaksはdirectory、履歴33 commits、staged差分で0 findings、
  Semgrepは32 targets、82 rulesで0 findingsだった。global pre-commit hookも成功した。
- **CI**：PR run `30530337700`はWindows、Ubuntu、macOSの3 jobがsuccess。
  exact merge commitに対するmain run `30530788471`も3 jobがsuccess。
- **Owner gate**：version、target commit、公開日時、final notesはすべて`未確認`。
- **公開操作**：merge後もremote tagは`v0.1.0`だけで、GitHub Releaseは0件。
  `v0.2.0` tag、GitHub Release、公開Release操作は未実施。
- **次の一手**：ownerが4項目を決定した後、選定したexact commitでlocal validationと
  Windows、Ubuntu、macOSのCIを再確認し、tagとGitHub Releaseを別の公開操作として実施する。
