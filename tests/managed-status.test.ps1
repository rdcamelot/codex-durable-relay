$ErrorActionPreference = 'Stop'
$tokens = $null
$errors = $null
$source = Join-Path (Split-Path $PSScriptRoot -Parent) 'src/Manage-CodexRelay.ps1'
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Status script did not parse.' }
foreach ($name in @('Convert-ManagedUtc','Get-EffectiveRelayStatus','Get-CleanupHealth')) {
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
$warning = Get-EffectiveRelayStatus $state $helper $true $true $now 'failed'
if ($warning -ne 'ready_cleanup_warning') { throw 'A working network hides the most recent failed lifecycle cleanup.' }
$oldSuccess = [pscustomobject]@{success=$true;completedAtUtc=$now.AddHours(-6).ToString('o');reason='clean_stop'}
$timeout = [pscustomobject]@{eventCode=6;status='session_logoff_complete';exitCode=-2;utc=$now.ToString('o')}
if ((Get-CleanupHealth $timeout $oldSuccess $null).health -ne 'failed') { throw 'Old successful STOP hides a more recent timeout.' }
$interrupted = [pscustomobject]@{success=$false;startedAtUtc=$now.AddMinutes(1).ToString('o');reason='in_progress'}
if ((Get-CleanupHealth $timeout $oldSuccess $interrupted).health -ne 'incomplete') { throw 'Interrupted cleanup shown as completed.' }
$newSuccess = [pscustomobject]@{success=$true;completedAtUtc=$now.AddMinutes(2).ToString('o');reason='clean_session_end'}
if ((Get-CleanupHealth $timeout $oldSuccess $newSuccess).health -ne 'verified') { throw 'Latest successful cleanup not recognized.' }
if ((Get-CleanupHealth $null $null $null).health -ne 'unknown') { throw 'Missing evidence must not be treated as success.' }
if ((Get-EffectiveRelayStatus $state $helper $true $true $now 'guard_unavailable') -ne 'ready_cleanup_warning') { throw 'Missing session protection not surfaced.' }
Write-Output '6 cleanup health checks passed.'

$guardPrevious = [pscustomobject]@{
    health='unverified'; reason='previous_receipt_missing'; instanceId='previous-instance'
    observedAtUtc=$now.AddMinutes(1).ToString('o')
}
$guard = [pscustomobject]@{version=2;instanceId='current-instance';previousExit=$guardPrevious}
$oldReceipt = [pscustomobject]@{
    version=2;instanceId='previous-instance';success=$true
    completedAtUtc=$now.AddMinutes(2).ToString('o');reason='clean_session_end'
}
$oldServiceSuccess = [pscustomobject]@{
    eventCode=6;status='stopped';exitCode=0;utc=$now.AddMinutes(3).ToString('o')
}
if ((Get-CleanupHealth $oldServiceSuccess $oldReceipt $oldReceipt $guard).health -ne 'unverified') {
    throw 'A mismatched receipt or old service success hid an unverified previous exit.'
}
if ((Get-CleanupHealth $null $null $null $guard).health -ne 'unverified') {
    throw 'A missing current receipt did not use the guard previousExit health.'
}
$legacyReceipt = [pscustomobject]@{success=$true;completedAtUtc=$now.AddMinutes(4).ToString('o');reason='legacy_success'}
if ((Get-CleanupHealth $null $null $legacyReceipt $guard).health -ne 'unverified') {
    throw 'A legacy receipt without instanceId was treated as verified.'
}
$currentSuccess = [pscustomobject]@{
    version=2;instanceId='current-instance';success=$true
    completedAtUtc=$now.AddMinutes(5).ToString('o');reason='clean_tray_exit'
}
if ((Get-CleanupHealth $null $null $currentSuccess $guard).health -ne 'verified') {
    throw 'A successful receipt for the current guard instance was not recognized.'
}
$currentFailure = [pscustomobject]@{
    version=2;instanceId='current-instance';success=$false
    completedAtUtc=$now.AddMinutes(6).ToString('o');reason='cleanup_deadline_exceeded'
}
if ((Get-CleanupHealth $oldServiceSuccess $null $currentFailure $guard).health -ne 'failed') {
    throw 'A failed receipt for the current guard instance was not recognized.'
}
$verifiedPrevious = [pscustomobject]@{
    health='verified';reason='clean_session_end';instanceId='previous-instance'
    completedAtUtc=$now.AddMinutes(1).ToString('o');observedAtUtc=$now.AddMinutes(1).ToString('o')
}
$verifiedGuard = [pscustomobject]@{version=2;instanceId='current-instance';previousExit=$verifiedPrevious}
$newServiceFailure = [pscustomobject]@{
    eventCode=6;status='stopped';exitCode=1;utc=$now.AddMinutes(7).ToString('o')
}
if ((Get-CleanupHealth $newServiceFailure $null $null $verifiedGuard).health -ne 'failed') {
    throw 'A newer service failure was hidden by a verified guard exit.'
}
$unknownGuard = [pscustomobject]@{
    version=2;instanceId='first-instance'
    previousExit=[pscustomobject]@{health='unknown';reason='no_previous_guard';instanceId=$null;observedAtUtc=$now.ToString('o')}
}
if ((Get-CleanupHealth $null $null $null $unknownGuard).health -ne 'unknown') {
    throw 'The first guard start was not reported as unknown.'
}
if ((Get-EffectiveRelayStatus $state $helper $true $true $now 'unknown') -ne 'ready') {
    throw 'Unknown first-start cleanup state was treated as a warning.'
}
if ((Get-EffectiveRelayStatus $state $helper $true $true $now 'unverified') -ne 'ready_cleanup_warning') {
    throw 'Unverified previous cleanup was not surfaced as a warning.'
}
$legacyGuard = [pscustomobject]@{version=1;pid=123}
if ((Get-CleanupHealth $null $null $legacyReceipt $legacyGuard).health -ne 'unverified') {
    throw 'A legacy guard without instanceId was treated as verified.'
}
$stopAst = $ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Stop-Relay'}, $true)
if ($stopAst.Extent.Text -match 'Stop-ScheduledTask\s+-TaskName\s+\$userTaskName') {
    throw 'Stop-Relay must let the tray host exit naturally.'
}
if ($stopAst.Extent.Text -notmatch 'Get-ScheduledTask') { throw 'Stop-Relay must wait for the user task to exit.' }
Write-Output '12 guard correlation checks passed.'
