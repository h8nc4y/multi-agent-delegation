[CmdletBinding()]
param(
    [string]$Path = '',

    # 公開wrapperと同じくbinding attributeへ依存せず、body内で固定診断へ
    # 正規化できるraw scalarとしてlower-only deadlineを検査する。
    [object]$ScanDeadlineMilliseconds = 120000
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($scriptRoot)) {
    $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false, $true)
$isWindowsPlatform = (
    [Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
)
$pathComparison = if ($isWindowsPlatform) {
    [System.StringComparison]::OrdinalIgnoreCase
} else {
    [System.StringComparison]::Ordinal
}
$pathComparer = if ($isWindowsPlatform) {
    [System.StringComparer]::OrdinalIgnoreCase
} else {
    [System.StringComparer]::Ordinal
}

function Write-FixedStartupFailure {
    param([string]$Code)

    # Resolve-Path等のPowerShell framingへraw inputを渡さず、起動前failureも
    # UTF-8の固定1行だけで返す。
    $line = "Private marker scan failed: $Code$([Environment]::NewLine)"
    $bytes = $utf8NoBom.GetBytes($line)
    $stream = [Console]::OpenStandardOutput()
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush()
}

try {
    $parsedScanDeadline = 0
    if (
        $ScanDeadlineMilliseconds -isnot [string] -or
        ([string]$ScanDeadlineMilliseconds) -notmatch '^[0-9]+$' -or
        -not [int]::TryParse(
            [string]$ScanDeadlineMilliseconds,
            [System.Globalization.NumberStyles]::None,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [ref]$parsedScanDeadline
        )
    ) {
        if ($ScanDeadlineMilliseconds -is [int]) {
            $parsedScanDeadline = [int]$ScanDeadlineMilliseconds
        } else {
            throw 'scan-deadline-invalid'
        }
    }
    $ScanDeadlineMilliseconds = $parsedScanDeadline
    if (
        $ScanDeadlineMilliseconds -lt 1 -or
        $ScanDeadlineMilliseconds -gt 120000
    ) {
        throw 'scan-deadline-invalid'
    }
}
catch {
    Write-FixedStartupFailure -Code 'scan-deadline-invalid'
    $script:PrivateMarkerScannerExitCode = 2
    return
}

if ([string]::IsNullOrWhiteSpace($Path)) {
    $Path = Split-Path -Parent $scriptRoot
}

try {
    $resolvedRoot = @(Resolve-Path -LiteralPath $Path -ErrorAction Stop)
    if ($resolvedRoot.Count -ne 1) {
        throw 'scan-root-invalid'
    }
    $root = [System.IO.Path]::GetFullPath($resolvedRoot[0].ProviderPath)
    $rootItem = Get-Item -LiteralPath $root -Force -ErrorAction Stop
    if (-not $rootItem.PSIsContainer) {
        throw 'scan-root-invalid'
    }
}
catch {
    Write-FixedStartupFailure -Code 'scan-root-invalid'
    $script:PrivateMarkerScannerExitCode = 2
    return
}

try {
    Import-Module (
        Join-Path $scriptRoot 'private-marker-process-runner.psm1'
    ) -Force -ErrorAction Stop
}
catch {
    Write-FixedStartupFailure -Code 'process-runner-initialization-failed'
    $script:PrivateMarkerScannerExitCode = 2
    return
}

$ownRepoUrlPattern = (
    '^https://github\.com/h8nc4y/multi-agent-delegation(?:\.git)?$'
)
$githubUrlPattern = (
    'https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:\.git)?'
)
$maxTextFileBytes = 4MB
$maxAggregateTextBytes = 64MB
$maxGitMetadataBytes = 8MB
$maxGitBatchOutputBytes = $maxAggregateTextBytes + $maxGitMetadataBytes
$maxTrackedEntries = 4096
$maxWorkingTreeEntries = 4096
$maxDetailedFindings = 1024
$maxTextLinesPerFile = 100000
$maxAggregateTextLines = 200000
$maxRegexMatchesPerLine = 4096
$maxLocalMarkers = 256
$maxLocalMarkerCharacters = 1024
$maxLocalMarkerSourceLines = 1024
$maxFinalOutputBytes = 64KB
$maxScanMilliseconds = $ScanDeadlineMilliseconds
$maxDisplayPathCharacters = 256
$regexTimeout = [TimeSpan]::FromMilliseconds(100)
$scanStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$aggregateTextBytes = [long]0
$aggregateTextLinesScanned = 0
$findingLimitExceeded = $false
$localMarkerLimitReported = $false
$aggregateTextLineLimitExceeded = $false
$findings = New-Object System.Collections.Generic.List[object]
$findingKeys = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::Ordinal
)
$rules = New-Object System.Collections.Generic.List[object]
$scanInputs = New-Object System.Collections.Generic.List[object]

$textExtensions = @(
    '.md', '.markdown', '.txt', '.ps1', '.psm1', '.psd1', '.yml', '.yaml',
    '.json', '.jsonc', '.toml', '.ini', '.cfg', '.conf', '.xml', '.csv',
    '.sh', '.bash', '.bat', '.cmd', '.py', '.js', '.ts', '.css', '.html',
    '.htm', '.editorconfig', '.gitattributes', '.gitignore',
    '.env', '.npmrc', '.pem', '.key'
)
$textExtensionSet = [System.Collections.Generic.HashSet[string]]::new(
    [string[]]$textExtensions,
    [System.StringComparer]::OrdinalIgnoreCase
)

function Test-ScanDeadline {
    if ($scanStopwatch.ElapsedMilliseconds -ge $maxScanMilliseconds) {
        throw 'scan-deadline-exceeded'
    }
}

function Write-FixedRuntimeFailure {
    param([string]$Code)

    $line = "Private marker scan failed: $Code$([Environment]::NewLine)"
    $bytes = $utf8NoBom.GetBytes($line)
    $stream = [Console]::OpenStandardOutput()
    # runtime diagnostic も serialize / stream 取得後・実 write 直前に確認する。
    Test-ScanDeadline
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush()
}

function Get-ChildTimeoutMilliseconds {
    param([int]$RequestedMilliseconds)

    Test-ScanDeadline
    $remaining = (
        $maxScanMilliseconds -
        [int]$scanStopwatch.ElapsedMilliseconds
    )
    return [Math]::Max(1, [Math]::Min($RequestedMilliseconds, $remaining))
}

function Add-ScanRule {
    param(
        [string]$Name,
        [string]$Pattern,
        [ValidateSet('literal', 'regex')]
        [string]$Kind,
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

Add-ScanRule `
    -Name 'openai-api-key-prefix' `
    -Pattern '(?<![A-Za-z0-9])sk-[A-Za-z0-9_-]{16,}' `
    -Kind 'regex'
Add-ScanRule -Name 'github-classic-token-prefix' -Pattern ('g' + 'hp_') -Kind 'literal'
Add-ScanRule -Name 'github-fine-grained-token-prefix' -Pattern ('github' + '_pat_') -Kind 'literal'
Add-ScanRule -Name 'slack-bot-token-prefix' -Pattern ('xo' + 'xb-') -Kind 'literal'
Add-ScanRule -Name 'bearer-token-header' -Pattern ('Bearer' + ' ') -Kind 'literal'
Add-ScanRule -Name 'private-key-block' -Pattern ('BEGIN ' + 'PRIVATE KEY') -Kind 'literal'
Add-ScanRule `
    -Name 'email-address' `
    -Pattern '\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b' `
    -Kind 'regex'

$winPathPlaceholderWord = (
    '(?:path|to|repo|you|your|example|placeholder|dir|folder|project|projects)'
)
$winPathParentWord = '(?:users|user|home|documents|appdata|local|roaming)'
$windowsPathPlaceholderAllowlist = '(?ix)^[A-Za-z]:\\(?:' +
    "(?:(?:$winPathPlaceholderWord|$winPathParentWord)\\)+" +
    '|' +
    "(?:$winPathPlaceholderWord\\?)+(?:\s.*)?" +
    ')$'
Add-ScanRule `
    -Name 'windows-absolute-path' `
    -Pattern '\b[A-Za-z]:\\(?:[^\\/:*?"<>|\r\n]+\\?){2,}' `
    -Kind 'regex' `
    -Allowlist $windowsPathPlaceholderAllowlist
Add-ScanRule -Name 'aws-access-key-id' -Pattern ('A' + 'KIA') -Kind 'literal'
Add-ScanRule `
    -Name 'gcp-api-key-prefix' `
    -Pattern ('AIza' + '[0-9A-Za-z_\-]{35}') `
    -Kind 'regex'
Add-ScanRule -Name 'slack-user-token-prefix' -Pattern ('xo' + 'xp-') -Kind 'literal'
Add-ScanRule -Name 'slack-legacy-app-token-prefix' -Pattern ('xo' + 'xa-') -Kind 'literal'
Add-ScanRule -Name 'slack-app-level-token-prefix' -Pattern ('xa' + 'pp-') -Kind 'literal'
Add-ScanRule `
    -Name 'stripe-live-secret-key' `
    -Pattern ('(s' + 'k|rk)_live_[0-9A-Za-z]{16,}') `
    -Kind 'regex'
Add-ScanRule `
    -Name 'pem-private-key-block' `
    -Pattern ('BEGIN ' + '(RSA|EC|OPENSSH|ENCRYPTED) PRIVATE KEY') `
    -Kind 'regex'

function Test-IsTextFile {
    param([string]$FullPath)

    $name = [System.IO.Path]::GetFileName($FullPath)
    if (
        $name.Equals('.env', [System.StringComparison]::OrdinalIgnoreCase) -or
        $name.StartsWith('.env.', [System.StringComparison]::OrdinalIgnoreCase)
    ) {
        return $true
    }
    $extension = [System.IO.Path]::GetExtension($name)
    if ([string]::IsNullOrEmpty($extension)) {
        return $true
    }
    return $textExtensionSet.Contains($extension)
}

function ConvertTo-SafeDisplayPath {
    param([AllowEmptyString()][string]$Value)

    $builder = New-Object System.Text.StringBuilder
    foreach ($character in $Value.ToCharArray()) {
        $category = [char]::GetUnicodeCategory($character)
        $unsafeCategory = $category -in @(
            [System.Globalization.UnicodeCategory]::Control,
            [System.Globalization.UnicodeCategory]::Format,
            [System.Globalization.UnicodeCategory]::LineSeparator,
            [System.Globalization.UnicodeCategory]::ParagraphSeparator,
            [System.Globalization.UnicodeCategory]::Surrogate
        )
        if ($unsafeCategory) {
            [void]$builder.Append('?')
        } elseif ($character -eq [char]92) {
            [void]$builder.Append('/')
        } else {
            [void]$builder.Append($character)
        }
        if ($builder.Length -ge $maxDisplayPathCharacters) {
            break
        }
    }
    if ($Value.Length -gt $maxDisplayPathCharacters) {
        if ($builder.Length -gt ($maxDisplayPathCharacters - 3)) {
            $builder.Length = $maxDisplayPathCharacters - 3
        }
        [void]$builder.Append('...')
    }
    return $builder.ToString()
}

function Add-RedactedFinding {
    param(
        [string]$RelativePath,
        [int]$Line,
        [string]$Rule
    )

    if ($findings.Count -ge $maxDetailedFindings) {
        $script:findingLimitExceeded = $true
        return
    }
    $safePath = ConvertTo-SafeDisplayPath -Value $RelativePath
    $safeRule = [regex]::Replace($Rule, '[^a-z0-9-]', '-')
    $key = "$safePath`0$Line`0$safeRule"
    if (-not $findingKeys.Add($key)) {
        return
    }
    $findings.Add([pscustomobject]@{
        File = $safePath
        Line = $Line
        Rule = $safeRule
        Match = '<redacted>'
    }) | Out-Null
}

function Add-SafetyFinding {
    param(
        [string]$RelativePath,
        [string]$Rule
    )

    $safePath = if ([string]::IsNullOrWhiteSpace($RelativePath)) {
        '<scan-root>'
    } else {
        $RelativePath
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
    $normalizedRoot = $root.TrimEnd([char]92, [char]47)
    $relative = $candidate.Substring($normalizedRoot.Length).TrimStart(
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
    $linkType = $Item.PSObject.Properties['LinkType']
    $linkTarget = $Item.PSObject.Properties['LinkTarget']
    return (
        ($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or
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
    $queue = [System.Collections.Generic.Queue[System.IO.DirectoryInfo]]::new()
    $scanRootItem = Get-Item -LiteralPath $root -Force
    if (
        -not $scanRootItem.PSIsContainer -or
        (Test-IsLinkOrReparse -Item $scanRootItem)
    ) {
        Add-SafetyFinding -RelativePath '<scan-root>' -Rule 'unsafe-file-entry'
        return $safeFiles.ToArray()
    }
    $queue.Enqueue($scanRootItem)
    $entryCount = 0
    while ($queue.Count -gt 0) {
        Test-ScanDeadline
        $directory = $queue.Dequeue()
        try {
            $remaining = $maxWorkingTreeEntries - $entryCount + 1
            $children = @(
                Get-ChildItem -LiteralPath $directory.FullName -Force |
                    Select-Object -First $remaining
            )
        }
        catch {
            Add-SafetyFinding `
                -RelativePath (Get-SafeRelativePath $directory.FullName) `
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
            # POSIXでは `.GIT` はordinary directoryである。PowerShellの
            # case-insensitive `-match`へ `.git` 判定を混ぜず、exact component
            # だけをcontrol metadataとして除外する。
            $relativeComponents = @($relative -split '/')
            if (
                $relativeComponents -ccontains '.git' -or
                $relative -match '(?:^|/)(?:node_modules|\.cache)(?:/|$)'
            ) {
                continue
            }
            if ($child.PSIsContainer) {
                $queue.Enqueue($child)
            } else {
                $safeFiles.Add($child) | Out-Null
            }
        }
    }
    return $safeFiles.ToArray()
}

function Find-NearestGitControlEntry {
    $current = Get-Item -LiteralPath $root -Force
    while ($null -ne $current) {
        try {
            $matches = @(
                Get-ChildItem -LiteralPath $current.FullName -Force |
                    Where-Object {
                        $_.Name.Equals('.git', $pathComparison)
                    }
            )
        }
        catch {
            throw 'git-probe-failed'
        }
        if ($matches.Count -gt 1) {
            throw 'git-probe-failed'
        }
        if ($matches.Count -eq 1) {
            return $matches[0]
        }
        $current = $current.Parent
    }
    return $null
}

function New-ChildEnvironment {
    # runner moduleが構築する固定allowlistだけを共通基底にする。Git / reader
    # 固有値は各呼び出し直前に明示し、ambient stateを暗黙に再導入しない。
    return New-PrivateMarkerChildEnvironment
}

function Get-NativeGitApplicationPath {
    # PowerShell script/function/alias解決をnative process境界へ渡さない。
    # PATH解決順の先頭ApplicationInfoだけを固定する。複数Gitの共存は通常状態
    # だが、先頭が不適格なら後順位へfallbackせずfail closedにする。
    $commands = @(
        Get-Command `
            git `
            -CommandType Application `
            -ErrorAction SilentlyContinue
    )
    if ($commands.Count -eq 0) {
        return ''
    }
    $candidate = [string]$commands[0].Path
    if (
        [string]::IsNullOrWhiteSpace($candidate) -or
        -not [System.IO.Path]::IsPathRooted($candidate) -or
        -not (Test-Path -LiteralPath $candidate -PathType Leaf)
    ) {
        return ''
    }
    $item = Get-Item -LiteralPath $candidate -Force
    if (
        $item -isnot [System.IO.FileInfo] -or
        (
            $item.Attributes -band
                [System.IO.FileAttributes]::ReparsePoint
        ) -ne 0
    ) {
        return ''
    }
    return $item.FullName
}

function ConvertFrom-StrictUtf8 {
    param(
        [byte[]]$Bytes,
        [string]$FailureCode
    )

    try {
        $text = $utf8NoBom.GetString($Bytes)
        if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) {
            return $text.Substring(1)
        }
        return $text
    }
    catch {
        throw $FailureCode
    }
}

function New-GitIsolationRoot {
    $temporaryParent = [System.IO.Path]::GetFullPath(
        [System.IO.Path]::GetTempPath()
    )
    $isolationRoot = Join-Path $temporaryParent (
        'multi-agent-delegation-git-env-' +
        [System.Guid]::NewGuid().ToString('N')
    )
    try {
        New-Item -ItemType Directory -Path $isolationRoot | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $isolationRoot 'hooks') |
            Out-Null
        New-Item -ItemType Directory -Path (Join-Path $isolationRoot 'template') |
            Out-Null
        foreach ($name in @('empty.gitconfig', 'attributes', 'excludes')) {
            [System.IO.File]::WriteAllText(
                (Join-Path $isolationRoot $name),
                '',
                $utf8NoBom
            )
        }
        return [pscustomobject]@{
            Root = $isolationRoot
            TemporaryParent = $temporaryParent
        }
    }
    catch {
        # partial createでも既知prefixの直下だけをbounded cleanupし、元例外の
        # absolute temp pathはprocess boundaryへ渡さない。
        try {
            Remove-GitIsolationRoot `
                -IsolationRoot $isolationRoot `
                -TemporaryParent $temporaryParent
        }
        catch {
            # outer boundaryは固定診断へ畳む。unsafe targetへ範囲を広げない。
        }
        throw 'git-isolation-create-failed'
    }
}

function Remove-GitIsolationRoot {
    param(
        [string]$IsolationRoot,
        [string]$TemporaryParent
    )

    $resolved = [System.IO.Path]::GetFullPath($IsolationRoot)
    $parent = [System.IO.Path]::GetDirectoryName($resolved)
    $expected = [System.IO.Path]::GetFullPath($TemporaryParent).TrimEnd(
        [char]92,
        [char]47
    )
    $actual = $parent.TrimEnd([char]92, [char]47)
    $leaf = [System.IO.Path]::GetFileName($resolved)
    if (
        -not $actual.Equals($expected, $pathComparison) -or
        $leaf -cnotmatch '^multi-agent-delegation-git-env-[0-9a-f]{32}$'
    ) {
        throw 'unsafe-isolation-cleanup-target'
    }
    if (Test-Path -LiteralPath $resolved) {
        $item = Get-Item -LiteralPath $resolved -Force
        if (Test-IsLinkOrReparse -Item $item) {
            throw 'unsafe-isolation-cleanup-target'
        }
        $queue = [System.Collections.Generic.Queue[
            System.IO.DirectoryInfo
        ]]::new()
        $queue.Enqueue($item)
        while ($queue.Count -gt 0) {
            $directory = $queue.Dequeue()
            foreach (
                $child in Get-ChildItem `
                    -LiteralPath $directory.FullName `
                    -Force
            ) {
                if (Test-IsLinkOrReparse -Item $child) {
                    throw 'unsafe-isolation-cleanup-target'
                }
                if ($child.PSIsContainer) {
                    $queue.Enqueue($child)
                }
            }
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}

function Invoke-BoundedGitProcess {
    param(
        [string]$GitPath,
        [string[]]$Arguments,
        [string]$IsolationRoot,
        [byte[]]$StandardInput = [byte[]]@(),
        [int]$TimeoutMilliseconds = 15000,
        [int]$MaxStandardOutputBytes = 8MB,
        [int]$MaxStandardErrorBytes = 1MB
    )

    $environment = New-ChildEnvironment
    $environment['GIT_CONFIG_NOSYSTEM'] = '1'
    $environment['GIT_ATTR_NOSYSTEM'] = '1'
    $environment['GIT_CONFIG_GLOBAL'] = Join-Path $IsolationRoot 'empty.gitconfig'
    $environment['GIT_CONFIG_SYSTEM'] = Join-Path $IsolationRoot 'empty.gitconfig'
    $environment['GIT_TERMINAL_PROMPT'] = '0'
    $environment['GIT_OPTIONAL_LOCKS'] = '0'
    $environment['GIT_LFS_SKIP_SMUDGE'] = '1'
    $environment['GIT_NO_LAZY_FETCH'] = '1'
    $environment['GIT_NO_REPLACE_OBJECTS'] = '1'
    $environment['GIT_PROTOCOL_FROM_USER'] = '0'
    $environment['GCM_INTERACTIVE'] = 'Never'
    # Git 2.43のlazy-fetch抑止warningをbyte-exactに判定できるよう、
    # child側の診断localeだけを固定する。path metadataは引き続き-zのraw byteで扱う。
    $environment['LC_ALL'] = 'C'
    $environment['LANG'] = 'C'

    $safeArguments = @(
        '--no-pager',
        '--no-replace-objects',
        '-c', "core.hooksPath=$(Join-Path $IsolationRoot 'hooks')",
        '-c', "core.attributesFile=$(Join-Path $IsolationRoot 'attributes')",
        '-c', "core.excludesFile=$(Join-Path $IsolationRoot 'excludes')",
        '-c', "init.templateDir=$(Join-Path $IsolationRoot 'template')",
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

    return Invoke-PrivateMarkerBoundedProcess `
        -FilePath $GitPath `
        -Arguments $safeArguments `
        -WorkingDirectory $root `
        -EnvironmentVariables $environment `
        -StandardInput $StandardInput `
        -TimeoutMilliseconds (
            Get-ChildTimeoutMilliseconds $TimeoutMilliseconds
        ) `
        -KillWaitMilliseconds 5000 `
        -MaxStandardOutputBytes $MaxStandardOutputBytes `
        -MaxStandardErrorBytes $MaxStandardErrorBytes
}

function Get-CurrentPowerShellPath {
    $candidateName = if ($PSVersionTable.PSVersion.Major -le 5) {
        'powershell.exe'
    } elseif ($isWindowsPlatform) {
        'pwsh.exe'
    } else {
        'pwsh'
    }
    $candidate = Join-Path $PSHOME $candidateName
    if ([System.IO.File]::Exists($candidate)) {
        return $candidate
    }
    return [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
}

function Invoke-BoundedTextFileRead {
    param(
        [System.IO.FileInfo]$Item,
        [string]$RelativePath
    )

    if (-not (Test-IsSafeRegularFile -Item $Item -RelativePath $RelativePath)) {
        return $null
    }
    $beforeLength = [long]$Item.Length
    $beforeWriteTicks = $Item.LastWriteTimeUtc.Ticks
    $readerCommand = @'
$ErrorActionPreference = 'Stop'
$source = [System.IO.File]::Open(
    $env:MULTI_AGENT_DELEGATION_SCAN_INPUT,
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
'@
    $arguments = @('-NoLogo', '-NoProfile', '-NonInteractive')
    if ($isWindowsPlatform) {
        $arguments += @('-ExecutionPolicy', 'Bypass')
    }
    $arguments += @('-Command', $readerCommand)
    $readerEnvironment = New-ChildEnvironment
    # reader childはprofile/update/telemetryを起動せず、scannerが選んだ単一
    # input pathだけを受け取る。dotnet CLIや親のPSModulePath等は不要。
    $readerEnvironment['POWERSHELL_TELEMETRY_OPTOUT'] = '1'
    $readerEnvironment['POWERSHELL_UPDATECHECK'] = 'Off'
    $readerEnvironment['MULTI_AGENT_DELEGATION_SCAN_INPUT'] = $Item.FullName
    $result = Invoke-PrivateMarkerBoundedProcess `
        -FilePath (Get-CurrentPowerShellPath) `
        -Arguments $arguments `
        -WorkingDirectory $root `
        -EnvironmentVariables $readerEnvironment `
        -TimeoutMilliseconds (Get-ChildTimeoutMilliseconds 5000) `
        -KillWaitMilliseconds 5000 `
        -MaxStandardOutputBytes ($maxTextFileBytes + 1) `
        -MaxStandardErrorBytes 64KB
    if ($result.ExitCode -ne 0 -or $result.StandardErrorBytes.Length -ne 0) {
        Add-SafetyFinding -RelativePath $RelativePath -Rule 'file-read-failed'
        return $null
    }
    try {
        $after = Get-Item -LiteralPath $Item.FullName -Force
    }
    catch {
        Add-SafetyFinding -RelativePath $RelativePath -Rule 'file-changed-during-scan'
        return $null
    }
    if (
        $result.StandardOutputBytes.Length -ne $beforeLength -or
        $after.Length -ne $beforeLength -or
        $after.LastWriteTimeUtc.Ticks -ne $beforeWriteTicks -or
        (Test-IsLinkOrReparse -Item $after)
    ) {
        Add-SafetyFinding -RelativePath $RelativePath -Rule 'file-changed-during-scan'
        return $null
    }
    return [byte[]]$result.StandardOutputBytes
}

function Add-LocalMarker {
    param([string]$Marker)

    $trimmed = $Marker.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith('#')) {
        return
    }
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
    Add-ScanRule `
        -Name "local-private-marker-$script:localMarkerIndex" `
        -Pattern $trimmed `
        -Kind 'literal'
}

function Add-LocalMarkersFromText {
    param([AllowEmptyString()][string]$Content)

    $reader = New-Object System.IO.StringReader($Content)
    $lineCount = 0
    try {
        while (($line = $reader.ReadLine()) -ne $null) {
            $lineCount++
            if ($lineCount -gt $maxLocalMarkerSourceLines) {
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

function Add-ScanInput {
    param(
        [string]$RelativePath,
        [byte[]]$Bytes,
        [string]$Source
    )

    if (($script:aggregateTextBytes + $Bytes.Length) -gt $maxAggregateTextBytes) {
        Add-SafetyFinding `
            -RelativePath '<scan-root>' `
            -Rule 'aggregate-scan-size-exceeded'
        return $false
    }
    $content = ConvertFrom-StrictUtf8 `
        -Bytes $Bytes `
        -FailureCode 'invalid-text-encoding'
    $script:aggregateTextBytes += $Bytes.Length
    $scanInputs.Add([pscustomobject]@{
        RelativePath = ConvertTo-SafeDisplayPath $RelativePath
        Content = $content
        Source = $Source
    }) | Out-Null
    return $true
}

function Test-ByteArrayEqual {
    param(
        [byte[]]$Left,
        [byte[]]$Right
    )

    if ($Left.Length -ne $Right.Length) {
        return $false
    }
    for ($index = 0; $index -lt $Left.Length; $index++) {
        if ($Left[$index] -ne $Right[$index]) {
            return $false
        }
    }
    return $true
}

function Add-TextFindings {
    param(
        [string]$RelativePath,
        [AllowEmptyString()][string]$Content
    )

    $lineNumber = 0
    $reader = New-Object System.IO.StringReader($Content)
    try {
        while (($line = $reader.ReadLine()) -ne $null) {
            Test-ScanDeadline
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
                continue
            }

            try {
                $githubMatch = [regex]::Match(
                    $line,
                    $githubUrlPattern,
                    [System.Text.RegularExpressions.RegexOptions]::None,
                    $regexTimeout
                )
                $githubMatchCount = 0
                while ($githubMatch.Success) {
                    $githubMatchCount++
                    if ($githubMatchCount -gt $maxRegexMatchesPerLine) {
                        Add-SafetyFinding `
                            -RelativePath $RelativePath `
                            -Rule 'regex-match-limit-exceeded'
                        break
                    }
                    if (
                        -not [regex]::IsMatch(
                            $githubMatch.Value,
                            $ownRepoUrlPattern,
                            [System.Text.RegularExpressions.RegexOptions]::None,
                            $regexTimeout
                        )
                    ) {
                        Add-RedactedFinding `
                            -RelativePath $RelativePath `
                            -Line $lineNumber `
                            -Rule 'non-allowlisted-github-repo-url'
                        break
                    }
                    $githubMatch = $githubMatch.NextMatch()
                }

                foreach ($rule in $rules) {
                    Test-ScanDeadline
                    if ($script:findingLimitExceeded) {
                        break
                    }
                    $matched = $false
                    if ($rule.Kind -eq 'literal') {
                        $matched = $line.Contains($rule.Pattern)
                    } elseif ([string]::IsNullOrEmpty($rule.Allowlist)) {
                        $matched = [regex]::IsMatch(
                            $line,
                            $rule.Pattern,
                            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase,
                            $regexTimeout
                        )
                    } else {
                        $ruleMatch = [regex]::Match(
                            $line,
                            $rule.Pattern,
                            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase,
                            $regexTimeout
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
                            if (
                                -not [regex]::IsMatch(
                                    $ruleMatch.Value,
                                    $rule.Allowlist,
                                    [System.Text.RegularExpressions.RegexOptions]::None,
                                    $regexTimeout
                                )
                            ) {
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
            catch [System.Text.RegularExpressions.RegexMatchTimeoutException] {
                Add-SafetyFinding `
                    -RelativePath $RelativePath `
                    -Rule 'regex-timeout'
                break
            }
        }
    }
    finally {
        $reader.Dispose()
    }
}

function Get-GitSnapshot {
    param(
        [string]$GitPath,
        [string]$IsolationRoot
    )

    $stage = Invoke-BoundedGitProcess `
        -GitPath $GitPath `
        -Arguments @('-C', $root, 'ls-files', '--stage', '-z') `
        -IsolationRoot $IsolationRoot `
        -MaxStandardOutputBytes $maxGitMetadataBytes
    $debug = Invoke-BoundedGitProcess `
        -GitPath $GitPath `
        -Arguments @('-C', $root, 'ls-files', '--debug', '-z') `
        -IsolationRoot $IsolationRoot `
        -MaxStandardOutputBytes $maxGitMetadataBytes
    if ($stage.ExitCode -ne 0 -or $debug.ExitCode -ne 0) {
        throw 'git-index-read-failed'
    }
    return [pscustomobject]@{
        Stage = [byte[]]$stage.StandardOutputBytes
        Debug = [byte[]]$debug.StandardOutputBytes
    }
}

function ConvertFrom-GitStageRecords {
    param([byte[]]$Bytes)

    $text = ConvertFrom-StrictUtf8 `
        -Bytes $Bytes `
        -FailureCode 'malformed-git-index-output'
    $records = New-Object System.Collections.Generic.List[object]
    $offset = 0
    while ($offset -lt $text.Length) {
        Test-ScanDeadline
        $nul = $text.IndexOf([char]0, $offset)
        if ($nul -lt 0 -or $nul -eq $offset) {
            throw 'malformed-git-index-output'
        }
        if ($records.Count -ge $maxTrackedEntries) {
            throw 'tracked-entry-limit-exceeded'
        }
        $record = $text.Substring($offset, $nul - $offset)
        $tab = $record.IndexOf("`t")
        if ($tab -lt 0) {
            throw 'malformed-git-index-entry'
        }
        $metadata = $record.Substring(0, $tab).Split(
            [char[]]@(' '),
            [System.StringSplitOptions]::RemoveEmptyEntries
        )
        $relative = $record.Substring($tab + 1)
        if (
            $metadata.Count -ne 3 -or
            $metadata[0] -notmatch '^\d{6}$' -or
            $metadata[1] -notmatch '^[0-9a-fA-F]{40,64}$' -or
            $metadata[2] -notmatch '^[0-3]$' -or
            [string]::IsNullOrEmpty($relative) -or
            $relative.Contains([char]0)
        ) {
            throw 'malformed-git-index-entry'
        }
        $nativeRelative = $relative.Replace(
            [char]47,
            [System.IO.Path]::DirectorySeparatorChar
        )
        $fullPath = Join-Path $root $nativeRelative
        if (-not (Test-IsPathInsideRoot -FullPath $fullPath)) {
            throw 'unsafe-git-index-entry'
        }
        $records.Add([pscustomobject]@{
            Mode = $metadata[0]
            ObjectId = $metadata[1].ToLowerInvariant()
            Stage = [int]$metadata[2]
            RelativePath = $relative
            FullPath = $fullPath
        }) | Out-Null
        $offset = $nul + 1
    }
    return $records.ToArray()
}

function Invoke-GitBlobBatch {
    param(
        [string]$GitPath,
        [string]$IsolationRoot,
        [string[]]$ObjectIds
    )

    $uniqueIds = New-Object System.Collections.Generic.List[string]
    $seen = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($objectId in $ObjectIds) {
        if ($seen.Add($objectId)) {
            $uniqueIds.Add($objectId) | Out-Null
        }
    }
    $requestText = if ($uniqueIds.Count -eq 0) {
        ''
    } else {
        (($uniqueIds.ToArray() -join "`n") + "`n")
    }
    $requestBytes = $utf8NoBom.GetBytes($requestText)
    $batch = Invoke-BoundedGitProcess `
        -GitPath $GitPath `
        -Arguments @('-C', $root, 'cat-file', '--batch') `
        -IsolationRoot $IsolationRoot `
        -StandardInput $requestBytes `
        -TimeoutMilliseconds 30000 `
        -MaxStandardOutputBytes $maxGitBatchOutputBytes
    # Git 2.43はGIT_NO_LAZY_FETCH=1を守ってmissingを返す際、成功exitでも
    # 固定warningをstderrへ1行だけ出す。これ以外のstderrは隠さずfail closedにする。
    $allowedLazyFetchWarnings = @(
        "warning: lazy fetching disabled; some objects may not be available`n",
        "warning: lazy fetching disabled; some objects may not be available`r`n"
    )
    $standardErrorAllowed = $batch.StandardErrorBytes.Length -eq 0
    if (-not $standardErrorAllowed) {
        foreach ($warning in $allowedLazyFetchWarnings) {
            if (
                Test-ByteArrayEqual `
                    -Left $batch.StandardErrorBytes `
                    -Right ($utf8NoBom.GetBytes($warning))
            ) {
                $standardErrorAllowed = $true
                break
            }
        }
    }
    if ($batch.ExitCode -ne 0 -or -not $standardErrorAllowed) {
        throw 'git-blob-batch-failed'
    }

    $contentById = [System.Collections.Generic.Dictionary[string,byte[]]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    $missingIds = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    $bytes = [byte[]]$batch.StandardOutputBytes
    $offset = 0
    foreach ($expectedId in $uniqueIds) {
        Test-ScanDeadline
        $headerEnd = -1
        $headerLimit = [Math]::Min($bytes.Length, $offset + 256)
        for ($index = $offset; $index -lt $headerLimit; $index++) {
            if ($bytes[$index] -eq 10) {
                $headerEnd = $index
                break
            }
        }
        if ($headerEnd -lt 0) {
            throw 'malformed-git-batch-output'
        }
        $headerBytes = New-Object byte[] ($headerEnd - $offset)
        [Array]::Copy(
            $bytes,
            $offset,
            $headerBytes,
            0,
            $headerBytes.Length
        )
        $header = [System.Text.Encoding]::ASCII.GetString($headerBytes)
        $offset = $headerEnd + 1
        if ($header -eq "$expectedId missing") {
            $missingIds.Add($expectedId) | Out-Null
            continue
        }
        $match = [regex]::Match(
            $header,
            '^([0-9a-fA-F]{40,64}) blob ([0-9]+)$'
        )
        $size = [long]0
        if (
            -not $match.Success -or
            -not $match.Groups[1].Value.Equals(
                $expectedId,
                [System.StringComparison]::OrdinalIgnoreCase
            ) -or
            -not [long]::TryParse($match.Groups[2].Value, [ref]$size) -or
            $size -lt 0 -or
            $size -gt [int]::MaxValue -or
            ($offset + $size) -ge $bytes.Length
        ) {
            throw 'malformed-git-batch-output'
        }
        if ($bytes[$offset + [int]$size] -ne 10) {
            throw 'malformed-git-batch-output'
        }
        $content = New-Object byte[] ([int]$size)
        if ($size -gt 0) {
            [Array]::Copy($bytes, $offset, $content, 0, [int]$size)
        }
        $contentById[$expectedId] = $content
        $offset += [int]$size + 1
    }
    if ($offset -ne $bytes.Length) {
        throw 'malformed-git-batch-output'
    }
    return [pscustomobject]@{
        ContentById = $contentById
        MissingIds = $missingIds
    }
}

function Write-BoundedFinalReport {
    param(
        [string]$ScanMode,
        [bool]$Failed,
        [string]$FixedIntegrityFailure = ''
    )

    $newline = [Environment]::NewLine
    $stream = New-Object System.IO.MemoryStream
    $outputTruncated = $false
    $truncationLine = (
        "<scan-root>`t0`toutput-limit-exceeded`t<redacted>$newline"
    )
    $truncationBytes = $utf8NoBom.GetBytes($truncationLine)

    function Add-OutputLine {
        param(
            [string]$Line,
            [bool]$ReserveTruncation
        )
        $bytes = $utf8NoBom.GetBytes($Line + $newline)
        $reserve = if ($ReserveTruncation) {
            $truncationBytes.Length
        } else {
            0
        }
        if (($stream.Length + $bytes.Length + $reserve) -gt $maxFinalOutputBytes) {
            return $false
        }
        $stream.Write($bytes, 0, $bytes.Length)
        return $true
    }

    if (-not [string]::IsNullOrEmpty($FixedIntegrityFailure)) {
        if (
            -not (Add-OutputLine `
                -Line (
                    'Private marker scan failed closed (integrity: ' +
                    "$FixedIntegrityFailure)."
                ) `
                -ReserveTruncation $false)
        ) {
            throw 'final-output-budget-invariant-failed'
        }
    } elseif ($Failed) {
        [void](Add-OutputLine `
            -Line "Private marker scan failed (scan target: $ScanMode):" `
            -ReserveTruncation $true)
        [void](Add-OutputLine `
            -Line "File`tLine`tRule`tMatch" `
            -ReserveTruncation $true)
        foreach ($finding in ($findings | Sort-Object File, Line, Rule)) {
            $line = (
                "$($finding.File)`t$($finding.Line)`t" +
                "$($finding.Rule)`t<redacted>"
            )
            if (-not (Add-OutputLine -Line $line -ReserveTruncation $true)) {
                $outputTruncated = $true
                break
            }
        }
        if ($outputTruncated) {
            if (($stream.Length + $truncationBytes.Length) -gt $maxFinalOutputBytes) {
                throw 'final-output-budget-invariant-failed'
            }
            $stream.Write($truncationBytes, 0, $truncationBytes.Length)
        }
    } else {
        if (
            -not (Add-OutputLine `
                -Line "Private marker scan passed (scan target: $ScanMode)." `
                -ReserveTruncation $false)
        ) {
            throw 'final-output-budget-invariant-failed'
        }
    }

    $bytes = $stream.ToArray()
    if ($bytes.Length -gt $maxFinalOutputBytes) {
        throw 'final-output-budget-invariant-failed'
    }
    $destination = [Console]::OpenStandardOutput()
    # serialize と stream 取得の後、finding / integrity failure / success の
    # 実 write 直前に scan-wide deadline を再確認する。
    Test-ScanDeadline
    $destination.Write($bytes, 0, $bytes.Length)
    $destination.Flush()
    $stream.Dispose()
}

$localMarkerIndex = 0
$scanMode = 'working-tree'
$gitIsolation = $null
$unexpectedFailure = $null
$fixedIntegrityFailure = ''
$fixedRuntimeFailure = ''

try {
    $environmentMarkers = [Environment]::GetEnvironmentVariable(
        'MULTI_AGENT_DELEGATION_PRIVATE_MARKERS'
    )
    if (-not [string]::IsNullOrWhiteSpace($environmentMarkers)) {
        Add-LocalMarkersFromText -Content $environmentMarkers
    }

    $localMarkerPath = Join-Path $root '.private-markers.local'
    if (Test-Path -LiteralPath $localMarkerPath) {
        $localMarkerItem = Get-Item -LiteralPath $localMarkerPath -Force
        $markerBytes = Invoke-BoundedTextFileRead `
            -Item $localMarkerItem `
            -RelativePath '.private-markers.local'
        if ($null -ne $markerBytes) {
            try {
                Add-LocalMarkersFromText -Content (
                    ConvertFrom-StrictUtf8 `
                        -Bytes $markerBytes `
                        -FailureCode 'invalid-local-marker-encoding'
                )
            }
            catch {
                Add-SafetyFinding `
                    -RelativePath '.private-markers.local' `
                    -Rule 'file-read-failed'
            }
        }
    }

    $gitControlEntry = Find-NearestGitControlEntry
    if ($null -eq $gitControlEntry) {
        foreach ($file in Get-SafeWorkingTreeFiles) {
            Test-ScanDeadline
            $relative = Get-SafeRelativePath -FullPath $file.FullName
            if (
                $file.Name -eq '.private-markers.local' -or
                -not (Test-IsTextFile -FullPath $file.FullName)
            ) {
                continue
            }
            $bytes = Invoke-BoundedTextFileRead `
                -Item $file `
                -RelativePath $relative
            if ($null -ne $bytes) {
                [void](Add-ScanInput `
                    -RelativePath $relative `
                    -Bytes $bytes `
                    -Source 'worktree')
            }
        }
        foreach ($input in $scanInputs) {
            Add-TextFindings `
                -RelativePath $input.RelativePath `
                -Content $input.Content
        }
    } else {
        $scanMode = 'git-index-worktree-union'
        # linked worktree/submodule の `.git` はregular gitfileである。directory
        # とnon-reparse regular fileだけをbounded Git probeへ渡し、broken
        # gitfile・dangling/reparse・root mismatchは同じ固定integrity failure
        # に畳む。
        $gitControlIsRegularFile = (
            -not $gitControlEntry.PSIsContainer -and
            $gitControlEntry -is [System.IO.FileInfo]
        )
        if (
            (Test-IsLinkOrReparse -Item $gitControlEntry) -or
            (
                -not $gitControlEntry.PSIsContainer -and
                -not $gitControlIsRegularFile
            )
        ) {
            $fixedIntegrityFailure = 'git-probe'
        } else {
            $gitPath = Get-NativeGitApplicationPath
            if ([string]::IsNullOrEmpty($gitPath)) {
                $fixedIntegrityFailure = 'git-probe'
            } else {
                $gitIsolation = New-GitIsolationRoot
                # probe child / UTF-8 decode / canonicalization のどこで失敗しても、
                # ambiguous control metadata を generic finding へdowngradeしない。
                $resolvedTop = try {
                    $topLevel = Invoke-BoundedGitProcess `
                        -GitPath $gitPath `
                        -Arguments @(
                            '-C',
                            $root,
                            'rev-parse',
                            '--show-toplevel'
                        ) `
                        -IsolationRoot $gitIsolation.Root
                    if ($topLevel.ExitCode -ne 0) {
                        throw 'git-probe-failed'
                    }
                    $topText = (
                        ConvertFrom-StrictUtf8 `
                            -Bytes $topLevel.StandardOutputBytes `
                            -FailureCode 'git-probe-failed'
                    ).Trim()
                    [System.IO.Path]::GetFullPath($topText)
                }
                catch {
                    ''
                }
                if ([string]::IsNullOrEmpty($resolvedTop)) {
                    $fixedIntegrityFailure = 'git-probe'
                } elseif (-not $resolvedTop.Equals($root, $pathComparison)) {
                    $fixedIntegrityFailure = 'git-probe'
                } else {
                    $initialSnapshot = Get-GitSnapshot `
                        -GitPath $gitPath `
                        -IsolationRoot $gitIsolation.Root
                    $records = ConvertFrom-GitStageRecords `
                        -Bytes $initialSnapshot.Stage
                    $recordsByPath = [System.Collections.Generic.Dictionary[
                        string,
                        System.Collections.Generic.List[object]
                    ]]::new($pathComparer)
                    foreach ($record in $records) {
                        if (-not $recordsByPath.ContainsKey($record.RelativePath)) {
                            $recordsByPath[$record.RelativePath] = (
                                New-Object System.Collections.Generic.List[object]
                            )
                        }
                        $recordsByPath[$record.RelativePath].Add($record)
                    }

                    $regularTextRecords = New-Object System.Collections.Generic.List[object]
                    foreach ($relative in $recordsByPath.Keys) {
                        Test-ScanDeadline
                        $pathRecords = $recordsByPath[$relative]
                        if (@($pathRecords | Where-Object { $_.Stage -ne 0 }).Count -gt 0) {
                            Add-SafetyFinding `
                                -RelativePath $relative `
                                -Rule 'unmerged-git-index-entry'
                            continue
                        }
                        if ($pathRecords.Count -ne 1) {
                            Add-SafetyFinding `
                                -RelativePath $relative `
                                -Rule 'malformed-git-index-entry'
                            continue
                        }
                        $record = $pathRecords[0]
                        if ($record.Mode -notin @('100644', '100755')) {
                            Add-SafetyFinding `
                                -RelativePath $relative `
                                -Rule 'unsafe-git-index-entry'
                            continue
                        }
                        if ($relative -eq '.private-markers.local') {
                            Add-SafetyFinding `
                                -RelativePath $relative `
                                -Rule 'tracked-private-marker-file'
                            continue
                        }
                        if (Test-Path -LiteralPath $record.FullPath) {
                            $worktreeItem = Get-Item `
                                -LiteralPath $record.FullPath `
                                -Force
                            if (Test-IsLinkOrReparse -Item $worktreeItem) {
                                Add-SafetyFinding `
                                    -RelativePath $relative `
                                    -Rule 'unsafe-file-entry'
                                continue
                            }
                        }
                        if (Test-IsTextFile -FullPath $relative) {
                            $regularTextRecords.Add($record) | Out-Null
                        }
                    }

                    $blobBatch = Invoke-GitBlobBatch `
                        -GitPath $gitPath `
                        -IsolationRoot $gitIsolation.Root `
                        -ObjectIds @($regularTextRecords | ForEach-Object {
                            $_.ObjectId
                        })
                    foreach ($record in $regularTextRecords) {
                        Test-ScanDeadline
                        $blobBytes = $null
                        if ($blobBatch.MissingIds.Contains($record.ObjectId)) {
                            Add-SafetyFinding `
                                -RelativePath $record.RelativePath `
                                -Rule 'git-blob-read-failed'
                        } elseif (
                            -not $blobBatch.ContentById.TryGetValue(
                                $record.ObjectId,
                                [ref]$blobBytes
                            )
                        ) {
                            Add-SafetyFinding `
                                -RelativePath $record.RelativePath `
                                -Rule 'git-blob-read-failed'
                        } elseif ($blobBytes.Length -gt $maxTextFileBytes) {
                            Add-SafetyFinding `
                                -RelativePath $record.RelativePath `
                                -Rule 'oversized-text-file'
                        } else {
                            [void](Add-ScanInput `
                                -RelativePath $record.RelativePath `
                                -Bytes $blobBytes `
                                -Source 'index')
                        }

                        if (Test-Path -LiteralPath $record.FullPath -PathType Leaf) {
                            $worktreeItem = Get-Item `
                                -LiteralPath $record.FullPath `
                                -Force
                            $worktreeBytes = Invoke-BoundedTextFileRead `
                                -Item $worktreeItem `
                                -RelativePath $record.RelativePath
                            if (
                                $null -ne $worktreeBytes -and
                                (
                                    $null -eq $blobBytes -or
                                    -not (
                                        Test-ByteArrayEqual `
                                            -Left $blobBytes `
                                            -Right $worktreeBytes
                                    )
                                )
                            ) {
                                [void](Add-ScanInput `
                                    -RelativePath $record.RelativePath `
                                    -Bytes $worktreeBytes `
                                    -Source 'worktree')
                            }
                        }
                    }

                    foreach ($input in $scanInputs) {
                        if (
                            $findingLimitExceeded -or
                            $aggregateTextLineLimitExceeded
                        ) {
                            break
                        }
                        Add-TextFindings `
                            -RelativePath $input.RelativePath `
                            -Content $input.Content
                    }

                    $finalSnapshot = Get-GitSnapshot `
                        -GitPath $gitPath `
                        -IsolationRoot $gitIsolation.Root
                    if (
                        -not (
                            Test-ByteArrayEqual `
                                -Left $initialSnapshot.Stage `
                                -Right $finalSnapshot.Stage
                        ) -or
                        -not (
                            Test-ByteArrayEqual `
                                -Left $initialSnapshot.Debug `
                                -Right $finalSnapshot.Debug
                        )
                    ) {
                        Add-SafetyFinding `
                            -RelativePath '<git-index>' `
                            -Rule 'git-index-changed-during-scan'
                    }
                }
            }
        }
    }
}
catch {
    $fixedCode = [string]$_.Exception.Message
    if ($fixedCode -eq 'git-probe-failed') {
        $fixedIntegrityFailure = 'git-probe'
    } elseif (
        @(
            'git-blob-batch-failed',
            'git-index-read-failed',
            'malformed-git-batch-output',
            'malformed-git-index-entry',
            'malformed-git-index-output',
            'tracked-entry-limit-exceeded',
            'unsafe-git-index-entry'
        ) -contains $fixedCode
    ) {
        # hostile Git bytesから導かれる既知のcontent findingは従来どおり
        # redacted ruleとして報告する。process/helper例外とは分離する。
        Add-SafetyFinding -RelativePath '<scan-root>' -Rule $fixedCode
    } else {
        # helper/isolation/filesystemの予期しない例外本文はpathを含み得る。
        # findingへ転記せず、process-boundary固定診断とexit 2へ畳む。
        $fixedRuntimeFailure = 'scanner-runtime-failed'
    }
}
finally {
    if ($null -ne $gitIsolation) {
        try {
            Remove-GitIsolationRoot `
                -IsolationRoot $gitIsolation.Root `
                -TemporaryParent $gitIsolation.TemporaryParent
        }
        catch {
            $fixedRuntimeFailure = 'scanner-runtime-failed'
        }
    }
}

if (-not [string]::IsNullOrEmpty($fixedRuntimeFailure)) {
    try {
        Write-FixedRuntimeFailure -Code $fixedRuntimeFailure
    }
    catch {
        # deadline/stdout failure時もraw exceptionやabsolute pathを出さない。
    }
    $script:PrivateMarkerScannerExitCode = 2
    return
}

if ($findingLimitExceeded) {
    $findings.Add([pscustomobject]@{
        File = '<scan-root>'
        Line = 0
        Rule = 'finding-limit-exceeded'
        Match = '<redacted>'
    }) | Out-Null
}

$failed = $findings.Count -gt 0
try {
    Write-BoundedFinalReport `
        -ScanMode $scanMode `
        -Failed $failed `
        -FixedIntegrityFailure $fixedIntegrityFailure
}
catch {
    # Deadline 超過後は未guardの代替出力を足さず、exit 2だけを返す。
    # それ以外の構築失敗も write 直前の deadline check を必須にする。
    if ([string]$_.Exception.Message -ne 'scan-deadline-exceeded') {
        try {
            Write-FixedRuntimeFailure -Code 'final-output-failed'
        }
        catch {
            # deadline / stdout failure を別の未bounded診断へ連鎖させない。
        }
    }
    $script:PrivateMarkerScannerExitCode = 2
    return
}
if (-not [string]::IsNullOrEmpty($fixedIntegrityFailure)) {
    $script:PrivateMarkerScannerExitCode = 2
    return
}
if ($failed) {
    $script:PrivateMarkerScannerExitCode = 1
    return
}
$script:PrivateMarkerScannerExitCode = 0
