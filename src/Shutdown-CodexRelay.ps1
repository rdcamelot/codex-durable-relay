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

function Test-RelayLauncherCommandLine {
    param(
        [Parameter(Mandatory = $true)][string]$CommandLine,
        [Parameter(Mandatory = $true)][string]$PowerShellPath,
        [Parameter(Mandatory = $true)][string]$LauncherScriptPath
    )
    $powerShell = [Regex]::Escape($PowerShellPath)
    $launcher = [Regex]::Escape($LauncherScriptPath)
    $pattern = '^\s*(?:"' + $powerShell + '"|' + $powerShell + ')\s+-NoProfile\s+-NonInteractive\s+-WindowStyle\s+Hidden\s+-File\s+"' + $launcher + '"\s*$'
    return [Regex]::IsMatch($CommandLine, $pattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
}

function Test-RelayTrayHostCommandLine {
    param(
        [Parameter(Mandatory = $true)][string]$CommandLine,
        [Parameter(Mandatory = $true)][string]$TrayHostPath
    )
    $trayHost = [Regex]::Escape($TrayHostPath)
    $pattern = '^\s*(?:"' + $trayHost + '"|' + $trayHost + ')\s*$'
    return [Regex]::IsMatch($CommandLine, $pattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
}

function Get-RelayProcessState {
    param([Parameter(Mandatory = $true)]$Settings)
    $nodePath = Join-Path $installRoot 'node.exe'
    $relayPath = Join-Path $installRoot 'managed-relay.cjs'
    $powerShellPath = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
    $launcherPath = Join-Path $installRoot 'Launch-ManagedRelay.ps1'
    $trayHostPath = Join-Path $installRoot 'CodexRelayTrayHost.exe'
    $processFilter = "Name='node.exe' OR Name='powershell.exe' OR Name='CodexRelayTrayHost.exe'"
    $ownerSid = [string]$Settings.ownerSid
    if ([string]::IsNullOrWhiteSpace($ownerSid)) { return [pscustomobject]@{State='Unknown';Reason='owner_identity_unavailable'} }
    $uncertain = $false
    try { $candidates = @(Get-CimInstance Win32_Process -Filter $processFilter -ErrorAction Stop) }
    catch { return [pscustomobject]@{State='Unknown';Reason='process_query_failed'} }
    foreach ($candidate in $candidates) {
        $path = [string]$candidate.ExecutablePath
        if ([string]::IsNullOrWhiteSpace($path)) {
            $uncertain = $true
            continue
        }
        $kind = if ([String]::Equals($path,$nodePath,[StringComparison]::OrdinalIgnoreCase)) { 'node' }
            elseif ([String]::Equals($path,$powerShellPath,[StringComparison]::OrdinalIgnoreCase)) { 'launcher' }
            elseif ([String]::Equals($path,$trayHostPath,[StringComparison]::OrdinalIgnoreCase)) { 'tray' }
            else { $null }
        if (-not $kind) { continue }
        $commandLine = [string]$candidate.CommandLine
        if ([string]::IsNullOrWhiteSpace($commandLine)) { $uncertain = $true; continue }
        $isFixed = if ($kind -eq 'node') {
            Test-ManagedRelayCommandLine -CommandLine $commandLine -NodePath $nodePath -RelayScriptPath $relayPath
        } elseif ($kind -eq 'launcher') {
            Test-RelayLauncherCommandLine -CommandLine $commandLine -PowerShellPath $powerShellPath -LauncherScriptPath $launcherPath
        } else {
            Test-RelayTrayHostCommandLine -CommandLine $commandLine -TrayHostPath $trayHostPath
        }
        if (-not $isFixed) { continue }
        try { $owner = Invoke-CimMethod -InputObject $candidate -MethodName GetOwnerSid -ErrorAction Stop }
        catch { $uncertain = $true; continue }
        if ($null -eq $owner -or $owner.ReturnValue -ne 0 -or [string]::IsNullOrWhiteSpace([string]$owner.Sid)) {
            $uncertain = $true
            continue
        }
        if ([String]::Equals([string]$owner.Sid,$ownerSid,[StringComparison]::OrdinalIgnoreCase)) {
            return [pscustomobject]@{State='Present';Reason='fixed_process_running'}
        }
    }
    if ($uncertain) { return [pscustomobject]@{State='Unknown';Reason='process_identity_unavailable'} }
    return [pscustomobject]@{State='Absent';Reason='fixed_processes_absent'}
}

function Get-RelayListenerState {
    try {
        $listeners = @(Get-NetTCPConnection -State Listen -ErrorAction Stop | Where-Object {
                $_.LocalAddress -eq '127.0.0.2' -and $_.LocalPort -eq 443
            })
    } catch { return [pscustomobject]@{State='Unknown';Reason='listener_query_failed'} }
    if ($listeners.Count -gt 0) { return [pscustomobject]@{State='Present';Reason='relay_listener_running'} }
    return [pscustomobject]@{State='Absent';Reason='relay_listener_absent'}
}

function Test-RelayTermination {
    param([Parameter(Mandatory = $true)]$Settings)
    $deadline = [DateTime]::UtcNow.AddSeconds(2)
    do {
        $listener = Get-RelayListenerState
        $processes = Get-RelayProcessState -Settings $Settings
        if ($listener.State -eq 'Absent' -and $processes.State -eq 'Absent') { return $true }
        if ([DateTime]::UtcNow -ge $deadline) { return $false }
        Start-Sleep -Milliseconds 200
    } while ($true)
}

function Write-LifecycleResult($Record) {
    $tempPath = Join-Path $installRoot ('lifecycle-cleanup-result.' + $PID + '.tmp')
    try {
        [IO.File]::WriteAllText($tempPath, ($Record | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $resultPath) { [IO.File]::Replace($tempPath,$resultPath,[NullString]::Value) }
        else { [IO.File]::Move($tempPath,$resultPath) }
        return $true
    } catch { return $false }
}

$result = [ordered]@{version=2;mode=$Mode;sessionId=$SessionId;startedAtUtc=[DateTime]::UtcNow.ToString('o');success=$false;reason='starting';phase='initializing';taskStopped=$false;mappingRemoved=$false}
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
            $result.phase = 'set_barrier'
            [void](Write-LifecycleResult $result)
            [IO.File]::WriteAllText($flagPath, [DateTime]::UtcNow.ToString('o'), [Text.Encoding]::ASCII)
            $flagCreated = $true
            # The protected flag stops admission/retries without reading user files.
            $deadline = [DateTime]::UtcNow.AddSeconds(10)
            $result.phase = 'wait_for_task'
            [void](Write-LifecycleResult $result)
            do {
                $task = Get-ScheduledTask -TaskName $userTaskName
                $expectedExe = Join-Path $installRoot 'CodexRelayTrayHost.exe'
                $expectedArgs = ''
                $actualArgs = [string]$task.Actions.Arguments
                if (@($task.Actions).Count -ne 1 -or $task.Actions.Execute -ne $expectedExe -or $actualArgs -ne $expectedArgs -or $task.Actions.WorkingDirectory -ne $installRoot) { throw 'task_identity_mismatch' }
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
            $result.phase = 'remove_mapping'
            [void](Write-LifecycleResult $result)
            & (Join-Path $installRoot 'managed-relay-hosts.ps1') -Cleanup
            if ($LASTEXITCODE -ne 0) { throw 'hosts_cleanup_failed' }
            $hosts = [IO.File]::ReadAllText((Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'))
            $result.mappingRemoved = -not $hosts.Contains('CODEX-DURABLE-RELAY-V2')
            $result.phase = 'verify_termination'
            [void](Write-LifecycleResult $result)
            if ($result.taskStopped -and $result.mappingRemoved -and (Test-RelayTermination -Settings $settings)) {
                $result.success = $true
                $result.reason = 'clean_stop'
            } else {
                $result.success = $false
                $result.reason = if ($result.taskStopped -and $result.mappingRemoved) { 'processes_still_running' } else { 'stop_unconfirmed' }
            }
            $exitCode = if ($result.success) { 0 } else { 1 }
        }
    }
} catch {
    $allowedReasons = @('reconcile_failed','task_identity_mismatch','hosts_cleanup_failed','processes_still_running')
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
    if (-not (Write-LifecycleResult $result)) { $exitCode=1 }
}
exit $exitCode
