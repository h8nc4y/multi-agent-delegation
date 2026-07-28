[CmdletBinding()]
param(
    [string]$Path = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# full scanner self-test hostの遅延TaskやPowerShell内部handleを測定へ混在させない。
# 同じPowerShell executableのfresh processでrunnerだけを固定windowごとに動かす。
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

    # startup 80回とcalibration 40回でruntimeの初期化を収束させ、続く2つの
    # 40回windowで単発plateauとrunner呼出しごとの継続増加を分離する。
    $handleWarmupRuns = 80
    $handleCalibrationRuns = 40
    $handleMeasuredRuns = 40
    $handleConfirmationRuns = 40
    $handleStartupGrowthLimit = 16
    # HandleCountはrunner所有handleだけでなく、Windows PowerShell runtimeの
    # 一時handleも同じaggregateへ含む。native close resultはrunner側で全件
    # 検査し、ここではbounded quiescence後も残る持続増加だけをlimit 4で検出する。
    $handleMeasuredFinalGrowthLimit = 4
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

    # startup中のmaximumはevidenceへ残す。一時peakはleakではないため、同じ
    # bounded quiescenceを通過したsettled値だけを既存limit 16と比較する。
    $handleWarmupObservedFinal = $handleWarmupFinal
    $handleWarmupSettled = $handleWarmupFinal
    for (
        $handleWarmupQuiescenceAttempt = 0;
        $handleWarmupQuiescenceAttempt -lt $handleQuiescenceSamples;
        $handleWarmupQuiescenceAttempt++
    ) {
        [System.Threading.Thread]::Sleep(
            $handleQuiescenceWaitMilliseconds
        )
        $handleProbeProcess.Refresh()
        $handleWarmupQuiescenceSample = $handleProbeProcess.HandleCount
        $handleWarmupSettled = [Math]::Min(
            $handleWarmupSettled,
            $handleWarmupQuiescenceSample
        )
    }
    if (
        ($handleWarmupSettled - $handleStartupBaseline) -gt
            $handleStartupGrowthLimit
    ) {
        throw (
            'windows-handle-probe-startup-persistent ' +
            "baseline=$handleStartupBaseline " +
            "observed-final=$handleWarmupObservedFinal " +
            "settled-final=$handleWarmupSettled " +
            "max=$handleWarmupMaximum limit=$handleStartupGrowthLimit"
        )
    }

    # calibration 40回はstartup limit 16の内側で評価する。最初のsteady
    # windowだけに現れるruntime初期化を、leak判定のbaselineへ混入させない。
    $handleCalibrationFinal = $handleWarmupSettled
    $handleCalibrationMaximum = $handleWarmupSettled
    for (
        $handleCalibrationAttempt = 0;
        $handleCalibrationAttempt -lt $handleCalibrationRuns;
        $handleCalibrationAttempt++
    ) {
        $handleCalibrationResult = private-marker-process-runner\Invoke-PrivateMarkerBoundedProcess `
            -FilePath $handleProbeTarget `
            -Arguments $handleProbeArguments `
            -WorkingDirectory $root `
            -EnvironmentVariables $handleProbeEnvironment `
            -TimeoutMilliseconds 10000
        if (
            $handleCalibrationResult.ExitCode -ne 0 -or
            $handleCalibrationResult.StandardOutputBytes.Length -ne 0 -or
            $handleCalibrationResult.StandardErrorBytes.Length -ne 0
        ) {
            throw 'windows-handle-probe-calibration-child-failed'
        }
        $handleProbeProcess.Refresh()
        $handleCalibrationFinal = $handleProbeProcess.HandleCount
        $handleCalibrationMaximum = [Math]::Max(
            $handleCalibrationMaximum,
            $handleCalibrationFinal
        )
    }

    # calibration後も固定回数だけ待ち、閉じたruntime handleをminimumへ反映する。
    $handleCalibrationObservedFinal = $handleCalibrationFinal
    $handleCalibrationSettled = $handleCalibrationFinal
    for (
        $handleCalibrationQuiescenceAttempt = 0;
        $handleCalibrationQuiescenceAttempt -lt $handleQuiescenceSamples;
        $handleCalibrationQuiescenceAttempt++
    ) {
        [System.Threading.Thread]::Sleep(
            $handleQuiescenceWaitMilliseconds
        )
        $handleProbeProcess.Refresh()
        $handleCalibrationQuiescenceSample = $handleProbeProcess.HandleCount
        $handleCalibrationSettled = [Math]::Min(
            $handleCalibrationSettled,
            $handleCalibrationQuiescenceSample
        )
    }
    if (
        ($handleCalibrationSettled - $handleStartupBaseline) -gt
            $handleStartupGrowthLimit
    ) {
        throw (
            'windows-handle-probe-calibration-persistent ' +
            "baseline=$handleStartupBaseline " +
            "observed-final=$handleCalibrationObservedFinal " +
            "settled-final=$handleCalibrationSettled " +
            "max=$handleCalibrationMaximum " +
            "limit=$handleStartupGrowthLimit"
        )
    }

    # calibration settled値をsteady baselineとし、次の40回に残る増加だけを測る。
    $handleBaseline = $handleCalibrationSettled
    $handleMeasuredMaximum = $handleBaseline
    $handleMeasuredFinal = $handleBaseline
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
        $handleMeasuredFinal = $handleProbeProcess.HandleCount
        $handleMeasuredMaximum = [Math]::Max(
            $handleMeasuredMaximum,
            $handleMeasuredFinal
        )
    }

    # child追加実行もGCも行わず、測定後のruntime揺らぎだけをminimumへ除外する。
    # runner所有handleが残る場合は全sampleで減らず、続くconfirmationでも同じ
    # limit 4を超えて増え続けた時点でpersistent leakとしてfailする。
    $handleObservedFinal = $handleMeasuredFinal
    $handleSettledFinal = $handleMeasuredFinal
    for (
        $handleMeasuredQuiescenceAttempt = 0;
        $handleMeasuredQuiescenceAttempt -lt $handleQuiescenceSamples;
        $handleMeasuredQuiescenceAttempt++
    ) {
        [System.Threading.Thread]::Sleep(
            $handleQuiescenceWaitMilliseconds
        )
        $handleProbeProcess.Refresh()
        $handleMeasuredQuiescenceSample = $handleProbeProcess.HandleCount
        $handleSettledFinal = [Math]::Min(
            $handleSettledFinal,
            $handleMeasuredQuiescenceSample
        )
    }
    # measured結果に依存する条件付きretryにはせず、confirmationを常時1回だけ
    # 実行する。各child/native failureは従来どおりその場でfail closedにする。
    $handleConfirmationFinal = $handleSettledFinal
    $handleConfirmationMaximum = $handleSettledFinal
    for (
        $handleConfirmationAttempt = 0;
        $handleConfirmationAttempt -lt $handleConfirmationRuns;
        $handleConfirmationAttempt++
    ) {
        $handleConfirmationResult = private-marker-process-runner\Invoke-PrivateMarkerBoundedProcess `
            -FilePath $handleProbeTarget `
            -Arguments $handleProbeArguments `
            -WorkingDirectory $root `
            -EnvironmentVariables $handleProbeEnvironment `
            -TimeoutMilliseconds 10000
        if (
            $handleConfirmationResult.ExitCode -ne 0 -or
            $handleConfirmationResult.StandardOutputBytes.Length -ne 0 -or
            $handleConfirmationResult.StandardErrorBytes.Length -ne 0
        ) {
            throw 'windows-handle-probe-confirmation-child-failed'
        }
        $handleProbeProcess.Refresh()
        $handleConfirmationFinal = $handleProbeProcess.HandleCount
        $handleConfirmationMaximum = [Math]::Max(
            $handleConfirmationMaximum,
            $handleConfirmationFinal
        )
    }

    # measuredと同じbounded quiescenceで、confirmation後に残るminimumを取る。
    $handleConfirmationObservedFinal = $handleConfirmationFinal
    $handleConfirmationSettled = $handleConfirmationFinal
    for (
        $handleConfirmationQuiescenceAttempt = 0;
        $handleConfirmationQuiescenceAttempt -lt $handleQuiescenceSamples;
        $handleConfirmationQuiescenceAttempt++
    ) {
        [System.Threading.Thread]::Sleep(
            $handleQuiescenceWaitMilliseconds
        )
        $handleProbeProcess.Refresh()
        $handleConfirmationQuiescenceSample = $handleProbeProcess.HandleCount
        $handleConfirmationSettled = [Math]::Min(
            $handleConfirmationSettled,
            $handleConfirmationQuiescenceSample
        )
    }

    # 単独windowでもstartupと同じabsolute limit 16を超える増加は拒否する。
    # その内側ではlimit 4を各windowへ維持し、2つとも超えたときだけ
    # 継続leakとする。片方だけの+5などはbounded plateauとして残す。
    if (
        (
            ($handleSettledFinal - $handleBaseline) -gt
                $handleStartupGrowthLimit
        ) -or
        (
            ($handleConfirmationSettled - $handleSettledFinal) -gt
                $handleStartupGrowthLimit
        ) -or
        (
            ($handleSettledFinal - $handleBaseline) -gt
                $handleMeasuredFinalGrowthLimit -and
            ($handleConfirmationSettled - $handleSettledFinal) -gt
                $handleMeasuredFinalGrowthLimit
        )
    ) {
        throw (
            'windows-handle-probe-steady-persistent ' +
            "baseline=$handleBaseline " +
            "measured-settled=$handleSettledFinal " +
            "confirmation-settled=$handleConfirmationSettled " +
            "measured-max=$handleMeasuredMaximum " +
            "confirmation-max=$handleConfirmationMaximum " +
            "plateau-limit=$handleStartupGrowthLimit " +
            "final-limit=$handleMeasuredFinalGrowthLimit"
        )
    }

    # 親self-testが厳密なregexで読む固定ASCII evidenceだけをstdoutへ出す。
    Write-Host (
        'Windows handle stability: ' +
        "startup-baseline=$handleStartupBaseline, " +
        "warmup-observed-final=$handleWarmupObservedFinal, " +
        "warmup-settled=$handleWarmupSettled, " +
        "warmup-max=$handleWarmupMaximum, " +
        "startup-limit=$handleStartupGrowthLimit, " +
        "warmup=$handleWarmupRuns, " +
        "calibration-observed-final=$handleCalibrationObservedFinal, " +
        "calibration-settled=$handleCalibrationSettled, " +
        "calibration-max=$handleCalibrationMaximum, " +
        "calibration=$handleCalibrationRuns, " +
        "baseline=$handleBaseline, " +
        "observed-final=$handleObservedFinal, " +
        "settled-final=$handleSettledFinal, " +
        "measured-max=$handleMeasuredMaximum, runs=$handleMeasuredRuns, " +
        "confirmation-observed-final=$handleConfirmationObservedFinal, " +
        "confirmation-settled=$handleConfirmationSettled, " +
        "confirmation-max=$handleConfirmationMaximum, " +
        "confirmation=$handleConfirmationRuns, " +
        "plateau-limit=$handleStartupGrowthLimit, " +
        "final-limit=$handleMeasuredFinalGrowthLimit, " +
        "quiescence-per-window=" +
        "$($handleQuiescenceSamples)x" +
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
