[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# macOSはtrusted `setsid`を標準搭載しない。暗黙のparent-only killへ
# downgradeせず、target起動前とpublic scanner境界の双方が固定診断で
# fail closedになることだけをnative runner上で検証する。
if (-not $IsMacOS) {
    throw 'This contract test must run on macOS.'
}

$scriptRoot = $PSScriptRoot
$repoRoot = Split-Path -Parent $scriptRoot
$runnerModule = Join-Path $scriptRoot 'private-marker-process-runner.psm1'
$scanner = Join-Path $scriptRoot 'scan-private-markers.ps1'
Microsoft.PowerShell.Core\Import-Module $runnerModule -Force -ErrorAction Stop

if (-not [string]::IsNullOrEmpty((Get-PrivateMarkerTrustedSetsidPath))) {
    throw 'macOS unexpectedly exposed a trusted setsid path; review the POSIX contract.'
}

$temporaryParent = [System.IO.Path]::GetFullPath(
    [System.IO.Path]::GetTempPath()
)
$temporaryRoot = Join-Path $temporaryParent (
    'multi-agent-delegation-macos-contract-' +
    [System.Guid]::NewGuid().ToString('N')
)
[System.IO.Directory]::CreateDirectory($temporaryRoot) | Out-Null

try {
    # synthetic sentinelはrunnerがtargetを一命令も起動していないことを示す。
    $sentinel = Join-Path $temporaryRoot 'target-ran'
    $environment = [System.Collections.Generic.Dictionary[string, string]]::new(
        [System.StringComparer]::Ordinal
    )
    $runnerFailureObserved = $false
    try {
        [void](Invoke-PrivateMarkerBoundedProcess `
            -FilePath '/bin/sh' `
            -Arguments @(
                '-c',
                'printf ran > "$1"',
                'synthetic-runner',
                $sentinel
            ) `
            -WorkingDirectory $repoRoot `
            -EnvironmentVariables $environment `
            -TimeoutMilliseconds 5000 `
            -KillWaitMilliseconds 1000 `
            -MaxStandardOutputBytes 4096 `
            -MaxStandardErrorBytes 4096)
    }
    catch {
        # PowerShellはstatic .NET callの例外をMethodInvocationException等で
        # 包む。raw outer messageを出力・部分一致せず、有限depthのexception
        # chain内に固定codeそのものがある場合だけexpected failureとする。
        $candidateException = $_.Exception
        for (
            $exceptionDepth = 0;
            $exceptionDepth -lt 8 -and $null -ne $candidateException;
            $exceptionDepth++
        ) {
            if (
                [string]::Equals(
                    [string]$candidateException.Message,
                    'trusted-setsid-missing',
                    [System.StringComparison]::Ordinal
                )
            ) {
                $runnerFailureObserved = $true
                break
            }
            $nextException = $candidateException.InnerException
            if (
                $null -ne $nextException -and
                [object]::ReferenceEquals(
                    $candidateException,
                    $nextException
                )
            ) {
                break
            }
            $candidateException = $nextException
        }
    }
    if (-not $runnerFailureObserved) {
        throw 'The runner did not return the fixed trusted-setsid-missing failure.'
    }
    if ([System.IO.File]::Exists($sentinel)) {
        throw 'The unsupported-platform runner started the synthetic target.'
    }

    # public scannerもraw exception/pathを出さず、固定stdout・空stderr・exit 2
    # へ畳む。async pipe drainでchildのbuffer待ちdeadlockを避ける。
    $powerShellPath = (
        [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    )
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $powerShellPath
    [void]$startInfo.ArgumentList.Add('-NoLogo')
    [void]$startInfo.ArgumentList.Add('-NoProfile')
    [void]$startInfo.ArgumentList.Add('-NonInteractive')
    [void]$startInfo.ArgumentList.Add('-File')
    [void]$startInfo.ArgumentList.Add($scanner)
    [void]$startInfo.ArgumentList.Add('-Path')
    [void]$startInfo.ArgumentList.Add($repoRoot)
    $startInfo.WorkingDirectory = $repoRoot
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $standardOutputTask = $null
    $standardErrorTask = $null
    try {
        if (-not $process.Start()) {
            throw 'The scanner contract child did not start.'
        }
        $standardOutputTask = $process.StandardOutput.ReadToEndAsync()
        $standardErrorTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(30000)) {
            $process.Kill($true)
            [void]$process.WaitForExit(5000)
            throw 'The scanner contract child exceeded its bounded timeout.'
        }
        $drained = [System.Threading.Tasks.Task]::WaitAll(
            [System.Threading.Tasks.Task[]]@(
                $standardOutputTask,
                $standardErrorTask
            ),
            5000
        )
        if (-not $drained) {
            throw 'The scanner contract child pipes did not drain within the bounded timeout.'
        }
        $standardOutput = $standardOutputTask.GetAwaiter().GetResult()
        $standardError = $standardErrorTask.GetAwaiter().GetResult()
        $expectedOutput = (
            'Private marker scan failed: scanner-runtime-failed' +
            [Environment]::NewLine
        )
        $boundaryFailures = New-Object System.Collections.Generic.List[string]
        if ($process.ExitCode -ne 2) {
            $boundaryFailures.Add(
                'exit-code-' +
                $process.ExitCode.ToString(
                    [System.Globalization.CultureInfo]::InvariantCulture
                )
            ) | Out-Null
        }
        if (
            -not [string]::Equals(
                $standardOutput,
                $expectedOutput,
                [System.StringComparison]::Ordinal
            )
        ) {
            $entrypointOutput = (
                'Private marker scan failed: scanner-entrypoint-failed' +
                [Environment]::NewLine
            )
            $outputClass = if (
                [string]::IsNullOrEmpty($standardOutput)
            ) {
                'stdout-empty'
            } elseif (
                [string]::Equals(
                    $standardOutput,
                    $entrypointOutput,
                    [System.StringComparison]::Ordinal
                )
            ) {
                'stdout-entrypoint-fixed'
            } else {
                # raw output、長さ、hashを公開せずshape不一致だけを報告する。
                'stdout-unexpected-shape'
            }
            $boundaryFailures.Add($outputClass) | Out-Null
        }
        if (-not [string]::IsNullOrEmpty($standardError)) {
            $boundaryFailures.Add('stderr-nonempty') | Out-Null
        }
        if ($boundaryFailures.Count -gt 0) {
            throw (
                'The public scanner did not preserve its fixed ' +
                'unsupported-platform boundary: ' +
                ($boundaryFailures -join ',')
            )
        }
    }
    finally {
        if (
            $null -ne $standardOutputTask -and
            $standardOutputTask.IsCompleted
        ) {
            $standardOutputTask.Dispose()
        }
        if (
            $null -ne $standardErrorTask -and
            $standardErrorTask.IsCompleted
        ) {
            $standardErrorTask.Dispose()
        }
        $process.Dispose()
    }
}
finally {
    # 自分で作成したfixed parent直下の一意directoryだけを再帰削除する。
    $resolvedTemporaryRoot = [System.IO.Path]::GetFullPath($temporaryRoot)
    $expectedPrefix = $temporaryParent.TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar
    ) + [System.IO.Path]::DirectorySeparatorChar
    if (
        $resolvedTemporaryRoot.StartsWith(
            $expectedPrefix,
            [System.StringComparison]::Ordinal
        ) -and
        [System.IO.Directory]::Exists($resolvedTemporaryRoot)
    ) {
        [System.IO.Directory]::Delete($resolvedTemporaryRoot, $true)
    }
}

Write-Host 'macOS unsupported-platform fail-closed contract passed.'
