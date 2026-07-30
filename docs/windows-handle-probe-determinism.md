# Windows handle probe determinism

## 目的と分類

- **分類**：Class M。
- **目的**：Windows PowerShell 5.1 hostの一時的なruntime handle増加と、runner呼出し後も残る持続的なhandle leakを分離する。
- **非目的**：growth limitの単純緩和、probeのskip、条件付き・無制限retry、GCによる
  強制回収、native close結果の検査削除は行わない。
- **影響**：専用handle probe、readinessの構造契約とsynthetic判定、self-testの固定evidence、README、CHANGELOGを同期する。

## 実測した非決定性

- PR #9のWindows jobでは、steady-state baseline 592に対してsettled final 597となり、final limit 4を1 handle超過した。
- 同jobのfailed-job rerunでは、同じsourceとhost種別で全stepが成功した。
- merge後の`main` jobでは、startup baseline 581に対してfinal 587、maximum 600となり、startup limit 16をmaximumだけが3 handles超過した。
- `main`のfailed-job rerunも、同じsourceとhost種別で全stepが成功した。
- 実装PRのWindows jobと、ローカルのPowerShell 7 / Windows PowerShell 5.1 full self-testも成功した。
- その後のPR #12 run `30344076784`では、80回startup、40回calibration、40回measuredを
  実装済みのsourceでも、Windows PowerShell 5.1だけが再びbaseline 592、
  observed / settled final 597、final limit 4で失敗した。同じcommitのWindows
  PowerShell 7、Ubuntu、macOS dedicated unsupported jobと、ローカル両hostは成功した。

初回の修正はstartup中の一時maximumと最初のsteady windowを分離したが、固定40回の
calibration後にも同じ5-handle plateauが発生し得ることが分かった。1つのwindowだけの
増加はrunner呼出しごとに継続するleakの証拠にならない。一方、同じ上限を超える増加が
連続する2つのsteady windowに残れば、bounded quiescence後も増え続ける証拠になる。

## 判定契約

1. 同じPowerShell executableのfresh hostで、module-qualified runnerと固定childを実行する。
2. startup 80回の後にbounded quiescenceを取り、最小handle countをwarmup settled値とする。
3. calibration 40回とbounded quiescenceを追加し、遅延した一度限りのruntime初期化をstartup window内へ収束させる。
4. startup baselineからcalibration settled値までの持続増加には、既存のlimit 16を維持する。
5. calibration settled値をsteady baselineとし、40回のmeasured windowとbounded
   quiescenceを実行する。window差分には既存のlimit 4を維持する。
6. measured結果にかかわらず、条件分岐やretryではなく常時40回のconfirmation windowと
   bounded quiescenceを1回だけ実行する。confirmationのbaselineはmeasured settled値とする。
7. measuredまたはconfirmationの単独増加がstartupと同じabsolute limit 16を
   超えた場合は、1 windowだけでもbounded plateauではないため拒否する。
8. absolute limit内でも、measuredとconfirmationの両方がそれぞれpersistent
   limit 4を超えた場合は、継続するsteady-state leakとして拒否する。どちらか
   一方だけが4を超え16以下ならbounded plateauとしてevidenceへ残す。
9. 各windowのobserved final、settled値、maximum、persistent limit 4、
   single-window plateau limit 16はevidenceへ残す。
   quiescenceで消えた一時handleをleak判定へ使わない。
10. quiescenceは各windowで固定回数と固定待機時間を使い、GC、条件付きretry、
   無期限waitを使わない。
11. runnerのnative close失敗、child失敗、出力逸脱は全windowで従来どおり即時失敗させる。

## Test plan

- **RED**：PR #9 / #12で再現したmeasured +5、次window +0のseriesと、常時
  confirmation windowのsource contractを追加し、現行3-window probeだけを拒否する。
- **GREEN**：warmup、calibration、measured、confirmationの各windowとsettled値を
  probeへ実装し、measured +5 / confirmation +0とmeasured +0 / confirmation +5を
  bounded plateauとして受理する。
- **negative**：startup settled増加17、measured +5 / confirmation +5、
  measured +17 / confirmation +0、measured +0 / confirmation +17、
  各execution / quiescence windowのzero-run、confirmationの条件付き化、
  limit緩和、runner置換を拒否する。
- **host**：PowerShell 7とWindows PowerShell 5.1でreadinessとfull scanner self-testを実行する。
- **regression**：repository scan、UTF-8 / LF、`git diff --check`、Gitleaks、Semgrepを実行する。
- **review**：source freeze後の独立reviewでP0 / P1 / P2 / P3を0にする。

## Handoff

- **2026-07-28再発対応**：PR #12 run `30344076784`のWindows PowerShell 5.1で、
  過去のPR #9と同じbaseline 592→settled 597を再検出した。failed jobのblind rerunは
  行わず、confirmation source contractのREDを両PowerShell hostで実測後、production
  probe、validator、self-test evidence、公開文書へ4-window契約を実装した。
  PowerShell 7とWindows PowerShell 5.1のreadiness、専用handle probe、full
  self-testはすべてexit 0。再reviewはP0 / P1 / P2 / P3各0、clearance YES。
  PR head run `30349730514`はWindows、Ubuntu、macOSの3 jobsが成功し、PR #12を
  merge commit `93c38924a676ef648ae373964df781033d93d4c7`で`main`へ統合した。
- **独立review P1**：最初の4-window実装は`+5 / +0`だけでなく`+100 / +0`も
  通すため、single-window plateauが無制限だった。persistent limit 4に加え、
  startupと同じabsolute limit 16を各steady windowへ適用した。修正前に
  `+17 / +0`と`+0 / +17`が通るREDを両PowerShell hostで確認し、修正後は
  両hostのreadinessがexit 0になった。
- **最終local regression**：machine-wide scanner slotを直列化し、専用probeは
  PowerShell 7が14.374秒、Windows PowerShell 5.1が13.056秒、full self-testは
  PowerShell 7が231.581秒、Windows PowerShell 5.1が197.387秒で、4本とも
  初回実行、exit 0、stderrなしだった。各full markerはhost名を含めてexact一致し、
  各終了後のscanner / handle-probe PIDは0、reviewed source freezeは不変だった。
- **post-main**：merge SHAを対象にしたrun `30350234181`はWindows、Ubuntu、macOSの
  3 jobsが成功した。local `main`でもPowerShell 7 / Windows PowerShell 5.1の
  readinessがexit 0で、`HEAD == main == origin/main`、tracked tree clean、
  task branchのlocal / remote削除を確認した。
- **前回PR #10状態**：GREEN実装、final full regression、security / hygiene、独立review、PR CI、mergeを完了した。
  PR #10をmerge commit `7791a20`で`main`へ統合済み。
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
- **review**：最終freezeの独立reviewでP0 / P1 / P2 / P3はいずれも0、clearance YESを確認した。
  reviewerはfreeze一致、80 / 40 / 40の契約、settle順序、limit 16 / 4、no GC / retry / skip、native runner不変を確認し、変更を加えていない。
- **CI**：PR #10のGitHub Actions run `30240567525`はWindows、Ubuntu、macOSの3 jobsが初回ですべて成功した。
  Windows jobでは両PowerShellのreadinessとfull self-test、repository scan、whitespaceが成功した。
- **外部境界**：公開GitHub repositoryのPR #10作成とmerge以外に、外部 agent送信、secret、OAuth、credential、実データ、production、deploy、費用操作は使用していない。
- **残作業**：なし。
  post-main CI、一致、clean tree、readiness、branch cleanupは上記の`post-main`で確認済み。
