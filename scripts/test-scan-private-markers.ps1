[CmdletBinding()]
param(
    [string]$Path = '',
    [switch]$EnvironmentContractProbe,
    [switch]$EnvironmentRemovalProbe,
    [switch]$ScannerBoundaryProbe,
    [switch]$WindowsJobCleanupProbe,
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
$processRunnerModule = Join-Path `
    $scriptRoot `
    'private-marker-process-runner.psm1'
$selfTest = $MyInvocation.MyCommand.Path
if (-not (Test-Path -LiteralPath $scanner -PathType Leaf)) {
    throw "Missing scanner script: $scanner"
}
if (-not (Test-Path -LiteralPath $processRunnerModule -PathType Leaf)) {
    throw 'Missing private marker process runner module.'
}
Microsoft.PowerShell.Core\Import-Module $processRunnerModule -Force

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
$gitCommands = @(Get-Command git -CommandType Application -ErrorAction Stop)
if ($gitCommands.Count -eq 0) {
    throw 'Native Git is required for the private-marker scanner self-test.'
}
$gitCommand = $gitCommands[0]
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$failures = New-Object System.Collections.Generic.List[string]

function Add-Failure {
    param([string]$Message)
    $failures.Add($Message) | Out-Null
}

function Test-PrivateMarkerCommandIsDeferredDefinition {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.Ast]$Command
    )

    $ancestor = $Command.Parent
    while ($null -ne $ancestor) {
        if (
            $ancestor -is
                [System.Management.Automation.Language.FunctionDefinitionAst] -or
            $ancestor -is
                [System.Management.Automation.Language.FunctionMemberAst] -or
            $ancestor -is
                [System.Management.Automation.Language.TypeDefinitionAst]
        ) {
            return $true
        }
        if (
            $ancestor -is
                [System.Management.Automation.Language.ScriptBlockExpressionAst]
        ) {
            # 保存した scriptblock は通常 data だが、command argument や
            # ScriptBlock.Invoke*() の receiver ならその場で実行され得る。
            $container = $ancestor.Parent
            $expressionCanExecuteScriptBlock = $false
            while ($null -ne $container) {
                if (
                    $container -is
                        [System.Management.Automation.Language.FunctionDefinitionAst] -or
                    $container -is
                        [System.Management.Automation.Language.FunctionMemberAst] -or
                    $container -is
                        [System.Management.Automation.Language.TypeDefinitionAst]
                ) {
                    return $true
                }
                if (
                    $container -is
                        [System.Management.Automation.Language.CommandAst] -or
                    $container -is
                        [System.Management.Automation.Language.InvokeMemberExpressionAst]
                ) {
                    $expressionCanExecuteScriptBlock = $true
                    break
                }
                $container = $container.Parent
            }
            if (-not $expressionCanExecuteScriptBlock) {
                return $true
            }
        }
        $ancestor = $ancestor.Parent
    }
    return $false
}

function Test-FirstBoundedInvocationIsRawTransport {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source
    )

    # 行番号や文字列順ではなく AST の所有関係を検査する。raw assignment の
    # RHS は helper 1 個だけの pipeline で、nested helper も許可しない。
    $tokens = $null
    $parseErrors = $null
    $sourceAst = [System.Management.Automation.Language.Parser]::ParseInput(
        $Source,
        [ref]$tokens,
        [ref]$parseErrors
    )
    if ($parseErrors.Count -gt 0) {
        return $false
    }

    # scope/module qualifierを除いたcommand identityで比較する。PowerShellの
    # command precedenceを悪用したtarget shadowも同じ名前として検出する。
    $normalizeFunctionName = {
        param([AllowEmptyString()][string]$Name)

        if ([string]::IsNullOrEmpty($Name)) {
            return ''
        }
        $normalized = $Name
        $moduleSeparator = $normalized.LastIndexOf('\')
        if ($moduleSeparator -ge 0) {
            $normalized = $normalized.Substring($moduleSeparator + 1)
        }
        return [regex]::Replace(
            $normalized,
            '^(?i:(?:global|script|local|private):)',
            ''
        )
    }
    $normalizeVariableName = {
        param([AllowEmptyString()][string]$Name)

        if ([string]::IsNullOrEmpty($Name)) {
            return ''
        }
        return [regex]::Replace(
            $Name,
            '^(?i:(?:global|script|local|private):)',
            ''
        )
    }

    # raw前のmodule loadはmodule bodyをeager実行できる。唯一のbootstrap
    # Import-Moduleだけは、script先頭からcommand末尾までのreview済みsourceが
    # exact一致し、module-qualified command identityを使う場合に限り許可する。
    $testCommandIsExactBootstrapModuleImport = {
        param([System.Management.Automation.Language.CommandAst]$Command)

        if (
            $Command.GetCommandName() -ne
                'Microsoft.PowerShell.Core\Import-Module' -or
            ($Command.Extent.Text -replace '\s+', ' ').Trim() -ne
                (
                    'Microsoft.PowerShell.Core\Import-Module ' +
                    '$processRunnerModule -Force'
                )
        ) {
            return $false
        }
        $commandAncestor = $Command.Parent
        while ($null -ne $commandAncestor) {
            if (
                $commandAncestor -is
                    [System.Management.Automation.Language.FunctionDefinitionAst] -or
                $commandAncestor -is
                    [System.Management.Automation.Language.FunctionMemberAst] -or
                $commandAncestor -is
                    [System.Management.Automation.Language.TypeDefinitionAst]
            ) {
                return $false
            }
            $commandAncestor = $commandAncestor.Parent
        }

        $normalizedBootstrapSource = (
            $Source.Substring(0, $Command.Extent.EndOffset) -replace
                "`r`n", "`n"
        ) -replace "`r", "`n"
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        try {
            $bootstrapHashBytes = $sha256.ComputeHash(
                [System.Text.Encoding]::UTF8.GetBytes(
                    $normalizedBootstrapSource
                )
            )
            $bootstrapHash = -join (
                $bootstrapHashBytes |
                    ForEach-Object { $_.ToString('x2') }
            )
        }
        finally {
            $sha256.Dispose()
        }
        return $bootstrapHash -eq
            'f29521a8724ec25d8611ea77e6bf8397cb0ff40cb9bff35aaa5d2b0c7b367ae8'
    }

    # function内のcall operatorは、同じfunctionのtop-levelで一度だけ
    # literal scriptblockへ束縛されたlocal変数なら、そのbodyをAST graphが
    # 別途検査できる。parameter/global/dynamic/reassigned targetは拒否する。
    $testDynamicCallTargetIsBoundLocalScriptBlock = {
        param(
            [System.Management.Automation.Language.CommandAst]$Command,
            [System.Management.Automation.Language.FunctionDefinitionAst]
                $FunctionDefinition
        )

        if (
            $Command.CommandElements.Count -eq 0 -or
            $Command.CommandElements[0] -isnot
                [System.Management.Automation.Language.VariableExpressionAst]
        ) {
            return $false
        }
        $targetVariablePath =
            $Command.CommandElements[0].VariablePath.UserPath
        if (
            [string]::IsNullOrWhiteSpace($targetVariablePath) -or
            $targetVariablePath -match ':'
        ) {
            return $false
        }

        $targetAssignments = @(
            $FunctionDefinition.FindAll(
                {
                    param($node)
                    if (
                        $node -isnot
                            [System.Management.Automation.Language.AssignmentStatementAst] -or
                        $node.Left -isnot
                            [System.Management.Automation.Language.VariableExpressionAst] -or
                        $node.Left.VariablePath.UserPath -ne $targetVariablePath
                    ) {
                        return $false
                    }
                    $assignmentAncestor = $node.Parent
                    while (
                        $null -ne $assignmentAncestor -and
                        $assignmentAncestor -ne $FunctionDefinition
                    ) {
                        if (
                            $assignmentAncestor -is
                                [System.Management.Automation.Language.ScriptBlockExpressionAst] -or
                            $assignmentAncestor -is
                                [System.Management.Automation.Language.FunctionDefinitionAst]
                        ) {
                            return $false
                        }
                        $assignmentAncestor = $assignmentAncestor.Parent
                    }
                    return $assignmentAncestor -eq $FunctionDefinition
                },
                $true
            )
        )
        if (
            $targetAssignments.Count -ne 1 -or
            [string]$targetAssignments[0].Operator -ne 'Equals' -or
            $targetAssignments[0].Extent.EndOffset -ge
                $Command.Extent.StartOffset -or
            $targetAssignments[0].Right -isnot
                [System.Management.Automation.Language.CommandExpressionAst] -or
            $targetAssignments[0].Right.Expression -isnot
                [System.Management.Automation.Language.ScriptBlockExpressionAst]
        ) {
            return $false
        }

        $assignedScriptBlock =
            $targetAssignments[0].Right.Expression.ScriptBlock
        $identityMutations = @(
            $assignedScriptBlock.FindAll(
                {
                    param($node)
                    if (
                        $node -isnot
                            [System.Management.Automation.Language.CommandAst]
                    ) {
                        return $false
                    }
                    $assignedCommandName = & $normalizeFunctionName (
                        $node.GetCommandName()
                    )
                    return @(
                        'Invoke-Expression',
                        'iex',
                        'Set-Alias',
                        'New-Alias',
                        'sal',
                        'nal',
                        'Import-Alias',
                        'ipal',
                        'Remove-Alias',
                        'ral',
                        'Import-Module',
                        'ipmo',
                        'New-Module',
                        'nmo',
                        'Set-Item',
                        'si',
                        'Set-Content',
                        'sc',
                        'New-Item',
                        'ni',
                        'Clear-Item',
                        'cli',
                        'Remove-Item',
                        'ri',
                        'rm',
                        'rmdir',
                        'del',
                        'erase',
                        'rd',
                        'Copy-Item',
                        'copy',
                        'cp',
                        'cpi',
                        'Move-Item',
                        'move',
                        'mv',
                        'mi',
                        'Rename-Item',
                        'ren',
                        'rni'
                    ) -contains $assignedCommandName
                },
                $true
            )
        )
        if ($identityMutations.Count -gt 0) {
            return $false
        }

        # Set-Variable/Variable: providerでtarget binding自体を差し替える
        # functionは、literal assignmentだけからruntime valueを証明しない。
        $targetMutations = @(
            $FunctionDefinition.FindAll(
                {
                    param($node)
                    if (
                        $node -isnot
                            [System.Management.Automation.Language.CommandAst]
                    ) {
                        return $false
                    }
                    $mutationName = & $normalizeFunctionName (
                        $node.GetCommandName()
                    )
                    return @(
                        'Set-Variable',
                        'sv',
                        'New-Variable',
                        'nv',
                        'Clear-Variable',
                        'clv',
                        'Remove-Variable',
                        'rv'
                    ) -contains $mutationName -or
                        (
                            @(
                                'Set-Item',
                                'si',
                                'Set-Content',
                                'sc',
                                'New-Item',
                                'ni',
                                'Clear-Item',
                                'cli',
                                'Remove-Item',
                                'ri',
                                'rm',
                                'rmdir',
                                'del',
                                'erase',
                                'rd'
                            ) -contains $mutationName -and
                            $node.Extent.Text -match '(?i)variable:'
                        )
                },
                $true
            )
        )
        return $targetMutations.Count -eq 0
    }

    # self-test cleanupは、bounded temp root・GUID名・reparse拒否を含む関数
    # 全体がreview済みbyte sequenceと一致する場合だけ例外にする。関数名や
    # `$resolvedRoot`変数だけを模倣したsourceはこのpositive proofを通らない。
    $testCommandIsExactBoundedFixtureCleanup = {
        param([System.Management.Automation.Language.CommandAst]$Command)

        if (
            (& $normalizeFunctionName $Command.GetCommandName()) -ne
                'Remove-Item' -or
            ($Command.Extent.Text -replace '\s+', ' ').Trim() -ne
                'Remove-Item -LiteralPath $resolvedRoot -Recurse -Force'
        ) {
            return $false
        }
        $cleanupFunction = $Command.Parent
        while (
            $null -ne $cleanupFunction -and
            $cleanupFunction -isnot
                [System.Management.Automation.Language.FunctionDefinitionAst]
        ) {
            $cleanupFunction = $cleanupFunction.Parent
        }
        if (
            $null -eq $cleanupFunction -or
            $cleanupFunction.Name -ne 'Remove-TestRoot'
        ) {
            return $false
        }

        $normalizedCleanupSource = (
            $cleanupFunction.Extent.Text -replace "`r`n", "`n"
        ) -replace "`r", "`n"
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        try {
            $cleanupHashBytes = $sha256.ComputeHash(
                [System.Text.Encoding]::UTF8.GetBytes(
                    $normalizedCleanupSource
                )
            )
            $cleanupHash = -join (
                $cleanupHashBytes |
                    ForEach-Object { $_.ToString('x2') }
            )
        }
        finally {
            $sha256.Dispose()
        }
        return $cleanupHash -eq
            'a70c391505cfa4c9bf783623e5178839fdefa270c3bbbadd7b88f3aec267ab5e'
    }

    # Remove/Clear-Item wrapperは、pathがEnv: providerへ固定される場合か、
    # 上のexact cleanup proofを満たす場合だけcommand identityへ影響しない。
    # filesystem変数や未知providerはfunction/alias targetを指し得るため拒否する。
    $testRemoveOrClearItemCanChangeCommandIdentity = {
        param([System.Management.Automation.Language.CommandAst]$Command)

        if (& $testCommandIsExactBoundedFixtureCleanup -Command $Command) {
            return $false
        }
        $providerPaths = New-Object System.Collections.Generic.List[object]
        $pendingPathValue = ''
        $positionalPathIndex = 0
        for (
            $elementIndex = 1;
            $elementIndex -lt $Command.CommandElements.Count;
            $elementIndex++
        ) {
            $element = $Command.CommandElements[$elementIndex]
            if (
                $element -is
                    [System.Management.Automation.Language.CommandParameterAst]
            ) {
                if (-not [string]::IsNullOrEmpty($pendingPathValue)) {
                    return $true
                }
                $parameterName = $element.ParameterName
                if (@('Path', 'LiteralPath') -contains $parameterName) {
                    if ($null -ne $element.Argument) {
                        $providerPaths.Add($element.Argument) | Out-Null
                    } else {
                        $pendingPathValue = 'path'
                    }
                } elseif (
                    @(
                        'Filter',
                        'Include',
                        'Exclude',
                        'ErrorAction',
                        'WarningAction',
                        'InformationAction',
                        'ProgressAction',
                        'ErrorVariable',
                        'WarningVariable',
                        'InformationVariable',
                        'OutVariable',
                        'OutBuffer',
                        'PipelineVariable'
                    ) -contains $parameterName
                ) {
                    if ($null -eq $element.Argument) {
                        $pendingPathValue = 'skip'
                    }
                } elseif (
                    @(
                        'Force',
                        'Recurse',
                        'WhatIf',
                        'Confirm',
                        'Verbose',
                        'Debug'
                    ) -notcontains $parameterName
                ) {
                    return $true
                }
                continue
            }
            if ($pendingPathValue -eq 'path') {
                $providerPaths.Add($element) | Out-Null
                $pendingPathValue = ''
                continue
            }
            if ($pendingPathValue -eq 'skip') {
                $pendingPathValue = ''
                continue
            }
            if ($positionalPathIndex -ne 0) {
                return $true
            }
            $providerPaths.Add($element) | Out-Null
            $positionalPathIndex++
        }
        if (
            -not [string]::IsNullOrEmpty($pendingPathValue) -or
            $providerPaths.Count -eq 0
        ) {
            return $true
        }

        foreach ($providerPath in $providerPaths) {
            if (
                $providerPath -is
                    [System.Management.Automation.Language.StringConstantExpressionAst]
            ) {
                if (
                    [string]$providerPath.Value -match
                        '(?i)^(?:Alias|Function):'
                ) {
                    return $true
                }
                if ([string]$providerPath.Value -match '(?i)^Env:\\') {
                    continue
                }
                return $true
            }
            # `('Env:\' + $name)` はprovider prefixが固定され、後半の値が
            # command namespaceへ切り替える余地がない。
            if (
                $providerPath.Extent.Text -match
                    '(?i)^\s*(?:\(\s*)?[''"](?:Alias|Function):'
            ) {
                return $true
            }
            if (
                $providerPath.Extent.Text -match
                    '(?i)^\s*(?:\(\s*)?[''"]Env:\\'
            ) {
                continue
            }
            return $true
        }
        return $false
    }

    $rawAssignments = @(
        $sourceAst.FindAll(
            {
                param($node)
                return (
                    $node -is
                        [System.Management.Automation.Language.AssignmentStatementAst] -and
                    $node.Left -is
                        [System.Management.Automation.Language.VariableExpressionAst] -and
                    $node.Left.VariablePath.UserPath -eq 'rawTransportResult'
                )
            },
            $true
        )
    )
    if (
        $rawAssignments.Count -ne 1 -or
        $rawAssignments[0].Right -isnot
            [System.Management.Automation.Language.PipelineAst]
    ) {
        return $false
    }

    $rawPipelineElements = @($rawAssignments[0].Right.PipelineElements)
    if (
        $rawPipelineElements.Count -ne 1 -or
        $rawPipelineElements[0] -isnot
            [System.Management.Automation.Language.CommandAst] -or
        (& $normalizeFunctionName (
            $rawPipelineElements[0].GetCommandName()
        )) -ne
            'Invoke-PrivateMarkerBoundedProcess'
    ) {
        return $false
    }
    $rawOuterCommand = $rawPipelineElements[0]
    $rawNestedCalls = @(
        $rawAssignments[0].Right.FindAll(
            {
                param($node)
                return (
                    $node -is
                        [System.Management.Automation.Language.CommandAst] -and
                    (& $normalizeFunctionName (
                        $node.GetCommandName()
                    )) -eq
                        'Invoke-PrivateMarkerBoundedProcess'
                )
            },
            $true
        )
    )
    if (
        $rawNestedCalls.Count -ne 1 -or
        (
            Test-PrivateMarkerCommandIsDeferredDefinition `
                -Command $rawOuterCommand
        )
    ) {
        return $false
    }

    # `using module` はcommand ASTを経由せずparse/import時にmodule bodyを
    # 実行するため、first eager runner callより前では一律に拒否する。
    $earlyUsingModuleStatements = @(
        $sourceAst.FindAll(
            {
                param($node)
                return (
                    $node -is
                        [System.Management.Automation.Language.UsingStatementAst] -and
                    [string]$node.UsingStatementKind -eq 'Module' -and
                    $node.Extent.StartOffset -lt
                        $rawOuterCommand.Extent.EndOffset
                )
            },
            $true
        )
    )
    if ($earlyUsingModuleStatements.Count -gt 0) {
        return $false
    }

    $allBoundedCalls = @(
        $sourceAst.FindAll(
            {
                param($node)
                return (
                    $node -is
                        [System.Management.Automation.Language.CommandAst] -and
                    (& $normalizeFunctionName (
                        $node.GetCommandName()
                    )) -eq
                        'Invoke-PrivateMarkerBoundedProcess'
                )
            },
            $true
        )
    )
    # helper を含む function は定義だけなら deferred だが、raw fixture より
    # 前の direct call や transitive call で実行される。関数call graphを
    # fixed pointまで伝播し、dynamic call operator は解決不能なら拒否する。
    $functionDefinitions = @(
        $sourceAst.FindAll(
            {
                param($node)
                return (
                    $node -is
                        [System.Management.Automation.Language.FunctionDefinitionAst] -and
                    $node.Extent.StartOffset -lt
                        $rawOuterCommand.Extent.StartOffset
                )
            },
            $true
        )
    )
    $riskyFunctionNames = (
        [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase
        )
    )
    foreach ($functionDefinition in $functionDefinitions) {
        $normalizedDefinitionName = (
            & $normalizeFunctionName $functionDefinition.Name
        )
        # raw assignmentのcommand名そのものがsource内functionにshadow
        # されれば、module runnerを呼んだ証明にならないため即時rejectする。
        if (
            $normalizedDefinitionName -eq
                'Invoke-PrivateMarkerBoundedProcess'
        ) {
            return $false
        }
        $containedBoundedCalls = @(
            $functionDefinition.FindAll(
                {
                    param($node)
                    return (
                        $node -is
                            [System.Management.Automation.Language.CommandAst] -and
                        (& $normalizeFunctionName (
                            $node.GetCommandName()
                        )) -eq
                            'Invoke-PrivateMarkerBoundedProcess'
                    )
                },
                $true
            )
        )
        if ($containedBoundedCalls.Count -gt 0) {
            [void]$riskyFunctionNames.Add(
                $normalizedDefinitionName
            )
        }
    }
    do {
        $riskyFunctionSetChanged = $false
        foreach ($functionDefinition in $functionDefinitions) {
            $normalizedDefinitionName = (
                & $normalizeFunctionName $functionDefinition.Name
            )
            if ($riskyFunctionNames.Contains($normalizedDefinitionName)) {
                continue
            }
            $containedCommands = @(
                $functionDefinition.FindAll(
                    {
                        param($node)
                        return (
                            $node -is
                                [System.Management.Automation.Language.CommandAst]
                        )
                    },
                    $true
                )
            )
            foreach ($containedCommand in $containedCommands) {
                $containedCommandName = & $normalizeFunctionName (
                    $containedCommand.GetCommandName()
                )
                $isUnresolvedCallOperator = (
                    [string]::IsNullOrEmpty($containedCommandName) -and
                    @('Ampersand', 'Dot') -contains
                        ([string]$containedCommand.InvocationOperator)
                )
                $isBoundLocalScriptBlockCall = (
                    $isUnresolvedCallOperator -and
                    (
                        & $testDynamicCallTargetIsBoundLocalScriptBlock `
                            -Command $containedCommand `
                            -FunctionDefinition $functionDefinition
                    )
                )
                if (
                    (
                        -not [string]::IsNullOrEmpty($containedCommandName) -and
                        $riskyFunctionNames.Contains($containedCommandName)
                    ) -or
                    (
                        $isUnresolvedCallOperator -and
                        -not $isBoundLocalScriptBlockCall
                    )
                ) {
                    if (
                        $riskyFunctionNames.Add($normalizedDefinitionName)
                    ) {
                        $riskyFunctionSetChanged = $true
                    }
                    break
                }
            }
        }
    } while ($riskyFunctionSetChanged)

    # class constructor/methodもdefinitionだけならdeferredだが、::new()や
    # static/member callから実行される。function/type間の参照をfixed pointで
    # 伝播し、wrapper functionを挟んだclass起動も見逃さない。
    $typeDefinitions = @(
        $sourceAst.FindAll(
            {
                param($node)
                return (
                    $node -is
                        [System.Management.Automation.Language.TypeDefinitionAst] -and
                    $node.Extent.StartOffset -lt
                        $rawOuterCommand.Extent.StartOffset
                )
            },
            $true
        )
    )
    $riskyTypeNames = (
        [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase
        )
    )
    foreach ($typeDefinition in $typeDefinitions) {
        $containedBoundedCalls = @(
            $typeDefinition.FindAll(
                {
                    param($node)
                    return (
                        $node -is
                            [System.Management.Automation.Language.CommandAst] -and
                        (& $normalizeFunctionName (
                            $node.GetCommandName()
                        )) -eq
                            'Invoke-PrivateMarkerBoundedProcess'
                    )
                },
                $true
            )
        )
        if ($containedBoundedCalls.Count -gt 0) {
            [void]$riskyTypeNames.Add($typeDefinition.Name)
        }
    }
    do {
        $riskGraphChanged = $false
        foreach ($typeDefinition in $typeDefinitions) {
            if ($riskyTypeNames.Contains($typeDefinition.Name)) {
                continue
            }
            $typeCommands = @(
                $typeDefinition.FindAll(
                    {
                        param($node)
                        return (
                            $node -is
                                [System.Management.Automation.Language.CommandAst]
                        )
                    },
                    $true
                )
            )
            $typeIsRisky = $false
            foreach ($typeCommand in $typeCommands) {
                $typeCommandName = & $normalizeFunctionName (
                    $typeCommand.GetCommandName()
                )
                $typeHasDynamicCall = (
                    [string]::IsNullOrEmpty($typeCommandName) -and
                    @('Ampersand', 'Dot') -contains
                        ([string]$typeCommand.InvocationOperator)
                )
                if (
                    $riskyFunctionNames.Contains($typeCommandName) -or
                    @('Invoke-Expression', 'iex') -contains $typeCommandName -or
                    @(
                        'Import-Module',
                        'ipmo',
                        'New-Module',
                        'nmo',
                        'Import-Alias',
                        'ipal',
                        'Remove-Alias',
                        'ral',
                        'Set-Item',
                        'si',
                        'Set-Content',
                        'sc',
                        'New-Item',
                        'ni',
                        'Copy-Item',
                        'copy',
                        'cp',
                        'cpi',
                        'Move-Item',
                        'move',
                        'mv',
                        'mi',
                        'Rename-Item',
                        'ren',
                        'rni'
                    ) -contains $typeCommandName -or
                    (
                        @(
                            'Remove-Item',
                            'ri',
                            'rm',
                            'rmdir',
                            'del',
                            'erase',
                            'rd',
                            'Clear-Item',
                            'cli'
                        ) -contains $typeCommandName -and
                        (
                            & $testRemoveOrClearItemCanChangeCommandIdentity `
                                -Command $typeCommand
                        )
                    ) -or
                    $typeCommandName -match '(?i)\.ps(?:1|m1)$' -or
                    ([string]$typeCommand.InvocationOperator) -eq 'Dot' -or
                    $typeHasDynamicCall
                ) {
                    $typeIsRisky = $true
                    break
                }
            }
            if (-not $typeIsRisky) {
                # PowerShell classの継承元はTypeExpressionAstではなく
                # TypeConstraintAst(BaseTypes)で保持される。derived生成時に
                # 暗黙実行されるrisky base constructorもfixed pointへ入れる。
                foreach ($baseType in @($typeDefinition.BaseTypes)) {
                    if (
                        $riskyTypeNames.Contains(
                            [string]$baseType.TypeName.FullName
                        )
                    ) {
                        $typeIsRisky = $true
                        break
                    }
                }
            }
            if (-not $typeIsRisky) {
                $typeReferences = @(
                    $typeDefinition.FindAll(
                        {
                            param($node)
                            return (
                                $node -is
                                    [System.Management.Automation.Language.TypeExpressionAst]
                            )
                        },
                        $true
                    )
                )
                foreach ($typeReference in $typeReferences) {
                    if (
                        $riskyTypeNames.Contains(
                            [string]$typeReference.TypeName.FullName
                        )
                    ) {
                        $typeIsRisky = $true
                        break
                    }
                }
            }
            if (
                $typeIsRisky -and
                $riskyTypeNames.Add($typeDefinition.Name)
            ) {
                $riskGraphChanged = $true
            }
        }
        foreach ($functionDefinition in $functionDefinitions) {
            $normalizedDefinitionName = (
                & $normalizeFunctionName $functionDefinition.Name
            )
            if ($riskyFunctionNames.Contains($normalizedDefinitionName)) {
                continue
            }
            $functionIsRisky = $false
            $functionTypeReferences = @(
                $functionDefinition.FindAll(
                    {
                        param($node)
                        return (
                            $node -is
                                [System.Management.Automation.Language.TypeExpressionAst]
                        )
                    },
                    $true
                )
            )
            foreach ($typeReference in $functionTypeReferences) {
                if (
                    $riskyTypeNames.Contains(
                        [string]$typeReference.TypeName.FullName
                    )
                ) {
                    $functionIsRisky = $true
                    break
                }
            }
            if (-not $functionIsRisky) {
                $functionCommands = @(
                    $functionDefinition.FindAll(
                        {
                            param($node)
                            return (
                                $node -is
                                    [System.Management.Automation.Language.CommandAst]
                            )
                        },
                        $true
                    )
                )
                foreach ($functionCommand in $functionCommands) {
                    $functionCommandName = & $normalizeFunctionName (
                        $functionCommand.GetCommandName()
                    )
                    $functionHasDynamicCall = (
                        [string]::IsNullOrEmpty($functionCommandName) -and
                        @('Ampersand', 'Dot') -contains
                            ([string]$functionCommand.InvocationOperator)
                    )
                    $functionHasSafeLocalScriptBlockCall = (
                        $functionHasDynamicCall -and
                        (
                            & $testDynamicCallTargetIsBoundLocalScriptBlock `
                                -Command $functionCommand `
                                -FunctionDefinition $functionDefinition
                        )
                    )
                    if (
                        $riskyFunctionNames.Contains($functionCommandName) -or
                        @('Invoke-Expression', 'iex') -contains
                            $functionCommandName -or
                        @(
                            'Import-Module',
                            'ipmo',
                            'New-Module',
                            'nmo',
                            'Import-Alias',
                            'ipal',
                            'Remove-Alias',
                            'ral',
                            'Set-Item',
                            'si',
                            'Set-Content',
                            'sc',
                            'New-Item',
                            'ni',
                            'Copy-Item',
                            'copy',
                            'cp',
                            'cpi',
                            'Move-Item',
                            'move',
                            'mv',
                            'mi',
                            'Rename-Item',
                            'ren',
                            'rni'
                        ) -contains $functionCommandName -or
                        (
                            @(
                                'Remove-Item',
                                'ri',
                                'rm',
                                'rmdir',
                                'del',
                                'erase',
                                'rd',
                                'Clear-Item',
                                'cli'
                            ) -contains $functionCommandName -and
                            (
                                & $testRemoveOrClearItemCanChangeCommandIdentity `
                                    -Command $functionCommand
                            )
                        ) -or
                        $functionCommandName -match '(?i)\.ps(?:1|m1)$' -or
                        ([string]$functionCommand.InvocationOperator) -eq 'Dot' -or
                        (
                            $functionHasDynamicCall -and
                            -not $functionHasSafeLocalScriptBlockCall
                        )
                    ) {
                        $functionIsRisky = $true
                        break
                    }
                }
            }
            if (
                $functionIsRisky -and
                $riskyFunctionNames.Add($normalizedDefinitionName)
            ) {
                $riskGraphChanged = $true
            }
        }
    } while ($riskGraphChanged)

    $earlyEagerCommands = @(
        $sourceAst.FindAll(
            {
                param($node)
                return (
                    $node -is
                        [System.Management.Automation.Language.CommandAst] -and
                    $node.Extent.StartOffset -lt
                        $rawOuterCommand.Extent.EndOffset
                )
            },
            $true
        ) |
            Where-Object {
                -not (
                    Test-PrivateMarkerCommandIsDeferredDefinition -Command $_
                )
            }
    )
    foreach ($earlyCommand in $earlyEagerCommands) {
        $earlyCommandName = & $normalizeFunctionName (
            $earlyCommand.GetCommandName()
        )
        if (
            @(
                'Import-Module',
                'ipmo',
                'New-Module',
                'nmo'
            ) -contains $earlyCommandName
        ) {
            if (
                $earlyCommandName -eq 'Import-Module' -and
                (
                    & $testCommandIsExactBootstrapModuleImport `
                        -Command $earlyCommand
                )
            ) {
                continue
            }
            return $false
        }
        # Invoke-Expressionはliteral/dynamicの別を問わずruntime codeへ変換
        # できるため、first-runner proofより前では静的安全性を証明しない。
        if (@('Invoke-Expression', 'iex') -contains $earlyCommandName) {
            return $false
        }
        # alias import/removeとAlias:/Function: provider mutationはcommand
        # identityを外部入力・削除・複製で変更できる。filesystemとの静的識別を
        # 広げず、raw前は保守的に拒否する。
        if (
            @(
                'Import-Alias',
                'ipal',
                'Remove-Alias',
                'ral',
                'Remove-Item',
                'ri',
                'rm',
                'rmdir',
                'del',
                'erase',
                'rd',
                'Clear-Item',
                'cli',
                'Copy-Item',
                'copy',
                'cp',
                'cpi',
                'Move-Item',
                'move',
                'mv',
                'mi',
                'Rename-Item',
                'ren',
                'rni'
            ) -contains $earlyCommandName
        ) {
            return $false
        }
        # dot-sourceやPowerShell script pathの直接/call-operator実行は、
        # global alias/functionを書き換えられるため、first-call証明前は拒否する。
        if (
            ([string]$earlyCommand.InvocationOperator) -eq 'Dot' -or
            $earlyCommandName -match '(?i)\.ps(?:1|m1)$'
        ) {
            return $false
        }
        if (
            $earlyCommandName -eq 'New-Object' -and
            $riskyTypeNames.Count -gt 0
        ) {
            foreach (
                $newObjectElement in
                    @($earlyCommand.CommandElements | Select-Object -Skip 1)
            ) {
                if (
                    $newObjectElement -is
                        [System.Management.Automation.Language.CommandParameterAst]
                ) {
                    if ($null -eq $newObjectElement.Argument) {
                        continue
                    }
                    $newObjectElement = $newObjectElement.Argument
                }
                if (
                    $newObjectElement -isnot
                        [System.Management.Automation.Language.StringConstantExpressionAst]
                ) {
                    return $false
                }
                if (
                    $riskyTypeNames.Contains(
                        [string]$newObjectElement.Value
                    )
                ) {
                    return $false
                }
            }
        }
        $isUnresolvedCallOperator = (
            [string]::IsNullOrEmpty($earlyCommandName) -and
            @('Ampersand', 'Dot') -contains
                ([string]$earlyCommand.InvocationOperator)
        )
        if (
            (
                -not [string]::IsNullOrEmpty($earlyCommandName) -and
                $riskyFunctionNames.Contains($earlyCommandName)
            ) -or
            $isUnresolvedCallOperator
        ) {
            return $false
        }

        # source内aliasが helper-bearing functionを指す場合は、alias callを
        # 別名として解決する前に定義時点で保守的に拒否する。dynamic valueも
        # staticに安全性を証明できないため拒否する。
        if (
            @('Set-Alias', 'New-Alias', 'sal', 'nal') -contains
                $earlyCommandName
        ) {
            for (
                $aliasElementIndex = 1;
                $aliasElementIndex -lt $earlyCommand.CommandElements.Count;
                $aliasElementIndex++
            ) {
                $aliasElement = $earlyCommand.CommandElements[$aliasElementIndex]
                if (
                    $aliasElement -is
                        [System.Management.Automation.Language.CommandParameterAst]
                ) {
                    if ($null -eq $aliasElement.Argument) {
                        continue
                    }
                    $aliasElement = $aliasElement.Argument
                }
                if (
                    $aliasElement -isnot
                        [System.Management.Automation.Language.StringConstantExpressionAst]
                ) {
                    return $false
                }
                $aliasValue = & $normalizeFunctionName $aliasElement.Value
                $riskSensitiveAliasTargets = @(
                    'Invoke-Expression',
                    'iex',
                    'New-Object',
                    'Set-Alias',
                    'New-Alias',
                    'sal',
                    'nal',
                    'Import-Module',
                    'ipmo',
                    'New-Module',
                    'nmo',
                    'Set-Item',
                    'si',
                    'Set-Content',
                    'sc',
                    'New-Item',
                    'ni',
                    'Clear-Item',
                    'cli',
                    'Remove-Item',
                    'ri',
                    'rm',
                    'rmdir',
                    'del',
                    'erase',
                    'rd',
                    'Import-Alias',
                    'ipal',
                    'Remove-Alias',
                    'ral',
                    'Get-Command',
                    'gcm',
                    'Get-Item',
                    'gi',
                    'Set-Variable',
                    'sv',
                    'New-Variable',
                    'nv',
                    'Clear-Variable',
                    'clv',
                    'Remove-Variable',
                    'rv',
                    'Copy-Item',
                    'copy',
                    'cp',
                    'cpi',
                    'Move-Item',
                    'move',
                    'mv',
                    'mi',
                    'Rename-Item',
                    'ren',
                    'rni'
                )
                if (
                    $aliasValue -eq
                        'Invoke-PrivateMarkerBoundedProcess' -or
                    $riskyFunctionNames.Contains($aliasValue) -or
                    $riskSensitiveAliasTargets -contains $aliasValue
                ) {
                    return $false
                }
            }
        }

        # Set-Item経由でもAlias:/Function: providerはtarget command identityを
        # 置換できる。pathがdynamic、wildcard、provider対象ならfirst-callの
        # provenanceを証明できないため保守的に拒否する。
        if (
            @(
                'Set-Item',
                'si',
                'Set-Content',
                'sc',
                'New-Item',
                'ni'
            ) -contains $earlyCommandName
        ) {
            $setItemPaths = New-Object System.Collections.Generic.List[object]
            $pendingSetItemValue = ''
            $setItemPositionalIndex = 0
            for (
                $elementIndex = 1;
                $elementIndex -lt $earlyCommand.CommandElements.Count;
                $elementIndex++
            ) {
                $setItemElement = $earlyCommand.CommandElements[$elementIndex]
                if (
                    $setItemElement -is
                        [System.Management.Automation.Language.CommandParameterAst]
                ) {
                    $parameterName = $setItemElement.ParameterName
                    $parameterOwnsPath = @('Path', 'LiteralPath') -contains
                        $parameterName
                    $parameterConsumesValue = @(
                        'Path',
                        'LiteralPath',
                        'Value',
                        'ItemType',
                        'Filter',
                        'Include',
                        'Exclude',
                        'Encoding',
                        'Stream',
                        'ErrorAction',
                        'WarningAction',
                        'InformationAction',
                        'ProgressAction'
                    ) -contains $parameterName
                    if ($null -ne $setItemElement.Argument) {
                        if ($parameterOwnsPath) {
                            $setItemPaths.Add(
                                $setItemElement.Argument
                            ) | Out-Null
                        }
                        $pendingSetItemValue = ''
                    } elseif ($parameterOwnsPath) {
                        $pendingSetItemValue = 'path'
                    } elseif ($parameterConsumesValue) {
                        $pendingSetItemValue = 'skip'
                    } else {
                        $pendingSetItemValue = ''
                    }
                    continue
                }
                if ($pendingSetItemValue -eq 'skip') {
                    $pendingSetItemValue = ''
                    continue
                }
                if ($pendingSetItemValue -eq 'path') {
                    $setItemPaths.Add($setItemElement) | Out-Null
                    $pendingSetItemValue = ''
                    continue
                }
                if ($setItemPositionalIndex -eq 0) {
                    $setItemPaths.Add($setItemElement) | Out-Null
                }
                $setItemPositionalIndex++
            }
            if (
                $pendingSetItemValue -eq 'path' -or
                $setItemPaths.Count -eq 0
            ) {
                return $false
            }
            foreach ($setItemPath in $setItemPaths) {
                $setItemPathValue = ''
                $setItemPathIsSafeFileSystemJoin = $false
                if (
                    $setItemPath -is
                        [System.Management.Automation.Language.StringConstantExpressionAst]
                ) {
                    $setItemPathValue = [string]$setItemPath.Value
                } elseif (
                    $setItemPath -is
                        [System.Management.Automation.Language.VariableExpressionAst]
                ) {
                    # `$p='Function:target'` のようなliteral-tainted pathは
                    # provider mutationとして解決する。一方、self-testのtemp
                    # fixtureはtop-level Join-Pathで構築されるため、そのcommand
                    # とprovider prefix不在を確認できた場合だけfilesystem path
                    # として許可する。
                    $setItemVariableName = $setItemPath.VariablePath.UserPath
                    $setItemAssignments = @(
                        $sourceAst.FindAll(
                            {
                                param($node)
                                return (
                                    $node -is
                                        [System.Management.Automation.Language.AssignmentStatementAst] -and
                                    $node.Left -is
                                        [System.Management.Automation.Language.VariableExpressionAst] -and
                                    $node.Left.VariablePath.UserPath -eq
                                        $setItemVariableName -and
                                    $node.Extent.EndOffset -le
                                        $earlyCommand.Extent.StartOffset
                                )
                            },
                            $true
                        ) |
                            Where-Object {
                                -not (
                                    Test-PrivateMarkerCommandIsDeferredDefinition `
                                        -Command $_
                                )
                            } |
                            Sort-Object { $_.Extent.EndOffset }
                    )
                    if ($setItemAssignments.Count -eq 0) {
                        return $false
                    }
                    $setItemAssignmentRight = (
                        $setItemAssignments[-1].Right
                    )
                    if (
                        $setItemAssignmentRight -is
                            [System.Management.Automation.Language.CommandExpressionAst] -and
                        $setItemAssignmentRight.Expression -is
                            [System.Management.Automation.Language.StringConstantExpressionAst]
                    ) {
                        $setItemPathValue = [string](
                            $setItemAssignmentRight.Expression.Value
                        )
                    } elseif (
                        $setItemAssignmentRight -is
                            [System.Management.Automation.Language.PipelineAst] -and
                        $setItemAssignmentRight.PipelineElements.Count -eq 1 -and
                        $setItemAssignmentRight.PipelineElements[0] -is
                            [System.Management.Automation.Language.CommandAst] -and
                        (
                            $setItemAssignmentRight.PipelineElements[0].GetCommandName()
                        ) -eq 'Join-Path' -and
                        $setItemAssignmentRight.Extent.Text -notmatch
                            '(?i:(?:Alias|Function):)'
                    ) {
                        $setItemPathIsSafeFileSystemJoin = $true
                    } else {
                        return $false
                    }
                } else {
                    return $false
                }
                if ($setItemPathIsSafeFileSystemJoin) {
                    continue
                }
                if (
                    $setItemPathValue -match '[*?\[\]]' -or
                    $setItemPathValue -match
                        '^(?i:(?:Alias|Function):[\\/]*)'
                ) {
                    return $false
                }
            }
        }

        # Get-Command / Get-Item が risky functionを取得すれば、その後の
        # .ScriptBlock.Invoke() で実行できる。literal targetだけを解析し、
        # wildcard・dynamic・targetなしはfail closedにする。`git
        # -CommandType Application` のようなliteral application lookupは通す。
        if (
            @('Get-Command', 'gcm', 'Get-Item', 'gi') -contains
                $earlyCommandName
        ) {
            $lookupTargets = New-Object System.Collections.Generic.List[object]
            $pendingLookupValue = ''
            for (
                $elementIndex = 1;
                $elementIndex -lt $earlyCommand.CommandElements.Count;
                $elementIndex++
            ) {
                $lookupElement = $earlyCommand.CommandElements[$elementIndex]
                if (
                    $lookupElement -is
                        [System.Management.Automation.Language.CommandParameterAst]
                ) {
                    $parameterName = $lookupElement.ParameterName
                    $parameterOwnsTarget = @(
                        'Name', 'Path', 'LiteralPath'
                    ) -contains $parameterName
                    $parameterConsumesValue = @(
                        'Name',
                        'Path',
                        'LiteralPath',
                        'CommandType',
                        'Module',
                        'ErrorAction',
                        'WarningAction',
                        'InformationAction',
                        'ProgressAction'
                    ) -contains $parameterName
                    if ($null -ne $lookupElement.Argument) {
                        if ($parameterOwnsTarget) {
                            $lookupTargets.Add(
                                $lookupElement.Argument
                            ) | Out-Null
                        }
                        $pendingLookupValue = ''
                    } elseif ($parameterOwnsTarget) {
                        $pendingLookupValue = 'target'
                    } elseif ($parameterConsumesValue) {
                        $pendingLookupValue = 'skip'
                    } else {
                        $pendingLookupValue = ''
                    }
                    continue
                }
                if ($pendingLookupValue -eq 'skip') {
                    $pendingLookupValue = ''
                    continue
                }
                if ($pendingLookupValue -eq 'target') {
                    $lookupTargets.Add($lookupElement) | Out-Null
                    $pendingLookupValue = ''
                    continue
                }
                $lookupTargets.Add($lookupElement) | Out-Null
            }
            if (
                $pendingLookupValue -eq 'target' -or
                $lookupTargets.Count -eq 0
            ) {
                return $false
            }
            foreach ($lookupTarget in $lookupTargets) {
                if (
                    $lookupTarget -isnot
                        [System.Management.Automation.Language.StringConstantExpressionAst]
                ) {
                    return $false
                }
                $lookupValue = [string]$lookupTarget.Value
                if ($lookupValue -match '[*?\[\]]') {
                    return $false
                }
                if (@('Get-Command', 'gcm') -contains $earlyCommandName) {
                    $lookupFunctionName = & $normalizeFunctionName $lookupValue
                    if ($riskyFunctionNames.Contains($lookupFunctionName)) {
                        return $false
                    }
                } elseif ($lookupValue -match '^(?i:function:[\\/]*)(?<name>.+)$') {
                    $lookupFunctionName = & $normalizeFunctionName (
                        $Matches['name']
                    )
                    if ($riskyFunctionNames.Contains($lookupFunctionName)) {
                        return $false
                    }
                }
            }
        }
    }

    if ($riskyTypeNames.Count -gt 0) {
        # cast / `-as` / static property accessもconstructor・static initializerを
        # 起動し得る。InvokeMemberだけでなく、deferred definition外のrisky type
        # reference全体をraw call前では拒否する。
        $earlyRiskyTypeReferences = @(
            $sourceAst.FindAll(
                {
                    param($node)
                    return (
                        $node -is
                            [System.Management.Automation.Language.TypeExpressionAst] -and
                        $node.Extent.StartOffset -lt
                            $rawOuterCommand.Extent.EndOffset
                    )
                },
                $true
            ) |
                Where-Object {
                    -not (
                        Test-PrivateMarkerCommandIsDeferredDefinition `
                            -Command $_
                    ) -and
                    $riskyTypeNames.Contains(
                        [string]$_.TypeName.FullName
                    )
                }
        )
        if ($earlyRiskyTypeReferences.Count -gt 0) {
            return $false
        }

        $earlyRiskyTypeInvocations = @(
            $sourceAst.FindAll(
                {
                    param($node)
                    return (
                        $node -is
                            [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
                        $node.Extent.StartOffset -lt
                            $rawOuterCommand.Extent.EndOffset
                    )
                },
                $true
            ) |
                Where-Object {
                    if (
                        Test-PrivateMarkerCommandIsDeferredDefinition `
                            -Command $_
                    ) {
                        return $false
                    }
                    $typeReferences = @(
                        $_.FindAll(
                            {
                                param($node)
                                return (
                                    $node -is
                                        [System.Management.Automation.Language.TypeExpressionAst]
                                )
                            },
                            $true
                        )
                    )
                    foreach ($typeReference in $typeReferences) {
                        if (
                            $riskyTypeNames.Contains(
                                [string]$typeReference.TypeName.FullName
                            )
                        ) {
                            return $true
                        }
                    }
                    return $false
                }
        )
        if ($earlyRiskyTypeInvocations.Count -gt 0) {
            return $false
        }
    }

    # receiver式の一部にsafe変数があっても、pipeline/commandが返す値全体の
    # provenanceは証明できない。raw transportより前のeager Invoke* memberは
    # receiver全体を安全と証明する仕組みがない限り一律に拒否する。
    $earlyInvokeMembers = @(
        $sourceAst.FindAll(
            {
                param($node)
                return (
                    $node -is
                        [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
                    $node.Extent.StartOffset -lt
                        $rawOuterCommand.Extent.EndOffset -and
                    $node.Member.Extent.Text -match '^(?i:Invoke)'
                )
            },
            $true
        ) |
            Where-Object {
                -not (
                    Test-PrivateMarkerCommandIsDeferredDefinition `
                        -Command $_
                )
            }
    )
    if ($earlyInvokeMembers.Count -gt 0) {
        return $false
    }
    foreach ($riskyFunctionName in $riskyFunctionNames) {
        $earlyFunctionReferences = @(
            $sourceAst.FindAll(
                {
                    param($node)
                    return (
                        $node -is
                            [System.Management.Automation.Language.VariableExpressionAst] -and
                        $node.Extent.StartOffset -lt
                            $rawOuterCommand.Extent.EndOffset
                    )
                },
                $true
            ) |
                Where-Object {
                    $variablePath = $_.VariablePath.UserPath
                    if ($variablePath -notmatch '^(?i:function:)') {
                        return $false
                    }
                    $variableFunctionName = & $normalizeFunctionName (
                        $variablePath.Substring('function:'.Length)
                    )
                    return $variableFunctionName -eq $riskyFunctionName
                }
        )
        if ($earlyFunctionReferences.Count -gt 0) {
            return $false
        }
    }

    # 保存scriptblockを「既知の危険名がないから安全」とは判定しない。
    # command/member/type invocationを含まない明示的な式だけをpositive setへ
    # 入れ、IEX、dynamic call、ScriptBlock::Create、unknown commandを含む
    # deferred codeはすべて保守的にriskyとして扱う。
    $testStoredScriptBlockIsExplicitlySafe = {
        param(
            [System.Management.Automation.Language.ScriptBlockExpressionAst]
                $ScriptBlockExpression
        )

        $storedScriptBlock = $ScriptBlockExpression.ScriptBlock
        if (
            $null -ne $storedScriptBlock.ParamBlock -or
            $null -ne $storedScriptBlock.DynamicParamBlock -or
            $null -ne $storedScriptBlock.BeginBlock -or
            $null -ne $storedScriptBlock.ProcessBlock -or
            $null -eq $storedScriptBlock.EndBlock -or
            $storedScriptBlock.EndBlock.Statements.Count -ne 1 -or
            (
                $null -ne $storedScriptBlock.EndBlock.Traps -and
                $storedScriptBlock.EndBlock.Traps.Count -ne 0
            )
        ) {
            return $false
        }

        $safeStatement = $storedScriptBlock.EndBlock.Statements[0]
        if (
            $safeStatement -isnot
                [System.Management.Automation.Language.PipelineAst] -or
            $safeStatement.PipelineElements.Count -ne 1 -or
            $safeStatement.PipelineElements[0] -isnot
                [System.Management.Automation.Language.CommandExpressionAst]
        ) {
            return $false
        }
        $safeCommandExpression = $safeStatement.PipelineElements[0]
        if (
            $safeCommandExpression.Redirections.Count -ne 0 -or
            $safeCommandExpression.Expression -isnot
                [System.Management.Automation.Language.VariableExpressionAst]
        ) {
            return $false
        }
        # `$global:_` 等は別scopeの任意値を返せるため、qualifierなしの
        # pipeline current-item 変数だけをpositive setへ入れる。
        return @('_', 'PSItem') -contains (
            $safeCommandExpression.Expression.VariablePath.UserPath
        )
    }

    # top-level変数へ保存した非safe scriptblockは、assignment後に変数として
    # 再参照された時点でrejectする。個別の実行構文をblacklist化せず、
    # 上のpositive proofを満たさないdeferred codeを一律fail closedにする。
    $riskyStoredScriptBlocks = @(
        $sourceAst.FindAll(
            {
                param($node)
                return (
                    $node -is
                        [System.Management.Automation.Language.ScriptBlockExpressionAst] -and
                    $node.Extent.StartOffset -lt
                        $rawOuterCommand.Extent.EndOffset
                )
            },
            $true
        ) |
            Where-Object {
                return -not (
                    & $testStoredScriptBlockIsExplicitlySafe $_
                )
            }
    )
    $riskyStoredVariableNames = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($scriptBlockOwner in $riskyStoredScriptBlocks) {
        $ancestor = $scriptBlockOwner.Parent
        $functionOwner = $null
        $typeOwner = $null
        while ($null -ne $ancestor) {
            if (
                $null -eq $functionOwner -and
                $ancestor -is
                    [System.Management.Automation.Language.FunctionDefinitionAst]
            ) {
                $functionOwner = $ancestor
            }
            if (
                $null -eq $typeOwner -and
                (
                    $ancestor -is
                        [System.Management.Automation.Language.FunctionMemberAst] -or
                    $ancestor -is
                    [System.Management.Automation.Language.TypeDefinitionAst]
                )
            ) {
                $typeOwner = $ancestor
            }
            $ancestor = $ancestor.Parent
        }
        if ($null -ne $functionOwner) {
            continue
        }
        if ($null -ne $typeOwner) {
            return $false
        }

        $assignmentOwner = $scriptBlockOwner.Parent
        while (
            $null -ne $assignmentOwner -and
            $assignmentOwner -isnot
                [System.Management.Automation.Language.AssignmentStatementAst]
        ) {
            $assignmentOwner = $assignmentOwner.Parent
        }
        if (
            $null -eq $assignmentOwner -or
            $assignmentOwner.Left -isnot
                [System.Management.Automation.Language.VariableExpressionAst]
        ) {
            return $false
        }
        $storedVariableName = $assignmentOwner.Left.VariablePath.UserPath
        [void]$riskyStoredVariableNames.Add(
            (& $normalizeVariableName $storedVariableName)
        )
        $earlyStoredReferences = @(
            $sourceAst.FindAll(
                {
                    param($node)
                    return (
                        $node -is
                            [System.Management.Automation.Language.VariableExpressionAst] -and
                        $node.VariablePath.UserPath -eq $storedVariableName -and
                        $node.Extent.StartOffset -ge
                            $assignmentOwner.Extent.EndOffset -and
                        $node.Extent.StartOffset -lt
                            $rawOuterCommand.Extent.EndOffset
                    )
                },
                $true
            )
        )
        if ($earlyStoredReferences.Count -gt 0) {
            return $false
        }
    }

    # literal Get-Variable lookupを許可するのは、raw fixtureより前に一度だけ
    # top-levelで直接代入された、明示safeなscriptblock名だけに限定する。
    # runtime生成、未束縛ambient、条件分岐内代入、再代入は証明不能として除外する。
    $preRawVariableAssignmentCounts = @{}
    $safeAssignmentCandidates =
        [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase
        )
    $safeAssignmentCandidateEndOffsets = @{}
    $preRawVariableAssignments = @(
        $sourceAst.FindAll(
            {
                param($node)
                return (
                    $node -is
                        [System.Management.Automation.Language.AssignmentStatementAst] -and
                    $node.Left -is
                        [System.Management.Automation.Language.VariableExpressionAst] -and
                    $node.Extent.EndOffset -le
                        $rawAssignments[0].Extent.StartOffset
                )
            },
            $true
        )
    )
    foreach ($variableAssignment in $preRawVariableAssignments) {
        $assignmentVariablePath =
            $variableAssignment.Left.VariablePath.UserPath
        # top-levelのunqualified/script scope代入だけが、direct lookupと
        # wrapperの`-Scope Script`の双方から同じ値として観測される。
        if (
            $assignmentVariablePath -match ':' -and
            $assignmentVariablePath -notmatch '^(?i:script):[^:]+$'
        ) {
            continue
        }
        $assignmentVariableName = & $normalizeVariableName (
            $assignmentVariablePath
        )
        if (-not $preRawVariableAssignmentCounts.ContainsKey(
            $assignmentVariableName
        )) {
            $preRawVariableAssignmentCounts[$assignmentVariableName] = 0
        }
        $preRawVariableAssignmentCounts[$assignmentVariableName]++

        $assignmentExpression = $null
        if (
            $variableAssignment.Parent -is
                [System.Management.Automation.Language.NamedBlockAst] -and
            $variableAssignment.Right -is
                [System.Management.Automation.Language.CommandExpressionAst]
        ) {
            $assignmentExpression = $variableAssignment.Right.Expression
        }
        if (
            $assignmentExpression -is
                [System.Management.Automation.Language.ScriptBlockExpressionAst] -and
            (& $testStoredScriptBlockIsExplicitlySafe $assignmentExpression)
        ) {
            [void]$safeAssignmentCandidates.Add($assignmentVariableName)
            $safeAssignmentCandidateEndOffsets[$assignmentVariableName] =
                $variableAssignment.Extent.EndOffset
        }
    }
    $safeStoredVariableNames =
        [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase
        )
    $safeStoredAssignmentEndOffsets = @{}
    foreach ($safeAssignmentCandidate in $safeAssignmentCandidates) {
        if (
            $preRawVariableAssignmentCounts[$safeAssignmentCandidate] -eq 1
        ) {
            [void]$safeStoredVariableNames.Add($safeAssignmentCandidate)
            $safeStoredAssignmentEndOffsets[$safeAssignmentCandidate] =
                $safeAssignmentCandidateEndOffsets[$safeAssignmentCandidate]
        }
    }

    # cmdlet/aliasやVariable: provider経由のmutationが同じ値を上書きし得る
    # sourceでは、単純代入だけからruntime値を証明できないためpositive setを
    # 無効化する。対象名やprovider pathがdynamicでもfail openにしない。
    $unprovenVariableMutations = @(
        $sourceAst.FindAll(
            {
                param($node)
                if (
                    $node.Extent.StartOffset -ge
                        $rawAssignments[0].Extent.StartOffset
                ) {
                    return $false
                }
                if (
                    $node -is
                        [System.Management.Automation.Language.InvokeMemberExpressionAst]
                ) {
                    return $true
                }
                if (
                    $node -isnot
                        [System.Management.Automation.Language.CommandAst]
                ) {
                    return $false
                }
                $mutationCommandName = & $normalizeFunctionName (
                    $node.GetCommandName()
                )
                if (
                    @(
                        'Set-Variable',
                        'New-Variable',
                        'Clear-Variable',
                        'Remove-Variable',
                        'sv',
                        'nv',
                        'clv',
                        'rv'
                    ) -contains $mutationCommandName
                ) {
                    return $true
                }
                return (
                    @(
                        'Set-Item',
                        'Set-Content',
                        'New-Item',
                        'Clear-Item',
                        'Remove-Item'
                    ) -contains $mutationCommandName -and
                    $node.Extent.Text -match '(?i)variable:'
                )
            },
            $true
        )
    )
    if ($unprovenVariableMutations.Count -gt 0) {
        $safeStoredVariableNames.Clear()
        $safeStoredAssignmentEndOffsets.Clear()
    }

    # Get-Variable/gvはVariableExpressionAstを作らず、保存scriptblockを値として
    # 再取得できる。target解析を1か所へ固定し、direct lookupと早期実行される
    # wrapper functionへ同じpositive-set判定を適用する。
    $testVariableLookupCanRecoverRiskyStoredBlock = {
        param(
            [System.Management.Automation.Language.CommandAst]$Command,
            [System.Collections.Generic.HashSet[string]]$SafeNames,
            [hashtable]$SafeAssignmentEndOffsets,
            [int]$ExecutionOffset = -1,
            [pscustomobject]$RequiredAssignmentEndOffset = $null
        )

        $lookupTargets = New-Object System.Collections.Generic.List[object]
        $lookupScopeTarget = $null
        $pendingLookupValue = ''
        $lookupPositionalIndex = 0
        for (
            $elementIndex = 1;
            $elementIndex -lt $Command.CommandElements.Count;
            $elementIndex++
        ) {
            $lookupElement = $Command.CommandElements[$elementIndex]
            if (
                $lookupElement -is
                    [System.Management.Automation.Language.CommandParameterAst]
            ) {
                $parameterName = $lookupElement.ParameterName
                $parameterOwnsName = $parameterName -eq 'Name'
                $parameterOwnsScope = $parameterName -eq 'Scope'
                $parameterIsSwitch = @(
                    'ValueOnly',
                    'Verbose',
                    'Debug',
                    'WhatIf',
                    'Confirm'
                ) -contains $parameterName
                $parameterConsumesValue = @(
                    'Name',
                    'Scope',
                    'ErrorAction',
                    'WarningAction',
                    'InformationAction',
                    'ProgressAction',
                    'ErrorVariable',
                    'WarningVariable',
                    'InformationVariable',
                    'OutVariable',
                    'OutBuffer',
                    'PipelineVariable'
                ) -contains $parameterName
                if ($null -ne $lookupElement.Argument) {
                    if ($parameterOwnsName) {
                        $lookupTargets.Add($lookupElement.Argument) | Out-Null
                    } elseif ($parameterOwnsScope) {
                        if ($null -ne $lookupScopeTarget) {
                            return $true
                        }
                        $lookupScopeTarget = $lookupElement.Argument
                    } elseif (
                        -not $parameterIsSwitch -and
                        -not $parameterConsumesValue
                    ) {
                        return $true
                    }
                    $pendingLookupValue = ''
                } elseif ($parameterOwnsName) {
                    $pendingLookupValue = 'name'
                } elseif ($parameterOwnsScope) {
                    $pendingLookupValue = 'scope'
                } elseif ($parameterConsumesValue) {
                    $pendingLookupValue = 'skip'
                } elseif ($parameterIsSwitch) {
                    $pendingLookupValue = ''
                } else {
                    return $true
                }
                continue
            }
            if ($pendingLookupValue -eq 'skip') {
                $pendingLookupValue = ''
                continue
            }
            if ($pendingLookupValue -eq 'name') {
                $lookupTargets.Add($lookupElement) | Out-Null
                $pendingLookupValue = ''
                continue
            }
            if ($pendingLookupValue -eq 'scope') {
                if ($null -ne $lookupScopeTarget) {
                    return $true
                }
                $lookupScopeTarget = $lookupElement
                $pendingLookupValue = ''
                continue
            }
            if ($lookupPositionalIndex -ne 0) {
                return $true
            }
            $lookupTargets.Add($lookupElement) | Out-Null
            $lookupPositionalIndex++
        }
        if (
            -not [string]::IsNullOrEmpty($pendingLookupValue) -or
            $lookupTargets.Count -eq 0
        ) {
            return $true
        }
        if ($null -ne $lookupScopeTarget) {
            if (
                $lookupScopeTarget -isnot
                    [System.Management.Automation.Language.StringConstantExpressionAst] -or
                [string]$lookupScopeTarget.Value -ne 'Script'
            ) {
                return $true
            }
        } else {
            $lookupAncestor = $Command.Parent
            while ($null -ne $lookupAncestor) {
                if (
                    $lookupAncestor -is
                        [System.Management.Automation.Language.FunctionDefinitionAst]
                ) {
                    return $true
                }
                $lookupAncestor = $lookupAncestor.Parent
            }
        }
        foreach ($lookupTarget in $lookupTargets) {
            if (
                $lookupTarget -isnot
                    [System.Management.Automation.Language.StringConstantExpressionAst]
            ) {
                return $true
            }
            $lookupName = & $normalizeVariableName (
                [string]$lookupTarget.Value
            )
            if (
                [System.Management.Automation.WildcardPattern]::
                    ContainsWildcardCharacters($lookupName) -or
                -not $SafeNames.Contains($lookupName)
            ) {
                return $true
            }
            $safeAssignmentEndOffset = [int](
                $SafeAssignmentEndOffsets[$lookupName]
            )
            if (
                $ExecutionOffset -ge 0 -and
                $safeAssignmentEndOffset -gt $ExecutionOffset
            ) {
                return $true
            }
            if (
                $null -ne $RequiredAssignmentEndOffset -and
                $safeAssignmentEndOffset -gt
                    [int]$RequiredAssignmentEndOffset.Value
            ) {
                $RequiredAssignmentEndOffset.Value =
                    $safeAssignmentEndOffset
            }
        }
        return $false
    }

    if ($earlyEagerCommands.Count -gt 0) {
        # builtin名だけでなく、raw fixtureより前にliteral定義されたaliasも
        # fixed pointで解決する。dynamic/ambiguous alias bindingは、lookup
        # identityを静的に証明できないためfail closedにする。
        $variableLookupCommandNames = (
            [System.Collections.Generic.HashSet[string]]::new(
                [System.StringComparer]::OrdinalIgnoreCase
            )
        )
        [void]$variableLookupCommandNames.Add('Get-Variable')
        [void]$variableLookupCommandNames.Add('gv')
        $literalAliasBindings = New-Object System.Collections.Generic.List[object]
        foreach ($earlyCommand in $earlyEagerCommands) {
            $earlyCommandName = & $normalizeFunctionName (
                $earlyCommand.GetCommandName()
            )
            if (
                @('Set-Alias', 'New-Alias', 'sal', 'nal') -notcontains
                    $earlyCommandName
            ) {
                continue
            }

            $aliasNameElement = $null
            $aliasTargetElement = $null
            $pendingAliasValue = ''
            for (
                $elementIndex = 1;
                $elementIndex -lt $earlyCommand.CommandElements.Count;
                $elementIndex++
            ) {
                $aliasElement = $earlyCommand.CommandElements[$elementIndex]
                if (
                    $aliasElement -is
                        [System.Management.Automation.Language.CommandParameterAst]
                ) {
                    $parameterName = $aliasElement.ParameterName
                    $parameterOwnsName = $parameterName -eq 'Name'
                    $parameterOwnsTarget = $parameterName -eq 'Value'
                    $parameterIsSwitch = @(
                        'Force',
                        'PassThru',
                        'Verbose',
                        'Debug',
                        'WhatIf',
                        'Confirm'
                    ) -contains $parameterName
                    $parameterConsumesValue = @(
                        'Name',
                        'Value',
                        'Description',
                        'Option',
                        'Scope',
                        'ErrorAction',
                        'WarningAction',
                        'InformationAction',
                        'ProgressAction',
                        'ErrorVariable',
                        'WarningVariable',
                        'InformationVariable',
                        'OutVariable',
                        'OutBuffer',
                        'PipelineVariable'
                    ) -contains $parameterName
                    if ($null -ne $aliasElement.Argument) {
                        if ($parameterOwnsName) {
                            if ($null -ne $aliasNameElement) {
                                return $false
                            }
                            $aliasNameElement = $aliasElement.Argument
                        } elseif ($parameterOwnsTarget) {
                            if ($null -ne $aliasTargetElement) {
                                return $false
                            }
                            $aliasTargetElement = $aliasElement.Argument
                        } elseif (
                            -not $parameterIsSwitch -and
                            -not $parameterConsumesValue
                        ) {
                            return $false
                        }
                        $pendingAliasValue = ''
                    } elseif ($parameterOwnsName) {
                        $pendingAliasValue = 'name'
                    } elseif ($parameterOwnsTarget) {
                        $pendingAliasValue = 'target'
                    } elseif ($parameterConsumesValue) {
                        $pendingAliasValue = 'skip'
                    } elseif ($parameterIsSwitch) {
                        $pendingAliasValue = ''
                    } else {
                        return $false
                    }
                    continue
                }
                if ($pendingAliasValue -eq 'skip') {
                    $pendingAliasValue = ''
                    continue
                }
                if ($pendingAliasValue -eq 'name') {
                    if ($null -ne $aliasNameElement) {
                        return $false
                    }
                    $aliasNameElement = $aliasElement
                    $pendingAliasValue = ''
                    continue
                }
                if ($pendingAliasValue -eq 'target') {
                    if ($null -ne $aliasTargetElement) {
                        return $false
                    }
                    $aliasTargetElement = $aliasElement
                    $pendingAliasValue = ''
                    continue
                }
                if ($null -eq $aliasNameElement) {
                    $aliasNameElement = $aliasElement
                } elseif ($null -eq $aliasTargetElement) {
                    $aliasTargetElement = $aliasElement
                } else {
                    return $false
                }
            }
            if (
                -not [string]::IsNullOrEmpty($pendingAliasValue) -or
                $aliasNameElement -isnot
                    [System.Management.Automation.Language.StringConstantExpressionAst] -or
                $aliasTargetElement -isnot
                    [System.Management.Automation.Language.StringConstantExpressionAst]
            ) {
                return $false
            }
            $literalAliasBindings.Add(
                [pscustomobject]@{
                    Name = & $normalizeFunctionName (
                        [string]$aliasNameElement.Value
                    )
                    Target = & $normalizeFunctionName (
                        [string]$aliasTargetElement.Value
                    )
                }
            ) | Out-Null
        }

        # Set-Alias/New-Alias自体へのliteral aliasは、次のcommandで新しい
        # lookup aliasを生成できる。二段目以降を推測せず、alias定義cmdletの
        # aliasが実行された時点でfail closedにする。
        $builtInAliasDefinitionCommandNames = (
            [System.Collections.Generic.HashSet[string]]::new(
                [System.StringComparer]::OrdinalIgnoreCase
            )
        )
        foreach (
            $aliasDefinitionCommandName in @(
                'Set-Alias',
                'New-Alias',
                'sal',
                'nal'
            )
        ) {
            [void]$builtInAliasDefinitionCommandNames.Add(
                $aliasDefinitionCommandName
            )
        }
        $aliasDefinitionCommandNames = (
            [System.Collections.Generic.HashSet[string]]::new(
                $builtInAliasDefinitionCommandNames,
                [System.StringComparer]::OrdinalIgnoreCase
            )
        )
        do {
            $aliasDefinitionGraphChanged = $false
            foreach ($aliasBinding in $literalAliasBindings) {
                if (
                    $aliasDefinitionCommandNames.Contains(
                        [string]$aliasBinding.Target
                    ) -and
                    $aliasDefinitionCommandNames.Add(
                        [string]$aliasBinding.Name
                    )
                ) {
                    $aliasDefinitionGraphChanged = $true
                }
            }
        } while ($aliasDefinitionGraphChanged)
        $aliasedAliasDefinitionCalls = @(
            $earlyEagerCommands |
                Where-Object {
                    $aliasDefinitionCommandName = & $normalizeFunctionName (
                        $_.GetCommandName()
                    )
                    return (
                        $aliasDefinitionCommandNames.Contains(
                            $aliasDefinitionCommandName
                        ) -and
                        -not $builtInAliasDefinitionCommandNames.Contains(
                            $aliasDefinitionCommandName
                        )
                    )
                }
        )
        if ($aliasedAliasDefinitionCalls.Count -gt 0) {
            return $false
        }

        do {
            $lookupAliasGraphChanged = $false
            foreach ($aliasBinding in $literalAliasBindings) {
                if (
                    $variableLookupCommandNames.Contains(
                        [string]$aliasBinding.Target
                    ) -and
                    $variableLookupCommandNames.Add(
                        [string]$aliasBinding.Name
                    )
                ) {
                    $lookupAliasGraphChanged = $true
                }
            }
        } while ($lookupAliasGraphChanged)

        # variable mutation cmdletを指すsource内aliasもfixed pointで解決する。
        # lookup実行前に呼ばれていれば、literal assignmentの値は保証できない。
        $variableMutationCommandNames = (
            [System.Collections.Generic.HashSet[string]]::new(
                [System.StringComparer]::OrdinalIgnoreCase
            )
        )
        foreach (
            $mutationCommandName in @(
                'Set-Variable',
                'New-Variable',
                'Clear-Variable',
                'Remove-Variable',
                'sv',
                'nv',
                'clv',
                'rv',
                'Set-Item',
                'Set-Content',
                'New-Item',
                'Clear-Item',
                'Remove-Item'
            )
        ) {
            [void]$variableMutationCommandNames.Add($mutationCommandName)
        }
        do {
            $mutationAliasGraphChanged = $false
            foreach ($aliasBinding in $literalAliasBindings) {
                if (
                    $variableMutationCommandNames.Contains(
                        [string]$aliasBinding.Target
                    ) -and
                    $variableMutationCommandNames.Add(
                        [string]$aliasBinding.Name
                    )
                ) {
                    $mutationAliasGraphChanged = $true
                }
            }
        } while ($mutationAliasGraphChanged)
        $resolvedVariableMutationCalls = @(
            $earlyEagerCommands |
                Where-Object {
                    $variableMutationCommandNames.Contains(
                        (& $normalizeFunctionName $_.GetCommandName())
                    )
                }
        )
        if ($resolvedVariableMutationCalls.Count -gt 0) {
            $safeStoredVariableNames.Clear()
            $safeStoredAssignmentEndOffsets.Clear()
        }

        $earlyVariableLookups = @(
            $earlyEagerCommands |
                Where-Object {
                    $variableLookupCommandNames.Contains(
                        (& $normalizeFunctionName $_.GetCommandName())
                    )
                }
        )
        foreach ($variableLookup in $earlyVariableLookups) {
            if (
                & $testVariableLookupCanRecoverRiskyStoredBlock `
                    -Command $variableLookup `
                    -SafeNames $safeStoredVariableNames `
                    -SafeAssignmentEndOffsets $safeStoredAssignmentEndOffsets `
                    -ExecutionOffset $variableLookup.Extent.StartOffset
            ) {
                return $false
            }
        }

        # lookupを含むfunctionは定義だけなら安全だが、raw fixtureより前の
        # direct/transitive callで実行される。既存function graphと同じ規則で
        # wrapper riskをfixed pointまで伝播する。
        $lookupRiskyFunctionNames = (
            [System.Collections.Generic.HashSet[string]]::new(
                [System.StringComparer]::OrdinalIgnoreCase
            )
        )
        $lookupRequiredAssignmentEndOffsets = @{}
        foreach ($functionDefinition in $functionDefinitions) {
            $normalizedLookupFunctionName = & $normalizeFunctionName (
                $functionDefinition.Name
            )
            $functionAliasDefinitionCommands = @(
                $functionDefinition.FindAll(
                    {
                        param($node)
                        return (
                            $node -is
                                [System.Management.Automation.Language.CommandAst] -and
                            $aliasDefinitionCommandNames.Contains(
                                (& $normalizeFunctionName $node.GetCommandName())
                            )
                        )
                    },
                    $true
                )
            )
            if ($functionAliasDefinitionCommands.Count -gt 0) {
                [void]$lookupRiskyFunctionNames.Add(
                    $normalizedLookupFunctionName
                )
                continue
            }
            $requiredAssignmentEndOffset = [pscustomobject]@{
                Value = 0
            }
            $functionVariableLookups = @(
                $functionDefinition.FindAll(
                    {
                        param($node)
                        return (
                            $node -is
                                [System.Management.Automation.Language.CommandAst] -and
                            $variableLookupCommandNames.Contains(
                                (& $normalizeFunctionName $node.GetCommandName())
                            )
                        )
                    },
                    $true
                )
            )
            foreach ($variableLookup in $functionVariableLookups) {
                if (
                    & $testVariableLookupCanRecoverRiskyStoredBlock `
                        -Command $variableLookup `
                        -SafeNames $safeStoredVariableNames `
                        -SafeAssignmentEndOffsets `
                            $safeStoredAssignmentEndOffsets `
                        -RequiredAssignmentEndOffset `
                            $requiredAssignmentEndOffset
                ) {
                    [void]$lookupRiskyFunctionNames.Add(
                        $normalizedLookupFunctionName
                    )
                    break
                }
            }
            if (
                -not $lookupRiskyFunctionNames.Contains(
                    $normalizedLookupFunctionName
                ) -and
                $requiredAssignmentEndOffset.Value -gt 0
            ) {
                $lookupRequiredAssignmentEndOffsets[
                    $normalizedLookupFunctionName
                ] = $requiredAssignmentEndOffset.Value
            }
        }
        do {
            $lookupRiskGraphChanged = $false
            foreach ($functionDefinition in $functionDefinitions) {
                $normalizedDefinitionName = (
                    & $normalizeFunctionName $functionDefinition.Name
                )
                if (
                    $lookupRiskyFunctionNames.Contains(
                        $normalizedDefinitionName
                    )
                ) {
                    continue
                }
                $containedCommands = @(
                    $functionDefinition.FindAll(
                        {
                            param($node)
                            return (
                                $node -is
                                    [System.Management.Automation.Language.CommandAst]
                            )
                        },
                        $true
                    )
                )
                foreach ($containedCommand in $containedCommands) {
                    $containedCommandName = & $normalizeFunctionName (
                        $containedCommand.GetCommandName()
                    )
                    $isUnresolvedCallOperator = (
                        [string]::IsNullOrEmpty($containedCommandName) -and
                        @('Ampersand', 'Dot') -contains
                            ([string]$containedCommand.InvocationOperator)
                    )
                    $isUnknownLookupWrapperCommand = (
                        $lookupRequiredAssignmentEndOffsets.ContainsKey(
                            $normalizedDefinitionName
                        ) -and
                        -not $variableLookupCommandNames.Contains(
                            $containedCommandName
                        ) -and
                        -not $lookupRequiredAssignmentEndOffsets.ContainsKey(
                            $containedCommandName
                        )
                    )
                    $isUnresolvedLookupWrapperCall = (
                        $isUnresolvedCallOperator -and
                        $lookupRequiredAssignmentEndOffsets.ContainsKey(
                            $normalizedDefinitionName
                        )
                    )
                    if (
                        $lookupRiskyFunctionNames.Contains(
                            $containedCommandName
                        ) -or
                        $isUnresolvedLookupWrapperCall -or
                        $isUnknownLookupWrapperCommand
                    ) {
                        if (
                            $lookupRiskyFunctionNames.Add(
                                $normalizedDefinitionName
                            )
                        ) {
                            $lookupRiskGraphChanged = $true
                        }
                        break
                    }
                    if (
                        $lookupRequiredAssignmentEndOffsets.ContainsKey(
                            $containedCommandName
                        )
                    ) {
                        $containedRequirement = [int](
                            $lookupRequiredAssignmentEndOffsets[
                                $containedCommandName
                            ]
                        )
                        $currentRequirement = 0
                        if (
                            $lookupRequiredAssignmentEndOffsets.ContainsKey(
                                $normalizedDefinitionName
                            )
                        ) {
                            $currentRequirement = [int](
                                $lookupRequiredAssignmentEndOffsets[
                                    $normalizedDefinitionName
                                ]
                            )
                        }
                        if ($containedRequirement -gt $currentRequirement) {
                            $lookupRequiredAssignmentEndOffsets[
                                $normalizedDefinitionName
                            ] = $containedRequirement
                            $lookupRiskGraphChanged = $true
                        }
                    }
                }
            }

            # alias が lookup-risky wrapper を指す場合も同じ固定点へ取り込み、
            # wrapper と alias を交互にたどる経路を早期実行判定から漏らさない。
            # safe wrapperも代入完了offsetをaliasへ伝播し、先行callを許可しない。
            foreach ($aliasBinding in $literalAliasBindings) {
                if (
                    $lookupRiskyFunctionNames.Contains(
                        [string]$aliasBinding.Target
                    ) -and
                    $lookupRiskyFunctionNames.Add(
                        [string]$aliasBinding.Name
                    )
                ) {
                    $lookupRiskGraphChanged = $true
                }
                if (
                    $lookupRequiredAssignmentEndOffsets.ContainsKey(
                        [string]$aliasBinding.Target
                    )
                ) {
                    $aliasRequirement = [int](
                        $lookupRequiredAssignmentEndOffsets[
                            [string]$aliasBinding.Target
                        ]
                    )
                    $currentAliasRequirement = 0
                    if (
                        $lookupRequiredAssignmentEndOffsets.ContainsKey(
                            [string]$aliasBinding.Name
                        )
                    ) {
                        $currentAliasRequirement = [int](
                            $lookupRequiredAssignmentEndOffsets[
                                [string]$aliasBinding.Name
                            ]
                        )
                    }
                    if ($aliasRequirement -gt $currentAliasRequirement) {
                        $lookupRequiredAssignmentEndOffsets[
                            [string]$aliasBinding.Name
                        ] = $aliasRequirement
                        $lookupRiskGraphChanged = $true
                    }
                }
            }
        } while ($lookupRiskGraphChanged)

        foreach ($earlyCommand in $earlyEagerCommands) {
            $earlyCommandName = & $normalizeFunctionName (
                $earlyCommand.GetCommandName()
            )
            if ($lookupRiskyFunctionNames.Contains($earlyCommandName)) {
                return $false
            }
            if (
                $lookupRequiredAssignmentEndOffsets.ContainsKey(
                    $earlyCommandName
                ) -and
                $earlyCommand.Extent.StartOffset -lt
                    [int]$lookupRequiredAssignmentEndOffsets[$earlyCommandName]
            ) {
                return $false
            }
        }
    }

    $eagerBoundedCalls = @(
        $allBoundedCalls |
            Where-Object {
                -not (
                    Test-PrivateMarkerCommandIsDeferredDefinition -Command $_
                )
            } |
            Sort-Object { $_.Extent.StartOffset }
    )
    return (
        $eagerBoundedCalls.Count -gt 0 -and
        $eagerBoundedCalls[0].Extent.StartOffset -eq
            $rawOuterCommand.Extent.StartOffset -and
        $eagerBoundedCalls[0].Extent.EndOffset -eq
            $rawOuterCommand.Extent.EndOffset
    )
}

function Assert-FirstBoundedInvocationValidatorRegressions {
    $cases = @(
        [pscustomobject]@{
            Name = 'direct-before'
            Expected = $false
            Source = @'
Invoke-PrivateMarkerBoundedProcess
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'shadow-target-function'
            Expected = $false
            Source = @'
function Invoke-PrivateMarkerBoundedProcess {
    return $null
}
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'retarget-target-alias'
            Expected = $false
            Source = @'
Set-Alias Invoke-PrivateMarkerBoundedProcess Get-Item
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'risk-sensitive-set-item-alias'
            Expected = $false
            Source = @'
Set-Alias mutate Set-Item
mutate Function:Invoke-PrivateMarkerBoundedProcess { Write-Output safe }
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'risk-sensitive-get-command-alias'
            Expected = $false
            Source = @'
function Invoke-Early {
    Invoke-PrivateMarkerBoundedProcess
}
Set-Alias resolve Get-Command
$stored = (resolve Invoke-Early).ScriptBlock
& $stored
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'risk-sensitive-new-object-alias'
            Expected = $false
            Source = @'
class EarlyClass {
    EarlyClass() {
        Invoke-PrivateMarkerBoundedProcess
    }
}
Set-Alias create New-Object
create EarlyClass
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'copy-item-invoke-expression-alias'
            Expected = $false
            Source = @'
Copy-Item Alias:iex Alias:runtext
runtext 'Invoke-PrivateMarkerBoundedProcess'
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'copy-item-get-variable-alias'
            Expected = $false
            Source = @'
Copy-Item Alias:gv Alias:readstored
$stored = { Invoke-PrivateMarkerBoundedProcess }
1 | ForEach-Object (readstored stored -ValueOnly)
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'copy-item-function-provider'
            Expected = $false
            Source = @'
function Invoke-Early {
    Invoke-PrivateMarkerBoundedProcess
}
Copy-Item Function:Invoke-Early Function:Invoke-Copied
Invoke-Copied
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'move-item-invoke-expression-alias'
            Expected = $false
            Source = @'
Move-Item Alias:iex Alias:runtext
runtext 'Invoke-PrivateMarkerBoundedProcess'
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'rename-item-invoke-expression-alias'
            Expected = $false
            Source = @'
Rename-Item Alias:iex runtext
runtext 'Invoke-PrivateMarkerBoundedProcess'
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'wrapper-copy-item-alias-provider'
            Expected = $false
            Source = @'
function Initialize-RunAlias {
    Copy-Item Alias:iex Alias:runtext
}
Initialize-RunAlias
runtext 'Invoke-PrivateMarkerBoundedProcess'
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'import-alias-before'
            Expected = $false
            Source = @'
Import-Alias '.\aliases.csv'
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'import-module-before'
            Expected = $false
            Source = @'
Import-Module '.\mutate.psm1'
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'import-module-alias-before'
            Expected = $false
            Source = @'
ipmo '.\mutate.psm1'
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'module-qualified-import-before'
            Expected = $false
            Source = @'
Microsoft.PowerShell.Core\Import-Module '.\mutate.psm1'
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'new-module-before'
            Expected = $false
            Source = @'
New-Module -ScriptBlock { Set-Alias Invoke-PrivateMarkerBoundedProcess Get-Item }
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'using-module-before'
            Expected = $false
            Source = @'
using module '.\mutate.psm1'
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'wrapper-import-module-before'
            Expected = $false
            Source = @'
function Import-UntrustedModule {
    Import-Module '.\mutate.psm1'
}
Import-UntrustedModule
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'class-import-module-before'
            Expected = $false
            Source = @'
class ModuleLoader {
    ModuleLoader() {
        Import-Module '.\mutate.psm1'
    }
}
[ModuleLoader]::new()
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'alias-to-import-module-before'
            Expected = $false
            Source = @'
Set-Alias loadmodule Import-Module
loadmodule '.\mutate.psm1'
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'remove-alias-target'
            Expected = $false
            Source = @'
Remove-Alias Invoke-PrivateMarkerBoundedProcess
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'remove-item-alias-target'
            Expected = $false
            Source = @'
ri Alias:Invoke-PrivateMarkerBoundedProcess
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'remove-item-function-target'
            Expected = $false
            Source = @'
Remove-Item Function:Invoke-PrivateMarkerBoundedProcess
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'wrapper-remove-item-function-target'
            Expected = $false
            Source = @'
function Remove-Runner {
    Remove-Item Function:Invoke-PrivateMarkerBoundedProcess
}
Remove-Runner
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'wrapper-dynamic-remove-item-function-target'
            Expected = $false
            Source = @'
function Remove-Runner {
    param([string]$Path)
    Remove-Item -LiteralPath $Path
}
Remove-Runner Function:Invoke-PrivateMarkerBoundedProcess
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'wrapper-fixed-env-remove-item'
            Expected = $true
            Source = @'
function Clear-TestEnvironment {
    Remove-Item -LiteralPath ('Env:\' + 'SAFE_TEST_VALUE')
}
Clear-TestEnvironment
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'dot-sourced-script-before'
            Expected = $false
            Source = @'
. '.\mutate.ps1'
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'call-script-before'
            Expected = $false
            Source = @'
& '.\mutate.ps1'
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'direct-script-before'
            Expected = $false
            Source = @'
.\mutate.ps1
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'wrapper-dynamic-script-before'
            Expected = $false
            Source = @'
function Invoke-ScriptPath {
    param([string]$ScriptPath)
    & $ScriptPath
}
$scriptPath = '.\mutate.ps1'
Invoke-ScriptPath $scriptPath
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'unused-dynamic-script-wrapper'
            Expected = $true
            Source = @'
function Invoke-ScriptPath {
    param([string]$ScriptPath)
    & $ScriptPath
}
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'bound-local-scriptblock-wrapper'
            Expected = $true
            Source = @'
function Invoke-LocalHelper {
    $localHelper = { param($Value) $Value }
    & $localHelper 'safe'
}
Invoke-LocalHelper
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'bound-local-scriptblock-provider-mutation'
            Expected = $false
            Source = @'
function Invoke-LocalHelper {
    $localHelper = {
        Set-Item Function:Invoke-PrivateMarkerBoundedProcess { 'shadow' }
    }
    & $localHelper
}
Invoke-LocalHelper
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'reassigned-local-scriptblock-wrapper'
            Expected = $false
            Source = @'
function Invoke-LocalHelper {
    $localHelper = { 'safe' }
    $localHelper = { Invoke-PrivateMarkerBoundedProcess }
    & $localHelper
}
Invoke-LocalHelper
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'set-item-alias-target'
            Expected = $false
            Source = @'
Set-Item -Path Alias:Invoke-PrivateMarkerBoundedProcess -Value Get-Item
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'set-item-function-target'
            Expected = $false
            Source = @'
Set-Item -Path Function:Invoke-PrivateMarkerBoundedProcess -Value { $null }
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'wrapper-set-item-function-target'
            Expected = $false
            Source = @'
function Set-RunnerShadow {
    Set-Item Function:Invoke-PrivateMarkerBoundedProcess { 'shadow' }
}
Set-RunnerShadow
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'class-set-item-function-target'
            Expected = $false
            Source = @'
class RunnerShadow {
    static [void] Install() {
        Set-Item Function:Invoke-PrivateMarkerBoundedProcess { 'shadow' }
    }
}
[RunnerShadow]::Install()
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'set-content-alias-function'
            Expected = $false
            Source = @'
function Invoke-Early {
    Invoke-PrivateMarkerBoundedProcess
}
Set-Content Alias:EarlyAlias Invoke-Early
EarlyAlias
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'new-item-dynamic-function-provider'
            Expected = $false
            Source = @'
$providerPath = 'Function:Invoke-PrivateMarkerBoundedProcess'
New-Item -Path $providerPath -ItemType Directory -Value { 'shadow' }
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'module-qualified-join-path-provider'
            Expected = $false
            Source = @'
$providerPath = Synthetic.Autoload\Join-Path $root 'fixture.txt'
Set-Content -LiteralPath $providerPath -Value 'safe'
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'function-before'
            Expected = $true
            Source = @'
function Invoke-Deferred {
    Invoke-PrivateMarkerBoundedProcess
}
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'invoked-function-before'
            Expected = $false
            Source = @'
function Invoke-Early {
    Invoke-PrivateMarkerBoundedProcess
}
Invoke-Early
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'scope-qualified-function-before'
            Expected = $false
            Source = @'
function Invoke-Early {
    Invoke-PrivateMarkerBoundedProcess
}
global:Invoke-Early
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'alias-function-before'
            Expected = $false
            Source = @'
function Invoke-Early {
    Invoke-PrivateMarkerBoundedProcess
}
Set-Alias EarlyAlias Invoke-Early
EarlyAlias
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'get-command-function-before'
            Expected = $false
            Source = @'
function Invoke-Early {
    Invoke-PrivateMarkerBoundedProcess
}
(Get-Command Invoke-Early).ScriptBlock.Invoke()
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'builtin-gcm-wrapper'
            Expected = $false
            Source = @'
function Invoke-Early {
    Invoke-PrivateMarkerBoundedProcess
}
(gcm Invoke-Early).ScriptBlock.Invoke()
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'module-qualified-get-command'
            Expected = $false
            Source = @'
function Invoke-Early {
    Invoke-PrivateMarkerBoundedProcess
}
(Microsoft.PowerShell.Core\Get-Command Invoke-Early).ScriptBlock.Invoke()
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'get-item-function-before'
            Expected = $false
            Source = @'
function Invoke-Early {
    Invoke-PrivateMarkerBoundedProcess
}
(Get-Item function:Invoke-Early).ScriptBlock.Invoke()
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'dynamic-get-command-function-before'
            Expected = $false
            Source = @'
function Invoke-Early {
    Invoke-PrivateMarkerBoundedProcess
}
$functionName = 'Invoke-Early'
(Get-Command $functionName).ScriptBlock.Invoke()
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'safe-get-command-application'
            Expected = $true
            Source = @'
function Invoke-Deferred {
    Invoke-PrivateMarkerBoundedProcess
}
Get-Command git -CommandType Application
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'stored-scriptblock-get-variable-foreach'
            Expected = $false
            Source = @'
function Invoke-Early {
    Invoke-PrivateMarkerBoundedProcess
}
$stored = { Invoke-Early }
ForEach-Object -InputObject 1 -Process (Get-Variable stored).Value
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'stored-scriptblock-gv-value-only'
            Expected = $false
            Source = @'
$stored = { Invoke-PrivateMarkerBoundedProcess }
1 | ForEach-Object (gv stored -ValueOnly)
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'stored-scriptblock-dynamic-get-variable'
            Expected = $false
            Source = @'
$stored = { Invoke-PrivateMarkerBoundedProcess }
$lookupName = 'stored'
1 | Where-Object (Get-Variable -Name $lookupName -ValueOnly)
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'unbound-literal-get-variable'
            Expected = $false
            Source = @'
1 | ForEach-Object (Get-Variable ambientStored -ValueOnly)
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'runtime-created-scriptblock-get-variable'
            Expected = $false
            Source = @'
$generated = [scriptblock]::Create('Invoke-PrivateMarkerBoundedProcess')
1 | ForEach-Object (Get-Variable generated -ValueOnly)
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'reassigned-runtime-scriptblock-get-variable'
            Expected = $false
            Source = @'
$safeStored = { $_ }
$safeStored = [scriptblock]::Create('Invoke-PrivateMarkerBoundedProcess')
1 | ForEach-Object (Get-Variable safeStored -ValueOnly)
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'compound-assignment-get-variable'
            Expected = $false
            Source = @'
$safeStored = { $_ }
$safeStored += { $_ }
1 | ForEach-Object (Get-Variable safeStored -ValueOnly)
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'alias-variable-mutation-get-variable'
            Expected = $false
            Source = @'
Set-Alias mutate Set-Variable
$safeStored = { $_ }
mutate -Name safeStored -Scope Script -Value ([scriptblock]::Create(
    'Invoke-PrivateMarkerBoundedProcess'
))
1 | ForEach-Object (Get-Variable safeStored -ValueOnly)
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'member-variable-mutation-get-variable'
            Expected = $false
            Source = @'
$safeStored = { $_ }
$ExecutionContext.SessionState.PSVariable.Set(
    'safeStored',
    [scriptblock]::Create('Invoke-PrivateMarkerBoundedProcess')
)
1 | ForEach-Object (Get-Variable safeStored -ValueOnly)
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'stored-scriptblock-invoke-expression-get-variable'
            Expected = $false
            Source = @'
$stored = { Invoke-Expression 'Invoke-PrivateMarkerBoundedProcess' }
1 | ForEach-Object (Get-Variable stored -ValueOnly)
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'stored-scriptblock-iex-get-variable'
            Expected = $false
            Source = @'
$stored = { iex 'Invoke-PrivateMarkerBoundedProcess' }
1 | ForEach-Object (Get-Variable stored -ValueOnly)
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'stored-scriptblock-unresolved-call-get-variable'
            Expected = $false
            Source = @'
$commandName = 'Invoke-PrivateMarkerBoundedProcess'
$stored = { & $commandName }
1 | ForEach-Object (Get-Variable stored -ValueOnly)
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'stored-scriptblock-unbound-command-get-variable'
            Expected = $false
            Source = @'
$stored = { Invoke-AmbientCommand }
1 | ForEach-Object (Get-Variable stored -ValueOnly)
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'stored-scriptblock-wildcard-get-variable'
            Expected = $false
            Source = @'
$safeStored = { $_ }
1 | ForEach-Object (Get-Variable 'safe*' -ValueOnly)
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'stored-scriptblock-name-omitted-get-variable'
            Expected = $false
            Source = @'
$safeStored = { $_ }
1 | ForEach-Object (Get-Variable -ValueOnly)
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'stored-scriptblock-get-variable-wrapper'
            Expected = $false
            Source = @'
function Invoke-Stored {
    (Get-Variable -Name stored -Scope Script -ValueOnly).Invoke()
}
$stored = { Invoke-PrivateMarkerBoundedProcess }
Invoke-Stored
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'stored-scriptblock-get-variable-alias'
            Expected = $false
            Source = @'
Set-Alias readstored Get-Variable
$stored = { Invoke-PrivateMarkerBoundedProcess }
1 | ForEach-Object (readstored stored -ValueOnly)
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'alias-of-set-alias-get-variable'
            Expected = $false
            Source = @'
Set-Alias makealias Set-Alias
makealias readstored Get-Variable
$stored = { Invoke-PrivateMarkerBoundedProcess }
1 | ForEach-Object (readstored stored -ValueOnly)
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'wrapper-set-alias-get-variable'
            Expected = $false
            Source = @'
function Initialize-LookupAlias {
    Set-Alias readstored Get-Variable -Scope Script
}
Initialize-LookupAlias
$stored = { Invoke-PrivateMarkerBoundedProcess }
1 | ForEach-Object (readstored stored -ValueOnly)
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'stored-scriptblock-get-variable-transitive-alias'
            Expected = $false
            Source = @'
Set-Alias readstored Get-Variable
Set-Alias readstoredagain readstored
$stored = { Invoke-PrivateMarkerBoundedProcess }
1 | ForEach-Object (readstoredagain stored -ValueOnly)
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'stored-scriptblock-get-variable-wrapper-alias'
            Expected = $false
            Source = @'
function Get-Stored {
    (Get-Variable -Name stored -Scope Script -ValueOnly).Invoke()
}
Set-Alias readstored Get-Stored
$stored = { Invoke-PrivateMarkerBoundedProcess }
readstored
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'safe-get-variable-wrapper-alias'
            Expected = $true
            Source = @'
function Get-SafeStored {
    Get-Variable -Name safeStored -Scope Script -ValueOnly
}
Set-Alias readsafe Get-SafeStored
$stored = { Invoke-PrivateMarkerBoundedProcess }
$safeStored = { $_ }
readsafe
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'safe-get-variable-wrapper-alias-before-assignment'
            Expected = $false
            Source = @'
function Get-SafeStored {
    Get-Variable -Name safeStored -Scope Script -ValueOnly
}
Set-Alias readsafe Get-SafeStored
readsafe
$safeStored = { $_ }
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'safe-get-variable-wrapper-unknown-command'
            Expected = $false
            Source = @'
function Get-SafeStored {
    Get-Variable -Name safeStored -Scope Script -ValueOnly
    Invoke-AmbientCommand
}
$safeStored = { $_ }
Get-SafeStored
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'safe-get-variable-wrapper-dynamic-call'
            Expected = $false
            Source = @'
function Get-SafeStored {
    Get-Variable -Name safeStored -Scope Script -ValueOnly
    & $commandName
}
$safeStored = { $_ }
$commandName = 'Invoke-PrivateMarkerBoundedProcess'
Get-SafeStored
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'safe-get-variable-alias-target'
            Expected = $true
            Source = @'
Set-Alias readstored Write-Output
$stored = { Invoke-PrivateMarkerBoundedProcess }
readstored safe
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'shadowed-get-variable-command'
            Expected = $false
            Source = @'
function Get-Variable {
    param([string]$Name)
    return $Name
}
$stored = { Invoke-PrivateMarkerBoundedProcess }
Get-Variable stored
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'unused-get-variable-wrapper'
            Expected = $true
            Source = @'
function Get-Stored {
    Get-Variable -Name stored -Scope Script -ValueOnly
}
$stored = { Invoke-PrivateMarkerBoundedProcess }
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'safe-stored-scriptblock-get-variable'
            Expected = $true
            Source = @'
function Invoke-Deferred {
    Invoke-PrivateMarkerBoundedProcess
}
$stored = { Invoke-Deferred }
$safeStored = { $_ }
1 | ForEach-Object (Get-Variable safeStored -ValueOnly)
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'global-safe-assignment-get-variable'
            Expected = $false
            Source = @'
$global:safeStored = { $_ }
Get-Variable safeStored -Scope Script -ValueOnly
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'script-scoped-safe-assignment-get-variable'
            Expected = $true
            Source = @'
$script:safeStored = { $_ }
Get-Variable safeStored -Scope Script -ValueOnly
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'parameter-global-safe-assignment-get-variable'
            Expected = $false
            Source = @'
param($safeStored)
$global:safeStored = { $_ }
Get-Variable safeStored -ValueOnly
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'qualified-current-item-scriptblock-get-variable'
            Expected = $false
            Source = @'
$safeStored = { $global:_ }
Get-Variable safeStored -ValueOnly
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'transitive-function-before'
            Expected = $false
            Source = @'
function Invoke-Inner {
    Invoke-PrivateMarkerBoundedProcess
}
function Invoke-Outer {
    Invoke-Inner
}
Invoke-Outer
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'dynamic-function-call-operator'
            Expected = $false
            Source = @'
function Invoke-Early {
    Invoke-PrivateMarkerBoundedProcess
}
$functionName = 'Invoke-Early'
& $functionName
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'bootstrap-variable-overwrite'
            Expected = $false
            Source = @'
$processBoundary = './trusted.ps1'
Set-Variable processBoundary ./synthetic.ps1
. $processBoundary
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'bootstrap-scope-wrapper-overwrite'
            Expected = $false
            Source = @'
$processBoundary = './trusted.ps1'
function Set-Boundary {
    Set-Variable -Scope 1 processBoundary ./synthetic.ps1
}
Set-Boundary
. $processBoundary
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'function-scriptblock-member'
            Expected = $false
            Source = @'
function Invoke-Early {
    Invoke-PrivateMarkerBoundedProcess
}
${function:Invoke-Early}.Invoke()
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'invoke-command-function-ref'
            Expected = $false
            Source = @'
function Invoke-Early {
    Invoke-PrivateMarkerBoundedProcess
}
Invoke-Command -ScriptBlock ${function:Invoke-Early}
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'foreach-function-ref'
            Expected = $false
            Source = @'
function Invoke-Early {
    Invoke-PrivateMarkerBoundedProcess
}
1 | ForEach-Object ${function:Invoke-Early}
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'class-constructor-before'
            Expected = $false
            Source = @'
class EarlyClass {
    EarlyClass() {
        Invoke-PrivateMarkerBoundedProcess
    }
}
[EarlyClass]::new()
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'derived-class-base-constructor-before'
            Expected = $false
            Source = @'
class RiskyBase {
    RiskyBase() {
        Invoke-PrivateMarkerBoundedProcess
    }
}
class DerivedClass : RiskyBase {
}
[DerivedClass]::new()
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'transitive-derived-base-constructor-before'
            Expected = $false
            Source = @'
class RiskyBase {
    RiskyBase() {
        Invoke-PrivateMarkerBoundedProcess
    }
}
class MiddleClass : RiskyBase {
}
class DerivedClass : MiddleClass {
}
[DerivedClass]::new()
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'safe-derived-base-constructor-before'
            Expected = $true
            Source = @'
class SafeBase {
    SafeBase() {
    }
}
class SafeDerived : SafeBase {
}
[SafeDerived]::new()
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'class-method-before'
            Expected = $false
            Source = @'
class EarlyClass {
    [void] Invoke() {
        Invoke-PrivateMarkerBoundedProcess
    }
}
[EarlyClass]::new().Invoke()
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'class-as-conversion-before'
            Expected = $false
            Source = @'
class EarlyClass {
    EarlyClass() {
        Invoke-PrivateMarkerBoundedProcess
    }
}
$instance = @{} -as [EarlyClass]
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'class-static-instance-before'
            Expected = $false
            Source = @'
class EarlyClass {
    EarlyClass() {
        Invoke-PrivateMarkerBoundedProcess
    }
    static [EarlyClass] $Instance = [EarlyClass]::new()
    [void] Run() {
    }
}
$instance = [EarlyClass]::Instance
$instance.Run()
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'invoke-expression-helper'
            Expected = $false
            Source = @'
Invoke-Expression 'Invoke-PrivateMarkerBoundedProcess'
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'invoke-expression-alias-helper'
            Expected = $false
            Source = @'
Set-Alias runtext Invoke-Expression
runtext 'Invoke-PrivateMarkerBoundedProcess'
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'function-inside-raw-argument'
            Expected = $false
            Source = @'
function Invoke-Early {
    Invoke-PrivateMarkerBoundedProcess
}
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess -Value $(Invoke-Early)
'@
        },
        [pscustomobject]@{
            Name = 'uninvoked-scriptblock'
            Expected = $true
            Source = @'
$unused = { Invoke-PrivateMarkerBoundedProcess }
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'stored-scriptblock-invoke'
            Expected = $false
            Source = @'
$stored = { Invoke-PrivateMarkerBoundedProcess }
$stored.Invoke()
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'stored-scriptblock-return-as-is'
            Expected = $false
            Source = @'
$stored = { Invoke-PrivateMarkerBoundedProcess }
$stored.InvokeReturnAsIs()
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'stored-scriptblock-call-operator'
            Expected = $false
            Source = @'
$stored = { Invoke-PrivateMarkerBoundedProcess }
& $stored
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'stored-scriptblock-dot-operator'
            Expected = $false
            Source = @'
$stored = { Invoke-PrivateMarkerBoundedProcess }
. $stored
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'stored-scriptblock-foreach-argument'
            Expected = $false
            Source = @'
$stored = { Invoke-PrivateMarkerBoundedProcess }
1 | ForEach-Object $stored
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'stored-scriptblock-where-argument'
            Expected = $false
            Source = @'
$stored = { Invoke-PrivateMarkerBoundedProcess }
1 | Where-Object $stored
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'unknown-invoke-composite-receiver'
            Expected = $false
            Source = @'
Set-Variable -Name x -Value { Invoke-PrivateMarkerBoundedProcess }
(Write-Output (Get-Variable x -ValueOnly) -Verbose:$safe).Invoke()
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'stored-scriptblock-inside-raw-argument'
            Expected = $false
            Source = @'
$stored = { Invoke-PrivateMarkerBoundedProcess }
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess -Value $stored.Invoke()
'@
        },
        [pscustomobject]@{
            Name = 'stored-risky-function-invoke'
            Expected = $false
            Source = @'
function Invoke-Early {
    Invoke-PrivateMarkerBoundedProcess
}
$stored = { Invoke-Early }
$stored.Invoke()
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'nested-inner'
            Expected = $false
            Source = @'
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess -Value $(Invoke-PrivateMarkerBoundedProcess)
'@
        },
        [pscustomobject]@{
            Name = 'invoked-scriptblock-member'
            Expected = $false
            Source = @'
({ Invoke-PrivateMarkerBoundedProcess }).Invoke()
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'invoked-scriptblock-return-as-is'
            Expected = $false
            Source = @'
({ Invoke-PrivateMarkerBoundedProcess }).InvokeReturnAsIs()
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        }
    )
    foreach ($case in $cases) {
        $actual = Test-FirstBoundedInvocationIsRawTransport `
            -Source $case.Source
        if ($actual -ne $case.Expected) {
            Add-Failure "First-invocation validator regression failed: $($case.Name)."
        }
    }
}

function Assert-FirstBoundedInvocationIsRawTransport {
    # 実 self-test 全体を helper 実行前に parse し、synthetic regression と
    # 同じ pure validator で最初の eager call を固定する。
    $source = [System.IO.File]::ReadAllText($selfTest)
    if (-not (Test-FirstBoundedInvocationIsRawTransport -Source $source)) {
        Add-Failure 'Expected raw binary transport to be the first executable bounded helper invocation.'
    }
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
        [System.Diagnostics.Stopwatch]$OperationStopwatch,
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
    $failure = ''

    try {
        while ($true) {
            $remaining = (
                $TimeoutMilliseconds -
                [int]$OperationStopwatch.ElapsedMilliseconds
            )
            if ($remaining -le 0) {
                $failure = "Child process timed out after $TimeoutMilliseconds ms."
                break
            }
            if ($stdoutDone -and $stderrDone -and $Process.HasExited) {
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
            # operation budgetをcleanupへ流用しない。以後は独立した
            # KillWaitMillisecondsだけでtree停止とpipe drainをboundedに行う。
            $OperationStopwatch.Stop()
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

    # Process.Start自体の遅延もoperation timeoutへ含める。cleanupはfinallyで
    # stopwatchを止めた後、独立したKillWaitMillisecondsを使用する。
    $operationStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    $started = $false
    try {
        [void]$process.Start()
        $started = $true
        $streamResult = Read-BoundedProcessStreams `
            -Process $process `
            -OperationStopwatch $operationStopwatch `
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
        $operationStopwatch.Stop()
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

function New-RunnerTestEnvironment {
    $comparer = if ($isWindowsPlatform) {
        [System.StringComparer]::OrdinalIgnoreCase
    } else {
        [System.StringComparer]::Ordinal
    }
    $environment = [System.Collections.Generic.Dictionary[string,string]]::new(
        $comparer
    )
    foreach (
        $entry in [Environment]::GetEnvironmentVariables('Process').GetEnumerator()
    ) {
        $environment[[string]$entry.Key] = [string]$entry.Value
    }
    return $environment
}

function New-TestGitEnvironment {
    $environment = New-RunnerTestEnvironment
    foreach ($name in @(
        $environment.Keys |
            Where-Object { $_ -match '^GIT_' }
    )) {
        [void]$environment.Remove([string]$name)
    }
    $environment['GIT_CONFIG_NOSYSTEM'] = '1'
    $environment['GIT_ATTR_NOSYSTEM'] = '1'
    $environment['GIT_CONFIG_GLOBAL'] = $script:testGitEmptyConfig
    $environment['GIT_CONFIG_SYSTEM'] = $script:testGitEmptyConfig
    $environment['GIT_TERMINAL_PROMPT'] = '0'
    $environment['GIT_OPTIONAL_LOCKS'] = '0'
    $environment['GIT_NO_LAZY_FETCH'] = '1'
    $environment['GIT_NO_REPLACE_OBJECTS'] = '1'
    $environment['GIT_PROTOCOL_FROM_USER'] = '0'
    return $environment
}

function Get-TestGitArguments {
    param(
        [string]$WorkingDirectory,
        [string[]]$Arguments
    )

    # fixture Git は scanner と同じく外部 config、hook、credential、
    # protocol を遮断し、ローカル synthetic object だけを扱う。
    return @(
        '--no-pager',
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
}

function Invoke-Scanner {
    param(
        [string]$ScanPath,
        [System.Collections.IDictionary]$EnvironmentOverrides = $null,
        [string[]]$AdditionalArguments = @(),
        [string]$ScannerPath = $scanner
    )

    $arguments = Get-PowerShellArguments -AdditionalArguments (
        @('-File', $ScannerPath, '-Path', $ScanPath) +
        $AdditionalArguments
    )
    return Invoke-BoundedProcess `
        -FilePath $powerShellPath `
        -Arguments $arguments `
        -WorkingDirectory $root `
        -EnvironmentOverrides $EnvironmentOverrides `
        -TimeoutMilliseconds 120000
}

function Assert-FixedScannerBoundaryFailure {
    param(
        [object]$Result,
        [string]$ExpectedCode,
        [string[]]$ForbiddenPaths,
        [string]$CaseName
    )

    $expectedOutput = (
        "Private marker scan failed: $ExpectedCode" +
        [Environment]::NewLine
    )
    if (
        $Result.ExitCode -ne 2 -or
        $Result.StandardOutput -cne $expectedOutput -or
        -not [string]::IsNullOrEmpty($Result.StandardError)
    ) {
        Add-Failure (
            "Expected $CaseName to return one fixed stdout line, empty stderr, " +
            "and exit 2 (exit=$($Result.ExitCode), " +
            "stdoutExact=$($Result.StandardOutput -ceq $expectedOutput), " +
            "stdoutChars=$($Result.StandardOutput.Length), " +
            "stderrChars=$($Result.StandardError.Length))."
        )
        return
    }

    $comparison = if ($isWindowsPlatform) {
        [System.StringComparison]::OrdinalIgnoreCase
    } else {
        [System.StringComparison]::Ordinal
    }
    $combinedOutput = $Result.StandardOutput + $Result.StandardError
    foreach ($forbiddenPath in $ForbiddenPaths) {
        if (
            -not [string]::IsNullOrEmpty($forbiddenPath) -and
            $combinedOutput.IndexOf($forbiddenPath, $comparison) -ge 0
        ) {
            Add-Failure "Expected $CaseName to redact repository, helper, and temporary paths."
            return
        }
    }
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

function Get-EnvironmentVariableState {
    param([string]$Name)

    $environment = [Environment]::GetEnvironmentVariables('Process')
    $comparison = if ($isWindowsPlatform) {
        [System.StringComparison]::OrdinalIgnoreCase
    } else {
        [System.StringComparison]::Ordinal
    }
    $matchingEntry = $null
    foreach ($entry in $environment.GetEnumerator()) {
        if (
            [string]::Equals(
                [string]$entry.Key,
                $Name,
                $comparison
            )
        ) {
            $matchingEntry = $entry
            break
        }
    }
    $exists = $null -ne $matchingEntry
    return [pscustomobject]@{
        Exists = $exists
        Name = if ($exists) { [string]$matchingEntry.Key } else { $Name }
        Value = if ($exists) { [string]$matchingEntry.Value } else { $null }
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

function Assert-ProductionChildEnvironmentAllowlist {
    # 親に存在し得るcredential値は読まず、exact key setで非継承を証明する。
    # 未知変数だけをsyntheticに追加し、旧ambient cloneへ戻る回帰も検出する。
    $syntheticName = 'SYNTHETIC_UNKNOWN_NON_GIT_AMBIENT'
    $syntheticBefore = Get-EnvironmentVariableState -Name $syntheticName
    $forbiddenNames = @(
        'PATH',
        'ComSpec',
        'PATHEXT',
        'WINDIR',
        'TEMP',
        'TMP',
        'TMPDIR',
        'HOME',
        'USERPROFILE',
        'APPDATA',
        'LOCALAPPDATA',
        'PSModulePath',
        'XDG_CONFIG_HOME',
        'TZ',
        'LD_PRELOAD',
        'LD_LIBRARY_PATH',
        'DYLD_INSERT_LIBRARIES',
        'DOTNET_STARTUP_HOOKS',
        'CORECLR_ENABLE_PROFILING',
        'CORECLR_PROFILER_PATH',
        'COR_ENABLE_PROFILING',
        'COR_PROFILER_PATH',
        'AWS_SECRET_ACCESS_KEY',
        'GITHUB_TOKEN',
        'SSH_AUTH_SOCK'
    )

    try {
        [Environment]::SetEnvironmentVariable(
            $syntheticName,
            'synthetic-blocked-value',
            'Process'
        )

        $childEnvironment = New-PrivateMarkerChildEnvironment
        $comparer = if ($isWindowsPlatform) {
            [System.StringComparer]::OrdinalIgnoreCase
        } else {
            [System.StringComparer]::Ordinal
        }
        $allowedNames = [System.Collections.Generic.HashSet[string]]::new(
            $comparer
        )
        if ($isWindowsPlatform) {
            [void]$allowedNames.Add('SystemRoot')
        }

        foreach ($name in $childEnvironment.Keys) {
            if (-not $allowedNames.Contains([string]$name)) {
                Add-Failure (
                    'Production child environment admitted a non-allowlisted ' +
                    'variable name.'
                )
                break
            }
        }
        if ($childEnvironment.ContainsKey($syntheticName)) {
            Add-Failure (
                'Production child environment retained an unknown ambient ' +
                'variable.'
            )
        }
        foreach ($name in $forbiddenNames) {
            if ($childEnvironment.ContainsKey($name)) {
                Add-Failure (
                    'Production child environment retained a loader, ' +
                    'credential, or runtime convenience variable.'
                )
                break
            }
        }
        if (
            $childEnvironment.Count -ne $allowedNames.Count
        ) {
            Add-Failure (
                'Production child environment did not use its exact minimal ' +
                'allowlist.'
            )
        }
        if ($isWindowsPlatform) {
            $expectedRoot = [System.IO.Directory]::GetParent(
                [Environment]::SystemDirectory
            ).FullName
            if (
                -not $childEnvironment.ContainsKey('SystemRoot') -or
                [string]$childEnvironment['SystemRoot'] -cne $expectedRoot
            ) {
                Add-Failure (
                    'Production child environment did not derive SystemRoot ' +
                    'from the OS runtime.'
                )
            }
        }
    }
    finally {
        if ($syntheticBefore.Exists) {
            [Environment]::SetEnvironmentVariable(
                $syntheticBefore.Name,
                $syntheticBefore.Value,
                'Process'
            )
        } else {
            # .NET/Windowsの組合せによってnull代入がpresent-emptyを残す。
            # Env: providerから固定名を削除し、元のabsent状態を復元する。
            Remove-Item `
                -LiteralPath ('Env:\' + $syntheticName) `
                -Force `
                -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-TestGit {
    param(
        [string]$WorkingDirectory,
        [string[]]$Arguments
    )

    $environmentOverrides = New-TestGitEnvironment
    $safeArguments = Get-TestGitArguments `
        -WorkingDirectory $WorkingDirectory `
        -Arguments $Arguments

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
$windowsHandleProbeEvidence = ''
$posixFdProbeEvidence = ''

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

    Assert-ProductionChildEnvironmentAllowlist
    Assert-FirstBoundedInvocationValidatorRegressions
    Assert-FirstBoundedInvocationIsRawTransport

    # これは top-level で最初の production helper invocation のまま保つ。
    # 3-byte read、分割 stderr write、EOF、nonzero exit を通し、Windows の
    # suspended CreateProcessW + Job 境界でも text framing が入らないと示す。
    $rawTransportScript = Join-Path $tempRoot 'raw-transport-child.ps1'
    [System.IO.File]::WriteAllText(
        $rawTransportScript,
        @'
$inputStream = [Console]::OpenStandardInput()
$outputStream = [Console]::OpenStandardOutput()
$errorStream = [Console]::OpenStandardError()
$readBuffer = New-Object byte[] 3
while (($count = $inputStream.Read($readBuffer, 0, $readBuffer.Length)) -gt 0) {
    $outputStream.Write($readBuffer, 0, $count)
    $outputStream.Flush()
}
$errorBytes = [byte[]](0xFF, 0xFE, 0x80, 0x7F, 0x0D, 0x0A, 0x01, 0x00)
$errorStream.Write($errorBytes, 0, 3)
$errorStream.Flush()
$errorStream.Write($errorBytes, 3, $errorBytes.Length - 3)
$errorStream.Flush()
exit 37
'@,
        $utf8NoBom
    )
    $rawTransportInput = [byte[]](
        0x00, 0x80, 0xFF, 0x01, 0x0A, 0x0D,
        0x7F, 0xFE, 0x02, 0x81, 0xFD, 0x03
    )
    $rawTransportResult = Invoke-PrivateMarkerBoundedProcess `
        -FilePath $powerShellPath `
        -Arguments (
            Get-PowerShellArguments -AdditionalArguments @(
                '-File', $rawTransportScript
            )
        ) `
        -WorkingDirectory $root `
        -EnvironmentVariables (New-RunnerTestEnvironment) `
        -StandardInput $rawTransportInput `
        -TimeoutMilliseconds 10000 `
        -MaxStandardOutputBytes 64KB `
        -MaxStandardErrorBytes 64KB
    $expectedRawTransportError = [byte[]](
        0xFF, 0xFE, 0x80, 0x7F, 0x0D, 0x0A, 0x01, 0x00
    )
    if (
        $rawTransportResult.ExitCode -ne 37 -or
        [Convert]::ToBase64String(
            $rawTransportResult.StandardOutputBytes
        ) -cne [Convert]::ToBase64String($rawTransportInput) -or
        [Convert]::ToBase64String(
            $rawTransportResult.StandardErrorBytes
        ) -cne [Convert]::ToBase64String($expectedRawTransportError)
    ) {
        Add-Failure 'Expected the containment gate to preserve binary stdin/stdout/stderr, EOF, and exit code exactly.'
    }

    # environment構築を意図的に遅らせ、operation deadlineがProcess.Startより
    # 前に確立・検査されることを実動で固定する。deadline超過時はsentinel
    # childを一度も起動せず、cleanup用kill waitとは独立して返る必要がある。
    $delayedEnvironmentTypeName = (
        'MultiAgentDelegation.Tests.DelayedEnvironmentDictionary'
    )
    if ($null -eq ($delayedEnvironmentTypeName -as [type])) {
        Add-Type -TypeDefinition @'
using System.Collections;
using System.Threading;

namespace MultiAgentDelegation.Tests
{
    public sealed class DelayedEnvironmentDictionary : Hashtable
    {
        private readonly int delayMilliseconds;

        public DelayedEnvironmentDictionary(int delayMilliseconds)
        {
            this.delayMilliseconds = delayMilliseconds;
        }

        public override IDictionaryEnumerator GetEnumerator()
        {
            Thread.Sleep(this.delayMilliseconds);
            return base.GetEnumerator();
        }
    }
}
'@
    }
    $delayedEnvironment = New-Object `
        -TypeName $delayedEnvironmentTypeName `
        -ArgumentList 700
    foreach (
        $environmentEntry in (
            New-RunnerTestEnvironment
        ).GetEnumerator()
    ) {
        $delayedEnvironment[[string]$environmentEntry.Key] = (
            [string]$environmentEntry.Value
        )
    }
    $preStartDeadlineSentinel = Join-Path (
        $tempRoot
    ) 'pre-start-deadline.sentinel'
    $escapedPreStartDeadlineSentinel = (
        $preStartDeadlineSentinel.Replace("'", "''")
    )
    $preStartDeadlineObserved = $false
    $preStartDeadlineStopwatch = (
        [System.Diagnostics.Stopwatch]::StartNew()
    )
    try {
        [void](Invoke-PrivateMarkerBoundedProcess `
            -FilePath $powerShellPath `
            -Arguments (
                Get-PowerShellArguments -AdditionalArguments @(
                    '-Command',
                    (
                        "[System.IO.File]::WriteAllText(" +
                        "'$escapedPreStartDeadlineSentinel','ran'); " +
                        'Start-Sleep -Seconds 2'
                    )
                )
            ) `
            -WorkingDirectory $root `
            -EnvironmentVariables $delayedEnvironment `
            -TimeoutMilliseconds 300 `
            -KillWaitMilliseconds 1000)
    }
    catch {
        if ($_.Exception.Message -match 'process-timeout') {
            $preStartDeadlineObserved = $true
        } else {
            Add-Failure 'Pre-start deadline fixture returned an unexpected failure class.'
        }
    }
    finally {
        $preStartDeadlineStopwatch.Stop()
    }
    if (
        -not $preStartDeadlineObserved -or
        (Test-Path -LiteralPath $preStartDeadlineSentinel) -or
        $preStartDeadlineStopwatch.ElapsedMilliseconds -lt 600 -or
        $preStartDeadlineStopwatch.ElapsedMilliseconds -ge 4000
    ) {
        Add-Failure 'Expected the operation deadline to expire before process start without consuming cleanup slack.'
    }

    # exported runnerのnumeric引数は[int] binderへ渡す前のraw scalarで検査し、
    # 小数丸め・指数表記・配列を固定codeで拒否してchildを起動しない。
    $invalidRunnerNumericCases = @(
        [pscustomobject]@{
            Name = 'TimeoutMilliseconds'
            Value = [double]10000.5
        },
        [pscustomobject]@{
            Name = 'KillWaitMilliseconds'
            Value = [decimal]5000.5
        },
        [pscustomobject]@{
            Name = 'MaxStandardOutputBytes'
            Value = '65536.5'
        },
        [pscustomobject]@{
            Name = 'MaxStandardErrorBytes'
            Value = [object[]]@('65536')
        }
    )
    foreach ($invalidNumericCase in $invalidRunnerNumericCases) {
        $numericSentinel = Join-Path $tempRoot (
            'invalid-numeric-' +
            $invalidNumericCase.Name +
            '.sentinel'
        )
        $escapedNumericSentinel = $numericSentinel.Replace("'", "''")
        $numericInvocation = @{
            FilePath = $powerShellPath
            Arguments = (
                Get-PowerShellArguments -AdditionalArguments @(
                    '-Command',
                    (
                        "[System.IO.File]::WriteAllText(" +
                        "'$escapedNumericSentinel','ran')"
                    )
                )
            )
            WorkingDirectory = $root
            EnvironmentVariables = (New-RunnerTestEnvironment)
            TimeoutMilliseconds = 10000
            KillWaitMilliseconds = 5000
            MaxStandardOutputBytes = 64KB
            MaxStandardErrorBytes = 64KB
        }
        $numericInvocation[$invalidNumericCase.Name] = (
            $invalidNumericCase.Value
        )
        $invalidNumericObserved = $false
        try {
            [void](Invoke-PrivateMarkerBoundedProcess @numericInvocation)
        }
        catch {
            if ($_.Exception.Message -match 'process-limit-invalid') {
                $invalidNumericObserved = $true
            } else {
                Add-Failure "Runner numeric case '$($invalidNumericCase.Name)' returned an unexpected failure class."
            }
        }
        if (
            -not $invalidNumericObserved -or
            (Test-Path -LiteralPath $numericSentinel)
        ) {
            Add-Failure "Expected runner numeric case '$($invalidNumericCase.Name)' to reject raw non-integer input before child start."
        }
    }

    if (-not $isWindowsPlatform) {
        # fake setsidがdirect launcherの終了前後に実groupを遅延作成しても、
        # verified PGIDより先にreleaseせず、late groupもcleanup budgetで回収する。
        $trustedSetsidPath = Get-PrivateMarkerTrustedSetsidPath
        $chmodPath = @('/usr/bin/chmod', '/bin/chmod') |
            Where-Object {
                [System.IO.File]::Exists($_)
            } |
            Select-Object -First 1
        $sleepPath = @('/usr/bin/sleep', '/bin/sleep') |
            Where-Object {
                [System.IO.File]::Exists($_)
            } |
            Select-Object -First 1
        if (
            [string]::IsNullOrEmpty($trustedSetsidPath) -or
            [string]::IsNullOrEmpty($chmodPath) -or
            [string]::IsNullOrEmpty($sleepPath)
        ) {
            Add-Failure 'Expected trusted setsid, chmod, and sleep executables for the POSIX launch-gate regression.'
        } else {
            $gatePayload = Join-Path $tempRoot 'posix-gate-payload.sh'
            [System.IO.File]::WriteAllText(
                $gatePayload,
                @'
#!/bin/sh
printf 'ran\n' > "$1"
"$PRIVATE_MARKER_TEST_SLEEP" 10
'@,
                $utf8NoBom
            )
            $directDelaySetsid = Join-Path $tempRoot 'fake-setsid-direct-delay.sh'
            [System.IO.File]::WriteAllText(
                $directDelaySetsid,
                @'
#!/bin/sh
printf '%s\n' "$7" > "$PRIVATE_MARKER_TEST_GATE_CAPTURE"
"$PRIVATE_MARKER_TEST_SLEEP" 0.25
exec "$PRIVATE_MARKER_TEST_REAL_SETSID" "$@"
'@,
                $utf8NoBom
            )
            $forkDelaySetsid = Join-Path $tempRoot 'fake-setsid-fork-delay.sh'
            [System.IO.File]::WriteAllText(
                $forkDelaySetsid,
                @'
#!/bin/sh
printf '%s\n' "$7" > "$PRIVATE_MARKER_TEST_GATE_CAPTURE"
(
    "$PRIVATE_MARKER_TEST_SLEEP" 0.25
    exec "$PRIVATE_MARKER_TEST_REAL_SETSID" "$@"
) &
exit 0
'@,
                $utf8NoBom
            )
            $chmodResult = Invoke-BoundedProcess `
                -FilePath $chmodPath `
                -Arguments @(
                    '700',
                    $gatePayload,
                    $directDelaySetsid,
                    $forkDelaySetsid
                ) `
                -WorkingDirectory $root `
                -TimeoutMilliseconds 5000
            if ($chmodResult.ExitCode -ne 0) {
                Add-Failure 'Expected POSIX launch-gate fixtures to become executable.'
            } else {
                foreach ($launchGateCase in @(
                    [pscustomobject]@{
                        Name = 'direct-delay'
                        SetsidPath = $directDelaySetsid
                    },
                    [pscustomobject]@{
                        Name = 'fork-delay'
                        SetsidPath = $forkDelaySetsid
                    }
                )) {
                    $gateSentinel = Join-Path $tempRoot (
                        'posix-gate-' + $launchGateCase.Name + '.sentinel'
                    )
                    $gateCapture = Join-Path $tempRoot (
                        'posix-gate-' + $launchGateCase.Name + '.root'
                    )
                    $gateEnvironment = New-RunnerTestEnvironment
                    $gateEnvironment[
                        'PRIVATE_MARKER_TEST_REAL_SETSID'
                    ] = $trustedSetsidPath
                    $gateEnvironment[
                        'PRIVATE_MARKER_TEST_GATE_CAPTURE'
                    ] = $gateCapture
                    $gateEnvironment[
                        'PRIVATE_MARKER_TEST_SLEEP'
                    ] = $sleepPath
                    $gateTimeoutObserved = $false
                    $gateStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
                    try {
                        [void][MultiAgentDelegation.PrivateMarkerBoundedProcess]::Run(
                            $gatePayload,
                            [string[]]@($gateSentinel),
                            $root,
                            $gateEnvironment,
                            [byte[]]@(),
                            100,
                            1500,
                            64KB,
                            64KB,
                            $launchGateCase.SetsidPath,
                            ''
                        )
                    }
                    catch {
                        if ($_.Exception.Message -match 'process-timeout') {
                            $gateTimeoutObserved = $true
                        } else {
                            Add-Failure "POSIX launch-gate case '$($launchGateCase.Name)' returned an unexpected failure class."
                        }
                    }
                    finally {
                        $gateStopwatch.Stop()
                    }

                    # method復帰後にも遅延childの実行余地を与え、gate rootと
                    # sentinelの双方が残らないことをboundedに確認する。
                    Start-Sleep -Milliseconds 400
                    $capturedGateRoot = ''
                    if (Test-Path -LiteralPath $gateCapture -PathType Leaf) {
                        $capturedGateRoot = [System.IO.File]::ReadAllText(
                            $gateCapture
                        ).Trim()
                    }
                    if (
                        -not $gateTimeoutObserved -or
                        $gateStopwatch.ElapsedMilliseconds -ge 4000 -or
                        [string]::IsNullOrWhiteSpace($capturedGateRoot) -or
                        (Test-Path -LiteralPath $capturedGateRoot) -or
                        (Test-Path -LiteralPath $gateSentinel)
                    ) {
                        Add-Failure "Expected POSIX launch-gate case '$($launchGateCase.Name)' to prevent target execution and remove its private gate."
                    }
                }
            }
        }
    }

    if ($isWindowsPlatform) {
        # GCへpipe/FileStream/Task handle回収を委ねる実装は成功ごとにhandleが
        # 単調増加する。warm-up後はGCを呼ばず40回成功させ、boundedな揺れだけ
        # を許可して明示Dispose契約を実測する。
        $handleProbeTarget = Join-Path (
            [Environment]::SystemDirectory
        ) 'cmd.exe'
        $handleProbeArguments = @('/d', '/c', 'exit', '0')
        [void](Invoke-PrivateMarkerBoundedProcess `
            -FilePath $handleProbeTarget `
            -Arguments $handleProbeArguments `
            -WorkingDirectory $root `
            -EnvironmentVariables (New-RunnerTestEnvironment) `
            -TimeoutMilliseconds 10000)
        $handleProbeProcess = [System.Diagnostics.Process]::GetCurrentProcess()
        try {
            $handleProbeProcess.Refresh()
            $handleBaseline = $handleProbeProcess.HandleCount
            $handleMaximum = $handleBaseline
            $handleFinal = $handleBaseline
            for ($handleAttempt = 0; $handleAttempt -lt 40; $handleAttempt++) {
                $handleProbeResult = Invoke-PrivateMarkerBoundedProcess `
                    -FilePath $handleProbeTarget `
                    -Arguments $handleProbeArguments `
                    -WorkingDirectory $root `
                    -EnvironmentVariables (New-RunnerTestEnvironment) `
                    -TimeoutMilliseconds 10000
                if (
                    $handleProbeResult.ExitCode -ne 0 -or
                    $handleProbeResult.StandardOutputBytes.Length -ne 0 -or
                    $handleProbeResult.StandardErrorBytes.Length -ne 0
                ) {
                    Add-Failure 'Expected every Windows handle-stability child to exit cleanly.'
                    break
                }
                $handleProbeProcess.Refresh()
                $handleFinal = $handleProbeProcess.HandleCount
                $handleMaximum = [Math]::Max(
                    $handleMaximum,
                    $handleFinal
                )
            }
            if (
                ($handleFinal - $handleBaseline) -gt 4 -or
                ($handleMaximum - $handleBaseline) -gt 8
            ) {
                Add-Failure (
                    'Expected 40 Windows success runs without GC to keep process ' +
                    "handles bounded (baseline=$handleBaseline, " +
                    "final=$handleFinal, max=$handleMaximum)."
                )
            }
            $windowsHandleProbeEvidence = (
                "baseline=$handleBaseline, final=$handleFinal, " +
                "max=$handleMaximum, runs=40, gc=not-invoked"
            )
        }
        finally {
            $handleProbeProcess.Dispose()
        }
    } elseif (Test-Path -LiteralPath "/proc/$PID/fd" -PathType Container) {
        # POSIX success pathもProcess.Disposeだけへ依存せず、pumpのpipe/Task/
        # bufferを明示回収する。GCなし40回でfdが単調増加しないことを測る。
        $truePath = @('/usr/bin/true', '/bin/true') |
            Where-Object {
                [System.IO.File]::Exists($_)
            } |
            Select-Object -First 1
        if ([string]::IsNullOrEmpty($truePath)) {
            Add-Failure 'Expected a trusted true executable for the POSIX fd probe.'
        } else {
            [void](Invoke-PrivateMarkerBoundedProcess `
                -FilePath $truePath `
                -WorkingDirectory $root `
                -EnvironmentVariables (New-RunnerTestEnvironment) `
                -TimeoutMilliseconds 10000)
            $fdDirectory = "/proc/$PID/fd"
            $fdBaseline = (
                [System.IO.Directory]::GetFileSystemEntries(
                    $fdDirectory
                ).Length
            )
            $fdMaximum = $fdBaseline
            $fdFinal = $fdBaseline
            for ($fdAttempt = 0; $fdAttempt -lt 40; $fdAttempt++) {
                $fdProbeResult = Invoke-PrivateMarkerBoundedProcess `
                    -FilePath $truePath `
                    -WorkingDirectory $root `
                    -EnvironmentVariables (New-RunnerTestEnvironment) `
                    -TimeoutMilliseconds 10000
                if (
                    $fdProbeResult.ExitCode -ne 0 -or
                    $fdProbeResult.StandardOutputBytes.Length -ne 0 -or
                    $fdProbeResult.StandardErrorBytes.Length -ne 0
                ) {
                    Add-Failure 'Expected every POSIX fd-stability child to exit cleanly.'
                    break
                }
                $fdFinal = (
                    [System.IO.Directory]::GetFileSystemEntries(
                        $fdDirectory
                    ).Length
                )
                $fdMaximum = [Math]::Max($fdMaximum, $fdFinal)
            }
            if (
                ($fdFinal - $fdBaseline) -gt 4 -or
                ($fdMaximum - $fdBaseline) -gt 8
            ) {
                Add-Failure (
                    'Expected 40 POSIX success runs without GC to keep file ' +
                    "descriptors bounded (baseline=$fdBaseline, " +
                    "final=$fdFinal, max=$fdMaximum)."
                )
            }
            $posixFdProbeEvidence = (
                "baseline=$fdBaseline, final=$fdFinal, " +
                "max=$fdMaximum, runs=40, gc=not-invoked"
            )
        }
    }

    # PowerShell childは自身の input 境界で UTF-8 preamble を許容し得るため、
    # native Git --batch へ直接 byte を渡し、PS5.1 でも BOM 混入がないことと
    # caller の Console.InputEncoding が完全復元されることを別 fixture で固定する。
    $rawGitRoot = Join-Path $tempRoot 'raw-git-transport'
    New-Item -ItemType Directory -Path $rawGitRoot | Out-Null
    [void](Invoke-TestGit `
        -WorkingDirectory $rawGitRoot `
        -Arguments @('init', '-q'))
    $rawGitBlobBytes = [byte[]](0x00, 0x80, 0xFF, 0x0A, 0x0D, 0x01, 0x02)
    [System.IO.File]::WriteAllBytes(
        (Join-Path $rawGitRoot 'blob.bin'),
        $rawGitBlobBytes
    )
    $rawGitHashResult = Invoke-TestGit `
        -WorkingDirectory $rawGitRoot `
        -Arguments @('hash-object', '-w', '--', 'blob.bin')
    $rawGitObjectId = $rawGitHashResult.StandardOutput.Trim()
    if ($rawGitObjectId -notmatch '^(?:[0-9a-f]{40}|[0-9a-f]{64})$') {
        Add-Failure 'Expected the native Git transport fixture to create a blob object.'
    } else {
        $inputCodePageBefore = [Console]::InputEncoding.CodePage
        $inputPreambleBefore = [Convert]::ToBase64String(
            [Console]::InputEncoding.GetPreamble()
        )
        $rawGitBatchInput = [System.Text.Encoding]::ASCII.GetBytes(
            "$rawGitObjectId`n"
        )
        $rawGitBatchResult = Invoke-PrivateMarkerBoundedProcess `
            -FilePath $gitCommand.Source `
            -Arguments (
                Get-TestGitArguments `
                    -WorkingDirectory $rawGitRoot `
                    -Arguments @('cat-file', '--batch')
            ) `
            -WorkingDirectory $rawGitRoot `
            -EnvironmentVariables (New-TestGitEnvironment) `
            -StandardInput $rawGitBatchInput `
            -TimeoutMilliseconds 10000 `
            -MaxStandardOutputBytes 64KB `
            -MaxStandardErrorBytes 64KB
        $rawGitHeaderBytes = [System.Text.Encoding]::ASCII.GetBytes(
            "$rawGitObjectId blob $($rawGitBlobBytes.Length)`n"
        )
        $expectedRawGitOutput = [byte[]](
            @($rawGitHeaderBytes) +
            @($rawGitBlobBytes) +
            @(0x0A)
        )
        if (
            $rawGitBatchResult.ExitCode -ne 0 -or
            $rawGitBatchResult.StandardErrorBytes.Length -ne 0 -or
            [Convert]::ToBase64String(
                $rawGitBatchResult.StandardOutputBytes
            ) -cne [Convert]::ToBase64String($expectedRawGitOutput)
        ) {
            Add-Failure 'Expected native git cat-file batch transport to remain byte-exact without a UTF-8 preamble.'
        }
        if (
            [Console]::InputEncoding.CodePage -ne $inputCodePageBefore -or
            [Convert]::ToBase64String(
                [Console]::InputEncoding.GetPreamble()
            ) -cne $inputPreambleBefore
        ) {
            Add-Failure 'Expected the raw input transport to restore the caller console input encoding exactly.'
        }
    }

    # scanner entry/helper/isolation境界の例外本文にはabsolute pathが含まれ
    # 得る。temp内の独立copyを壊し、stdout固定1行・stderr空・exit 2だけを
    # 公開することと、repo/temp/helper pathが一切出ないことを固定する。
    $boundaryFixtureRoot = Join-Path $tempRoot 'scanner-boundary-fixtures'
    New-Item -ItemType Directory -Path $boundaryFixtureRoot | Out-Null
    $scannerV2Path = Join-Path $root 'scripts/scan-private-markers-v2.ps1'
    $scannerSource = [System.IO.File]::ReadAllText($scanner)
    $scannerV2Source = [System.IO.File]::ReadAllText($scannerV2Path)
    $processRunnerSource = [System.IO.File]::ReadAllText($processRunnerModule)
    $utf8WithBom = New-Object System.Text.UTF8Encoding($true)
    $writeBoundaryVariant = {
        param(
            [string]$Name,
            [string]$ImplementationSource,
            [AllowNull()][object]$RunnerSource
        )

        $variantRoot = Join-Path $boundaryFixtureRoot $Name
        New-Item -ItemType Directory -Path $variantRoot | Out-Null
        $variantScanner = Join-Path $variantRoot 'scan-private-markers.ps1'
        [System.IO.File]::WriteAllText(
            $variantScanner,
            $scannerSource,
            $utf8WithBom
        )
        [System.IO.File]::WriteAllText(
            (Join-Path $variantRoot 'scan-private-markers-v2.ps1'),
            $ImplementationSource,
            $utf8WithBom
        )
        if ($null -ne $RunnerSource) {
            [System.IO.File]::WriteAllText(
                (
                    Join-Path $variantRoot (
                        'private-marker-process-runner.psm1'
                    )
                ),
                [string]$RunnerSource,
                $utf8WithBom
            )
        }
        return $variantScanner
    }
    $boundaryForbiddenPaths = @(
        $root,
        $tempRoot,
        $boundaryFixtureRoot,
        $scanner,
        $scannerV2Path,
        $processRunnerModule
    )

    $missingImplementationRoot = Join-Path (
        $boundaryFixtureRoot
    ) 'missing-implementation'
    New-Item -ItemType Directory -Path $missingImplementationRoot | Out-Null
    $missingImplementationScanner = Join-Path (
        $missingImplementationRoot
    ) 'scan-private-markers.ps1'
    [System.IO.File]::WriteAllText(
        $missingImplementationScanner,
        $scannerSource,
        $utf8WithBom
    )
    Assert-FixedScannerBoundaryFailure `
        -Result (
            Invoke-Scanner `
                -ScanPath $rawGitRoot `
                -ScannerPath $missingImplementationScanner
        ) `
        -ExpectedCode 'scanner-entrypoint-failed' `
        -ForbiddenPaths $boundaryForbiddenPaths `
        -CaseName 'missing scanner implementation'

    $missingRunnerScanner = & $writeBoundaryVariant `
        -Name 'missing-runner' `
        -ImplementationSource $scannerV2Source `
        -RunnerSource $null
    Assert-FixedScannerBoundaryFailure `
        -Result (
            Invoke-Scanner `
                -ScanPath $rawGitRoot `
                -ScannerPath $missingRunnerScanner
        ) `
        -ExpectedCode 'process-runner-initialization-failed' `
        -ForbiddenPaths $boundaryForbiddenPaths `
        -CaseName 'missing process runner'

    $leakyHelperPath = Join-Path $boundaryFixtureRoot 'helper-private-path'
    $escapedLeakyHelperPath = $leakyHelperPath.Replace("'", "''")
    $escapedRawGitRoot = $rawGitRoot.Replace("'", "''")
    $throwingRunnerSource = @"
`$script:BoundaryInvocationCount = 0
function New-PrivateMarkerChildEnvironment {
    return @{}
}
function Invoke-PrivateMarkerBoundedProcess {
    param(
        [string]`$FilePath,
        [string[]]`$Arguments,
        [string]`$WorkingDirectory,
        [System.Collections.IDictionary]`$EnvironmentVariables,
        [byte[]]`$StandardInput,
        [int]`$TimeoutMilliseconds,
        [int]`$KillWaitMilliseconds,
        [int]`$MaxStandardOutputBytes,
        [int]`$MaxStandardErrorBytes
    )
    `$script:BoundaryInvocationCount++
    if (`$script:BoundaryInvocationCount -eq 1) {
        `$encoding = New-Object System.Text.UTF8Encoding(`$false)
        return [pscustomobject]@{
            ExitCode = 0
            StandardOutputBytes = `$encoding.GetBytes(
                '$escapedRawGitRoot' + [Environment]::NewLine
            )
            StandardErrorBytes = [byte[]]@()
        }
    }
    throw '$escapedLeakyHelperPath'
}
Export-ModuleMember -Function @(
    'New-PrivateMarkerChildEnvironment',
    'Invoke-PrivateMarkerBoundedProcess'
)
"@
    $throwingRunnerScanner = & $writeBoundaryVariant `
        -Name 'throwing-runner' `
        -ImplementationSource $scannerV2Source `
        -RunnerSource $throwingRunnerSource
    Assert-FixedScannerBoundaryFailure `
        -Result (
            Invoke-Scanner `
                -ScanPath $rawGitRoot `
                -ScannerPath $throwingRunnerScanner
        ) `
        -ExpectedCode 'scanner-runtime-failed' `
        -ForbiddenPaths (
            @($boundaryForbiddenPaths) + @($leakyHelperPath)
        ) `
        -CaseName 'process runner exception'

    $leakyCreatePath = Join-Path $boundaryFixtureRoot 'create-private-path'
    $createNeedle = (
        '        New-Item -ItemType Directory -Path $isolationRoot | ' +
        'Out-Null'
    )
    $createReplacement = (
        $createNeedle +
        [Environment]::NewLine +
        "        throw '$($leakyCreatePath.Replace("'", "''"))'"
    )
    $createFailureSource = $scannerV2Source.Replace(
        $createNeedle,
        $createReplacement
    )
    if ($createFailureSource -ceq $scannerV2Source) {
        Add-Failure 'Expected the isolation-create boundary mutation to apply.'
    } else {
        $createFailureScanner = & $writeBoundaryVariant `
            -Name 'isolation-create-failure' `
            -ImplementationSource $createFailureSource `
            -RunnerSource $processRunnerSource
        Assert-FixedScannerBoundaryFailure `
            -Result (
                Invoke-Scanner `
                    -ScanPath $rawGitRoot `
                    -ScannerPath $createFailureScanner
            ) `
            -ExpectedCode 'scanner-runtime-failed' `
            -ForbiddenPaths (
                @($boundaryForbiddenPaths) + @($leakyCreatePath)
            ) `
            -CaseName 'Git isolation creation failure'
    }

    $leakyRemovePath = Join-Path $boundaryFixtureRoot 'remove-private-path'
    $removeNeedle = (
        '    $resolved = [System.IO.Path]::GetFullPath($IsolationRoot)'
    )
    $removeReplacement = (
        "    throw '$($leakyRemovePath.Replace("'", "''"))'" +
        [Environment]::NewLine +
        $removeNeedle
    )
    $removeFailureSource = $scannerV2Source.Replace(
        $removeNeedle,
        $removeReplacement
    )
    if ($removeFailureSource -ceq $scannerV2Source) {
        Add-Failure 'Expected the isolation-remove boundary mutation to apply.'
    } else {
        $removeFailureScanner = & $writeBoundaryVariant `
            -Name 'isolation-remove-failure' `
            -ImplementationSource $removeFailureSource `
            -RunnerSource $processRunnerSource
        Assert-FixedScannerBoundaryFailure `
            -Result (
                Invoke-Scanner `
                    -ScanPath $rawGitRoot `
                    -ScannerPath $removeFailureScanner
            ) `
            -ExpectedCode 'scanner-runtime-failed' `
            -ForbiddenPaths (
                @($boundaryForbiddenPaths) + @($leakyRemovePath)
            ) `
            -CaseName 'Git isolation removal failure'
    }

    if ($ScannerBoundaryProbe) {
        if ($failures.Count -gt 0) {
            Write-Host 'Scanner boundary probe failed:'
            foreach ($failure in $failures) {
                Write-Host "- $failure"
            }
            exit 1
        }
        Write-Host 'Scanner boundary probe passed.'
        exit 0
    }

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

    # parameter binding前のValidateRangeに依存するとPowerShell framingと入力値
    # がstderrへ漏れる。公開wrapperの上下限違反をbody内tryで固定診断へ畳む。
    foreach (
        $invalidDeadline in @(
            '0',
            '120001',
            '1.5',
            '1e3',
            'not-an-integer',
            '2147483648'
        )
    ) {
        $invalidDeadlineResult = Invoke-Scanner `
            -ScanPath $cleanRoot `
            -AdditionalArguments @(
                '-ScanDeadlineMilliseconds',
                $invalidDeadline
            )
        Assert-FixedScannerBoundaryFailure `
            -Result $invalidDeadlineResult `
            -ExpectedCode 'scanner-entrypoint-failed' `
            -ForbiddenPaths @($root, $cleanRoot, $scanner) `
            -CaseName "invalid public scan deadline $invalidDeadline"
    }

    # production の 120 秒は延長できず、self-test だけが lower-only の 1 ms
    # deadline で最終 success write 直前の fail-closed 経路を再現する。
    $scanDeadlineStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $scanDeadlineResult = Invoke-Scanner `
        -ScanPath $cleanRoot `
        -AdditionalArguments @('-ScanDeadlineMilliseconds', '1')
    $scanDeadlineStopwatch.Stop()
    if (
        $scanDeadlineResult.ExitCode -eq 0 -or
        $scanDeadlineResult.Output -match 'Private marker scan passed' -or
        $scanDeadlineStopwatch.ElapsedMilliseconds -ge 10000
    ) {
        Add-Failure 'Expected the lower-only scan deadline to fail before final success output inside a bounded runtime.'
    }

    # 真の non-Git fallback では scan root より下の `.git` directory / leaf
    # だけを control metadata として除外し、中身を一切読まない。
    $nestedGitFallbackRoot = Join-Path $tempRoot 'nested-git-fallback'
    $nestedGitDirectory = Join-Path $nestedGitFallbackRoot (
        Join-Path 'neutral-directory' '.git'
    )
    $nestedGitLeafDirectory = Join-Path (
        $nestedGitFallbackRoot
    ) 'neutral-leaf'
    New-Item -ItemType Directory -Path $nestedGitDirectory -Force | Out-Null
    New-Item `
        -ItemType Directory `
        -Path $nestedGitLeafDirectory `
        -Force | Out-Null
    [System.IO.File]::WriteAllText(
        (Join-Path $nestedGitFallbackRoot 'README.md'),
        '# Visible clean content',
        $utf8NoBom
    )
    $nestedGitDirectoryMarker = ('g' + 'hp_') +
        'synthetic_nested_git_directory'
    $nestedGitLeafMarker = ('g' + 'hp_') +
        'synthetic_nested_git_leaf'
    [System.IO.File]::WriteAllText(
        (Join-Path $nestedGitDirectory 'ignored.md'),
        $nestedGitDirectoryMarker,
        $utf8NoBom
    )
    [System.IO.File]::WriteAllText(
        (Join-Path $nestedGitLeafDirectory '.git'),
        "gitdir: $nestedGitLeafMarker",
        $utf8NoBom
    )
    $nestedGitFallbackResult = Invoke-Scanner `
        -ScanPath $nestedGitFallbackRoot
    if (
        $nestedGitFallbackResult.ExitCode -ne 0 -or
        $nestedGitFallbackResult.Output -notmatch
            'scan target: working-tree' -or
        $nestedGitFallbackResult.Output.Contains(
            $nestedGitDirectoryMarker
        ) -or
        $nestedGitFallbackResult.Output.Contains($nestedGitLeafMarker)
    ) {
        Add-Failure 'Expected nested .git directory/leaf entries to remain excluded only inside true non-Git fallback.'
    }

    if (-not $isWindowsPlatform) {
        # case-sensitive POSIXでは `.GIT` はGit control metadataではない。
        # ordinary directoryのmarkerをscanし、値自体はredactされることを固定する。
        $upperGitRoot = Join-Path $tempRoot 'uppercase-git-fallback'
        $upperGitDirectory = Join-Path $upperGitRoot '.GIT'
        New-Item `
            -ItemType Directory `
            -Path $upperGitDirectory `
            -Force | Out-Null
        $upperGitMarker = ('g' + 'hp_') +
            'synthetic_uppercase_git_directory'
        [System.IO.File]::WriteAllText(
            (Join-Path $upperGitDirectory 'visible.md'),
            $upperGitMarker,
            $utf8NoBom
        )
        $upperGitResult = Invoke-Scanner -ScanPath $upperGitRoot
        if (
            $upperGitResult.ExitCode -eq 0 -or
            $upperGitResult.Output -notmatch 'github-classic-token-prefix' -or
            $upperGitResult.Output -notmatch 'scan target: working-tree' -or
            $upperGitResult.Output.Contains($upperGitMarker)
        ) {
            Add-Failure 'Expected POSIX non-Git fallback to scan ordinary uppercase .GIT content with redaction.'
        }
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

    # Resolve-Pathより前のhostile/nonexistent inputもraw pathやUnicode control、
    # PowerShell framingを出さず、固定code 1行へ畳み込む。
    $hostileMissingPath = Join-Path $tempRoot (
        'missing-' +
        [char]0x202E +
        'bidi' +
        [char]0x200B +
        'format' +
        [char]0x2028 +
        'separator'
    )
    $hostilePathResult = Invoke-Scanner -ScanPath $hostileMissingPath
    $hostileOutputBytes = $utf8NoBom.GetByteCount(
        $hostilePathResult.StandardOutput
    )
    if (
        $hostilePathResult.ExitCode -eq 0 -or
        $hostilePathResult.StandardOutput -notmatch 'scan-root-invalid' -or
        -not [string]::IsNullOrEmpty($hostilePathResult.StandardError) -or
        $hostilePathResult.Output.Contains([string][char]0x202E) -or
        $hostilePathResult.Output.Contains([string][char]0x200B) -or
        $hostilePathResult.Output.Contains([string][char]0x2028) -or
        $hostilePathResult.Output -match 'Resolve-Path' -or
        $hostileOutputBytes -gt 256
    ) {
        Add-Failure 'Hostile missing scan root did not use its fixed bounded diagnostic.'
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
        -TimeoutMilliseconds 240000
    if (
        $probeResult.ExitCode -ne 0 -or
        $probeResult.Output -notmatch 'Environment contract probe passed'
    ) {
        Add-Failure 'Expected the present-empty/absent environment contract probe to pass.'
    }

    if ($isWindowsPlatform) {
        # Job assign 前 / resume 前の native failure は suspended target を
        # 一度も実行せず、terminate・wait・全 handle close を検査して返す。
        # Job cleanup failureはdirect TerminateProcessへfallbackし、close失敗
        # 時もhandleを保持したままbounded retryで回収する。
        $launchFailureTarget = Join-Path (
            $tempRoot
        ) 'windows-launch-failure-target.ps1'
        [System.IO.File]::WriteAllText(
            $launchFailureTarget,
            @'
param([string]$SentinelPath)
[System.IO.File]::WriteAllText($SentinelPath, 'ran')
'@,
            $utf8NoBom
        )
        foreach ($launchFailureMode in @('assign', 'resume', 'job-close')) {
            $launchFailureSentinel = Join-Path $tempRoot (
                "windows-launch-failure-$launchFailureMode.sentinel"
            )
            $launchFailureObserved = $false
            $launchFailureStopwatch = (
                [System.Diagnostics.Stopwatch]::StartNew()
            )
            try {
                [void](Invoke-PrivateMarkerBoundedProcess `
                    -FilePath $powerShellPath `
                    -Arguments (
                        Get-PowerShellArguments -AdditionalArguments @(
                            '-File',
                            $launchFailureTarget,
                            '-SentinelPath',
                            $launchFailureSentinel
                        )
                    ) `
                    -WorkingDirectory $root `
                    -EnvironmentVariables (New-RunnerTestEnvironment) `
                    -TimeoutMilliseconds 10000 `
                    -ForceWindowsLaunchFailure $launchFailureMode)
            }
            catch {
                if (
                    $_.Exception.Message -match
                        "synthetic-windows-(job-assign|process-resume|job-close)-failed" -or
                    (
                        $launchFailureMode -eq 'job-close' -and
                        $_.Exception.Message -match
                            'windows-launch-cleanup-failed'
                    )
                ) {
                    $launchFailureObserved = $true
                } else {
                    Add-Failure "Windows $launchFailureMode fault injection returned an unexpected native failure class."
                }
            }
            finally {
                $launchFailureStopwatch.Stop()
            }

            $launchFailureProcessId = (
                [MultiAgentDelegation.PrivateMarkerBoundedProcess]::
                    LastSyntheticFailureProcessId
            )
            $launchFailureProcessGone = $false
            if ($launchFailureProcessId -gt 0) {
                # APIの成功判定だけでなく、PID が kernel process table から
                # 消えるまで最大 1 秒だけ bounded に再確認する。
                for (
                    $pidCheckAttempt = 0;
                    $pidCheckAttempt -lt 20;
                    $pidCheckAttempt++
                ) {
                    if (
                        $null -eq (
                            Get-Process `
                                -Id $launchFailureProcessId `
                                -ErrorAction SilentlyContinue
                        )
                    ) {
                        $launchFailureProcessGone = $true
                        break
                    }
                    Start-Sleep -Milliseconds 50
                }
            }
            Start-Sleep -Milliseconds 100
            $jobCloseCleanupObserved = $true
            if ($launchFailureMode -eq 'job-close') {
                $jobCloseCleanupObserved = (
                    [MultiAgentDelegation.PrivateMarkerBoundedProcess]::
                        LastSyntheticTerminateProcessFallbackUsed -and
                    [MultiAgentDelegation.PrivateMarkerBoundedProcess]::
                        LastSyntheticJobCloseRetrySucceeded
                )
            }
            if (
                -not $launchFailureObserved -or
                $launchFailureProcessId -le 0 -or
                -not $launchFailureProcessGone -or
                -not $jobCloseCleanupObserved -or
                $launchFailureStopwatch.ElapsedMilliseconds -ge 6000 -or
                (Test-Path -LiteralPath $launchFailureSentinel)
            ) {
                Add-Failure "Expected Windows $launchFailureMode failure to remove its PID without resuming the suspended sentinel target."
            }
        }
    }

    if ($WindowsJobCleanupProbe) {
        if ($failures.Count -gt 0) {
            Write-Host 'Windows Job cleanup probe failed:'
            foreach ($failure in $failures) {
                Write-Host "- $failure"
            }
            exit 1
        }
        if (-not [string]::IsNullOrEmpty($windowsHandleProbeEvidence)) {
            Write-Host "Windows handle stability: $windowsHandleProbeEvidence"
        }
        Write-Host 'Windows Job cleanup probe passed.'
        exit 0
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
        Invoke-PrivateMarkerBoundedProcess `
            -FilePath $powerShellPath `
            -Arguments $timeoutArguments `
            -WorkingDirectory $root `
            -EnvironmentVariables (New-RunnerTestEnvironment) `
            -TimeoutMilliseconds 1500 | Out-Null
    }
    catch {
        if ($_.Exception.Message -match 'process-timeout') {
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
        Invoke-PrivateMarkerBoundedProcess `
            -FilePath $powerShellPath `
            -Arguments $outputLimitArguments `
            -WorkingDirectory $root `
            -EnvironmentVariables (New-RunnerTestEnvironment) `
            -TimeoutMilliseconds 5000 `
            -MaxStandardOutputBytes 32768 | Out-Null
    }
    catch {
        if ($_.Exception.Message -match 'process-stdout-limit-exceeded') {
            $outputLimitObserved = $true
        } else {
            Add-Failure 'Bounded output fixture raised an unexpected failure class.'
        }
    }
    if (-not $outputLimitObserved) {
        Add-Failure 'Expected the bounded output fixture to hit its byte cap.'
    }

    # 合成git.exeでmalformed空recordと4097件の非空recordを返し、
    # downgrade拒否とparser/CPU budgetをbehaviorally固定する。mode/stateは
    # child environmentに抜け道を作らず、fixture root内の固定fileで渡す。
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
using System.Text;

public static class SyntheticGit
{
    public static int Main(string[] args)
    {
        string root = Directory.GetCurrentDirectory();
        string modePath = Path.Combine(root, ".synthetic-git-mode");
        string statePath = Path.Combine(root, ".synthetic-git-state");
        string mode = File.Exists(modePath)
            ? File.ReadAllText(modePath).Trim()
            : String.Empty;
        if (Array.IndexOf(args, "--show-toplevel") >= 0)
        {
            Console.WriteLine(root);
            return 0;
        }

        if (Array.IndexOf(args, "ls-files") >= 0)
        {
            Stream output = Console.OpenStandardOutput();
            if (String.Equals(mode, "snapshot-mutation", StringComparison.Ordinal))
            {
                if (Array.IndexOf(args, "--stage") >= 0)
                {
                    int count = File.Exists(statePath)
                        ? Int32.Parse(File.ReadAllText(statePath))
                        : 0;
                    File.WriteAllText(statePath, (count + 1).ToString());
                    if (count > 0)
                    {
                        output.WriteByte(120);
                        output.Flush();
                    }
                }
                return 0;
            }
            if (String.Equals(
                    mode,
                    "empty-record",
                    StringComparison.Ordinal))
            {
                output.WriteByte(0);
                output.Flush();
                return 0;
            }

            byte[] record = Encoding.ASCII.GetBytes(
                "100644 0000000000000000000000000000000000000000 0\tp\0");
            for (int index = 0; index < 4097; index++)
                output.Write(record, 0, record.Length);
            output.Flush();
            return 0;
        }

        if (
            String.Equals(mode, "snapshot-mutation", StringComparison.Ordinal) &&
            Array.IndexOf(args, "cat-file") >= 0
        )
        {
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
            $syntheticGitModePath = Join-Path (
                $syntheticGitRoot
            ) '.synthetic-git-mode'
            [System.IO.File]::WriteAllText(
                $syntheticGitModePath,
                'record-limit',
                $utf8NoBom
            )
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

            [System.IO.File]::WriteAllText(
                $syntheticGitModePath,
                'empty-record',
                $utf8NoBom
            )
            $syntheticEmptyRecordResult = Invoke-Scanner `
                -ScanPath $syntheticGitRoot `
                -EnvironmentOverrides @{
                    'PATH' = (
                            $syntheticGitBin +
                            [System.IO.Path]::PathSeparator +
                            [Environment]::GetEnvironmentVariable('PATH')
                        )
                }
            if (
                $syntheticEmptyRecordResult.ExitCode -eq 0 -or
                $syntheticEmptyRecordResult.Output -notmatch 'malformed-git-index-output'
            ) {
                Add-Failure 'Expected an empty Git index record to fail as malformed.'
            }

            # 同じscanner runの最初と最後でraw stage outputを変え、contentが
            # 空でもsnapshot equalityが必ずfail closedになることを固定する。
            $snapshotMutationState = Join-Path (
                $syntheticGitRoot
            ) '.synthetic-git-state'
            [System.IO.File]::WriteAllText(
                $syntheticGitModePath,
                'snapshot-mutation',
                $utf8NoBom
            )
            Remove-Item `
                -LiteralPath $snapshotMutationState `
                -Force `
                -ErrorAction SilentlyContinue
            $snapshotMutationResult = Invoke-Scanner `
                -ScanPath $syntheticGitRoot `
                -EnvironmentOverrides @{
                    'PATH' = (
                            $syntheticGitBin +
                            [System.IO.Path]::PathSeparator +
                            [Environment]::GetEnvironmentVariable('PATH')
                        )
                }
            if (
                $snapshotMutationResult.ExitCode -eq 0 -or
                $snapshotMutationResult.Output -notmatch
                'git-index-changed-during-scan'
            ) {
                Add-Failure 'Expected final raw Git snapshot mutation to fail closed.'
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
    $findingOutputBytes = $utf8NoBom.GetByteCount(
        $findingLimitResult.StandardOutput
    )
    if (
        $findingOutputBytes -gt 64KB -or
        -not [string]::IsNullOrEmpty($findingLimitResult.StandardError)
    ) {
        Add-Failure 'Finding-limit report exceeded its UTF-8 byte budget.'
    }
    if (
        $isWindowsPlatform -and
        [regex]::IsMatch($findingLimitResult.StandardOutput, '(?<!\r)\n')
    ) {
        Add-Failure 'Finding-limit report did not budget the Windows CRLF newline.'
    }
    if (
        -not $isWindowsPlatform -and
        $findingLimitResult.StandardOutput.Contains("`r")
    ) {
        Add-Failure 'Finding-limit report did not use the POSIX LF newline.'
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
    $worktreeOnlyMarker = ('xo' + 'xb-') + 'worktree-only-placeholder'
    $intentToAddMarker = ('A' + 'KIA') + 'INTENT000000000000'
    $sensitiveNameMarker = ('Bear' + 'er ') + 'synthetic-sensitive-placeholder'
    [System.IO.File]::WriteAllText(
        (Join-Path $trackedRoot 'worktree-only.md'),
        '# Clean staged content',
        $utf8NoBom
    )
    [System.IO.File]::WriteAllText(
        (Join-Path $trackedRoot 'intent-to-add.txt'),
        $intentToAddMarker,
        $utf8NoBom
    )
    $sensitiveNames = @(
        '.env',
        '.env.local',
        '.npmrc',
        'synthetic.pem',
        'synthetic.key',
        'extensionless-sensitive'
    )
    foreach ($sensitiveName in $sensitiveNames) {
        [System.IO.File]::WriteAllText(
            (Join-Path $trackedRoot $sensitiveName),
            $sensitiveNameMarker,
            $utf8NoBom
        )
    }
    Invoke-TestGit -WorkingDirectory $trackedRoot -Arguments @('init') | Out-Null
    Invoke-TestGit -WorkingDirectory $trackedRoot -Arguments @(
        'add',
        '--',
        'tracked-clean.md',
        'tracked-marker.md',
        'worktree-only.md'
    ) | Out-Null
    Invoke-TestGit -WorkingDirectory $trackedRoot -Arguments @(
        @('add', '-f', '--') + $sensitiveNames
    ) | Out-Null
    Invoke-TestGit -WorkingDirectory $trackedRoot -Arguments @(
        'add', '-N', '--', 'intent-to-add.txt'
    ) | Out-Null
    [System.IO.File]::WriteAllText(
        (Join-Path $trackedRoot 'worktree-only.md'),
        $worktreeOnlyMarker,
        $utf8NoBom
    )

    # regular stage-0 fileの親directoryをstage後に外部reparseへ差し替え、
    # union側がindex blobは保持しつつworktree targetを読まないことを固定する。
    $trackedReparseDirectory = Join-Path $trackedRoot 'tracked-reparse'
    New-Item -ItemType Directory -Path $trackedReparseDirectory | Out-Null
    [System.IO.File]::WriteAllText(
        (Join-Path $trackedReparseDirectory 'entry.md'),
        '# Clean staged reparse content',
        $utf8NoBom
    )
    Invoke-TestGit -WorkingDirectory $trackedRoot -Arguments @(
        'add', '--', 'tracked-reparse/entry.md'
    ) | Out-Null
    Remove-Item `
        -LiteralPath (Join-Path $trackedReparseDirectory 'entry.md') `
        -Force
    Remove-Item -LiteralPath $trackedReparseDirectory -Force
    $trackedReparseOutside = Join-Path $outsideRoot 'tracked-reparse-target'
    New-Item -ItemType Directory -Path $trackedReparseOutside | Out-Null
    $trackedReparseMarker = ('xo' + 'xa-') + 'outside-reparse-placeholder'
    [System.IO.File]::WriteAllText(
        (Join-Path $trackedReparseOutside 'entry.md'),
        $trackedReparseMarker,
        $utf8NoBom
    )
    if ($isWindowsPlatform) {
        New-Item `
            -ItemType Junction `
            -Path $trackedReparseDirectory `
            -Target $trackedReparseOutside | Out-Null
    } else {
        New-Item `
            -ItemType SymbolicLink `
            -Path $trackedReparseDirectory `
            -Target $trackedReparseOutside | Out-Null
    }
    $trackedReparseCreated = $true

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
    try {
        $adversarialResult = Invoke-Scanner `
            -ScanPath $trackedRoot `
            -EnvironmentOverrides $hostileEnvironment
    }
    finally {
        if ($trackedReparseCreated) {
            [System.IO.Directory]::Delete($trackedReparseDirectory, $false)
            $trackedReparseCreated = $false
        }
    }
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
    if ($adversarialResult.Output -notmatch 'slack-bot-token-prefix') {
        Add-Failure 'Expected an unstaged worktree marker to be scanned with the index blob.'
    }
    if ($adversarialResult.Output -notmatch 'aws-access-key-id') {
        Add-Failure 'Expected an intent-to-add worktree marker to be scanned.'
    }
    if ($adversarialResult.Output -notmatch 'bearer-token-header') {
        Add-Failure 'Expected sensitive-name files to be included in the union scan.'
    }
    if ($adversarialResult.Output -notmatch 'unsafe-file-entry') {
        Add-Failure 'Expected a tracked worktree reparse parent to fail closed.'
    }
    if (
        $adversarialResult.Output -match 'slack-legacy-app-token-prefix' -or
        -not (
            Test-Path `
                -LiteralPath (Join-Path $trackedReparseOutside 'entry.md') `
                -PathType Leaf
        )
    ) {
        Add-Failure 'Tracked worktree reparse target was read or modified.'
    }
    foreach ($sensitiveName in $sensitiveNames) {
        if ($adversarialResult.Output -notmatch [regex]::Escape($sensitiveName)) {
            Add-Failure 'Expected every sensitive-name matrix entry to produce a redacted finding.'
            break
        }
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
    if (
        $adversarialResult.Output -notmatch
        'scan target: git-index-worktree-union'
    ) {
        Add-Failure 'Expected adversarial fixture to retain union scan mode.'
    }
    foreach ($redactedMarker in @(
        $trackedMarker,
        $missingTrackedMarker,
        $worktreeOnlyMarker,
        $intentToAddMarker,
        $sensitiveNameMarker,
        $trackedReparseMarker,
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

    $gitProbeFailureDiagnostic = (
        'Private marker scan failed closed (integrity: git-probe).'
    )

    # 正常な親 repository の child scan も、要求 root と Git root が違う。
    # 親 `.git` を見落として working-tree fallback へ落とさず固定診断にする。
    $nestedScanRoot = Join-Path $trackedRoot 'nested-scan-root'
    New-Item -ItemType Directory -Path $nestedScanRoot | Out-Null
    [System.IO.File]::WriteAllText(
        (Join-Path $nestedScanRoot 'nested.md'),
        '# Nested root must not downgrade',
        $utf8NoBom
    )
    $rootMismatchResult = Invoke-Scanner -ScanPath $nestedScanRoot
    if (
        $rootMismatchResult.ExitCode -ne 2 -or
        $rootMismatchResult.StandardOutput.TrimEnd(
            [char[]]"`r`n"
        ) -cne $gitProbeFailureDiagnostic -or
        -not [string]::IsNullOrEmpty(
            $rootMismatchResult.StandardError
        )
    ) {
        Add-Failure 'Expected a valid ancestor Git root mismatch to use the fixed git-probe diagnostic.'
    }

    # linked worktree/submodule rootはnon-reparse regular `.git` gitfileを持つ。
    # control file自体を読むのではなくbounded Git probeでexact rootを確立し、
    # directory型`.git`と同じindex/worktree union契約へ進める。
    $gitfileSourceRoot = Join-Path $tempRoot 'gitfile-source'
    $linkedWorktreeRoot = Join-Path $outsideRoot 'linked-worktree'
    New-Item -ItemType Directory -Path $gitfileSourceRoot | Out-Null
    [void](Invoke-TestGit `
        -WorkingDirectory $gitfileSourceRoot `
        -Arguments @('init', '-q'))
    [System.IO.File]::WriteAllText(
        (Join-Path $gitfileSourceRoot 'README.md'),
        '# Linked worktree scanner fixture',
        $utf8NoBom
    )
    [void](Invoke-TestGit `
        -WorkingDirectory $gitfileSourceRoot `
        -Arguments @('add', '--', 'README.md'))
    [void](Invoke-TestGit `
        -WorkingDirectory $gitfileSourceRoot `
        -Arguments @(
            '-c',
            'user.name=Synthetic Scanner Test',
            '-c',
            'user.email=scanner-test.invalid',
            'commit',
            '-q',
            '-m',
            'test: initialize linked worktree fixture'
        ))
    [void](Invoke-TestGit `
        -WorkingDirectory $gitfileSourceRoot `
        -Arguments @(
            'worktree',
            'add',
            '--detach',
            $linkedWorktreeRoot,
            'HEAD'
        ))
    $linkedGitControl = Get-Item `
        -LiteralPath (Join-Path $linkedWorktreeRoot '.git') `
        -Force
    $linkedWorktreeResult = Invoke-Scanner -ScanPath $linkedWorktreeRoot
    if (
        $linkedGitControl.PSIsContainer -or
        (
            [int]$linkedGitControl.Attributes -band
            [int][System.IO.FileAttributes]::ReparsePoint
        ) -ne 0 -or
        $linkedWorktreeResult.ExitCode -ne 0 -or
        $linkedWorktreeResult.Output -notmatch
            'scan target: git-index-worktree-union'
    ) {
        Add-Failure 'Expected a valid non-reparse linked-worktree gitfile root to pass bounded Git probing.'
    }

    # root / ancestor の壊れた `.git` は file / directory のどちらでも
    # ambiguous control metadata であり、child scan を含めて exit 2 に固定する。
    foreach ($gitControlCase in @(
        @{
            Name = 'root-directory'
            EntryKind = 'directory'
            ScanChild = $false
        },
        @{
            Name = 'root-file'
            EntryKind = 'file'
            ScanChild = $false
        },
        @{
            Name = 'ancestor-directory'
            EntryKind = 'directory'
            ScanChild = $true
        },
        @{
            Name = 'ancestor-file'
            EntryKind = 'file'
            ScanChild = $true
        }
    )) {
        $gitControlParent = Join-Path $tempRoot (
            'invalid-git-control-' + $gitControlCase.Name
        )
        New-Item `
            -ItemType Directory `
            -Path $gitControlParent `
            -Force | Out-Null
        $gitControlEntryPath = Join-Path $gitControlParent '.git'
        if ($gitControlCase.EntryKind -eq 'directory') {
            New-Item `
                -ItemType Directory `
                -Path $gitControlEntryPath | Out-Null
        } else {
            [System.IO.File]::WriteAllText(
                $gitControlEntryPath,
                'gitdir: synthetic-missing-control-directory',
                $utf8NoBom
            )
        }
        $gitControlScanRoot = if ($gitControlCase.ScanChild) {
            Join-Path $gitControlParent 'child'
        } else {
            $gitControlParent
        }
        if ($gitControlCase.ScanChild) {
            New-Item `
                -ItemType Directory `
                -Path $gitControlScanRoot | Out-Null
        }
        [System.IO.File]::WriteAllText(
            (Join-Path $gitControlScanRoot 'README.md'),
            '# Synthetic clean content',
            $utf8NoBom
        )
        $gitControlResult = Invoke-Scanner `
            -ScanPath $gitControlScanRoot
        if (
            $gitControlResult.ExitCode -ne 2 -or
            $gitControlResult.StandardOutput.TrimEnd(
                [char[]]"`r`n"
            ) -cne $gitProbeFailureDiagnostic -or
            -not [string]::IsNullOrEmpty(
                $gitControlResult.StandardError
            )
        ) {
            Add-Failure "Expected invalid $($gitControlCase.Name) metadata to use the fixed git-probe diagnostic."
        }
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
                $danglingGitResult.ExitCode -ne 2 -or
                $danglingGitResult.StandardOutput.TrimEnd(
                    [char[]]"`r`n"
                ) -cne $gitProbeFailureDiagnostic -or
                -not [string]::IsNullOrEmpty(
                    $danglingGitResult.StandardError
                )
            ) {
                Add-Failure 'Expected dangling Git control entry to use the fixed git-probe diagnostic.'
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

if (-not [string]::IsNullOrEmpty($windowsHandleProbeEvidence)) {
    Write-Host "Windows handle stability: $windowsHandleProbeEvidence"
}
if (-not [string]::IsNullOrEmpty($posixFdProbeEvidence)) {
    Write-Host "POSIX fd stability: $posixFdProbeEvidence"
}
Write-Host "Private marker scan self-test passed (host: $powerShellLeaf)."
exit 0
