[CmdletBinding()]
param(
    [string]$Path = '',

    # ValidateRange は script body より前にstderrへ未redact binding errorを
    # 出し得る。[int]の暗黙丸めも避け、raw scalarをbody内で正規化する。
    [object]$ScanDeadlineMilliseconds = 120000
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# 公開entry pointを固定し、hardening本体は独立fileでAST/test対象にする。
# child processは増やさず同じPowerShell process内で実装scriptへ委譲する。
$script:PrivateMarkerScannerExitCode = 2
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
        # PowerShell内の既定値と内部呼出しだけはCLR Int32のまま受理する。
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
    . (Join-Path $PSScriptRoot 'scan-private-markers-v2.ps1') `
        -Path $Path `
        -ScanDeadlineMilliseconds $ScanDeadlineMilliseconds
}
catch {
    # parse/import/helper境界の例外本文はabsolute script/repo/temp pathを含み
    # 得る。PowerShell既定stderrへ流さず、固定UTF-8 1行とexit 2へ畳む。
    try {
        $encoding = New-Object System.Text.UTF8Encoding($false)
        $line = (
            'Private marker scan failed: scanner-entrypoint-failed' +
            [Environment]::NewLine
        )
        $bytes = $encoding.GetBytes($line)
        $stream = [Console]::OpenStandardOutput()
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()
    }
    catch {
        # stdout自体のfailureでも未redact例外をstderrへ連鎖させない。
    }
    $script:PrivateMarkerScannerExitCode = 2
}
exit $script:PrivateMarkerScannerExitCode
