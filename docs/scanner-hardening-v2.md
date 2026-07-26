# Private-marker scanner hardening v2

## 目的と分類

- 分類: Class L（公開用 security scanner、複数 OS の process 境界、Git index/worktree 契約を変更）
- 目的: scan 対象・実行中 snapshot・child process・診断出力の各境界を fail closed にし、Windows と Ubuntu の実測可能な同一契約へ揃える。
- 非目的: あらゆる secret 形式を検出すること、real credential を fixture に使うこと、外部サービスへデータを送ること。

## Source of truth

- public scanner entrypoint: `scripts/scan-private-markers.ps1`
- scanner implementation: `scripts/scan-private-markers-v2.ps1`
- byte-exact process 境界: `scripts/private-marker-process-runner.psm1`
- adversarial test: `scripts/test-scan-private-markers.ps1`
- repository gate: `scripts/validate-oss-readiness.ps1`
- CI: `.github/workflows/validate.yml`
- 利用者向け契約: `README.md`、`SECURITY.md`、`CONTRIBUTING.md`

## 必須不変条件

### Path と診断

1. 存在しない・不正な `-Path` は raw path や PowerShell error framing を表示せず、固定 code `scan-root-invalid` で終了する。
2. 表示可能 path は C0/C1、bidi、format、line/paragraph separator を除去し、長さと UTF-8 byte 数を制限する。
3. 最終出力は prefix、列、実 OS newline を含む UTF-8 byte budget 内で明示的に serialize する。

### Git snapshot と scan 対象

1. child environment は親から複製せず、Windows の OS API 由来 `SystemRoot` だけを共通基底、POSIX は空を基底にする。Git は固定 `GIT_*`、`GCM_INTERACTIVE=Never`、`LC_ALL/LANG=C`、file-reader は固定 PowerShell module-search/cache null-device、telemetry/update opt-out、入力 path だけを追加し、`PATH`、temp、home/profile、loader/profiler、credential/token、SSH-agent を継承しない。PowerShell 7 が起動時に既定module pathを前置するため、reader bodyの最初に未修飾commandを使わず実効`PSModulePath`をnull deviceへ固定し直す。Git executableは `Get-Command git -CommandType Application` のPATH先頭candidateだけを固定し、rooted regular non-reparse fileを要求する。Windowsの通常hard linkはregular fileとして許可するが、alias/function/script/symbolic link/reparse targetや不適格な先頭candidateから後順位へのfallbackは許可しない。
2. regular stage-0 blob と安全な current worktree file の union を scan する。
3. regular non-reparse `.git` gitfileを持つlinked worktree/submoduleは、bounded Git probeでrequested rootとexact一致した場合だけrepository modeとして許可する。broken/dangling/reparse/mismatchを含め、scan rootまたはancestorの`.git` entryからexact rootを確立できない場合はexit 2と固定診断 `Private marker scan failed closed (integrity: git-probe).` でfail closedにする。
4. 真の non-Git fallback では scan root より下のexact-case `.git` directory/leafだけをcontrol metadataとして除外し、内容を開かない。case-sensitive POSIXの`.GIT`はordinary contentとしてscanする。
5. conflict、symlink、gitlink、reparse、malformed record、missing object を fail closed にする。
6. intent-to-add と worktree-only state を見落とさない。
7. scan 前後で raw `ls-files --stage -z` と raw `ls-files --debug -z` が byte-exact に一致しなければ失敗する。
8. blob は単一 `git cat-file --batch` process で取得し、request/response 件数・長さ・OID・size を厳密に照合する。
9. Git 2.43 が `GIT_NO_LAZY_FETCH=1` で missing object を返す際の固定 warning は、`LC_ALL=C` で完全一致する LF/CRLF byte 列だけを許可し、追加 stderr は拒否する。

### Child process

1. stdin/stdout/stderr は byte stream のまま扱い、`0x00`、`0x80`、`0xFF`、partial read/write、EOF、nonzero exit を保持する。
2. Windows は suspended `CreateProcessW` で起動し、限定 handle list と kill-on-close Job Object へ割り当ててから resume する。
3. Windows は C# の raw pipe handle を直接読み書きし、PowerShell text `StandardInput` や PowerShell proxy を境界に挟まない。最初の eager production-runner call を AST で固定し、direct/transitive/scope-qualified function call、source内alias、staticなfunction provider / `Get-Command` 参照、直接またはfunction経由の保存scriptblockとその `Get-Variable`/`gv` 再取得（source内literal alias、early direct/transitive wrapper、lookup-risky wrapperを指すaliasを含む）、risky class constructor/method/cast/static initialization、derived classのdirect/transitive base constructorを追跡する。`Get-Variable`/`gv` はraw fixtureより前にtop-levelのunqualifiedまたは`script:`変数へ一度だけ直接代入され、lookup実行前に代入が完了した、unqualified current-item変数だけのliteral `{ $_ }` / `{ $PSItem }` だけをpositive safe setとして許可する。target function/alias shadow、lookup-name shadow、scope不一致代入、qualified current-item変数、alias import/remove、exactなmodule-qualified bootstrap以外のmodule import/new/`using module`、safe filesystem helperを装うmodule-qualified command、`Set-Item`/`Set-Content`/`New-Item`と`Copy-Item`/`Move-Item`/`Rename-Item`/`Remove-Item`/`Clear-Item`のAlias:/Function: provider mutation、外部PowerShell scriptのdirect/call-operator/dot-source実行、bootstrap変数上書き後のdynamic dot-source、`ForEach-Object`/`Where-Object`への保存scriptblock渡し、複合receiverのunknown `.Invoke()`、`Invoke-Expression`とそのalias、unknown/unbound変数、runtime生成・再代入・variable mutation、deferred IEX/unknown/dynamic call、wildcard/name省略の保存変数lookup、解決不能なdynamic call/lookupは保守的に拒否する。function-local call operatorは一意なliteral scriptblock束縛とbodyのidentity検査を満たす場合だけ許可する。early `Remove-Item` wrapperは固定`Env:` pathまたはSHA-256で固定したbounded fixture cleanup関数だけを例外とし、runner module bootstrapもSHA-256固定source prefixとsibling moduleへの`Microsoft.PowerShell.Core\Import-Module`だけを許可する。lookup以外を指すsafe alias、`Get-Command git -CommandType Application` のようなliteral application lookupは許可する。native Git batch response と caller input encoding の不変性で BOM-less transport を実測する。
4. Windows の assign/resume/Job cleanup failure は target を実行せず、terminate、wait、pipe/thread/process/Job handle close の全 native result を検査する。Job handleはclose成功前に0化せず1回だけ再試行し、launch cleanupのJob termination失敗時もdirect `TerminateProcess` fallbackを維持する。success pathもpump Task、pipe FileStream、bufferを明示Disposeする。main self-testでraw transport契約を確認した後、handle回帰は同じPowerShell executableのfresh専用hostと専用scriptで実行する。専用scriptはcanonical UTF-8 sourceのSHA-256封印と別系統のAST契約を併用し、run数の再代入、引数内control flow、provider command shadow、到達不能bodyを拒否する。aggregate `HandleCount`だけでruntime threadとrunner漏れを断定せず、GCなし40回のstartup window自体に増加上限を設けた後、別の40回へより厳しいfinal／peak上限を適用する。これにより先行self-testの遅延cleanupを混在させず、startup-only growthを無制限にbaselineへ吸収せず、steady-stateの反復漏れも検出する。
5. POSIX は trusted `setsid` で新規 process group/session を作る。固定 `/tmp` 配下へ `mkdir(0700)` した private release gate で shell の ready PID を受け、`getpgid(pid) == pid` を確認した後にだけ one-shot release fileを作ってtargetを`exec`する。release前timeoutではdirect launcherを止め、独立kill-wait内のlate-readyも検証してgroupを終了する。`finally` はlauncher exit後もverified groupをprobeし、既知のready/releaseとnon-recursive gate directoryだけを削除する。libc `kill(2)` と direct `WaitForExit` の return、termination failureを握り潰さず、pump Task、stream、bufferを明示Disposeする。GCを呼ばない40回実行のfile descriptor countをboundedに保つ。
6. process 単位 timeout に加え、lower-only `1..120000` ms の scan-wide monotonic deadline を全 child/read/parse/serialize と実出力直前へ伝播する。process operationのmonotonic budgetはenvironment準備とprocess launchより前に開始し、termination/cleanupには独立したbounded kill-wait allowanceを使う。exported runnerのpublic numeric parameterはcanonical integerだけを受理し、fractional、exponential、aggregate、overflow、範囲違反を`process-limit-invalid`へ畳む。public scanner deadlineはbinding attributeでなくentrypoint body内で検査し、scannerの固定stdout・空stderr・exit 2境界を維持する。

### CI workflow

1. top-level key は `name`、`on`、`permissions`、`jobs` の exact sequence とする。
2. trigger は `pull_request` と `main` への `push`、permission は top-level `contents: read` だけとし、job-local override を許可しない。
3. job ID、各 job の direct key、全 step property を exact に検査し、third-party action は full commit SHA pin だけを許可する。
4. `pull_request_target`、extra trigger、duplicate job、job permission override、mutable action ref の synthetic mutation が validator を通らないことを self-check する。

### Resource caps

- file/aggregate bytes
- tracked/worktree entries
- per-file/aggregate lines
- regex matches
- detailed findings
- local marker count/source lines/characters
- child stdout/stderr
- final serialized output
- scan-wide deadline

すべてを有限値にし、超過値や一致内容を表示せず固定 rule へ畳み込む。

## Test plan

### 共通 adversarial fixtures

- index/worktree divergence、intent-to-add、missing worktree
- `.env`、`.env.*`、`.npmrc`、`.pem`、`.key`、extensionless file
- conflict stage、symlink、gitlink、junction/reparse
- valid linked-worktree gitfileのexact root許可、broken root/ancestor `.git` file/directoryとdangling/reparse `.git`の固定exit 2、nested exact-case `.git`のfallback除外、POSIX `.GIT`のscan
- ambient/unknown/present-empty `GIT_*` と、unknown non-Git、loader/profiler、credential/token、SSH-agent environment の非継承
- scan 中の stage/debug mutation
- `cat-file --batch` の malformed、short、oversized、missing response
- hostile/nonexistent path の Unicode/control
- byte-exact stdin/stdout/stderr、EOF、nonzero exit、partial writes
- first eager call の AST ownership（target function/alias/Set-Item・Set-Content・New-Item provider shadow、alias import/remove、module import/new/usingとexact bootstrap proof、Copy/Move/Rename/Remove/Clear provider identity、外部PowerShell scriptのdirect/call/dot-source実行、function-local literal scriptblock call proof、bootstrap path overwrite、未実行／実行済み／scope-qualified／alias経由／static参照／transitive function、未使用／変数保存／function間接保存／`Get-Variable`/`gv` のpositive safe assignmentとassignment/current-item scope、unknown/unbound/runtime生成/再代入/IEX/unresolved/wildcard/name省略、source内alias・wrapper・wrapper alias・代入順序伝播／ForEach/Where引数 scriptblock、risky class constructor/method/cast/static initializer、derived classのdirect/transitive base constructor、`.Invoke()` / `.InvokeReturnAsIs()` / composite receiver / call operator / `Invoke-Expression`とalias、dynamic lookupのfail closed、literal application lookupの許可）
- native Git batch の binary blob、BOM-less stdin、caller `Console.InputEncoding` 復元
- descendant escape、pre-launchを含むoperation timeout、独立したcleanup allowance、stdout/stderr cap
- Windows assign/resume failure の PID 消失と未実行 sentinel
- Windows Job termination/close failure のdirect process fallback、handle保持、bounded close retry
- fresh同一PowerShell hostでWindows successをstartup 40回の増加上限＋steady-state 40回の厳格なfinal／peak上限・GC未実行で確認するpump/pipe/thread handle安定性、POSIX file descriptor安定性、direct-delay/fork-delay fake `setsid` がrelease前にtargetを実行せずlate groupとprivate gateを残さないこと
- helper欠落／helper例外／Git isolation create/remove失敗の固定redacted stdout、空stderr、exit 2
- lower-only scan-wide deadline の bounded runtimeとpublic numeric parameter（fractional/exponential/aggregate/overflow/範囲違反）の固定diagnostic
- final output byte boundary（実 OS newline 込み）
- workflow trigger/permission/job/action-pin の exact validation と mutation rejection

### 実行環境

- Windows PowerShell 7
- Windows PowerShell 5.1
- official PowerShell Ubuntu container + Ubuntu Git 2.43

### 最終 gate

- readiness
- self-test
- repository scan
- workflow YAML parse
- PowerShell AST parse
- `git diff --check`
- Gitleaks
- Semgrep
- source freeze 後の独立 review（P1/P2/P3 = 0）

## Handoff

- 統合状況（2026-07-26確認）: scanner境界強化はPR #3（merge commit `36e4d08`）、Windows PowerShell 5.1のhandle probe安定化はPR #4（merge commit `07d593a`）として`main`へ統合済み。state sync着手前にlocal `main` = `origin/main` = `07d593a`、tracked tree cleanを確認した。
- 検証証拠: GitHub Actions `Validate` run `30160602927` はcommit `07d593a` に対するWindows / Ubuntu jobが成功した。localではreadinessをPowerShell 7 / Windows PowerShell 5.1で、repository scanをPowerShell 7で実行して成功した。以後の統合状態は最新のdefault branchとGitHub Actionsを正本とし、この項目のcommit / runは2026-07-26時点の証拠baselineとして扱う。
- 残る未確認事項: PSScriptAnalyzerは未導入。PATH先頭native Git candidateの署名・配布元identity、PID / PGIDが意図したprocessであることのkernel-level identity、aggregate handle増加のhandle type別内訳は未確認。
- commit / push / PR: 未統合の実装WIPや旧追補treeはない。
- external cost / OAuth / secret / real data: 使用しない
