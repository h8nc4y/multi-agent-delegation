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

    $lines = @(Get-Content -LiteralPath $filePath)
    $jobsStart = -1
    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -match '^jobs:\s*$') {
            $jobsStart = $index
            break
        }
    }
    if ($jobsStart -lt 0) {
        Add-Failure "$RelativePath must contain a top-level jobs mapping"
        return @()
    }

    $jobStart = -1
    $jobPattern = '^  ' + [regex]::Escape($JobName) + ':\s*$'
    for ($index = $jobsStart + 1; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -match '^\S') {
            break
        }
        if ($lines[$index] -match $jobPattern) {
            $jobStart = $index
            break
        }
    }
    if ($jobStart -lt 0) {
        Add-Failure "$RelativePath must contain jobs.$JobName"
        return @()
    }

    $jobEnd = $lines.Count
    for ($index = $jobStart + 1; $index -lt $lines.Count; $index++) {
        if (
            $lines[$index] -match '^\S' -or
            $lines[$index] -match '^  [A-Za-z0-9_-]+:\s*$'
        ) {
            $jobEnd = $index
            break
        }
    }
    return @($lines[$jobStart..($jobEnd - 1)])
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
    foreach ($line in $jobLines[$stepsStart..($stepsEnd - 1)]) {
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
            continue
        }
        $usesMatch = [regex]::Match(
            $line,
            '^        uses:[ \t]*(?<value>[^#\r\n]+?)[ \t]*(?:#.*)?$'
        )
        if ($usesMatch.Success) {
            $currentStep.Uses = $usesMatch.Groups['value'].Value.Trim("'`" ")
            continue
        }
        $runMatch = [regex]::Match(
            $line,
            '^        run:[ \t]*(?<value>[^#\r\n]+?)[ \t]*$'
        )
        if ($runMatch.Success) {
            $currentStep.Run = $runMatch.Groups['value'].Value.Trim("'`"")
        }
    }

    if ($null -ne $currentStep) {
        $steps.Add($currentStep) | Out-Null
    }
    return $steps.ToArray()
}

function Assert-WorkflowUsesStep {
    param(
        [object[]]$Steps,
        [string]$Name,
        [string]$Uses
    )

    $matches = @($Steps | Where-Object { $_.Name -ceq $Name })
    if ($matches.Count -ne 1) {
        Add-Failure "Workflow must contain exactly one active step named '$Name' (found $($matches.Count))"
        return
    }
    if ($matches[0].Uses -cne $Uses) {
        Add-Failure "Workflow step '$Name' must use '$Uses' (found '$($matches[0].Uses)')"
    }
}

function Assert-WorkflowStep {
    param(
        [object[]]$Steps,
        [string]$Name,
        [string]$Shell,
        [string]$Run
    )

    $matches = @($Steps | Where-Object { $_.Name -ceq $Name })
    if ($matches.Count -ne 1) {
        Add-Failure "Workflow must contain exactly one active step named '$Name' (found $($matches.Count))"
        return
    }

    $step = $matches[0]
    if (-not $step.Shell.Equals($Shell, [System.StringComparison]::OrdinalIgnoreCase)) {
        Add-Failure "Workflow step '$Name' must use shell '$Shell' (found '$($step.Shell)')"
    }
    if ($step.Run -cne $Run) {
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
    'examples/delegation-prompt-template.md',
    'examples/verification-checklist.md',
    'examples/ledger-template.md',
    'scripts/scan-private-markers.ps1',
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
Assert-WorkflowJobTimeout `
    -RelativePath '.github/workflows/validate.yml' `
    -JobName 'validate' `
    -Minutes 10

$workflowSteps = Get-WorkflowSteps `
    -RelativePath '.github/workflows/validate.yml' `
    -JobName 'validate'
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

foreach ($powerShellScript in @(
    'scripts/scan-private-markers.ps1',
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
