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

# StreamReaderはBOMを自動除去するため、stdout/stderrのbyte-exact契約には
# 使わない。専用pumpはraw BaseStreamを有限byteまで読み、上限超過時は
# それ以上bufferへ追加しない。
$rawPumpTypeName = 'MultiAgentDelegation.MacOsContractRawPump'
if ($null -eq ($rawPumpTypeName -as [type])) {
    $rawPumpSource = @'
using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;

namespace MultiAgentDelegation
{
    public sealed class MacOsContractRawPump : IDisposable
    {
        private Stream source;
        private readonly int limit;
        private MemoryStream buffer;

        public string ErrorCode { get; private set; }
        public Task PumpTask { get; private set; }

        public MacOsContractRawPump(Stream source, int limit)
        {
            this.source = source;
            this.limit = limit;
            this.buffer = new MemoryStream();
            this.ErrorCode = null;
        }

        public void Start()
        {
            this.PumpTask = Task.Factory.StartNew(
                delegate
                {
                    byte[] chunk = new byte[4096];
                    try
                    {
                        while (true)
                        {
                            int count = this.source.Read(
                                chunk,
                                0,
                                chunk.Length
                            );
                            if (count == 0)
                            {
                                break;
                            }
                            if (this.buffer.Length + count > this.limit)
                            {
                                this.ErrorCode = "capture-limit";
                                // finite childをpipe backpressureでblockさせない。
                                // cap後はbufferを増やさずEOFまで読み捨てる。
                                continue;
                            }
                            if (this.ErrorCode != null)
                            {
                                continue;
                            }
                            this.buffer.Write(chunk, 0, count);
                        }
                    }
                    catch
                    {
                        if (this.ErrorCode == null)
                        {
                            this.ErrorCode = "capture-read-failed";
                        }
                    }
                },
                CancellationToken.None,
                TaskCreationOptions.None,
                TaskScheduler.Default
            );
        }

        public byte[] ToArray()
        {
            if (this.PumpTask == null || !this.PumpTask.IsCompleted)
            {
                throw new InvalidOperationException("capture-not-complete");
            }
            return this.buffer.ToArray();
        }

        public void Dispose()
        {
            Stream ownedSource = this.source;
            this.source = null;
            if (ownedSource != null)
            {
                ownedSource.Dispose();
            }
            Task ownedTask = this.PumpTask;
            if (ownedTask != null && ownedTask.IsCompleted)
            {
                ownedTask.Dispose();
                this.PumpTask = null;
            }
            if (ownedTask == null || ownedTask.IsCompleted)
            {
                MemoryStream ownedBuffer = this.buffer;
                this.buffer = null;
                if (ownedBuffer != null)
                {
                    ownedBuffer.Dispose();
                }
            }
        }
    }
}
'@
    Microsoft.PowerShell.Utility\Add-Type `
        -TypeDefinition $rawPumpSource `
        -Language CSharp `
        -ErrorAction Stop
}

# StreamReaderへ戻してBOM-only stderrをemptyに正規化する退行を防ぐため、
# pump自身がsynthetic UTF-8 BOMを3 raw bytesのまま保持することを先に固定する。
$rawBomFixture = [byte[]]@(0xEF, 0xBB, 0xBF)
$rawBomStream = [System.IO.MemoryStream]::new(
    $rawBomFixture,
    $false
)
$rawBomPump = [MultiAgentDelegation.MacOsContractRawPump]::new(
    $rawBomStream,
    16
)
try {
    $rawBomPump.Start()
    if (-not $rawBomPump.PumpTask.Wait(5000)) {
        throw 'The raw capture BOM regression exceeded its bounded timeout.'
    }
    $capturedBom = $rawBomPump.ToArray()
    if (
        $capturedBom.Length -ne 3 -or
        $capturedBom[0] -ne 0xEF -or
        $capturedBom[1] -ne 0xBB -or
        $capturedBom[2] -ne 0xBF
    ) {
        throw 'The raw capture BOM regression was normalized.'
    }
}
finally {
    $rawBomPump.Dispose()
}

# 0 / cap直前 / cap exact / cap+1を固定し、cap+1だけが有限bufferの
# capture-limitへ畳まれることをbehaviorally確認する。
foreach ($rawBoundaryLength in @(0, 65535, 65536, 65537)) {
    $rawBoundaryBytes = [byte[]]::new($rawBoundaryLength)
    $rawBoundaryStream = [System.IO.MemoryStream]::new(
        $rawBoundaryBytes,
        $false
    )
    $rawBoundaryPump = [MultiAgentDelegation.MacOsContractRawPump]::new(
        $rawBoundaryStream,
        65536
    )
    try {
        $rawBoundaryPump.Start()
        if (-not $rawBoundaryPump.PumpTask.Wait(5000)) {
            throw 'The raw capture boundary regression exceeded its bounded timeout.'
        }
        $rawBoundaryCapture = $rawBoundaryPump.ToArray()
        if ($rawBoundaryLength -le 65536) {
            if (
                -not [string]::IsNullOrEmpty(
                    $rawBoundaryPump.ErrorCode
                ) -or
                $rawBoundaryCapture.Length -ne $rawBoundaryLength
            ) {
                throw 'The raw capture accepted boundary was not preserved.'
            }
        } elseif (
            -not [string]::Equals(
                $rawBoundaryPump.ErrorCode,
                'capture-limit',
                [System.StringComparison]::Ordinal
            ) -or
            $rawBoundaryCapture.Length -gt 65536
        ) {
            throw 'The raw capture overflow boundary did not fail closed.'
        }
    }
    finally {
        $rawBoundaryPump.Dispose()
    }
}

# 旧実装はcap到達時にreadを止め、有限1 MiB childをpipe writeでblockさせた。
# cap後もraw bytesをEOFまで読み捨て、childがtimeout前に正常終了することを
# named pipe越しのRED回帰として固定する。
$overflowStartInfo = [System.Diagnostics.ProcessStartInfo]::new()
$overflowStartInfo.FileName = (
    [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
)
[void]$overflowStartInfo.ArgumentList.Add('-NoLogo')
[void]$overflowStartInfo.ArgumentList.Add('-NoProfile')
[void]$overflowStartInfo.ArgumentList.Add('-NonInteractive')
[void]$overflowStartInfo.ArgumentList.Add('-Command')
[void]$overflowStartInfo.ArgumentList.Add(
    '$bytes = [byte[]]::new(1048576); ' +
    '$stream = [Console]::OpenStandardOutput(); ' +
    '$stream.Write($bytes, 0, $bytes.Length); $stream.Flush()'
)
$overflowStartInfo.UseShellExecute = $false
$overflowStartInfo.RedirectStandardOutput = $true
$overflowStartInfo.RedirectStandardError = $true
$overflowProcess = [System.Diagnostics.Process]::new()
$overflowProcess.StartInfo = $overflowStartInfo
$overflowOutputPump = $null
$overflowErrorPump = $null
try {
    if (-not $overflowProcess.Start()) {
        throw 'The finite overflow child did not start.'
    }
    $overflowOutputPump = [MultiAgentDelegation.MacOsContractRawPump]::new(
        $overflowProcess.StandardOutput.BaseStream,
        1024
    )
    $overflowErrorPump = [MultiAgentDelegation.MacOsContractRawPump]::new(
        $overflowProcess.StandardError.BaseStream,
        1024
    )
    $overflowOutputPump.Start()
    $overflowErrorPump.Start()
    if (-not $overflowProcess.WaitForExit(10000)) {
        $overflowProcess.Kill($true)
        [void]$overflowProcess.WaitForExit(5000)
        throw 'The finite overflow child was blocked by capture backpressure.'
    }
    $overflowDrained = [System.Threading.Tasks.Task]::WaitAll(
        [System.Threading.Tasks.Task[]]@(
            $overflowOutputPump.PumpTask,
            $overflowErrorPump.PumpTask
        ),
        5000
    )
    if (
        -not $overflowDrained -or
        $overflowProcess.ExitCode -ne 0 -or
        -not [string]::Equals(
            $overflowOutputPump.ErrorCode,
            'capture-limit',
            [System.StringComparison]::Ordinal
        ) -or
        $overflowOutputPump.ToArray().Length -gt 1024 -or
        -not [string]::IsNullOrEmpty(
            $overflowErrorPump.ErrorCode
        ) -or
        $overflowErrorPump.ToArray().Length -ne 0
    ) {
        throw 'The finite overflow child did not preserve bounded raw capture.'
    }
}
finally {
    if ($null -ne $overflowOutputPump) {
        $overflowOutputPump.Dispose()
    }
    if ($null -ne $overflowErrorPump) {
        $overflowErrorPump.Dispose()
    }
    $overflowProcess.Dispose()
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
    $standardOutputPump = $null
    $standardErrorPump = $null
    try {
        if (-not $process.Start()) {
            throw 'The scanner contract child did not start.'
        }
        $standardOutputPump = [MultiAgentDelegation.MacOsContractRawPump]::new(
            $process.StandardOutput.BaseStream,
            65536
        )
        $standardErrorPump = [MultiAgentDelegation.MacOsContractRawPump]::new(
            $process.StandardError.BaseStream,
            65536
        )
        $standardOutputPump.Start()
        $standardErrorPump.Start()
        if (-not $process.WaitForExit(30000)) {
            $process.Kill($true)
            [void]$process.WaitForExit(5000)
            throw 'The scanner contract child exceeded its bounded timeout.'
        }
        $drained = [System.Threading.Tasks.Task]::WaitAll(
            [System.Threading.Tasks.Task[]]@(
                $standardOutputPump.PumpTask,
                $standardErrorPump.PumpTask
            ),
            5000
        )
        if (-not $drained) {
            throw 'The scanner contract child pipes did not drain within the bounded timeout.'
        }
        $standardOutputBytes = $standardOutputPump.ToArray()
        $standardErrorBytes = $standardErrorPump.ToArray()
        $standardOutput = ''
        $standardOutputIsStrictUtf8 = $false
        $standardOutputHasUtf8Bom = (
            $standardOutputBytes.Length -ge 3 -and
            $standardOutputBytes[0] -eq 0xEF -and
            $standardOutputBytes[1] -eq 0xBB -and
            $standardOutputBytes[2] -eq 0xBF
        )
        if (-not $standardOutputHasUtf8Bom) {
            try {
                $strictUtf8 = New-Object System.Text.UTF8Encoding(
                    $false,
                    $true
                )
                $standardOutput = $strictUtf8.GetString(
                    $standardOutputBytes
                )
                $standardOutputIsStrictUtf8 = $true
            }
            catch {
                $standardOutputIsStrictUtf8 = $false
            }
        }
        $runtimeOutputBase = (
            'Private marker scan failed: scanner-runtime-failed'
        )
        $expectedOutput = $runtimeOutputBase + [Environment]::NewLine
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
            -not [string]::IsNullOrEmpty(
                $standardOutputPump.ErrorCode
            )
        ) {
            $boundaryFailures.Add('stdout-capture-failed') | Out-Null
        } elseif ($standardOutputHasUtf8Bom) {
            $boundaryFailures.Add('stdout-runtime-bom') | Out-Null
        } elseif (-not $standardOutputIsStrictUtf8) {
            $boundaryFailures.Add('stdout-invalid-utf8') | Out-Null
        } elseif (
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
            } elseif (
                [string]::Equals(
                    $standardOutput,
                    ($runtimeOutputBase + "`r`n"),
                    [System.StringComparison]::Ordinal
                )
            ) {
                'stdout-runtime-crlf'
            } elseif (
                [string]::Equals(
                    $standardOutput,
                    $runtimeOutputBase,
                    [System.StringComparison]::Ordinal
                )
            ) {
                'stdout-runtime-no-newline'
            } elseif (
                [string]::Equals(
                    $standardOutput,
                    ($expectedOutput + [Environment]::NewLine),
                    [System.StringComparison]::Ordinal
                )
            ) {
                'stdout-runtime-extra-newline'
            } elseif (
                $standardOutput.StartsWith(
                    $runtimeOutputBase,
                    [System.StringComparison]::Ordinal
                )
            ) {
                'stdout-runtime-prefix-extra'
            } elseif (
                $standardOutput.Contains(
                    $runtimeOutputBase,
                    [System.StringComparison]::Ordinal
                )
            ) {
                'stdout-runtime-embedded-extra'
            } else {
                # raw output、長さ、hashを公開せずshape不一致だけを報告する。
                'stdout-other-fixed-shape'
            }
            $boundaryFailures.Add($outputClass) | Out-Null
        }
        if (
            -not [string]::IsNullOrEmpty(
                $standardErrorPump.ErrorCode
            )
        ) {
            $boundaryFailures.Add('stderr-capture-failed') | Out-Null
        } elseif ($standardErrorBytes.Length -ne 0) {
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
        if ($null -ne $standardOutputPump) {
            $standardOutputPump.Dispose()
        }
        if ($null -ne $standardErrorPump) {
            $standardErrorPump.Dispose()
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
