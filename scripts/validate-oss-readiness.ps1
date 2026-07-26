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
$failures = New-Object System.Collections.Generic.List[string]

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

    $content = Get-Content -LiteralPath $filePath -Raw
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

    $content = Get-Content -LiteralPath $filePath -Raw
    if ($content -match $Pattern) {
        Add-Failure "$RelativePath contains forbidden content: $Description"
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

function Test-WindowsHandleProbeAstContract {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source
    )

    # loop headerだけの正規表現では、runner呼出しをbody外へ移動または削除した
    # no-op実装を見抜けない。ASTで2つのfor bodyを特定し、各windowが実際に
    # process実行とhandle更新を直下statementとして所有することを検査する。
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
    $measuredLoops = @(
        $forStatements |
            Where-Object {
                $_.Condition.Extent.Text -match (
                    '^\s*\$handleAttempt\s*-lt\s*' +
                    '\$handleMeasuredRuns\s*$'
                )
            }
    )
    if ($warmupLoops.Count -ne 1 -or $measuredLoops.Count -ne 1) {
        return $false
    }

    $warmupLoop = $warmupLoops[0]
    $measuredLoop = $measuredLoops[0]
    if (
        $warmupLoop.Extent.StartOffset -ge
            $measuredLoop.Extent.StartOffset
    ) {
        return $false
    }
    if (
        -not [object]::ReferenceEquals(
            $warmupLoop.Parent,
            $measuredLoop.Parent
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
        [pscustomobject]@{ Name = 'handleWarmupRuns'; Value = 40 },
        [pscustomobject]@{ Name = 'handleMeasuredRuns'; Value = 40 },
        [pscustomobject]@{ Name = 'handleStartupGrowthLimit'; Value = 16 },
        [pscustomobject]@{
            Name = 'handleMeasuredFinalGrowthLimit'
            Value = 4
        },
        [pscustomobject]@{
            Name = 'handleMeasuredPeakGrowthLimit'
            Value = 8
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
            Test-WindowsHandleProbeLoopContract `
                -Loop $measuredLoop `
                -CounterName 'handleAttempt' `
                -LimitName 'handleMeasuredRuns' `
                -ResultName 'handleProbeResult' `
                -FinalName 'handleFinal' `
                -MaximumName 'handleMaximum' `
                -ChildFailureCode 'windows-handle-probe-steady-child-failed'
        )
    ) {
        return $false
    }

    # sourceをASTの境界で分割し、startup baseline → warm-up body →
    # startup上限 → steady-state body → steady-state上限の順序も固定する。
    $prefix = $Source.Substring(0, $warmupLoop.Extent.StartOffset)
    $warmupBody = $warmupLoop.Extent.Text
    $between = $Source.Substring(
        $warmupLoop.Extent.EndOffset,
        $measuredLoop.Extent.StartOffset - $warmupLoop.Extent.EndOffset
    )
    $measuredBody = $measuredLoop.Extent.Text
    $suffix = $Source.Substring($measuredLoop.Extent.EndOffset)

    $prefixContract = (
        '(?s)' +
        '\$handleWarmupRuns\s*=\s*40.*?' +
        '\$handleMeasuredRuns\s*=\s*40.*?' +
        '\$handleStartupGrowthLimit\s*=\s*16.*?' +
        '\$handleMeasuredFinalGrowthLimit\s*=\s*4.*?' +
        '\$handleMeasuredPeakGrowthLimit\s*=\s*8.*?' +
        '\$handleProbeProcess\s*=\s*' +
        '\[System\.Diagnostics\.Process\]::GetCurrentProcess\(\).*?' +
        '\$handleStartupBaseline\s*=\s*' +
        '\$handleProbeProcess\.HandleCount'
    )
    $warmupBodyContract = (
        '(?s)' +
        '\$handleWarmupResult\s*=\s*' +
        'private-marker-process-runner\\' +
        'Invoke-PrivateMarkerBoundedProcess.*?' +
        '\$handleProbeProcess\.Refresh\(\).*?' +
        '\$handleWarmupFinal\s*=\s*\$handleProbeProcess\.HandleCount.*?' +
        '\$handleWarmupMaximum\s*=\s*\[Math\]::Max\('
    )
    $betweenContract = (
        '(?s)' +
        '\(\$handleWarmupFinal\s*-\s*\$handleStartupBaseline\)\s*' +
        '-gt\s*\$handleStartupGrowthLimit.*?' +
        '\(\$handleWarmupMaximum\s*-\s*\$handleStartupBaseline\)\s*' +
        '-gt\s*\$handleStartupGrowthLimit.*?' +
        '\$handleBaseline\s*=\s*\$handleWarmupFinal'
    )
    $measuredBodyContract = (
        '(?s)' +
        '\$handleProbeResult\s*=\s*' +
        'private-marker-process-runner\\' +
        'Invoke-PrivateMarkerBoundedProcess.*?' +
        '\$handleProbeProcess\.Refresh\(\).*?' +
        '\$handleFinal\s*=\s*\$handleProbeProcess\.HandleCount.*?' +
        '\$handleMaximum\s*=\s*\[Math\]::Max\('
    )
    $suffixContract = (
        '(?s)' +
        '\(\$handleFinal\s*-\s*\$handleBaseline\)\s*' +
        '-gt\s*\$handleMeasuredFinalGrowthLimit.*?' +
        '\(\$handleMaximum\s*-\s*\$handleBaseline\)\s*' +
        '-gt\s*\$handleMeasuredPeakGrowthLimit'
    )

    return (
        $prefix -match $prefixContract -and
        $warmupBody -match $warmupBodyContract -and
        $between -match $betweenContract -and
        $measuredBody -match $measuredBodyContract -and
        $suffix -match $suffixContract
    )
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
        'dcad83706cd800b7d52a0d7f2d83b81f85aee752256dc45dcec6c78a83444e7c'
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
        }
    )
    foreach ($mutation in $mutations) {
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
                ShellCount = 0
                RunCount = 0
                UsesCount = 0
            }
            continue
        }
        if ($isStepStart) {
            continue
        }

        if ($null -eq $currentStep) {
            continue
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
        [int]$ExpectedRunCount
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
    $deepActiveEntryCount = @(
        $Lines | Where-Object {
            $_ -match '^ {10,}(?![ #\r\n]).+$'
        }
    ).Count
    $expectedStepPropertyCount = (
        1 +
        $ExpectedShellCount +
        $ExpectedRunCount
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
        $deepActiveEntryCount -ne 0) {
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
        [string]$Uses
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
        $matches[0].RunCount -ne 0) {
        Add-Failure (
            "Workflow step '$Name' must contain exactly one uses " +
            'and no shell/run key'
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

    $lines = Get-Content -LiteralPath $skillPath
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

Assert-FileContains -RelativePath 'README.md' -Pattern '(?im)^##\s+Install' -Description 'installation instructions'
Assert-FileContains -RelativePath 'README.md' -Pattern '(?im)^##\s+Validation' -Description 'validation instructions'
Assert-FileContains -RelativePath 'README.md' -Pattern '(?im)^##\s+Contributing' -Description 'contribution guidance'
Assert-FileContains -RelativePath 'README.md' -Pattern '(?im)^##\s+Security' -Description 'security reporting guidance'
Assert-FileContains -RelativePath 'README.md' -Pattern 'CONTRIBUTING\.md' -Description 'link to CONTRIBUTING.md'
Assert-FileContains -RelativePath 'README.md' -Pattern 'SECURITY\.md' -Description 'link to SECURITY.md'
Assert-FileContains -RelativePath 'README.md' -Pattern 'docs/SKILL\.ja\.md' -Description 'link to the Japanese skill version'
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
            'bounded startup and steady-state Windows handle regressions without GC'
        )
    }

    # 片方だけ0回へ変えても必ずrejectされることを別々に検証する。両方を同時に
    # 変えるfixtureでは、一方のheader検査が欠けてもnegativeになり得るため分離する。
    $windowsHandleZeroRunCases = @(
        [pscustomobject]@{
            Name = 'startup'
            Before = '$handleWarmupAttempt = 0;'
            After = '$handleWarmupAttempt = $handleWarmupRuns;'
        },
        [pscustomobject]@{
            Name = 'steady-state'
            Before = '$handleAttempt = 0;'
            After = '$handleAttempt = $handleMeasuredRuns;'
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

    # headerを変えずlimitだけ0へ再代入する変異も各windowでrejectする。
    # evidence直前に40へ戻して表示値だけ正規化しても、代入数検査で失敗する。
    $windowsHandleLimitReassignmentCases = @(
        [pscustomobject]@{
            Name = 'startup'
            Before = '$handleWarmupRuns = 40'
            After = (
                '$handleWarmupRuns = 40' +
                "`n    " +
                '$handleWarmupRuns = 0'
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
            Name = 'steady-state'
            Before = (
                '$handleProbeResult = ' +
                'private-marker-process-runner\' +
                'Invoke-PrivateMarkerBoundedProcess'
            )
            After = '$handleProbeResult = New-PrivateMarkerDummyResult'
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
            Before = '$handleWarmupRuns = 40'
            After = (
                '$handleWarmupRuns = 40' +
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

    # body全体を到達不能なifへ包む変異も、startup/steady-stateごとに拒否する。
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

# 変数名とloop headerだけを残したno-op実装をpositiveにしないことも固定する。
# validator自身のAST契約が弱体化すると、production runnerを一度も呼ばない検査が
# readinessを通過できるため、最小のnegative controlを同じ場所で実行する。
$windowsHandleProbeNoOpFixture = @'
$handleWarmupRuns = 40
$handleMeasuredRuns = 40
$handleStartupGrowthLimit = 16
$handleMeasuredFinalGrowthLimit = 4
$handleMeasuredPeakGrowthLimit = 8
$handleProbeProcess = [System.Diagnostics.Process]::GetCurrentProcess()
$handleStartupBaseline = $handleProbeProcess.HandleCount
for ($handleWarmupAttempt = 0; $handleWarmupAttempt -lt $handleWarmupRuns; $handleWarmupAttempt++) {
}
if (($handleWarmupFinal - $handleStartupBaseline) -gt $handleStartupGrowthLimit -or
    ($handleWarmupMaximum - $handleStartupBaseline) -gt $handleStartupGrowthLimit) {
}
$handleBaseline = $handleWarmupFinal
for ($handleAttempt = 0; $handleAttempt -lt $handleMeasuredRuns; $handleAttempt++) {
}
if (($handleFinal - $handleBaseline) -gt $handleMeasuredFinalGrowthLimit -or
    ($handleMaximum - $handleBaseline) -gt $handleMeasuredPeakGrowthLimit) {
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
$handleWarmupRuns = 40
$handleMeasuredRuns = 40
$handleStartupGrowthLimit = 16
$handleMeasuredFinalGrowthLimit = 4
$handleMeasuredPeakGrowthLimit = 8
$handleProbeProcess = [System.Diagnostics.Process]::GetCurrentProcess()
$handleProbeProcess.Refresh()
$handleStartupBaseline = $handleProbeProcess.HandleCount
for ($handleWarmupAttempt = 0; $handleWarmupAttempt -lt $handleWarmupRuns; $handleWarmupAttempt++) {
}
$handleWarmupResult = Invoke-PrivateMarkerBoundedProcess
$handleProbeProcess.Refresh()
$handleWarmupFinal = $handleProbeProcess.HandleCount
$handleWarmupMaximum = [Math]::Max($handleWarmupMaximum, $handleWarmupFinal)
if (($handleWarmupFinal - $handleStartupBaseline) -gt $handleStartupGrowthLimit -or
    ($handleWarmupMaximum - $handleStartupBaseline) -gt $handleStartupGrowthLimit) {
}
$handleBaseline = $handleWarmupFinal
for ($handleAttempt = 0; $handleAttempt -lt $handleMeasuredRuns; $handleAttempt++) {
}
$handleProbeResult = Invoke-PrivateMarkerBoundedProcess
$handleProbeProcess.Refresh()
$handleFinal = $handleProbeProcess.HandleCount
$handleMaximum = [Math]::Max($handleMaximum, $handleFinal)
if (($handleFinal - $handleBaseline) -gt $handleMeasuredFinalGrowthLimit -or
    ($handleMaximum - $handleBaseline) -gt $handleMeasuredPeakGrowthLimit) {
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
    -Pattern '(?s)\$handleProbeScript\s*=\s*Join-Path.*?''test-private-marker-handle-stability\.ps1''.*?\$handleProbeArguments\s*=\s*Get-PowerShellArguments.*?\$handleProbeHostResult\s*=\s*Invoke-BoundedProcess.*?-FilePath\s+\$powerShellPath.*?-TimeoutMilliseconds\s+120000.*?\$handleEvidenceMatch' `
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
    -Pattern '(?s)Get-PrivateMarkerTrustedSetsidPath.*?trusted-setsid-missing.*?scanner-runtime-failed.*?ExitCode\s+-ne\s+2' `
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
    -ExpectedCount 6
$workflowJobLines = Get-WorkflowJobLines `
    -RelativePath $workflowPath `
    -JobName 'validate'
Assert-WorkflowJobShape `
    -Lines $workflowJobLines `
    -JobName 'validate' `
    -ExpectedStepCount 6 `
    -ExpectedShellCount 5 `
    -ExpectedRunCount 5
Assert-WorkflowUsesStep -Steps $workflowSteps -Name 'Check out repository' `
    -Uses 'actions/checkout@93cb6efe18208431cddfb8368fd83d5badbf9bfd'
Assert-WorkflowStep -Steps $workflowSteps -Name 'Validate OSS readiness' `
    -Shell 'pwsh' -Run './scripts/validate-oss-readiness.ps1'
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
    -ExpectedRunCount 4
Assert-WorkflowUsesStep -Steps $ubuntuWorkflowSteps -Name 'Check out repository' `
    -Uses 'actions/checkout@93cb6efe18208431cddfb8368fd83d5badbf9bfd'
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
    -ExpectedRunCount 3
Assert-WorkflowUsesStep -Steps $macosWorkflowSteps -Name 'Check out repository' `
    -Uses 'actions/checkout@93cb6efe18208431cddfb8368fd83d5badbf9bfd'
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
