[CmdletBinding()]
param(
    [ValidateSet('Initialize','Stop','SessionLogoff')][string]$Mode = 'Stop',
    [uint32]$SessionId = 0
)
$ErrorActionPreference = 'Stop'
$installRoot = 'C:\Program Files\CodexDurableRelay'
$userTaskName = 'Codex Durable Relay - User'
$flagPath = Join-Path $installRoot 'shutdown-request.flag'
$resultPath = Join-Path $installRoot 'lifecycle-cleanup-result.json'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $identity.IsSystem -and -not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Lifecycle cleanup requires the protected service or an administrator.' }
if ([IO.Path]::GetFullPath($PSScriptRoot) -ne $installRoot) { throw 'Lifecycle cleanup must run from the protected installation.' }
. (Join-Path $installRoot 'managed-hosts-lib.ps1')

function Test-RelaySessionOwner {
    param([uint32]$ExpectedSessionId, $Settings)
    $nodePath = Join-Path $installRoot 'node.exe'
    $relayPath = Join-Path $installRoot 'managed-relay.cjs'
    $candidates = @(Get-CimInstance Win32_Process -Filter ('Name=''node.exe'' AND SessionId=' + $ExpectedSessionId))
    foreach ($candidate in $candidates) {
        if ($candidate.ExecutablePath -ne $nodePath -or $candidate.SessionId -ne $ExpectedSessionId) { continue }
        if (-not (Test-ManagedRelayCommandLine -CommandLine $candidate.CommandLine -NodePath $nodePath -RelayScriptPath $relayPath)) { continue }
        $owner = Invoke-CimMethod -InputObject $candidate -MethodName GetOwnerSid
        if ($owner.ReturnValue -eq 0 -and $owner.Sid -eq $Settings.ownerSid) { return $true }
    }
    return $false
}

function Write-LifecycleResult($Record) {
    $tempPath = Join-Path $installRoot ('lifecycle-cleanup-result.' + $PID + '.tmp')
    try {
        [IO.File]::WriteAllText($tempPath, ($Record | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $resultPath) { [IO.File]::Replace($tempPath,$resultPath,$null) }
        else { [IO.File]::Move($tempPath,$resultPath) }
    } catch { }
}

$result = [ordered]@{version=1;mode=$Mode;sessionId=$SessionId;startedAtUtc=[DateTime]::UtcNow.ToString('o');success=$false;reason='starting';taskStopped=$false;mappingRemoved=$false}
$exitCode = 1
$flagCreated = $false
try {
    if ($Mode -eq 'Initialize') {
        $resultPath = Join-Path $installRoot 'lifecycle-initialize-result.json'
        if (Test-Path -LiteralPath $flagPath) { Remove-Item -LiteralPath $flagPath -Force }
        $result.success = $true
        $result.reason = 'initialized'
        $exitCode = 0
    } else {
        $settings = Get-Content -LiteralPath (Join-Path $installRoot 'settings.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $applicable = $Mode -eq 'Stop' -or (Test-RelaySessionOwner -ExpectedSessionId $SessionId -Settings $settings)
        if (-not $applicable) {
            $resultPath = Join-Path $installRoot 'lifecycle-session-check.json'
            # Another session logging off must not stop this user's live relay.
            # Reconcile still removes an orphan if the target process already exited.
            & (Join-Path $installRoot 'managed-relay-hosts.ps1')
            if ($LASTEXITCODE -ne 0) { throw 'reconcile_failed' }
            $result.success = $true
            $result.reason = 'unrelated_or_already_ended_session'
            $exitCode = 0
        } else {
            [IO.File]::WriteAllText($flagPath, [DateTime]::UtcNow.ToString('o'), [Text.Encoding]::ASCII)
            $flagCreated = $true
            # The protected flag stops admission/retries without reading user files.
            $deadline = [DateTime]::UtcNow.AddSeconds(10)
            do {
                $task = Get-ScheduledTask -TaskName $userTaskName
                $expectedExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
                $expectedArgs = '-NoProfile -NonInteractive -WindowStyle Hidden -File "C:\Program Files\CodexDurableRelay\Launch-ManagedRelay.ps1"'
                if (@($task.Actions).Count -ne 1 -or $task.Actions.Execute -ne $expectedExe -or $task.Actions.Arguments -ne $expectedArgs) { throw 'task_identity_mismatch' }
                if ($task.State -ne 'Running') { break }
                Start-Sleep -Milliseconds 250
            } while ([DateTime]::UtcNow -lt $deadline)
            if ($task.State -eq 'Running') { Stop-ScheduledTask -TaskName $userTaskName }
            $deadline = [DateTime]::UtcNow.AddSeconds(2)
            do {
                $task = Get-ScheduledTask -TaskName $userTaskName
                if ($task.State -ne 'Running') { break }
                Start-Sleep -Milliseconds 200
            } while ([DateTime]::UtcNow -lt $deadline)
            $result.taskStopped = $task.State -ne 'Running'
            & (Join-Path $installRoot 'managed-relay-hosts.ps1') -Cleanup
            if ($LASTEXITCODE -ne 0) { throw 'hosts_cleanup_failed' }
            $hosts = [IO.File]::ReadAllText((Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'))
            $result.mappingRemoved = -not $hosts.Contains('CODEX-DURABLE-RELAY-V2')
            $result.success = $result.taskStopped -and $result.mappingRemoved
            $result.reason = if ($result.success) { 'clean_stop' } else { 'stop_unconfirmed' }
            $exitCode = if ($result.success) { 0 } else { 1 }
        }
    }
} catch {
    $allowedReasons = @('reconcile_failed','task_identity_mismatch','hosts_cleanup_failed')
    $result.reason = if ($_.Exception.Message -in $allowedReasons) { $_.Exception.Message } else { 'lifecycle_cleanup_failed' }
    # Even when task control is unavailable, prevent a stale route at shutdown.
    if ($flagCreated) {
        try {
            & (Join-Path $installRoot 'managed-relay-hosts.ps1') -Cleanup
            $result.mappingRemoved = $LASTEXITCODE -eq 0
        } catch { }
    }
} finally {
    # Logoff is followed by another login without necessarily restarting services.
    if ($Mode -eq 'SessionLogoff' -and $flagCreated) {
        try { Remove-Item -LiteralPath $flagPath -Force -ErrorAction Stop } catch { $result.success=$false; $result.reason='flag_cleanup_failed'; $exitCode=1 }
    }
    $result.completedAtUtc = [DateTime]::UtcNow.ToString('o')
    Write-LifecycleResult $result
}
exit $exitCode
