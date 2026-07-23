[CmdletBinding()]
param(
    [string]$Path = '',
    [switch]$EnvironmentContractProbe,
    [switch]$EnvironmentRemovalProbe,
    [string]$ProbeCleanPath = '',
    [string]$ProbeFailurePath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($scriptRoot)) {
    $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}

if ([string]::IsNullOrWhiteSpace($Path)) {
    $Path = Split-Path -Parent $scriptRoot
}

$root = (Resolve-Path -LiteralPath $Path).Path
$scanner = Join-Path $root 'scripts/scan-private-markers.ps1'
$selfTest = $MyInvocation.MyCommand.Path
if (-not (Test-Path -LiteralPath $scanner -PathType Leaf)) {
    throw "Missing scanner script: $scanner"
}

$isWindowsPlatform = [Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
$hostExecutableName = if ($PSVersionTable.PSVersion.Major -le 5) {
    'powershell.exe'
} elseif ($isWindowsPlatform) {
    'pwsh.exe'
} else {
    'pwsh'
}
$powerShellPath = Join-Path $PSHOME $hostExecutableName
if (-not (Test-Path -LiteralPath $powerShellPath -PathType Leaf)) {
    $powerShellPath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
}
$powerShellLeaf = [System.IO.Path]::GetFileName($powerShellPath)
if (
    $PSVersionTable.PSVersion.Major -le 5 -and
    $powerShellLeaf -notlike 'powershell*'
) {
    throw "Windows PowerShell self-test resolved an unexpected host: $powerShellLeaf"
}
if (
    $PSVersionTable.PSVersion.Major -ge 6 -and
    $powerShellLeaf -notlike 'pwsh*'
) {
    throw "PowerShell 7+ self-test resolved an unexpected host: $powerShellLeaf"
}
$gitCommand = Get-Command git -ErrorAction Stop
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$failures = New-Object System.Collections.Generic.List[string]

function Add-Failure {
    param([string]$Message)
    $failures.Add($Message) | Out-Null
}

function ConvertTo-WindowsProcessArgument {
    param([AllowEmptyString()][string]$Value)

    if ([string]::IsNullOrEmpty($Value)) {
        return '""'
    }
    if ($Value -notmatch '[\s"]') {
        return $Value
    }

    # Windows PowerShell 5.1 では ArgumentList がないため、Windowsの
    # command-line quoting規則で空白・quote・末尾backslashを保持する。
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    $backslashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq [char]92) {
            $backslashes++
            continue
        }
        if ($character -eq [char]34) {
            [void]$builder.Append(([string][char]92) * (($backslashes * 2) + 1))
            [void]$builder.Append([char]34)
            $backslashes = 0
            continue
        }
        if ($backslashes -gt 0) {
            [void]$builder.Append(([string][char]92) * $backslashes)
            $backslashes = 0
        }
        [void]$builder.Append($character)
    }
    if ($backslashes -gt 0) {
        [void]$builder.Append(([string][char]92) * ($backslashes * 2))
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Set-ProcessArguments {
    param(
        [System.Diagnostics.ProcessStartInfo]$StartInfo,
        [string[]]$Arguments
    )

    $argumentListProperty = $StartInfo.PSObject.Properties['ArgumentList']
    if ($null -ne $argumentListProperty) {
        foreach ($argument in $Arguments) {
            $StartInfo.ArgumentList.Add($argument)
        }
        return
    }

    $StartInfo.Arguments = (
        $Arguments |
            ForEach-Object { ConvertTo-WindowsProcessArgument -Value $_ }
    ) -join ' '
}

function Set-ChildEnvironmentOverrides {
    param(
        [System.Diagnostics.ProcessStartInfo]$StartInfo,
        [System.Collections.IDictionary]$EnvironmentOverrides
    )

    if ($null -eq $EnvironmentOverrides) {
        return
    }

    # ProcessStartInfoの環境は親processから複製された子専用dictionaryである。
    # 親envを変更しないので、PS5.1でpresent-emptyが削除扱いになる問題を避ける。
    foreach ($name in $EnvironmentOverrides.Keys) {
        $value = $EnvironmentOverrides[$name]
        if ($null -eq $value) {
            [void]$StartInfo.EnvironmentVariables.Remove([string]$name)
        } else {
            $StartInfo.EnvironmentVariables[[string]$name] = [string]$value
        }
    }
}

function Stop-ProcessTree {
    param(
        [System.Diagnostics.Process]$Process,
        [int]$KillWaitMilliseconds = 5000
    )

    if ($Process.HasExited) {
        return
    }

    # .NET CoreではKill(true)でdescendantを含める。PS5.1ではtaskkill /Tを
    # bounded childとして使い、最後にdirect killも試す。
    $treeKillMethod = $Process.GetType().GetMethods() |
        Where-Object {
            $_.Name -eq 'Kill' -and
            $_.GetParameters().Count -eq 1 -and
            $_.GetParameters()[0].ParameterType -eq [bool]
        } |
        Select-Object -First 1

    if ($null -ne $treeKillMethod) {
        [void]$treeKillMethod.Invoke($Process, @($true))
    } elseif ($isWindowsPlatform) {
        $taskKillPath = Join-Path $env:SystemRoot 'System32\taskkill.exe'
        $taskKillStartInfo = New-Object System.Diagnostics.ProcessStartInfo
        $taskKillStartInfo.FileName = $taskKillPath
        $taskKillStartInfo.UseShellExecute = $false
        $taskKillStartInfo.CreateNoWindow = $true
        Set-ProcessArguments -StartInfo $taskKillStartInfo -Arguments @(
            '/PID', "$($Process.Id)", '/T', '/F'
        )
        $taskKillProcess = New-Object System.Diagnostics.Process
        $taskKillProcess.StartInfo = $taskKillStartInfo
        try {
            [void]$taskKillProcess.Start()
            if (-not $taskKillProcess.WaitForExit($KillWaitMilliseconds)) {
                $taskKillProcess.Kill()
                if (-not $taskKillProcess.WaitForExit($KillWaitMilliseconds)) {
                    throw 'taskkill did not exit within the bounded re-wait.'
                }
            }
        }
        finally {
            $taskKillProcess.Dispose()
        }
    } else {
        $Process.Kill()
    }

    if (-not $Process.WaitForExit($KillWaitMilliseconds) -and -not $Process.HasExited) {
        $Process.Kill()
        if (-not $Process.WaitForExit($KillWaitMilliseconds)) {
            throw 'Timed-out child process did not exit after tree termination.'
        }
    }
}

function Read-BoundedProcessStreams {
    param(
        [System.Diagnostics.Process]$Process,
        [int]$TimeoutMilliseconds,
        [int]$KillWaitMilliseconds,
        [int]$MaxStandardOutputBytes,
        [int]$MaxStandardErrorBytes
    )

    $stdoutBuffer = New-Object byte[] 8192
    $stderrBuffer = New-Object byte[] 4096
    $stdoutBytes = New-Object System.IO.MemoryStream
    $stderrBytes = New-Object System.IO.MemoryStream
    $stdoutTask = $Process.StandardOutput.BaseStream.ReadAsync(
        $stdoutBuffer,
        0,
        $stdoutBuffer.Length
    )
    $stderrTask = $Process.StandardError.BaseStream.ReadAsync(
        $stderrBuffer,
        0,
        $stderrBuffer.Length
    )
    $stdoutDone = $false
    $stderrDone = $false
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $failure = ''

    try {
        while ($true) {
            if ($stdoutDone -and $stderrDone -and $Process.HasExited) {
                break
            }
            $remaining = $TimeoutMilliseconds - [int]$stopwatch.ElapsedMilliseconds
            if ($remaining -le 0) {
                $failure = "Child process timed out after $TimeoutMilliseconds ms."
                break
            }

            $pending = New-Object System.Collections.Generic.List[System.Threading.Tasks.Task]
            if (-not $stdoutDone) {
                $pending.Add($stdoutTask) | Out-Null
            }
            if (-not $stderrDone) {
                $pending.Add($stderrTask) | Out-Null
            }
            if ($pending.Count -gt 0) {
                [void][System.Threading.Tasks.Task]::WaitAny(
                    $pending.ToArray(),
                    [Math]::Min(100, $remaining)
                )
            } else {
                [void]$Process.WaitForExit([Math]::Min(100, $remaining))
            }

            if (-not $stdoutDone -and $stdoutTask.IsCompleted) {
                try {
                    $count = $stdoutTask.GetAwaiter().GetResult()
                }
                catch {
                    $failure = 'Child stdout read failed.'
                    break
                }
                if ($count -eq 0) {
                    $stdoutDone = $true
                } elseif (($stdoutBytes.Length + $count) -gt $MaxStandardOutputBytes) {
                    $failure = 'Child stdout exceeded its bounded byte limit.'
                    break
                } else {
                    $stdoutBytes.Write($stdoutBuffer, 0, $count)
                    $stdoutTask = $Process.StandardOutput.BaseStream.ReadAsync(
                        $stdoutBuffer,
                        0,
                        $stdoutBuffer.Length
                    )
                }
            }

            if (-not $stderrDone -and $stderrTask.IsCompleted) {
                try {
                    $count = $stderrTask.GetAwaiter().GetResult()
                }
                catch {
                    $failure = 'Child stderr read failed.'
                    break
                }
                if ($count -eq 0) {
                    $stderrDone = $true
                } elseif (($stderrBytes.Length + $count) -gt $MaxStandardErrorBytes) {
                    $failure = 'Child stderr exceeded its bounded byte limit.'
                    break
                } else {
                    $stderrBytes.Write($stderrBuffer, 0, $count)
                    $stderrTask = $Process.StandardError.BaseStream.ReadAsync(
                        $stderrBuffer,
                        0,
                        $stderrBuffer.Length
                    )
                }
            }
        }

        if (-not [string]::IsNullOrEmpty($failure)) {
            try {
                if (-not $Process.HasExited) {
                    Stop-ProcessTree `
                        -Process $Process `
                        -KillWaitMilliseconds $KillWaitMilliseconds
                }
            }
            finally {
                $Process.StandardOutput.Close()
                $Process.StandardError.Close()
            }
            $pendingReads = @(
                @($stdoutTask, $stderrTask) |
                    Where-Object { $null -ne $_ -and -not $_.IsCompleted }
            )
            if ($pendingReads.Count -gt 0) {
                try {
                    [void][System.Threading.Tasks.Task]::WaitAll(
                        [System.Threading.Tasks.Task[]]$pendingReads,
                        $KillWaitMilliseconds
                    )
                }
                catch {
                    # pipe closeによるfault/cancelは固定failureへ畳み込む。
                }
            }
            throw $failure
        }

        return [pscustomobject]@{
            StandardOutput = $utf8NoBom.GetString($stdoutBytes.ToArray())
            StandardError = $utf8NoBom.GetString($stderrBytes.ToArray())
        }
    }
    finally {
        $stopwatch.Stop()
        $stdoutBytes.Dispose()
        $stderrBytes.Dispose()
    }
}

function Invoke-BoundedProcess {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [string]$WorkingDirectory,
        [System.Collections.IDictionary]$EnvironmentOverrides = $null,
        [int]$TimeoutMilliseconds = 30000,
        [int]$KillWaitMilliseconds = 5000,
        [int]$MaxStandardOutputBytes = 8MB,
        [int]$MaxStandardErrorBytes = 1MB
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
        $startInfo.WorkingDirectory = $WorkingDirectory
    }
    Set-ProcessArguments -StartInfo $startInfo -Arguments $Arguments
    Set-ChildEnvironmentOverrides -StartInfo $startInfo -EnvironmentOverrides $EnvironmentOverrides

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    $started = $false
    try {
        [void]$process.Start()
        $started = $true
        $streamResult = Read-BoundedProcessStreams `
            -Process $process `
            -TimeoutMilliseconds $TimeoutMilliseconds `
            -KillWaitMilliseconds $KillWaitMilliseconds `
            -MaxStandardOutputBytes $MaxStandardOutputBytes `
            -MaxStandardErrorBytes $MaxStandardErrorBytes

        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            StandardOutput = $streamResult.StandardOutput
            StandardError = $streamResult.StandardError
            Output = ($streamResult.StandardOutput + $streamResult.StandardError)
        }
    }
    finally {
        if ($started -and -not $process.HasExited) {
            Stop-ProcessTree -Process $process -KillWaitMilliseconds $KillWaitMilliseconds
        }
        $process.Dispose()
    }
}

function Get-PowerShellArguments {
    param([string[]]$AdditionalArguments)

    $arguments = @('-NoLogo', '-NoProfile', '-NonInteractive')
    if ($isWindowsPlatform) {
        $arguments += @('-ExecutionPolicy', 'Bypass')
    }
    return @($arguments + $AdditionalArguments)
}

function Invoke-Scanner {
    param(
        [string]$ScanPath,
        [System.Collections.IDictionary]$EnvironmentOverrides = $null
    )

    $arguments = Get-PowerShellArguments -AdditionalArguments @(
        '-File', $scanner, '-Path', $ScanPath
    )
    return Invoke-BoundedProcess `
        -FilePath $powerShellPath `
        -Arguments $arguments `
        -WorkingDirectory $root `
        -EnvironmentOverrides $EnvironmentOverrides `
        -TimeoutMilliseconds 30000
}

function Get-GitEnvironmentSnapshot {
    return @(
        [Environment]::GetEnvironmentVariables('Process').GetEnumerator() |
            Where-Object { ([string]$_.Key) -cmatch '^GIT_' } |
            ForEach-Object {
                $name = [string]$_.Key
                $value = [string]$_.Value
                '{0}:{1}:{2}:{3}' -f $name.Length, $name, $value.Length, $value
            } |
            Sort-Object -CaseSensitive
    )
}

function Test-SnapshotEqual {
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$Before,
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$After
    )

    $beforeItems = @($Before)
    $afterItems = @($After)
    if ($beforeItems.Count -ne $afterItems.Count) {
        return $false
    }
    if ($beforeItems.Count -eq 0) {
        return $true
    }
    return @(
        Compare-Object `
            -ReferenceObject $beforeItems `
            -DifferenceObject $afterItems `
            -CaseSensitive
    ).Count -eq 0
}

function Get-EnvironmentVariableState {
    param([string]$Name)

    $environment = [Environment]::GetEnvironmentVariables('Process')
    $exists = $environment.Contains($Name)
    return [pscustomobject]@{
        Exists = $exists
        Value = if ($exists) { [string]$environment[$Name] } else { $null }
    }
}

function Test-EnvironmentVariableStateEqual {
    param(
        [object]$Left,
        [object]$Right
    )

    return (
        $Left.Exists -eq $Right.Exists -and
        (
            (-not $Left.Exists) -or
            $Left.Value -ceq $Right.Value
        )
    )
}

function Invoke-TestGit {
    param(
        [string]$WorkingDirectory,
        [string[]]$Arguments
    )

    $environmentOverrides = @{}
    foreach ($name in @(
        [Environment]::GetEnvironmentVariables('Process').Keys |
            ForEach-Object { [string]$_ } |
            Where-Object { $_ -match '^GIT_' }
    )) {
        $environmentOverrides[$name] = $null
    }
    $environmentOverrides['GIT_CONFIG_NOSYSTEM'] = '1'
    $environmentOverrides['GIT_ATTR_NOSYSTEM'] = '1'
    $environmentOverrides['GIT_CONFIG_GLOBAL'] = $script:testGitEmptyConfig
    $environmentOverrides['GIT_CONFIG_SYSTEM'] = $script:testGitEmptyConfig
    $environmentOverrides['GIT_TERMINAL_PROMPT'] = '0'
    $environmentOverrides['GIT_OPTIONAL_LOCKS'] = '0'
    $environmentOverrides['GIT_NO_LAZY_FETCH'] = '1'
    $environmentOverrides['GIT_NO_REPLACE_OBJECTS'] = '1'
    $environmentOverrides['GIT_PROTOCOL_FROM_USER'] = '0'

    $safeArguments = @(
        '--no-pager',
        '--no-lazy-fetch',
        '--no-replace-objects',
        '-c', "core.hooksPath=$script:testGitEmptyHooks",
        '-c', "core.attributesFile=$script:testGitEmptyAttributes",
        '-c', "core.excludesFile=$script:testGitEmptyExcludes",
        '-c', "init.templateDir=$script:testGitEmptyTemplate",
        '-c', 'core.fsmonitor=false',
        '-c', 'credential.helper=',
        '-c', 'credential.interactive=never',
        '-c', 'protocol.allow=never',
        '-c', 'protocol.file.allow=never',
        '-c', 'protocol.ext.allow=never',
        '-c', 'protocol.http.allow=never',
        '-c', 'protocol.https.allow=never',
        '-c', 'protocol.ssh.allow=never',
        '-c', 'protocol.git.allow=never',
        '-C', $WorkingDirectory
    ) + $Arguments

    $result = Invoke-BoundedProcess `
        -FilePath $gitCommand.Source `
        -Arguments $safeArguments `
        -WorkingDirectory $WorkingDirectory `
        -EnvironmentOverrides $environmentOverrides `
        -TimeoutMilliseconds 15000

    if ($result.ExitCode -ne 0) {
        throw "Synthetic Git setup failed for operation '$($Arguments[0])' (exit $($result.ExitCode))."
    }
    return $result
}

function Test-PathTextEqual {
    param(
        [string]$Left,
        [string]$Right
    )

    $comparison = if ($isWindowsPlatform) {
        [System.StringComparison]::OrdinalIgnoreCase
    } else {
        [System.StringComparison]::Ordinal
    }
    return $Left.Equals($Right, $comparison)
}

function Remove-TestRoot {
    param(
        [string]$RootPath,
        [string]$TemporaryParent
    )

    $resolvedRoot = [System.IO.Path]::GetFullPath($RootPath)
    $resolvedParent = [System.IO.Path]::GetDirectoryName($resolvedRoot)
    $resolvedTemporaryParent = [System.IO.Path]::GetFullPath($TemporaryParent)
    $separators = [char[]]@(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
    $resolvedParent = $resolvedParent.TrimEnd($separators)
    $resolvedTemporaryParent = $resolvedTemporaryParent.TrimEnd($separators)
    $rootName = [System.IO.Path]::GetFileName($resolvedRoot)

    # recursive deleteは、このrunがOS temp直下へ作ったGUID fixtureだけに限定する。
    if (
        -not (Test-PathTextEqual -Left $resolvedParent -Right $resolvedTemporaryParent) -or
        $rootName -cnotmatch '^multi-agent-delegation-scan-(?:test|outside)-[0-9a-f]{32}$'
    ) {
        throw 'Refusing to remove a scanner fixture outside the bounded temp root.'
    }

    if (Test-Path -LiteralPath $resolvedRoot) {
        $rootItem = Get-Item -LiteralPath $resolvedRoot
        if (($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'Refusing to recursively remove a scanner fixture through a reparse point.'
        }
        Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
    }
}

function Invoke-EnvironmentContractProbe {
    $presentEmptyName = 'GIT_PRESENT_EMPTY_CONTRACT'
    $absentName = 'GIT_ABSENT_CONTRACT'
    $presentBefore = Get-EnvironmentVariableState -Name $presentEmptyName
    $absentBefore = Get-EnvironmentVariableState -Name $absentName

    if (-not $presentBefore.Exists -or $presentBefore.Value -cne '') {
        throw 'Probe host did not receive the required present-empty environment value.'
    }
    if ($absentBefore.Exists) {
        throw 'Probe host unexpectedly received the required absent environment value.'
    }

    # present-emptyを保持するprobe親から、子専用dictionaryのRemoveを通して
    # 実childでabsentになったことを確認する。PS5.1の空文字代入に頼らない。
    $removalArguments = Get-PowerShellArguments -AdditionalArguments @(
        '-File', $selfTest,
        '-Path', $root,
        '-EnvironmentRemovalProbe'
    )
    $removalResult = Invoke-BoundedProcess `
        -FilePath $powerShellPath `
        -Arguments $removalArguments `
        -WorkingDirectory $root `
        -EnvironmentOverrides @{
            $presentEmptyName = $null
            $absentName = $null
        } `
        -TimeoutMilliseconds 15000
    if (
        $removalResult.ExitCode -ne 0 -or
        $removalResult.Output -notmatch 'Environment removal probe passed'
    ) {
        throw 'Child environment removal did not preserve the required absent state.'
    }

    $cleanResult = Invoke-Scanner -ScanPath $ProbeCleanPath
    if ($cleanResult.ExitCode -ne 0) {
        throw 'Environment probe clean scan did not succeed.'
    }
    $presentAfterSuccess = Get-EnvironmentVariableState -Name $presentEmptyName
    $absentAfterSuccess = Get-EnvironmentVariableState -Name $absentName
    if (
        -not (Test-EnvironmentVariableStateEqual -Left $presentBefore -Right $presentAfterSuccess) -or
        -not (Test-EnvironmentVariableStateEqual -Left $absentBefore -Right $absentAfterSuccess)
    ) {
        throw 'Environment existence/value changed after a successful scanner child.'
    }

    $failureResult = Invoke-Scanner -ScanPath $ProbeFailurePath
    if ($failureResult.ExitCode -eq 0) {
        throw 'Environment probe failure scan unexpectedly succeeded.'
    }
    $presentAfterFailure = Get-EnvironmentVariableState -Name $presentEmptyName
    $absentAfterFailure = Get-EnvironmentVariableState -Name $absentName
    if (
        -not (Test-EnvironmentVariableStateEqual -Left $presentBefore -Right $presentAfterFailure) -or
        -not (Test-EnvironmentVariableStateEqual -Left $absentBefore -Right $absentAfterFailure)
    ) {
        throw 'Environment existence/value changed after a failing scanner child.'
    }

    Write-Host 'Environment contract probe passed.'
}

if ($EnvironmentRemovalProbe) {
    foreach ($name in @('GIT_PRESENT_EMPTY_CONTRACT', 'GIT_ABSENT_CONTRACT')) {
        $state = Get-EnvironmentVariableState -Name $name
        if ($state.Exists) {
            throw 'Environment removal probe received a variable that should be absent.'
        }
    }
    Write-Host 'Environment removal probe passed.'
    exit 0
}

if ($EnvironmentContractProbe) {
    if (
        [string]::IsNullOrWhiteSpace($ProbeCleanPath) -or
        [string]::IsNullOrWhiteSpace($ProbeFailurePath)
    ) {
        throw 'Environment contract probe requires clean and failing fixture paths.'
    }
    Invoke-EnvironmentContractProbe
    exit 0
}

$tempParent = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
$tempRoot = Join-Path $tempParent (
    'multi-agent-delegation-scan-test-' + [System.Guid]::NewGuid().ToString('N')
)
$outsideRoot = Join-Path $tempParent (
    'multi-agent-delegation-scan-outside-' + [System.Guid]::NewGuid().ToString('N')
)
$primaryFailure = $null

New-Item -ItemType Directory -Path $tempRoot | Out-Null
New-Item -ItemType Directory -Path $outsideRoot | Out-Null

try {
    $script:testGitIsolationRoot = Join-Path $tempRoot 'git-isolation'
    $script:testGitEmptyConfig = Join-Path $script:testGitIsolationRoot 'empty.gitconfig'
    $script:testGitEmptyHooks = Join-Path $script:testGitIsolationRoot 'hooks'
    $script:testGitEmptyAttributes = Join-Path $script:testGitIsolationRoot 'attributes'
    $script:testGitEmptyExcludes = Join-Path $script:testGitIsolationRoot 'excludes'
    $script:testGitEmptyTemplate = Join-Path $script:testGitIsolationRoot 'template'
    New-Item -ItemType Directory -Path $script:testGitIsolationRoot | Out-Null
    New-Item -ItemType Directory -Path $script:testGitEmptyHooks | Out-Null
    New-Item -ItemType Directory -Path $script:testGitEmptyTemplate | Out-Null
    [System.IO.File]::WriteAllText($script:testGitEmptyConfig, '', $utf8NoBom)
    [System.IO.File]::WriteAllText($script:testGitEmptyAttributes, '', $utf8NoBom)
    [System.IO.File]::WriteAllText($script:testGitEmptyExcludes, '', $utf8NoBom)

    $cleanRoot = Join-Path $tempRoot 'clean'
    New-Item -ItemType Directory -Path $cleanRoot | Out-Null
    [System.IO.File]::WriteAllLines(
        (Join-Path $cleanRoot 'README.md'),
        [string[]]@(
            '# Clean synthetic fixture',
            'A completion notice is a claim, not evidence. Verify artifacts first.'
        ),
        $utf8NoBom
    )

    $cleanResult = Invoke-Scanner -ScanPath $cleanRoot
    if ($cleanResult.ExitCode -ne 0) {
        Add-Failure "Expected clean fixture to pass, but scanner exited $($cleanResult.ExitCode)."
    }

    $markerRoot = Join-Path $tempRoot 'marker'
    New-Item -ItemType Directory -Path $markerRoot | Out-Null
    $syntheticMarker = ('g' + 'hp_') + 'synthetic_placeholder_only'
    [System.IO.File]::WriteAllText(
        (Join-Path $markerRoot 'leak.txt'),
        "synthetic marker: $syntheticMarker",
        $utf8NoBom
    )

    $markerResult = Invoke-Scanner -ScanPath $markerRoot
    if ($markerResult.ExitCode -eq 0) {
        Add-Failure 'Expected synthetic marker fixture to fail, but scanner exited 0.'
    }
    if ($markerResult.Output -notmatch 'github-classic-token-prefix') {
        Add-Failure 'Expected synthetic marker output to name github-classic-token-prefix.'
    }

    # 同じPowerShell hostを明示してprobeを再起動し、present-empty/absentを
    # 親processへ触れずに成功・失敗scanの前後で固定する。
    $probeEnvironment = @{
        'GIT_PRESENT_EMPTY_CONTRACT' = ''
        'GIT_ABSENT_CONTRACT' = $null
    }
    $probeArguments = Get-PowerShellArguments -AdditionalArguments @(
        '-File', $selfTest,
        '-Path', $root,
        '-EnvironmentContractProbe',
        '-ProbeCleanPath', $cleanRoot,
        '-ProbeFailurePath', $markerRoot
    )
    $probeResult = Invoke-BoundedProcess `
        -FilePath $powerShellPath `
        -Arguments $probeArguments `
        -WorkingDirectory $root `
        -EnvironmentOverrides $probeEnvironment `
        -TimeoutMilliseconds 30000
    if (
        $probeResult.ExitCode -ne 0 -or
        $probeResult.Output -notmatch 'Environment contract probe passed'
    ) {
        Add-Failure 'Expected the present-empty/absent environment contract probe to pass.'
    }

    # 孫processが親のstdout pipeを継承するfixtureで、process timeoutと
    # chunked output drainの双方がboundedかつtree-killになることを確認する。
    $grandchildPidPath = Join-Path $tempRoot 'grandchild-pipe.pid'
    $grandchildScript = Join-Path $tempRoot 'grandchild-pipe.ps1'
    $pipeParentScript = Join-Path $tempRoot 'pipe-parent.ps1'
    [System.IO.File]::WriteAllText(
        $grandchildScript,
        @'
param([string]$PidPath)
[System.IO.File]::WriteAllText($PidPath, [string]$PID)
[Console]::Out.WriteLine('grandchild-pipe-open')
Start-Sleep -Seconds 30
'@,
        $utf8NoBom
    )
    [System.IO.File]::WriteAllText(
        $pipeParentScript,
        @'
param(
    [string]$HostPath,
    [string]$GrandchildScript,
    [string]$PidPath
)
$childArguments = @('-NoLogo', '-NoProfile', '-NonInteractive')
if ([Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
    $childArguments += @('-ExecutionPolicy', 'Bypass')
}
$childArguments += @('-File', $GrandchildScript, '-PidPath', $PidPath)
& $HostPath @childArguments
'@,
        $utf8NoBom
    )

    $timeoutObserved = $false
    $timeoutStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $timeoutArguments = Get-PowerShellArguments -AdditionalArguments @(
            '-File', $pipeParentScript,
            '-HostPath', $powerShellPath,
            '-GrandchildScript', $grandchildScript,
            '-PidPath', $grandchildPidPath
        )
        Invoke-BoundedProcess `
            -FilePath $powerShellPath `
            -Arguments $timeoutArguments `
            -WorkingDirectory $root `
            -TimeoutMilliseconds 1500 | Out-Null
    }
    catch {
        if ($_.Exception.Message -match 'timed out') {
            $timeoutObserved = $true
        } else {
            Add-Failure 'Bounded child timeout raised an unexpected failure class.'
        }
    }
    finally {
        $timeoutStopwatch.Stop()
    }
    if (-not $timeoutObserved) {
        Add-Failure 'Expected the bounded child timeout path to terminate the child.'
    }
    if ($timeoutStopwatch.Elapsed.TotalSeconds -gt 12) {
        Add-Failure 'Bounded child timeout/output-drain path exceeded its fixed deadline.'
    }
    if (-not (Test-Path -LiteralPath $grandchildPidPath -PathType Leaf)) {
        Add-Failure 'Grandchild pipe fixture did not start before the bounded timeout.'
    } else {
        $grandchildPidText = [System.IO.File]::ReadAllText($grandchildPidPath).Trim()
        $grandchildPid = 0
        if (-not [int]::TryParse($grandchildPidText, [ref]$grandchildPid)) {
            Add-Failure 'Grandchild pipe fixture wrote an invalid PID.'
        } elseif ($null -ne (Get-Process -Id $grandchildPid -ErrorAction SilentlyContinue)) {
            Add-Failure 'Grandchild pipe fixture survived tree termination.'
            Stop-Process -Id $grandchildPid -Force -ErrorAction SilentlyContinue
        }
    }

    # 短時間に大量stdoutを出すchildもmemoryへ全量保持せず、byte capで
    # tree終了して固定failureへ畳み込む。
    $outputLimitObserved = $false
    try {
        $outputLimitArguments = Get-PowerShellArguments -AdditionalArguments @(
            '-Command', "[Console]::Out.Write('x' * 131072)"
        )
        Invoke-BoundedProcess `
            -FilePath $powerShellPath `
            -Arguments $outputLimitArguments `
            -WorkingDirectory $root `
            -TimeoutMilliseconds 5000 `
            -MaxStandardOutputBytes 32768 | Out-Null
    }
    catch {
        if ($_.Exception.Message -match 'bounded byte limit') {
            $outputLimitObserved = $true
        } else {
            Add-Failure 'Bounded output fixture raised an unexpected failure class.'
        }
    }
    if (-not $outputLimitObserved) {
        Add-Failure 'Expected the bounded output fixture to hit its byte cap.'
    }

    # 合成git.exeでmalformed空recordと4097件の非空recordを返し、
    # downgrade拒否とparser/CPU budgetをbehaviorally固定する。
    if ($isWindowsPlatform) {
        $syntheticGitRoot = Join-Path $tempRoot 'synthetic-nul-git-root'
        $syntheticGitBin = Join-Path $tempRoot 'synthetic-nul-git-bin'
        $syntheticGitSource = Join-Path $syntheticGitBin 'SyntheticGit.cs'
        $syntheticGitExe = Join-Path $syntheticGitBin 'git.exe'
        New-Item -ItemType Directory -Path $syntheticGitRoot | Out-Null
        New-Item -ItemType Directory -Path (
            Join-Path $syntheticGitRoot '.git'
        ) | Out-Null
        New-Item -ItemType Directory -Path $syntheticGitBin | Out-Null
        [System.IO.File]::WriteAllText(
            $syntheticGitSource,
            @'
using System;
using System.IO;

public static class SyntheticGit
{
    public static int Main(string[] args)
    {
        if (Array.IndexOf(args, "--show-toplevel") >= 0)
        {
            Console.WriteLine(
                Environment.GetEnvironmentVariable("SYNTHETIC_GIT_ROOT"));
            return 0;
        }

        if (Array.IndexOf(args, "ls-files") >= 0)
        {
            Stream output = Console.OpenStandardOutput();
            if (String.Equals(
                    Environment.GetEnvironmentVariable("SYNTHETIC_GIT_MODE"),
                    "empty-record",
                    StringComparison.Ordinal))
            {
                output.WriteByte(0);
                output.Flush();
                return 0;
            }

            byte[] record = new byte[] { 120, 0 };
            for (int index = 0; index < 4097; index++)
                output.Write(record, 0, record.Length);
            output.Flush();
            return 0;
        }

        return 1;
    }
}
'@,
            $utf8NoBom
        )
        $windowsPowerShellPath = Join-Path $env:SystemRoot (
            'System32\WindowsPowerShell\v1.0\powershell.exe'
        )
        $compilerCommand = (
            "Add-Type -Path '$syntheticGitSource' " +
            "-OutputAssembly '$syntheticGitExe' " +
            '-OutputType ConsoleApplication'
        )
        $compilerResult = Invoke-BoundedProcess `
            -FilePath $windowsPowerShellPath `
            -Arguments @(
                '-NoLogo',
                '-NoProfile',
                '-NonInteractive',
                '-ExecutionPolicy',
                'Bypass',
                '-Command',
                $compilerCommand
            ) `
            -WorkingDirectory $root `
            -TimeoutMilliseconds 30000
        if (
            $compilerResult.ExitCode -ne 0 -or
            -not (Test-Path -LiteralPath $syntheticGitExe -PathType Leaf)
        ) {
            Add-Failure 'Synthetic bounded Git fixture could not be compiled.'
        } else {
            $syntheticGitStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            try {
                $syntheticGitResult = Invoke-Scanner `
                    -ScanPath $syntheticGitRoot `
                    -EnvironmentOverrides @{
                        'PATH' = (
                            $syntheticGitBin +
                            [System.IO.Path]::PathSeparator +
                            [Environment]::GetEnvironmentVariable('PATH')
                        )
                        'SYNTHETIC_GIT_ROOT' = $syntheticGitRoot
                        'SYNTHETIC_GIT_MODE' = 'record-limit'
                    }
            }
            finally {
                $syntheticGitStopwatch.Stop()
            }
            if (
                $syntheticGitResult.ExitCode -eq 0 -or
                $syntheticGitResult.Output -notmatch 'tracked-entry-limit-exceeded'
            ) {
                Add-Failure 'Expected NUL-only Git metadata to hit the record limit.'
            }
            if ($syntheticGitStopwatch.Elapsed.TotalSeconds -gt 15) {
                Add-Failure 'Excessive Git metadata records exceeded the parser deadline.'
            }

            $syntheticEmptyRecordResult = Invoke-Scanner `
                -ScanPath $syntheticGitRoot `
                -EnvironmentOverrides @{
                    'PATH' = (
                        $syntheticGitBin +
                        [System.IO.Path]::PathSeparator +
                        [Environment]::GetEnvironmentVariable('PATH')
                    )
                    'SYNTHETIC_GIT_ROOT' = $syntheticGitRoot
                    'SYNTHETIC_GIT_MODE' = 'empty-record'
                }
            if (
                $syntheticEmptyRecordResult.ExitCode -eq 0 -or
                $syntheticEmptyRecordResult.Output -notmatch 'malformed-git-index-output'
            ) {
                Add-Failure 'Expected an empty Git index record to fail as malformed.'
            }
        }
    }

    # Higher-recall cloud / PEM prefixes, with one redaction regression each.
    $prefixCases = @(
        @{ Rule = 'openai-api-key-prefix';            Marker = ('s' + 'k-') + 'SyntheticOpenAI000000000000' }
        @{ Rule = 'aws-access-key-id';                Marker = ('A' + 'KIA') + 'EXAMPLE0000000000000' }
        @{ Rule = 'gcp-api-key-prefix';               Marker = ('AIza') + 'Synthetic0000000000000000000000000000' }
        @{ Rule = 'slack-user-token-prefix';          Marker = ('xo' + 'xp-') + 'synthetic-placeholder' }
        @{ Rule = 'slack-legacy-app-token-prefix';    Marker = ('xo' + 'xa-') + 'synthetic-placeholder' }
        @{ Rule = 'slack-app-level-token-prefix';     Marker = ('xa' + 'pp-') + 'synthetic-placeholder' }
        @{ Rule = 'stripe-live-secret-key';           Marker = ('s' + 'k') + '_live_SyntheticPlaceholder0000' }
        @{ Rule = 'pem-private-key-block';            Marker = '-----' + ('BEGIN ' + 'OPENSSH PRIVATE KEY') + '-----' }
    )

    foreach ($case in $prefixCases) {
        $prefixRoot = Join-Path $tempRoot ('prefix-' + $case.Rule)
        New-Item -ItemType Directory -Path $prefixRoot | Out-Null
        [System.IO.File]::WriteAllText(
            (Join-Path $prefixRoot 'leak.txt'),
            "synthetic marker: $($case.Marker)",
            $utf8NoBom
        )

        $prefixResult = Invoke-Scanner -ScanPath $prefixRoot
        if ($prefixResult.ExitCode -eq 0) {
            Add-Failure "Expected $($case.Rule) fixture to fail, but scanner exited 0."
        }
        if ($prefixResult.Output -notmatch [regex]::Escape($case.Rule)) {
            Add-Failure "Expected output to name $($case.Rule)."
        }
        if ($prefixResult.Output.Contains($case.Marker)) {
            Add-Failure "Expected $($case.Rule) finding to stay redacted."
        }
        if ($prefixResult.Output -notmatch '<redacted>') {
            Add-Failure "Expected $($case.Rule) finding to report '<redacted>'."
        }
    }

    # finding tableの詳細件数を固定し、同じmarkerを大量に含む入力でも
    # raw値を出さず、1件の集約findingへ畳み込む。
    $findingLimitRoot = Join-Path $tempRoot 'finding-limit'
    New-Item -ItemType Directory -Path $findingLimitRoot | Out-Null
    $findingLimitMarker = ('g' + 'hp_') + 'finding_limit_placeholder'
    $findingLimitContent = New-Object System.Text.StringBuilder
    for ($index = 0; $index -lt 1100; $index++) {
        [void]$findingLimitContent.Append($findingLimitMarker)
        [void]$findingLimitContent.Append('-')
        [void]$findingLimitContent.Append($index)
        [void]$findingLimitContent.Append("`n")
    }
    [System.IO.File]::WriteAllText(
        (Join-Path $findingLimitRoot 'many-findings.txt'),
        $findingLimitContent.ToString(),
        $utf8NoBom
    )
    $findingLimitResult = Invoke-Scanner -ScanPath $findingLimitRoot
    if (
        $findingLimitResult.ExitCode -eq 0 -or
        $findingLimitResult.Output -notmatch 'finding-limit-exceeded'
    ) {
        Add-Failure 'Expected excessive findings to fail with one aggregate notice.'
    }
    if ($findingLimitResult.Output.Contains($findingLimitMarker)) {
        Add-Failure 'Finding-limit output exposed a configured synthetic marker.'
    }
    if ($findingLimitResult.Output.Length -gt 1MB) {
        Add-Failure 'Finding-limit report exceeded its bounded output expectation.'
    }

    # configured markerもrule数と1件長を固定し、private inputを表示せず
    # fail closedにする。
    $localMarkerLimitRoot = Join-Path $tempRoot 'local-marker-limit'
    New-Item -ItemType Directory -Path $localMarkerLimitRoot | Out-Null
    $localMarkerLimitContent = New-Object System.Text.StringBuilder
    for ($index = 0; $index -lt 257; $index++) {
        [void]$localMarkerLimitContent.Append('synthetic-local-marker-')
        [void]$localMarkerLimitContent.Append($index)
        [void]$localMarkerLimitContent.Append("`n")
    }
    [System.IO.File]::WriteAllText(
        (Join-Path $localMarkerLimitRoot '.private-markers.local'),
        $localMarkerLimitContent.ToString(),
        $utf8NoBom
    )
    [System.IO.File]::WriteAllText(
        (Join-Path $localMarkerLimitRoot 'README.md'),
        '# Local marker limit fixture',
        $utf8NoBom
    )
    $localMarkerLimitResult = Invoke-Scanner -ScanPath $localMarkerLimitRoot
    if (
        $localMarkerLimitResult.ExitCode -eq 0 -or
        $localMarkerLimitResult.Output -notmatch 'local-marker-limit-exceeded'
    ) {
        Add-Failure 'Expected excessive local markers to fail closed.'
    }
    if ($localMarkerLimitResult.Output -match 'synthetic-local-marker-') {
        Add-Failure 'Local-marker limit output exposed private marker text.'
    }

    # 改行密度が高いtextも配列化せず、固定行数を超えた時点で
    # 匿名findingを返す。
    $lineLimitRoot = Join-Path $tempRoot 'line-limit'
    New-Item -ItemType Directory -Path $lineLimitRoot | Out-Null
    $lineLimitContent = New-Object System.Text.StringBuilder
    for ($index = 0; $index -lt 100001; $index++) {
        [void]$lineLimitContent.Append("x`n")
    }
    [System.IO.File]::WriteAllText(
        (Join-Path $lineLimitRoot 'many-lines.txt'),
        $lineLimitContent.ToString(),
        $utf8NoBom
    )
    $lineLimitResult = Invoke-Scanner -ScanPath $lineLimitRoot
    if (
        $lineLimitResult.ExitCode -eq 0 -or
        $lineLimitResult.Output -notmatch 'text-line-limit-exceeded'
    ) {
        Add-Failure 'Expected excessive text lines to fail closed.'
    }

    # fileごとの100,000行以下でもscan全体が200,000行を超えた場合は、
    # 空行を含めてaggregate budgetでfail closedにする。
    $aggregateLineLimitRoot = Join-Path $tempRoot 'aggregate-line-limit'
    New-Item -ItemType Directory -Path $aggregateLineLimitRoot | Out-Null
    $oneHundredThousandNewlines = "`n" * 100000
    [System.IO.File]::WriteAllText(
        (Join-Path $aggregateLineLimitRoot 'a.txt'),
        $oneHundredThousandNewlines,
        $utf8NoBom
    )
    [System.IO.File]::WriteAllText(
        (Join-Path $aggregateLineLimitRoot 'b.txt'),
        $oneHundredThousandNewlines,
        $utf8NoBom
    )
    [System.IO.File]::WriteAllText(
        (Join-Path $aggregateLineLimitRoot 'c.txt'),
        "`n",
        $utf8NoBom
    )
    $aggregateLineLimitResult = Invoke-Scanner -ScanPath $aggregateLineLimitRoot
    if (
        $aggregateLineLimitResult.ExitCode -eq 0 -or
        $aggregateLineLimitResult.Output -notmatch 'aggregate-text-line-limit-exceeded'
    ) {
        Add-Failure 'Expected aggregate text lines to hit the scan-wide limit.'
    }

    # allowlisted URLだけでも1行のmatch探索を4096件へ固定し、
    # 4097件目を匿名findingへ畳み込む。
    $regexMatchLimitRoot = Join-Path $tempRoot 'regex-match-limit'
    New-Item -ItemType Directory -Path $regexMatchLimitRoot | Out-Null
    $regexMatchLimitContent = New-Object System.Text.StringBuilder
    for ($index = 0; $index -lt 4097; $index++) {
        [void]$regexMatchLimitContent.Append(
            'https://github.com/h8nc4y/multi-agent-delegation '
        )
    }
    [System.IO.File]::WriteAllText(
        (Join-Path $regexMatchLimitRoot 'many-allowlisted-urls.txt'),
        $regexMatchLimitContent.ToString(),
        $utf8NoBom
    )
    $regexMatchLimitResult = Invoke-Scanner -ScanPath $regexMatchLimitRoot
    if (
        $regexMatchLimitResult.ExitCode -eq 0 -or
        $regexMatchLimitResult.Output -notmatch 'regex-match-limit-exceeded'
    ) {
        Add-Failure 'Expected per-line regex matches to hit the fixed limit.'
    }

    $winPathRealRoot = Join-Path $tempRoot 'winpath-real'
    New-Item -ItemType Directory -Path $winPathRealRoot | Out-Null
    $realWinPath = 'C' + ':\Users\realperson\Secrets\config'
    [System.IO.File]::WriteAllText(
        (Join-Path $winPathRealRoot 'doc.md'),
        "See $realWinPath for details.",
        $utf8NoBom
    )
    $winPathRealResult = Invoke-Scanner -ScanPath $winPathRealRoot
    if ($winPathRealResult.ExitCode -eq 0) {
        Add-Failure 'Expected real-looking Windows path fixture to fail, but scanner exited 0.'
    }
    if ($winPathRealResult.Output -notmatch 'windows-absolute-path') {
        Add-Failure 'Expected real Windows path output to name windows-absolute-path.'
    }

    $winPathDocRoot = Join-Path $tempRoot 'winpath-doc'
    New-Item -ItemType Directory -Path $winPathDocRoot | Out-Null
    [System.IO.File]::WriteAllText(
        (Join-Path $winPathDocRoot 'doc.md'),
        @'
Use a placeholder path such as C:\path\to\repo in examples.
You can also write C:\Users\<name>\project to describe a user directory.
'@,
        $utf8NoBom
    )
    $winPathDocResult = Invoke-Scanner -ScanPath $winPathDocRoot
    if ($winPathDocResult.ExitCode -ne 0) {
        Add-Failure 'Expected placeholder Windows path documentation to pass.'
    }

    $localMarkerRoot = Join-Path $tempRoot 'local-marker'
    New-Item -ItemType Directory -Path $localMarkerRoot | Out-Null
    [System.IO.File]::WriteAllText(
        (Join-Path $localMarkerRoot '.private-markers.local'),
        'local-only-marker',
        $utf8NoBom
    )
    [System.IO.File]::WriteAllText(
        (Join-Path $localMarkerRoot 'leak.txt'),
        'synthetic local-only-marker fixture',
        $utf8NoBom
    )

    $localMarkerResult = Invoke-Scanner -ScanPath $localMarkerRoot
    if ($localMarkerResult.ExitCode -eq 0) {
        Add-Failure 'Expected local marker fixture to fail, but scanner exited 0.'
    }
    if ($localMarkerResult.Output -notmatch 'local-private-marker-1') {
        Add-Failure 'Expected local marker output to name local-private-marker-1.'
    }

    # working-tree modeでもreparse directoryを1階層列挙で検出し、外部targetを
    # 開かずfail closedにする。junction削除は非再帰APIでlink自体に限定する。
    if ($isWindowsPlatform) {
        $workingLinkRoot = Join-Path $tempRoot 'working-tree-link'
        $workingJunction = Join-Path $workingLinkRoot 'external-junction'
        $workingOutsideMarker = ('github' + '_pat_') + 'working_outside_placeholder'
        $workingOutsideFile = Join-Path $outsideRoot 'working-outside-target.md'
        New-Item -ItemType Directory -Path $workingLinkRoot | Out-Null
        [System.IO.File]::WriteAllText(
            (Join-Path $workingLinkRoot 'README.md'),
            '# Working tree link fixture',
            $utf8NoBom
        )
        [System.IO.File]::WriteAllText(
            $workingOutsideFile,
            "outside marker: $workingOutsideMarker",
            $utf8NoBom
        )
        try {
            New-Item `
                -ItemType Junction `
                -Path $workingJunction `
                -Target $outsideRoot | Out-Null
            $workingLinkResult = Invoke-Scanner -ScanPath $workingLinkRoot
            if (
                $workingLinkResult.ExitCode -eq 0 -or
                $workingLinkResult.Output -notmatch 'unsafe-file-entry'
            ) {
                Add-Failure 'Expected working-tree junction to fail closed.'
            }
            if (
                $workingLinkResult.Output -match 'github-fine-grained-token-prefix' -or
                $workingLinkResult.Output.Contains($workingOutsideMarker)
            ) {
                Add-Failure 'Working-tree junction target outside the root was scanned.'
            }
        }
        finally {
            if (Test-Path -LiteralPath $workingJunction) {
                [System.IO.Directory]::Delete($workingJunction, $false)
            }
        }
        if (-not (Test-Path -LiteralPath $workingOutsideFile -PathType Leaf)) {
            Add-Failure 'Working-tree junction cleanup modified its external target.'
        }
    }

    # hostile ambient Git環境でtracked enumerationを別indexへ逸脱させる。
    # scannerが未隔離ならtracked markerを見失い、traceもfixture外へ生成する。
    $trackedRoot = Join-Path $tempRoot 'tracked-adversarial'
    New-Item -ItemType Directory -Path $trackedRoot | Out-Null
    $trackedMarker = ('g' + 'hp_') + 'tracked_synthetic_placeholder'
    $missingTrackedMarker = ('s' + 'k-') + 'SyntheticMissingTracked000000'
    [System.IO.File]::WriteAllText(
        (Join-Path $trackedRoot 'tracked-clean.md'),
        "synthetic missing-worktree marker: $missingTrackedMarker",
        $utf8NoBom
    )
    [System.IO.File]::WriteAllText(
        (Join-Path $trackedRoot 'tracked-marker.md'),
        "synthetic marker: $trackedMarker",
        $utf8NoBom
    )
    Invoke-TestGit -WorkingDirectory $trackedRoot -Arguments @('init') | Out-Null
    Invoke-TestGit -WorkingDirectory $trackedRoot -Arguments @(
        'add', '--', 'tracked-clean.md', 'tracked-marker.md'
    ) | Out-Null

    # local marker fileはuntracked専用であり、force-addされた場合は内容を
    # 通常scanから除外するだけでなく契約違反として拒否する。
    [System.IO.File]::WriteAllText(
        (Join-Path $trackedRoot '.private-markers.local'),
        '# Synthetic tracked local-marker contract violation',
        $utf8NoBom
    )
    Invoke-TestGit -WorkingDirectory $trackedRoot -Arguments @(
        'add', '-f', '--', '.private-markers.local'
    ) | Out-Null

    # refs/replaceでindex OIDをclean blobへ差し替えても、scannerは
    # GIT_NO_REPLACE_OBJECTSにより元のstaged marker blobを読む。
    $trackedMarkerOid = (
        Invoke-TestGit `
            -WorkingDirectory $trackedRoot `
            -Arguments @('rev-parse', ':tracked-marker.md')
    ).StandardOutput.Trim()
    $replacementSource = Join-Path $trackedRoot 'replacement-clean.txt'
    [System.IO.File]::WriteAllText(
        $replacementSource,
        '# Synthetic clean replacement',
        $utf8NoBom
    )
    $replacementOid = (
        Invoke-TestGit `
            -WorkingDirectory $trackedRoot `
            -Arguments @('hash-object', '-w', '--', $replacementSource)
    ).StandardOutput.Trim()
    Invoke-TestGit -WorkingDirectory $trackedRoot -Arguments @(
        'replace', $trackedMarkerOid, $replacementOid
    ) | Out-Null
    Remove-Item -LiteralPath $replacementSource -Force

    # index blobを正本として読むことを証明する。markerはstage後にworking
    # treeから消し、別tracked fileは削除してもindex内容をscanできるようにする。
    [System.IO.File]::WriteAllText(
        (Join-Path $trackedRoot 'tracked-marker.md'),
        '# Worktree is intentionally clean after staging',
        $utf8NoBom
    )
    Remove-Item -LiteralPath (Join-Path $trackedRoot 'tracked-clean.md') -Force

    # 外部marker fileを指すtracked symlinkをindex mode 120000として直接作る。
    # filesystem link権限へ依存せず、scannerがtargetを開かずfail closedにする。
    $outsideSymlinkMarker = ('github' + '_pat_') + 'outside_synthetic_placeholder'
    $outsideSymlinkTarget = Join-Path $outsideRoot 'external-link-target.md'
    [System.IO.File]::WriteAllText(
        $outsideSymlinkTarget,
        "outside synthetic marker: $outsideSymlinkMarker",
        $utf8NoBom
    )
    $linkBlobSource = Join-Path $trackedRoot 'link-target-source.txt'
    $relativeOutsideTarget = '..\..\' +
        [System.IO.Path]::GetFileName($outsideRoot) +
        '\external-link-target.md'
    [System.IO.File]::WriteAllText(
        $linkBlobSource,
        $relativeOutsideTarget,
        $utf8NoBom
    )
    $linkBlobResult = Invoke-TestGit -WorkingDirectory $trackedRoot -Arguments @(
        'hash-object', '-w', '--', $linkBlobSource
    )
    $linkBlobId = $linkBlobResult.StandardOutput.Trim()
    if ($linkBlobId -notmatch '^[0-9a-fA-F]{40,64}$') {
        throw 'Synthetic symlink blob creation returned an invalid object ID.'
    }
    Invoke-TestGit -WorkingDirectory $trackedRoot -Arguments @(
        'update-index',
        '--add',
        '--cacheinfo',
        "120000,$linkBlobId,external-marker-link.md"
    ) | Out-Null
    Remove-Item -LiteralPath $linkBlobSource -Force

    # promisor repoにだけ存在するblobをindexへ登録する。scannerがlazy
    # fetchするとsynthetic remote helper artifactが生成されるため、NO_LAZY
    # とprotocol境界を外部通信なしでbehavioral proofできる。
    $promisorSource = Join-Path $outsideRoot 'promisor-source'
    New-Item -ItemType Directory -Path $promisorSource | Out-Null
    Invoke-TestGit -WorkingDirectory $promisorSource -Arguments @('init') | Out-Null
    $promisorBlobSource = Join-Path $promisorSource 'promisor-source.txt'
    [System.IO.File]::WriteAllText(
        $promisorBlobSource,
        '# Synthetic promisor-only blob',
        $utf8NoBom
    )
    $promisorBlobId = (
        Invoke-TestGit `
            -WorkingDirectory $promisorSource `
            -Arguments @('hash-object', '-w', '--', $promisorBlobSource)
    ).StandardOutput.Trim()
    Invoke-TestGit -WorkingDirectory $trackedRoot -Arguments @(
        'update-index',
        '--info-only',
        '--add',
        '--cacheinfo',
        "100644,$promisorBlobId,promisor-missing.md"
    ) | Out-Null
    foreach ($configPair in @(
        @('core.repositoryformatversion', '1'),
        @('extensions.partialClone', 'origin'),
        @('remote.origin.url', 'synthetic::fixture'),
        @('remote.origin.promisor', 'true'),
        @('remote.origin.partialclonefilter', 'blob:none'),
        @('protocol.synthetic.allow', 'always')
    )) {
        Invoke-TestGit -WorkingDirectory $trackedRoot -Arguments @(
            'config', '--local', $configPair[0], $configPair[1]
        ) | Out-Null
    }
    $promisorLocalObject = Join-Path (
        Join-Path (Join-Path $trackedRoot '.git') 'objects'
    ) (
        $promisorBlobId.Substring(0, 2) +
        [System.IO.Path]::DirectorySeparatorChar +
        $promisorBlobId.Substring(2)
    )
    if (Test-Path -LiteralPath $promisorLocalObject) {
        throw 'Synthetic promisor blob unexpectedly exists in the scan repository.'
    }

    $promisorHelperArtifact = Join-Path $outsideRoot 'promisor-helper-artifact'
    $promisorHelperDirectory = Join-Path $outsideRoot 'promisor-helper'
    if ($isWindowsPlatform) {
        New-Item -ItemType Directory -Path $promisorHelperDirectory | Out-Null
        $promisorHelper = Join-Path $promisorHelperDirectory 'git-remote-synthetic.cmd'
        [System.IO.File]::WriteAllLines(
            $promisorHelper,
            [string[]]@(
                '@echo off',
                "echo invoked>`"$promisorHelperArtifact`"",
                'exit /b 1'
            ),
            [System.Text.Encoding]::ASCII
        )
    }

    $ambientRepository = Join-Path $outsideRoot 'ambient-repository'
    New-Item -ItemType Directory -Path $ambientRepository | Out-Null
    Invoke-TestGit -WorkingDirectory $ambientRepository -Arguments @('init') | Out-Null
    Invoke-TestGit -WorkingDirectory $ambientRepository -Arguments @('read-tree', '--empty') | Out-Null

    $ambientGitDirectory = Join-Path $ambientRepository '.git'
    $ambientIndexFile = Join-Path $ambientGitDirectory 'index'
    $ambientObjectDirectory = Join-Path $ambientGitDirectory 'objects'
    $ambientAlternateObjects = Join-Path $outsideRoot 'alternate-objects'
    $ambientHooks = Join-Path $outsideRoot 'hooks'
    $ambientTemplate = Join-Path $outsideRoot 'template'
    $ambientAttributes = Join-Path $outsideRoot 'attributes'
    $ambientExcludes = Join-Path $outsideRoot 'excludes'
    $hostileConfig = Join-Path $outsideRoot 'hostile.gitconfig'
    New-Item -ItemType Directory -Path $ambientAlternateObjects | Out-Null
    New-Item -ItemType Directory -Path $ambientHooks | Out-Null
    New-Item -ItemType Directory -Path $ambientTemplate | Out-Null
    [System.IO.File]::WriteAllText($ambientAttributes, '*.md filter=ambient', $utf8NoBom)
    [System.IO.File]::WriteAllText($ambientExcludes, '*.md', $utf8NoBom)
    [System.IO.File]::WriteAllText(
        $hostileConfig,
        @"
[core]
    hooksPath = $($ambientHooks.Replace('\', '/'))
    attributesFile = $($ambientAttributes.Replace('\', '/'))
    excludesFile = $($ambientExcludes.Replace('\', '/'))
[init]
    templateDir = $($ambientTemplate.Replace('\', '/'))
[filter "ambient"]
    clean = false
    required = true
"@,
        $utf8NoBom
    )

    $traceArtifact = Join-Path $outsideRoot 'git-trace.log'
    $trace2Artifact = Join-Path $outsideRoot 'git-trace2.json'
    $hookArtifact = Join-Path $outsideRoot 'hook-artifact'
    $filterArtifact = Join-Path $outsideRoot 'filter-artifact'
    $promptArtifact = Join-Path $outsideRoot 'prompt-artifact'
    $futureArtifact = Join-Path $outsideRoot 'future-artifact'
    $configPairs = @(
        @('core.hooksPath', $ambientHooks),
        @('core.attributesFile', $ambientAttributes),
        @('core.excludesFile', $ambientExcludes),
        @('init.templateDir', $ambientTemplate),
        @('filter.ambient.clean', "echo triggered > `"$filterArtifact`""),
        @('filter.ambient.required', 'true'),
        @('core.fsmonitor', "echo triggered > `"$hookArtifact`"")
    )

    $hostileEnvironment = [ordered]@{
        'GIT_DIR' = $ambientGitDirectory
        'GIT_COMMON_DIR' = $ambientGitDirectory
        'GIT_WORK_TREE' = $trackedRoot
        'GIT_INDEX_FILE' = $ambientIndexFile
        'GIT_OBJECT_DIRECTORY' = $ambientObjectDirectory
        'GIT_ALTERNATE_OBJECT_DIRECTORIES' = $ambientAlternateObjects
        'GIT_CONFIG' = $hostileConfig
        'GIT_CONFIG_GLOBAL' = $hostileConfig
        'GIT_CONFIG_SYSTEM' = $hostileConfig
        'GIT_CONFIG_NOSYSTEM' = ''
        'GIT_ATTR_NOSYSTEM' = ''
        'GIT_TERMINAL_PROMPT' = '1'
        'GIT_ASKPASS' = $promptArtifact
        'GIT_EXEC_PATH' = $outsideRoot
        'GIT_TRACE' = $traceArtifact
        'GIT_TRACE2_EVENT' = $trace2Artifact
        'GIT_FUTURE_EXTERNAL_ARTIFACT' = $futureArtifact
        'GIT_CONFIG_COUNT' = "$($configPairs.Count)"
    }
    if ($isWindowsPlatform) {
        $hostileEnvironment['PATH'] = (
            $promisorHelperDirectory +
            [System.IO.Path]::PathSeparator +
            [Environment]::GetEnvironmentVariable('PATH')
        )
    }
    for ($index = 0; $index -lt $configPairs.Count; $index++) {
        $hostileEnvironment["GIT_CONFIG_KEY_$index"] = $configPairs[$index][0]
        $hostileEnvironment["GIT_CONFIG_VALUE_$index"] = $configPairs[$index][1]
    }

    $environmentBefore = @(Get-GitEnvironmentSnapshot)
    $adversarialResult = Invoke-Scanner `
        -ScanPath $trackedRoot `
        -EnvironmentOverrides $hostileEnvironment
    $environmentAfter = @(Get-GitEnvironmentSnapshot)

    if (-not (Test-SnapshotEqual -Before $environmentBefore -After $environmentAfter)) {
        Add-Failure 'Parent GIT environment changed after adversarial scanner child.'
    }
    if ($adversarialResult.ExitCode -eq 0) {
        Add-Failure 'Expected tracked adversarial marker to fail without enumeration drift.'
    }
    if ($adversarialResult.Output -notmatch 'github-classic-token-prefix') {
        Add-Failure 'Expected adversarial output to name github-classic-token-prefix.'
    }
    if ($adversarialResult.Output -notmatch 'openai-api-key-prefix') {
        Add-Failure 'Expected missing working-tree file to be scanned from its staged blob.'
    }
    if ($adversarialResult.Output -notmatch 'unsafe-git-index-entry') {
        Add-Failure 'Expected tracked external symlink mode to fail closed.'
    }
    if ($adversarialResult.Output -notmatch 'git-blob-read-failed') {
        Add-Failure 'Expected missing promisor blob to fail closed without lazy fetch.'
    }
    if ($adversarialResult.Output -notmatch 'tracked-private-marker-file') {
        Add-Failure 'Expected a tracked local marker file to violate the untracked-only contract.'
    }
    if ($adversarialResult.Output -notmatch 'scan target: git-tracked') {
        Add-Failure 'Expected adversarial fixture to retain git-tracked scan mode.'
    }
    foreach ($redactedMarker in @(
        $trackedMarker,
        $missingTrackedMarker,
        $outsideSymlinkMarker
    )) {
        if ($adversarialResult.Output.Contains($redactedMarker)) {
            Add-Failure 'Expected adversarial marker values to stay redacted.'
        }
    }
    if ($adversarialResult.Output -match 'github-fine-grained-token-prefix') {
        Add-Failure 'Tracked symlink target outside the repository was unexpectedly scanned.'
    }
    if (
        (Test-Path -LiteralPath $promisorHelperArtifact) -or
        (Test-Path -LiteralPath $promisorLocalObject)
    ) {
        Add-Failure 'Missing promisor blob triggered a remote helper or local object write.'
    }

    # repo subdirectoryは親repoのworking-tree fallbackへ落とさず、root mismatch
    # としてfail closedにする。
    $nestedScanRoot = Join-Path $trackedRoot 'nested-scan-root'
    New-Item -ItemType Directory -Path $nestedScanRoot | Out-Null
    [System.IO.File]::WriteAllText(
        (Join-Path $nestedScanRoot 'nested.md'),
        '# Nested root must not downgrade',
        $utf8NoBom
    )
    $rootMismatchResult = Invoke-Scanner -ScanPath $nestedScanRoot
    if (
        $rootMismatchResult.ExitCode -eq 0 -or
        $rootMismatchResult.Output -notmatch 'repository-root-mismatch' -or
        $rootMismatchResult.Output -match 'scan target: working-tree'
    ) {
        Add-Failure 'Expected repository root mismatch to fail without working-tree fallback.'
    }

    # `.git` control entryがあるのにprobeできない場合も非Git扱いにしない。
    $brokenGitRoot = Join-Path $tempRoot 'broken-git-probe'
    New-Item -ItemType Directory -Path $brokenGitRoot | Out-Null
    [System.IO.File]::WriteAllText(
        (Join-Path $brokenGitRoot '.git'),
        'synthetic invalid gitdir control entry',
        $utf8NoBom
    )
    [System.IO.File]::WriteAllText(
        (Join-Path $brokenGitRoot 'README.md'),
        '# Probe failure fixture',
        $utf8NoBom
    )
    $probeFailureResult = Invoke-Scanner -ScanPath $brokenGitRoot
    if (
        $probeFailureResult.ExitCode -eq 0 -or
        $probeFailureResult.Output -notmatch 'git-probe-failed' -or
        $probeFailureResult.Output -match 'scan target: working-tree'
    ) {
        Add-Failure 'Expected Git probe failure to fail without working-tree fallback.'
    }

    # dangling `.git` junctionはTest-Path falseでもentry自体を非追従列挙し、
    # working-tree modeへ落とさずunsafe controlとして拒否する。
    if ($isWindowsPlatform) {
        $danglingGitRoot = Join-Path $tempRoot 'dangling-git-control'
        $danglingGitEntry = Join-Path $danglingGitRoot '.git'
        $danglingGitTarget = Join-Path $outsideRoot 'deleted-git-control-target'
        New-Item -ItemType Directory -Path $danglingGitRoot | Out-Null
        New-Item -ItemType Directory -Path $danglingGitTarget | Out-Null
        try {
            New-Item `
                -ItemType Junction `
                -Path $danglingGitEntry `
                -Target $danglingGitTarget | Out-Null
            [System.IO.Directory]::Delete($danglingGitTarget, $false)
            $danglingGitResult = Invoke-Scanner -ScanPath $danglingGitRoot
            if (
                $danglingGitResult.ExitCode -eq 0 -or
                $danglingGitResult.Output -notmatch 'unsafe-git-control-entry' -or
                $danglingGitResult.Output -match 'scan target: working-tree'
            ) {
                Add-Failure 'Expected dangling Git control entry to fail without fallback.'
            }
        }
        finally {
            if (Test-Path -LiteralPath $danglingGitEntry) {
                [System.IO.Directory]::Delete($danglingGitEntry, $false)
            } else {
                # Test-Path can be false for the dangling link; enumerate its parent.
                $danglingEntryItem = @(
                    Get-ChildItem -LiteralPath $danglingGitRoot -Force |
                        Where-Object { $_.Name -ceq '.git' }
                )
                if ($danglingEntryItem.Count -eq 1) {
                    [System.IO.Directory]::Delete(
                        $danglingEntryItem[0].FullName,
                        $false
                    )
                }
            }
        }
    }

    foreach ($artifact in @(
        $traceArtifact,
        $trace2Artifact,
        $hookArtifact,
        $filterArtifact,
        $promptArtifact,
        $futureArtifact,
        $promisorHelperArtifact
    )) {
        if (Test-Path -LiteralPath $artifact) {
            Add-Failure 'Hostile Git environment created an artifact outside the scan fixture.'
        }
    }
}
catch {
    $primaryFailure = $_
    throw
}
finally {
    foreach ($fixtureRoot in @($tempRoot, $outsideRoot)) {
        try {
            Remove-TestRoot -RootPath $fixtureRoot -TemporaryParent $tempParent
        }
        catch {
            if ($null -eq $primaryFailure) {
                throw
            }
            Write-Warning 'Fixture cleanup also failed after the primary self-test failure.'
        }
    }
}

if ($failures.Count -gt 0) {
    Write-Host 'Private marker scan self-test failed:'
    foreach ($failure in $failures) {
        Write-Host "- $failure"
    }
    exit 1
}

Write-Host "Private marker scan self-test passed (host: $powerShellLeaf)."
exit 0
