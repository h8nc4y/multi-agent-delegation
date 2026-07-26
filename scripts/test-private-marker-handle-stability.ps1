[CmdletBinding()]
param(
    [string]$Path = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# full scanner self-test hostの遅延TaskやPowerShell内部handleを測定へ混在させない。
# 同じPowerShell executableのfresh processでrunnerだけを80回動かす専用probe。
$scriptRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($scriptRoot)) {
    $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}
if ([string]::IsNullOrWhiteSpace($Path)) {
    $Path = Split-Path -Parent $scriptRoot
}

$handleProbeProcess = $null
try {
    if (
        [Environment]::OSVersion.Platform -ne
            [System.PlatformID]::Win32NT
    ) {
        throw 'windows-handle-probe-platform-invalid'
    }

    $root = (Resolve-Path -LiteralPath $Path).Path
    $processRunnerModule = Join-Path `
        $scriptRoot `
        'private-marker-process-runner.psm1'
    if (-not (Test-Path -LiteralPath $processRunnerModule -PathType Leaf)) {
        throw 'windows-handle-probe-runner-missing'
    }
    Microsoft.PowerShell.Core\Import-Module $processRunnerModule -Force

    # absolute SystemDirectory配下のcmd.exeだけを対象にし、PATHやComSpecを参照しない。
    $handleProbeTarget = Join-Path (
        [Environment]::SystemDirectory
    ) 'cmd.exe'
    if (
        -not [System.IO.Path]::IsPathRooted($handleProbeTarget) -or
        -not (Test-Path -LiteralPath $handleProbeTarget -PathType Leaf)
    ) {
        throw 'windows-handle-probe-target-invalid'
    }
    $handleProbeArguments = @('/d', '/c', 'exit', '0')
    $handleProbeEnvironment = New-PrivateMarkerChildEnvironment

    # 最初の40回はruntimeの一度限りの初期化を含むstartup window。ここにも上限を
    # 設け、初期化という名目で継続的なrunner所有handle漏れを隠さない。
    $handleWarmupRuns = 40
    $handleMeasuredRuns = 40
    $handleStartupGrowthLimit = 16
    # HandleCountはrunner所有handleだけでなく、Windows PowerShell runtimeの
    # 一時handleも同じaggregateへ含む。native close resultはrunner側で別途
    # 全件検査し、ここでは40回後も残る増加を従来どおり4で検出する。終了後の
    # bounded sampleで解消するruntime揺らぎだけをsettled finalから除外する。
    $handleMeasuredFinalGrowthLimit = 4
    $handleMeasuredPeakGrowthLimit = 12
    $handleQuiescenceSamples = 10
    $handleQuiescenceWaitMilliseconds = 50
    $handleProbeProcess = [System.Diagnostics.Process]::GetCurrentProcess()
    $handleProbeProcess.Refresh()
    $handleStartupBaseline = $handleProbeProcess.HandleCount
    $handleWarmupFinal = $handleStartupBaseline
    $handleWarmupMaximum = $handleStartupBaseline

    for (
        $handleWarmupAttempt = 0;
        $handleWarmupAttempt -lt $handleWarmupRuns;
        $handleWarmupAttempt++
    ) {
        $handleWarmupResult = private-marker-process-runner\Invoke-PrivateMarkerBoundedProcess `
            -FilePath $handleProbeTarget `
            -Arguments $handleProbeArguments `
            -WorkingDirectory $root `
            -EnvironmentVariables $handleProbeEnvironment `
            -TimeoutMilliseconds 10000
        if (
            $handleWarmupResult.ExitCode -ne 0 -or
            $handleWarmupResult.StandardOutputBytes.Length -ne 0 -or
            $handleWarmupResult.StandardErrorBytes.Length -ne 0
        ) {
            throw 'windows-handle-probe-startup-child-failed'
        }
        $handleProbeProcess.Refresh()
        $handleWarmupFinal = $handleProbeProcess.HandleCount
        $handleWarmupMaximum = [Math]::Max(
            $handleWarmupMaximum,
            $handleWarmupFinal
        )
    }
    if (
        ($handleWarmupFinal - $handleStartupBaseline) -gt
            $handleStartupGrowthLimit -or
        ($handleWarmupMaximum - $handleStartupBaseline) -gt
            $handleStartupGrowthLimit
    ) {
        throw (
            'windows-handle-probe-startup-unbounded ' +
            "baseline=$handleStartupBaseline final=$handleWarmupFinal " +
            "max=$handleWarmupMaximum limit=$handleStartupGrowthLimit"
        )
    }

    # 後半40回はsteady-state。最終値とpeakを別々に固定し、一時的な増加と
    # 単調リークの両方をGCなしで検出する。
    $handleBaseline = $handleWarmupFinal
    $handleMaximum = $handleBaseline
    $handleFinal = $handleBaseline
    for (
        $handleAttempt = 0;
        $handleAttempt -lt $handleMeasuredRuns;
        $handleAttempt++
    ) {
        $handleProbeResult = private-marker-process-runner\Invoke-PrivateMarkerBoundedProcess `
            -FilePath $handleProbeTarget `
            -Arguments $handleProbeArguments `
            -WorkingDirectory $root `
            -EnvironmentVariables $handleProbeEnvironment `
            -TimeoutMilliseconds 10000
        if (
            $handleProbeResult.ExitCode -ne 0 -or
            $handleProbeResult.StandardOutputBytes.Length -ne 0 -or
            $handleProbeResult.StandardErrorBytes.Length -ne 0
        ) {
            throw 'windows-handle-probe-steady-child-failed'
        }
        $handleProbeProcess.Refresh()
        $handleFinal = $handleProbeProcess.HandleCount
        $handleMaximum = [Math]::Max(
            $handleMaximum,
            $handleFinal
        )
    }

    # childを追加実行せず、GCも呼ばないbounded quiescenceでruntime由来の
    # 遅延closeだけを観測する。runner所有native handleが持続して残る場合は
    # 全sampleで減らないため、従来のfinal上限4を超えてfailする。
    $handleObservedFinal = $handleFinal
    $handleSettledFinal = $handleFinal
    for (
        $handleQuiescenceAttempt = 0;
        $handleQuiescenceAttempt -lt $handleQuiescenceSamples;
        $handleQuiescenceAttempt++
    ) {
        [System.Threading.Thread]::Sleep(
            $handleQuiescenceWaitMilliseconds
        )
        $handleProbeProcess.Refresh()
        $handleQuiescenceSample = $handleProbeProcess.HandleCount
        $handleSettledFinal = [Math]::Min(
            $handleSettledFinal,
            $handleQuiescenceSample
        )
    }
    if (
        ($handleSettledFinal - $handleBaseline) -gt
            $handleMeasuredFinalGrowthLimit -or
        ($handleMaximum - $handleBaseline) -gt
            $handleMeasuredPeakGrowthLimit
    ) {
        throw (
            'windows-handle-probe-steady-unbounded ' +
            "baseline=$handleBaseline observed-final=$handleObservedFinal " +
            "settled-final=$handleSettledFinal " +
            "max=$handleMaximum " +
            "final-limit=$handleMeasuredFinalGrowthLimit " +
            "peak-limit=$handleMeasuredPeakGrowthLimit"
        )
    }

    # 親self-testが厳密なregexで読む固定ASCII evidenceだけをstdoutへ出す。
    Write-Host (
        'Windows handle stability: ' +
        "startup-baseline=$handleStartupBaseline, " +
        "startup-final=$handleWarmupFinal, " +
        "startup-max=$handleWarmupMaximum, " +
        "startup-limit=$handleStartupGrowthLimit, " +
        "warmup=$handleWarmupRuns, baseline=$handleBaseline, " +
        "observed-final=$handleObservedFinal, " +
        "settled-final=$handleSettledFinal, max=$handleMaximum, " +
        "runs=$handleMeasuredRuns, " +
        "quiescence=$($handleQuiescenceSamples)x" +
        "$($handleQuiescenceWaitMilliseconds)ms, gc=not-invoked"
    )
    exit 0
}
catch {
    # PowerShell/module例外のmessageへpath等が含まれても外へ再送しない。probeが
    # 自分で生成した固定codeと数値だけを診断として許可する。
    $diagnostic = [string]$_.Exception.Message
    if (
        $diagnostic -notmatch
            '^windows-handle-probe-[a-z-]+(?: [a-z-]+=[0-9]+)*$'
    ) {
        $diagnostic = 'windows-handle-probe-unexpected-error'
    }
    Write-Host "Windows handle stability probe failed: $diagnostic"
    exit 1
}
finally {
    if ($null -ne $handleProbeProcess) {
        $handleProbeProcess.Dispose()
    }
}
