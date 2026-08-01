# CI timeout documentation contract

## 目的と分類

- **分類**：Class M。
- **目的**：workflowの3 OS jobへ設定した25分の上限と、READMEおよび
  CONTRIBUTINGの利用者向け説明が同じ契約を維持する。
- **影響**：README、CONTRIBUTING、OSS readiness validator、focused test、
  CHANGELOG。
- **非影響**：workflowのtrigger、permission、job、step、runner、
  `timeout-minutes`値、tag、Releaseは変更しない。

## 要件

1. READMEとCONTRIBUTINGは、Windows、Ubuntu、macOSの各CI jobが25分に
   制限されることを同じexact句で1件だけ記載する。
2. validatorは同じ25分定数をworkflowの3 jobと2文書の検査に使う。
3. 20分への変更、macOSの欠落、矛盾する別のjob timeout文の併記を含む
   in-memory mutationを拒否する。
4. 文書はstrict UTF-8として読み、PowerShell 7とWindows PowerShell 5.1で
   同じ判定を返す。
5. Release候補の公開判断とowner gateは変更しない。

## Test plan

- **RED**：focused testで旧READMEのOS省略を拒否する。
- **GREEN**：READMEとCONTRIBUTINGの正本句、必須3 mutation、語順・単位表記を
  変えた6件の曖昧化を
  PowerShell 7とWindows PowerShell 5.1で検証する。
- **hygiene**：変更fileのstrict UTF-8、BOM方針、LF、NUL不在、
  `git diff --check`を確認する。
- **回帰**：host-wide scannerとreadiness全体は司令塔の排他gateで直列実行する。
- **review**：source freeze後に独立reviewを行う。

## Handoff

- **状態**：pull request #21をhead `ce36ead8a15295d985a09a70fec139588ab9a8bc`、
  merge commit `f7588b2769a809179b6def2712f2d6a24c03128e`で統合済み。
- **RED**：focused testは旧READMEの3 OS明記不足を1件検出し、exit 1を返した。
- **実装**：job timeoutを扱う文をcanonical exact句1件だけに限定するpure
  matcherを追加した。
  READMEとCONTRIBUTINGの各fileに対して20分化、macOS欠落、矛盾する重複文、
  別語順のtimeout文、`min`短縮形、例外句、否定前置をmemory上で生成し、
  matcherが拒否する。
- **検証**：focused testはPowerShell 7とWindows PowerShell 5.1の両方で
  exit 0。
  変更した2 scriptは両hostのparserでerror 0。
  変更5 fileはstrict UTF-8、規定BOM、LF、NULなしで、`git diff --check`も
  error 0。
- **回帰境界**：司令塔の排他gateでPowerShell 7 / Windows PowerShell 5.1の
  full readinessとactual private-marker scanがPASSした。
  Gitleaksはhistory 36 commits / worktreeともfinding 0、Semgrep `p/default`は
  82 rules / 33 tracked targetsでfinding 0だった。
- **独立review**：初回P2 1件は曖昧性検出の語順不足だった。
  sentence-level matcherと5 counterexample mutationを追加して解消した。
  続くP3 1件はhandoffを実装どおりのexact句限定へ直し、最終P0、P1、P2、
  P3をclearにした。root reviewのP2 1件は`min`短縮形を候補化し、
  counterexampleへ追加して解消し、`min` / `mins`を両PowerShellで拒否した。
- **外部境界**：secret、OAuth、実データ、production、deploy、費用、
  tag、Releaseは使用しない。
- **統合証拠**：pull request head run `30586873953`とpost-main run
  `30587286612`は、Windows、Ubuntu、macOSの3 jobすべてがsuccess。
  両runで対象のOSS readinessとprivate-marker検証もsuccess。
- **残作業**：この契約に残作業なし。`v0.2.0`のversion、target commit、
  公開日時、final release notesはrelease owner gateとして引き続き未確認。
