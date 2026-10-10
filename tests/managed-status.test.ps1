$ErrorActionPreference = 'Stop'
$tokens = $null
$errors = $null
$source = Join-Path (Split-Path $PSScriptRoot -Parent) 'src/Manage-CodexRelay.ps1'
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Status script did not parse.' }
foreach ($name in @('Convert-ManagedUtc','Get-EffectiveRelayStatus')) {
    $function = $ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name}, $true)
    . ([scriptblock]::Create($function.Extent.Text))
}
$now = [DateTime]::UtcNow
$state = [pscustomobject]@{status='ready';pid=123;updatedAt=$now.ToString('o')}
$helper = [pscustomobject]@{status='mapped';relayPid=123;updatedAtUtc=$now.ToString('o')}
$cases = @(
    @{label='ready only with current matching mapping';helper=$helper;live=$true;mapping=$true;expected='ready'},
    @{label='helper missing';helper=$null;live=$true;mapping=$true;expected='waiting_mapping'},
    @{label='mapping not actually present';helper=$helper;live=$true;mapping=$false;expected='waiting_mapping'},
    @{label='process absent with leftover mapping';helper=$helper;live=$false;mapping=$true;expected='cleanup_pending'},
    @{label='cleanly stopped';helper=$helper;live=$false;mapping=$false;expected='stopped'},
    @{label='mapping belongs to another process';helper=[pscustomobject]@{status='mapped';relayPid=456;updatedAtUtc=$now.ToString('o')};live=$true;mapping=$true;expected='waiting_mapping'},
    @{label='old helper success';helper=[pscustomobject]@{status='mapped';relayPid=123;updatedAtUtc=$now.AddMinutes(-4).ToString('o')};live=$true;mapping=$true;expected='maintenance_stale'}
)
foreach($case in $cases) {
    $observed = Get-EffectiveRelayStatus $state $case.helper $case.live $case.mapping $now
    if ($observed -ne $case.expected) { throw ($case.label + ': expected ' + $case.expected + ', got ' + $observed) }
}
$state.updatedAt = $now.AddMinutes(-4).ToString('o')
if ((Get-EffectiveRelayStatus $state $helper $true $true $now) -ne 'status_stale') { throw 'Stale supervisor state was presented as ready.' }
$state.updatedAt = $now
$helper.updatedAtUtc = $now
if ((Get-EffectiveRelayStatus $state $helper $true $true $now) -ne 'ready') { throw 'PowerShell 7 DateTime values changed timezone during status parsing.' }
Write-Output '9 status checks passed.'
