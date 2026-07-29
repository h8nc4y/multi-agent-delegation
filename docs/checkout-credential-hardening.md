# Checkout credential hardening

## 目的と分類

- **分類**：Class M。
- **目的**：GitHub Actions の checkout 後に action の認証tokenをlocal Git configへ
  永続化せず、後続の検証scriptから再利用できない境界を固定する。
- **影響**：Windows、Ubuntu、macOS の既存 checkout step、readiness validator、
  公開 security contract、利用者向け説明、CHANGELOG。
- **非影響**：action の immutable SHA、trigger、permission、job、step、runner、
  tag、Release は変更しない。

## 要件

1. 既存3件の `actions/checkout` stepは同じimmutable v5.0.1 SHAを維持する。
2. 各 checkout step の `with` 直下に `persist-credentials: false` を1件だけ置く。
3. 同名scalarが欠落、`true`、または別階層にある場合、readinessはfail closedにする。
4. validator自身が上記3 mutationをin-memoryで作り、受理しないことを固定する。
5. trigger、permission、job/step集合、runner、timeoutの既存contractを維持する。

## Test plan

- **focused readiness**：PowerShell 7とWindows PowerShell 5.1で
  `scripts/validate-oss-readiness.ps1` を実行する。
- **negative mutations**：欠落、`true`、誤ネストをpure in-memory fixtureで拒否する。
- **scanner regression**：PowerShell 7とWindows PowerShell 5.1のscanner
  self-test、およびrepository scanを実行する。
- **hygiene/security**：`git diff --check`、UTF-8/LF/NUL、Gitleaks、Semgrepを確認する。
- **review**：source freeze後に独立reviewを行い、P1/P2/P3 findingを解消する。

## Handoff

- **状態**：実装、local検証、独立review、commit、push、PR CI、mergeを完了。
  PR #15はmerge commit `4b44b538a335de629a4282f12dbfc48f7a2ffe30`で
  `main`へ統合済み。
- **実装**：branch `fix/checkout-persist-credentials`、commit
  `476644ad8a25aa2915cdf69068912b069189382e`。
- **readiness**：PowerShell 7は16.8秒、Windows PowerShell 5.1は14.0秒で
  exit 0。両hostで欠落、`true`、誤ネストを含むin-memory mutationを拒否した。
  handoff同期後の再実行も両hostでexit 0だった。
- **scanner regression**：PowerShell 7 self-testは217.1秒、Windows
  PowerShell 5.1 self-testは194.1秒、repository scanは27.4秒でexit 0。
  最終scanner/readiness関連processは0件だった。
- **security/hygiene**：`git diff --check`、変更7 fileのUTF-8/LF/NUL検査は
  成功。Gitleaksはworking treeで0 findings。Semgrep local 5 rulesは
  exit 0、results 0、errors 0だったが、対応言語fileがないためscanned targetsは0。
- **workflow shape**：immutable checkout SHAは3件、mutable checkoutは0件、
  `persist-credentials: false`は3件、workflow fileは1件を確認した。
- **独立review**：freezeしたstaged diffを別agentが確認し、P1 / P2 / P3は
  すべて0、clearance YES。review前後でstaged patch hash一致、unstaged 0を確認した。
- **commit security**：staged Gitleaksは9.38 KBで0 findings。global
  pre-commit Gitleaksもpassし、Semgrepは対応fileなしでskipした。
- **CI**：GitHub Actions run `30428038383`のWindows、Ubuntu、macOS
  3 jobはすべてsuccess。
- **外部境界**：secret、OAuth、実データ、production、deploy、費用は使用しない。
- **残作業**：本handoff同期を`main`へ統合後、local/remote branch cleanupと
  `main == origin/main`、clean treeを確認する。
