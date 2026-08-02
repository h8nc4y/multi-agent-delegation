# Checkout v7 upgrade

## 目的と分類

- **分類**：Class M。
- **目的**：Windows、Ubuntu、macOSの3 CI jobで使う`actions/checkout`を、
  公式v7.0.1 tagのimmutable full SHAへ更新する。
- **影響**：`.github/workflows/validate.yml`、workflow boundary validator、
  validator自身のnegative mutation、CHANGELOG、本handoff。
- **非影響**：trigger、top-level `contents: read`、job / step集合、runner、
  25分timeout、`persist-credentials: false`、scanner、README、SECURITY、過去の
  credential hardening記録、tag、GitHub Releaseは変更しない。

## 公式根拠

- GitHub公式 `actions/checkout` のtag `v7.0.1`は
  commit `3d3c42e5aac5ba805825da76410c181273ba90b1`を指し、GitHubのcommit
  verificationはvalidだった。
- v7はunsafeなfork PR checkoutを既定拒否し、ESM移行と依存security fixを含む。
  v7.0.1は既定入力時のunsafe PR check、branch whitespace、`--unset`値escapeを修正する。
- action runtimeはNode 24。公式READMEが示す最低runnerはv2.327.1で、現行v5と同じ
  runtime境界である。認証付きGitをcontainer actionから使うstepは本workflowにない。

## 要件

1. 3 checkout stepを同じv7.0.1 full SHAへ固定する。
2. 各stepの`with.persist-credentials: false` ownershipを維持する。
3. validatorはv7.0.1以外のpin、mutable `@v7`、旧v5.0.1 full SHAをfail closedにする。
4. trigger、permission、job / step、runner、timeoutの既存exact contractを維持する。
5. CHANGELOGへ現在の更新を追記し、v5.0.1を記録した過去handoffは履歴として維持する。

## Test plan

- **baseline**：PowerShell 7 / Windows PowerShell 5.1のreadinessと、現行mainの
  Windows / Ubuntu / macOS CI成功を確認する。
- **TDD RED**：validatorをv7.0.1 exact SHAへ先に更新し、旧v5.0.1 workflowを拒否する。
- **GREEN**：workflow 3 stepを更新後、両PowerShell hostのreadinessを通す。
- **scanner**：両PowerShell hostのscanner self-testとrepository scanを直列実行する。
- **security / hygiene**：private-marker baseline差分、Gitleaks、Semgrep、UTF-8 / LF / NUL、
  `git diff --check`を確認する。
- **review / integration**：source freeze後に独立reviewし、PR exact headとpost-mainで
  Windows / Ubuntu / macOSの3 jobを確認する。

## Handoff

- **状態**：doing。公式tag / release / action runtime、baseline main / origin、
  open PR / issue 0、現行mainの3 job成功をread-onlyで確認した。validator先行更新では
  旧v5.0.1 workflowを拒否し、実装後はstale version commentも拒否するTDD REDを確認した。
- **local evidence**：最終候補のreadinessはPowerShell 7 / 5.1で成功した。
  scanner self-testは両hostで成功し、handle growthはともに0。baseline / 候補のrepository
  scan、Gitleaks staged、Semgrep 82 rules / 4 files、`git diff --check`、UTF-8 / LF / NUL
  検査も成功した。validatorの既存UTF-8 BOMはbaselineと同じprofileを維持した。
- **review**：独立した2 reviewはいずれもP0-P3 finding 0だった。
- **外部境界**：public repositoryの通常CI以外に、secret、OAuth、実データ、
  production、deploy、tag / Release、paid operationを使用しない。
- **未確認**：v7.0.1を使うPR / main CIはpush前のため未確認。
