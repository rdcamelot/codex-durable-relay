[CmdletBinding()]
param(
    [ValidateSet('Start','Stop','Status','EnableAutostart','DisableAutostart','Uninstall')][string]$Action = 'Status',
    [switch]$AsJson
)
$ErrorActionPreference = 'Stop'
$userTaskName = 'Codex Durable Relay - User'
$helperTaskName = 'Codex Durable Relay - Hosts'
$settings = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'settings.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$statePath = Join-Path $settings.stateDirectory 'status.json'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)

function Read-State {
    try { Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json } catch { $null }
}
function Convert-ManagedUtc($Value) {
    if ($Value -is [DateTime]) { return $Value.ToUniversalTime() }
    return [DateTime]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
}
function Test-StateProcess($State) {
    if (-not $State -or -not $State.pid) { return $false }
    $candidate = Get-Process -Id ([int]$State.pid) -ErrorAction SilentlyContinue
    if (-not $candidate) { return $false }
    return [Math]::Abs(($candidate.StartTime.ToUniversalTime() - (Convert-ManagedUtc $State.startedAt)).TotalSeconds) -lt 10
}
function Get-EffectiveRelayStatus($State, $Helper, [bool]$Live, [bool]$OwnedMappingPresent, [DateTime]$NowUtc, [string]$CleanupHealth = 'unknown') {
    if (-not $Live) {
        if ($OwnedMappingPresent) { return 'cleanup_pending' }
        return 'stopped'
    }
    if (($NowUtc - (Convert-ManagedUtc $State.updatedAt)).TotalSeconds -gt 90) { return 'status_stale' }
    if ($State.status -ne 'ready') { return [string]$State.status }
    if (-not $Helper -or $Helper.status -ne 'mapped' -or $Helper.relayPid -ne $State.pid -or -not $OwnedMappingPresent) { return 'waiting_mapping' }
    if (($NowUtc - (Convert-ManagedUtc $Helper.updatedAtUtc)).TotalSeconds -gt 150) { return 'maintenance_stale' }
    if ($CleanupHealth -in @('failed','incomplete','unverified','guard_unavailable')) { return 'ready_cleanup_warning' }
    return 'ready'
}
function Get-CleanupHealth($Operation, $Receipt, $SessionReceipt, $Guard) {
    $serviceObservations = @()
    if ($Operation -and [int]$Operation.eventCode -ne 0) {
        $health = if ($Operation.status -eq 'stopped' -or $Operation.status -eq 'session_logoff_complete') {
            if ([int]$Operation.exitCode -eq 0) { 'verified' } else { 'failed' }
        } else { 'incomplete' }
        $operationTime = if ($Operation.utc) { Convert-ManagedUtc $Operation.utc } else { $null }
        $serviceObservations += [pscustomobject]@{time=$operationTime;health=$health;source='service';reason=('exit_' + $Operation.exitCode)}
    }
    if ($Receipt) {
        $timestamp = if ($Receipt.completedAtUtc) { $Receipt.completedAtUtc } else { $Receipt.startedAtUtc }
        if ($timestamp) {
            $health = if (-not $Receipt.completedAtUtc) { 'incomplete' } elseif ($Receipt.success) { 'verified' } else { 'failed' }
            $serviceObservations += [pscustomobject]@{time=(Convert-ManagedUtc $timestamp);health=$health;source='service_receipt';reason=$Receipt.reason}
        }
    }

    # A v2 guard is the authority for user-session cleanup. Its current
    # receipt is valid only when the process instance ids match. A stale or
    # legacy receipt must never look like a successful current exit.
    $guardObservation = $null
    if ($null -ne $Guard) {
        $guardInstanceId = [string]$Guard.instanceId
        $sessionInstanceId = if ($SessionReceipt) { [string]$SessionReceipt.instanceId } else { '' }
        $hasCurrentInstance = -not [string]::IsNullOrWhiteSpace($guardInstanceId)
        $hasSessionInstance = -not [string]::IsNullOrWhiteSpace($sessionInstanceId)
        if ($hasCurrentInstance -and $hasSessionInstance -and $sessionInstanceId -eq $guardInstanceId) {
            $timestamp = if ($SessionReceipt.completedAtUtc) { $SessionReceipt.completedAtUtc } else { $SessionReceipt.startedAtUtc }
            if ($timestamp) {
                $health = if (-not $SessionReceipt.completedAtUtc) { 'incomplete' } elseif ($SessionReceipt.success) { 'verified' } else { 'failed' }
                $guardObservation = [pscustomobject]@{time=(Convert-ManagedUtc $timestamp);health=$health;source='session_guard';reason=$SessionReceipt.reason;instanceId=$sessionInstanceId}
            } else {
                $guardObservation = [pscustomobject]@{time=$null;health='incomplete';source='session_guard';reason='session_receipt_missing_timestamp';instanceId=$sessionInstanceId}
            }
        } elseif ($SessionReceipt -and $hasCurrentInstance -and -not $hasSessionInstance) {
            $timestamp = if ($SessionReceipt.completedAtUtc) { $SessionReceipt.completedAtUtc } else { $SessionReceipt.startedAtUtc }
            $guardObservation = [pscustomobject]@{time=$(if ($timestamp) { Convert-ManagedUtc $timestamp } else { $null });health='unverified';source='session_guard';reason='session_receipt_instance_id_missing'}
        } elseif (-not $hasCurrentInstance) {
            # A status file from the old guard has no way to bind its receipt
            # to a process. Treat it as an unverified previous exit.
            $guardObservation = [pscustomobject]@{time=$null;health='unverified';source='session_guard';reason='guard_instance_id_missing'}
        } elseif ($Guard.previousExit) {
            $previous = $Guard.previousExit
            $health = [string]$previous.health
            if ($health -notin @('verified','failed','incomplete','unverified','unknown')) { $health = 'unverified' }
            $timestamp = if ($previous.completedAtUtc) { $previous.completedAtUtc } else { $previous.observedAtUtc }
            $guardObservation = [pscustomobject]@{time=$(if ($timestamp) { Convert-ManagedUtc $timestamp } else { $null });health=$health;source='guard_previous';reason=$previous.reason;instanceId=$previous.instanceId}
        } else {
            # A malformed v2 status is evidence that the previous exit could
            # not be correlated. A valid first-run status carries unknown in
            # previousExit and therefore does not take this branch.
            $guardObservation = [pscustomobject]@{time=$null;health='unverified';source='guard_previous';reason='previous_exit_missing'}
        }
    }
    if ($null -eq $Guard) {
        $observations = @($serviceObservations)
        if ($SessionReceipt) {
            $timestamp = if ($SessionReceipt.completedAtUtc) { $SessionReceipt.completedAtUtc } else { $SessionReceipt.startedAtUtc }
            if ($timestamp) {
                $health = if (-not $SessionReceipt.completedAtUtc) { 'incomplete' } elseif ($SessionReceipt.success) { 'verified' } else { 'failed' }
                $observations += [pscustomobject]@{time=(Convert-ManagedUtc $timestamp);health=$health;source='session_guard';reason=$SessionReceipt.reason}
            }
        }
        $latest = $observations | Sort-Object time -Descending | Select-Object -First 1
        if ($latest) { return $latest }
        return [pscustomobject]@{time=$null;health='unknown';source=$null;reason='no_cleanup_receipt'}
    }

    if ($guardObservation) {
        # A verified service receipt is not proof that the user guard cleaned
        # up this instance. A later service failure remains actionable, even
        # when the guard has a successful or unverified previous-exit record.
        foreach ($service in $serviceObservations) {
            $newer = (-not $guardObservation.time) -or ($service.time -and $service.time -gt $guardObservation.time)
            if ($newer -and $service.health -in @('failed','incomplete')) {
                $guardObservation = $service
            }
        }
        return $guardObservation
    }
    if ($serviceObservations) {
        return ($serviceObservations | Sort-Object time -Descending | Select-Object -First 1)
    }
    return [pscustomobject]@{time=$null;health='unknown';source=$null;reason='no_cleanup_receipt'}
}
function Test-SessionGuardAlive($Guard) {
    if (-not $Guard -or -not $Guard.pid -or -not $Guard.windowHandle -or -not $Guard.prioritySet) { return $false }
    try {
        $process = Get-Process -Id ([int]$Guard.pid) -ErrorAction Stop
        if (-not ('RelaySessionGuard' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'RelaySessionGuard.dll') }
        return [Math]::Abs(($process.StartTime.ToUniversalTime() - (Convert-ManagedUtc $Guard.processStartedAtUtc)).TotalSeconds) -lt 1 -and [RelaySessionGuard]::IsWindowForProcess([long]$Guard.windowHandle,[int]$Guard.pid)
    } catch { return $false }
}
function Test-ManagedTaskStopped([string]$TaskName) {
    try {
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
        return [string]$task.State -ne 'Running'
    } catch {
        # A removed task cannot be holding the tray host open.
        return $true
    }
}
function Stop-Relay {
    $state = Read-State
    $requestedPid = if ($state -and $state.pid) { [int]$state.pid } else { 0 }
    if (Test-Path -LiteralPath $settings.stateDirectory) {
        @{pid=$requestedPid;requestedAt=[DateTime]::UtcNow.ToString('o')} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $settings.stateDirectory 'stop.json') -Encoding ASCII
    }
    $relayWasAlive = Test-StateProcess $state
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    $relayStopped = -not $relayWasAlive
    $taskStopped = Test-ManagedTaskStopped $userTaskName
    do {
        $state = Read-State
        $relayExited = -not (Test-StateProcess $state)
        $relayStopped = (-not $relayWasAlive) -or ($relayExited -and (-not $state -or $state.status -eq 'stopped'))
        $taskStopped = Test-ManagedTaskStopped $userTaskName
        if ($relayStopped -and $taskStopped) { break }
        Start-Sleep -Milliseconds 300
    } while ([DateTime]::UtcNow -lt $deadline)
    if (-not $relayStopped) { throw 'Relay stop request timed out waiting for the relay to exit cleanly; the tray host was left running for retry.' }
    if (-not $taskStopped) { throw 'Relay stop request timed out waiting for the tray host task to exit; it was left running for retry.' }

    # The launcher normally starts maintenance in its finally block. Trigger
    # it only after the tray host has exited, so its cleanup cannot race the
    # guard's natural shutdown.
    try {
        $helperTask = Get-ScheduledTask -TaskName $helperTaskName -ErrorAction Stop
        if ([string]$helperTask.State -ne 'Running') { Start-ScheduledTask -TaskName $helperTaskName -ErrorAction SilentlyContinue }
    } catch { }
    # Cleanup is asynchronous; verify the observable hosts result before claiming success.
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    $hostsFile = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    do {
        try {
            if ([IO.File]::ReadAllText($hostsFile) -notmatch 'CODEX-DURABLE-RELAY-V2') { return }
        } catch { }
        Start-Sleep -Milliseconds 300
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'Relay and tray host exited, but hosts cleanup did not finish before the deadline; no task was killed, so inspect Status and retry.'
}

if ($Action -in @('EnableAutostart','DisableAutostart','Uninstall') -and -not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    # Uninstall performs fixed-path shutdown in its elevated phase. Do not
    # require a user-state stop or existing tasks before retrying partial removal.
    $elevated = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -Verb RunAs -WindowStyle Hidden -ArgumentList ('-NoProfile -NonInteractive -File "' + $PSCommandPath + '" -Action ' + $Action) -Wait -PassThru
    exit $elevated.ExitCode
}
switch ($Action) {
    'Start' {
        if ($identity.User.Value -ne $settings.ownerSid) { throw 'Run Start as the configured Windows user.' }
        Start-ScheduledTask -TaskName $userTaskName
        Write-Output 'Start requested. The relay waits for the proxy; use Status to inspect readiness.'
    }
    'Stop' {
        if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run Stop without elevation; control files belong to the ordinary user.' }
        Stop-Relay
        Write-Output 'Relay stopped. Login autostart is unchanged; use DisableAutostart to disable it.'
    }
    'EnableAutostart' {
        $task = Get-ScheduledTask -TaskName $userTaskName
        $triggers = @($task.Triggers)
        foreach ($trigger in $triggers) { $trigger.Enabled = $true }
        Set-ScheduledTask -TaskName $userTaskName -Trigger $triggers | Out-Null
        Write-Output 'Login autostart enabled. Start manually to enable it in this session.'
    }
    'DisableAutostart' {
        $task = Get-ScheduledTask -TaskName $userTaskName
        $triggers = @($task.Triggers)
        foreach ($trigger in $triggers) { $trigger.Enabled = $false }
        Set-ScheduledTask -TaskName $userTaskName -Trigger $triggers | Out-Null
        Write-Output 'Login autostart disabled. Current relay and manual Start remain available.'
    }
    'Status' {
        $state = Read-State
        $helper = try { Get-Content -LiteralPath (Join-Path $PSScriptRoot 'helper-status.json') -Raw | ConvertFrom-Json } catch { $null }
        $task = Get-ScheduledTask -TaskName $userTaskName
        $live = Test-StateProcess $state
        $ownedMappingPresent = [IO.File]::ReadAllText((Join-Path $env:SystemRoot 'System32\drivers\etc\hosts')).Contains('127.0.0.2 codex-cloud-backend.chatgpt.com # CODEX-DURABLE-RELAY-V2')
        $effectiveStatus = Get-EffectiveRelayStatus $state $helper $live $ownedMappingPresent ([DateTime]::UtcNow)
        $lifecycle = Get-Service -Name 'CodexDurableRelayLifecycle' -ErrorAction SilentlyContinue
        $cleanup = try { Get-Content -LiteralPath (Join-Path $PSScriptRoot 'lifecycle-cleanup-result.json') -Raw | ConvertFrom-Json } catch { $null }
        $operation = try { Get-Content -LiteralPath (Join-Path $PSScriptRoot 'lifecycle-last-operation.json') -Raw | ConvertFrom-Json } catch { $null }
        if (-not $operation) { $operation = try { Get-Content -LiteralPath (Join-Path $PSScriptRoot 'lifecycle-service-status.json') -Raw | ConvertFrom-Json } catch { $null } }
        $sessionReceipt = try { Get-Content -LiteralPath (Join-Path $settings.stateDirectory 'session-end-result.json') -Raw | ConvertFrom-Json } catch { $null }
        $guard = try { Get-Content -LiteralPath (Join-Path $settings.stateDirectory 'session-guard-status.json') -Raw | ConvertFrom-Json } catch { $null }
        $guardAlive = Test-SessionGuardAlive $guard
        $cleanupHealth = Get-CleanupHealth $operation $cleanup $sessionReceipt $guard
        $health = if ($live -and -not $guardAlive) { 'guard_unavailable' } else { $cleanupHealth.health }
        $effectiveStatus = Get-EffectiveRelayStatus $state $helper $live $ownedMappingPresent ([DateTime]::UtcNow) $health
        if ($effectiveStatus -eq 'ready' -and (-not $lifecycle -or $lifecycle.Status -ne 'Running')) { $effectiveStatus = 'lifecycle_unavailable' }
        $result = [ordered]@{ status=$effectiveStatus; loginAutostart=(@($task.Triggers | Where-Object Enabled).Count -gt 0); taskState=[string]$task.State; processAlive=$live; relay=$state; hostsMaintenance=$helper; lifecycleService=[string]$lifecycle.Status; lastLifecycleCleanup=$cleanup; lastLifecycleOperation=$operation; sessionGuardAlive=$guardAlive; sessionGuardStatus=$guard; previousExit=$(if ($guard) { $guard.previousExit } else { $null }); lastSessionCleanup=$sessionReceipt; cleanupHealth=$cleanupHealth; note='TLS readiness does not prove authenticated WebSocket or message delivery.' }
        if ($AsJson) { $result | ConvertTo-Json -Depth 8 } else {
            $statusText = switch ($effectiveStatus) {
                'ready' { '已启用，TLS 检查通过' }
                'ready_cleanup_warning' { if ($cleanupHealth.health -eq 'unverified') { '网络已启用，但上次运行退出清理未确认，请检查下方记录' } else { '网络已启用，但退出清理有异常，请检查下方记录' } }
                'waiting_proxy' { '等待 Clash 或上游连接恢复' }
                'degraded' { '连接异常，正在等待恢复' }
                'waiting_mapping' { '正在等待域名映射；若持续出现，请查看维护状态' }
                'maintenance_stale' { '维护任务状态过期，需检查计划任务' }
                'lifecycle_unavailable' { '网络中继可用，但关机清理服务未运行' }
                'status_stale' { '中继状态更新超时，需检查进程' }
                'cleanup_pending' { '中继已退出，等待清理域名映射' }
                'blocked' { '监听端口不可用，暂未启用' }
                'stopping' { '正在停止' }
                default { '已停止' }
            }
            Write-Output ('状态：' + $statusText)
            Write-Output ('登录自动启动：' + $(if ($result.loginAutostart) { '已启用' } else { '已关闭' }))
            Write-Output ('关机清理服务：' + $(if ($lifecycle.Status -eq 'Running') { '运行中' } else { '未运行' }))
            Write-Output ('用户会话退出保护：' + $(if ($guardAlive) { '运行中' } else { '未运行' }))
            Write-Output ('最近退出清理：' + $cleanupHealth.health + ' / ' + $cleanupHealth.reason)
            if ($cleanupHealth.time) { Write-Output ('清理记录时间：' + $cleanupHealth.time.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss')) }
            if ($state.tlsVerifiedAt) { Write-Output ('最近 TLS 检查成功：' + (Convert-ManagedUtc $state.tlsVerifiedAt).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss')) }
            if ($helper.status -eq 'error') { Write-Output ('维护异常：' + $helper.reason) }
            Write-Output ('诊断记录：' + $settings.stateDirectory)
            Write-Output 'TLS 检查不代表云端会话或消息发送一定成功。'
        }
    }
    'Uninstall' {
        $expectedRoot = [IO.Path]::GetFullPath((Join-Path $env:ProgramFiles 'CodexDurableRelay'))
        $actualRoot = [IO.Path]::GetFullPath($PSScriptRoot)
        if ($actualRoot -ne $expectedRoot -or ((Get-Item -LiteralPath $actualRoot).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Unexpected install path; refusing removal.' }
        $lifecycle = Get-Service -Name 'CodexDurableRelayLifecycle' -ErrorAction SilentlyContinue
        if ($lifecycle) {
            Stop-Service -Name 'CodexDurableRelayLifecycle' -ErrorAction Stop
            $lifecycle.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Stopped, [TimeSpan]::FromSeconds(45))
            $lifecycle.Dispose()
        }
        Stop-ScheduledTask -TaskName $userTaskName -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
        if (Get-NetTCPConnection -LocalAddress 127.0.0.2 -LocalPort 443 -State Listen -ErrorAction SilentlyContinue) { throw 'A listener is still present; stop the relay as its ordinary user before uninstalling.' }
        Stop-ScheduledTask -TaskName $helperTaskName -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
        & (Join-Path $PSScriptRoot 'managed-relay-hosts.ps1') -Cleanup
        if ($LASTEXITCODE -ne 0) { throw 'Hosts cleanup did not confirm success; installation retained.' }
        foreach ($taskName in @($userTaskName,$helperTaskName)) {
            if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
                Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
            }
        }
        # Retain the safety service until hosts cleanup has succeeded. A locked
        # hosts file must leave the service and task registrations recoverable.
        if ($lifecycle) {
            & "$env:SystemRoot\System32\sc.exe" delete 'CodexDurableRelayLifecycle' | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'Lifecycle service removal failed; installation retained.' }
            $deadline = [DateTime]::UtcNow.AddSeconds(10)
            do {
                $remainingService = Get-Service -Name 'CodexDurableRelayLifecycle' -ErrorAction SilentlyContinue
                if (-not $remainingService) { break }
                $remainingService.Dispose()
                Start-Sleep -Milliseconds 200
            } while ([DateTime]::UtcNow -lt $deadline)
            if ($remainingService) { throw 'Lifecycle service deletion is pending; files retained. Close service management tools before retrying uninstall.' }
        }
        Remove-Item -LiteralPath $actualRoot -Recurse -Force
        Write-Output 'Uninstalled; user logs and control shortcuts were retained.'
    }
}
