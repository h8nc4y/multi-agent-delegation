[CmdletBinding()]
param(
    [string]$Path = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = if ([string]::IsNullOrWhiteSpace($Path)) {
    Split-Path -Parent $PSScriptRoot
} else {
    (Resolve-Path -LiteralPath $Path).Path
}

# host-wide gateを起動せず、正本validatorのpure functionだけを同じprocessへ
# 読み込んでREADMEとCONTRIBUTINGの契約およびmemory mutationを検証する。
$readinessScript = Join-Path $PSScriptRoot 'validate-oss-readiness.ps1'
. $readinessScript -Path $repoRoot -InternalDefinitionsOnly

$failures.Clear()
$ciJobTimeoutMinutes = 25
foreach ($relativePath in @('README.md', 'CONTRIBUTING.md')) {
    Assert-CiTimeoutDocumentationContract `
        -RelativePath $relativePath `
        -Minutes $ciJobTimeoutMinutes
}

if ($failures.Count -gt 0) {
    Write-Host 'CI timeout documentation contract test failed:'
    foreach ($failure in $failures) {
        Write-Host "- $failure"
    }
    exit 1
}

Write-Host 'CI timeout documentation contract test passed.'
exit 0
