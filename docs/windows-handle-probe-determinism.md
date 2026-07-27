# Windows handle probe determinism

## 目的と分類

- **分類**：Class M。
- **目的**：Windows PowerShell 5.1 hostの一時的なruntime handle増加と、runner呼出し後も残る持続的なhandle leakを分離する。
- **非目的**：growth limitの単純緩和、probeのskip、GCによる強制回収、native close結果の検査削除は行わない。
- **影響**：専用handle probe、readinessの構造契約とsynthetic判定、self-testの固定evidence、README、CHANGELOGを同期する。

## 実測した非決定性

- PR #9のWindows jobでは、steady-state baseline 592に対してsettled final 597となり、final limit 4を1 handle超過した。
- 同jobのfailed-job rerunでは、同じsourceとhost種別で全stepが成功した。
- merge後の`main` jobでは、startup baseline 581に対してfinal 587、maximum 600となり、startup limit 16をmaximumだけが3 handles超過した。
- `main`のfailed-job rerunも、同じsourceとhost種別で全stepが成功した。
- 実装PRのWindows jobと、ローカルのPowerShell 7 / Windows PowerShell 5.1 full self-testも成功した。

この証拠はrunnerの持続leakを示さない。
一方、現在のprobeはstartup中の一時maximumと、追加初期化が発生し得る最初のsteady windowを持続leakと同じ条件で判定するため、runtime揺らぎを分離できていない。

## 判定契約

1. 同じPowerShell executableのfresh hostで、module-qualified runnerと固定childを実行する。
2. startup 80回の後にbounded quiescenceを取り、最小handle countをwarmup settled値とする。
3. calibration 40回とbounded quiescenceを追加し、遅延した一度限りのruntime初期化をstartup window内へ収束させる。
4. startup baselineからcalibration settled値までの持続増加には、既存のlimit 16を維持する。
5. calibration settled値をsteady baselineとし、次の40回後のsettled final増加には、既存のlimit 4を維持する。
6. 各windowのmaximumはevidenceへ残すが、quiescenceで消えた一時handleをleak判定へ使わない。
7. quiescenceは各windowで固定回数と固定待機時間を使い、GC、内部retry、無期限waitを使わない。
8. runnerのnative close失敗、child失敗、出力逸脱は従来どおり即時失敗させる。

## Test plan

- **RED**：実測した2種類の一時増加をsynthetic seriesへ追加し、現行判定が拒否することを確認する。
- **GREEN**：warmup、calibration、measuredの各windowとsettled値をprobeへ実装し、実測seriesを受理する。
- **negative**：startup settled増加17、measured settled増加5、calibrationまたはmeasuredのzero-run、quiescence無効化、runner置換を拒否する。
- **host**：PowerShell 7とWindows PowerShell 5.1でreadinessとfull scanner self-testを実行する。
- **regression**：repository scan、UTF-8 / LF、`git diff --check`、Gitleaks、Semgrepを実行する。
- **review**：source freeze後の独立reviewでP0 / P1 / P2 / P3を0にする。

## Handoff

- **状態**：GREEN実装、final full regression、security / hygieneを完了し、独立review前のsource freeze段階。
- **RED**：calibration 40回を必須化するvalidatorをproduction変更前に実行し、現行probeの不足だけをexit 1で確認した。
- **実装**：warmup、calibration、measuredの各window後に同じ10回、50 msのbounded quiescenceを追加した。
  startup limit 16とsteady final limit 4は変更していない。
  maximumは固定evidenceへ残し、settled値だけを持続leak判定へ使う。
- **構造契約**：6個のloop、定数、実行順、module-qualified runner、child guard、handle更新をASTで固定した。
  zero-run、limit緩和、runner置換、conditional bodyを各windowのparse-valid mutationで拒否した。
- **host regression**：最終sourceのPowerShell 7 full self-testは202.23秒、Windows PowerShell 5.1 full self-testは195.88秒で、いずれも初回成功した。
  両hostでwarmup、calibration、measuredのsettled値は同値で、持続増加は0だった。
  最終repository scanも26.33秒、exit 0だった。
- **既存fixtureの揺らぎ**：PowerShell 7の初回full self-testはhandle probe到達前のgrandchild pipe起動待ちで1回失敗し、同sourceの再実行で成功した。
  full self-test直後のrepository scanも固定`scanner-runtime-failed`で1回失敗し、同じ公開境界の再実行で22.84秒、exit 0となった。
  どちらも同failure classは1回だけで、変更対象のhandle判定では再現していない。
- **security**：Gitleaksはworking tree 693.67 KBと履歴22 commits、808.22 KBで0 findingsだった。
  local Semgrep 5 rulesはexit 0だったが、変更対象がPowerShellとMarkdownのためscanned target 0であり、security coverageには数えない。
- **hygiene**：変更6 filesはstrict UTF-8、LF、NUL不在だった。
  Windows PowerShell 5.1で実行する3 scriptsは既存どおりUTF-8 BOMを保持した。
  `git diff --check`も成功した。
- **外部境界**：synthetic/local検証と既存GitHub Actionsだけを使う。
  secret、OAuth、credential、実データ、production、deploy、費用操作は対象外とする。
- **残作業**：独立review、PR、3 OS CI、merge、`main`再検証、cleanup。
