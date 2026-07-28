# Baseline-aware completion verification

## 目的と分類

- **分類**: Class M。
- **目的**: 完了通知を編集前のbaselineと比較し、既存成果物を指すだけの空振りと、
  cleanなcommitで正当に完了した変更を区別する。
- **影響**: 英語正本、日本語版、委譲テンプレート、完了確認checklist、README、
  CHANGELOG、readiness validatorを同じ契約へ同期する。
- **非影響**: agent起動、scanner、外部送信、credential、production、deployは変更しない。

## 背景

完了後の`git status --porcelain`と成果物の実在だけでは、次の2件を正しく判定できない。

1. 編集前から成果物が存在し、agentが何も変更しなかった場合でも「成果物あり」を成功と
   誤認できる。
2. 編集前のHEADから新しいcommitを作り、working treeをcleanにした正当な作業でも、
   空のporcelainを空振りと誤認できる。

同一threadで明示的に割り当て済みのdirty WIPを再開する場合は、編集前後とも同じpathが
porcelainに出ることがある。したがって、完了後の状態だけでなく、編集前からの変化を測る。

## Baseline契約

### 編集前

- Git repositoryでは、現在branch、`git rev-parse --verify HEAD`の完全OID、
  `git --no-optional-locks status --porcelain=v1 --untracked-files=all`の全出力を記録する。
- 受け入れ条件の成果物について、実在、byte size、SHA-256を記録する。少なくとも
  non-Git taskと、明示的に割り当て済みのdirty WIPを再開するtaskでは必須とする。
- 未割当WIPは内容を開いたりdigest計算したりせず、従来どおり編集前に停止する。
- baseline取得はread-only Git commandだけを使う。`git write-tree`、`update-index`、
  stash、reset、checkoutなど、index・working tree・object databaseを変更するcommandを
  baseline取得に使わない。

### 完了通知後

司令塔が同じcheckoutで独立して、最終branch、最終HEAD、baseline HEADから最終HEADまでの
`git diff --name-status <baseline>..<final> --`、現在の
`git --no-optional-locks status --porcelain=v1 --untracked-files=all`、成果物の
実在・内容・size・SHA-256を再測定する。baseline HEADが存在する場合は、
`git merge-base --is-ancestor <baseline> <final>`のexit 0を必須とする。

判定は次の証拠を合成する。

- baseline HEADと最終HEAD、initial→finalのporcelain、assigned artifact stateが
  すべて同じなら、既存成果物が受け入れ文言を満たしていてもfile-changing taskは空振り。
- 最終porcelainが空でも、HEADが変わり、baseline→final diffが割当済みpathを含み、
  baselineがfinal HEADのancestorで、成果物の内容が受け入れ条件を満たせばcommit済みの
  成功として扱う。同じbranch名とassigned-only diffだけではhistory保持の証拠にならず、
  rewritten / divergent historyはscope違反とする。
- 明示的に割り当て済みのdirty WIPを同一threadで再開する場合は、initialとfinalの
  artifact stateを比較する。initial / final porcelainのpath表示が同じだけでは空振りと
  判定しない。
- baselineまたはfinalのporcelain、baseline→final diffに割当外pathがあればscope違反。
  未割当WIPを変更、stage、commit、削除、吸収した結果を成功として扱わない。
- mtime、成果物の実在、完了通知文面、最終porcelainのいずれか1つだけでは完了証拠にしない。

## Test plan

- **RED A**: pre-existing artifact、HEAD不変、porcelain不変、artifact digest不変を
  legacyな「成果物あり」判定が成功にすることをsynthetic temp repositoryで再現する。
- **RED B**: H0からC1へ期待pathだけをcommitし、最終porcelainが空の状態をlegacyな
  「porcelain空=空振り」判定が拒否することを再現する。
- **GREEN**: baseline-aware判定がAをno-op、Bをsuccessとする。
- **dirty resume**: HEADとporcelain path表示が同じでも、割当済みartifactのdigestが
  initial→finalで変わればsuccessとする。
- **scope**: (a) clean baseline→clean finalで未割当pathをcommit、(b) clean baseline→
  assigned commit後にfinal未割当porcelain、(c) initial未割当porcelain→assigned-only
  clean finalを別repositoryで作り、committed diff / final / initialの3 guardを個別に
  success拒否へ固定する。
- **hermetic Git**: hostile `GIT_DIR` / `GIT_WORK_TREE` / `GIT_INDEX_FILE`と、
  global/system configおよび`GIT_CONFIG_COUNT`経由のexternal clean filterを別
  PowerShell childへ注入する。fixed minimal environmentとbyte-bounded process-tree
  runnerを通るfixture Gitが外部index/object sentinelを変更しないことを検査する。
- **host capability**: no-op、acceptance、commit / artifact delta、initial / final /
  committed scope、ancestryのpure decision fixtureは全hostで常時実行する。
  process-backed Git fixtureはWindows job objectまたはproduction sourceが返すfixed
  trusted `setsid`の実在を確認できるhostだけで実行する。trusted `setsid`のない
  macOSではこのfixtureを実行済みとせず、専用CI stepでunsupported fail-closed境界を
  検証する。sourceのexact contractとin-memory mutationでgate消失とalways-skipを拒否する。
- **ancestry**: H0からassigned C1を作った後、同名branchをH0の親へrewindし、
  assigned-only divergent C2をcommitする。branch名同一、final clean、acceptance true、
  diff path assigned-onlyでも`merge-base --is-ancestor H0 C2`がexit 1なら拒否し、
  external sentinelが不変であることを検査する。
- **contract**: exact semantic blockとin-memory mutationを英語正本、日本語版、
  bilingual template、checklist、READMEで検査する。
- **hosts / hygiene**: PowerShell 7、Windows PowerShell 5.1、scanner full gate、
  UTF-8 BOMなし、LF、Gitleaks、`git diff --check`を確認する。

## Handoff

- **状態**: docs-first要件、legacy 2判定のRED、baseline-aware semantic fixtureの
  GREEN、英日契約同期を実装済み。PowerShell 7 / Windows PowerShell 5.1の
  readiness、repository scan、full scanner self-testは通過した。初回PR #12の
  macOS readinessでprocess fixtureが`trusted-setsid-missing`へ到達するhost capability
  不整合を検出し、pure fixtureの全host実行とprocess fixtureだけのcapability gateへ
  分離した。修正版のPowerShell 7 / Windows PowerShell 5.1 readinessとrepository
  scan、Gitleaks、`git diff --check`は通過した。修正版のfull scanner self-test、
  再review、hosted CI、mergeは未実施。
- **実装境界**: synthetic Git fixtureはH0 no-op、clean H0→C1 commit、acceptance failure、
  assigned dirty resume、未割当pathのinitial/final/committed 3経路を独立検査する。
  Git childは既存のbyte-bounded runner、full executable path、fixed minimal environment、
  empty config/hook/attribute inputsで隔離し、別processのhostile環境negativeで確認する。
  bounded ancestry測定とdivergent history negativeも実装する。
  Git repository外のsibling fixtureはnon-Git成果物の実在・size・SHA-256差分を検査する。
  macOSではprocess-backed fixtureを実行せず、pure decision fixtureと既存の
  unsupported fail-closed CI stepを別証拠として扱う。
- **外部境界**: fixtureは合成一時repositoryと公開可能な固定文字列だけを使う。
  実credential、API、OAuth、secret、実データ、外部送信、production、deploy、費用は
  使用しない。
