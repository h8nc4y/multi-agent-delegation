[CmdletBinding()]
param(
    [string]$Path = '',

    # hostile-environment probeが同じhelper定義を別processで読むための内部seam。
    # 通常validationでは指定せず、定義後に副作用なくreturnする。
    [switch]$InternalDefinitionsOnly
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
$failures = New-Object System.Collections.Generic.List[string]
$processRunnerModule = Join-Path `
    $scriptRoot `
    'private-marker-process-runner.psm1'
if (-not (Test-Path -LiteralPath $processRunnerModule -PathType Leaf)) {
    throw 'process-runner-module-missing'
}
Import-Module -Name $processRunnerModule -Force -ErrorAction Stop

function Add-Failure {
    param([string]$Message)
    $failures.Add($Message) | Out-Null
}

function Get-RepoFilePath {
    param([string]$RelativePath)
    return Join-Path $root $RelativePath
}

function Assert-FileExists {
    param([string]$RelativePath)

    $filePath = Get-RepoFilePath -RelativePath $RelativePath
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        Add-Failure "Missing required file: $RelativePath"
    }
}

function Assert-FileContains {
    param(
        [string]$RelativePath,
        [string]$Pattern,
        [string]$Description
    )

    $filePath = Get-RepoFilePath -RelativePath $RelativePath
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        Add-Failure "Cannot inspect missing file: $RelativePath ($Description)"
        return
    }

    # 公開MarkdownはUTF-8 BOMなしのため、Windows PowerShell 5.1のANSI既定値へ
    # 委ねず明示的にUTF-8として読む。
    $content = Get-Content -LiteralPath $filePath -Raw -Encoding UTF8
    if ($content -notmatch $Pattern) {
        Add-Failure "$RelativePath is missing: $Description"
    }
}

function Assert-FileDoesNotContain {
    param(
        [string]$RelativePath,
        [string]$Pattern,
        [string]$Description
    )

    $filePath = Get-RepoFilePath -RelativePath $RelativePath
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        Add-Failure "Cannot inspect missing file: $RelativePath ($Description)"
        return
    }

    # negative契約もpositive契約と同じdecode境界で評価し、host差を作らない。
    $content = Get-Content -LiteralPath $filePath -Raw -Encoding UTF8
    if ($content -match $Pattern) {
        Add-Failure "$RelativePath contains forbidden content: $Description"
    }
}

function Test-ContainsExactContract {
    param(
        [string]$Content,
        [string]$Expected
    )

    $normalizedContent = [regex]::Replace($Content, '\s+', ' ').Trim()
    $normalizedExpected = [regex]::Replace($Expected, '\s+', ' ').Trim()
    $firstIndex = $normalizedContent.IndexOf(
        $normalizedExpected,
        [System.StringComparison]::Ordinal
    )
    return (
        $firstIndex -ge 0 -and
        $firstIndex -eq $normalizedContent.LastIndexOf(
            $normalizedExpected,
            [System.StringComparison]::Ordinal
        )
    )
}

function Assert-FileContainsExactContract {
    param(
        [string]$RelativePath,
        [string]$Expected,
        [string]$Description
    )

    $filePath = Get-RepoFilePath -RelativePath $RelativePath
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        Add-Failure "Cannot inspect missing file: $RelativePath ($Description)"
        return
    }

    # Markdownの折返しだけを無視し、契約を構成する語句と順序は完全一致で固定する。
    # 部分regexでは危険な動詞だけを反転しても通るため、意味単位のblock全体を比較する。
    $content = Get-Content -LiteralPath $filePath -Raw -Encoding UTF8
    if (-not (Test-ContainsExactContract -Content $content -Expected $Expected)) {
        Add-Failure "$RelativePath is missing exact contract: $Description"
    }
}

function Assert-FileContractMutationRejected {
    param(
        [string]$RelativePath,
        [string]$Expected,
        [string]$Needle,
        [string]$Replacement,
        [string]$Description
    )

    $filePath = Get-RepoFilePath -RelativePath $RelativePath
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        Add-Failure "Cannot mutate missing file: $RelativePath ($Description)"
        return
    }

    $content = Get-Content -LiteralPath $filePath -Raw -Encoding UTF8
    $normalizedContent = [regex]::Replace($content, '\s+', ' ').Trim()
    $normalizedExpected = [regex]::Replace($Expected, '\s+', ' ').Trim()
    $normalizedNeedle = [regex]::Replace($Needle, '\s+', ' ').Trim()
    $normalizedReplacement = (
        [regex]::Replace($Replacement, '\s+', ' ').Trim()
    )

    # anchorはfile全体でなく検証対象block内に限定し、将来の無関係な同語追加で
    # negative fixtureが壊れないようにする。
    $contractIndex = $normalizedContent.IndexOf(
        $normalizedExpected,
        [System.StringComparison]::Ordinal
    )
    if (
        $contractIndex -lt 0 -or
        $contractIndex -ne $normalizedContent.LastIndexOf(
            $normalizedExpected,
            [System.StringComparison]::Ordinal
        )
    ) {
        Add-Failure (
            "$RelativePath mutation contract must occur exactly once: " +
            $Description
        )
        return
    }

    $needleIndex = $normalizedExpected.IndexOf(
        $normalizedNeedle,
        [System.StringComparison]::Ordinal
    )
    if (
        $needleIndex -lt 0 -or
        $needleIndex -ne $normalizedExpected.LastIndexOf(
            $normalizedNeedle,
            [System.StringComparison]::Ordinal
        )
    ) {
        Add-Failure (
            "$RelativePath mutation anchor must occur once in contract: " +
            $Description
        )
        return
    }

    # 実fileを変更せずmemory上で危険な意味へ反転し、本番matcherが拒否することを
    # 検証する。これによりnegative fixture自体も全hostのreadinessで常時実行される。
    $mutationIndex = $contractIndex + $needleIndex
    $mutated = (
        $normalizedContent.Substring(0, $mutationIndex) +
        $normalizedReplacement +
        $normalizedContent.Substring(
            $mutationIndex + $normalizedNeedle.Length
        )
    )
    if (Test-ContainsExactContract -Content $mutated -Expected $Expected) {
        Add-Failure "$RelativePath accepts semantic mutation: $Description"
    }
}

function Resolve-SyntheticGitExecutable {
    param([string]$CandidatePath = '')

    if ([string]::IsNullOrWhiteSpace($CandidatePath)) {
        $commands = @(
            Get-Command `
                -Name 'git' `
                -CommandType Application `
                -ErrorAction Stop
        )
        if ($commands.Count -lt 1) {
            throw 'synthetic-git-executable-missing'
        }
        $CandidatePath = [string]$commands[0].Source
    }

    if (-not [System.IO.Path]::IsPathRooted($CandidatePath)) {
        throw 'synthetic-git-executable-not-absolute'
    }
    $resolvedPath = [System.IO.Path]::GetFullPath($CandidatePath)
    if (-not [System.IO.File]::Exists($resolvedPath)) {
        throw 'synthetic-git-executable-missing'
    }
    $leaf = [System.IO.Path]::GetFileName($resolvedPath)
    $expectedLeaf = if (
        [Environment]::OSVersion.Platform -eq
            [System.PlatformID]::Win32NT
    ) {
        'git.exe'
    } else {
        'git'
    }
    if (
        -not [string]::Equals(
            $leaf,
            $expectedLeaf,
            [System.StringComparison]::OrdinalIgnoreCase
        )
    ) {
        throw 'synthetic-git-executable-name-invalid'
    }
    return $resolvedPath
}

function Initialize-SyntheticGitControlRoot {
    param([string]$SafeRoot)

    foreach ($directoryName in @('hooks', 'template')) {
        [System.IO.Directory]::CreateDirectory(
            (Join-Path $SafeRoot $directoryName)
        ) | Out-Null
    }
    foreach ($fileName in @(
        'global.config',
        'system.config',
        'attributes',
        'excludes'
    )) {
        Write-SyntheticUtf8Text `
            -Path (Join-Path $SafeRoot $fileName) `
            -Content ''
    }
}

function New-SyntheticGitChildEnvironment {
    param([string]$SafeRoot)

    # production scannerと同じfixed minimal child environmentから始める。
    # ambient GIT_*, HOME, credential, loader, profiler値は列挙も継承もしない。
    $environment = New-PrivateMarkerChildEnvironment
    $environment['GIT_CONFIG_NOSYSTEM'] = '1'
    $environment['GIT_ATTR_NOSYSTEM'] = '1'
    $environment['GIT_CONFIG_GLOBAL'] = Join-Path $SafeRoot 'global.config'
    $environment['GIT_CONFIG_SYSTEM'] = Join-Path $SafeRoot 'system.config'
    $environment['GIT_TERMINAL_PROMPT'] = '0'
    $environment['GIT_OPTIONAL_LOCKS'] = '0'
    $environment['GIT_NO_LAZY_FETCH'] = '1'
    $environment['GIT_NO_REPLACE_OBJECTS'] = '1'
    $environment['GIT_PROTOCOL_FROM_USER'] = '0'
    $environment['GCM_INTERACTIVE'] = 'Never'
    $environment['LC_ALL'] = 'C'
    $environment['LANG'] = 'C'
    return $environment
}

function Get-SyntheticGitArguments {
    param(
        [object]$Context,
        [string[]]$Arguments
    )

    # repository local configをinit templateから隔離し、hook、signing、
    # attributes/filter、credential、network protocolをcommand lineで固定する。
    return @(
        '--no-pager',
        '--no-replace-objects',
        '--no-optional-locks',
        '-c', ('core.hooksPath=' + (Join-Path $Context.SafeRoot 'hooks')),
        '-c', (
            'core.attributesFile=' +
                (Join-Path $Context.SafeRoot 'attributes')
        ),
        '-c', (
            'core.excludesFile=' +
                (Join-Path $Context.SafeRoot 'excludes')
        ),
        '-c', (
            'init.templateDir=' +
                (Join-Path $Context.SafeRoot 'template')
        ),
        '-c', 'core.fsmonitor=false',
        '-c', 'core.untrackedCache=false',
        '-c', 'commit.gpgsign=false',
        '-c', 'tag.gpgsign=false',
        '-c', 'credential.helper=',
        '-c', 'credential.interactive=never',
        '-c', 'protocol.allow=never',
        '-c', 'protocol.file.allow=never',
        '-c', 'protocol.ext.allow=never',
        '-c', 'protocol.http.allow=never',
        '-c', 'protocol.https.allow=never',
        '-c', 'protocol.ssh.allow=never',
        '-c', 'protocol.git.allow=never',
        '-C', $Context.RepositoryPath
    ) + $Arguments
}

function New-SyntheticGitContext {
    param(
        [string]$RepositoryPath,
        [string]$SafeRoot,
        [string]$GitExecutablePath
    )

    return [pscustomobject]@{
        RepositoryPath = [System.IO.Path]::GetFullPath($RepositoryPath)
        SafeRoot = [System.IO.Path]::GetFullPath($SafeRoot)
        GitExecutablePath = Resolve-SyntheticGitExecutable `
            -CandidatePath $GitExecutablePath
    }
}

function Invoke-SyntheticGitRaw {
    param(
        [object]$Context,
        [string[]]$Arguments
    )

    if (
        -not [System.IO.Directory]::Exists($Context.RepositoryPath) -or
        -not [System.IO.Directory]::Exists($Context.SafeRoot)
    ) {
        throw 'synthetic-git-context-invalid'
    }

    # full executable path、exact environment、byte-bounded process treeを使い、
    # native failure、timeout、stderr、decode failureをfail closedにする。
    $result = Invoke-PrivateMarkerBoundedProcess `
        -FilePath $Context.GitExecutablePath `
        -Arguments (
            Get-SyntheticGitArguments `
                -Context $Context `
                -Arguments $Arguments
        ) `
        -WorkingDirectory $Context.RepositoryPath `
        -EnvironmentVariables (
            New-SyntheticGitChildEnvironment -SafeRoot $Context.SafeRoot
        ) `
        -TimeoutMilliseconds 20000 `
        -KillWaitMilliseconds 5000 `
        -MaxStandardOutputBytes 1MB `
        -MaxStandardErrorBytes 256KB
    return $result
}

function Invoke-SyntheticGit {
    param(
        [object]$Context,
        [string[]]$Arguments
    )

    $result = Invoke-SyntheticGitRaw `
        -Context $Context `
        -Arguments $Arguments
    if (
        $result.ExitCode -ne 0 -or
        $result.StandardErrorBytes.Length -ne 0
    ) {
        throw 'synthetic-git-command-failed'
    }

    $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
    try {
        $output = $strictUtf8.GetString($result.StandardOutputBytes)
    }
    catch {
        throw 'synthetic-git-output-invalid'
    }
    $output = $output.Replace("`r`n", "`n")
    if ($output.EndsWith("`n", [System.StringComparison]::Ordinal)) {
        $output = $output.Substring(0, $output.Length - 1)
    }
    if ($output.Length -eq 0) {
        return @()
    }
    return @($output -split "`n")
}

function Test-SyntheticBaselineIsAncestor {
    param(
        [object]$Context,
        [string]$BaselineHead,
        [string]$FinalHead
    )

    # merge-baseの0/1だけをbool evidenceへ変換する。その他のexit、
    # stdout/stderr、timeoutはhistory判定不能としてfail closedにする。
    $result = Invoke-SyntheticGitRaw `
        -Context $Context `
        -Arguments @(
            'merge-base',
            '--is-ancestor',
            $BaselineHead,
            $FinalHead
        )
    if (
        $result.StandardOutputBytes.Length -ne 0 -or
        $result.StandardErrorBytes.Length -ne 0 -or
        ($result.ExitCode -ne 0 -and $result.ExitCode -ne 1)
    ) {
        throw 'synthetic-git-ancestry-check-failed'
    }
    return $result.ExitCode -eq 0
}

function Write-SyntheticUtf8Text {
    param(
        [string]$Path,
        [string]$Content
    )

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Get-SyntheticArtifactState {
    param(
        [string]$RepositoryPath,
        [string]$RelativePath
    )

    $artifactPath = Join-Path $RepositoryPath $RelativePath
    if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) {
        return [pscustomobject]@{
            Exists = $false
            Length = 0L
            Sha256 = ''
        }
    }

    $bytes = [System.IO.File]::ReadAllBytes($artifactPath)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $digest = (
            $sha256.ComputeHash($bytes) |
                ForEach-Object { $_.ToString('x2') }
        ) -join ''
    }
    finally {
        $sha256.Dispose()
    }

    return [pscustomobject]@{
        Exists = $true
        Length = [long]$bytes.Length
        Sha256 = $digest
    }
}

function Get-SyntheticCompletionSnapshot {
    param(
        [object]$Context,
        [string[]]$ArtifactPaths
    )

    # baseline/final snapshotはread-only Git commandだけで構成する。
    # write-treeやindex mutationを検証の近道として使用しない。
    $branch = @(
        Invoke-SyntheticGit `
            -Context $Context `
            -Arguments @('branch', '--show-current')
    ) -join "`n"
    $head = @(
        Invoke-SyntheticGit `
            -Context $Context `
            -Arguments @('rev-parse', '--verify', 'HEAD')
    ) -join "`n"
    $porcelain = @(
        Invoke-SyntheticGit `
            -Context $Context `
            -Arguments @(
                'status',
                '--porcelain=v1',
                '--untracked-files=all'
            )
    )

    $artifacts = @{}
    foreach ($artifactPath in $ArtifactPaths) {
        $artifacts[$artifactPath] = Get-SyntheticArtifactState `
            -RepositoryPath $Context.RepositoryPath `
            -RelativePath $artifactPath
    }

    return [pscustomobject]@{
        Branch = $branch
        Head = $head
        Porcelain = @($porcelain)
        Artifacts = $artifacts
    }
}

function Get-SyntheticCommittedPaths {
    param(
        [object]$Context,
        [string]$BaselineHead,
        [string]$FinalHead
    )

    if (
        [string]::Equals(
            $BaselineHead,
            $FinalHead,
            [System.StringComparison]::Ordinal
        )
    ) {
        return @()
    }

    $range = "$BaselineHead..$FinalHead"
    $nameStatus = @(
        Invoke-SyntheticGit `
            -Context $Context `
            -Arguments @(
                'diff',
                '--name-status',
                '--no-renames',
                $range,
                '--'
            )
    )
    $paths = New-Object System.Collections.Generic.List[string]
    foreach ($line in $nameStatus) {
        $fields = @($line -split "`t")
        if ($fields.Count -lt 2) {
            throw 'synthetic-git-name-status-invalid'
        }
        $paths.Add($fields[$fields.Count - 1]) | Out-Null
    }
    return @($paths)
}

function Get-SyntheticPorcelainPaths {
    param([string[]]$Porcelain)

    $paths = New-Object System.Collections.Generic.List[string]
    foreach ($line in $Porcelain) {
        # fixtureはrenameを使わず、porcelain v1の通常pathだけを対象にする。
        # public契約では司令塔がraw出力を独立確認する。
        if ($line.Length -lt 4) {
            throw 'synthetic-git-porcelain-invalid'
        }
        $paths.Add($line.Substring(3)) | Out-Null
    }
    return @($paths)
}

function Test-SyntheticArtifactChanged {
    param(
        [object]$Initial,
        [object]$Final
    )

    return (
        $Initial.Exists -ne $Final.Exists -or
        $Initial.Length -ne $Final.Length -or
        -not [string]::Equals(
            $Initial.Sha256,
            $Final.Sha256,
            [System.StringComparison]::Ordinal
        )
    )
}

function Test-BaselineAwareCompletionDecision {
    param(
        [object]$Initial,
        [object]$Final,
        [string[]]$CommittedPaths,
        [string[]]$AssignedPaths,
        [Parameter(Mandatory = $true)]
        [bool]$BaselineIsAncestor,
        [bool]$AcceptanceSatisfied
    )

    if (-not $AcceptanceSatisfied) {
        return $false
    }
    if (-not $BaselineIsAncestor) {
        return $false
    }
    if (
        -not [string]::Equals(
            $Initial.Branch,
            $Final.Branch,
            [System.StringComparison]::Ordinal
        )
    ) {
        return $false
    }

    $assigned = New-Object 'System.Collections.Generic.HashSet[string]' (
        [System.StringComparer]::Ordinal
    )
    foreach ($assignedPath in $AssignedPaths) {
        $assigned.Add($assignedPath) | Out-Null
    }

    # initial/final porcelainとbaseline→final commit差分の全pathを割当境界へ
    # containし、未割当WIPの変更・stage・commit・吸収を成功へ昇格させない。
    $scopePaths = New-Object System.Collections.Generic.List[string]
    foreach (
        $porcelainPath in Get-SyntheticPorcelainPaths `
            -Porcelain @($Initial.Porcelain)
    ) {
        $scopePaths.Add($porcelainPath) | Out-Null
    }
    foreach (
        $porcelainPath in Get-SyntheticPorcelainPaths `
            -Porcelain @($Final.Porcelain)
    ) {
        $scopePaths.Add($porcelainPath) | Out-Null
    }
    foreach ($committedPath in $CommittedPaths) {
        $scopePaths.Add($committedPath) | Out-Null
    }
    foreach ($scopePath in $scopePaths) {
        if (-not $assigned.Contains($scopePath)) {
            return $false
        }
    }

    $headChanged = -not [string]::Equals(
        $Initial.Head,
        $Final.Head,
        [System.StringComparison]::Ordinal
    )
    $hasCommittedDelta = (
        $headChanged -and
        @($CommittedPaths).Count -gt 0
    )

    # dirty resumeではporcelainのstatus/path表示が同じまま変化し得るため、
    # assigned artifactのinitial→final byte stateを独立したdelta証拠にする。
    $hasArtifactDelta = $false
    foreach ($assignedPath in $AssignedPaths) {
        if (
            -not $Initial.Artifacts.ContainsKey($assignedPath) -or
            -not $Final.Artifacts.ContainsKey($assignedPath)
        ) {
            return $false
        }
        if (
            Test-SyntheticArtifactChanged `
                -Initial $Initial.Artifacts[$assignedPath] `
                -Final $Final.Artifacts[$assignedPath]
        ) {
            $hasArtifactDelta = $true
        }
    }

    return ($hasCommittedDelta -or $hasArtifactDelta)
}

function Test-NonGitArtifactCompletionDecision {
    param(
        [object]$Initial,
        [object]$Final,
        [bool]$AcceptanceSatisfied
    )

    # 非Git成果物も「現在ある」ではなく、開始前に記録したbyte stateとの
    # 差分と受け入れ条件の両方を満たした場合だけ完了へ昇格する。
    if (-not $AcceptanceSatisfied) {
        return $false
    }
    return Test-SyntheticArtifactChanged -Initial $Initial -Final $Final
}

function New-SyntheticPureDecisionSnapshot {
    param(
        [string]$Branch,
        [string]$Head,
        [string[]]$Porcelain,
        [long]$ArtifactLength,
        [string]$ArtifactSha256
    )

    # Git processを起動できないhostでもcompletion decision自体を常時検査する。
    # 固定snapshotだけを組み立て、filesystemやambient Git状態へ依存させない。
    $artifacts = @{}
    $artifacts['evidence.txt'] = [pscustomobject]@{
        Exists = $true
        Length = $ArtifactLength
        Sha256 = $ArtifactSha256
    }
    return [pscustomobject]@{
        Branch = $Branch
        Head = $Head
        Porcelain = @($Porcelain)
        Artifacts = $artifacts
    }
}

function Assert-BaselineAwareCompletionPureDecisionFixtures {
    $initial = New-SyntheticPureDecisionSnapshot `
        -Branch 'main' `
        -Head ('1' * 40) `
        -Porcelain @() `
        -ArtifactLength 4 `
        -ArtifactSha256 ('a' * 64)
    $unchangedFinal = New-SyntheticPureDecisionSnapshot `
        -Branch 'main' `
        -Head ('1' * 40) `
        -Porcelain @() `
        -ArtifactLength 4 `
        -ArtifactSha256 ('a' * 64)
    $committedFinal = New-SyntheticPureDecisionSnapshot `
        -Branch 'main' `
        -Head ('2' * 40) `
        -Porcelain @() `
        -ArtifactLength 8 `
        -ArtifactSha256 ('b' * 64)
    $dirtyInitial = New-SyntheticPureDecisionSnapshot `
        -Branch 'main' `
        -Head ('1' * 40) `
        -Porcelain @(' M evidence.txt') `
        -ArtifactLength 4 `
        -ArtifactSha256 ('a' * 64)
    $dirtyFinal = New-SyntheticPureDecisionSnapshot `
        -Branch 'main' `
        -Head ('1' * 40) `
        -Porcelain @(' M evidence.txt') `
        -ArtifactLength 8 `
        -ArtifactSha256 ('b' * 64)

    # no-op、acceptance、commit delta、dirty artifact deltaをprocess非依存で固定する。
    if (
        Test-BaselineAwareCompletionDecision `
            -Initial $initial `
            -Final $unchangedFinal `
            -CommittedPaths @() `
            -AssignedPaths @('evidence.txt') `
            -BaselineIsAncestor $true `
            -AcceptanceSatisfied $true
    ) {
        Add-Failure 'pure completion decision accepts no-op'
    }
    if (
        Test-BaselineAwareCompletionDecision `
            -Initial $initial `
            -Final $committedFinal `
            -CommittedPaths @('evidence.txt') `
            -AssignedPaths @('evidence.txt') `
            -BaselineIsAncestor $true `
            -AcceptanceSatisfied $false
    ) {
        Add-Failure 'pure completion decision accepts failed acceptance'
    }
    if (
        -not (
            Test-BaselineAwareCompletionDecision `
                -Initial $initial `
                -Final $committedFinal `
                -CommittedPaths @('evidence.txt') `
                -AssignedPaths @('evidence.txt') `
                -BaselineIsAncestor $true `
                -AcceptanceSatisfied $true
        )
    ) {
        Add-Failure 'pure completion decision rejects committed delta'
    }
    if (
        -not (
            Test-BaselineAwareCompletionDecision `
                -Initial $dirtyInitial `
                -Final $dirtyFinal `
                -CommittedPaths @() `
                -AssignedPaths @('evidence.txt') `
                -BaselineIsAncestor $true `
                -AcceptanceSatisfied $true
        )
    ) {
        Add-Failure 'pure completion decision rejects artifact delta'
    }

    # initial、final、committedの3つのscope guardを独立してfail-closedへ固定する。
    $initialScopeViolation = New-SyntheticPureDecisionSnapshot `
        -Branch 'main' `
        -Head ('1' * 40) `
        -Porcelain @('?? owner-wip.txt') `
        -ArtifactLength 4 `
        -ArtifactSha256 ('a' * 64)
    $finalScopeViolation = New-SyntheticPureDecisionSnapshot `
        -Branch 'main' `
        -Head ('2' * 40) `
        -Porcelain @('?? owner-wip.txt') `
        -ArtifactLength 8 `
        -ArtifactSha256 ('b' * 64)
    foreach ($scopeCase in @(
        [pscustomobject]@{
            Name = 'initial'
            Initial = $initialScopeViolation
            Final = $committedFinal
            CommittedPaths = @('evidence.txt')
        },
        [pscustomobject]@{
            Name = 'final'
            Initial = $initial
            Final = $finalScopeViolation
            CommittedPaths = @('evidence.txt')
        },
        [pscustomobject]@{
            Name = 'committed'
            Initial = $initial
            Final = $committedFinal
            CommittedPaths = @('evidence.txt', 'owner-wip.txt')
        }
    )) {
        if (
            Test-BaselineAwareCompletionDecision `
                -Initial $scopeCase.Initial `
                -Final $scopeCase.Final `
                -CommittedPaths @($scopeCase.CommittedPaths) `
                -AssignedPaths @('evidence.txt') `
                -BaselineIsAncestor $true `
                -AcceptanceSatisfied $true
        ) {
            Add-Failure (
                'pure completion decision accepts ' +
                $scopeCase.Name +
                ' scope violation'
            )
        }
    }

    # 他の成功条件が揃っていてもancestry evidence=falseなら必ず拒否する。
    if (
        Test-BaselineAwareCompletionDecision `
            -Initial $initial `
            -Final $committedFinal `
            -CommittedPaths @('evidence.txt') `
            -AssignedPaths @('evidence.txt') `
            -BaselineIsAncestor $false `
            -AcceptanceSatisfied $true
    ) {
        Add-Failure 'pure completion decision accepts divergent ancestry'
    }
}

function Test-SyntheticGitProcessFixtureCapabilityDecision {
    param(
        [bool]$IsWindowsHost,
        [bool]$HasTrustedSetsid
    )

    # production runnerと同じく、Windows job objectまたはfixed trusted setsidの
    # どちらかでprocess treeを閉じられるhostだけを実行可能とする。
    return ($IsWindowsHost -or $HasTrustedSetsid)
}

function Assert-SyntheticGitProcessFixtureCapabilityDecisions {
    foreach ($capabilityCase in @(
        [pscustomobject]@{
            Name = 'windows-job-object'
            IsWindowsHost = $true
            HasTrustedSetsid = $false
            Expected = $true
        },
        [pscustomobject]@{
            Name = 'unix-trusted-setsid'
            IsWindowsHost = $false
            HasTrustedSetsid = $true
            Expected = $true
        },
        [pscustomobject]@{
            Name = 'unsupported-unix'
            IsWindowsHost = $false
            HasTrustedSetsid = $false
            Expected = $false
        }
    )) {
        $actual = Test-SyntheticGitProcessFixtureCapabilityDecision `
            -IsWindowsHost $capabilityCase.IsWindowsHost `
            -HasTrustedSetsid $capabilityCase.HasTrustedSetsid
        if ($actual -ne $capabilityCase.Expected) {
            Add-Failure (
                'synthetic Git process capability decision failed: ' +
                $capabilityCase.Name
            )
        }
    }
}

function Test-SyntheticGitProcessFixtureSupported {
    $isWindowsHost = (
        [Environment]::OSVersion.Platform -eq
            [System.PlatformID]::Win32NT
    )
    $hasTrustedSetsid = $false
    if (-not $isWindowsHost) {
        # resolverはproduction sourceのfixed pathだけを返す。readiness側でも
        # rooted existing fileを再確認し、任意PATHやambient commandへfallbackしない。
        $trustedSetsidPath = [string](Get-PrivateMarkerTrustedSetsidPath)
        $hasTrustedSetsid = (
            -not [string]::IsNullOrWhiteSpace($trustedSetsidPath) -and
            [System.IO.Path]::IsPathRooted($trustedSetsidPath) -and
            [System.IO.File]::Exists($trustedSetsidPath)
        )
    }
    return Test-SyntheticGitProcessFixtureCapabilityDecision `
        -IsWindowsHost $isWindowsHost `
        -HasTrustedSetsid $hasTrustedSetsid
}

function Test-SyntheticByteArrayEqual {
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

function Get-SyntheticDirectoryState {
    param([string]$DirectoryPath)

    $records = New-Object System.Collections.Generic.List[string]
    if ([System.IO.Directory]::Exists($DirectoryPath)) {
        $rootPath = [System.IO.Path]::GetFullPath($DirectoryPath).TrimEnd(
            [System.IO.Path]::DirectorySeparatorChar,
            [System.IO.Path]::AltDirectorySeparatorChar
        )
        foreach (
            $filePath in @(
                [System.IO.Directory]::GetFiles(
                    $rootPath,
                    '*',
                    [System.IO.SearchOption]::AllDirectories
                ) | Sort-Object
            )
        ) {
            $relativePath = $filePath.Substring($rootPath.Length + 1)
            $state = Get-SyntheticArtifactState `
                -RepositoryPath $rootPath `
                -RelativePath $relativePath
            $records.Add(
                (
                    '{0}:{1}:{2}:{3}' -f
                        $relativePath.Length,
                        $relativePath,
                        $state.Length,
                        $state.Sha256
                )
            ) | Out-Null
        }
    }

    $encoding = New-Object System.Text.UTF8Encoding($false)
    $bytes = $encoding.GetBytes(($records -join "`n"))
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $digest = (
            $sha256.ComputeHash($bytes) |
                ForEach-Object { $_.ToString('x2') }
        ) -join ''
    }
    finally {
        $sha256.Dispose()
    }
    return [pscustomobject]@{
        Count = $records.Count
        Sha256 = $digest
    }
}

function Test-SyntheticDirectoryStateEqual {
    param(
        [object]$Left,
        [object]$Right
    )

    return (
        $Left.Count -eq $Right.Count -and
        [string]::Equals(
            $Left.Sha256,
            $Right.Sha256,
            [System.StringComparison]::Ordinal
        )
    )
}

function Resolve-SyntheticPowerShellExecutable {
    $process = [System.Diagnostics.Process]::GetCurrentProcess()
    try {
        $candidatePath = [string]$process.MainModule.FileName
    }
    finally {
        $process.Dispose()
    }
    if (
        -not [System.IO.Path]::IsPathRooted($candidatePath) -or
        -not [System.IO.File]::Exists($candidatePath)
    ) {
        throw 'synthetic-powershell-executable-invalid'
    }
    $leaf = [System.IO.Path]::GetFileName($candidatePath)
    if ($leaf -notmatch '^(?i:pwsh|powershell)(?:\.exe)?$') {
        throw 'synthetic-powershell-executable-invalid'
    }
    return [System.IO.Path]::GetFullPath($candidatePath)
}

function New-SyntheticProbeHarnessEnvironment {
    param(
        [string]$HarnessRoot,
        [string]$PowerShellPath,
        [string]$GitPath
    )

    # hostile GIT_*をprocess-globalへ書かず、別PowerShell processだけへ渡す。
    # harness自体もfixed local pathだけを持ち、profileやcredentialを継承しない。
    $syntheticIsWindows = (
        [Environment]::OSVersion.Platform -eq
            [System.PlatformID]::Win32NT
    )
    $comparer = if ($syntheticIsWindows) {
        [System.StringComparer]::OrdinalIgnoreCase
    } else {
        [System.StringComparer]::Ordinal
    }
    $environment = New-Object `
        'System.Collections.Generic.Dictionary[string,string]' `
        $comparer
    $homeRoot = Join-Path $HarnessRoot 'home'
    $tempRoot = Join-Path $HarnessRoot 'temp'
    [System.IO.Directory]::CreateDirectory($homeRoot) | Out-Null
    [System.IO.Directory]::CreateDirectory($tempRoot) | Out-Null
    $environment['HOME'] = $homeRoot
    $environment['LC_ALL'] = 'C'
    $environment['LANG'] = 'C'
    $environment['POWERSHELL_TELEMETRY_OPTOUT'] = '1'
    $environment['DOTNET_CLI_TELEMETRY_OPTOUT'] = '1'

    $pathEntries = New-Object System.Collections.Generic.List[string]
    foreach ($executablePath in @($PowerShellPath, $GitPath)) {
        $parent = [System.IO.Path]::GetDirectoryName($executablePath)
        if (-not [string]::IsNullOrWhiteSpace($parent)) {
            $pathEntries.Add($parent) | Out-Null
        }
    }
    if ($syntheticIsWindows) {
        $systemDirectory = [Environment]::SystemDirectory
        $windowsRoot = [System.IO.Directory]::GetParent($systemDirectory)
        if ($null -eq $windowsRoot) {
            throw 'synthetic-harness-environment-invalid'
        }
        $runtimeDirectory = (
            [System.Runtime.InteropServices.RuntimeEnvironment]::
                GetRuntimeDirectory()
        )
        foreach ($entry in @($systemDirectory, $runtimeDirectory)) {
            $pathEntries.Add($entry) | Out-Null
        }
        $environment['SystemRoot'] = $windowsRoot.FullName
        $environment['WINDIR'] = $windowsRoot.FullName
        $environment['ComSpec'] = Join-Path $systemDirectory 'cmd.exe'
        $environment['PATHEXT'] = '.COM;.EXE;.BAT;.CMD'
        $environment['TEMP'] = $tempRoot
        $environment['TMP'] = $tempRoot
        $environment['USERPROFILE'] = $homeRoot
        $environment['APPDATA'] = Join-Path $homeRoot 'AppData\Roaming'
        $environment['LOCALAPPDATA'] = Join-Path $homeRoot 'AppData\Local'
        [System.IO.Directory]::CreateDirectory(
            $environment['APPDATA']
        ) | Out-Null
        [System.IO.Directory]::CreateDirectory(
            $environment['LOCALAPPDATA']
        ) | Out-Null
    } else {
        foreach ($entry in @('/usr/bin', '/bin', '/usr/sbin', '/sbin')) {
            if ([System.IO.Directory]::Exists($entry)) {
                $pathEntries.Add($entry) | Out-Null
            }
        }
        $environment['TMPDIR'] = $tempRoot
        $environment['DOTNET_CLI_HOME'] = $homeRoot
    }
    $environment['PATH'] = @($pathEntries | Select-Object -Unique) -join (
        [System.IO.Path]::PathSeparator
    )
    return $environment
}

function Invoke-SyntheticHermeticChildProbe {
    param(
        [object]$Context,
        [System.Collections.IDictionary]$HarnessEnvironment
    )

    $powerShellPath = Resolve-SyntheticPowerShellExecutable
    $probeScript = @'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$VerbosePreference = 'SilentlyContinue'
$DebugPreference = 'SilentlyContinue'
$InformationPreference = 'SilentlyContinue'
. $env:SYNTHETIC_VALIDATOR_PATH `
    -Path $env:SYNTHETIC_VALIDATOR_ROOT `
    -InternalDefinitionsOnly
$context = [pscustomobject]@{
    RepositoryPath = $env:SYNTHETIC_GIT_REPOSITORY
    SafeRoot = $env:SYNTHETIC_GIT_SAFE_ROOT
    GitExecutablePath = $env:SYNTHETIC_GIT_EXECUTABLE
}
Invoke-SyntheticGit `
    -Context $context `
    -Arguments @('add', '--', '.gitattributes', 'evidence.txt') |
    Out-Null
$success = [System.Text.Encoding]::UTF8.GetBytes(
    "synthetic-git-hermetic-probe-passed`n"
)
$stdout = [Console]::OpenStandardOutput()
$stdout.Write($success, 0, $success.Length)
$stdout.Flush()
'@
    $encodedProbe = [Convert]::ToBase64String(
        [System.Text.Encoding]::Unicode.GetBytes($probeScript)
    )
    $arguments = @('-NoLogo', '-NoProfile', '-NonInteractive')
    if (
        [Environment]::OSVersion.Platform -eq
            [System.PlatformID]::Win32NT
    ) {
        $arguments += @('-ExecutionPolicy', 'Bypass')
    }
    $arguments += @('-EncodedCommand', $encodedProbe)

    $HarnessEnvironment['SYNTHETIC_VALIDATOR_PATH'] = Join-Path `
        $scriptRoot `
        'validate-oss-readiness.ps1'
    $HarnessEnvironment['SYNTHETIC_VALIDATOR_ROOT'] = $root
    $HarnessEnvironment['SYNTHETIC_GIT_REPOSITORY'] = (
        $Context.RepositoryPath
    )
    $HarnessEnvironment['SYNTHETIC_GIT_SAFE_ROOT'] = $Context.SafeRoot
    $HarnessEnvironment['SYNTHETIC_GIT_EXECUTABLE'] = (
        $Context.GitExecutablePath
    )

    try {
        $result = Invoke-PrivateMarkerBoundedProcess `
            -FilePath $powerShellPath `
            -Arguments $arguments `
            -WorkingDirectory $Context.RepositoryPath `
            -EnvironmentVariables $HarnessEnvironment `
            -TimeoutMilliseconds 60000 `
            -KillWaitMilliseconds 5000 `
            -MaxStandardOutputBytes 16KB `
            -MaxStandardErrorBytes 64KB
    }
    catch {
        Add-Failure 'synthetic Git hostile-environment child failed closed'
        return $false
    }

    $expectedOutput = [System.Text.Encoding]::UTF8.GetBytes(
        "synthetic-git-hermetic-probe-passed`n"
    )
    if (
        $result.ExitCode -ne 0 -or
        $result.StandardErrorBytes.Length -ne 0 -or
        -not (
            Test-SyntheticByteArrayEqual `
                -Left $result.StandardOutputBytes `
                -Right $expectedOutput
        )
    ) {
        Add-Failure (
            'synthetic Git hostile-environment child result was not exact ' +
            (
                '(exit={0}, stdout-bytes={1}, stderr-bytes={2})' -f
                    $result.ExitCode,
                    $result.StandardOutputBytes.Length,
                    $result.StandardErrorBytes.Length
            )
        )
        return $false
    }
    return $true
}

function Initialize-SyntheticBaselineRepository {
    param(
        [object]$Context,
        [string]$ArtifactPath,
        [string]$InitialContent = "pre-existing`n"
    )

    Invoke-SyntheticGit `
        -Context $Context `
        -Arguments @('init', '--quiet') |
        Out-Null
    Invoke-SyntheticGit `
        -Context $Context `
        -Arguments @('config', 'user.name', 'Synthetic Fixture') |
        Out-Null
    Invoke-SyntheticGit `
        -Context $Context `
        -Arguments @('config', 'user.email', 'fixture.invalid') |
        Out-Null
    Write-SyntheticUtf8Text `
        -Path (Join-Path $Context.RepositoryPath $ArtifactPath) `
        -Content $InitialContent
    Invoke-SyntheticGit `
        -Context $Context `
        -Arguments @('add', '--', $ArtifactPath) |
        Out-Null
    Invoke-SyntheticGit `
        -Context $Context `
        -Arguments @(
            'commit',
            '--quiet',
            '--no-verify',
            '-m',
            'fixture H0'
        ) |
        Out-Null
}

function Remove-SyntheticFixtureDirectory {
    param([string]$DirectoryPath)

    if (-not [System.IO.Directory]::Exists($DirectoryPath)) {
        return
    }

    # Git for Windowsはloose objectをread-onlyで作る。合成fixture配下の
    # 既知fileだけをnormalへ戻してから、生成したrootを1回で削除する。
    foreach (
        $filePath in [System.IO.Directory]::GetFiles(
            $DirectoryPath,
            '*',
            [System.IO.SearchOption]::AllDirectories
        )
    ) {
        [System.IO.File]::SetAttributes(
            $filePath,
            [System.IO.FileAttributes]::Normal
        )
    }
    [System.IO.Directory]::Delete($DirectoryPath, $true)
}

function Assert-BaselineAwareCompletionSemanticFixtures {
    $tempBase = [System.IO.Path]::GetTempPath()
    $fixtureRoot = [System.IO.Path]::Combine(
        $tempBase,
        'multi-agent-delegation-completion-' +
            [System.Guid]::NewGuid().ToString('N')
    )
    $hostileRoot = $fixtureRoot + '-hostile'
    $controlRoot = Join-Path $fixtureRoot 'git-controls'
    $mainRoot = Join-Path $fixtureRoot 'main'
    $nonGitRoot = Join-Path $fixtureRoot 'non-git'
    $artifactPath = 'evidence.txt'
    $unassignedPath = 'owner-wip.txt'
    $semanticStage = 'setup'

    try {
        [System.IO.Directory]::CreateDirectory($fixtureRoot) | Out-Null
        [System.IO.Directory]::CreateDirectory($hostileRoot) | Out-Null
        [System.IO.Directory]::CreateDirectory($controlRoot) | Out-Null
        [System.IO.Directory]::CreateDirectory($mainRoot) | Out-Null
        Initialize-SyntheticGitControlRoot -SafeRoot $controlRoot
        $gitExecutable = Resolve-SyntheticGitExecutable
        $mainContext = New-SyntheticGitContext `
            -RepositoryPath $mainRoot `
            -SafeRoot $controlRoot `
            -GitExecutablePath $gitExecutable

        # H0には受け入れ条件と同名のartifactを先に置き、no-opを実在だけで
        # 成功扱いできないcaseを作る。
        Initialize-SyntheticBaselineRepository `
            -Context $mainContext `
            -ArtifactPath $artifactPath

        $noOpInitial = Get-SyntheticCompletionSnapshot `
            -Context $mainContext `
            -ArtifactPaths @($artifactPath)
        $noOpFinal = Get-SyntheticCompletionSnapshot `
            -Context $mainContext `
            -ArtifactPaths @($artifactPath)
        $noOpPaths = Get-SyntheticCommittedPaths `
            -Context $mainContext `
            -BaselineHead $noOpInitial.Head `
            -FinalHead $noOpFinal.Head
        $noOpAncestor = Test-SyntheticBaselineIsAncestor `
            -Context $mainContext `
            -BaselineHead $noOpInitial.Head `
            -FinalHead $noOpFinal.Head
        if (
            Test-BaselineAwareCompletionDecision `
                -Initial $noOpInitial `
                -Final $noOpFinal `
                -CommittedPaths $noOpPaths `
                -AssignedPaths @($artifactPath) `
                -BaselineIsAncestor $noOpAncestor `
                -AcceptanceSatisfied $true
        ) {
            Add-Failure (
                'baseline completion fixture accepts unchanged ' +
                'pre-existing artifact'
            )
        }

        $semanticStage = 'main-acceptance'
        # 成果物に差分があっても受け入れ条件が偽なら完了にしない。
        $rejectedArtifact = Get-SyntheticArtifactState `
            -RepositoryPath $mainRoot `
            -RelativePath $artifactPath
        Write-SyntheticUtf8Text `
            -Path (Join-Path $mainRoot $artifactPath) `
            -Content "acceptance rejected`n"
        $rejectedArtifactFinal = Get-SyntheticArtifactState `
            -RepositoryPath $mainRoot `
            -RelativePath $artifactPath
        if (
            Test-NonGitArtifactCompletionDecision `
                -Initial $rejectedArtifact `
                -Final $rejectedArtifactFinal `
                -AcceptanceSatisfied $false
        ) {
            Add-Failure (
                'baseline completion fixture ignores failed acceptance'
            )
        }
        Write-SyntheticUtf8Text `
            -Path (Join-Path $mainRoot $artifactPath) `
            -Content "pre-existing`n"

        $semanticStage = 'main-commit'
        # H0から期待pathだけをC1へcommitし、final porcelainが空でも成功する
        # committed-delta caseを作る。
        Write-SyntheticUtf8Text `
            -Path (Join-Path $mainRoot $artifactPath) `
            -Content "accepted C1`n"
        Invoke-SyntheticGit `
            -Context $mainContext `
            -Arguments @('add', '--', $artifactPath) | Out-Null
        Invoke-SyntheticGit `
            -Context $mainContext `
            -Arguments @(
                'commit',
                '--quiet',
                '--no-verify',
                '-m',
                'fixture C1'
            ) |
            Out-Null
        $commitFinal = Get-SyntheticCompletionSnapshot `
            -Context $mainContext `
            -ArtifactPaths @($artifactPath)
        $commitPaths = Get-SyntheticCommittedPaths `
            -Context $mainContext `
            -BaselineHead $noOpInitial.Head `
            -FinalHead $commitFinal.Head
        $commitAncestor = Test-SyntheticBaselineIsAncestor `
            -Context $mainContext `
            -BaselineHead $noOpInitial.Head `
            -FinalHead $commitFinal.Head
        if (
            -not (
                Test-BaselineAwareCompletionDecision `
                    -Initial $noOpInitial `
                    -Final $commitFinal `
                    -CommittedPaths $commitPaths `
                    -AssignedPaths @($artifactPath) `
                    -BaselineIsAncestor $commitAncestor `
                    -AcceptanceSatisfied $true
            )
        ) {
            Add-Failure (
                'baseline completion fixture rejects clean committed delta'
            )
        }
        if (
            Test-BaselineAwareCompletionDecision `
                -Initial $noOpInitial `
                -Final $commitFinal `
                -CommittedPaths $commitPaths `
                -AssignedPaths @($artifactPath) `
                -BaselineIsAncestor $commitAncestor `
                -AcceptanceSatisfied $false
        ) {
            Add-Failure (
                'baseline completion fixture accepts failed Git acceptance'
            )
        }

        $semanticStage = 'dirty-resume'
        # 同一threadのassigned dirty resumeでは、porcelain pathが同じままでも
        # artifact digestのinitial→final変化を証拠にする。
        Write-SyntheticUtf8Text `
            -Path (Join-Path $mainRoot $artifactPath) `
            -Content "assigned draft 1`n"
        $dirtyInitial = Get-SyntheticCompletionSnapshot `
            -Context $mainContext `
            -ArtifactPaths @($artifactPath)
        Write-SyntheticUtf8Text `
            -Path (Join-Path $mainRoot $artifactPath) `
            -Content "assigned draft 2`n"
        $dirtyFinal = Get-SyntheticCompletionSnapshot `
            -Context $mainContext `
            -ArtifactPaths @($artifactPath)
        $dirtyPaths = Get-SyntheticCommittedPaths `
            -Context $mainContext `
            -BaselineHead $dirtyInitial.Head `
            -FinalHead $dirtyFinal.Head
        $dirtyAncestor = Test-SyntheticBaselineIsAncestor `
            -Context $mainContext `
            -BaselineHead $dirtyInitial.Head `
            -FinalHead $dirtyFinal.Head
        if (
            -not (
                Test-BaselineAwareCompletionDecision `
                    -Initial $dirtyInitial `
                    -Final $dirtyFinal `
                    -CommittedPaths $dirtyPaths `
                    -AssignedPaths @($artifactPath) `
                    -BaselineIsAncestor $dirtyAncestor `
                    -AcceptanceSatisfied $true
            )
        ) {
            Add-Failure (
                'baseline completion fixture rejects assigned dirty delta'
            )
        }

        $semanticStage = 'scope-commit'
        # scope guardの3入力を別repositoryへ分け、1 guardだけで他2件が
        # 偶然GREENになることを防ぐ。
        $scopeCommitRoot = Join-Path $fixtureRoot 'scope-commit'
        [System.IO.Directory]::CreateDirectory($scopeCommitRoot) | Out-Null
        $scopeCommitContext = New-SyntheticGitContext `
            -RepositoryPath $scopeCommitRoot `
            -SafeRoot $controlRoot `
            -GitExecutablePath $gitExecutable
        Initialize-SyntheticBaselineRepository `
            -Context $scopeCommitContext `
            -ArtifactPath $artifactPath
        $scopeCommitInitial = Get-SyntheticCompletionSnapshot `
            -Context $scopeCommitContext `
            -ArtifactPaths @($artifactPath)
        Write-SyntheticUtf8Text `
            -Path (Join-Path $scopeCommitRoot $artifactPath) `
            -Content "assigned commit delta`n"
        Write-SyntheticUtf8Text `
            -Path (Join-Path $scopeCommitRoot $unassignedPath) `
            -Content "unassigned commit delta`n"
        Invoke-SyntheticGit `
            -Context $scopeCommitContext `
            -Arguments @('add', '--', $artifactPath, $unassignedPath) |
            Out-Null
        Invoke-SyntheticGit `
            -Context $scopeCommitContext `
            -Arguments @(
                'commit',
                '--quiet',
                '--no-verify',
                '-m',
                'fixture unassigned commit'
            ) |
            Out-Null
        $scopeCommitFinal = Get-SyntheticCompletionSnapshot `
            -Context $scopeCommitContext `
            -ArtifactPaths @($artifactPath)
        $scopeCommitPaths = Get-SyntheticCommittedPaths `
            -Context $scopeCommitContext `
            -BaselineHead $scopeCommitInitial.Head `
            -FinalHead $scopeCommitFinal.Head
        $scopeCommitAncestor = Test-SyntheticBaselineIsAncestor `
            -Context $scopeCommitContext `
            -BaselineHead $scopeCommitInitial.Head `
            -FinalHead $scopeCommitFinal.Head
        if (
            Test-BaselineAwareCompletionDecision `
                -Initial $scopeCommitInitial `
                -Final $scopeCommitFinal `
                -CommittedPaths $scopeCommitPaths `
                -AssignedPaths @($artifactPath) `
                -BaselineIsAncestor $scopeCommitAncestor `
                -AcceptanceSatisfied $true
        ) {
            Add-Failure (
                'baseline completion fixture accepts unassigned committed path'
            )
        }

        $semanticStage = 'scope-final'
        $scopeFinalRoot = Join-Path $fixtureRoot 'scope-final'
        [System.IO.Directory]::CreateDirectory($scopeFinalRoot) | Out-Null
        $scopeFinalContext = New-SyntheticGitContext `
            -RepositoryPath $scopeFinalRoot `
            -SafeRoot $controlRoot `
            -GitExecutablePath $gitExecutable
        Initialize-SyntheticBaselineRepository `
            -Context $scopeFinalContext `
            -ArtifactPath $artifactPath
        $scopeFinalInitial = Get-SyntheticCompletionSnapshot `
            -Context $scopeFinalContext `
            -ArtifactPaths @($artifactPath)
        Write-SyntheticUtf8Text `
            -Path (Join-Path $scopeFinalRoot $artifactPath) `
            -Content "assigned final delta`n"
        Invoke-SyntheticGit `
            -Context $scopeFinalContext `
            -Arguments @('add', '--', $artifactPath) |
            Out-Null
        Invoke-SyntheticGit `
            -Context $scopeFinalContext `
            -Arguments @(
                'commit',
                '--quiet',
                '--no-verify',
                '-m',
                'fixture assigned final'
            ) |
            Out-Null
        Write-SyntheticUtf8Text `
            -Path (Join-Path $scopeFinalRoot $unassignedPath) `
            -Content "unassigned final porcelain`n"
        $scopeFinalOnly = Get-SyntheticCompletionSnapshot `
            -Context $scopeFinalContext `
            -ArtifactPaths @($artifactPath)
        $scopeFinalPaths = Get-SyntheticCommittedPaths `
            -Context $scopeFinalContext `
            -BaselineHead $scopeFinalInitial.Head `
            -FinalHead $scopeFinalOnly.Head
        $scopeFinalAncestor = Test-SyntheticBaselineIsAncestor `
            -Context $scopeFinalContext `
            -BaselineHead $scopeFinalInitial.Head `
            -FinalHead $scopeFinalOnly.Head
        if (
            Test-BaselineAwareCompletionDecision `
                -Initial $scopeFinalInitial `
                -Final $scopeFinalOnly `
                -CommittedPaths $scopeFinalPaths `
                -AssignedPaths @($artifactPath) `
                -BaselineIsAncestor $scopeFinalAncestor `
                -AcceptanceSatisfied $true
        ) {
            Add-Failure (
                'baseline completion fixture accepts unassigned final porcelain'
            )
        }

        $semanticStage = 'scope-initial'
        $scopeInitialRoot = Join-Path $fixtureRoot 'scope-initial'
        [System.IO.Directory]::CreateDirectory($scopeInitialRoot) | Out-Null
        $scopeInitialContext = New-SyntheticGitContext `
            -RepositoryPath $scopeInitialRoot `
            -SafeRoot $controlRoot `
            -GitExecutablePath $gitExecutable
        Initialize-SyntheticBaselineRepository `
            -Context $scopeInitialContext `
            -ArtifactPath $artifactPath
        $initialOnlyPath = Join-Path $scopeInitialRoot $unassignedPath
        Write-SyntheticUtf8Text `
            -Path $initialOnlyPath `
            -Content "unassigned initial porcelain`n"
        $scopeInitialOnly = Get-SyntheticCompletionSnapshot `
            -Context $scopeInitialContext `
            -ArtifactPaths @($artifactPath)
        # controlled fixture setup removes the synthetic unassigned file so
        # only the initial-porcelain guard can reject the final decision.
        [System.IO.File]::Delete($initialOnlyPath)
        Write-SyntheticUtf8Text `
            -Path (Join-Path $scopeInitialRoot $artifactPath) `
            -Content "assigned initial delta`n"
        Invoke-SyntheticGit `
            -Context $scopeInitialContext `
            -Arguments @('add', '--', $artifactPath) |
            Out-Null
        Invoke-SyntheticGit `
            -Context $scopeInitialContext `
            -Arguments @(
                'commit',
                '--quiet',
                '--no-verify',
                '-m',
                'fixture assigned initial'
            ) |
            Out-Null
        $scopeInitialFinal = Get-SyntheticCompletionSnapshot `
            -Context $scopeInitialContext `
            -ArtifactPaths @($artifactPath)
        $scopeInitialPaths = Get-SyntheticCommittedPaths `
            -Context $scopeInitialContext `
            -BaselineHead $scopeInitialOnly.Head `
            -FinalHead $scopeInitialFinal.Head
        $scopeInitialAncestor = Test-SyntheticBaselineIsAncestor `
            -Context $scopeInitialContext `
            -BaselineHead $scopeInitialOnly.Head `
            -FinalHead $scopeInitialFinal.Head
        if (
            Test-BaselineAwareCompletionDecision `
                -Initial $scopeInitialOnly `
                -Final $scopeInitialFinal `
                -CommittedPaths $scopeInitialPaths `
                -AssignedPaths @($artifactPath) `
                -BaselineIsAncestor $scopeInitialAncestor `
                -AcceptanceSatisfied $true
        ) {
            Add-Failure (
                'baseline completion fixture accepts unassigned initial porcelain'
            )
        }

        $semanticStage = 'divergent-history'
        $divergentRoot = Join-Path $fixtureRoot 'divergent-history'
        [System.IO.Directory]::CreateDirectory($divergentRoot) | Out-Null
        $divergentContext = New-SyntheticGitContext `
            -RepositoryPath $divergentRoot `
            -SafeRoot $controlRoot `
            -GitExecutablePath $gitExecutable
        Initialize-SyntheticBaselineRepository `
            -Context $divergentContext `
            -ArtifactPath $artifactPath `
            -InitialContent "parent P0`n"
        Write-SyntheticUtf8Text `
            -Path (Join-Path $divergentRoot $artifactPath) `
            -Content "baseline H0`n"
        Invoke-SyntheticGit `
            -Context $divergentContext `
            -Arguments @('add', '--', $artifactPath) |
            Out-Null
        Invoke-SyntheticGit `
            -Context $divergentContext `
            -Arguments @(
                'commit',
                '--quiet',
                '--no-verify',
                '-m',
                'fixture baseline H0'
            ) |
            Out-Null
        $divergentInitial = Get-SyntheticCompletionSnapshot `
            -Context $divergentContext `
            -ArtifactPaths @($artifactPath)
        Write-SyntheticUtf8Text `
            -Path (Join-Path $divergentRoot $artifactPath) `
            -Content "discarded forward C1`n"
        Invoke-SyntheticGit `
            -Context $divergentContext `
            -Arguments @('add', '--', $artifactPath) |
            Out-Null
        Invoke-SyntheticGit `
            -Context $divergentContext `
            -Arguments @(
                'commit',
                '--quiet',
                '--no-verify',
                '-m',
                'fixture discarded C1'
            ) |
            Out-Null
        $divergentParent = @(
            Invoke-SyntheticGit `
                -Context $divergentContext `
                -Arguments @(
                    'rev-parse',
                    '--verify',
                    ($divergentInitial.Head + '^')
                )
        ) -join "`n"
        $historySentinelPath = Join-Path `
            $hostileRoot `
            'divergent-history.sentinel'
        Write-SyntheticUtf8Text `
            -Path $historySentinelPath `
            -Content "external history sentinel`n"
        $historySentinelBefore = Get-SyntheticArtifactState `
            -RepositoryPath $hostileRoot `
            -RelativePath 'divergent-history.sentinel'

        # synthetic branchだけをP0へrewindし、同名branchにassigned-only C2を作る。
        # このreset自体が完了契約で拒否すべきhistory破壊caseである。
        Invoke-SyntheticGit `
            -Context $divergentContext `
            -Arguments @('reset', '--hard', '--quiet', $divergentParent) |
            Out-Null
        Write-SyntheticUtf8Text `
            -Path (Join-Path $divergentRoot $artifactPath) `
            -Content "divergent assigned C2`n"
        Invoke-SyntheticGit `
            -Context $divergentContext `
            -Arguments @('add', '--', $artifactPath) |
            Out-Null
        Invoke-SyntheticGit `
            -Context $divergentContext `
            -Arguments @(
                'commit',
                '--quiet',
                '--no-verify',
                '-m',
                'fixture divergent C2'
            ) |
            Out-Null
        $divergentFinal = Get-SyntheticCompletionSnapshot `
            -Context $divergentContext `
            -ArtifactPaths @($artifactPath)
        $divergentPaths = Get-SyntheticCommittedPaths `
            -Context $divergentContext `
            -BaselineHead $divergentInitial.Head `
            -FinalHead $divergentFinal.Head
        $divergentAncestor = Test-SyntheticBaselineIsAncestor `
            -Context $divergentContext `
            -BaselineHead $divergentInitial.Head `
            -FinalHead $divergentFinal.Head
        $historySentinelAfter = Get-SyntheticArtifactState `
            -RepositoryPath $hostileRoot `
            -RelativePath 'divergent-history.sentinel'
        if ($divergentAncestor) {
            Add-Failure (
                'baseline completion fixture failed to create divergent history'
            )
        }
        if (
            -not (
                Test-BaselineAwareCompletionDecision `
                    -Initial $divergentInitial `
                    -Final $divergentFinal `
                    -CommittedPaths $divergentPaths `
                    -AssignedPaths @($artifactPath) `
                    -BaselineIsAncestor $true `
                    -AcceptanceSatisfied $true
            )
        ) {
            Add-Failure (
                'divergent fixture did not isolate the ancestry guard'
            )
        }
        if (
            Test-BaselineAwareCompletionDecision `
                -Initial $divergentInitial `
                -Final $divergentFinal `
                -CommittedPaths $divergentPaths `
                -AssignedPaths @($artifactPath) `
                -BaselineIsAncestor $divergentAncestor `
                -AcceptanceSatisfied $true
        ) {
            Add-Failure (
                'baseline completion fixture accepts divergent history'
            )
        }
        if (
            Test-SyntheticArtifactChanged `
                -Initial $historySentinelBefore `
                -Final $historySentinelAfter
        ) {
            Add-Failure (
                'divergent history fixture changed external sentinel'
            )
        }

        $semanticStage = 'hermetic-setup'
        # ambient redirectとglobal filterを別PowerShell childへだけ注入し、
        # hermetic Git childが外部index/object sentinelを変更しないと証明する。
        $hermeticRoot = Join-Path $fixtureRoot 'hermetic'
        $externalBareRoot = Join-Path $hostileRoot 'external-bare.git'
        [System.IO.Directory]::CreateDirectory($hermeticRoot) | Out-Null
        [System.IO.Directory]::CreateDirectory($externalBareRoot) | Out-Null
        $hermeticContext = New-SyntheticGitContext `
            -RepositoryPath $hermeticRoot `
            -SafeRoot $controlRoot `
            -GitExecutablePath $gitExecutable
        $externalBareContext = New-SyntheticGitContext `
            -RepositoryPath $externalBareRoot `
            -SafeRoot $controlRoot `
            -GitExecutablePath $gitExecutable
        Invoke-SyntheticGit `
            -Context $hermeticContext `
            -Arguments @('init', '--quiet') |
            Out-Null
        Invoke-SyntheticGit `
            -Context $externalBareContext `
            -Arguments @('init', '--bare', '--quiet') |
            Out-Null
        Write-SyntheticUtf8Text `
            -Path (Join-Path $hermeticRoot '.gitattributes') `
            -Content "*.txt filter=sentinel`n"
        Write-SyntheticUtf8Text `
            -Path (Join-Path $hermeticRoot $artifactPath) `
            -Content "hermetic redirect probe`n"

        $hostileIndexPath = Join-Path $hostileRoot 'redirect-index.sentinel'
        Write-SyntheticUtf8Text `
            -Path $hostileIndexPath `
            -Content "external index sentinel`n"
        $redirectIndexBefore = Get-SyntheticArtifactState `
            -RepositoryPath $hostileRoot `
            -RelativePath 'redirect-index.sentinel'
        $redirectBareBefore = Get-SyntheticDirectoryState `
            -DirectoryPath $externalBareRoot
        $semanticStage = 'hermetic-powershell-resolve'
        $powerShellPath = Resolve-SyntheticPowerShellExecutable
        $semanticStage = 'hermetic-redirect-environment'
        $redirectEnvironment = New-SyntheticProbeHarnessEnvironment `
            -HarnessRoot (Join-Path $hostileRoot 'redirect-harness') `
            -PowerShellPath $powerShellPath `
            -GitPath $gitExecutable
        $redirectEnvironment['GIT_DIR'] = $externalBareRoot
        $redirectEnvironment['GIT_WORK_TREE'] = $hermeticRoot
        $redirectEnvironment['GIT_INDEX_FILE'] = $hostileIndexPath
        $semanticStage = 'hermetic-redirect-child'
        $redirectPassed = Invoke-SyntheticHermeticChildProbe `
            -Context $hermeticContext `
            -HarnessEnvironment $redirectEnvironment
        $semanticStage = 'hermetic-redirect-verify'
        $redirectIndexAfter = Get-SyntheticArtifactState `
            -RepositoryPath $hostileRoot `
            -RelativePath 'redirect-index.sentinel'
        $redirectBareAfter = Get-SyntheticDirectoryState `
            -DirectoryPath $externalBareRoot
        if (
            -not $redirectPassed -or
            (Test-SyntheticArtifactChanged `
                -Initial $redirectIndexBefore `
                -Final $redirectIndexAfter) -or
            -not (
                Test-SyntheticDirectoryStateEqual `
                    -Left $redirectBareBefore `
                    -Right $redirectBareAfter
            )
        ) {
            Add-Failure (
                'synthetic Git inherited redirect environment or changed sentinel'
            )
        }

        $semanticStage = 'hermetic-filter'
        Write-SyntheticUtf8Text `
            -Path (Join-Path $hermeticRoot $artifactPath) `
            -Content "hermetic filter probe`n"
        $hostileConfig = Join-Path $hostileRoot 'hostile.config'
        Write-SyntheticUtf8Text -Path $hostileConfig -Content ''
        $gitForShell = $gitExecutable.Replace('\', '/')
        $bareForShell = $externalBareRoot.Replace('\', '/')
        $filterCommand = (
            '"' + $gitForShell + '" --git-dir="' +
            $bareForShell + '" hash-object -w --stdin'
        )
        foreach ($configEntry in @(
            @('filter.sentinel.clean', $filterCommand),
            @('filter.sentinel.required', 'true'),
            @('commit.gpgsign', 'true')
        )) {
            Invoke-SyntheticGit `
                -Context $hermeticContext `
                -Arguments @(
                    'config',
                    '--file',
                    $hostileConfig,
                    $configEntry[0],
                    $configEntry[1]
                ) |
                Out-Null
        }
        $filterBareBefore = Get-SyntheticDirectoryState `
            -DirectoryPath $externalBareRoot
        $hostileConfigBefore = Get-SyntheticArtifactState `
            -RepositoryPath $hostileRoot `
            -RelativePath 'hostile.config'
        $filterEnvironment = New-SyntheticProbeHarnessEnvironment `
            -HarnessRoot (Join-Path $hostileRoot 'filter-harness') `
            -PowerShellPath $powerShellPath `
            -GitPath $gitExecutable
        $filterEnvironment['GIT_CONFIG_GLOBAL'] = $hostileConfig
        $filterEnvironment['GIT_CONFIG_SYSTEM'] = $hostileConfig
        $filterEnvironment['GIT_CONFIG_NOSYSTEM'] = '0'
        $filterEnvironment['GIT_CONFIG_COUNT'] = '3'
        $filterEnvironment['GIT_CONFIG_KEY_0'] = 'filter.sentinel.clean'
        $filterEnvironment['GIT_CONFIG_VALUE_0'] = $filterCommand
        $filterEnvironment['GIT_CONFIG_KEY_1'] = 'filter.sentinel.required'
        $filterEnvironment['GIT_CONFIG_VALUE_1'] = 'true'
        $filterEnvironment['GIT_CONFIG_KEY_2'] = 'commit.gpgsign'
        $filterEnvironment['GIT_CONFIG_VALUE_2'] = 'true'
        $filterPassed = Invoke-SyntheticHermeticChildProbe `
            -Context $hermeticContext `
            -HarnessEnvironment $filterEnvironment
        $filterBareAfter = Get-SyntheticDirectoryState `
            -DirectoryPath $externalBareRoot
        $hostileConfigAfter = Get-SyntheticArtifactState `
            -RepositoryPath $hostileRoot `
            -RelativePath 'hostile.config'
        if (
            -not $filterPassed -or
            -not (
                Test-SyntheticDirectoryStateEqual `
                    -Left $filterBareBefore `
                    -Right $filterBareAfter
            ) -or
            (Test-SyntheticArtifactChanged `
                -Initial $hostileConfigBefore `
                -Final $hostileConfigAfter)
        ) {
            Add-Failure (
                'synthetic Git inherited hostile config or executed filter'
            )
        }

        $semanticStage = 'non-git'
        # Git repository外のsiblingを使い、Git証拠に依存しない成果物へも
        # 同じ存在・size・SHA-256契約を適用する。
        [System.IO.Directory]::CreateDirectory($nonGitRoot) | Out-Null
        Write-SyntheticUtf8Text `
            -Path (Join-Path $nonGitRoot $artifactPath) `
            -Content "non-git pre-existing`n"
        $nonGitInitial = Get-SyntheticArtifactState `
            -RepositoryPath $nonGitRoot `
            -RelativePath $artifactPath
        $nonGitNoOp = Get-SyntheticArtifactState `
            -RepositoryPath $nonGitRoot `
            -RelativePath $artifactPath
        if (
            Test-NonGitArtifactCompletionDecision `
                -Initial $nonGitInitial `
                -Final $nonGitNoOp `
                -AcceptanceSatisfied $true
        ) {
            Add-Failure (
                'baseline completion fixture accepts non-Git no-op'
            )
        }
        Write-SyntheticUtf8Text `
            -Path (Join-Path $nonGitRoot $artifactPath) `
            -Content "non-git accepted`n"
        $nonGitFinal = Get-SyntheticArtifactState `
            -RepositoryPath $nonGitRoot `
            -RelativePath $artifactPath
        if (
            -not (
                Test-NonGitArtifactCompletionDecision `
                    -Initial $nonGitInitial `
                    -Final $nonGitFinal `
                    -AcceptanceSatisfied $true
            )
        ) {
            Add-Failure (
                'baseline completion fixture rejects non-Git artifact delta'
            )
        }
    }
    catch {
        # temp pathやnative stderrを公開validatorの診断へ流さない。
        Add-Failure (
            'baseline completion semantic fixture failed closed: ' +
            $semanticStage
        )
    }
    finally {
        foreach ($syntheticRoot in @($fixtureRoot, $hostileRoot)) {
            if ([System.IO.Directory]::Exists($syntheticRoot)) {
                try {
                    Remove-SyntheticFixtureDirectory `
                        -DirectoryPath $syntheticRoot
                }
                catch {
                    Add-Failure (
                        'baseline completion semantic fixture cleanup failed'
                    )
                }
            }
        }
    }
}

function Test-WindowsHandleProbeLoopContract {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.ForStatementAst]$Loop,
        [Parameter(Mandatory = $true)]
        [string]$CounterName,
        [Parameter(Mandatory = $true)]
        [string]$LimitName,
        [Parameter(Mandatory = $true)]
        [string]$ResultName,
        [Parameter(Mandatory = $true)]
        [string]$FinalName,
        [Parameter(Mandatory = $true)]
        [string]$MaximumName,
        [Parameter(Mandatory = $true)]
        [string]$ChildFailureCode
    )

    # 反復回数の変数名だけでなく、0初期化とpostfix incrementをASTで固定する。
    # これにより、header文字列を保ったまま0回実行へ変える退行を拒否する。
    $initializer = $Loop.Initializer
    if (
        $initializer -isnot
            [System.Management.Automation.Language.AssignmentStatementAst] -or
        $initializer.Operator -ne
            [System.Management.Automation.Language.TokenKind]::Equals -or
        $initializer.Left -isnot
            [System.Management.Automation.Language.VariableExpressionAst] -or
        -not $initializer.Left.VariablePath.IsUnqualified -or
        -not [string]::Equals(
            $initializer.Left.VariablePath.UserPath,
            $CounterName,
            [System.StringComparison]::Ordinal
        ) -or
        $initializer.Right -isnot
            [System.Management.Automation.Language.CommandExpressionAst] -or
        $initializer.Right.Expression -isnot
            [System.Management.Automation.Language.ConstantExpressionAst] -or
        $initializer.Right.Expression.Value -ne 0
    ) {
        return $false
    }

    $conditionContract = (
        '^\s*\$' +
        [regex]::Escape($CounterName) +
        '\s*-lt\s*\$' +
        [regex]::Escape($LimitName) +
        '\s*$'
    )
    if ($Loop.Condition.Extent.Text -notmatch $conditionContract) {
        return $false
    }

    $iterator = $Loop.Iterator
    if (
        $iterator -isnot
            [System.Management.Automation.Language.PipelineAst] -or
        $iterator.PipelineElements.Count -ne 1 -or
        $iterator.PipelineElements[0] -isnot
            [System.Management.Automation.Language.CommandExpressionAst] -or
        $iterator.PipelineElements[0].Expression -isnot
            [System.Management.Automation.Language.UnaryExpressionAst] -or
        $iterator.PipelineElements[0].Expression.TokenKind -ne
            [System.Management.Automation.Language.TokenKind]::PostfixPlusPlus -or
        $iterator.PipelineElements[0].Expression.Child -isnot
            [System.Management.Automation.Language.VariableExpressionAst] -or
        -not (
            $iterator.PipelineElements[0].
                Expression.Child.VariablePath.IsUnqualified
        ) -or
        -not [string]::Equals(
            $iterator.PipelineElements[0].
                Expression.Child.VariablePath.UserPath,
            $CounterName,
            [System.StringComparison]::Ordinal
        )
    ) {
        return $false
    }

    # bodyは5個の直下statementに限定する。runnerやhandle更新がif/try等の
    # 到達不能な子scopeへ包まれても、descendant検索ではpositiveにしない。
    $statements = @($Loop.Body.Statements)
    if (
        $statements.Count -ne 5 -or
        $statements[0] -isnot
            [System.Management.Automation.Language.AssignmentStatementAst] -or
        $statements[1] -isnot
            [System.Management.Automation.Language.IfStatementAst] -or
        $statements[2] -isnot
            [System.Management.Automation.Language.PipelineAst] -or
        $statements[3] -isnot
            [System.Management.Automation.Language.AssignmentStatementAst] -or
        $statements[4] -isnot
            [System.Management.Automation.Language.AssignmentStatementAst]
    ) {
        return $false
    }

    # 各statementを全体一致させ、子process検証を飛ばすcontinue/returnや、
    # handle取得順の入替えも契約違反として検出する。
    $runnerContract = (
        '(?s)^\s*\$' +
        [regex]::Escape($ResultName) +
        '\s*=\s*private-marker-process-runner\\' +
        'Invoke-PrivateMarkerBoundedProcess\b.*$'
    )
    $childGuardContract = (
        '(?s)^\s*if\s*\(\s*' +
        '\$' + [regex]::Escape($ResultName) +
        '\.ExitCode\s*-ne\s*0\s*-or\s*' +
        '\$' + [regex]::Escape($ResultName) +
        '\.StandardOutputBytes\.Length\s*-ne\s*0\s*-or\s*' +
        '\$' + [regex]::Escape($ResultName) +
        '\.StandardErrorBytes\.Length\s*-ne\s*0\s*' +
        '\)\s*\{\s*throw\s+''' +
        [regex]::Escape($ChildFailureCode) +
        '''\s*\}\s*$'
    )
    $refreshContract = '^\s*\$handleProbeProcess\.Refresh\(\)\s*$'
    $finalContract = (
        '^\s*\$' +
        [regex]::Escape($FinalName) +
        '\s*=\s*\$handleProbeProcess\.HandleCount\s*$'
    )
    $maximumContract = (
        '(?s)^\s*\$' +
        [regex]::Escape($MaximumName) +
        '\s*=\s*\[Math\]::Max\(\s*\$' +
        [regex]::Escape($MaximumName) +
        '\s*,\s*\$' +
        [regex]::Escape($FinalName) +
        '\s*\)\s*$'
    )
    return (
        $statements[0].Extent.Text -match $runnerContract -and
        $statements[1].Extent.Text -match $childGuardContract -and
        $statements[2].Extent.Text -match $refreshContract -and
        $statements[3].Extent.Text -match $finalContract -and
        $statements[4].Extent.Text -match $maximumContract
    )
}

function Test-WindowsHandleQuiescenceLoopContract {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.ForStatementAst]$Loop,
        [Parameter(Mandatory = $true)]
        [string]$CounterName,
        [Parameter(Mandatory = $true)]
        [string]$SampleName,
        [Parameter(Mandatory = $true)]
        [string]$SettledName
    )

    # sample回数を0へ迂回したり、Sleep/Refresh/min更新を条件分岐へ隠したり
    # できないよう、headerと4つの直下statementをAST extentで全体一致する。
    if (
        $Loop.Initializer.Extent.Text -notmatch (
            '^\s*\$' +
            [regex]::Escape($CounterName) +
            '\s*=\s*0\s*$'
        ) -or
        $Loop.Condition.Extent.Text -notmatch (
            '^\s*\$' +
            [regex]::Escape($CounterName) +
            '\s*-lt\s*\$handleQuiescenceSamples\s*$'
        ) -or
        $Loop.Iterator.Extent.Text -notmatch (
            '^\s*\$' +
            [regex]::Escape($CounterName) +
            '\+\+\s*$'
        )
    ) {
        return $false
    }

    $statements = @($Loop.Body.Statements)
    if (
        $statements.Count -ne 4 -or
        $statements[0] -isnot
            [System.Management.Automation.Language.PipelineAst] -or
        $statements[1] -isnot
            [System.Management.Automation.Language.PipelineAst] -or
        $statements[2] -isnot
            [System.Management.Automation.Language.AssignmentStatementAst] -or
        $statements[3] -isnot
            [System.Management.Automation.Language.AssignmentStatementAst]
    ) {
        return $false
    }

    $sleepContract = (
        '(?s)^\s*\[System\.Threading\.Thread\]::Sleep\(\s*' +
        '\$handleQuiescenceWaitMilliseconds\s*\)\s*$'
    )
    $refreshContract = '^\s*\$handleProbeProcess\.Refresh\(\)\s*$'
    $sampleContract = (
        '^\s*\$' +
        [regex]::Escape($SampleName) +
        '\s*=\s*' +
        '\$handleProbeProcess\.HandleCount\s*$'
    )
    $minimumContract = (
        '(?s)^\s*\$' +
        [regex]::Escape($SettledName) +
        '\s*=\s*\[Math\]::Min\(\s*\$' +
        [regex]::Escape($SettledName) +
        '\s*,\s*\$' +
        [regex]::Escape($SampleName) +
        '\s*\)\s*$'
    )
    return (
        $statements[0].Extent.Text -match $sleepContract -and
        $statements[1].Extent.Text -match $refreshContract -and
        $statements[2].Extent.Text -match $sampleContract -and
        $statements[3].Extent.Text -match $minimumContract
    )
}

function Test-WindowsHandleCalibratedWindowsWithinLimits {
    param(
        [int]$StartupBaseline,
        [int]$WarmupObservedFinal,
        [int[]]$WarmupQuiescenceSamples,
        [int]$CalibrationObservedFinal,
        [int[]]$CalibrationQuiescenceSamples,
        [int]$MeasuredObservedFinal,
        [int[]]$MeasuredQuiescenceSamples,
        [int]$ConfirmationObservedFinal,
        [int[]]$ConfirmationQuiescenceSamples
    )

    # 各windowの一時peakではなく、同じbounded quiescenceで残った最小値を
    # 比較する。runtime handleが閉じた証拠を受理し、持続leakだけを残す。
    if (
        $WarmupQuiescenceSamples.Count -ne 10 -or
        $CalibrationQuiescenceSamples.Count -ne 10 -or
        $MeasuredQuiescenceSamples.Count -ne 10 -or
        $ConfirmationQuiescenceSamples.Count -ne 10
    ) {
        return $false
    }
    $warmupSettled = $WarmupObservedFinal
    foreach ($sample in $WarmupQuiescenceSamples) {
        $warmupSettled = [Math]::Min($warmupSettled, $sample)
    }
    $calibrationSettled = $CalibrationObservedFinal
    foreach ($sample in $CalibrationQuiescenceSamples) {
        $calibrationSettled = [Math]::Min(
            $calibrationSettled,
            $sample
        )
    }
    $measuredSettled = $MeasuredObservedFinal
    foreach ($sample in $MeasuredQuiescenceSamples) {
        $measuredSettled = [Math]::Min($measuredSettled, $sample)
    }
    $confirmationSettled = $ConfirmationObservedFinal
    foreach ($sample in $ConfirmationQuiescenceSamples) {
        $confirmationSettled = [Math]::Min(
            $confirmationSettled,
            $sample
        )
    }

    # startup limit 16を単独steady windowのabsolute capにも使う。その内側では
    # limit 4を両windowが超えた場合だけ継続増加として拒否する。
    return (
        ($warmupSettled - $StartupBaseline) -le 16 -and
        ($calibrationSettled - $StartupBaseline) -le 16 -and
        ($measuredSettled - $calibrationSettled) -le 16 -and
        ($confirmationSettled - $measuredSettled) -le 16 -and
        -not (
            ($measuredSettled - $calibrationSettled) -gt 4 -and
            ($confirmationSettled - $measuredSettled) -gt 4
        )
    )
}

function Test-WindowsHandleProbeAstContract {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source
    )

    # loop headerだけの正規表現では、runner呼出しをbody外へ移動または削除した
    # no-op実装を見抜けない。ASTで4つの実行windowと各quiescenceを特定し、
    # 必要な処理を直下statementとして所有することを検査する。
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput(
        $Source,
        [ref]$tokens,
        [ref]$parseErrors
    )
    if ($parseErrors.Count -ne 0) {
        return $false
    }

    # 専用probeはfunctionを定義しない。import後の同名local functionで
    # unqualified command resolutionをshadowする変異をsource全体で拒否する。
    $functionDefinitions = @(
        $ast.FindAll(
            {
                param($node)
                $node -is
                    [System.Management.Automation.Language.FunctionDefinitionAst]
            },
            $true
        )
    )
    if ($functionDefinitions.Count -ne 0) {
        return $false
    }

    $forStatements = @(
        $ast.FindAll(
            {
                param($node)
                $node -is [System.Management.Automation.Language.ForStatementAst]
            },
            $true
        )
    )
    $warmupLoops = @(
        $forStatements |
            Where-Object {
                $_.Condition.Extent.Text -match (
                    '^\s*\$handleWarmupAttempt\s*-lt\s*' +
                    '\$handleWarmupRuns\s*$'
                )
            }
    )
    $warmupQuiescenceLoops = @(
        $forStatements |
            Where-Object {
                $_.Condition.Extent.Text -match (
                    '^\s*\$handleWarmupQuiescenceAttempt\s*-lt\s*' +
                    '\$handleQuiescenceSamples\s*$'
                )
            }
    )
    $calibrationLoops = @(
        $forStatements |
            Where-Object {
                $_.Condition.Extent.Text -match (
                    '^\s*\$handleCalibrationAttempt\s*-lt\s*' +
                    '\$handleCalibrationRuns\s*$'
                )
            }
    )
    $calibrationQuiescenceLoops = @(
        $forStatements |
            Where-Object {
                $_.Condition.Extent.Text -match (
                    '^\s*\$handleCalibrationQuiescenceAttempt\s*-lt\s*' +
                    '\$handleQuiescenceSamples\s*$'
                )
            }
    )
    $measuredLoops = @(
        $forStatements |
            Where-Object {
                $_.Condition.Extent.Text -match (
                    '^\s*\$handleAttempt\s*-lt\s*' +
                    '\$handleMeasuredRuns\s*$'
                )
            }
    )
    $measuredQuiescenceLoops = @(
        $forStatements |
            Where-Object {
                $_.Condition.Extent.Text -match (
                    '^\s*\$handleMeasuredQuiescenceAttempt\s*-lt\s*' +
                    '\$handleQuiescenceSamples\s*$'
                )
            }
    )
    $confirmationLoops = @(
        $forStatements |
            Where-Object {
                $_.Condition.Extent.Text -match (
                    '^\s*\$handleConfirmationAttempt\s*-lt\s*' +
                    '\$handleConfirmationRuns\s*$'
                )
            }
    )
    $confirmationQuiescenceLoops = @(
        $forStatements |
            Where-Object {
                $_.Condition.Extent.Text -match (
                    '^\s*\$handleConfirmationQuiescenceAttempt\s*-lt\s*' +
                    '\$handleQuiescenceSamples\s*$'
                )
            }
    )
    if (
        $forStatements.Count -ne 8 -or
        $warmupLoops.Count -ne 1 -or
        $warmupQuiescenceLoops.Count -ne 1 -or
        $calibrationLoops.Count -ne 1 -or
        $calibrationQuiescenceLoops.Count -ne 1 -or
        $measuredLoops.Count -ne 1 -or
        $measuredQuiescenceLoops.Count -ne 1 -or
        $confirmationLoops.Count -ne 1 -or
        $confirmationQuiescenceLoops.Count -ne 1
    ) {
        return $false
    }

    $warmupLoop = $warmupLoops[0]
    $warmupQuiescenceLoop = $warmupQuiescenceLoops[0]
    $calibrationLoop = $calibrationLoops[0]
    $calibrationQuiescenceLoop = $calibrationQuiescenceLoops[0]
    $measuredLoop = $measuredLoops[0]
    $measuredQuiescenceLoop = $measuredQuiescenceLoops[0]
    $confirmationLoop = $confirmationLoops[0]
    $confirmationQuiescenceLoop = $confirmationQuiescenceLoops[0]
    if (
        $warmupLoop.Extent.StartOffset -ge
            $warmupQuiescenceLoop.Extent.StartOffset -or
        $warmupQuiescenceLoop.Extent.StartOffset -ge
            $calibrationLoop.Extent.StartOffset -or
        $calibrationLoop.Extent.StartOffset -ge
            $calibrationQuiescenceLoop.Extent.StartOffset -or
        $calibrationQuiescenceLoop.Extent.StartOffset -ge
            $measuredLoop.Extent.StartOffset -or
        $measuredLoop.Extent.StartOffset -ge
            $measuredQuiescenceLoop.Extent.StartOffset -or
        $measuredQuiescenceLoop.Extent.StartOffset -ge
            $confirmationLoop.Extent.StartOffset -or
        $confirmationLoop.Extent.StartOffset -ge
            $confirmationQuiescenceLoop.Extent.StartOffset
    ) {
        return $false
    }
    if (
        -not [object]::ReferenceEquals(
            $warmupLoop.Parent,
            $warmupQuiescenceLoop.Parent
        ) -or
        -not [object]::ReferenceEquals(
            $warmupLoop.Parent,
            $calibrationLoop.Parent
        ) -or
        -not [object]::ReferenceEquals(
            $warmupLoop.Parent,
            $calibrationQuiescenceLoop.Parent
        ) -or
        -not [object]::ReferenceEquals(
            $warmupLoop.Parent,
            $measuredLoop.Parent
        ) -or
        -not [object]::ReferenceEquals(
            $warmupLoop.Parent,
            $measuredQuiescenceLoop.Parent
        ) -or
        -not [object]::ReferenceEquals(
            $warmupLoop.Parent,
            $confirmationLoop.Parent
        ) -or
        -not [object]::ReferenceEquals(
            $warmupLoop.Parent,
            $confirmationQuiescenceLoop.Parent
        ) -or
        $warmupLoop.Parent -isnot
            [System.Management.Automation.Language.StatementBlockAst] -or
        $warmupLoop.Parent.Parent -isnot
            [System.Management.Automation.Language.TryStatementAst]
    ) {
        return $false
    }

    # run数とgrowth上限は、同じTry直下で各1回だけ定数代入し、最初のloopより
    # 前に確定させる。loop直前の0再代入や、evidence直前の40復元を拒否する。
    $constantAssignments = @(
        [pscustomobject]@{ Name = 'handleWarmupRuns'; Value = 80 },
        [pscustomobject]@{ Name = 'handleCalibrationRuns'; Value = 40 },
        [pscustomobject]@{ Name = 'handleMeasuredRuns'; Value = 40 },
        [pscustomobject]@{ Name = 'handleConfirmationRuns'; Value = 40 },
        [pscustomobject]@{ Name = 'handleStartupGrowthLimit'; Value = 16 },
        [pscustomobject]@{
            Name = 'handleMeasuredFinalGrowthLimit'
            Value = 4
        },
        [pscustomobject]@{
            Name = 'handleQuiescenceSamples'
            Value = 10
        },
        [pscustomobject]@{
            Name = 'handleQuiescenceWaitMilliseconds'
            Value = 50
        }
    )
    $assignmentStatements = @(
        $ast.FindAll(
            {
                param($node)
                $node -is
                    [System.Management.Automation.Language.AssignmentStatementAst]
            },
            $true
        )
    )
    foreach ($constantAssignment in $constantAssignments) {
        $matchingAssignments = @(
            $assignmentStatements |
                Where-Object {
                    $_.Left -is
                        [System.Management.Automation.Language.VariableExpressionAst] -and
                    $_.Left.VariablePath.UserPath -match (
                        '(?i)(?:^|:)' +
                        [regex]::Escape($constantAssignment.Name) +
                        '$'
                    )
                }
        )
        if ($matchingAssignments.Count -ne 1) {
            return $false
        }

        $matchingAssignment = $matchingAssignments[0]
        if (
            -not $matchingAssignment.Left.VariablePath.IsUnqualified -or
            $matchingAssignment.Left.VariablePath.UserPath -cne
                $constantAssignment.Name -or
            $matchingAssignment.Operator -ne
                [System.Management.Automation.Language.TokenKind]::Equals -or
            $matchingAssignment.Right -isnot
                [System.Management.Automation.Language.CommandExpressionAst] -or
            $matchingAssignment.Right.Expression -isnot
                [System.Management.Automation.Language.ConstantExpressionAst] -or
            $matchingAssignment.Right.Expression.Value -ne
                $constantAssignment.Value -or
            -not [object]::ReferenceEquals(
                $matchingAssignment.Parent,
                $warmupLoop.Parent
            ) -or
            $matchingAssignment.Extent.StartOffset -ge
                $warmupLoop.Extent.StartOffset
        ) {
            return $false
        }
    }

    if (
        -not (
            Test-WindowsHandleProbeLoopContract `
                -Loop $warmupLoop `
                -CounterName 'handleWarmupAttempt' `
                -LimitName 'handleWarmupRuns' `
                -ResultName 'handleWarmupResult' `
                -FinalName 'handleWarmupFinal' `
                -MaximumName 'handleWarmupMaximum' `
                -ChildFailureCode 'windows-handle-probe-startup-child-failed'
        ) -or
        -not (
            Test-WindowsHandleQuiescenceLoopContract `
                -Loop $warmupQuiescenceLoop `
                -CounterName 'handleWarmupQuiescenceAttempt' `
                -SampleName 'handleWarmupQuiescenceSample' `
                -SettledName 'handleWarmupSettled'
        ) -or
        -not (
            Test-WindowsHandleProbeLoopContract `
                -Loop $calibrationLoop `
                -CounterName 'handleCalibrationAttempt' `
                -LimitName 'handleCalibrationRuns' `
                -ResultName 'handleCalibrationResult' `
                -FinalName 'handleCalibrationFinal' `
                -MaximumName 'handleCalibrationMaximum' `
                -ChildFailureCode `
                    'windows-handle-probe-calibration-child-failed'
        ) -or
        -not (
            Test-WindowsHandleQuiescenceLoopContract `
                -Loop $calibrationQuiescenceLoop `
                -CounterName 'handleCalibrationQuiescenceAttempt' `
                -SampleName 'handleCalibrationQuiescenceSample' `
                -SettledName 'handleCalibrationSettled'
        ) -or
        -not (
            Test-WindowsHandleProbeLoopContract `
                -Loop $measuredLoop `
                -CounterName 'handleAttempt' `
                -LimitName 'handleMeasuredRuns' `
                -ResultName 'handleProbeResult' `
                -FinalName 'handleMeasuredFinal' `
                -MaximumName 'handleMeasuredMaximum' `
                -ChildFailureCode 'windows-handle-probe-steady-child-failed'
        ) -or
        -not (
            Test-WindowsHandleQuiescenceLoopContract `
                -Loop $measuredQuiescenceLoop `
                -CounterName 'handleMeasuredQuiescenceAttempt' `
                -SampleName 'handleMeasuredQuiescenceSample' `
                -SettledName 'handleSettledFinal'
        ) -or
        -not (
            Test-WindowsHandleProbeLoopContract `
                -Loop $confirmationLoop `
                -CounterName 'handleConfirmationAttempt' `
                -LimitName 'handleConfirmationRuns' `
                -ResultName 'handleConfirmationResult' `
                -FinalName 'handleConfirmationFinal' `
                -MaximumName 'handleConfirmationMaximum' `
                -ChildFailureCode `
                    'windows-handle-probe-confirmation-child-failed'
        ) -or
        -not (
            Test-WindowsHandleQuiescenceLoopContract `
                -Loop $confirmationQuiescenceLoop `
                -CounterName 'handleConfirmationQuiescenceAttempt' `
                -SampleName 'handleConfirmationQuiescenceSample' `
                -SettledName 'handleConfirmationSettled'
        )
    ) {
        return $false
    }

    # ASTで各loop bodyを固定したうえで、startup → calibration → measured →
    # confirmationのbaselineとpersistent判定が同じTry内で順番どおり接続される
    # ことも検査する。
    $orderedContract = (
        '(?s)' +
        '\$handleWarmupRuns\s*=\s*80.*?' +
        '\$handleCalibrationRuns\s*=\s*40.*?' +
        '\$handleMeasuredRuns\s*=\s*40.*?' +
        '\$handleConfirmationRuns\s*=\s*40.*?' +
        '\$handleStartupGrowthLimit\s*=\s*16.*?' +
        '\$handleMeasuredFinalGrowthLimit\s*=\s*4.*?' +
        '\$handleQuiescenceSamples\s*=\s*10.*?' +
        '\$handleQuiescenceWaitMilliseconds\s*=\s*50.*?' +
        '\$handleStartupBaseline\s*=\s*' +
        '\$handleProbeProcess\.HandleCount.*?' +
        '\$handleWarmupObservedFinal\s*=\s*\$handleWarmupFinal.*?' +
        '\$handleWarmupSettled\s*=\s*\$handleWarmupFinal.*?' +
        '\(\$handleWarmupSettled\s*-\s*\$handleStartupBaseline\)\s*' +
        '-gt\s*\$handleStartupGrowthLimit.*?' +
        'windows-handle-probe-startup-persistent.*?' +
        '\$handleCalibrationFinal\s*=\s*\$handleWarmupSettled.*?' +
        '\$handleCalibrationObservedFinal\s*=\s*' +
        '\$handleCalibrationFinal.*?' +
        '\$handleCalibrationSettled\s*=\s*\$handleCalibrationFinal.*?' +
        '\(\$handleCalibrationSettled\s*-\s*' +
        '\$handleStartupBaseline\)\s*' +
        '-gt\s*\$handleStartupGrowthLimit.*?' +
        'windows-handle-probe-calibration-persistent.*?' +
        '\$handleBaseline\s*=\s*\$handleCalibrationSettled.*?' +
        '\$handleObservedFinal\s*=\s*\$handleMeasuredFinal.*?' +
        '\$handleSettledFinal\s*=\s*\$handleMeasuredFinal.*?' +
        '\$handleConfirmationFinal\s*=\s*\$handleSettledFinal.*?' +
        '\$handleConfirmationObservedFinal\s*=\s*' +
        '\$handleConfirmationFinal.*?' +
        '\$handleConfirmationSettled\s*=\s*' +
        '\$handleConfirmationFinal.*?' +
        '\(\$handleSettledFinal\s*-\s*\$handleBaseline\)\s*' +
        '-gt\s*\$handleStartupGrowthLimit\s*\)\s*-or\s*\(\s*' +
        '\(\$handleConfirmationSettled\s*-\s*' +
        '\$handleSettledFinal\)\s*' +
        '-gt\s*\$handleStartupGrowthLimit\s*\)\s*-or\s*\(\s*' +
        '\(\$handleSettledFinal\s*-\s*\$handleBaseline\)\s*' +
        '-gt\s*\$handleMeasuredFinalGrowthLimit\s*-and\s*' +
        '\(\$handleConfirmationSettled\s*-\s*' +
        '\$handleSettledFinal\)\s*' +
        '-gt\s*\$handleMeasuredFinalGrowthLimit.*?' +
        'windows-handle-probe-steady-persistent.*?' +
        'warmup-settled=\$handleWarmupSettled.*?' +
        'calibration-settled=\$handleCalibrationSettled.*?' +
        'confirmation-settled=\$handleConfirmationSettled.*?' +
        'confirmation=\$handleConfirmationRuns.*?' +
        'plateau-limit=\$handleStartupGrowthLimit.*?' +
        'final-limit=\$handleMeasuredFinalGrowthLimit'
    )
    return $Source -match $orderedContract
}

function Test-WindowsHandleProbeContract {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source
    )

    # 専用probeは小さく閉じたregression fixtureなので、AST契約に加えてcanonical
    # source全体をSHA-256で封印する。Set-Variable、outer wrapper、偽evidence等の
    # AST上は合法な追記も、個別deny-listへ依存せず必ずreview対象に戻す。
    $expectedSourceSha256 = (
        '778ef2b532027e6c26bedf83eb8a15209fc22d9bd3558dcb98217e196a52750a'
    )
    $sourceBytes = [System.Text.Encoding]::UTF8.GetBytes($Source)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $actualSourceSha256 = (
            $sha256.ComputeHash($sourceBytes) |
                ForEach-Object { $_.ToString('x2') }
        ) -join ''
    }
    finally {
        $sha256.Dispose()
    }
    if (
        -not [string]::Equals(
            $actualSourceSha256,
            $expectedSourceSha256,
            [System.StringComparison]::Ordinal
        )
    ) {
        return $false
    }

    return Test-WindowsHandleProbeAstContract -Source $Source
}

function Test-StringSequenceEqual {
    param(
        [AllowEmptyCollection()]
        [string[]]$Left,
        [AllowEmptyCollection()]
        [string[]]$Right
    )

    if ($Left.Count -ne $Right.Count) {
        return $false
    }
    for ($index = 0; $index -lt $Left.Count; $index++) {
        if (
            -not [string]::Equals(
                $Left[$index],
                $Right[$index],
                [System.StringComparison]::Ordinal
            )
        ) {
            return $false
        }
    }
    return $true
}

function Test-WorkflowBoundaryContract {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source
    )

    $lines = @($Source -split '\r?\n')
    $activeLines = @(
        $lines |
            Where-Object { $_ -notmatch '^[ \t]*(?:#.*)?$' }
    )

    # trigger/permission の追加や duplicate top-level key を黙認しない。
    # jobs 配下の詳細は既存の job/step exact validator が別途固定する。
    $topLevelLines = @(
        $activeLines |
            Where-Object { $_ -match '^\S' }
    )
    if (
        -not (
            Test-StringSequenceEqual `
                -Left $topLevelLines `
                -Right @('name: Validate', 'on:', 'permissions:', 'jobs:')
        )
    ) {
        return $false
    }

    $jobsIndexes = @()
    for ($index = 0; $index -lt $lines.Count; $index++) {
        if (
            [string]::Equals(
                $lines[$index],
                'jobs:',
                [System.StringComparison]::Ordinal
            )
        ) {
            $jobsIndexes += $index
        }
    }
    if ($jobsIndexes.Count -ne 1) {
        return $false
    }
    $jobsIndex = $jobsIndexes[0]
    $envelopeLines = @(
        $lines[0..$jobsIndex] |
            Where-Object { $_ -notmatch '^[ \t]*(?:#.*)?$' }
    )
    $expectedEnvelope = @(
        'name: Validate',
        'on:',
        '  pull_request:',
        '  push:',
        '    branches:',
        '      - main',
        'permissions:',
        '  contents: read',
        'jobs:'
    )
    if (
        -not (
            Test-StringSequenceEqual `
                -Left $envelopeLines `
                -Right $expectedEnvelope
        )
    ) {
        return $false
    }

    $jobNames = New-Object System.Collections.Generic.List[string]
    for ($index = $jobsIndex + 1; $index -lt $lines.Count; $index++) {
        $jobMatch = [regex]::Match(
            $lines[$index],
            '^  (?<name>[A-Za-z0-9_-]+):\s*$'
        )
        if ($jobMatch.Success) {
            $jobNames.Add($jobMatch.Groups['name'].Value) | Out-Null
        }
    }
    if (
        -not (
            Test-StringSequenceEqual `
                -Left @($jobNames.ToArray()) `
                -Right @('validate', 'validate_ubuntu', 'validate_macos')
        )
    ) {
        return $false
    }
    if (@($lines | Where-Object { $_ -match '^    permissions:\s*' }).Count -ne 0) {
        return $false
    }

    # third-party action は immutable full commit SHA だけを許可する。
    # 現 workflow は Windows/Ubuntu/macOS 各 1 回の checkout 以外を持たない。
    $expectedCheckout = (
        'actions/checkout@93cb6efe18208431cddfb8368fd83d5badbf9bfd'
    )
    $usesValues = New-Object System.Collections.Generic.List[string]
    foreach ($line in $lines) {
        $usesMatch = [regex]::Match(
            $line,
            '^[ \t]+uses:[ \t]*(?<value>[^#\r\n]+?)[ \t]*(?:#.*)?$'
        )
        if ($usesMatch.Success) {
            $usesValues.Add(
                $usesMatch.Groups['value'].Value.Trim()
            ) | Out-Null
        }
    }
    if ($usesValues.Count -ne 3) {
        return $false
    }
    foreach ($usesValue in $usesValues) {
        if (
            -not [string]::Equals(
                $usesValue,
                $expectedCheckout,
                [System.StringComparison]::Ordinal
            ) -or
            $usesValue -cnotmatch
                '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@[0-9a-f]{40}$'
        ) {
            return $false
        }
    }

    # checkout の資格情報は step.with 直下で明示的に非永続化する。
    # 同名scalarが別階層にあるだけでは合格させず、各checkout stepのactive tailを
    # exact sequenceとして確認する。
    $checkoutUsesPattern = (
        '^        uses:[ \t]*' +
        [regex]::Escape($expectedCheckout) +
        '[ \t]*(?:#.*)?$'
    )
    $checkoutUsesIndexes = @()
    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -match $checkoutUsesPattern) {
            $checkoutUsesIndexes += $index
        }
    }
    if ($checkoutUsesIndexes.Count -ne 3) {
        return $false
    }
    foreach ($usesIndex in $checkoutUsesIndexes) {
        $stepEnd = $lines.Count
        for ($index = $usesIndex + 1; $index -lt $lines.Count; $index++) {
            if (
                $lines[$index] -match
                    '^(?:      -[ \t]+|  [A-Za-z0-9_-]+:\s*$)'
            ) {
                $stepEnd = $index
                break
            }
        }
        $checkoutTail = @()
        if ($usesIndex + 1 -lt $stepEnd) {
            $checkoutTail = @(
                $lines[($usesIndex + 1)..($stepEnd - 1)] |
                    Where-Object { $_ -notmatch '^[ \t]*(?:#.*)?$' }
            )
        }
        if (
            -not (
                Test-StringSequenceEqual `
                    -Left $checkoutTail `
                    -Right @(
                        '        with:',
                        '          persist-credentials: false'
                    )
            )
        ) {
            return $false
        }
    }
    return $true
}

function Assert-WorkflowBoundaryContract {
    param([string]$RelativePath)

    $filePath = Get-RepoFilePath -RelativePath $RelativePath
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        return
    }
    try {
        $source = [System.IO.File]::ReadAllText(
            $filePath,
            (New-Object System.Text.UTF8Encoding($false, $true))
        )
    }
    catch {
        return
    }
    if (-not (Test-WorkflowBoundaryContract -Source $source)) {
        Add-Failure (
            "$RelativePath must keep its exact top-level trigger, " +
            'permission, job-ID, and immutable-action contract'
        )
        return
    }

    # validator 自体が代表的な権限拡張・mutable action・duplicate job を
    # 拒否することを pure mutation で固定し、regex の誤合格を防ぐ。
    $mutations = @(
        [pscustomobject]@{
            Name = 'pull-request-target'
            Source = [regex]::Replace(
                $source,
                '(?m)^  pull_request:\s*$',
                '  pull_request_target:'
            )
        },
        [pscustomobject]@{
            Name = 'extra-trigger'
            Source = [regex]::Replace(
                $source,
                '(?m)^  pull_request:\s*$',
                "  pull_request:`n  workflow_dispatch:"
            )
        },
        [pscustomobject]@{
            Name = 'duplicate-job'
            Source = [regex]::Replace(
                $source,
                '(?m)^  validate_ubuntu:\s*$',
                "  validate:`n  validate_ubuntu:"
            )
        },
        [pscustomobject]@{
            Name = 'job-permission-override'
            Source = [regex]::Replace(
                $source,
                '(?m)^  validate:\s*$',
                "  validate:`n    permissions:`n      contents: write"
            )
        },
        [pscustomobject]@{
            Name = 'mutable-action-ref'
            Source = $source.Replace(
                'actions/checkout@93cb6efe18208431cddfb8368fd83d5badbf9bfd',
                'actions/checkout@v5'
            )
        },
        [pscustomobject]@{
            Name = 'missing-persist-credentials'
            Source = [regex]::Replace(
                $source,
                '(?m)^          persist-credentials:[ \t]*false[ \t]*(?:\r?\n)?',
                ''
            )
        },
        [pscustomobject]@{
            Name = 'persist-credentials-true'
            Source = [regex]::Replace(
                $source,
                '(?m)^          persist-credentials:[ \t]*false[ \t]*$',
                '          persist-credentials: true'
            )
        },
        [pscustomobject]@{
            Name = 'misnested-persist-credentials'
            Source = [regex]::Replace(
                $source,
                '(?m)^          persist-credentials:[ \t]*false[ \t]*$',
                '        persist-credentials: false'
            )
        }
    )
    foreach ($mutation in $mutations) {
        if (
            [string]::Equals(
                $mutation.Source,
                $source,
                [System.StringComparison]::Ordinal
            )
        ) {
            Add-Failure (
                "$RelativePath workflow mutation setup made no change: " +
                $mutation.Name
            )
            continue
        }
        if (Test-WorkflowBoundaryContract -Source $mutation.Source) {
            Add-Failure (
                "$RelativePath workflow validator accepted mutation: " +
                $mutation.Name
            )
        }
    }
}

function Get-WorkflowJobLines {
    param(
        [string]$RelativePath,
        [string]$JobName
    )

    $filePath = Get-RepoFilePath -RelativePath $RelativePath
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        Add-Failure "Cannot inspect missing workflow file: $RelativePath"
        return @()
    }

    # Windows PowerShell 5.1 の locale 既定へ依存せず、workflow を strict
    # UTF-8 として読み、top-level jobs mapping 内だけを解析する。
    try {
        $workflowSource = [System.IO.File]::ReadAllText(
            $filePath,
            (New-Object System.Text.UTF8Encoding($false, $true))
        )
    }
    catch {
        Add-Failure "$RelativePath must be valid UTF-8"
        return @()
    }
    $lines = @($workflowSource -split '\r?\n')
    $jobsIndexes = @()
    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -match '^jobs:\s*$') {
            $jobsIndexes += $index
        }
    }
    if ($jobsIndexes.Count -ne 1) {
        Add-Failure "$RelativePath must contain exactly one top-level jobs mapping"
        return @()
    }
    $jobsStart = $jobsIndexes[0]
    $jobsEnd = $lines.Count
    for ($index = $jobsStart + 1; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -match '^\S') {
            $jobsEnd = $index
            break
        }
    }

    $jobStart = -1
    $jobPattern = '^  ' + [regex]::Escape($JobName) + ':\s*$'
    for ($index = $jobsStart + 1; $index -lt $jobsEnd; $index++) {
        if ($lines[$index] -match $jobPattern) {
            $jobStart = $index
            break
        }
    }
    if ($jobStart -lt 0) {
        Add-Failure "$RelativePath must contain jobs.$JobName"
        return @()
    }

    $jobEnd = $jobsEnd
    for ($index = $jobStart + 1; $index -lt $jobsEnd; $index++) {
        if (
            $lines[$index] -match '^  [A-Za-z0-9_-]+:\s*$'
        ) {
            $jobEnd = $index
            break
        }
    }
    return @($lines[$jobStart..($jobEnd - 1)])
}

function Assert-WorkflowJobSet {
    param(
        [string]$RelativePath,
        [string[]]$ExpectedJobs
    )

    $filePath = Get-RepoFilePath -RelativePath $RelativePath
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        return
    }
    try {
        $source = [System.IO.File]::ReadAllText(
            $filePath,
            (New-Object System.Text.UTF8Encoding($false, $true))
        )
    }
    catch {
        return
    }
    $lines = @($source -split '\r?\n')
    $jobsIndexes = @()
    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -match '^jobs:\s*$') {
            $jobsIndexes += $index
        }
    }
    if ($jobsIndexes.Count -ne 1) {
        return
    }

    $jobsEnd = $lines.Count
    for (
        $index = $jobsIndexes[0] + 1;
        $index -lt $lines.Count;
        $index++
    ) {
        if ($lines[$index] -match '^\S') {
            $jobsEnd = $index
            break
        }
    }
    $jobNames = New-Object System.Collections.Generic.List[string]
    $unexpectedDirectEntries = 0
    for (
        $index = $jobsIndexes[0] + 1;
        $index -lt $jobsEnd;
        $index++
    ) {
        $jobMatch = [regex]::Match(
            $lines[$index],
            '^  (?<name>[A-Za-z0-9_-]+):\s*$'
        )
        if ($jobMatch.Success) {
            $jobNames.Add($jobMatch.Groups['name'].Value) | Out-Null
        } elseif ($lines[$index] -match '^  (?![ #\r\n]).+$') {
            $unexpectedDirectEntries++
        }
    }

    $actualJobs = @($jobNames.ToArray())
    $expectedSequenceMatches = (
        $actualJobs.Count -eq $ExpectedJobs.Count
    )
    if ($expectedSequenceMatches) {
        for ($index = 0; $index -lt $ExpectedJobs.Count; $index++) {
            if (
                -not [string]::Equals(
                    $actualJobs[$index],
                    $ExpectedJobs[$index],
                    [System.StringComparison]::Ordinal
                )
            ) {
                $expectedSequenceMatches = $false
                break
            }
        }
    }
    if (-not $expectedSequenceMatches -or
        $unexpectedDirectEntries -ne 0) {
        Add-Failure (
            "$RelativePath jobs mapping must contain exactly: " +
            ($ExpectedJobs -join ', ')
        )
    }
}

function Assert-WorkflowJobTimeout {
    param(
        [string]$RelativePath,
        [string]$JobName,
        [int]$Minutes
    )

    $jobLines = @(Get-WorkflowJobLines -RelativePath $RelativePath -JobName $JobName)
    if ($jobLines.Count -eq 0) {
        return
    }
    $timeoutMatches = @(
        $jobLines |
            Where-Object { $_ -match '^    timeout-minutes:\s*(?<minutes>\d+)\s*$' }
    )
    if ($timeoutMatches.Count -ne 1) {
        Add-Failure "Workflow jobs.$JobName must contain exactly one timeout-minutes"
        return
    }
    $timeoutMatch = [regex]::Match(
        $timeoutMatches[0],
        '^    timeout-minutes:\s*(?<minutes>\d+)\s*$'
    )
    if ([int]$timeoutMatch.Groups['minutes'].Value -ne $Minutes) {
        Add-Failure "Workflow jobs.$JobName timeout-minutes must be $Minutes"
    }
}

function Assert-WorkflowJobDirectValue {
    param(
        [string]$RelativePath,
        [string]$JobName,
        [string]$Key,
        [string]$Value
    )

    # 別jobの値で誤合格しないよう、対象job直下のexact scalarだけを数える。
    $jobLines = @(
        Get-WorkflowJobLines -RelativePath $RelativePath -JobName $JobName
    )
    if ($jobLines.Count -eq 0) {
        return
    }
    $pattern = (
        '^    ' + [regex]::Escape($Key) + ':\s*' +
        [regex]::Escape($Value) + '\s*$'
    )
    $matches = @($jobLines | Where-Object { $_ -match $pattern })
    if ($matches.Count -ne 1) {
        Add-Failure (
            "Workflow jobs.$JobName must contain exactly one " +
            "$Key value '$Value'"
        )
    }
}

function Get-WorkflowSteps {
    param(
        [string]$RelativePath,
        [string]$JobName
    )

    # job内の別nested sequenceをstepと誤認しないよう、jobs.<name>.steps
    # 直下だけを切り出してname / shell / runを同じrecordへ束ねる。
    $jobLines = @(
        Get-WorkflowJobLines -RelativePath $RelativePath -JobName $JobName
    )
    $stepsIndexes = @()
    for ($index = 0; $index -lt $jobLines.Count; $index++) {
        if ($jobLines[$index] -match '^    steps:\s*$') {
            $stepsIndexes += $index
        }
    }
    if ($stepsIndexes.Count -ne 1) {
        Add-Failure "Workflow jobs.$JobName must contain exactly one direct steps mapping"
        return @()
    }
    $stepsStart = $stepsIndexes[0] + 1
    $stepsEnd = $jobLines.Count
    for ($index = $stepsStart; $index -lt $jobLines.Count; $index++) {
        if ($jobLines[$index] -match '^    [A-Za-z0-9_-]+:\s*') {
            $stepsEnd = $index
            break
        }
    }

    $steps = New-Object System.Collections.Generic.List[object]
    $currentStep = $null
    $currentNestedParent = ''
    if ($stepsStart -ge $stepsEnd) {
        Add-Failure "Workflow jobs.$JobName.steps must not be empty"
        return @()
    }
    $stepLines = @($jobLines[$stepsStart..($stepsEnd - 1)])
    $allStepCount = @(
        $stepLines | Where-Object { $_ -match '^      -[ \t]+' }
    ).Count
    $namedStepCount = @(
        $stepLines |
            Where-Object { $_ -match '^      -[ \t]+name:[ \t]+' }
    ).Count
    if ($allStepCount -ne $namedStepCount) {
        Add-Failure (
            "Workflow jobs.$JobName must give every active step " +
            'an explicit name'
        )
    }
    foreach ($line in $stepLines) {
        $isStepStart = $line -match '^      -[ \t]+'
        if ($isStepStart -and $null -ne $currentStep) {
            $steps.Add($currentStep) | Out-Null
            $currentStep = $null
            $currentNestedParent = ''
        }
        $nameMatch = [regex]::Match(
            $line,
            '^      - name:[ \t]*(?<value>[^#\r\n]+?)[ \t]*$'
        )
        if ($nameMatch.Success) {
            $currentStep = [pscustomobject]@{
                Name = $nameMatch.Groups['value'].Value.Trim("'`"")
                Shell = ''
                Run = ''
                Uses = ''
                PersistCredentials = ''
                ShellCount = 0
                RunCount = 0
                UsesCount = 0
                WithCount = 0
                PersistCredentialsCount = 0
            }
            $currentNestedParent = ''
            continue
        }
        if ($isStepStart) {
            continue
        }

        if ($null -eq $currentStep) {
            continue
        }
        $withMatch = [regex]::Match(
            $line,
            '^        with:[ \t]*$'
        )
        if ($withMatch.Success) {
            $currentStep.WithCount++
            $currentNestedParent = 'with'
            continue
        }
        $persistCredentialsMatch = [regex]::Match(
            $line,
            '^          persist-credentials:[ \t]*(?<value>[^#\r\n]+?)[ \t]*$'
        )
        if (
            $persistCredentialsMatch.Success -and
            [string]::Equals(
                $currentNestedParent,
                'with',
                [System.StringComparison]::Ordinal
            )
        ) {
            $currentStep.PersistCredentials = (
                $persistCredentialsMatch.Groups['value'].Value.Trim("'`"")
            )
            $currentStep.PersistCredentialsCount++
            continue
        }
        if ($line -match '^        (?![ #\r\n]).+$') {
            $currentNestedParent = ''
        }
        $shellMatch = [regex]::Match(
            $line,
            '^        shell:[ \t]*(?<value>[^#\r\n]+?)[ \t]*$'
        )
        if ($shellMatch.Success) {
            $currentStep.Shell = $shellMatch.Groups['value'].Value.Trim("'`"")
            $currentStep.ShellCount++
            continue
        }
        $usesMatch = [regex]::Match(
            $line,
            '^        uses:[ \t]*(?<value>[^#\r\n]+?)[ \t]*(?:#.*)?$'
        )
        if ($usesMatch.Success) {
            $currentStep.Uses = $usesMatch.Groups['value'].Value.Trim("'`" ")
            $currentStep.UsesCount++
            continue
        }
        $runMatch = [regex]::Match(
            $line,
            '^        run:[ \t]*(?<value>[^#\r\n]+?)[ \t]*$'
        )
        if ($runMatch.Success) {
            $currentStep.Run = $runMatch.Groups['value'].Value.Trim("'`"")
            $currentStep.RunCount++
        }
    }

    if ($null -ne $currentStep) {
        $steps.Add($currentStep) | Out-Null
    }
    return $steps.ToArray()
}

function Assert-WorkflowStepCount {
    param(
        [object[]]$Steps,
        [string]$JobName,
        [int]$ExpectedCount
    )

    if ($Steps.Count -ne $ExpectedCount) {
        Add-Failure (
            "Workflow jobs.$JobName must contain exactly " +
            "$ExpectedCount named steps (found $($Steps.Count))"
        )
    }
}

function Assert-WorkflowJobShape {
    param(
        [string[]]$Lines,
        [string]$JobName,
        [int]$ExpectedStepCount,
        [int]$ExpectedShellCount,
        [int]$ExpectedRunCount,
        [int]$ExpectedWithCount,
        [int]$ExpectedNestedEntryCount
    )

    # expected keyを残したまま if / env / continue-on-error / extra actionを
    # 足して gate を無効化できないよう、全 active entry をindent別に数える。
    $jobEntryCount = @(
        $Lines | Where-Object { $_ -match '^    (?![ #\r\n]).+$' }
    ).Count
    $nameKeyCount = @(
        $Lines | Where-Object { $_ -match '^    name:[ \t]*' }
    ).Count
    $runsOnKeyCount = @(
        $Lines | Where-Object { $_ -match '^    runs-on:[ \t]*' }
    ).Count
    $timeoutKeyCount = @(
        $Lines | Where-Object { $_ -match '^    timeout-minutes:[ \t]*' }
    ).Count
    $stepsKeyCount = @(
        $Lines | Where-Object { $_ -match '^    steps:[ \t]*' }
    ).Count
    $stepItemCount = @(
        $Lines | Where-Object { $_ -match '^      -[ \t]+' }
    ).Count
    $stepPropertyCount = @(
        $Lines | Where-Object { $_ -match '^        (?![ #\r\n]).+$' }
    ).Count
    $shellKeyCount = @(
        $Lines | Where-Object { $_ -match '^        shell:[ \t]*' }
    ).Count
    $runKeyCount = @(
        $Lines | Where-Object { $_ -match '^        run:[ \t]*' }
    ).Count
    $usesKeyCount = @(
        $Lines | Where-Object { $_ -match '^        uses:[ \t]*' }
    ).Count
    $withKeyCount = @(
        $Lines | Where-Object { $_ -match '^        with:[ \t]*' }
    ).Count
    $deepActiveEntryCount = @(
        $Lines | Where-Object {
            $_ -match '^ {10,}(?![ #\r\n]).+$'
        }
    ).Count
    $expectedStepPropertyCount = (
        1 +
        $ExpectedShellCount +
        $ExpectedRunCount +
        $ExpectedWithCount
    )

    if ($jobEntryCount -ne 4 -or
        $nameKeyCount -ne 1 -or
        $runsOnKeyCount -ne 1 -or
        $timeoutKeyCount -ne 1 -or
        $stepsKeyCount -ne 1) {
        Add-Failure (
            "Workflow jobs.$JobName must contain only one " +
            'name/runs-on/timeout-minutes/steps mapping'
        )
    }
    if ($stepItemCount -ne $ExpectedStepCount) {
        Add-Failure (
            "Workflow jobs.$JobName must contain exactly " +
            "$ExpectedStepCount step items (found $stepItemCount)"
        )
    }
    if ($stepPropertyCount -ne $expectedStepPropertyCount -or
        $shellKeyCount -ne $ExpectedShellCount -or
        $runKeyCount -ne $ExpectedRunCount -or
        $usesKeyCount -ne 1 -or
        $withKeyCount -ne $ExpectedWithCount -or
        $deepActiveEntryCount -ne $ExpectedNestedEntryCount) {
        Add-Failure (
            "Workflow jobs.$JobName contains an unexpected, " +
            'missing, duplicate, or nested step-level key'
        )
    }
}

function Assert-WorkflowUsesStep {
    param(
        [object[]]$Steps,
        [string]$Name,
        [string]$Uses,
        [string]$PersistCredentials
    )

    $matches = @(
        $Steps |
            Where-Object {
                [string]::Equals(
                    $_.Name,
                    $Name,
                    [System.StringComparison]::Ordinal
                )
            }
    )
    if ($matches.Count -ne 1) {
        Add-Failure "Workflow must contain exactly one active step named '$Name' (found $($matches.Count))"
        return
    }
    if (
        -not [string]::Equals(
            $matches[0].Uses,
            $Uses,
            [System.StringComparison]::Ordinal
        )
    ) {
        Add-Failure "Workflow step '$Name' must use '$Uses' (found '$($matches[0].Uses)')"
    }
    if ($matches[0].UsesCount -ne 1 -or
        $matches[0].ShellCount -ne 0 -or
        $matches[0].RunCount -ne 0 -or
        $matches[0].WithCount -ne 1 -or
        $matches[0].PersistCredentialsCount -ne 1) {
        Add-Failure (
            "Workflow step '$Name' must contain exactly one uses " +
            'and one with.persist-credentials scalar, with no shell/run key'
        )
    }
    if (
        -not [string]::Equals(
            $matches[0].PersistCredentials,
            $PersistCredentials,
            [System.StringComparison]::Ordinal
        )
    ) {
        Add-Failure (
            "Workflow step '$Name' persist-credentials must be " +
            "'$PersistCredentials' (found '$($matches[0].PersistCredentials)')"
        )
    }
}

function Assert-WorkflowStep {
    param(
        [object[]]$Steps,
        [string]$Name,
        [string]$Shell,
        [string]$Run
    )

    $matches = @(
        $Steps |
            Where-Object {
                [string]::Equals(
                    $_.Name,
                    $Name,
                    [System.StringComparison]::Ordinal
                )
            }
    )
    if ($matches.Count -ne 1) {
        Add-Failure "Workflow must contain exactly one active step named '$Name' (found $($matches.Count))"
        return
    }

    $step = $matches[0]
    if ($step.ShellCount -ne 1 -or
        $step.RunCount -ne 1 -or
        $step.UsesCount -ne 0) {
        Add-Failure (
            "Workflow step '$Name' must contain exactly one shell/run " +
            'and no uses key'
        )
    }
    if (-not $step.Shell.Equals($Shell, [System.StringComparison]::OrdinalIgnoreCase)) {
        Add-Failure "Workflow step '$Name' must use shell '$Shell' (found '$($step.Shell)')"
    }
    if (
        -not [string]::Equals(
            $step.Run,
            $Run,
            [System.StringComparison]::Ordinal
        )
    ) {
        Add-Failure "Workflow step '$Name' must run '$Run' (found '$($step.Run)')"
    }
}

function Assert-PowerShellByteHygiene {
    param([string]$RelativePath)

    $filePath = Get-RepoFilePath -RelativePath $RelativePath
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        return
    }

    # 日本語commentをPS5.1でも安全にparseするためUTF-8 BOMを必須にし、
    # repositoryのLF契約とNUL非混入も同時に固定する。
    $bytes = [System.IO.File]::ReadAllBytes($filePath)
    $hasUtf8Bom = (
        $bytes.Length -ge 3 -and
        $bytes[0] -eq 0xEF -and
        $bytes[1] -eq 0xBB -and
        $bytes[2] -eq 0xBF
    )
    if (-not $hasUtf8Bom) {
        Add-Failure "$RelativePath must use UTF-8 with BOM for Windows PowerShell 5.1."
    }
    if ($bytes -contains 13) {
        Add-Failure "$RelativePath must use LF line endings."
    }
    if ($bytes -contains 0) {
        Add-Failure "$RelativePath must not contain NUL bytes."
    }
}

function Test-SkillFrontmatter {
    $skillPath = Get-RepoFilePath -RelativePath 'SKILL.md'
    if (-not (Test-Path -LiteralPath $skillPath -PathType Leaf)) {
        return
    }

    # frontmatterも本文と同じUTF-8境界で読み、hostごとのANSI既定値を使わない。
    $lines = Get-Content -LiteralPath $skillPath -Encoding UTF8
    if ($lines.Count -lt 4 -or $lines[0] -ne '---') {
        Add-Failure 'SKILL.md must start with YAML frontmatter.'
        return
    }

    $closingIndex = -1
    for ($index = 1; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -eq '---') {
            $closingIndex = $index
            break
        }
    }

    if ($closingIndex -lt 0) {
        Add-Failure 'SKILL.md frontmatter must be closed with --- before content.'
        return
    }

    $frontmatter = $lines[1..($closingIndex - 1)] -join "`n"
    if ($frontmatter -notmatch '(?m)^name:\s*multi-agent-delegation\s*$') {
        Add-Failure 'SKILL.md frontmatter must declare name: multi-agent-delegation.'
    }
    if ($frontmatter -notmatch '(?m)^description:\s*\S') {
        Add-Failure 'SKILL.md frontmatter must include a non-empty description.'
    }
    if ($frontmatter.Length -gt 1024) {
        Add-Failure 'SKILL.md frontmatter must stay under 1024 characters.'
    }
}

if ($InternalDefinitionsOnly) {
    return
}

$requiredFiles = @(
    '.editorconfig',
    '.gitattributes',
    '.gitignore',
    '.github/ISSUE_TEMPLATE/bug_report.yml',
    '.github/ISSUE_TEMPLATE/config.yml',
    '.github/pull_request_template.md',
    '.github/workflows/validate.yml',
    'CHANGELOG.md',
    'CODE_OF_CONDUCT.md',
    'CONTRIBUTING.md',
    'LICENSE',
    'README.md',
    'SECURITY.md',
    'SKILL.md',
    'docs/completion-baseline-verification.md',
    'docs/delegation-contract-hardening.md',
    'docs/SKILL.ja.md',
    'docs/scanner-hardening-v2.md',
    'examples/delegation-prompt-template.md',
    'examples/verification-checklist.md',
    'examples/ledger-template.md',
    'scripts/private-marker-process-runner.psm1',
    'scripts/scan-private-markers.ps1',
    'scripts/scan-private-markers-v2.ps1',
    'scripts/test-macos-fail-closed.ps1',
    'scripts/test-private-marker-handle-stability.ps1',
    'scripts/test-scan-private-markers.ps1',
    'scripts/validate-oss-readiness.ps1'
)

foreach ($requiredFile in $requiredFiles) {
    Assert-FileExists -RelativePath $requiredFile
}

Assert-BaselineAwareCompletionPureDecisionFixtures
Assert-SyntheticGitProcessFixtureCapabilityDecisions
if (Test-SyntheticGitProcessFixtureSupported) {
    Assert-BaselineAwareCompletionSemanticFixtures
}

Assert-FileContains -RelativePath 'README.md' -Pattern '(?im)^##\s+Install' -Description 'installation instructions'
Assert-FileContains -RelativePath 'README.md' -Pattern '(?im)^##\s+Validation' -Description 'validation instructions'
Assert-FileContains -RelativePath 'README.md' -Pattern '(?im)^##\s+Contributing' -Description 'contribution guidance'
Assert-FileContains -RelativePath 'README.md' -Pattern '(?im)^##\s+Security' -Description 'security reporting guidance'
Assert-FileContains -RelativePath 'README.md' -Pattern 'CONTRIBUTING\.md' -Description 'link to CONTRIBUTING.md'
Assert-FileContains -RelativePath 'README.md' -Pattern 'SECURITY\.md' -Description 'link to SECURITY.md'
Assert-FileContains -RelativePath 'README.md' -Pattern 'docs/SKILL\.ja\.md' -Description 'link to the Japanese skill version'
# 単独委譲でもshared checkoutへ複数writerが入らないよう、正本・翻訳・利用者向け
# fixtureのすべてに編集前のownership gateを必須化する。
$skillAbsolutePathsContract = @'
2. The absolute path of the exclusive checkout / worktree, the absolute
   expected artifact path(s), and the acceptance criteria: what must exist for
   the task to count as done.
'@
Assert-FileContainsExactContract `
    -RelativePath 'SKILL.md' `
    -Expected $skillAbsolutePathsContract `
    -Description 'canonical absolute checkout and artifact paths'

$skillOwnershipClause = @'
5. "Checkout ownership: before editing, inspect the current branch and
   `git status --porcelain`. If existing WIP is present and was not explicitly
   assigned to you, another writer is using the same checkout, or ownership is
   unclear, do not edit, commit, push, or merge. Report the conflict to the
   orchestrator. Use an exclusive checkout or isolated worktree and task
   branch before continuing."
'@
Assert-FileContainsExactContract `
    -RelativePath 'SKILL.md' `
    -Expected $skillOwnershipClause `
    -Description 'mandatory pre-edit checkout ownership clause'

$skillResumeContract = @'
The ownership clause prevents a different failure: two agents editing one
checkout can overwrite or absorb each other's WIP and make the measured diff
disagree with either completion report. Pre-existing WIP not explicitly
assigned to the delegated agent must not be stashed, reset, deleted, or
included in the delegated task's commit. A resumed agent may continue its own
explicitly assigned WIP in the same thread.
'@
Assert-FileContainsExactContract `
    -RelativePath 'SKILL.md' `
    -Expected $skillResumeContract `
    -Description 'assigned-WIP resume exception'

$skillSafetyContract = @'
- A delegated writer must have an exclusive checkout or isolated worktree.
  If another writer, unassigned existing WIP, or unclear ownership is
  detected, the agent reports the conflict without modifying Git state or
  files.
'@
Assert-FileContainsExactContract `
    -RelativePath 'SKILL.md' `
    -Expected $skillSafetyContract `
    -Description 'canonical fail-closed writer safety condition'

$skillCompletionContract = @'
- The agent recorded its initial branch/status and had exclusive checkout
  ownership before editing; unassigned pre-existing WIP was not altered or
  absorbed.
'@
Assert-FileContainsExactContract `
    -RelativePath 'SKILL.md' `
    -Expected $skillCompletionContract `
    -Description 'canonical ownership completion evidence'

$skillBaselineClause = @'
6. "Completion verification baseline: before editing, record the current
   branch, the full OID from `git rev-parse --verify HEAD`, and all output from
   `git --no-optional-locks status --porcelain=v1 --untracked-files=all`. For
   non-Git artifacts and explicitly assigned dirty-resume artifacts, also
   record existence, byte size, and SHA-256. Use read-only Git commands only;
   never use `git write-tree` or another command that mutates the index,
   working tree, or object database to create the baseline."
'@
Assert-FileContainsExactContract `
    -RelativePath 'SKILL.md' `
    -Expected $skillBaselineClause `
    -Description 'canonical read-only completion baseline clause'

$skillFinalMeasurementContract = @'
- After the completion notice, the orchestrator independently re-measures the
  final branch, full HEAD OID, `git diff --name-status
  <baseline>..<final> --`, current `git --no-optional-locks status
  --porcelain=v1 --untracked-files=all`, and the acceptance artifact's
  existence, content, byte size, and SHA-256. For an existing baseline HEAD,
  `git merge-base --is-ancestor <baseline> <final>` must exit 0; the same
  branch name is not proof that history was preserved.
'@
Assert-FileContainsExactContract `
    -RelativePath 'SKILL.md' `
    -Expected $skillFinalMeasurementContract `
    -Description 'canonical independent final measurement'

$skillVerificationEvidenceContract = @'
- Combine the evidence. An unchanged HEAD plus unchanged initial-to-final
  porcelain and assigned artifact state is a no-op even when the artifact
  already exists. An empty final porcelain is valid when HEAD changed, the
  baseline is an ancestor of final HEAD, the baseline-to-final diff contains
  only assigned paths, and the artifact content passes acceptance. Rewritten or
  divergent history is a scope violation even when its diff is assigned-only.
  For an explicitly assigned dirty resume, compare the initial and final
  artifact states because the same porcelain path may appear at both times.
  Any unassigned path in the initial/final porcelain or committed diff is a
  scope violation, not successful work.
- For a non-Git file-changing task, compare the final artifact with its
  pre-edit existence, byte size, and SHA-256, then inspect its content against
  acceptance. Existence or modification time alone is not completion evidence.
'@
Assert-FileContainsExactContract `
    -RelativePath 'SKILL.md' `
    -Expected $skillVerificationEvidenceContract `
    -Description 'canonical baseline-to-final completion decision'

$japaneseAbsolutePathsContract = @'
2. 排他的 checkout / worktree の絶対パス、成果物の絶対パス、受け入れ条件
   （何が存在すれば完了か）
'@
Assert-FileContainsExactContract `
    -RelativePath 'docs/SKILL.ja.md' `
    -Expected $japaneseAbsolutePathsContract `
    -Description 'Japanese absolute checkout and artifact paths'

$japaneseOwnershipClause = @'
5. **「checkout の所有権: 編集前に現在 branch と `git status --porcelain` を確認する。
   明示的に割り当てられていない既存 WIP、同じ checkout の別 writer、または
   所有権不明を検出した場合は、編集、commit、push、merge を行わず司令塔へ競合を
   報告する。続行前に排他的な checkout または隔離 worktree と task branch を
   割り当てること」**
'@
Assert-FileContainsExactContract `
    -RelativePath 'docs/SKILL.ja.md' `
    -Expected $japaneseOwnershipClause `
    -Description 'Japanese pre-edit checkout ownership clause'

$japaneseResumeContract = @'
所有権の条項が防ぐ別の失敗: 2体の agent が同じ checkout を編集すると、互いの WIP を上書きしたり混入したりして、実測 diff と各完了報告が一致しなくなる。
委譲先へ明示的に割り当てられていない既存 WIP を stash、reset、削除、または委譲 task の commit へ含めてはならない。
同一 thread で resume した agent は、自身へ明示的に割り当て済みの WIP を継続できる。
'@
Assert-FileContainsExactContract `
    -RelativePath 'docs/SKILL.ja.md' `
    -Expected $japaneseResumeContract `
    -Description 'Japanese assigned-WIP resume exception'

$japaneseSafetyContract = @'
- 委譲先 writer は排他的な checkout または隔離 worktree を所有する。別 writer、
  未割当の既存 WIP、所有権不明を検出した場合は、Git state と file を変更せず競合を
  報告する。
'@
Assert-FileContainsExactContract `
    -RelativePath 'docs/SKILL.ja.md' `
    -Expected $japaneseSafetyContract `
    -Description 'Japanese fail-closed writer safety condition'

$japaneseCompletionContract = @'
- 編集前の branch/status と checkout の排他的所有を記録済みで、未割当の既存 WIP を
  変更も混入もしていない。
'@
Assert-FileContainsExactContract `
    -RelativePath 'docs/SKILL.ja.md' `
    -Expected $japaneseCompletionContract `
    -Description 'Japanese ownership completion evidence'

$japaneseBaselineClause = @'
6. **「完了検証baseline: 編集前に現在branch、`git rev-parse --verify HEAD`の完全OID、
   `git --no-optional-locks status --porcelain=v1 --untracked-files=all`の全出力を記録する。
   non-Git成果物と明示的に割り当て済みのdirty resume成果物では、実在、byte size、
   SHA-256も記録する。baseline取得にはread-only Git commandだけを使い、
   `git write-tree`などindex、working tree、object databaseを変更するcommandを使わない」**
'@
Assert-FileContainsExactContract `
    -RelativePath 'docs/SKILL.ja.md' `
    -Expected $japaneseBaselineClause `
    -Description 'Japanese read-only completion baseline clause'

$japaneseFinalMeasurementContract = @'
- 完了通知後、司令塔が最終branch、完全HEAD OID、`git diff --name-status
  <baseline>..<final> --`、現在の`git --no-optional-locks status --porcelain=v1
  --untracked-files=all`、受け入れ成果物の実在・内容・byte size・SHA-256を独立して
  再測定する。baseline HEADが存在する場合は`git merge-base --is-ancestor
  <baseline> <final>`のexit 0を必須とし、同じbranch名だけでhistory保持と判定しない。
'@
Assert-FileContainsExactContract `
    -RelativePath 'docs/SKILL.ja.md' `
    -Expected $japaneseFinalMeasurementContract `
    -Description 'Japanese independent final measurement'

$japaneseVerificationEvidenceContract = @'
- 証拠を合成する。HEAD、porcelain、assigned artifact stateがinitial→finalで不変なら、
  成果物が既に存在しても空振り。最終porcelainが空でも、HEADが変わり、
  baselineがfinal HEADのancestorで、baseline→final diffが割当済みpathだけを含み、
  成果物内容が受け入れ条件を満たせばcommit済みの成功とする。割当済みpathだけの
  diffでも、rewrittenまたはdivergent historyはscope違反とする。
  明示的に割り当て済みのdirty resumeは、porcelainに同じpathが出続け得るためartifact
  stateをinitial→finalで比較する。initial/final porcelainまたはcommit差分に未割当pathが
  あれば、成功ではなくscope違反とする。
- non-Gitのfile-changing taskは、編集前後の実在・byte size・SHA-256を比較してから
  内容を受け入れ条件と照合する。実在や更新時刻だけを完了証拠にしない。
'@
Assert-FileContainsExactContract `
    -RelativePath 'docs/SKILL.ja.md' `
    -Expected $japaneseVerificationEvidenceContract `
    -Description 'Japanese baseline-to-final completion decision'

$englishTemplateContract = @'
Target checkout / worktree (absolute path): <exclusive-checkout-path>
(assigned exclusively to you)
Work branch: <branch-name> (use or create it only in the assigned checkout /
worktree; do not commit to the default branch)

Checkout ownership [MANDATORY]:
- Before editing, report the current branch and run
  `git status --porcelain`.
- You must be the exclusive writer for this checkout. If existing WIP is
  present and was not explicitly assigned to you, another writer is using the
  checkout, or ownership is unclear, stop and report the conflict. Do not
  edit, commit, push, or merge.
- Do not stash, reset, delete, or absorb unassigned pre-existing WIP. Continue
  only in the exclusive checkout or isolated worktree and task branch assigned
  to you.

Completion verification baseline [MANDATORY]:
- Before editing, record the current branch, the full OID from
  `git rev-parse --verify HEAD`, and all output from
  `git --no-optional-locks status --porcelain=v1 --untracked-files=all`.
- For non-Git artifacts and explicitly assigned dirty-resume artifacts, also
  record pre-edit existence, byte size, and SHA-256. Do not read or hash
  unassigned WIP; stop on that ownership conflict.
- Baseline collection is read-only. Do not use `git write-tree`, `update-index`,
  stash, reset, checkout, or another command that changes Git or file state.

Deliverables and acceptance criteria [MANDATORY] (use absolute artifact
paths):
'@
Assert-FileContainsExactContract `
    -RelativePath 'examples/delegation-prompt-template.md' `
    -Expected $englishTemplateContract `
    -Description 'English synthetic checkout ownership template'

$japaneseTemplateContract = @'
対象 checkout / worktree（絶対パス）: <exclusive-checkout-path>
（あなた専用として割当済み）
作業ブランチ: <branch-name>（割当済み checkout / worktree 内だけで使用または
作成し、デフォルトブランチへ直接コミットしない）

checkout の所有権【必須】:
- 編集前に現在 branch を報告し、`git status --porcelain` を実行する。
- この checkout の排他的 writer であること。明示的に割り当てられていない既存 WIP、
  同じ checkout の別 writer、または所有権不明を検出した場合は停止して競合を報告し、
  編集、commit、push、merge を行わない。
- 未割当の既存 WIP を stash、reset、削除、自分の commit へ混入しない。割り当て
  られた排他的 checkout または隔離 worktree と task branch でのみ続行する。

完了検証baseline【必須】:
- 編集前に現在branch、`git rev-parse --verify HEAD`の完全OID、
  `git --no-optional-locks status --porcelain=v1 --untracked-files=all`の全出力を記録する。
- non-Git成果物と明示的に割り当て済みのdirty resume成果物では、編集前の実在、
  byte size、SHA-256も記録する。未割当WIPは開いたりhash化したりせず、競合として停止する。
- baseline取得はread-onlyとし、`git write-tree`、`update-index`、stash、reset、
  checkoutなどGit stateやfileを変更するcommandを使わない。

成果物と受け入れ条件【必須】（成果物も絶対パスで指定）:
'@
Assert-FileContainsExactContract `
    -RelativePath 'examples/delegation-prompt-template.md' `
    -Expected $japaneseTemplateContract `
    -Description 'Japanese synthetic checkout ownership template'

$englishTemplateCompletionContract = @'
- Include the final branch and full HEAD OID, baseline-to-final
  `git diff --name-status`, current porcelain with all untracked files, and
  artifact content/state evidence. For an existing baseline HEAD, include the
  exit result of `git merge-base --is-ancestor <baseline> <final>`; exit 0 is
  required. A clean committed task is not a no-op merely because final
  porcelain is empty, but divergent history is never valid completion.
'@
Assert-FileContainsExactContract `
    -RelativePath 'examples/delegation-prompt-template.md' `
    -Expected $englishTemplateCompletionContract `
    -Description 'English synthetic final completion evidence'

$japaneseTemplateCompletionContract = @'
- 最終branchと完全HEAD OID、baseline→finalの`git diff --name-status`、untrackedを
  全件含む現在porcelain、成果物の内容/state証拠を含めること。baseline HEADが存在する
  場合は`git merge-base --is-ancestor <baseline> <final>`のexit結果も含め、exit 0を
  必須とする。commit済みでcleanなtaskを最終porcelainが空という理由だけで空振りに
  しないが、divergent historyを完了扱いしない。
'@
Assert-FileContainsExactContract `
    -RelativePath 'examples/delegation-prompt-template.md' `
    -Expected $japaneseTemplateCompletionContract `
    -Description 'Japanese synthetic final completion evidence'

$verificationChecklistContract = @'
## 0. Existing WIP and writer ownership

- [ ] Before editing, the agent recorded its initial branch, full
      `git rev-parse --verify HEAD` OID (or explicit unborn state), and all
      output from
      `git --no-optional-locks status --porcelain=v1 --untracked-files=all`.
- [ ] For non-Git artifacts and explicitly assigned dirty-resume artifacts,
      the pre-edit baseline includes existence, byte size, and SHA-256.
- [ ] Baseline collection used read-only commands only. It did not use
      `git write-tree`, `update-index`, stash, reset, checkout, or another
      state-changing shortcut.
- [ ] The agent was the exclusive writer for its checkout, or used an
      orchestrator-assigned isolated worktree and task branch.
- [ ] The agent did not stash, reset, delete, or absorb unassigned
      pre-existing WIP.
- [ ] If ownership was unclear or another writer was present, the agent
      stopped without editing, committing, pushing, or merging.
'@
Assert-FileContainsExactContract `
    -RelativePath 'examples/verification-checklist.md' `
    -Expected $verificationChecklistContract `
    -Description 'orchestrator ownership verification checklist'

$verificationDeltaContract = @'
- [ ] For an existing baseline HEAD, `merge-base --is-ancestor` exited 0.
      Matching branch names or an assigned-only diff did not substitute for
      ancestry; rewritten or divergent history is a scope violation.
- [ ] Every acceptance artifact was opened and checked for required content;
      final existence, byte size, and SHA-256 were independently measured.
- [ ] Unchanged HEAD, porcelain, and initial-to-final assigned artifact state
      are classified as a no-op even if the artifact already existed.
- [ ] Empty final porcelain is accepted when HEAD changed, the
      baseline is an ancestor of final HEAD, the baseline-to-final diff contains
      only assigned paths, and artifact content passes acceptance.
- [ ] For an explicitly assigned dirty resume, initial and final artifact
      states were compared; identical porcelain path text alone was not treated
      as proof of either a no-op or a change.
- [ ] For a non-Git file-changing task, final existence, byte size, and SHA-256
      differ from the pre-edit baseline and content passes acceptance.
- [ ] Any unassigned path in initial/final porcelain or the committed diff is a
      scope violation. The agent did not alter, stage, commit, delete, or absorb
      unassigned WIP.
'@
Assert-FileContainsExactContract `
    -RelativePath 'examples/verification-checklist.md' `
    -Expected $verificationDeltaContract `
    -Description 'orchestrator baseline-to-final decision checklist'

$verificationAncestryCommandContract = @'
  git -C <repo> --no-optional-locks merge-base --is-ancestor <baseline> <final>
  git -C <repo> --no-optional-locks diff --name-status <baseline>..<final> --
  git -C <repo> --no-optional-locks status --porcelain=v1 --untracked-files=all
'@
Assert-FileContainsExactContract `
    -RelativePath 'examples/verification-checklist.md' `
    -Expected $verificationAncestryCommandContract `
    -Description 'orchestrator read-only ancestry measurement command'

$readmeSafetyContract = @'
- Every delegated editor must be the exclusive writer for its checkout.
  If unassigned existing WIP or another writer is present, stop without
  changing it and continue only after the orchestrator assigns an exclusive
  checkout or isolated worktree and task branch. A resumed agent may continue
  its own explicitly assigned WIP. See
  [delegation contract hardening](docs/delegation-contract-hardening.md).
'@
Assert-FileContainsExactContract `
    -RelativePath 'README.md' `
    -Expected $readmeSafetyContract `
    -Description 'public shared-checkout safety summary'

$readmeBaselineContract = @'
- Completion verification is baseline-aware: a pre-existing artifact with no
  initial-to-final delta is a no-op, while a clean committed task can be
  successful when baseline HEAD is an ancestor of final HEAD and its
  baseline-to-final diff and artifact content match the assignment. The
  orchestrator independently re-measures final evidence and rejects divergent
  history and unassigned paths. Baseline capture is read-only and never uses
  `git write-tree`. See
  [baseline-aware completion verification](docs/completion-baseline-verification.md).
'@
Assert-FileContainsExactContract `
    -RelativePath 'README.md' `
    -Expected $readmeBaselineContract `
    -Description 'public baseline-aware completion summary'

$readmeJapaneseBaselineContract = @'
- 編集前のbranch・完全HEAD OID・porcelain全出力・必要なartifact stateをread-onlyで
  baseline化し、完了後のHEAD/diff/current porcelain/内容と比較する。baseline HEADが
  存在する場合は`merge-base --is-ancestor`のexit 0を必須とする
'@
Assert-FileContainsExactContract `
    -RelativePath 'README.md' `
    -Expected $readmeJapaneseBaselineContract `
    -Description 'Japanese public baseline-aware completion summary'

$readmeJapaneseContract = @'
- 委譲プロンプトの必須文言（再委譲禁止・排他的 checkout または隔離 worktree の
  絶対パス・成果物の絶対パス・受け入れ条件・変更ファイル一覧の報告・書式制約）
- 編集前に checkout の排他的所有と未割当 WIP の不在を確認し、競合時は変更せず
  排他的 checkout または隔離 worktree を割り当てる
'@
Assert-FileContainsExactContract `
    -RelativePath 'README.md' `
    -Expected $readmeJapaneseContract `
    -Description 'Japanese public shared-checkout summary'

# reviewerが指摘した意味反転をmemory上のsynthetic fixtureとして固定し、部分一致への
# 退行をPowerShell 7 / 5.1の両hostで拒否する。
Assert-FileContractMutationRejected `
    -RelativePath 'SKILL.md' `
    -Expected $skillAbsolutePathsContract `
    -Needle 'the absolute' `
    -Replacement 'the relative' `
    -Description 'canonical absolute artifact path weakened'
Assert-FileContractMutationRejected `
    -RelativePath 'SKILL.md' `
    -Expected $skillOwnershipClause `
    -Needle 'Use an exclusive checkout or isolated worktree' `
    -Replacement 'Use the shared checkout or any worktree' `
    -Description 'canonical exclusive continuation reversed'
Assert-FileContractMutationRejected `
    -RelativePath 'SKILL.md' `
    -Expected $skillResumeContract `
    -Needle 'A resumed agent may continue its own' `
    -Replacement 'A resumed agent must abandon its own' `
    -Description 'canonical assigned-WIP resume exception reversed'
Assert-FileContractMutationRejected `
    -RelativePath 'SKILL.md' `
    -Expected $skillBaselineClause `
    -Needle 'Use read-only Git commands only; never use `git write-tree`' `
    -Replacement 'Use state-changing Git commands such as `git write-tree`' `
    -Description 'canonical read-only baseline reversed'
Assert-FileContractMutationRejected `
    -RelativePath 'SKILL.md' `
    -Expected $skillFinalMeasurementContract `
    -Needle 'independently re-measures' `
    -Replacement 'trusts the agent to measure' `
    -Description 'canonical independent final measurement reversed'
Assert-FileContractMutationRejected `
    -RelativePath 'SKILL.md' `
    -Expected $skillFinalMeasurementContract `
    -Needle 'must exit 0' `
    -Replacement 'may exit 1' `
    -Description 'canonical ancestry requirement reversed'
Assert-FileContractMutationRejected `
    -RelativePath 'SKILL.md' `
    -Expected $skillVerificationEvidenceContract `
    -Needle 'is a no-op even when the artifact already exists' `
    -Replacement 'is complete when the artifact already exists' `
    -Description 'canonical pre-existing artifact no-op reversed'
Assert-FileContractMutationRejected `
    -RelativePath 'docs/SKILL.ja.md' `
    -Expected $japaneseAbsolutePathsContract `
    -Needle '成果物の絶対パス' `
    -Replacement '成果物の相対パス' `
    -Description 'Japanese absolute artifact path weakened'
Assert-FileContractMutationRejected `
    -RelativePath 'docs/SKILL.ja.md' `
    -Expected $japaneseOwnershipClause `
    -Needle '行わず司令塔へ競合を' `
    -Replacement '行いながら司令塔へ競合を' `
    -Description 'Japanese conflict stop reversed'
Assert-FileContractMutationRejected `
    -RelativePath 'docs/SKILL.ja.md' `
    -Expected $japaneseResumeContract `
    -Needle '継続できる。' `
    -Replacement '継続できない。' `
    -Description 'Japanese assigned-WIP resume exception reversed'
Assert-FileContractMutationRejected `
    -RelativePath 'docs/SKILL.ja.md' `
    -Expected $japaneseBaselineClause `
    -Needle 'read-only Git commandだけを使い' `
    -Replacement 'state-changing Git commandを使い' `
    -Description 'Japanese read-only baseline reversed'
Assert-FileContractMutationRejected `
    -RelativePath 'docs/SKILL.ja.md' `
    -Expected $japaneseFinalMeasurementContract `
    -Needle '独立して' `
    -Replacement '委譲先を信頼して' `
    -Description 'Japanese independent final measurement reversed'
Assert-FileContractMutationRejected `
    -RelativePath 'docs/SKILL.ja.md' `
    -Expected $japaneseFinalMeasurementContract `
    -Needle 'exit 0を必須とし' `
    -Replacement 'exit 1も許容し' `
    -Description 'Japanese ancestry requirement reversed'
Assert-FileContractMutationRejected `
    -RelativePath 'docs/SKILL.ja.md' `
    -Expected $japaneseVerificationEvidenceContract `
    -Needle '既に存在しても空振り。' `
    -Replacement '既に存在すれば成功。' `
    -Description 'Japanese pre-existing artifact no-op reversed'
Assert-FileContractMutationRejected `
    -RelativePath 'examples/delegation-prompt-template.md' `
    -Expected $englishTemplateContract `
    -Needle '(assigned exclusively to you)' `
    -Replacement '(shared with other writers)' `
    -Description 'English template exclusive assignment reversed'
Assert-FileContractMutationRejected `
    -RelativePath 'examples/delegation-prompt-template.md' `
    -Expected $englishTemplateContract `
    -Needle 'stop and report the conflict.' `
    -Replacement 'continue while reporting the conflict.' `
    -Description 'English template conflict stop reversed'
Assert-FileContractMutationRejected `
    -RelativePath 'examples/delegation-prompt-template.md' `
    -Expected $englishTemplateContract `
    -Needle 'only in the exclusive checkout or isolated worktree' `
    -Replacement 'in any shared checkout or worktree' `
    -Description 'English template exclusive continuation reversed'
Assert-FileContractMutationRejected `
    -RelativePath 'examples/delegation-prompt-template.md' `
    -Expected $englishTemplateContract `
    -Needle 'use absolute artifact' `
    -Replacement 'use relative artifact' `
    -Description 'English template absolute artifact path weakened'
Assert-FileContractMutationRejected `
    -RelativePath 'examples/delegation-prompt-template.md' `
    -Expected $englishTemplateContract `
    -Needle 'Do not use `git write-tree`' `
    -Replacement 'Use `git write-tree`' `
    -Description 'English template read-only baseline reversed'
Assert-FileContractMutationRejected `
    -RelativePath 'examples/delegation-prompt-template.md' `
    -Expected $englishTemplateCompletionContract `
    -Needle 'is not a no-op merely' `
    -Replacement 'is always a no-op' `
    -Description 'English template clean commit result reversed'
Assert-FileContractMutationRejected `
    -RelativePath 'examples/delegation-prompt-template.md' `
    -Expected $englishTemplateCompletionContract `
    -Needle 'exit 0 is required' `
    -Replacement 'exit 1 is accepted' `
    -Description 'English template ancestry requirement reversed'
Assert-FileContractMutationRejected `
    -RelativePath 'examples/delegation-prompt-template.md' `
    -Expected $japaneseTemplateContract `
    -Needle '排他的 writer' `
    -Replacement '共有 writer' `
    -Description 'Japanese template exclusive writer reversed'
Assert-FileContractMutationRejected `
    -RelativePath 'examples/delegation-prompt-template.md' `
    -Expected $japaneseTemplateContract `
    -Needle '編集、commit、push、merge を行わない。' `
    -Replacement '編集、commit、push、merge を続ける。' `
    -Description 'Japanese template conflict stop reversed'
Assert-FileContractMutationRejected `
    -RelativePath 'examples/delegation-prompt-template.md' `
    -Expected $japaneseTemplateContract `
    -Needle 'baseline取得はread-onlyとし' `
    -Replacement 'baseline取得はstate-changingとし' `
    -Description 'Japanese template read-only baseline reversed'
Assert-FileContractMutationRejected `
    -RelativePath 'examples/delegation-prompt-template.md' `
    -Expected $japaneseTemplateCompletionContract `
    -Needle '空振りに しないが' `
    -Replacement '必ず空振りにする。' `
    -Description 'Japanese template clean commit result reversed'
Assert-FileContractMutationRejected `
    -RelativePath 'examples/delegation-prompt-template.md' `
    -Expected $japaneseTemplateCompletionContract `
    -Needle 'exit 0を 必須とする。' `
    -Replacement 'exit 1も許容する。' `
    -Description 'Japanese template ancestry requirement reversed'
Assert-FileContractMutationRejected `
    -RelativePath 'examples/verification-checklist.md' `
    -Expected $verificationChecklistContract `
    -Needle 'Before editing, the agent recorded its initial branch' `
    -Replacement 'Before editing, the agent skipped its initial branch' `
    -Description 'initial branch and status evidence removed'
Assert-FileContractMutationRejected `
    -RelativePath 'examples/verification-checklist.md' `
    -Expected $verificationChecklistContract `
    -Needle 'stopped without editing, committing, pushing, or merging.' `
    -Replacement 'continued while editing, committing, pushing, and merging.' `
    -Description 'checklist conflict stop reversed'
Assert-FileContractMutationRejected `
    -RelativePath 'examples/verification-checklist.md' `
    -Expected $verificationChecklistContract `
    -Needle 'Baseline collection used read-only commands only.' `
    -Replacement 'Baseline collection used state-changing commands.' `
    -Description 'checklist read-only baseline reversed'
Assert-FileContractMutationRejected `
    -RelativePath 'examples/verification-checklist.md' `
    -Expected $verificationAncestryCommandContract `
    -Needle 'merge-base --is-ancestor' `
    -Replacement 'merge-base' `
    -Description 'checklist ancestry command weakened'
Assert-FileContractMutationRejected `
    -RelativePath 'examples/verification-checklist.md' `
    -Expected $verificationDeltaContract `
    -Needle '`merge-base --is-ancestor` exited 0.' `
    -Replacement '`merge-base --is-ancestor` may exit 1.' `
    -Description 'checklist ancestry requirement reversed'
Assert-FileContractMutationRejected `
    -RelativePath 'examples/verification-checklist.md' `
    -Expected $verificationDeltaContract `
    -Needle 'are classified as a no-op' `
    -Replacement 'are classified as complete' `
    -Description 'checklist pre-existing artifact no-op reversed'
Assert-FileContractMutationRejected `
    -RelativePath 'examples/verification-checklist.md' `
    -Expected $verificationDeltaContract `
    -Needle 'Empty final porcelain is accepted' `
    -Replacement 'Empty final porcelain is rejected' `
    -Description 'checklist clean commit result reversed'
Assert-FileContractMutationRejected `
    -RelativePath 'README.md' `
    -Expected $readmeSafetyContract `
    -Needle 'stop without' `
    -Replacement 'continue while' `
    -Description 'public fail-closed wording reversed'
Assert-FileContractMutationRejected `
    -RelativePath 'README.md' `
    -Expected $readmeSafetyContract `
    -Needle 'A resumed agent may continue' `
    -Replacement 'A resumed agent must discard' `
    -Description 'public assigned-WIP resume exception reversed'
Assert-FileContractMutationRejected `
    -RelativePath 'README.md' `
    -Expected $readmeBaselineContract `
    -Needle 'baseline HEAD is an ancestor of final HEAD' `
    -Replacement 'the branch name matches at final HEAD' `
    -Description 'public ancestry requirement reversed'
Assert-FileContractMutationRejected `
    -RelativePath 'README.md' `
    -Expected $readmeBaselineContract `
    -Needle 'is a no-op' `
    -Replacement 'is complete' `
    -Description 'public pre-existing artifact no-op reversed'
Assert-FileContractMutationRejected `
    -RelativePath 'README.md' `
    -Expected $readmeBaselineContract `
    -Needle 'never uses `git write-tree`' `
    -Replacement 'always uses `git write-tree`' `
    -Description 'public read-only baseline reversed'
Assert-FileContractMutationRejected `
    -RelativePath 'README.md' `
    -Expected $readmeJapaneseBaselineContract `
    -Needle 'artifact stateをread-onlyで' `
    -Replacement 'artifact stateをstate-changingで' `
    -Description 'Japanese public read-only baseline reversed'
Assert-FileContractMutationRejected `
    -RelativePath 'README.md' `
    -Expected $readmeJapaneseBaselineContract `
    -Needle 'exit 0を必須とする' `
    -Replacement 'exit 1も許容する' `
    -Description 'Japanese public ancestry requirement reversed'
Assert-FileContractMutationRejected `
    -RelativePath 'README.md' `
    -Expected $readmeJapaneseContract `
    -Needle '排他的 checkout または隔離 worktree の' `
    -Replacement '排他的 worktree の' `
    -Description 'Japanese summary over-restricted to worktree'
$syntheticProcessFixtureGateContract = @(
    'Assert-BaselineAwareCompletionPureDecisionFixtures',
    'Assert-SyntheticGitProcessFixtureCapabilityDecisions',
    'if (Test-SyntheticGitProcessFixtureSupported) {',
    '    Assert-BaselineAwareCompletionSemanticFixtures',
    '}'
) -join "`n"
Assert-FileContainsExactContract `
    -RelativePath 'scripts/validate-oss-readiness.ps1' `
    -Expected $syntheticProcessFixtureGateContract `
    -Description 'pure completion fixtures and capability-gated process fixture'
Assert-FileContractMutationRejected `
    -RelativePath 'scripts/validate-oss-readiness.ps1' `
    -Expected $syntheticProcessFixtureGateContract `
    -Needle 'if (Test-SyntheticGitProcessFixtureSupported) {' `
    -Replacement 'if ($true) {' `
    -Description 'synthetic process fixture capability gate removed'
Assert-FileContractMutationRejected `
    -RelativePath 'scripts/validate-oss-readiness.ps1' `
    -Expected $syntheticProcessFixtureGateContract `
    -Needle 'if (Test-SyntheticGitProcessFixtureSupported) {' `
    -Replacement 'if ($false) {' `
    -Description 'synthetic process fixture forced to always skip'
Assert-FileContains `
    -RelativePath 'scripts/validate-oss-readiness.ps1' `
    -Pattern '(?s)function\s+Test-SyntheticGitProcessFixtureSupported.*?\[System\.PlatformID\]::Win32NT.*?Get-PrivateMarkerTrustedSetsidPath.*?\[System\.IO\.Path\]::IsPathRooted.*?\[System\.IO\.File\]::Exists.*?Test-SyntheticGitProcessFixtureCapabilityDecision' `
    -Description 'production-aligned Windows or fixed trusted setsid capability'
Assert-FileContains -RelativePath '.gitignore' -Pattern '\.private-markers\.local' -Description 'ignore local private marker files'
Assert-FileContains -RelativePath 'CONTRIBUTING.md' -Pattern '(?im)no token|never.*token|secret' -Description 'secret-safe contribution guidance'
Assert-FileContains -RelativePath 'SECURITY.md' -Pattern '(?im)do not.*public|private|security' -Description 'private vulnerability reporting guidance'
Assert-FileContains `
    -RelativePath 'scripts/scan-private-markers.ps1' `
    -Pattern '(?s)\[object\]\$ScanDeadlineMilliseconds.*?\[int\]::TryParse\(.*?\[ref\]\$parsedScanDeadline.*?\$ScanDeadlineMilliseconds\s*=\s*\$parsedScanDeadline.*?\$ScanDeadlineMilliseconds\s*-lt\s*1.*?\$ScanDeadlineMilliseconds\s*-gt\s*120000' `
    -Description 'raw integer and range validated public scan deadline seam'
Assert-FileContains `
    -RelativePath 'scripts/scan-private-markers-v2.ps1' `
    -Pattern '(?s)\[object\]\$ScanDeadlineMilliseconds.*?\[int\]::TryParse\(.*?\[ref\]\$parsedScanDeadline.*?\$ScanDeadlineMilliseconds\s*=\s*\$parsedScanDeadline.*?throw\s+''scan-deadline-invalid''.*?Write-FixedStartupFailure\s+-Code\s+''scan-deadline-invalid''' `
    -Description 'raw integer and range validated implementation scan deadline seam'
Assert-FileContains `
    -RelativePath 'scripts/scan-private-markers-v2.ps1' `
    -Pattern '(?s)\$destination\s*=\s*\[Console\]::OpenStandardOutput\(\).*?Test-ScanDeadline\s*\$destination\.Write\(' `
    -Description 'deadline check immediately before final finding/failure/success write'
Assert-FileContains `
    -RelativePath 'scripts/scan-private-markers-v2.ps1' `
    -Pattern '(?s)function\s+Write-FixedRuntimeFailure.*?\$stream\s*=\s*\[Console\]::OpenStandardOutput\(\)\s*#.*?Test-ScanDeadline\s*\$stream\.Write\(' `
    -Description 'deadline check immediately before runtime diagnostic write'
# 親environmentの将来の再複製と、Git/reader固有値の混線を静的契約でも止める。
Assert-FileContains `
    -RelativePath 'scripts/private-marker-process-runner.psm1' `
    -Pattern '(?s)function\s+New-PrivateMarkerChildEnvironment.*?\[Environment\]::SystemDirectory.*?\$environment\[''SystemRoot''\]\s*=\s*\$windowsRoot\.FullName.*?return\s+\$environment' `
    -Description 'OS-derived fixed minimal child environment'
Assert-FileDoesNotContain `
    -RelativePath 'scripts/private-marker-process-runner.psm1' `
    -Pattern 'GetEnvironmentVariables' `
    -Description 'ambient process-environment enumeration'
Assert-FileContains `
    -RelativePath 'scripts/scan-private-markers-v2.ps1' `
    -Pattern '(?s)function\s+New-ChildEnvironment\s*\{.*?return\s+New-PrivateMarkerChildEnvironment.*?function\s+ConvertFrom-StrictUtf8' `
    -Description 'scanner child environment delegates to the fixed allowlist'
Assert-FileContains `
    -RelativePath 'scripts/scan-private-markers-v2.ps1' `
    -Pattern '(?s)\$readerEnvironment\s*=\s*New-ChildEnvironment.*?POWERSHELL_TELEMETRY_OPTOUT.*?POWERSHELL_UPDATECHECK.*?MULTI_AGENT_DELEGATION_SCAN_INPUT' `
    -Description 'file reader receives only explicit offline and input values'
Assert-FileContains `
    -RelativePath 'scripts/scan-private-markers-v2.ps1' `
    -Pattern '(?s)function\s+Get-NativeGitApplicationPath.*?Get-Command\s+`\s*git\s+`\s*-CommandType\s+Application.*?\$commands\.Count\s+-eq\s+0.*?\$commands\[0\]\.Path.*?\[System\.IO\.Path\]::IsPathRooted.*?Test-Path\s+-LiteralPath\s+\$candidate\s+-PathType\s+Leaf.*?\$item\s+-isnot\s+\[System\.IO\.FileInfo\].*?\[System\.IO\.FileAttributes\]::ReparsePoint.*?return\s+\$item\.FullName' `
    -Description 'rooted regular native Git application resolution'
Assert-FileContains `
    -RelativePath 'scripts/test-scan-private-markers.ps1' `
    -Pattern '(?s)Assert-ProductionChildEnvironmentAllowlist.*?SYNTHETIC_UNKNOWN_NON_GIT_AMBIENT.*?LD_PRELOAD.*?GITHUB_TOKEN.*?New-PrivateMarkerChildEnvironment' `
    -Description 'ambient loader and credential child-environment regression'
Assert-FileContains `
    -RelativePath 'scripts/private-marker-process-runner.psm1' `
    -Pattern 'if\s*\(\s*!TerminateJobObject\(' `
    -Description 'checked Windows Job termination result'
Assert-FileContains `
    -RelativePath 'scripts/private-marker-process-runner.psm1' `
    -Pattern 'launchCleanupWait\s*!=\s*WaitObject0' `
    -Description 'checked Windows launch cleanup wait result'
Assert-FileContains `
    -RelativePath 'scripts/private-marker-process-runner.psm1' `
    -Pattern 'windows-thread-handle-close-failed' `
    -Description 'checked Windows thread handle close result'
Assert-FileContains `
    -RelativePath 'scripts/private-marker-process-runner.psm1' `
    -Pattern 'windows-process-handle-close-failed' `
    -Description 'checked Windows process handle close result'
Assert-FileContains `
    -RelativePath 'scripts/private-marker-process-runner.psm1' `
    -Pattern 'windows-job-handle-close-failed' `
    -Description 'checked Windows Job handle close result'
Assert-FileContains `
    -RelativePath 'scripts/private-marker-process-runner.psm1' `
    -Pattern 'if\s*\(\s*!CloseHandle\(handle\)\s*\)' `
    -Description 'checked Windows raw handle close result'
Assert-FileContains `
    -RelativePath 'scripts/private-marker-process-runner.psm1' `
    -Pattern 'if\s*\(\s*!process\.WaitForExit\(' `
    -Description 'checked POSIX direct rewait result'
Assert-FileContains `
    -RelativePath 'scripts/private-marker-process-runner.psm1' `
    -Pattern '(?s)CreatePosixLaunchGate\(\).*?mkdir\(root,\s*PosixOwnerOnlyDirectoryMode\).*?WaitForVerifiedPosixGroup\(.*?GetPosixProcessGroupId\(.*?processGroupId\s*==\s*readyProcessId' `
    -Description 'owner-only POSIX gate and verified process-group leader'
Assert-FileContains `
    -RelativePath 'scripts/private-marker-process-runner.psm1' `
    -Pattern '(?s)ThrowIfOperationTimedOut\(\s*operationStopwatch,\s*timeoutMilliseconds\s*\).*?CreatePosixRelease\(launchGate\.Release\)' `
    -Description 'POSIX release occurs only after the final operation deadline check'
Assert-FileContains `
    -RelativePath 'scripts/private-marker-process-runner.psm1' `
    -Pattern '(?s)TerminateUnreleasedPosixLaunch\(.*?TryReadPosixReadyPid\(.*?TerminatePosixGroup\(.*?CleanupPosixLaunchGate' `
    -Description 'bounded late-ready termination and private gate cleanup'
Assert-FileContains `
    -RelativePath 'scripts/private-marker-process-runner.psm1' `
    -Pattern '(?s)posix-process-cleanup-failed.*?cleanupFailure' `
    -Description 'aggregated POSIX termination and dispose cleanup failures'
Assert-FileContains `
    -RelativePath 'scripts/test-scan-private-markers.ps1' `
    -Pattern '(?s)fake-setsid-direct-delay\.sh.*?fake-setsid-fork-delay\.sh.*?PRIVATE_MARKER_TEST_GATE_CAPTURE.*?process-timeout.*?capturedGateRoot' `
    -Description 'POSIX direct-delay and fork-delay launch-gate regressions'
Assert-FileContains `
    -RelativePath 'scripts/test-scan-private-markers.ps1' `
    -Pattern 'LastSyntheticFailureProcessId' `
    -Description 'Windows launch failure PID regression'
Assert-FileContains `
    -RelativePath 'scripts/test-scan-private-markers.ps1' `
    -Pattern 'windows-launch-failure-\$launchFailureMode\.sentinel' `
    -Description 'Windows suspended launch sentinel regression'
Assert-FileContains `
    -RelativePath 'scripts/private-marker-process-runner.psm1' `
    -Pattern '(?s)job-close.*?windows-launch-process-fallback-termination-failed.*?forceFirstJobCloseFailure.*?LastSyntheticJobCloseRetrySucceeded' `
    -Description 'Windows Job cleanup fallback and retained-handle retry'
Assert-FileContains `
    -RelativePath 'scripts/test-scan-private-markers.ps1' `
    -Pattern '(?s)LastSyntheticTerminateProcessFallbackUsed.*?LastSyntheticJobCloseRetrySucceeded' `
    -Description 'Windows Job cleanup fault-injection evidence'
Assert-FileContains `
    -RelativePath 'scripts/private-marker-process-runner.psm1' `
    -Pattern '(?s)DisposeStream\(ref stdoutStream\).*?stdout\.Dispose\(\).*?stderr\.Dispose\(\).*?stdin\.Dispose\(\)' `
    -Description 'explicit Windows success pump and stream disposal'
Assert-FileContains `
    -RelativePath 'scripts/private-marker-process-runner.psm1' `
    -Pattern '(?s)RunPosix\(.*?PrivateMarkerReadPump stdout = null.*?finally.*?DisposePumps\(stdout, stderr, stdin\).*?WaitPumpsBounded\(.*?DisposePumps\(stdout, stderr, stdin\).*?process\.Dispose\(\)' `
    -Description 'explicit POSIX pump, task, stream, and buffer disposal'
Assert-FileContains `
    -RelativePath 'scripts/private-marker-process-runner.psm1' `
    -Pattern '(?s)Stopwatch operationStopwatch = Stopwatch\.StartNew\(\).*?RunWindows\(.*?operationStopwatch.*?RunPosix\(.*?operationStopwatch' `
    -Description 'operation deadline established before OS process launch'
Assert-FileContains `
    -RelativePath 'scripts/private-marker-process-runner.psm1' `
    -Pattern '(?s)ThrowIfOperationTimedOut\(\s*operationStopwatch,\s*timeoutMilliseconds\s*\).*?CreateProcessW\(.*?ThrowIfOperationTimedOut\(\s*operationStopwatch,\s*timeoutMilliseconds\s*\).*?ResumeThread' `
    -Description 'Windows deadline checks before create and resume'
Assert-FileContains `
    -RelativePath 'scripts/private-marker-process-runner.psm1' `
    -Pattern '(?s)RunPosix\(.*?ApplyProcessEnvironment\(startInfo, environment\).*?ThrowIfOperationTimedOut\(\s*operationStopwatch,\s*timeoutMilliseconds\s*\).*?process\.Start\(\)' `
    -Description 'POSIX deadline check before process start'
Assert-FileContains `
    -RelativePath 'scripts/private-marker-process-runner.psm1' `
    -Pattern '(?s)ConvertTo-PrivateMarkerBoundedInteger.*?\^\[0-9\]\+\$.*?\[object\]\$TimeoutMilliseconds.*?\[object\]\$KillWaitMilliseconds.*?\[object\]\$MaxStandardOutputBytes.*?\[object\]\$MaxStandardErrorBytes' `
    -Description 'raw integer validation for exported runner numeric arguments'
$windowsHandleProbePath = Get-RepoFilePath `
    -RelativePath 'scripts/test-private-marker-handle-stability.ps1'
if (-not (Test-Path -LiteralPath $windowsHandleProbePath -PathType Leaf)) {
    Add-Failure 'Cannot inspect missing Windows handle stability regression.'
} else {
    $windowsHandleProbeSource = Get-Content `
        -LiteralPath $windowsHandleProbePath `
        -Raw
    if (
        -not (
            Test-WindowsHandleProbeContract `
                -Source $windowsHandleProbeSource
        )
    ) {
        Add-Failure (
            'scripts/test-private-marker-handle-stability.ps1 is missing: ' +
            'bounded startup, calibration, measured, and confirmation Windows handle regressions without GC'
        )
    }

    # 各windowだけを0回へ変えても必ずrejectされることを別々に検証する。同時に
    # 変えるfixtureでは、一方のheader検査が欠けてもnegativeになり得るため分離する。
    $windowsHandleZeroRunCases = @(
        [pscustomobject]@{
            Name = 'startup'
            Before = '$handleWarmupAttempt = 0;'
            After = '$handleWarmupAttempt = $handleWarmupRuns;'
        },
        [pscustomobject]@{
            Name = 'warmup quiescence'
            Before = '$handleWarmupQuiescenceAttempt = 0;'
            After = (
                '$handleWarmupQuiescenceAttempt = ' +
                '$handleQuiescenceSamples;'
            )
        },
        [pscustomobject]@{
            Name = 'calibration'
            Before = '$handleCalibrationAttempt = 0;'
            After = (
                '$handleCalibrationAttempt = ' +
                '$handleCalibrationRuns;'
            )
        },
        [pscustomobject]@{
            Name = 'calibration quiescence'
            Before = '$handleCalibrationQuiescenceAttempt = 0;'
            After = (
                '$handleCalibrationQuiescenceAttempt = ' +
                '$handleQuiescenceSamples;'
            )
        },
        [pscustomobject]@{
            Name = 'steady-state'
            Before = '$handleAttempt = 0;'
            After = '$handleAttempt = $handleMeasuredRuns;'
        },
        [pscustomobject]@{
            Name = 'measured quiescence'
            Before = '$handleMeasuredQuiescenceAttempt = 0;'
            After = (
                '$handleMeasuredQuiescenceAttempt = ' +
                '$handleQuiescenceSamples;'
            )
        },
        [pscustomobject]@{
            Name = 'confirmation'
            Before = '$handleConfirmationAttempt = 0;'
            After = (
                '$handleConfirmationAttempt = ' +
                '$handleConfirmationRuns;'
            )
        },
        [pscustomobject]@{
            Name = 'confirmation quiescence'
            Before = '$handleConfirmationQuiescenceAttempt = 0;'
            After = (
                '$handleConfirmationQuiescenceAttempt = ' +
                '$handleQuiescenceSamples;'
            )
        }
    )
    foreach ($zeroRunCase in $windowsHandleZeroRunCases) {
        $zeroRunFixture = $windowsHandleProbeSource.Replace(
            $zeroRunCase.Before,
            $zeroRunCase.After
        )
        if (
            [string]::Equals(
                $zeroRunFixture,
                $windowsHandleProbeSource,
                [System.StringComparison]::Ordinal
            )
        ) {
            Add-Failure (
                'Windows handle readiness zero-run fixture setup failed: ' +
                $zeroRunCase.Name
            )
        } elseif (
            Test-WindowsHandleProbeAstContract -Source $zeroRunFixture
        ) {
            Add-Failure (
                'Windows handle readiness AST contract accepts a zero-run ' +
                $zeroRunCase.Name +
                ' window.'
            )
        }
    }

    # headerを変えずlimitを再代入・短縮・緩和する変異もrejectする。
    # evidence直前に80へ戻して表示値だけ正規化しても、代入数検査で失敗する。
    $windowsHandleLimitReassignmentCases = @(
        [pscustomobject]@{
            Name = 'startup'
            Before = '$handleWarmupRuns = 80'
            After = (
                '$handleWarmupRuns = 80' +
                "`n    " +
                '$handleWarmupRuns = 0'
            )
        },
        [pscustomobject]@{
            Name = 'startup shortened'
            Before = '$handleWarmupRuns = 80'
            After = '$handleWarmupRuns = 40'
        },
        [pscustomobject]@{
            Name = 'startup / plateau growth relaxed'
            Before = '$handleStartupGrowthLimit = 16'
            After = '$handleStartupGrowthLimit = 17'
        },
        [pscustomobject]@{
            Name = 'calibration'
            Before = '$handleCalibrationRuns = 40'
            After = (
                '$handleCalibrationRuns = 40' +
                "`n    " +
                '$handleCalibrationRuns = 0'
            )
        },
        [pscustomobject]@{
            Name = 'steady-state'
            Before = '$handleMeasuredRuns = 40'
            After = (
                '$handleMeasuredRuns = 40' +
                "`n    " +
                '$handleMeasuredRuns = 0'
            )
        },
        [pscustomobject]@{
            Name = 'confirmation'
            Before = '$handleConfirmationRuns = 40'
            After = (
                '$handleConfirmationRuns = 40' +
                "`n    " +
                '$handleConfirmationRuns = 0'
            )
        },
        [pscustomobject]@{
            Name = 'steady growth relaxed'
            Before = '$handleMeasuredFinalGrowthLimit = 4'
            After = '$handleMeasuredFinalGrowthLimit = 5'
        },
        [pscustomobject]@{
            Name = 'quiescence samples'
            Before = '$handleQuiescenceSamples = 10'
            After = (
                '$handleQuiescenceSamples = 10' +
                "`n    " +
                '$handleQuiescenceSamples = 0'
            )
        },
        [pscustomobject]@{
            Name = 'quiescence wait'
            Before = '$handleQuiescenceWaitMilliseconds = 50'
            After = (
                '$handleQuiescenceWaitMilliseconds = 50' +
                "`n    " +
                '$handleQuiescenceWaitMilliseconds = 0'
            )
        }
    )
    foreach (
        $limitReassignmentCase in $windowsHandleLimitReassignmentCases
    ) {
        $limitReassignmentFixture = $windowsHandleProbeSource.Replace(
            $limitReassignmentCase.Before,
            $limitReassignmentCase.After
        )
        $limitFixtureTokens = $null
        $limitFixtureParseErrors = $null
        [System.Management.Automation.Language.Parser]::ParseInput(
            $limitReassignmentFixture,
            [ref]$limitFixtureTokens,
            [ref]$limitFixtureParseErrors
        ) | Out-Null
        if (
            [string]::Equals(
                $limitReassignmentFixture,
                $windowsHandleProbeSource,
                [System.StringComparison]::Ordinal
            ) -or
            $limitFixtureParseErrors.Count -ne 0
        ) {
            Add-Failure (
                'Windows handle readiness limit-reassignment fixture setup ' +
                'failed: ' +
                $limitReassignmentCase.Name
            )
        } elseif (
            Test-WindowsHandleProbeAstContract `
                -Source $limitReassignmentFixture
        ) {
            Add-Failure (
                'Windows handle readiness AST contract accepts a reassigned ' +
                $limitReassignmentCase.Name +
                ' limit.'
            )
        }
    }

    # 同じresult変数へdummy commandの返り値を入れるだけの置換もrejectする。
    # 出力shapeだけを模倣して実runnerを一度も呼ばない退行をpositiveにしない。
    $windowsHandleRunnerSubstitutionCases = @(
        [pscustomobject]@{
            Name = 'startup'
            Before = (
                '$handleWarmupResult = ' +
                'private-marker-process-runner\' +
                'Invoke-PrivateMarkerBoundedProcess'
            )
            After = '$handleWarmupResult = New-PrivateMarkerDummyResult'
        },
        [pscustomobject]@{
            Name = 'calibration'
            Before = (
                '$handleCalibrationResult = ' +
                'private-marker-process-runner\' +
                'Invoke-PrivateMarkerBoundedProcess'
            )
            After = '$handleCalibrationResult = New-PrivateMarkerDummyResult'
        },
        [pscustomobject]@{
            Name = 'steady-state'
            Before = (
                '$handleProbeResult = ' +
                'private-marker-process-runner\' +
                'Invoke-PrivateMarkerBoundedProcess'
            )
            After = '$handleProbeResult = New-PrivateMarkerDummyResult'
        },
        [pscustomobject]@{
            Name = 'confirmation'
            Before = (
                '$handleConfirmationResult = ' +
                'private-marker-process-runner\' +
                'Invoke-PrivateMarkerBoundedProcess'
            )
            After = (
                '$handleConfirmationResult = ' +
                'New-PrivateMarkerDummyResult'
            )
        }
    )
    foreach (
        $runnerSubstitutionCase in $windowsHandleRunnerSubstitutionCases
    ) {
        $runnerSubstitutionFixture = $windowsHandleProbeSource.Replace(
            $runnerSubstitutionCase.Before,
            $runnerSubstitutionCase.After
        )
        $runnerFixtureTokens = $null
        $runnerFixtureParseErrors = $null
        [System.Management.Automation.Language.Parser]::ParseInput(
            $runnerSubstitutionFixture,
            [ref]$runnerFixtureTokens,
            [ref]$runnerFixtureParseErrors
        ) | Out-Null
        if (
            [string]::Equals(
                $runnerSubstitutionFixture,
                $windowsHandleProbeSource,
                [System.StringComparison]::Ordinal
            ) -or
            $runnerFixtureParseErrors.Count -ne 0
        ) {
            Add-Failure (
                'Windows handle readiness runner-substitution fixture setup ' +
                'failed: ' +
                $runnerSubstitutionCase.Name
            )
        } elseif (
            Test-WindowsHandleProbeAstContract `
                -Source $runnerSubstitutionFixture
        ) {
            Add-Failure (
                'Windows handle readiness AST contract accepts a dummy ' +
                $runnerSubstitutionCase.Name +
                ' runner.'
            )
        }
    }

    # import後に同名local functionを置くcommand-resolution shadowもrejectする。
    # production call自体もmodule-qualifiedに固定し、静的契約とruntime双方で守る。
    $handleProbeImportStatement = (
        'Microsoft.PowerShell.Core\Import-Module ' +
        '$processRunnerModule -Force'
    )
    $providerShadowMutation = @'
Microsoft.PowerShell.Management\Set-Item `
    -LiteralPath Function:New-PrivateMarkerDummyResult `
    -Value {
        [pscustomobject]@{
            ExitCode = 0
            StandardOutputBytes = [byte[]]@()
            StandardErrorBytes = [byte[]]@()
        }
    }
Microsoft.PowerShell.Utility\Set-Alias `
    -Name 'private-marker-process-runner\Invoke-PrivateMarkerBoundedProcess' `
    -Value 'New-PrivateMarkerDummyResult'
'@
    $canonicalSealMutationCases = @(
        [pscustomobject]@{
            Name = 'runtime limit mutation'
            Before = '$handleWarmupRuns = 80'
            After = (
                '$handleWarmupRuns = 80' +
                "`n    " +
                'Set-Variable -Name handleWarmupRuns -Value 0'
            )
        },
        [pscustomobject]@{
            Name = 'runner argument control flow'
            Before = '-FilePath $handleProbeTarget'
            After = '-FilePath $(continue)'
        },
        [pscustomobject]@{
            Name = 'provider command shadow'
            Before = $handleProbeImportStatement
            After = (
                $handleProbeImportStatement +
                "`n`n" +
                $providerShadowMutation
            )
        }
    )
    foreach ($canonicalSealMutationCase in $canonicalSealMutationCases) {
        $canonicalSealFixture = $windowsHandleProbeSource.Replace(
            $canonicalSealMutationCase.Before,
            $canonicalSealMutationCase.After
        )
        $canonicalSealTokens = $null
        $canonicalSealParseErrors = $null
        [System.Management.Automation.Language.Parser]::ParseInput(
            $canonicalSealFixture,
            [ref]$canonicalSealTokens,
            [ref]$canonicalSealParseErrors
        ) | Out-Null
        if (
            [string]::Equals(
                $canonicalSealFixture,
                $windowsHandleProbeSource,
                [System.StringComparison]::Ordinal
            ) -or
            $canonicalSealParseErrors.Count -ne 0
        ) {
            Add-Failure (
                'Windows handle readiness canonical-seal fixture setup ' +
                'failed: ' +
                $canonicalSealMutationCase.Name
            )
        } elseif (
            Test-WindowsHandleProbeContract -Source $canonicalSealFixture
        ) {
            Add-Failure (
                'Windows handle readiness canonical source seal accepts: ' +
                $canonicalSealMutationCase.Name
            )
        }
    }

    $handleProbeShadowFunction = @'
function Invoke-PrivateMarkerBoundedProcess {
    [pscustomobject]@{
        ExitCode = 0
        StandardOutputBytes = [byte[]]@()
        StandardErrorBytes = [byte[]]@()
    }
}
'@
    $shadowFixtureReplacement = (
        $handleProbeImportStatement +
        "`n`n" +
        $handleProbeShadowFunction
    )
    $shadowFunctionFixture = $windowsHandleProbeSource.Replace(
        $handleProbeImportStatement,
        $shadowFixtureReplacement
    )
    $shadowFixtureTokens = $null
    $shadowFixtureParseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseInput(
        $shadowFunctionFixture,
        [ref]$shadowFixtureTokens,
        [ref]$shadowFixtureParseErrors
    ) | Out-Null
    if (
        [string]::Equals(
            $shadowFunctionFixture,
            $windowsHandleProbeSource,
            [System.StringComparison]::Ordinal
        ) -or
        $shadowFixtureParseErrors.Count -ne 0
    ) {
        Add-Failure (
            'Windows handle readiness command-shadow fixture setup failed.'
        )
    } elseif (
        Test-WindowsHandleProbeAstContract -Source $shadowFunctionFixture
    ) {
        Add-Failure (
            'Windows handle readiness AST contract accepts a local runner ' +
            'function shadow.'
        )
    }

    # body全体を到達不能なifへ包む変異も各windowごとに拒否する。
    # ASTのbody offsetから組み立てることで、runner文字列を残した実際的なbypassを
    # validator自身へのnegative controlとして維持する。
    $fixtureTokens = $null
    $fixtureParseErrors = $null
    $fixtureAst = [System.Management.Automation.Language.Parser]::ParseInput(
        $windowsHandleProbeSource,
        [ref]$fixtureTokens,
        [ref]$fixtureParseErrors
    )
    $fixtureForStatements = @(
        $fixtureAst.FindAll(
            {
                param($node)
                $node -is [System.Management.Automation.Language.ForStatementAst]
            },
            $true
        )
    )
    $conditionalBodyCases = @(
        [pscustomobject]@{
            Name = 'startup'
            Loops = @(
                $fixtureForStatements |
                    Where-Object {
                        $_.Condition.Extent.Text -match (
                            '^\s*\$handleWarmupAttempt\s*-lt\s*' +
                            '\$handleWarmupRuns\s*$'
                        )
                    }
            )
        },
        [pscustomobject]@{
            Name = 'warmup quiescence'
            Loops = @(
                $fixtureForStatements |
                    Where-Object {
                        $_.Condition.Extent.Text -match (
                            '^\s*\$handleWarmupQuiescenceAttempt\s*' +
                            '-lt\s*\$handleQuiescenceSamples\s*$'
                        )
                    }
            )
        },
        [pscustomobject]@{
            Name = 'calibration'
            Loops = @(
                $fixtureForStatements |
                    Where-Object {
                        $_.Condition.Extent.Text -match (
                            '^\s*\$handleCalibrationAttempt\s*-lt\s*' +
                            '\$handleCalibrationRuns\s*$'
                        )
                    }
            )
        },
        [pscustomobject]@{
            Name = 'calibration quiescence'
            Loops = @(
                $fixtureForStatements |
                    Where-Object {
                        $_.Condition.Extent.Text -match (
                            '^\s*\$handleCalibrationQuiescenceAttempt\s*' +
                            '-lt\s*\$handleQuiescenceSamples\s*$'
                        )
                    }
            )
        },
        [pscustomobject]@{
            Name = 'steady-state'
            Loops = @(
                $fixtureForStatements |
                    Where-Object {
                        $_.Condition.Extent.Text -match (
                            '^\s*\$handleAttempt\s*-lt\s*' +
                            '\$handleMeasuredRuns\s*$'
                        )
                    }
            )
        },
        [pscustomobject]@{
            Name = 'measured quiescence'
            Loops = @(
                $fixtureForStatements |
                    Where-Object {
                        $_.Condition.Extent.Text -match (
                            '^\s*\$handleMeasuredQuiescenceAttempt\s*' +
                            '-lt\s*\$handleQuiescenceSamples\s*$'
                        )
                    }
            )
        },
        [pscustomobject]@{
            Name = 'confirmation'
            Loops = @(
                $fixtureForStatements |
                    Where-Object {
                        $_.Condition.Extent.Text -match (
                            '^\s*\$handleConfirmationAttempt\s*-lt\s*' +
                            '\$handleConfirmationRuns\s*$'
                        )
                    }
            )
        },
        [pscustomobject]@{
            Name = 'confirmation quiescence'
            Loops = @(
                $fixtureForStatements |
                    Where-Object {
                        $_.Condition.Extent.Text -match (
                            '^\s*\$handleConfirmationQuiescenceAttempt\s*' +
                            '-lt\s*\$handleQuiescenceSamples\s*$'
                        )
                    }
            )
        }
    )
    foreach ($conditionalBodyCase in $conditionalBodyCases) {
        if (
            $fixtureParseErrors.Count -ne 0 -or
            $conditionalBodyCase.Loops.Count -ne 1
        ) {
            Add-Failure (
                'Windows handle readiness conditional-body fixture setup ' +
                'failed: ' +
                $conditionalBodyCase.Name
            )
            continue
        }

        $fixtureBodyExtent = $conditionalBodyCase.Loops[0].Body.Extent
        $conditionalBodyFixture = $windowsHandleProbeSource.Insert(
            $fixtureBodyExtent.EndOffset - 1,
            "`n        }`n    "
        )
        $conditionalBodyFixture = $conditionalBodyFixture.Insert(
            $fixtureBodyExtent.StartOffset + 1,
            "`n        if (`$false) {"
        )
        $conditionalTokens = $null
        $conditionalParseErrors = $null
        [System.Management.Automation.Language.Parser]::ParseInput(
            $conditionalBodyFixture,
            [ref]$conditionalTokens,
            [ref]$conditionalParseErrors
        ) | Out-Null
        if ($conditionalParseErrors.Count -ne 0) {
            Add-Failure (
                'Windows handle readiness conditional-body fixture parse ' +
                'failed: ' +
                $conditionalBodyCase.Name
            )
        } elseif (
            Test-WindowsHandleProbeAstContract `
                -Source $conditionalBodyFixture
        ) {
            Add-Failure (
                'Windows handle readiness AST contract accepts a conditional ' +
                $conditionalBodyCase.Name +
                ' body.'
            )
        }
    }
}

# 実測した単発+5 plateauは、次windowで増え続けない限りpassする。
# startup累積超過または2つのsteady windowに連続する+5はlimit 16/4のままfailする。
$runtimeStartupTransientSeries = @(
    600, 598, 590, 587, 587, 587, 587, 587, 587, 587
)
$runtimeCalibrationPlateauSeries = @(
    597, 597, 597, 597, 597, 597, 597, 597, 597, 597
)
$runtimeMeasuredPlateauSeries = @(
    597, 597, 597, 597, 597, 597, 597, 597, 597, 597
)
$runtimeCalibration592Series = @(
    592, 592, 592, 592, 592, 592, 592, 592, 592, 592
)
$persistentStartupSeries = @(
    117, 117, 117, 117, 117, 117, 117, 117, 117, 117
)
$persistentMeasuredSeries = @(
    115, 115, 115, 115, 115, 115, 115, 115, 115, 115
)
$persistentConfirmationSeries = @(
    120, 120, 120, 120, 120, 120, 120, 120, 120, 120
)
$absolutePlateauExcessSeries = @(
    127, 127, 127, 127, 127, 127, 127, 127, 127, 127
)
$transientMeasuredSeries = @(
    125, 119, 114, 110, 110, 110, 110, 110, 110, 110
)
if (
    -not (
        Test-WindowsHandleCalibratedWindowsWithinLimits `
            -StartupBaseline 581 `
            -WarmupObservedFinal 587 `
            -WarmupQuiescenceSamples $runtimeStartupTransientSeries `
            -CalibrationObservedFinal 597 `
            -CalibrationQuiescenceSamples `
                $runtimeCalibrationPlateauSeries `
            -MeasuredObservedFinal 597 `
            -MeasuredQuiescenceSamples $runtimeMeasuredPlateauSeries `
            -ConfirmationObservedFinal 597 `
            -ConfirmationQuiescenceSamples $runtimeMeasuredPlateauSeries
    ) -or
    -not (
        Test-WindowsHandleCalibratedWindowsWithinLimits `
            -StartupBaseline 100 `
            -WarmupObservedFinal 105 `
            -WarmupQuiescenceSamples @(105, 105, 105, 105, 105, 105, 105, 105, 105, 105) `
            -CalibrationObservedFinal 110 `
            -CalibrationQuiescenceSamples @(110, 110, 110, 110, 110, 110, 110, 110, 110, 110) `
            -MeasuredObservedFinal 125 `
            -MeasuredQuiescenceSamples $transientMeasuredSeries `
            -ConfirmationObservedFinal 110 `
            -ConfirmationQuiescenceSamples @(110, 110, 110, 110, 110, 110, 110, 110, 110, 110)
    ) -or
    # PR #9 / #12の実測値。最初のsteady windowだけ+5、次は+0なら受理する。
    -not (
        Test-WindowsHandleCalibratedWindowsWithinLimits `
            -StartupBaseline 581 `
            -WarmupObservedFinal 587 `
            -WarmupQuiescenceSamples $runtimeStartupTransientSeries `
            -CalibrationObservedFinal 592 `
            -CalibrationQuiescenceSamples $runtimeCalibration592Series `
            -MeasuredObservedFinal 597 `
            -MeasuredQuiescenceSamples $runtimeMeasuredPlateauSeries `
            -ConfirmationObservedFinal 597 `
            -ConfirmationQuiescenceSamples $runtimeMeasuredPlateauSeries
    ) -or
    # one-time initializationがconfirmation側で起きても連続増加でなければ受理する。
    -not (
        Test-WindowsHandleCalibratedWindowsWithinLimits `
            -StartupBaseline 581 `
            -WarmupObservedFinal 587 `
            -WarmupQuiescenceSamples $runtimeStartupTransientSeries `
            -CalibrationObservedFinal 592 `
            -CalibrationQuiescenceSamples $runtimeCalibration592Series `
            -MeasuredObservedFinal 592 `
            -MeasuredQuiescenceSamples $runtimeCalibration592Series `
            -ConfirmationObservedFinal 597 `
            -ConfirmationQuiescenceSamples $runtimeMeasuredPlateauSeries
    ) -or
    (
        Test-WindowsHandleCalibratedWindowsWithinLimits `
            -StartupBaseline 100 `
            -WarmupObservedFinal 110 `
            -WarmupQuiescenceSamples @(110, 110, 110, 110, 110, 110, 110, 110, 110, 110) `
            -CalibrationObservedFinal 117 `
            -CalibrationQuiescenceSamples $persistentStartupSeries `
            -MeasuredObservedFinal 117 `
            -MeasuredQuiescenceSamples $persistentStartupSeries `
            -ConfirmationObservedFinal 117 `
            -ConfirmationQuiescenceSamples $persistentStartupSeries
    ) -or
    # limit 4を超える+5が2つのsteady windowで続けばpersistent leakとして拒否する。
    (
        Test-WindowsHandleCalibratedWindowsWithinLimits `
            -StartupBaseline 100 `
            -WarmupObservedFinal 105 `
            -WarmupQuiescenceSamples @(105, 105, 105, 105, 105, 105, 105, 105, 105, 105) `
            -CalibrationObservedFinal 110 `
            -CalibrationQuiescenceSamples @(110, 110, 110, 110, 110, 110, 110, 110, 110, 110) `
            -MeasuredObservedFinal 115 `
            -MeasuredQuiescenceSamples $persistentMeasuredSeries `
            -ConfirmationObservedFinal 120 `
            -ConfirmationQuiescenceSamples $persistentConfirmationSeries
    ) -or
    # 単独windowでも+17はbounded plateauのabsolute limit 16を超えるため拒否する。
    (
        Test-WindowsHandleCalibratedWindowsWithinLimits `
            -StartupBaseline 100 `
            -WarmupObservedFinal 105 `
            -WarmupQuiescenceSamples @(105, 105, 105, 105, 105, 105, 105, 105, 105, 105) `
            -CalibrationObservedFinal 110 `
            -CalibrationQuiescenceSamples @(110, 110, 110, 110, 110, 110, 110, 110, 110, 110) `
            -MeasuredObservedFinal 127 `
            -MeasuredQuiescenceSamples $absolutePlateauExcessSeries `
            -ConfirmationObservedFinal 127 `
            -ConfirmationQuiescenceSamples $absolutePlateauExcessSeries
    ) -or
    (
        Test-WindowsHandleCalibratedWindowsWithinLimits `
            -StartupBaseline 100 `
            -WarmupObservedFinal 105 `
            -WarmupQuiescenceSamples @(105, 105, 105, 105, 105, 105, 105, 105, 105, 105) `
            -CalibrationObservedFinal 110 `
            -CalibrationQuiescenceSamples @(110, 110, 110, 110, 110, 110, 110, 110, 110, 110) `
            -MeasuredObservedFinal 110 `
            -MeasuredQuiescenceSamples @(110, 110, 110, 110, 110, 110, 110, 110, 110, 110) `
            -ConfirmationObservedFinal 127 `
            -ConfirmationQuiescenceSamples $absolutePlateauExcessSeries
    )
) {
    Add-Failure (
        'Windows handle readiness calibrated runtime/leak boundary ' +
        'regression failed.'
    )
}

# 構造契約。startup 80回とmeasured 40回の間で、同じrunnerを40回動かす
# calibration windowを必須化する。
Assert-FileContains `
    -RelativePath 'scripts/test-private-marker-handle-stability.ps1' `
    -Pattern '(?s)\$handleCalibrationRuns\s*=\s*40.*?\$handleCalibrationAttempt\s*=\s*0.*?\$handleCalibrationAttempt\s*-lt\s*\$handleCalibrationRuns.*?Invoke-PrivateMarkerBoundedProcess' `
    -Description 'forty-run Windows handle runtime calibration window'

# 構造契約。固定calibration後にも発生した単発+5 plateauと継続leakを分けるため、
# measured結果に依存せず実行する40回confirmation、single-window absolute cap、
# 連続2-window判定を必須化する。
Assert-FileContains `
    -RelativePath 'scripts/test-private-marker-handle-stability.ps1' `
    -Pattern '(?s)\$handleConfirmationRuns\s*=\s*40.*?\$handleConfirmationAttempt\s*=\s*0.*?\$handleConfirmationAttempt\s*-lt\s*\$handleConfirmationRuns.*?Invoke-PrivateMarkerBoundedProcess.*?\$handleConfirmationSettled.*?\(\$handleSettledFinal\s*-\s*\$handleBaseline\)\s*-gt\s*\$handleStartupGrowthLimit.*?-or.*?\(\$handleConfirmationSettled\s*-\s*\$handleSettledFinal\)\s*-gt\s*\$handleStartupGrowthLimit.*?-or.*?\(\$handleSettledFinal\s*-\s*\$handleBaseline\)\s*-gt\s*\$handleMeasuredFinalGrowthLimit\s*-and\s*\(\$handleConfirmationSettled\s*-\s*\$handleSettledFinal\)\s*-gt\s*\$handleMeasuredFinalGrowthLimit.*?windows-handle-probe-steady-persistent' `
    -Description 'unconditional forty-run Windows handle confirmation window with bounded plateau'

# 変数名とloop headerだけを残したno-op実装をpositiveにしないことも固定する。
# validator自身のAST契約が弱体化すると、production runnerを一度も呼ばない検査が
# readinessを通過できるため、最小のnegative controlを同じ場所で実行する。
$windowsHandleProbeNoOpFixture = @'
$handleWarmupRuns = 80
$handleCalibrationRuns = 40
$handleMeasuredRuns = 40
$handleConfirmationRuns = 40
$handleStartupGrowthLimit = 16
$handleMeasuredFinalGrowthLimit = 4
$handleQuiescenceSamples = 10
$handleQuiescenceWaitMilliseconds = 50
$handleProbeProcess = [System.Diagnostics.Process]::GetCurrentProcess()
$handleStartupBaseline = $handleProbeProcess.HandleCount
for ($handleWarmupAttempt = 0; $handleWarmupAttempt -lt $handleWarmupRuns; $handleWarmupAttempt++) {
}
$handleWarmupObservedFinal = $handleWarmupFinal
$handleWarmupSettled = $handleWarmupFinal
for ($handleWarmupQuiescenceAttempt = 0; $handleWarmupQuiescenceAttempt -lt $handleQuiescenceSamples; $handleWarmupQuiescenceAttempt++) {
}
if (($handleWarmupSettled - $handleStartupBaseline) -gt $handleStartupGrowthLimit) {
}
$handleCalibrationFinal = $handleWarmupSettled
for ($handleCalibrationAttempt = 0; $handleCalibrationAttempt -lt $handleCalibrationRuns; $handleCalibrationAttempt++) {
}
$handleCalibrationObservedFinal = $handleCalibrationFinal
$handleCalibrationSettled = $handleCalibrationFinal
for ($handleCalibrationQuiescenceAttempt = 0; $handleCalibrationQuiescenceAttempt -lt $handleQuiescenceSamples; $handleCalibrationQuiescenceAttempt++) {
}
if (($handleCalibrationSettled - $handleStartupBaseline) -gt $handleStartupGrowthLimit) {
}
$handleBaseline = $handleCalibrationSettled
for ($handleAttempt = 0; $handleAttempt -lt $handleMeasuredRuns; $handleAttempt++) {
}
$handleObservedFinal = $handleMeasuredFinal
$handleSettledFinal = $handleMeasuredFinal
for ($handleMeasuredQuiescenceAttempt = 0; $handleMeasuredQuiescenceAttempt -lt $handleQuiescenceSamples; $handleMeasuredQuiescenceAttempt++) {
}
$handleConfirmationFinal = $handleSettledFinal
for ($handleConfirmationAttempt = 0; $handleConfirmationAttempt -lt $handleConfirmationRuns; $handleConfirmationAttempt++) {
}
$handleConfirmationObservedFinal = $handleConfirmationFinal
$handleConfirmationSettled = $handleConfirmationFinal
for ($handleConfirmationQuiescenceAttempt = 0; $handleConfirmationQuiescenceAttempt -lt $handleQuiescenceSamples; $handleConfirmationQuiescenceAttempt++) {
}
if (
    ($handleSettledFinal - $handleBaseline) -gt $handleStartupGrowthLimit -or
    ($handleConfirmationSettled - $handleSettledFinal) -gt $handleStartupGrowthLimit -or
    (
        ($handleSettledFinal - $handleBaseline) -gt $handleMeasuredFinalGrowthLimit -and
        ($handleConfirmationSettled - $handleSettledFinal) -gt $handleMeasuredFinalGrowthLimit
    )
) {
}
'@
if (
    Test-WindowsHandleProbeAstContract `
        -Source $windowsHandleProbeNoOpFixture
) {
    Add-Failure 'Windows handle readiness AST contract accepts a no-op probe.'
}

# runner呼出しとhandle更新を各loop直後へ逃がした場合も、token順だけなら
# positiveに見える。AST extent検査がbody所属を要求していることを明示する。
$windowsHandleProbeScopeEscapeFixture = @'
$handleWarmupRuns = 80
$handleCalibrationRuns = 40
$handleMeasuredRuns = 40
$handleConfirmationRuns = 40
$handleStartupGrowthLimit = 16
$handleMeasuredFinalGrowthLimit = 4
$handleQuiescenceSamples = 10
$handleQuiescenceWaitMilliseconds = 50
$handleProbeProcess = [System.Diagnostics.Process]::GetCurrentProcess()
$handleProbeProcess.Refresh()
$handleStartupBaseline = $handleProbeProcess.HandleCount
for ($handleWarmupAttempt = 0; $handleWarmupAttempt -lt $handleWarmupRuns; $handleWarmupAttempt++) {
}
$handleWarmupResult = Invoke-PrivateMarkerBoundedProcess
$handleProbeProcess.Refresh()
$handleWarmupFinal = $handleProbeProcess.HandleCount
$handleWarmupMaximum = [Math]::Max($handleWarmupMaximum, $handleWarmupFinal)
$handleWarmupObservedFinal = $handleWarmupFinal
$handleWarmupSettled = $handleWarmupFinal
for ($handleWarmupQuiescenceAttempt = 0; $handleWarmupQuiescenceAttempt -lt $handleQuiescenceSamples; $handleWarmupQuiescenceAttempt++) {
}
$handleWarmupQuiescenceSample = $handleProbeProcess.HandleCount
$handleWarmupSettled = [Math]::Min($handleWarmupSettled, $handleWarmupQuiescenceSample)
if (($handleWarmupSettled - $handleStartupBaseline) -gt $handleStartupGrowthLimit) {
}
$handleCalibrationFinal = $handleWarmupSettled
for ($handleCalibrationAttempt = 0; $handleCalibrationAttempt -lt $handleCalibrationRuns; $handleCalibrationAttempt++) {
}
$handleCalibrationResult = Invoke-PrivateMarkerBoundedProcess
$handleProbeProcess.Refresh()
$handleCalibrationFinal = $handleProbeProcess.HandleCount
$handleCalibrationMaximum = [Math]::Max($handleCalibrationMaximum, $handleCalibrationFinal)
$handleCalibrationObservedFinal = $handleCalibrationFinal
$handleCalibrationSettled = $handleCalibrationFinal
for ($handleCalibrationQuiescenceAttempt = 0; $handleCalibrationQuiescenceAttempt -lt $handleQuiescenceSamples; $handleCalibrationQuiescenceAttempt++) {
}
$handleCalibrationQuiescenceSample = $handleProbeProcess.HandleCount
$handleCalibrationSettled = [Math]::Min($handleCalibrationSettled, $handleCalibrationQuiescenceSample)
if (($handleCalibrationSettled - $handleStartupBaseline) -gt $handleStartupGrowthLimit) {
}
$handleBaseline = $handleCalibrationSettled
for ($handleAttempt = 0; $handleAttempt -lt $handleMeasuredRuns; $handleAttempt++) {
}
$handleProbeResult = Invoke-PrivateMarkerBoundedProcess
$handleProbeProcess.Refresh()
$handleMeasuredFinal = $handleProbeProcess.HandleCount
$handleMeasuredMaximum = [Math]::Max($handleMeasuredMaximum, $handleMeasuredFinal)
$handleObservedFinal = $handleMeasuredFinal
$handleSettledFinal = $handleMeasuredFinal
for ($handleMeasuredQuiescenceAttempt = 0; $handleMeasuredQuiescenceAttempt -lt $handleQuiescenceSamples; $handleMeasuredQuiescenceAttempt++) {
}
$handleMeasuredQuiescenceSample = $handleProbeProcess.HandleCount
$handleSettledFinal = [Math]::Min($handleSettledFinal, $handleMeasuredQuiescenceSample)
$handleConfirmationFinal = $handleSettledFinal
for ($handleConfirmationAttempt = 0; $handleConfirmationAttempt -lt $handleConfirmationRuns; $handleConfirmationAttempt++) {
}
$handleConfirmationResult = Invoke-PrivateMarkerBoundedProcess
$handleProbeProcess.Refresh()
$handleConfirmationFinal = $handleProbeProcess.HandleCount
$handleConfirmationMaximum = [Math]::Max($handleConfirmationMaximum, $handleConfirmationFinal)
$handleConfirmationObservedFinal = $handleConfirmationFinal
$handleConfirmationSettled = $handleConfirmationFinal
for ($handleConfirmationQuiescenceAttempt = 0; $handleConfirmationQuiescenceAttempt -lt $handleQuiescenceSamples; $handleConfirmationQuiescenceAttempt++) {
}
$handleConfirmationQuiescenceSample = $handleProbeProcess.HandleCount
$handleConfirmationSettled = [Math]::Min($handleConfirmationSettled, $handleConfirmationQuiescenceSample)
if (
    ($handleSettledFinal - $handleBaseline) -gt $handleStartupGrowthLimit -or
    ($handleConfirmationSettled - $handleSettledFinal) -gt $handleStartupGrowthLimit -or
    (
        ($handleSettledFinal - $handleBaseline) -gt $handleMeasuredFinalGrowthLimit -and
        ($handleConfirmationSettled - $handleSettledFinal) -gt $handleMeasuredFinalGrowthLimit
    )
) {
}
'@
if (
    Test-WindowsHandleProbeAstContract `
        -Source $windowsHandleProbeScopeEscapeFixture
) {
    Add-Failure (
        'Windows handle readiness AST contract accepts loop-body scope escape.'
    )
}
Assert-FileContains `
    -RelativePath 'scripts/test-private-marker-handle-stability.ps1' `
    -Pattern '(?s)Microsoft\.PowerShell\.Core\\Import-Module\s+\$processRunnerModule\s+-Force.*?\$handleProbeTarget\s*=\s*Join-Path\s*\(\s*\[Environment\]::SystemDirectory\s*\)\s*''cmd\.exe''.*?\$handleProbeEnvironment\s*=\s*New-PrivateMarkerChildEnvironment.*?Windows handle stability:' `
    -Description 'fresh handle probe uses the reviewed runner and fixed minimal child environment'
Assert-FileContains `
    -RelativePath 'scripts/test-scan-private-markers.ps1' `
    -Pattern '(?s)\$handleProbeScript\s*=\s*Join-Path.*?''test-private-marker-handle-stability\.ps1''.*?\$handleProbeArguments\s*=\s*Get-PowerShellArguments.*?\$handleProbeHostResult\s*=\s*Invoke-BoundedProcess.*?-FilePath\s+\$powerShellPath.*?-TimeoutMilliseconds\s+120000.*?confirmation-observed-final=\[0-9\]\+.*?confirmation-settled=\[0-9\]\+.*?confirmation-max=\[0-9\]\+.*?confirmation=40.*?plateau-limit=16.*?\$handleEvidenceMatch' `
    -Description 'bounded same-host Windows handle probe isolation'
Assert-FileContains `
    -RelativePath 'scripts/test-private-marker-handle-stability.ps1' `
    -Pattern '(?s)catch\s*\{.*?\^windows-handle-probe-\[a-z-\]\+.*?windows-handle-probe-unexpected-error.*?Windows handle stability probe failed:' `
    -Description 'fixed redacted Windows handle probe failure diagnostics'
Assert-FileContains `
    -RelativePath 'scripts/test-scan-private-markers.ps1' `
    -Pattern '(?s)/proc/\$PID/fd.*?\$fdAttempt\s*=\s*0.*?\$fdAttempt\s*-lt\s*40' `
    -Description 'forty-run POSIX file descriptor stability regression without GC'
Assert-FileContains `
    -RelativePath 'scripts/test-scan-private-markers.ps1' `
    -Pattern '(?s)DelayedEnvironmentDictionary.*?pre-start-deadline\.sentinel.*?TimeoutMilliseconds 300.*?process-timeout' `
    -Description 'pre-start operation deadline regression'
Assert-FileContains `
    -RelativePath 'scripts/test-scan-private-markers.ps1' `
    -Pattern '(?s)\$operationStopwatch\s*=\s*\[System\.Diagnostics\.Stopwatch\]::StartNew\(\).*?\$process\.Start\(\).*?-OperationStopwatch\s+\$operationStopwatch' `
    -Description 'self-test process deadline starts before Process.Start'
Assert-FileContains `
    -RelativePath 'scripts/test-scan-private-markers.ps1' `
    -Pattern '(?s)invalidRunnerNumericCases.*?TimeoutMilliseconds.*?KillWaitMilliseconds.*?MaxStandardOutputBytes.*?MaxStandardErrorBytes.*?process-limit-invalid' `
    -Description 'exported runner raw numeric argument regressions'
Assert-FileContains `
    -RelativePath 'scripts/test-scan-private-markers.ps1' `
    -Pattern "(?s)Name\s*=\s*'root-directory'.*?Name\s*=\s*'root-file'.*?Name\s*=\s*'ancestor-directory'.*?Name\s*=\s*'ancestor-file'" `
    -Description 'root/ancestor Git control file/directory regressions'
Assert-FileContains `
    -RelativePath 'scripts/scan-private-markers-v2.ps1' `
    -Pattern '(?s)function\s+Find-NearestGitControlEntry.*?Get-ChildItem\s+-LiteralPath\s+\$current\.FullName\s+-Force.*?\.Name\.Equals\(' `
    -Description 'non-following parent enumeration for Git control metadata'
Assert-FileContains `
    -RelativePath 'scripts/test-scan-private-markers.ps1' `
    -Pattern 'dangling-git-control' `
    -Description 'dangling Git control junction regression'
Assert-FileContains `
    -RelativePath 'scripts/test-scan-private-markers.ps1' `
    -Pattern '(?s)linked-worktree.*?git-index-worktree-union' `
    -Description 'valid linked-worktree gitfile root regression'
Assert-FileContains `
    -RelativePath 'scripts/test-scan-private-markers.ps1' `
    -Pattern '(?s)uppercase-git-fallback.*?github-classic-token-prefix' `
    -Description 'case-sensitive POSIX uppercase .GIT regression'
Assert-FileContains `
    -RelativePath 'scripts/test-scan-private-markers.ps1' `
    -Pattern '(?s)scanner-entrypoint-failed.*?invalid public scan deadline' `
    -Description 'fixed public invalid deadline diagnostic'
Assert-FileContains `
    -RelativePath 'scripts/test-scan-private-markers.ps1' `
    -Pattern "(?s)'1\.5'.*?'1e3'.*?'not-an-integer'.*?'2147483648'.*?invalid public scan deadline" `
    -Description 'non-integer and overflowing public deadline regressions'
Assert-FileContains `
    -RelativePath 'scripts/test-scan-private-markers.ps1' `
    -Pattern 'Test-FirstBoundedInvocationIsRawTransport' `
    -Description 'AST-validated first raw process invocation'
Assert-FileContains `
    -RelativePath 'scripts/test-scan-private-markers.ps1' `
    -Pattern 'invoked-scriptblock-return-as-is' `
    -Description 'InvokeReturnAsIs eager-scriptblock AST regression'
Assert-FileContains `
    -RelativePath 'scripts/test-scan-private-markers.ps1' `
    -Pattern '(?s)invoked-function-before.*?scope-qualified-function-before.*?alias-function-before.*?get-command-function-before.*?get-item-function-before.*?dynamic-get-command-function-before.*?safe-get-command-application.*?transitive-function-before.*?dynamic-function-call-operator.*?function-scriptblock-member.*?function-inside-raw-argument' `
    -Description 'direct, scoped, aliased, referenced, transitive, dynamic, and nested deferred-function invocation regressions'
Assert-FileContains `
    -RelativePath 'scripts/test-scan-private-markers.ps1' `
    -Pattern '(?s)shadow-target-function.*?retarget-target-alias.*?risk-sensitive-set-item-alias.*?risk-sensitive-get-command-alias.*?risk-sensitive-new-object-alias.*?copy-item-invoke-expression-alias.*?copy-item-get-variable-alias.*?copy-item-function-provider.*?move-item-invoke-expression-alias.*?rename-item-invoke-expression-alias.*?wrapper-copy-item-alias-provider.*?import-alias-before.*?import-module-before.*?import-module-alias-before.*?module-qualified-import-before.*?new-module-before.*?using-module-before.*?wrapper-import-module-before.*?class-import-module-before.*?alias-to-import-module-before.*?remove-alias-target.*?remove-item-alias-target.*?remove-item-function-target.*?wrapper-remove-item-function-target.*?wrapper-dynamic-remove-item-function-target.*?wrapper-fixed-env-remove-item.*?dot-sourced-script-before.*?call-script-before.*?direct-script-before.*?wrapper-dynamic-script-before.*?unused-dynamic-script-wrapper.*?bound-local-scriptblock-wrapper.*?bound-local-scriptblock-provider-mutation.*?reassigned-local-scriptblock-wrapper.*?set-item-alias-target.*?set-item-function-target.*?wrapper-set-item-function-target.*?class-set-item-function-target.*?builtin-gcm-wrapper.*?module-qualified-get-command.*?function-scriptblock-member.*?invoke-command-function-ref' `
    -Description 'target-shadow, alias import/remove, provider removal, external-script execution, built-in/module lookup, and function-reference regressions'
Assert-FileContains `
    -RelativePath 'scripts/test-scan-private-markers.ps1' `
    -Pattern '(?s)invoke-command-function-ref.*?foreach-function-ref.*?class-constructor-before.*?class-method-before.*?invoke-expression-helper.*?invoke-expression-alias-helper' `
    -Description 'command-wrapper, type-construction, and runtime-expression regressions'
Assert-FileContains `
    -RelativePath 'scripts/test-scan-private-markers.ps1' `
    -Pattern '(?s)typeDefinition\.BaseTypes.*?derived-class-base-constructor-before.*?transitive-derived-base-constructor-before.*?safe-derived-base-constructor-before' `
    -Description 'derived class base-constructor risk propagation regressions'
Assert-FileContains `
    -RelativePath 'scripts/test-scan-private-markers.ps1' `
    -Pattern '(?s)stored-scriptblock-invoke.*?stored-scriptblock-return-as-is.*?stored-scriptblock-call-operator.*?stored-scriptblock-dot-operator.*?stored-scriptblock-inside-raw-argument.*?stored-risky-function-invoke' `
    -Description 'direct and function-indirect variable-backed scriptblock invocation regressions'
Assert-FileContains `
    -RelativePath 'scripts/test-scan-private-markers.ps1' `
    -Pattern '(?s)stored-scriptblock-get-variable-foreach.*?stored-scriptblock-gv-value-only.*?stored-scriptblock-dynamic-get-variable.*?unbound-literal-get-variable.*?runtime-created-scriptblock-get-variable.*?reassigned-runtime-scriptblock-get-variable.*?compound-assignment-get-variable.*?alias-variable-mutation-get-variable.*?member-variable-mutation-get-variable.*?stored-scriptblock-invoke-expression-get-variable.*?stored-scriptblock-iex-get-variable.*?stored-scriptblock-unresolved-call-get-variable.*?stored-scriptblock-unbound-command-get-variable.*?stored-scriptblock-wildcard-get-variable.*?stored-scriptblock-name-omitted-get-variable.*?stored-scriptblock-get-variable-wrapper.*?stored-scriptblock-get-variable-alias.*?alias-of-set-alias-get-variable.*?wrapper-set-alias-get-variable.*?stored-scriptblock-get-variable-transitive-alias.*?stored-scriptblock-get-variable-wrapper-alias.*?safe-get-variable-wrapper-alias.*?safe-get-variable-wrapper-alias-before-assignment.*?safe-get-variable-wrapper-unknown-command.*?safe-get-variable-wrapper-dynamic-call.*?safe-get-variable-alias-target.*?shadowed-get-variable-command.*?unused-get-variable-wrapper.*?safe-stored-scriptblock-get-variable.*?global-safe-assignment-get-variable.*?script-scoped-safe-assignment-get-variable.*?parameter-global-safe-assignment-get-variable.*?qualified-current-item-scriptblock-get-variable' `
    -Description 'positive-safe, scope-qualified, unbound, generated, IEX, unresolved, wildcard, alias, wrapper, ordering, and safe Get-Variable regressions'
Assert-FileContains `
    -RelativePath 'scripts/test-scan-private-markers.ps1' `
    -Pattern '(?s)set-item-alias-target.*?set-item-function-target.*?stored-scriptblock-foreach-argument.*?stored-scriptblock-where-argument.*?unknown-invoke-composite-receiver' `
    -Description 'provider shadow, command-argument scriptblock, and composite receiver regressions'
Assert-FileContains `
    -RelativePath 'scripts/test-scan-private-markers.ps1' `
    -Pattern '(?s)testCommandIsExactBootstrapModuleImport.*?f29521a8724ec25d8611ea77e6bf8397cb0ff40cb9bff35aaa5d2b0c7b367ae8.*?testDynamicCallTargetIsBoundLocalScriptBlock' `
    -Description 'exact bootstrap module-import and local-scriptblock call integrity'
Assert-FileContains `
    -RelativePath 'scripts/test-scan-private-markers.ps1' `
    -Pattern '(?s)testCommandIsExactBoundedFixtureCleanup.*?SHA256.*?a70c391505cfa4c9bf783623e5178839fdefa270c3bbbadd7b88f3aec267ab5e.*?testRemoveOrClearItemCanChangeCommandIdentity' `
    -Description 'exact bounded fixture-cleanup exception integrity'
Assert-FileContains `
    -RelativePath 'scripts/test-scan-private-markers.ps1' `
    -Pattern '(?s)set-content-alias-function.*?new-item-dynamic-function-provider.*?module-qualified-join-path-provider.*?bootstrap-variable-overwrite.*?bootstrap-scope-wrapper-overwrite.*?class-as-conversion-before.*?class-static-instance-before' `
    -Description 'content/item provider, bootstrap overwrite, and class conversion/static initializer regressions'
Assert-FileContains `
    -RelativePath 'scripts/test-scan-private-markers.ps1' `
    -Pattern '(?s)\$rawGitBatchResult\s*=\s*Invoke-PrivateMarkerBoundedProcess.*?cat-file.*?--batch' `
    -Description 'native Git byte-exact batch transport regression'
Assert-FileContains `
    -RelativePath 'scripts/test-scan-private-markers.ps1' `
    -Pattern '(?s)\$inputCodePageBefore\s*=\s*\[Console\]::InputEncoding\.CodePage.*?\$inputPreambleBefore.*?\[Console\]::InputEncoding\.GetPreamble\(\)' `
    -Description 'caller console input-encoding restoration regression'
Assert-FileContains `
    -RelativePath 'docs/scanner-hardening-v2.md' `
    -Pattern 'Private marker scan failed closed \(integrity: git-probe\)\.' `
    -Description 'fixed Git probe diagnostic contract'
Assert-FileContains `
    -RelativePath 'docs/scanner-hardening-v2.md' `
    -Pattern '(?s)private release gate.*?getpgid\(pid\) == pid.*?late-ready.*?non-recursive gate directory' `
    -Description 'documented POSIX verified release-gate contract'
Assert-FileContains `
    -RelativePath 'docs/scanner-hardening-v2.md' `
    -Pattern '(?s)Get-Command git -CommandType Application.*?hard link.*?reparse target.*?fallback' `
    -Description 'documented PATH-first native Git executable contract'
Assert-FileContains `
    -RelativePath 'scripts/scan-private-markers.ps1' `
    -Pattern 'Private marker scan failed: scanner-entrypoint-failed' `
    -Description 'fixed redacted scanner entrypoint diagnostic'
Assert-FileContains `
    -RelativePath 'scripts/scan-private-markers-v2.ps1' `
    -Pattern '(?s)\$fixedRuntimeFailure\s*=\s*''scanner-runtime-failed''.*?Write-FixedRuntimeFailure\s+-Code\s+\$fixedRuntimeFailure' `
    -Description 'fixed redacted process-boundary runtime diagnostic'
Assert-FileContains `
    -RelativePath 'scripts/test-scan-private-markers.ps1' `
    -Pattern '(?s)missing-implementation.*?missing-runner.*?throwing-runner.*?isolation-create-failure.*?isolation-remove-failure' `
    -Description 'missing implementation/helper, helper exception, and isolation failure redaction regressions'
Assert-FileContains `
    -RelativePath 'scripts/test-macos-fail-closed.ps1' `
    -Pattern '(?s)Get-PrivateMarkerTrustedSetsidPath.*?trusted-setsid-missing.*?Private marker scan failed closed \(integrity: git-probe\)\..*?ExitCode\s+-ne\s+2' `
    -Description 'native macOS unsupported-platform fail-closed contract'

$workflowPath = '.github/workflows/validate.yml'
Assert-WorkflowBoundaryContract -RelativePath $workflowPath
Assert-WorkflowJobSet `
    -RelativePath $workflowPath `
    -ExpectedJobs @('validate', 'validate_ubuntu', 'validate_macos')
Assert-WorkflowJobTimeout `
    -RelativePath $workflowPath `
    -JobName 'validate' `
    -Minutes 25
Assert-WorkflowJobTimeout `
    -RelativePath $workflowPath `
    -JobName 'validate_ubuntu' `
    -Minutes 25
Assert-WorkflowJobTimeout `
    -RelativePath $workflowPath `
    -JobName 'validate_macos' `
    -Minutes 25
Assert-WorkflowJobDirectValue `
    -RelativePath $workflowPath `
    -JobName 'validate' `
    -Key 'runs-on' `
    -Value 'windows-latest'
Assert-WorkflowJobDirectValue `
    -RelativePath $workflowPath `
    -JobName 'validate_ubuntu' `
    -Key 'runs-on' `
    -Value 'ubuntu-24.04'
Assert-WorkflowJobDirectValue `
    -RelativePath $workflowPath `
    -JobName 'validate_macos' `
    -Key 'runs-on' `
    -Value 'macos-15'

$workflowSteps = Get-WorkflowSteps `
    -RelativePath $workflowPath `
    -JobName 'validate'
Assert-WorkflowStepCount `
    -Steps $workflowSteps `
    -JobName 'validate' `
    -ExpectedCount 7
$workflowJobLines = Get-WorkflowJobLines `
    -RelativePath $workflowPath `
    -JobName 'validate'
Assert-WorkflowJobShape `
    -Lines $workflowJobLines `
    -JobName 'validate' `
    -ExpectedStepCount 7 `
    -ExpectedShellCount 6 `
    -ExpectedRunCount 6 `
    -ExpectedWithCount 1 `
    -ExpectedNestedEntryCount 1
Assert-WorkflowUsesStep -Steps $workflowSteps -Name 'Check out repository' `
    -Uses 'actions/checkout@93cb6efe18208431cddfb8368fd83d5badbf9bfd' `
    -PersistCredentials 'false'
Assert-WorkflowStep -Steps $workflowSteps -Name 'Validate OSS readiness' `
    -Shell 'pwsh' -Run './scripts/validate-oss-readiness.ps1'
Assert-WorkflowStep `
    -Steps $workflowSteps `
    -Name 'Validate OSS readiness (Windows PowerShell 5.1)' `
    -Shell 'powershell' `
    -Run './scripts/validate-oss-readiness.ps1'
Assert-WorkflowStep -Steps $workflowSteps -Name 'Test private marker scan (PowerShell 7)' `
    -Shell 'pwsh' -Run './scripts/test-scan-private-markers.ps1'
Assert-WorkflowStep -Steps $workflowSteps -Name 'Test private marker scan (Windows PowerShell 5.1)' `
    -Shell 'powershell' -Run './scripts/test-scan-private-markers.ps1'
Assert-WorkflowStep -Steps $workflowSteps -Name 'Scan for private markers' `
    -Shell 'pwsh' -Run './scripts/scan-private-markers.ps1'
$whitespaceCommand = (
    'git diff-tree --check ' +
    '4b825dc642cb6eb9a060e54bf8d69288fbee4904 HEAD'
)
Assert-WorkflowStep -Steps $workflowSteps -Name 'Check whitespace' `
    -Shell 'pwsh' -Run $whitespaceCommand

$ubuntuWorkflowSteps = Get-WorkflowSteps `
    -RelativePath $workflowPath `
    -JobName 'validate_ubuntu'
Assert-WorkflowStepCount `
    -Steps $ubuntuWorkflowSteps `
    -JobName 'validate_ubuntu' `
    -ExpectedCount 5
$ubuntuWorkflowJobLines = Get-WorkflowJobLines `
    -RelativePath $workflowPath `
    -JobName 'validate_ubuntu'
Assert-WorkflowJobShape `
    -Lines $ubuntuWorkflowJobLines `
    -JobName 'validate_ubuntu' `
    -ExpectedStepCount 5 `
    -ExpectedShellCount 4 `
    -ExpectedRunCount 4 `
    -ExpectedWithCount 1 `
    -ExpectedNestedEntryCount 1
Assert-WorkflowUsesStep -Steps $ubuntuWorkflowSteps -Name 'Check out repository' `
    -Uses 'actions/checkout@93cb6efe18208431cddfb8368fd83d5badbf9bfd' `
    -PersistCredentials 'false'
Assert-WorkflowStep -Steps $ubuntuWorkflowSteps -Name 'Validate OSS readiness' `
    -Shell 'pwsh' -Run './scripts/validate-oss-readiness.ps1'
Assert-WorkflowStep -Steps $ubuntuWorkflowSteps -Name 'Test private marker scan (PowerShell 7)' `
    -Shell 'pwsh' -Run './scripts/test-scan-private-markers.ps1'
Assert-WorkflowStep -Steps $ubuntuWorkflowSteps -Name 'Scan for private markers' `
    -Shell 'pwsh' -Run './scripts/scan-private-markers.ps1'
Assert-WorkflowStep -Steps $ubuntuWorkflowSteps -Name 'Check whitespace' `
    -Shell 'pwsh' -Run $whitespaceCommand

$macosWorkflowSteps = Get-WorkflowSteps `
    -RelativePath $workflowPath `
    -JobName 'validate_macos'
Assert-WorkflowStepCount `
    -Steps $macosWorkflowSteps `
    -JobName 'validate_macos' `
    -ExpectedCount 4
$macosWorkflowJobLines = Get-WorkflowJobLines `
    -RelativePath $workflowPath `
    -JobName 'validate_macos'
Assert-WorkflowJobShape `
    -Lines $macosWorkflowJobLines `
    -JobName 'validate_macos' `
    -ExpectedStepCount 4 `
    -ExpectedShellCount 3 `
    -ExpectedRunCount 3 `
    -ExpectedWithCount 1 `
    -ExpectedNestedEntryCount 1
Assert-WorkflowUsesStep -Steps $macosWorkflowSteps -Name 'Check out repository' `
    -Uses 'actions/checkout@93cb6efe18208431cddfb8368fd83d5badbf9bfd' `
    -PersistCredentials 'false'
Assert-WorkflowStep -Steps $macosWorkflowSteps -Name 'Validate OSS readiness' `
    -Shell 'pwsh' -Run './scripts/validate-oss-readiness.ps1'
Assert-WorkflowStep -Steps $macosWorkflowSteps -Name 'Test unsupported macOS fail-closed contract' `
    -Shell 'pwsh' -Run './scripts/test-macos-fail-closed.ps1'
Assert-WorkflowStep -Steps $macosWorkflowSteps -Name 'Check whitespace' `
    -Shell 'pwsh' -Run $whitespaceCommand

foreach ($powerShellScript in @(
    'scripts/private-marker-process-runner.psm1',
    'scripts/scan-private-markers.ps1',
    'scripts/scan-private-markers-v2.ps1',
    'scripts/test-macos-fail-closed.ps1',
    'scripts/test-private-marker-handle-stability.ps1',
    'scripts/test-scan-private-markers.ps1',
    'scripts/validate-oss-readiness.ps1'
)) {
    Assert-PowerShellByteHygiene -RelativePath $powerShellScript
}

Test-SkillFrontmatter

if ($failures.Count -gt 0) {
    Write-Host 'OSS readiness validation failed:'
    foreach ($failure in $failures) {
        Write-Host "- $failure"
    }
    exit 1
}

Write-Host "OSS readiness validation passed for $root"
exit 0
