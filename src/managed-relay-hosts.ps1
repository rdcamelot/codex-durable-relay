[CmdletBinding(DefaultParameterSetName = 'Reconcile')]
param(
    [Parameter(ParameterSetName = 'Reconcile')][switch]$Reconcile,
    [Parameter(ParameterSetName = 'Cleanup', Mandatory = $true)][switch]$Cleanup
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# This script is intended for a narrow SYSTEM scheduled task.  It obtains every
# executable and control value from the protected installation directory; it
# never reads relay PIDs, paths, or actions from a user-writable state file.
$installDirectory = 'C:\Program Files\CodexDurableRelay'
$settingsPath = Join-Path $installDirectory 'settings.json'
$hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$hostsBackupPath = Join-Path $installDirectory 'hosts-backup.bin'
. (Join-Path $PSScriptRoot 'managed-hosts-lib.ps1')

$statusValues = @('mapped', 'unmapped', 'error')
$reasonValues = @('mapping_added', 'mapping_present', 'mapping_removed', 'no_owned_mapping', 'foreign_mapping_untouched', 'listener_absent', 'listener_identity_mismatch', 'listener_query_failed', 'multiple_listeners', 'hosts_conflicting_mapping', 'hosts_modified_marker', 'hosts_null_bytes', 'hosts_duplicate_owned_mapping', 'hosts_missing_terminal_newline', 'hosts_too_large', 'hosts_locked', 'hosts_io_error', 'dns_cache_flush_failed', 'settings_invalid', 'post_write_identity_changed', 'internal_error')

function ConvertTo-ManagedFullPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    $fullPath = [IO.Path]::GetFullPath($Path)
    if ($fullPath.Length -gt 3) { $fullPath = $fullPath.TrimEnd('\') }
    return $fullPath
}

function Get-ManagedRelaySettings {
    if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) { throw 'settings_invalid' }
    try { $settings = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop } catch { throw 'settings_invalid' }
    foreach ($name in @('ownerSid', 'ownerName', 'stateDirectory')) {
        if ($null -eq $settings.PSObject.Properties[$name] -or [String]::IsNullOrWhiteSpace([string]$settings.$name)) { throw 'settings_invalid' }
    }
    try { [void](New-Object Security.Principal.SecurityIdentifier([string]$settings.ownerSid)) } catch { throw 'settings_invalid' }
    if (([string]$settings.ownerName).IndexOfAny([char[]]"`r`n") -ge 0) { throw 'settings_invalid' }
    try {
        $stateDirectory = ConvertTo-ManagedFullPath -Path ([string]$settings.stateDirectory)
        if (-not [IO.Path]::IsPathRooted($stateDirectory)) { throw 'settings_invalid' }
    } catch { throw 'settings_invalid' }
    return [pscustomobject]@{
        OwnerSid = [string]$settings.ownerSid
        OwnerName = [string]$settings.ownerName
        StateDirectory = $stateDirectory
        NodePath = (Join-Path $installDirectory 'node.exe')
        RelayScriptPath = (Join-Path $installDirectory 'managed-relay.cjs')
    }
}

function Write-ManagedHelperStatus {
    param(
        [Parameter(Mandatory = $true)][string]$Action,
        [Parameter(Mandatory = $true)][string]$Status,
        [Parameter(Mandatory = $true)][string]$Reason,
        [int]$RelayPid = 0
    )
    if ($statusValues -notcontains $Status -or $reasonValues -notcontains $Reason) { return $false }
    $record = [ordered]@{
        schemaVersion = 1
        updatedAtUtc = [DateTime]::UtcNow.ToString('o')
        action = $Action
        status = $Status
        reason = $Reason
    }
    if ($RelayPid -gt 0) { $record.relayPid = $RelayPid }
    # This file remains in the protected installation directory.  In
    # particular, stateDirectory is not a privileged output path; it is used by
    # the ordinary-user relay only and must never direct a SYSTEM write.
    $statusPath = Join-Path $installDirectory 'helper-status.json'
    try {
        [IO.File]::WriteAllText($statusPath, ($record | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
        return $true
    } catch {
        return $false
    }
}

function ConvertFrom-ManagedCimCreationDate {
    param([Parameter(Mandatory = $true)]$Value)
    if ($Value -is [DateTime]) { return $Value.ToUniversalTime() }
    return [Management.ManagementDateTimeConverter]::ToDateTime([string]$Value).ToUniversalTime()
}

function Test-ManagedRelayLauncherCommandLine {
    param(
        [Parameter(Mandatory = $true)][string]$CommandLine,
        [Parameter(Mandatory = $true)][string]$PowerShellPath,
        [Parameter(Mandatory = $true)][string]$LauncherScriptPath
    )
    # CIM may omit the PowerShell executable's outer quotes.  Everything after
    # it is fixed by the installed scheduled task: no profiles, no inherited
    # command text, and exactly the installed launcher script.
    $powerShell = [Regex]::Escape($PowerShellPath)
    $launcher = [Regex]::Escape($LauncherScriptPath)
    $pattern = '^\s*(?:"' + $powerShell + '"|' + $powerShell + ')\s+-NoProfile\s+-NonInteractive\s+-WindowStyle\s+Hidden\s+-File\s+"' + $launcher + '"\s*$'
    return [Regex]::IsMatch($CommandLine, $pattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
}

function Get-ManagedRelayIdentity {
    param(
        [Parameter(Mandatory = $true)][int]$ProcessId,
        [Parameter(Mandatory = $true)]$Settings
    )
    $launcherPath = Join-Path $installDirectory 'Launch-ManagedRelay.ps1'
    $powerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $Settings.NodePath -PathType Leaf) -or -not (Test-Path -LiteralPath $Settings.RelayScriptPath -PathType Leaf) -or -not (Test-Path -LiteralPath $launcherPath -PathType Leaf)) { return $null }
    try {
        $cim = Get-CimInstance Win32_Process -Filter ('ProcessId = ' + $ProcessId) -ErrorAction Stop
        if ($null -eq $cim -or [String]::IsNullOrWhiteSpace([string]$cim.ExecutablePath) -or [String]::IsNullOrWhiteSpace([string]$cim.CommandLine)) { return $null }
        if (-not [String]::Equals((ConvertTo-ManagedFullPath -Path $cim.ExecutablePath), (ConvertTo-ManagedFullPath -Path $Settings.NodePath), [StringComparison]::OrdinalIgnoreCase)) { return $null }
        if (-not (Test-ManagedRelayCommandLine -CommandLine $cim.CommandLine -NodePath $Settings.NodePath -RelayScriptPath $Settings.RelayScriptPath)) { return $null }
        $sidResult = Invoke-CimMethod -InputObject $cim -MethodName GetOwnerSid -ErrorAction Stop
        $ownerResult = Invoke-CimMethod -InputObject $cim -MethodName GetOwner -ErrorAction Stop
        if ($sidResult.ReturnValue -ne 0 -or $ownerResult.ReturnValue -ne 0 -or [String]::IsNullOrWhiteSpace([string]$sidResult.Sid)) { return $null }
        $observedOwnerName = [string]$ownerResult.Domain + '\' + [string]$ownerResult.User
        if (-not [String]::Equals([string]$sidResult.Sid, $Settings.OwnerSid, [StringComparison]::OrdinalIgnoreCase)) { return $null }
        if (-not [String]::Equals($observedOwnerName, $Settings.OwnerName, [StringComparison]::OrdinalIgnoreCase)) { return $null }
        $cimStartTime = ConvertFrom-ManagedCimCreationDate -Value $cim.CreationDate
        $processStartTime = (Get-Process -Id $ProcessId -ErrorAction Stop).StartTime.ToUniversalTime()
        if ([Math]::Abs(($cimStartTime - $processStartTime).TotalSeconds) -gt 2) { return $null }
        $parentProcessId = [int]$cim.ParentProcessId
        if ($parentProcessId -le 0) { return $null }
        $parentCim = Get-CimInstance Win32_Process -Filter ('ProcessId = ' + $parentProcessId) -ErrorAction Stop
        if ($null -eq $parentCim -or [String]::IsNullOrWhiteSpace([string]$parentCim.ExecutablePath) -or [String]::IsNullOrWhiteSpace([string]$parentCim.CommandLine)) { return $null }
        if (-not [String]::Equals((ConvertTo-ManagedFullPath -Path $parentCim.ExecutablePath), (ConvertTo-ManagedFullPath -Path $powerShellPath), [StringComparison]::OrdinalIgnoreCase)) { return $null }
        if (-not (Test-ManagedRelayLauncherCommandLine -CommandLine $parentCim.CommandLine -PowerShellPath $powerShellPath -LauncherScriptPath $launcherPath)) { return $null }
        $parentSidResult = Invoke-CimMethod -InputObject $parentCim -MethodName GetOwnerSid -ErrorAction Stop
        $parentOwnerResult = Invoke-CimMethod -InputObject $parentCim -MethodName GetOwner -ErrorAction Stop
        if ($parentSidResult.ReturnValue -ne 0 -or $parentOwnerResult.ReturnValue -ne 0 -or [String]::IsNullOrWhiteSpace([string]$parentSidResult.Sid)) { return $null }
        $parentOwnerName = [string]$parentOwnerResult.Domain + '\' + [string]$parentOwnerResult.User
        if (-not [String]::Equals([string]$parentSidResult.Sid, [string]$sidResult.Sid, [StringComparison]::OrdinalIgnoreCase)) { return $null }
        if (-not [String]::Equals($parentOwnerName, $observedOwnerName, [StringComparison]::OrdinalIgnoreCase)) { return $null }
        $parentCimStartTime = ConvertFrom-ManagedCimCreationDate -Value $parentCim.CreationDate
        $parentProcessStartTime = (Get-Process -Id $parentProcessId -ErrorAction Stop).StartTime.ToUniversalTime()
        if ([Math]::Abs(($parentCimStartTime - $parentProcessStartTime).TotalSeconds) -gt 2) { return $null }
        if ($parentCimStartTime -ge $cimStartTime) { return $null }
        return [pscustomobject]@{
            ProcessId = $ProcessId
            ExecutablePath = (ConvertTo-ManagedFullPath -Path $cim.ExecutablePath)
            CommandLine = [string]$cim.CommandLine
            OwnerSid = [string]$sidResult.Sid
            OwnerName = $observedOwnerName
            CreationTicks = $cimStartTime.Ticks
            ParentProcessId = $parentProcessId
            ParentExecutablePath = (ConvertTo-ManagedFullPath -Path $parentCim.ExecutablePath)
            ParentCommandLine = [string]$parentCim.CommandLine
            ParentOwnerSid = [string]$parentSidResult.Sid
            ParentOwnerName = $parentOwnerName
            ParentCreationTicks = $parentCimStartTime.Ticks
        }
    } catch {
        return $null
    }
}

function Get-ManagedRelayListenerSnapshot {
    param([Parameter(Mandatory = $true)]$Settings)
    try {
        # Filtering after enumeration treats no matching endpoint as the normal
        # "Absent" state.  Some Windows builds throw a non-terminating error
        # when the address/port filter itself has no match.
        $listeners = @(Get-NetTCPConnection -State Listen -ErrorAction Stop | Where-Object {
                $_.LocalAddress -eq $script:ManagedRelayAddress -and $_.LocalPort -eq 443
            })
    } catch {
        return [pscustomobject]@{ State = 'Invalid'; Reason = 'listener_query_failed'; Identity = $null }
    }
    if ($listeners.Count -eq 0) { return [pscustomobject]@{ State = 'Absent'; Reason = 'listener_absent'; Identity = $null } }
    if ($listeners.Count -ne 1) { return [pscustomobject]@{ State = 'Invalid'; Reason = 'multiple_listeners'; Identity = $null } }
    $identity = Get-ManagedRelayIdentity -ProcessId ([int]$listeners[0].OwningProcess) -Settings $Settings
    if ($null -eq $identity) { return [pscustomobject]@{ State = 'Invalid'; Reason = 'listener_identity_mismatch'; Identity = $null } }
    return [pscustomobject]@{ State = 'Valid'; Reason = 'mapping_present'; Identity = $identity }
}

function Test-ManagedSameRelayIdentity {
    param(
        [Parameter(Mandatory = $true)]$InitialIdentity,
        [Parameter(Mandatory = $true)]$Settings
    )
    $current = Get-ManagedRelayListenerSnapshot -Settings $Settings
    if ($current.State -ne 'Valid') { return $false }
    return ($current.Identity.ProcessId -eq $InitialIdentity.ProcessId -and
        $current.Identity.CreationTicks -eq $InitialIdentity.CreationTicks -and
        [String]::Equals($current.Identity.ExecutablePath, $InitialIdentity.ExecutablePath, [StringComparison]::OrdinalIgnoreCase) -and
        [String]::Equals($current.Identity.CommandLine, $InitialIdentity.CommandLine, [StringComparison]::Ordinal) -and
        [String]::Equals($current.Identity.OwnerSid, $InitialIdentity.OwnerSid, [StringComparison]::OrdinalIgnoreCase) -and
        $current.Identity.ParentProcessId -eq $InitialIdentity.ParentProcessId -and
        $current.Identity.ParentCreationTicks -eq $InitialIdentity.ParentCreationTicks -and
        [String]::Equals($current.Identity.ParentExecutablePath, $InitialIdentity.ParentExecutablePath, [StringComparison]::OrdinalIgnoreCase) -and
        [String]::Equals($current.Identity.ParentCommandLine, $InitialIdentity.ParentCommandLine, [StringComparison]::Ordinal) -and
        [String]::Equals($current.Identity.ParentOwnerSid, $InitialIdentity.ParentOwnerSid, [StringComparison]::OrdinalIgnoreCase) -and
        [String]::Equals($current.Identity.ParentOwnerName, $InitialIdentity.ParentOwnerName, [StringComparison]::OrdinalIgnoreCase))
}

function Convert-ManagedHostsPlanToStatus {
    param([Parameter(Mandatory = $true)]$Plan, [Parameter(Mandatory = $true)][string]$Mode)
    switch ($Plan.Reason) {
        'mapping_added' { return @('mapped', 'mapping_added', 0) }
        'mapping_present' { return @('mapped', 'mapping_present', 0) }
        'mapping_removed' { return @('unmapped', 'mapping_removed', 0) }
        'no_owned_mapping' { return @('unmapped', 'no_owned_mapping', 0) }
        'foreign_mapping_untouched' { return @('unmapped', 'foreign_mapping_untouched', 0) }
        'hosts_conflicting_mapping' { return @('error', 'hosts_conflicting_mapping', 1) }
        'hosts_modified_marker' { return @('error', 'hosts_modified_marker', 1) }
        'hosts_null_bytes' { return @('error', 'hosts_null_bytes', 1) }
        'hosts_duplicate_owned_mapping' { return @('error', 'hosts_duplicate_owned_mapping', 1) }
        'hosts_missing_terminal_newline' { return @('error', 'hosts_missing_terminal_newline', 1) }
        'hosts_too_large' { return @('error', 'hosts_too_large', 1) }
        default { return @('error', 'internal_error', 1) }
    }
}

function Invoke-ManagedOwnedCleanup {
    try {
        return [pscustomobject]@{ Succeeded = $true; Plan = (Invoke-ManagedFixedHostsPlan -Mode Cleanup); Reason = $null }
    } catch [IO.IOException] {
        return [pscustomobject]@{ Succeeded = $false; Plan = $null; Reason = 'hosts_locked' }
    } catch {
        if ($_.Exception.Message -eq 'dns_cache_flush_failed') {
            return [pscustomobject]@{ Succeeded = $false; Plan = $null; Reason = 'dns_cache_flush_failed' }
        }
        return [pscustomobject]@{ Succeeded = $false; Plan = $null; Reason = 'hosts_io_error' }
    }
}

function Invoke-ManagedFixedHostsPlan {
    param([ValidateSet('Reconcile', 'Cleanup')][string]$Mode)
    # HostsPath and BackupPath are module constants.  This is the only helper
    # path that flushes the system resolver cache, and it does so only after an
    # atomic mapping change has succeeded.
    $plan = Invoke-ManagedHostsFilePlan -HostsPath $hostsPath -BackupPath $hostsBackupPath -Mode $Mode
    if ($plan.Action -eq 'Append' -or $plan.Action -eq 'Remove') {
        try { Clear-DnsClientCache -ErrorAction Stop } catch { throw 'dns_cache_flush_failed' }
    }
    return $plan
}

$settings = $null
$action = if ($Cleanup) { 'cleanup' } else { 'reconcile' }
$exitCode = 0
try {
    $settings = Get-ManagedRelaySettings
} catch {
    [void](Write-ManagedHelperStatus -Action $action -Status 'error' -Reason 'settings_invalid')
    exit 1
}

try {
    if ($Cleanup -or (Test-Path -LiteralPath (Join-Path $installDirectory 'shutdown-request.flag'))) {
        $plan = Invoke-ManagedFixedHostsPlan -Mode Cleanup
        $result = Convert-ManagedHostsPlanToStatus -Plan $plan -Mode $action
        [void](Write-ManagedHelperStatus -Action $action -Status $result[0] -Reason $result[1])
        exit [int]$result[2]
    }

    $snapshot = Get-ManagedRelayListenerSnapshot -Settings $settings
    if ($snapshot.State -eq 'Absent') {
        $cleanupOutcome = Invoke-ManagedOwnedCleanup
        if (-not $cleanupOutcome.Succeeded) {
            [void](Write-ManagedHelperStatus -Action $action -Status 'error' -Reason $cleanupOutcome.Reason)
            exit 1
        }
        $cleanupResult = Convert-ManagedHostsPlanToStatus -Plan $cleanupOutcome.Plan -Mode 'Cleanup'
        if ([int]$cleanupResult[2] -ne 0) {
            [void](Write-ManagedHelperStatus -Action $action -Status $cleanupResult[0] -Reason $cleanupResult[1])
            exit [int]$cleanupResult[2]
        }
        $reason = if ($cleanupOutcome.Plan.Reason -eq 'mapping_removed') { 'mapping_removed' } else { 'listener_absent' }
        [void](Write-ManagedHelperStatus -Action $action -Status 'unmapped' -Reason $reason)
        exit 0
    }
    if ($snapshot.State -ne 'Valid') {
        $cleanupOutcome = Invoke-ManagedOwnedCleanup
        if (-not $cleanupOutcome.Succeeded) {
            [void](Write-ManagedHelperStatus -Action $action -Status 'error' -Reason $cleanupOutcome.Reason)
            exit 1
        }
        $cleanupResult = Convert-ManagedHostsPlanToStatus -Plan $cleanupOutcome.Plan -Mode 'Cleanup'
        if ([int]$cleanupResult[2] -ne 0) {
            [void](Write-ManagedHelperStatus -Action $action -Status $cleanupResult[0] -Reason $cleanupResult[1])
            exit [int]$cleanupResult[2]
        }
        [void](Write-ManagedHelperStatus -Action $action -Status 'error' -Reason $snapshot.Reason)
        exit 1
    }

    $plan = Invoke-ManagedFixedHostsPlan -Mode Reconcile
    $result = Convert-ManagedHostsPlanToStatus -Plan $plan -Mode $action
    if ([int]$result[2] -ne 0) {
        [void](Write-ManagedHelperStatus -Action $action -Status $result[0] -Reason $result[1])
        exit [int]$result[2]
    }
    if (-not (Test-ManagedSameRelayIdentity -InitialIdentity $snapshot.Identity -Settings $settings)) {
        $cleanupOutcome = Invoke-ManagedOwnedCleanup
        if (-not $cleanupOutcome.Succeeded) {
            [void](Write-ManagedHelperStatus -Action $action -Status 'error' -Reason $cleanupOutcome.Reason)
            exit 1
        }
        $cleanupResult = Convert-ManagedHostsPlanToStatus -Plan $cleanupOutcome.Plan -Mode 'Cleanup'
        if ([int]$cleanupResult[2] -ne 0) {
            [void](Write-ManagedHelperStatus -Action $action -Status $cleanupResult[0] -Reason $cleanupResult[1])
            exit [int]$cleanupResult[2]
        }
        [void](Write-ManagedHelperStatus -Action $action -Status 'error' -Reason 'post_write_identity_changed')
        exit 1
    }
    [void](Write-ManagedHelperStatus -Action $action -Status $result[0] -Reason $result[1] -RelayPid $snapshot.Identity.ProcessId)
    exit 0
} catch [IO.IOException] {
    [void](Write-ManagedHelperStatus -Action $action -Status 'error' -Reason 'hosts_locked')
    exit 1
} catch {
    if ($_.Exception.Message -eq 'hosts_too_large') {
        [void](Write-ManagedHelperStatus -Action $action -Status 'error' -Reason 'hosts_too_large')
        exit 1
    }
    if ($_.Exception.Message -eq 'dns_cache_flush_failed') {
        [void](Write-ManagedHelperStatus -Action $action -Status 'error' -Reason 'dns_cache_flush_failed')
        exit 1
    }
    [void](Write-ManagedHelperStatus -Action $action -Status 'error' -Reason 'hosts_io_error')
    exit 1
}
