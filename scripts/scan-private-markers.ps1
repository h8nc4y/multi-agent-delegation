[CmdletBinding()]
param(
    [string]$Path = ''
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
$ownRepoUrlPattern = '^https://github\.com/h8nc4y/multi-agent-delegation(?:\.git)?$'
$isWindowsPlatform = [Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
$pathComparison = if ($isWindowsPlatform) {
    [System.StringComparison]::OrdinalIgnoreCase
} else {
    [System.StringComparison]::Ordinal
}
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$rules = New-Object System.Collections.Generic.List[object]

function Add-ScanRule {
    param(
        [string]$Name,
        [string]$Pattern,
        [ValidateSet('literal', 'regex')]
        [string]$Kind,
        # Optional: suppress regex matches whose value is a known-safe placeholder.
        # This keeps documentation examples from becoming noisy findings.
        [string]$Allowlist = ''
    )

    if ([string]::IsNullOrWhiteSpace($Pattern)) {
        return
    }

    $rules.Add([pscustomobject]@{
        Name = $Name
        Pattern = $Pattern
        Kind = $Kind
        Allowlist = $Allowlist
    }) | Out-Null
}

Add-ScanRule -Name 'openai-api-key-prefix' -Pattern '(?<![A-Za-z0-9])sk-[A-Za-z0-9_-]{16,}' -Kind 'regex'
Add-ScanRule -Name 'github-classic-token-prefix' -Pattern ('g' + 'hp_') -Kind 'literal'
Add-ScanRule -Name 'github-fine-grained-token-prefix' -Pattern ('github' + '_pat_') -Kind 'literal'
Add-ScanRule -Name 'slack-bot-token-prefix' -Pattern ('xo' + 'xb-') -Kind 'literal'
Add-ScanRule -Name 'bearer-token-header' -Pattern ('Bearer' + ' ') -Kind 'literal'
Add-ScanRule -Name 'private-key-block' -Pattern ('BEGIN ' + 'PRIVATE KEY') -Kind 'literal'
Add-ScanRule -Name 'email-address' -Pattern '\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b' -Kind 'regex'
# windows-absolute-path detects private-looking absolute Windows paths while allowing
# documented placeholders. The regex stops before bracketed placeholder segments and
# can also greedily include trailing prose, so the allowlist suppresses either:
#   (a) values ending at a path separator with only placeholder or parent words, or
#   (b) full placeholder-only paths, with optional trailing prose.
# Real-looking paths with non-placeholder child segments remain findings.
# Keep literal absolute paths out of comments so this script does not flag itself.
$winPathPlaceholderWord = '(?:path|to|repo|you|your|example|placeholder|dir|folder|project|projects)'
$winPathParentWord = '(?:users|user|home|documents|appdata|local|roaming)'
$windowsPathPlaceholderAllowlist = '(?ix)^[A-Za-z]:\\(?:' +
    # (a) Placeholder or parent words only, ending at a separator.
    "(?:(?:$winPathPlaceholderWord|$winPathParentWord)\\)+" +
    '|' +
    # (b) Full placeholder-only paths, optionally followed by prose.
    "(?:$winPathPlaceholderWord\\?)+(?:\s.*)?" +
    ')$'
Add-ScanRule -Name 'windows-absolute-path' -Pattern '\b[A-Za-z]:\\(?:[^\\/:*?"<>|\r\n]+\\?){2,}' -Kind 'regex' -Allowlist $windowsPathPlaceholderAllowlist

# Additional cloud / key-block prefixes for higher secret recall.
# Prefixes are split so this scanner does not match its own rule definitions.
Add-ScanRule -Name 'aws-access-key-id' -Pattern ('A' + 'KIA') -Kind 'literal'
Add-ScanRule -Name 'gcp-api-key-prefix' -Pattern ('AIza' + '[0-9A-Za-z_\-]{35}') -Kind 'regex'
Add-ScanRule -Name 'slack-user-token-prefix' -Pattern ('xo' + 'xp-') -Kind 'literal'
Add-ScanRule -Name 'slack-legacy-app-token-prefix' -Pattern ('xo' + 'xa-') -Kind 'literal'
Add-ScanRule -Name 'slack-app-level-token-prefix' -Pattern ('xa' + 'pp-') -Kind 'literal'
Add-ScanRule -Name 'stripe-live-secret-key' -Pattern ('(s' + 'k|rk)_live_[0-9A-Za-z]{16,}') -Kind 'regex'
Add-ScanRule -Name 'pem-private-key-block' -Pattern ('BEGIN ' + '(RSA|EC|OPENSSH|ENCRYPTED) PRIVATE KEY') -Kind 'regex'

$githubUrlPattern = 'https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:\.git)?'
$findings = New-Object System.Collections.Generic.List[object]
$maxTextFileBytes = 4MB
$maxAggregateTextBytes = 64MB
$maxGitMetadataBytes = 8MB
$maxTrackedEntries = 4096
$maxWorkingTreeEntries = 4096
$maxDetailedFindings = 1024
$maxTextLinesPerFile = 100000
$maxAggregateTextLines = 200000
$maxRegexMatchesPerLine = 4096
$maxLocalMarkers = 256
$maxLocalMarkerCharacters = 1024
$maxLocalMarkerSourceLines = 1024
$findingLimitExceeded = $false
$localMarkerLimitReported = $false
$aggregateTextLineLimitExceeded = $false
$aggregateTextLinesScanned = 0

# Limit scanning to text files to avoid binary noise and expensive regex work.
# Extensionless text files such as LICENSE are still allowed.
$textExtensions = @(
    '.md', '.markdown', '.txt', '.ps1', '.psm1', '.psd1', '.yml', '.yaml',
    '.json', '.jsonc', '.toml', '.ini', '.cfg', '.conf', '.xml', '.csv',
    '.sh', '.bash', '.bat', '.cmd', '.py', '.js', '.ts', '.css', '.html',
    '.htm', '.editorconfig', '.gitattributes', '.gitignore'
)
$textExtensionSet = [System.Collections.Generic.HashSet[string]]::new(
    [string[]]$textExtensions, [System.StringComparer]::OrdinalIgnoreCase)

function Test-IsTextFile {
    param([string]$FullPath)

    $extension = [System.IO.Path]::GetExtension($FullPath)
    if ([string]::IsNullOrEmpty($extension)) {
        # Treat extensionless files as text.
        return $true
    }
    return $textExtensionSet.Contains($extension)
}

function ConvertTo-SafeDisplayPath {
    param([AllowEmptyString()][string]$Value)

    $display = [regex]::Replace($Value, '[\x00-\x1F\x7F]', '?')
    $display = $display.Replace([string][char]92, '/')
    if ($display.Length -gt 512) {
        return $display.Substring(0, 509) + '...'
    }
    return $display
}

function Add-RedactedFinding {
    param(
        [string]$RelativePath,
        [int]$Line,
        [string]$Rule
    )

    # 攻撃的な入力からfinding objectと最終tableが無制限に増えないよう、
    # 詳細件数を固定し、超過は最後に匿名の集約finding 1件へ畳み込む。
    if ($findings.Count -ge $maxDetailedFindings) {
        $script:findingLimitExceeded = $true
        return
    }
    $findings.Add([pscustomobject]@{
        File = $RelativePath
        Line = $Line
        Rule = $Rule
        Match = '<redacted>'
    }) | Out-Null
}

function Add-SafetyFinding {
    param(
        [string]$RelativePath,
        [string]$Rule
    )

    # 安全性判定の失敗理由だけを公開し、root外の実pathや内容は出力しない。
    $safePath = if ([string]::IsNullOrWhiteSpace($RelativePath)) {
        '<scan-root>'
    } else {
        ConvertTo-SafeDisplayPath -Value $RelativePath
    }
    Add-RedactedFinding -RelativePath $safePath -Line 0 -Rule $Rule
}

function Test-IsPathInsideRoot {
    param([string]$FullPath)

    try {
        $candidate = [System.IO.Path]::GetFullPath($FullPath)
    }
    catch {
        return $false
    }

    $separators = [char[]]@(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
    $normalizedRoot = $root.TrimEnd($separators)
    if ([string]::IsNullOrEmpty($normalizedRoot)) {
        $normalizedRoot = [System.IO.Path]::GetPathRoot($root).TrimEnd(
            [System.IO.Path]::AltDirectorySeparatorChar
        )
    }
    $rootPrefix = $normalizedRoot + [System.IO.Path]::DirectorySeparatorChar
    return (
        $candidate.Equals($normalizedRoot, $pathComparison) -or
        $candidate.StartsWith($rootPrefix, $pathComparison)
    )
}

function Get-SafeRelativePath {
    param([string]$FullPath)

    if (-not (Test-IsPathInsideRoot -FullPath $FullPath)) {
        return '<outside-scan-root>'
    }
    $candidate = [System.IO.Path]::GetFullPath($FullPath)
    $relative = $candidate.Substring($root.TrimEnd(
        [char]92,
        [char]47
    ).Length).TrimStart(
        [char]92,
        [char]47
    )
    return $relative.Replace([string][char]92, '/')
}

function Test-IsLinkOrReparse {
    param([System.IO.FileSystemInfo]$Item)

    if ($null -eq $Item) {
        return $true
    }
    $isReparse = (
        ($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
    )
    $linkType = $Item.PSObject.Properties['LinkType']
    $linkTarget = $Item.PSObject.Properties['LinkTarget']
    return (
        $isReparse -or
        ($null -ne $linkType -and -not [string]::IsNullOrEmpty([string]$linkType.Value)) -or
        ($null -ne $linkTarget -and -not [string]::IsNullOrEmpty([string]$linkTarget.Value))
    )
}

function Test-IsSafeRegularFile {
    param(
        [System.IO.FileSystemInfo]$Item,
        [string]$RelativePath
    )

    if (
        $null -eq $Item -or
        $Item.PSIsContainer -or
        -not (Test-IsPathInsideRoot -FullPath $Item.FullName)
    ) {
        Add-SafetyFinding -RelativePath $RelativePath -Rule 'unsafe-file-entry'
        return $false
    }

    # file自身だけでなく親directoryも辿り、junction/symlink配下から
    # scan root外へ抜ける経路を内容読取り前に拒否する。
    $current = $Item
    while ($null -ne $current) {
        if (Test-IsLinkOrReparse -Item $current) {
            Add-SafetyFinding -RelativePath $RelativePath -Rule 'unsafe-file-entry'
            return $false
        }

        if ($current.FullName.Equals($root, $pathComparison)) {
            break
        }
        $parentPath = [System.IO.Path]::GetDirectoryName($current.FullName)
        if (
            [string]::IsNullOrEmpty($parentPath) -or
            -not (Test-IsPathInsideRoot -FullPath $parentPath)
        ) {
            Add-SafetyFinding -RelativePath $RelativePath -Rule 'unsafe-file-entry'
            return $false
        }
        try {
            $current = Get-Item -LiteralPath $parentPath -Force
        }
        catch {
            Add-SafetyFinding -RelativePath $RelativePath -Rule 'unsafe-file-entry'
            return $false
        }
    }

    if ($Item.Length -gt $maxTextFileBytes) {
        Add-SafetyFinding -RelativePath $RelativePath -Rule 'oversized-text-file'
        return $false
    }
    return $true
}

function Get-SafeWorkingTreeFiles {
    $safeFiles = New-Object System.Collections.Generic.List[object]
    $directoryQueue = [System.Collections.Generic.Queue[System.IO.DirectoryInfo]]::new()
    $rootItem = Get-Item -LiteralPath $root -Force
    if (-not $rootItem.PSIsContainer -or (Test-IsLinkOrReparse -Item $rootItem)) {
        Add-SafetyFinding -RelativePath '<scan-root>' -Rule 'unsafe-file-entry'
        return $safeFiles.ToArray()
    }
    $directoryQueue.Enqueue($rootItem)
    $entryCount = 0

    # `Get-ChildItem -Recurse`にlink追従の差を委ねず、1階層ずつ列挙する。
    # reparse directoryは検出時にfailureへ入れ、queueへ追加しない。
    while ($directoryQueue.Count -gt 0) {
        $directory = $directoryQueue.Dequeue()
        try {
            # provider pipelineをremaining+1件で停止し、単一directoryの
            # 全entryを上限確認前にarray materializationしない。
            $remainingEntryBudget = $maxWorkingTreeEntries - $entryCount + 1
            $children = @(
                Get-ChildItem -LiteralPath $directory.FullName -Force |
                    Select-Object -First $remainingEntryBudget
            )
        }
        catch {
            Add-SafetyFinding `
                -RelativePath (Get-SafeRelativePath -FullPath $directory.FullName) `
                -Rule 'directory-enumeration-failed'
            continue
        }

        foreach ($child in $children) {
            $entryCount++
            if ($entryCount -gt $maxWorkingTreeEntries) {
                Add-SafetyFinding `
                    -RelativePath '<scan-root>' `
                    -Rule 'working-tree-entry-limit-exceeded'
                return $safeFiles.ToArray()
            }
            $relative = Get-SafeRelativePath -FullPath $child.FullName
            if (Test-IsLinkOrReparse -Item $child) {
                Add-SafetyFinding -RelativePath $relative -Rule 'unsafe-file-entry'
                continue
            }
            if ($relative -match '(?:^|/)(?:\.git|node_modules|\.cache)(?:/|$)') {
                continue
            }
            if (-not (Test-IsPathInsideRoot -FullPath $child.FullName)) {
                Add-SafetyFinding -RelativePath '<outside-scan-root>' -Rule 'unsafe-file-entry'
                continue
            }
            if ($child.PSIsContainer) {
                $directoryQueue.Enqueue($child)
                continue
            }
            $safeFiles.Add($child) | Out-Null
        }
    }
    return $safeFiles.ToArray()
}

function Find-NearestGitControlEntry {
    $current = Get-Item -LiteralPath $root -Force
    while ($null -ne $current) {
        # Test-Pathはdangling linkをfalseにできるため、親directoryを
        # 非再帰列挙して`.git` entry自体を検出する。
        $matches = @(
            Get-ChildItem -LiteralPath $current.FullName -Force |
                Where-Object { $_.Name.Equals('.git', $pathComparison) }
        )
        if ($matches.Count -gt 1) {
            throw 'Multiple Git control entries were found in one directory.'
        }
        if ($matches.Count -eq 1) {
            return $matches[0]
        }
        $current = $current.Parent
    }
    return $null
}

function Add-LocalMarker {
    param([string]$Marker)

    $trimmed = $Marker.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith('#')) {
        return
    }

    # local marker sourceも非公開入力であるため、1件の長さとrule件数を
    # 固定する。超過値は出力せず、匿名の安全性findingだけを残す。
    if (
        $trimmed.Length -gt $maxLocalMarkerCharacters -or
        $script:localMarkerIndex -ge $maxLocalMarkers
    ) {
        if (-not $script:localMarkerLimitReported) {
            Add-SafetyFinding `
                -RelativePath '<private-markers>' `
                -Rule 'local-marker-limit-exceeded'
            $script:localMarkerLimitReported = $true
        }
        return
    }

    $script:localMarkerIndex++
    Add-ScanRule -Name "local-private-marker-$script:localMarkerIndex" -Pattern $trimmed -Kind 'literal'
}

function Add-LocalMarkersFromText {
    param([AllowEmptyString()][string]$Content)

    # `-split`は改行だけの入力から巨大配列を作れるため、StringReaderで
    # 1行ずつ処理し、blank/comment行を含むsource行数にも上限を設ける。
    $reader = New-Object System.IO.StringReader($Content)
    $sourceLineCount = 0
    try {
        while (($line = $reader.ReadLine()) -ne $null) {
            $sourceLineCount++
            if ($sourceLineCount -gt $maxLocalMarkerSourceLines) {
                if (-not $script:localMarkerLimitReported) {
                    Add-SafetyFinding `
                        -RelativePath '<private-markers>' `
                        -Rule 'local-marker-limit-exceeded'
                    $script:localMarkerLimitReported = $true
                }
                break
            }
            Add-LocalMarker -Marker $line
        }
    }
    finally {
        $reader.Dispose()
    }
}

$localMarkerIndex = 0
$environmentMarkers = [Environment]::GetEnvironmentVariable('MULTI_AGENT_DELEGATION_PRIVATE_MARKERS')
if (-not [string]::IsNullOrWhiteSpace($environmentMarkers)) {
    Add-LocalMarkersFromText -Content $environmentMarkers
}

function ConvertTo-WindowsProcessArgument {
    param([AllowEmptyString()][string]$Value)

    if ([string]::IsNullOrEmpty($Value)) {
        return '""'
    }
    if ($Value -notmatch '[\s"]') {
        return $Value
    }

    # PS5.1にはProcessStartInfo.ArgumentListがないため、Windowsの
    # quoting規則で空白・quote・末尾backslashを失わないようにする。
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

function Stop-ProcessTree {
    param(
        [System.Diagnostics.Process]$Process,
        [int]$KillWaitMilliseconds = 5000
    )

    if ($Process.HasExited) {
        return
    }

    # Git childがtimeoutした場合はdescendantを含めて停止し、その後も
    # bounded re-waitしてscanner自体の無期限停止を防ぐ。
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
            throw 'Timed-out Git process did not exit after tree termination.'
        }
    }
}

function Read-BoundedProcessStreams {
    param(
        [System.Diagnostics.Process]$Process,
        [int]$TimeoutMilliseconds,
        [int]$KillWaitMilliseconds,
        [int]$MaxStandardOutputBytes,
        [int]$MaxStandardErrorBytes,
        [string]$ProcessLabel
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
            if (
                $stdoutDone -and
                $stderrDone -and
                $Process.HasExited
            ) {
                break
            }

            $remaining = $TimeoutMilliseconds - [int]$stopwatch.ElapsedMilliseconds
            if ($remaining -le 0) {
                $failure = "$ProcessLabel process timed out after $TimeoutMilliseconds ms."
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
                    $failure = "$ProcessLabel stdout read failed."
                    break
                }
                if ($count -eq 0) {
                    $stdoutDone = $true
                } elseif (($stdoutBytes.Length + $count) -gt $MaxStandardOutputBytes) {
                    $failure = "$ProcessLabel stdout exceeded its bounded byte limit."
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
                    $failure = "$ProcessLabel stderr read failed."
                    break
                }
                if ($count -eq 0) {
                    $stderrDone = $true
                } elseif (($stderrBytes.Length + $count) -gt $MaxStandardErrorBytes) {
                    $failure = "$ProcessLabel stderr exceeded its bounded byte limit."
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
            # timeout/limit/errorでは生存treeを停止し、reader側pipeも閉じる。
            # close後のpending readもbounded re-waitしてfinallyへ進む。
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
                    # stream closeによるfault/cancelは固定failureへ畳み込む。
                }
            }
            throw $failure
        }

        $standardOutput = $utf8NoBom.GetString($stdoutBytes.ToArray())
        $standardError = $utf8NoBom.GetString($stderrBytes.ToArray())
        if (
            $standardOutput.Length -gt 0 -and
            $standardOutput[0] -eq [char]0xFEFF
        ) {
            $standardOutput = $standardOutput.Substring(1)
        }
        if (
            $standardError.Length -gt 0 -and
            $standardError[0] -eq [char]0xFEFF
        ) {
            $standardError = $standardError.Substring(1)
        }
        return [pscustomobject]@{
            StandardOutput = $standardOutput
            StandardError = $standardError
            StandardOutputByteCount = [long]$stdoutBytes.Length
            StandardErrorByteCount = [long]$stderrBytes.Length
        }
    }
    finally {
        $stopwatch.Stop()
        $stdoutBytes.Dispose()
        $stderrBytes.Dispose()
    }
}

function Invoke-BoundedGitProcess {
    param(
        [string]$GitPath,
        [string[]]$Arguments,
        [string]$WorkingDirectory,
        [string]$IsolationRoot,
        [int]$TimeoutMilliseconds = 15000,
        [int]$KillWaitMilliseconds = 5000,
        [int]$MaxStandardOutputBytes = 8MB,
        [int]$MaxStandardErrorBytes = 1MB
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $GitPath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.WorkingDirectory = $WorkingDirectory
    if ($null -ne $startInfo.PSObject.Properties['StandardOutputEncoding']) {
        $startInfo.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $startInfo.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    }

    $emptyConfig = Join-Path $IsolationRoot 'empty.gitconfig'
    $emptyHooks = Join-Path $IsolationRoot 'hooks'
    $emptyAttributes = Join-Path $IsolationRoot 'attributes'
    $emptyExcludes = Join-Path $IsolationRoot 'excludes'
    $emptyTemplate = Join-Path $IsolationRoot 'template'
    $safeArguments = @(
        '--no-pager',
        '--no-lazy-fetch',
        '--no-replace-objects',
        '-c', "core.hooksPath=$emptyHooks",
        '-c', "core.attributesFile=$emptyAttributes",
        '-c', "core.excludesFile=$emptyExcludes",
        '-c', "init.templateDir=$emptyTemplate",
        '-c', 'core.fsmonitor=false',
        '-c', 'core.untrackedCache=false',
        '-c', 'credential.helper=',
        '-c', 'credential.interactive=never',
        '-c', 'protocol.allow=never',
        '-c', 'protocol.file.allow=never',
        '-c', 'protocol.ext.allow=never',
        '-c', 'protocol.http.allow=never',
        '-c', 'protocol.https.allow=never',
        '-c', 'protocol.ssh.allow=never',
        '-c', 'protocol.git.allow=never'
    ) + $Arguments
    Set-ProcessArguments -StartInfo $startInfo -Arguments $safeArguments

    # 親processは一切変更せず、子process専用のenv cloneから全ambient
    # GIT_*（未知名・trace・repo/index/object/config/exec系を含む）を除去する。
    foreach ($name in @(
        $startInfo.EnvironmentVariables.Keys |
            ForEach-Object { [string]$_ } |
            Where-Object { $_ -match '^GIT_' }
    )) {
        [void]$startInfo.EnvironmentVariables.Remove($name)
    }
    $startInfo.EnvironmentVariables['GIT_CONFIG_NOSYSTEM'] = '1'
    $startInfo.EnvironmentVariables['GIT_ATTR_NOSYSTEM'] = '1'
    $startInfo.EnvironmentVariables['GIT_CONFIG_GLOBAL'] = $emptyConfig
    $startInfo.EnvironmentVariables['GIT_CONFIG_SYSTEM'] = $emptyConfig
    $startInfo.EnvironmentVariables['GIT_TERMINAL_PROMPT'] = '0'
    $startInfo.EnvironmentVariables['GIT_OPTIONAL_LOCKS'] = '0'
    $startInfo.EnvironmentVariables['GIT_LFS_SKIP_SMUDGE'] = '1'
    $startInfo.EnvironmentVariables['GIT_NO_LAZY_FETCH'] = '1'
    $startInfo.EnvironmentVariables['GIT_NO_REPLACE_OBJECTS'] = '1'
    $startInfo.EnvironmentVariables['GIT_PROTOCOL_FROM_USER'] = '0'
    $startInfo.EnvironmentVariables['GCM_INTERACTIVE'] = 'Never'

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
            -MaxStandardErrorBytes $MaxStandardErrorBytes `
            -ProcessLabel 'Git'

        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            StandardOutput = $streamResult.StandardOutput
            StandardError = $streamResult.StandardError
            StandardOutputByteCount = $streamResult.StandardOutputByteCount
            StandardErrorByteCount = $streamResult.StandardErrorByteCount
        }
    }
    finally {
        if ($started -and -not $process.HasExited) {
            Stop-ProcessTree -Process $process -KillWaitMilliseconds $KillWaitMilliseconds
        }
        $process.Dispose()
    }
}

function Test-PathTextEqual {
    param(
        [string]$Left,
        [string]$Right
    )

    return $Left.Equals($Right, $pathComparison)
}

function Remove-GitIsolationRoot {
    param(
        [string]$IsolationRoot,
        [string]$TemporaryParent
    )

    $resolvedRoot = [System.IO.Path]::GetFullPath($IsolationRoot)
    $resolvedParent = [System.IO.Path]::GetDirectoryName($resolvedRoot)
    $resolvedTemporaryParent = [System.IO.Path]::GetFullPath($TemporaryParent)
    $separators = [char[]]@(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
    $resolvedParent = $resolvedParent.TrimEnd($separators)
    $resolvedTemporaryParent = $resolvedTemporaryParent.TrimEnd($separators)
    $rootName = [System.IO.Path]::GetFileName($resolvedRoot)
    if (
        -not (Test-PathTextEqual -Left $resolvedParent -Right $resolvedTemporaryParent) -or
        $rootName -cnotmatch '^multi-agent-delegation-git-env-[0-9a-f]{32}$'
    ) {
        throw 'Refusing to remove a Git isolation directory outside the OS temp root.'
    }

    if (Test-Path -LiteralPath $resolvedRoot) {
        $rootItem = Get-Item -LiteralPath $resolvedRoot
        if (($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'Refusing to recursively remove a Git isolation reparse point.'
        }
        Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
    }
}

function Invoke-BoundedTextFileRead {
    param(
        [string]$FullPath,
        [int]$TimeoutMilliseconds = 5000
    )

    $temporaryParent = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    $readerRoot = Join-Path $temporaryParent (
        'multi-agent-delegation-git-env-' + [System.Guid]::NewGuid().ToString('N')
    )
    $readerScript = Join-Path $readerRoot 'read-text-file.ps1'
    $process = $null
    $started = $false
    try {
        New-Item -ItemType Directory -Path $readerRoot | Out-Null
        [System.IO.File]::WriteAllText(
            $readerScript,
            @'
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$InputPath)

$source = [System.IO.File]::Open(
    $InputPath,
    [System.IO.FileMode]::Open,
    [System.IO.FileAccess]::Read,
    [System.IO.FileShare]::Read
)
try {
    $destination = [Console]::OpenStandardOutput()
    $buffer = New-Object byte[] 8192
    while (($count = $source.Read($buffer, 0, $buffer.Length)) -gt 0) {
        $destination.Write($buffer, 0, $count)
    }
    $destination.Flush()
}
finally {
    $source.Dispose()
}
'@,
            $utf8NoBom
        )

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
        $arguments = @('-NoLogo', '-NoProfile', '-NonInteractive')
        if ($isWindowsPlatform) {
            $arguments += @('-ExecutionPolicy', 'Bypass')
        }
        $arguments += @('-File', $readerScript, '-InputPath', $FullPath)

        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $powerShellPath
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.WorkingDirectory = $root
        Set-ProcessArguments -StartInfo $startInfo -Arguments $arguments

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $startInfo
        [void]$process.Start()
        $started = $true
        $streamResult = Read-BoundedProcessStreams `
            -Process $process `
            -TimeoutMilliseconds $TimeoutMilliseconds `
            -KillWaitMilliseconds 5000 `
            -MaxStandardOutputBytes ($maxTextFileBytes + 4) `
            -MaxStandardErrorBytes 64KB `
            -ProcessLabel 'File reader'
        if ($process.ExitCode -ne 0) {
            throw 'File reader child failed.'
        }
        return $streamResult
    }
    finally {
        if ($null -ne $process) {
            if ($started -and -not $process.HasExited) {
                Stop-ProcessTree -Process $process -KillWaitMilliseconds 5000
            }
            $process.Dispose()
        }
        Remove-GitIsolationRoot `
            -IsolationRoot $readerRoot `
            -TemporaryParent $temporaryParent
    }
}

# local-only marker fileもcontainment/link/size境界を通し、内容read自体を
# bounded childへ隔離してFIFO/device/raceによる親scanner停止を防ぐ。
$localMarkerFile = Join-Path $root '.private-markers.local'
if (Test-Path -LiteralPath $localMarkerFile) {
    $localMarkerItem = Get-Item -LiteralPath $localMarkerFile -Force
    if (
        Test-IsSafeRegularFile `
            -Item $localMarkerItem `
            -RelativePath '.private-markers.local'
    ) {
        try {
            $localMarkerRead = Invoke-BoundedTextFileRead `
                -FullPath $localMarkerItem.FullName
            Add-LocalMarkersFromText -Content $localMarkerRead.StandardOutput
        }
        catch {
            Add-SafetyFinding `
                -RelativePath '.private-markers.local' `
                -Rule 'file-read-failed'
        }
    }
}

# scan modeごとの入力をまず固定し、content searchと境界判定を分離する。
$scanMode = 'working-tree'
$scanInputs = New-Object System.Collections.Generic.List[object]
$aggregateTextBytes = [long]0
$gitControlEntry = Find-NearestGitControlEntry
$gitControlIsSafe = (
    $null -eq $gitControlEntry -or
    -not (Test-IsLinkOrReparse -Item $gitControlEntry)
)

if ($null -ne $gitControlEntry) {
    $scanMode = 'git-tracked-index'
    $gitExe = Get-Command git -ErrorAction SilentlyContinue
    if (-not $gitControlIsSafe) {
        Add-SafetyFinding -RelativePath '<git-index>' -Rule 'unsafe-git-control-entry'
    } elseif ($null -eq $gitExe) {
        Add-SafetyFinding -RelativePath '<git-index>' -Rule 'git-probe-failed'
    } else {
        $temporaryParent = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
        $gitIsolationRoot = Join-Path $temporaryParent (
            'multi-agent-delegation-git-env-' + [System.Guid]::NewGuid().ToString('N')
        )
        try {
            New-Item -ItemType Directory -Path $gitIsolationRoot | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $gitIsolationRoot 'hooks') | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $gitIsolationRoot 'template') | Out-Null
            [System.IO.File]::WriteAllText(
                (Join-Path $gitIsolationRoot 'empty.gitconfig'),
                '',
                $utf8NoBom
            )
            [System.IO.File]::WriteAllText(
                (Join-Path $gitIsolationRoot 'attributes'),
                '',
                $utf8NoBom
            )
            [System.IO.File]::WriteAllText(
                (Join-Path $gitIsolationRoot 'excludes'),
                '',
                $utf8NoBom
            )

            # `.git`検出後のprobe failureと別root解決は、working-treeへ
            # downgradeせずfail closedにする。
            $topLevel = Invoke-BoundedGitProcess `
                -GitPath $gitExe.Source `
                -Arguments @('-C', $root, 'rev-parse', '--show-toplevel') `
                -WorkingDirectory $root `
                -IsolationRoot $gitIsolationRoot
            $resolvedTopLevel = $null
            if ($topLevel.ExitCode -eq 0) {
                try {
                    $resolvedTopLevel = [System.IO.Path]::GetFullPath(
                        $topLevel.StandardOutput.Trim()
                    )
                }
                catch {
                    $resolvedTopLevel = $null
                }
            }

            if ($topLevel.ExitCode -ne 0 -or $null -eq $resolvedTopLevel) {
                Add-SafetyFinding -RelativePath '<git-index>' -Rule 'git-probe-failed'
            } elseif (-not (Test-PathTextEqual -Left $resolvedTopLevel -Right $root)) {
                Add-SafetyFinding -RelativePath '<git-index>' -Rule 'repository-root-mismatch'
            } else {
                # stage/mode/object IDを同時取得し、worktree fileではなく
                # stage-0 blobをscanする。
                $trackedList = Invoke-BoundedGitProcess `
                    -GitPath $gitExe.Source `
                    -Arguments @('-C', $root, 'ls-files', '--stage', '-z') `
                    -WorkingDirectory $root `
                    -IsolationRoot $gitIsolationRoot `
                    -MaxStandardOutputBytes $maxGitMetadataBytes
                if ($trackedList.ExitCode -ne 0) {
                    Add-SafetyFinding -RelativePath '<git-index>' -Rule 'git-index-read-failed'
                } else {
                    # `-split NUL`は8 MiB内でもNULだけの入力から巨大配列を
                    # 作れる。indexを逐次探索し、上限+1件目で直ちに止める。
                    $trackedEntries = New-Object System.Collections.Generic.List[string]
                    $trackedEntryLimitExceeded = $false
                    $trackedOutputMalformed = $false
                    $trackedOffset = 0
                    $trackedRecordCount = 0
                    while ($trackedOffset -lt $trackedList.StandardOutput.Length) {
                        $nulIndex = $trackedList.StandardOutput.IndexOf(
                            [char]0,
                            $trackedOffset
                        )
                        if ($nulIndex -lt 0) {
                            $trackedOutputMalformed = $true
                            break
                        }
                        $entryLength = $nulIndex - $trackedOffset
                        if ($entryLength -eq 0) {
                            # 正規の`git ls-files -z`は空pathを返さない。
                            # NUL-only入力は空indexへdowngradeせず即拒否する。
                            $trackedOutputMalformed = $true
                            break
                        }
                        $trackedRecordCount++
                        if ($trackedRecordCount -gt $maxTrackedEntries) {
                            $trackedEntryLimitExceeded = $true
                            break
                        }
                        $trackedEntries.Add(
                            $trackedList.StandardOutput.Substring(
                                $trackedOffset,
                                $entryLength
                            )
                        ) | Out-Null
                        $trackedOffset = $nulIndex + 1
                    }
                    if ($trackedOutputMalformed) {
                        Add-SafetyFinding `
                            -RelativePath '<git-index>' `
                            -Rule 'malformed-git-index-output'
                    } elseif ($trackedEntryLimitExceeded) {
                        Add-SafetyFinding `
                            -RelativePath '<git-index>' `
                            -Rule 'tracked-entry-limit-exceeded'
                    } else {
                    $rejectedPaths = [System.Collections.Generic.HashSet[string]]::new(
                        [System.StringComparer]::Ordinal
                    )
                    foreach ($entry in $trackedEntries) {
                        $tabIndex = $entry.IndexOf("`t")
                        if ($tabIndex -lt 0) {
                            Add-SafetyFinding -RelativePath '<git-index>' -Rule 'malformed-git-index-entry'
                            continue
                        }
                        $metadata = $entry.Substring(0, $tabIndex)
                        $relative = $entry.Substring($tabIndex + 1)
                        $metadataParts = $metadata.Split(
                            [char[]]@(' '),
                            [System.StringSplitOptions]::RemoveEmptyEntries
                        )
                        if (
                            $metadataParts.Count -ne 3 -or
                            $metadataParts[0] -notmatch '^\d{6}$' -or
                            $metadataParts[1] -notmatch '^[0-9a-fA-F]{40,64}$' -or
                            $metadataParts[2] -notmatch '^\d+$'
                        ) {
                            Add-SafetyFinding -RelativePath '<git-index>' -Rule 'malformed-git-index-entry'
                            continue
                        }

                        $mode = $metadataParts[0]
                        $objectId = $metadataParts[1]
                        $stage = [int]$metadataParts[2]
                        $nativeRelativePath = $relative.Replace(
                            [char]47,
                            [System.IO.Path]::DirectorySeparatorChar
                        )
                        $fullPath = Join-Path $root $nativeRelativePath
                        if (-not (Test-IsPathInsideRoot -FullPath $fullPath)) {
                            Add-SafetyFinding -RelativePath '<outside-scan-root>' -Rule 'unsafe-file-entry'
                            continue
                        }
                        if ($relative -eq '.private-markers.local') {
                            # local marker fileはuntracked専用契約である。indexに
                            # 現れた時点で内容を公開せずfail closedにする。
                            Add-SafetyFinding `
                                -RelativePath $relative `
                                -Rule 'tracked-private-marker-file'
                            continue
                        }
                        if (-not (Test-IsTextFile -FullPath $relative)) {
                            continue
                        }
                        if ($stage -ne 0) {
                            if ($rejectedPaths.Add($relative)) {
                                Add-SafetyFinding -RelativePath $relative -Rule 'unmerged-git-index-entry'
                            }
                            continue
                        }
                        if ($mode -notin @('100644', '100755')) {
                            if ($rejectedPaths.Add($relative)) {
                                Add-SafetyFinding -RelativePath $relative -Rule 'unsafe-git-index-entry'
                            }
                            continue
                        }

                        $blobSizeResult = Invoke-BoundedGitProcess `
                            -GitPath $gitExe.Source `
                            -Arguments @('-C', $root, 'cat-file', '-s', $objectId) `
                            -WorkingDirectory $root `
                            -IsolationRoot $gitIsolationRoot
                        $blobSizeText = $blobSizeResult.StandardOutput.Trim()
                        $blobSize = [long]0
                        if (
                            $blobSizeResult.ExitCode -ne 0 -or
                            -not [long]::TryParse($blobSizeText, [ref]$blobSize)
                        ) {
                            Add-SafetyFinding -RelativePath $relative -Rule 'git-blob-read-failed'
                            continue
                        }
                        if ($blobSize -gt $maxTextFileBytes) {
                            Add-SafetyFinding -RelativePath $relative -Rule 'oversized-text-file'
                            continue
                        }
                        if (($aggregateTextBytes + $blobSize) -gt $maxAggregateTextBytes) {
                            Add-SafetyFinding -RelativePath '<git-index>' -Rule 'aggregate-scan-size-exceeded'
                            break
                        }

                        $blobResult = Invoke-BoundedGitProcess `
                            -GitPath $gitExe.Source `
                            -Arguments @('-C', $root, 'cat-file', 'blob', $objectId) `
                            -WorkingDirectory $root `
                            -IsolationRoot $gitIsolationRoot
                        if (
                            $blobResult.ExitCode -ne 0 -or
                            $blobResult.StandardOutputByteCount -ne $blobSize
                        ) {
                            Add-SafetyFinding -RelativePath $relative -Rule 'git-blob-read-failed'
                            continue
                        }
                        $aggregateTextBytes += $blobSize
                        $scanInputs.Add([pscustomobject]@{
                            RelativePath = ConvertTo-SafeDisplayPath -Value $relative
                            Content = $blobResult.StandardOutput
                        }) | Out-Null
                    }
                    }
                }
            }
        }
        finally {
            Remove-GitIsolationRoot `
                -IsolationRoot $gitIsolationRoot `
                -TemporaryParent $temporaryParent
        }
    }
} else {
    # `.git`が存在しないfixtureだけworking-tree modeへ進む。file自身と
    # 全ancestorのlink/reparse/containment/sizeを検査してから内容を開く。
    foreach ($file in Get-SafeWorkingTreeFiles) {
        $relative = Get-SafeRelativePath -FullPath $file.FullName
        if (
            $file.Name -eq '.private-markers.local' -or
            -not (Test-IsTextFile -FullPath $file.FullName)
        ) {
            continue
        }
        if (-not (Test-IsSafeRegularFile -Item $file -RelativePath $relative)) {
            continue
        }
        try {
            $fileRead = Invoke-BoundedTextFileRead -FullPath $file.FullName
        }
        catch {
            Add-SafetyFinding -RelativePath $relative -Rule 'file-read-failed'
            continue
        }
        if (
            ($aggregateTextBytes + $fileRead.StandardOutputByteCount) -gt
            $maxAggregateTextBytes
        ) {
            Add-SafetyFinding -RelativePath '<scan-root>' -Rule 'aggregate-scan-size-exceeded'
            break
        }
        $aggregateTextBytes += $fileRead.StandardOutputByteCount
        $scanInputs.Add([pscustomobject]@{
            RelativePath = ConvertTo-SafeDisplayPath -Value $relative
            Content = $fileRead.StandardOutput
        }) | Out-Null
    }
}

function Add-TextFindings {
    param(
        [string]$RelativePath,
        [AllowEmptyString()][string]$Content
    )

    $lineNumber = 0
    $reader = New-Object System.IO.StringReader($Content)
    try {
        # 改行だけの4 MiB fileでも配列化せず逐次走査する。行数上限を超えた
        # 入力はscan済み扱いにせず、匿名findingでfail closedにする。
        while (($line = $reader.ReadLine()) -ne $null) {
            $lineNumber++
            $script:aggregateTextLinesScanned++
            if ($lineNumber -gt $maxTextLinesPerFile) {
                Add-SafetyFinding `
                    -RelativePath $RelativePath `
                    -Rule 'text-line-limit-exceeded'
                break
            }
            if ($script:aggregateTextLinesScanned -gt $maxAggregateTextLines) {
                Add-SafetyFinding `
                    -RelativePath '<scan-root>' `
                    -Rule 'aggregate-text-line-limit-exceeded'
                $script:aggregateTextLineLimitExceeded = $true
                break
            }
            if ($script:findingLimitExceeded) {
                break
            }
            if ($line.Length -eq 0) {
                # 空行もline budgetへ数えるが、pattern評価は不要。
                continue
            }

            # MatchCollectionを作らず、対象repo以外を1件見つけた時点で
            # その行のURL検査を終える。findingは値を常にredactする。
            $githubMatch = [regex]::Match($line, $githubUrlPattern)
            $githubMatchCount = 0
            while ($githubMatch.Success) {
                $githubMatchCount++
                if ($githubMatchCount -gt $maxRegexMatchesPerLine) {
                    Add-SafetyFinding `
                        -RelativePath $RelativePath `
                        -Rule 'regex-match-limit-exceeded'
                    break
                }
                if ($githubMatch.Value -notmatch $ownRepoUrlPattern) {
                    Add-RedactedFinding `
                        -RelativePath $RelativePath `
                        -Line $lineNumber `
                        -Rule 'non-allowlisted-github-repo-url'
                    break
                }
                $githubMatch = $githubMatch.NextMatch()
            }

            foreach ($rule in $rules) {
                if ($script:findingLimitExceeded) {
                    break
                }
                $matched = $false
                if ($rule.Kind -eq 'literal') {
                    $matched = $line.Contains($rule.Pattern)
                } elseif ([string]::IsNullOrEmpty($rule.Allowlist)) {
                    $matched = [regex]::IsMatch($line, $rule.Pattern, 'IgnoreCase')
                } else {
                    # allowlist付きruleもMatchCollectionを全展開せず、
                    # 最初の非allowlisted matchで判定を確定する。
                    $ruleMatch = [regex]::Match(
                        $line,
                        $rule.Pattern,
                        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
                    )
                    $ruleMatchCount = 0
                    while ($ruleMatch.Success) {
                        $ruleMatchCount++
                        if ($ruleMatchCount -gt $maxRegexMatchesPerLine) {
                            Add-SafetyFinding `
                                -RelativePath $RelativePath `
                                -Rule 'regex-match-limit-exceeded'
                            break
                        }
                        if (-not [regex]::IsMatch($ruleMatch.Value, $rule.Allowlist)) {
                            $matched = $true
                            break
                        }
                        $ruleMatch = $ruleMatch.NextMatch()
                    }
                }

                if ($matched) {
                    Add-RedactedFinding `
                        -RelativePath $RelativePath `
                        -Line $lineNumber `
                        -Rule $rule.Name
                }
            }
        }
    }
    finally {
        $reader.Dispose()
    }
}

foreach ($scanInput in $scanInputs) {
    if ($findingLimitExceeded -or $aggregateTextLineLimitExceeded) {
        break
    }
    Add-TextFindings `
        -RelativePath $scanInput.RelativePath `
        -Content $scanInput.Content
}

if ($findingLimitExceeded) {
    # 詳細上限分に匿名の集約1件だけを加えるため、最終出力も常に有界。
    $findings.Add([pscustomobject]@{
        File = '<scan-root>'
        Line = 0
        Rule = 'finding-limit-exceeded'
        Match = '<redacted>'
    }) | Out-Null
}

if ($findings.Count -gt 0) {
    Write-Host "Private marker scan failed (scan target: $scanMode):"
    $findings | Sort-Object File, Line, Rule | Format-Table -AutoSize
    exit 1
}

Write-Host "Private marker scan passed (scan target: $scanMode)."
exit 0
