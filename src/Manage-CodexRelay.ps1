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
function Get-EffectiveRelayStatus($State, $Helper, [bool]$Live, [bool]$OwnedMappingPresent, [DateTime]$NowUtc) {
    if (-not $Live) {
        if ($OwnedMappingPresent) { return 'cleanup_pending' }
        return 'stopped'
    }
    if (($NowUtc - (Convert-ManagedUtc $State.updatedAt)).TotalSeconds -gt 90) { return 'status_stale' }
    if ($State.status -ne 'ready') { return [string]$State.status }
    if (-not $Helper -or $Helper.status -ne 'mapped' -or $Helper.relayPid -ne $State.pid -or -not $OwnedMappingPresent) { return 'waiting_mapping' }
    if (($NowUtc - (Convert-ManagedUtc $Helper.updatedAtUtc)).TotalSeconds -gt 150) { return 'maintenance_stale' }
    return 'ready'
}
function Stop-Relay {
    $state = Read-State
    $requestedPid = if ($state -and $state.pid) { [int]$state.pid } else { 0 }
    if (Test-Path -LiteralPath $settings.stateDirectory) {
        @{pid=$requestedPid;requestedAt=[DateTime]::UtcNow.ToString('o')} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $settings.stateDirectory 'stop.json') -Encoding ASCII
    }
    if (Test-StateProcess $state) {
        $deadline = (Get-Date).AddSeconds(25)
        do {
            Start-Sleep -Milliseconds 300
            $state = Read-State
            if ($state.status -eq 'stopped') { break }
        } while ((Get-Date) -lt $deadline)
        if ($state.status -ne 'stopped') { throw 'The relay did not confirm a clean stop. Inspect Status; no unrelated process was killed.' }
    }
    Stop-ScheduledTask -TaskName $userTaskName -ErrorAction SilentlyContinue
    Start-ScheduledTask -TaskName $helperTaskName
    # Cleanup is asynchronous; verify the observable hosts result before claiming success.
    $deadline = (Get-Date).AddSeconds(15)
    $hostsFile = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    do {
        if ([IO.File]::ReadAllText($hostsFile) -notmatch 'CODEX-DURABLE-RELAY-V2') { return }
        Start-Sleep -Milliseconds 300
    } while ((Get-Date) -lt $deadline)
    throw 'Relay stopped but hosts cleanup is not confirmed. Inspect Status or run the protected cleanup as administrator.'
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
        if ($effectiveStatus -eq 'ready' -and (-not $lifecycle -or $lifecycle.Status -ne 'Running')) { $effectiveStatus = 'lifecycle_unavailable' }
        $result = [ordered]@{ status=$effectiveStatus; loginAutostart=(@($task.Triggers | Where-Object Enabled).Count -gt 0); taskState=[string]$task.State; processAlive=$live; relay=$state; hostsMaintenance=$helper; lifecycleService=[string]$lifecycle.Status; lastLifecycleCleanup=$cleanup; note='TLS readiness does not prove authenticated WebSocket or message delivery.' }
        if ($AsJson) { $result | ConvertTo-Json -Depth 8 } else {
            $statusText = switch ($effectiveStatus) {
                'ready' { '已启用，TLS 检查通过' }
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
