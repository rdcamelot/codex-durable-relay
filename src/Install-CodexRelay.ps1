[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$OwnerSid,
    [Parameter(Mandatory=$true)][string]$OwnerName,
    [Parameter(Mandatory=$true)][string]$StateDirectory,
    [Parameter(Mandatory=$true)][string]$NodeSource,
    [Parameter(Mandatory=$true)][string]$ManifestHash,
    [Parameter(Mandatory=$true)][string]$NodeHash,
    [Parameter(Mandatory=$true)][string]$PayloadDirectory,
    [ValidateRange(1,65535)][int]$ProxyPort = 7890
)
$ErrorActionPreference = 'Stop'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Installation requires administrator approval.' }
if (-not [Environment]::Is64BitProcess -or $env:ProgramFiles -ne 'C:\Program Files' -or $env:SystemRoot -ne 'C:\Windows') { throw 'This version requires standard 64-bit Windows installation paths.' }
$null = New-Object Security.Principal.SecurityIdentifier($OwnerSid)
if ((New-Object Security.Principal.NTAccount($OwnerName)).Translate([Security.Principal.SecurityIdentifier]).Value -ne $OwnerSid) { throw 'Owner identity mismatch.' }
$profile = Get-CimInstance Win32_UserProfile | Where-Object SID -eq $OwnerSid | Select-Object -First 1
if (-not $profile -or -not $profile.LocalPath) { throw 'Owner profile was not found.' }
$expectedState = Join-Path $profile.LocalPath 'AppData\Local\CodexDurableRelay'
if ([IO.Path]::GetFullPath($StateDirectory) -ne [IO.Path]::GetFullPath($expectedState)) { throw 'Unexpected user state location.' }
$manifestPath = Join-Path $PayloadDirectory 'managed-manifest.json'
$manifestBytes = [IO.File]::ReadAllBytes($manifestPath)
$hasher = [Security.Cryptography.SHA256]::Create()
try { $observedManifestHash = [BitConverter]::ToString($hasher.ComputeHash($manifestBytes)).Replace('-','') } finally { $hasher.Dispose() }
if ($observedManifestHash -ne $ManifestHash) { throw 'The reviewed manifest changed.' }
$manifest = [Text.Encoding]::UTF8.GetString($manifestBytes).TrimStart([char]0xFEFF) | ConvertFrom-Json
$allowedFiles = @('codex-durable-relay.cjs','relay-log.cjs','managed-relay.cjs','managed-relay-hosts.ps1','managed-hosts-lib.ps1','Launch-ManagedRelay.ps1','Manage-CodexRelay.ps1','Shutdown-CodexRelay.ps1','CodexRelayLifecycle.exe','CodexRelayLifecycle.cs')
if (@($manifest.files).Count -ne $allowedFiles.Count) { throw 'Unexpected payload count.' }
foreach ($file in $allowedFiles) {
    $entry = @($manifest.files | Where-Object name -eq $file)
    if ($entry.Count -ne 1 -or (Get-FileHash -LiteralPath (Join-Path $PayloadDirectory $file) -Algorithm SHA256).Hash -ne $entry[0].sha256) { throw "Reviewed payload changed: $file" }
}
if ((Get-FileHash -LiteralPath $NodeSource -Algorithm SHA256).Hash -ne $NodeHash) { throw 'The reviewed Node runtime changed.' }
$signature = Get-AuthenticodeSignature -LiteralPath $NodeSource
if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=OpenJS Foundation') { throw 'Expected a valid OpenJS Node signature.' }
$installRoot = Join-Path $env:ProgramFiles 'CodexDurableRelay'
$userTaskName = 'Codex Durable Relay - User'
$helperTaskName = 'Codex Durable Relay - Hosts'
$serviceName = 'CodexDurableRelayLifecycle'
if (Test-Path -LiteralPath $installRoot) { throw 'Installation directory already exists. Inspect/uninstall the existing version before replacing it.' }
if (Get-ScheduledTask -TaskName $userTaskName,$helperTaskName -ErrorAction SilentlyContinue) { throw 'A task with this name already exists; refusing to overwrite it.' }
if (Get-Service -Name $serviceName -ErrorAction SilentlyContinue) { throw 'Lifecycle service already exists; refusing to overwrite it.' }
$hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$activeLines = ([IO.File]::ReadAllText($hostsPath) -split '\r?\n' | ForEach-Object { ($_ -split '#',2)[0] }) -join "`n"
if ($activeLines -match '(?i)(?<![\w.-])codex-cloud-backend\.chatgpt\.com(?![\w.-])') { throw 'An existing hosts mapping conflicts with this installation.' }
function Set-ProtectedDirectoryAcl([string]$Directory, [string]$UserSid, [bool]$UserWrite) {
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true,$false)
    foreach ($sid in @('S-1-5-18','S-1-5-32-544')) {
        $rule = New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier($sid)), 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    $rights = if ($UserWrite) { 'Modify' } else { 'ReadAndExecute' }
    $userRule = New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier($UserSid)), $rights, 'ContainerInherit,ObjectInherit', 'None', 'Allow')
    $acl.AddAccessRule($userRule)
    $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))
    Set-Acl -LiteralPath $Directory -AclObject $acl
}
$createdUserTask = $false
$createdHelperTask = $false
$createdService = $false
$protectedDirectory = $false
$payloadVerified = $false
try {
    New-Item -ItemType Directory -Path $installRoot | Out-Null
    if ((Get-Item -LiteralPath $installRoot -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Installation directory must not be redirected.' }
    Set-ProtectedDirectoryAcl $installRoot $OwnerSid $false
    $protectedDirectory = $true
    foreach ($file in $allowedFiles) {
        $destination = Join-Path $installRoot $file
        Copy-Item -LiteralPath (Join-Path $PayloadDirectory $file) -Destination $destination
        $expected = ($manifest.files | Where-Object name -eq $file).sha256
        if ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -ne $expected) { throw 'Copied payload verification failed.' }
    }
    Copy-Item -LiteralPath $NodeSource -Destination (Join-Path $installRoot 'node.exe')
    if ((Get-FileHash -LiteralPath (Join-Path $installRoot 'node.exe') -Algorithm SHA256).Hash -ne $NodeHash) { throw 'Copied runtime verification failed.' }
    $copiedSignature = Get-AuthenticodeSignature -LiteralPath (Join-Path $installRoot 'node.exe')
    if ($copiedSignature.Status -ne 'Valid' -or $copiedSignature.SignerCertificate.Subject -notmatch 'O=OpenJS Foundation') { throw 'Copied runtime signature verification failed.' }
    # The limited user process creates its own diagnostics directory. Never write
    # elevated status/control files through a user-controlled directory or link.
    $settingsJson = @{ version=2; ownerSid=$OwnerSid; ownerName=$OwnerName; stateDirectory=$StateDirectory; proxyPort=$ProxyPort; installedAt=[DateTime]::UtcNow.ToString('o') } | ConvertTo-Json
    [IO.File]::WriteAllText((Join-Path $installRoot 'settings.json'), $settingsJson, (New-Object Text.UTF8Encoding($false)))
    $payloadVerified = $true
    $powerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $userAction = New-ScheduledTaskAction -Execute $powerShellPath -Argument ('-NoProfile -NonInteractive -WindowStyle Hidden -File "' + (Join-Path $installRoot 'Launch-ManagedRelay.ps1') + '"') -WorkingDirectory $installRoot
    $userTrigger = New-ScheduledTaskTrigger -AtLogOn -User $OwnerName
    $userPrincipal = New-ScheduledTaskPrincipal -UserId $OwnerSid -LogonType Interactive -RunLevel Limited
    # The launcher owns the retry budget; scheduler retries would multiply it.
    $userSettings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -StartWhenAvailable
    Register-ScheduledTask -TaskName $userTaskName -Action $userAction -Trigger $userTrigger -Principal $userPrincipal -Settings $userSettings -Description 'Fixed Codex cloud relay, ordinary user, waits for existing local proxy.' | Out-Null
    $createdUserTask = $true
    $helperAction = New-ScheduledTaskAction -Execute $powerShellPath -Argument ('-NoProfile -NonInteractive -WindowStyle Hidden -File "' + (Join-Path $installRoot 'managed-relay-hosts.ps1') + '"') -WorkingDirectory $installRoot
    $helperTriggers = @((New-ScheduledTaskTrigger -AtStartup), (New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 1)))
    $helperPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $helperSettings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 2) -StartWhenAvailable
    Register-ScheduledTask -TaskName $helperTaskName -Action $helperAction -Trigger $helperTriggers -Principal $helperPrincipal -Settings $helperSettings -Description 'Reconcile only one owned hosts mapping with a verified local relay; no arbitrary input.' | Out-Null
    $createdHelperTask = $true
    # The configured user may read/run tasks, but may not replace privileged actions.
    $scheduler = New-Object -ComObject 'Schedule.Service'
    $scheduler.Connect()
    foreach ($taskName in @($userTaskName,$helperTaskName)) {
        $scheduler.GetFolder('\').GetTask($taskName).SetSecurityDescriptor(('D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;GRGX;;;' + $OwnerSid + ')'),0)
    }
    New-Service -Name $serviceName -BinaryPathName ('"' + (Join-Path $installRoot 'CodexRelayLifecycle.exe') + '"') -DisplayName 'Codex Relay Lifecycle' -Description 'Stop the fixed Codex relay and restore its hosts mapping on Windows shutdown or owner logoff.' -StartupType Manual -DependsOn 'Schedule' | Out-Null
    $createdService = $true
    # The SYSTEM service sets its fixed 45-second budget with ChangeServiceConfig2.
    & "$env:SystemRoot\System32\sc.exe" sdset $serviceName ('D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;CCLCRPRC;;;' + $OwnerSid + ')') | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Cannot protect lifecycle service permissions.' }
    Start-Service -Name $serviceName
    Start-ScheduledTask -TaskName $helperTaskName
    Start-ScheduledTask -TaskName $userTaskName
    Set-Service -Name $serviceName -StartupType Automatic
    @{success=$true;completedAt=[DateTime]::UtcNow.ToString('o');ownerSid=$OwnerSid} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $installRoot 'install-result.json') -Encoding ASCII
    Write-Output ('Installed: ' + $installRoot)
} catch {
    # Disable restart paths before attempting cleanup. Only verified, protected
    # scripts may run elevated; a partial copy is retained but never executed.
    $registrationRemoved = $true
    if ($protectedDirectory) { try { [IO.File]::WriteAllText((Join-Path $installRoot 'shutdown-request.flag'),'installation_failed') } catch { $registrationRemoved = $false } }
    foreach ($taskName in @($(if ($createdUserTask) { $userTaskName }), $(if ($createdHelperTask) { $helperTaskName }))) {
        if (-not $taskName) { continue }
        try { Disable-ScheduledTask -TaskName $taskName | Out-Null } catch { $registrationRemoved = $false }
        try { Stop-ScheduledTask -TaskName $taskName } catch { $registrationRemoved = $false }
    }
    if ($createdService) {
        try { Set-Service -Name $serviceName -StartupType Disabled } catch { $registrationRemoved = $false }
        try { Stop-Service -Name $serviceName -ErrorAction Stop } catch { $registrationRemoved = $false }
    }
    $mappingRemoved = $false
    try {
        if ($payloadVerified) {
            & (Join-Path $installRoot 'managed-relay-hosts.ps1') -Cleanup
            if ($LASTEXITCODE -ne 0) { throw 'cleanup_failed' }
        }
        $mappingRemoved = -not [IO.File]::ReadAllText($hostsPath).Contains('CODEX-DURABLE-RELAY-V2')
    } catch { }
    foreach ($taskName in @($(if ($createdUserTask) { $userTaskName }), $(if ($createdHelperTask) { $helperTaskName }))) {
        if (-not $taskName) { continue }
        try { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop } catch { $registrationRemoved = $false }
    }
    if ($createdService) {
        & "$env:SystemRoot\System32\sc.exe" delete $serviceName | Out-Null
        if ($LASTEXITCODE -ne 0) { $registrationRemoved = $false }
    }
    if ($protectedDirectory) {
        $result = @{success=$false;completedAt=[DateTime]::UtcNow.ToString('o');reason='installation_failed';mappingRemoved=$mappingRemoved;registrationRemovalRequested=$registrationRemoved}
        try { [IO.File]::WriteAllText((Join-Path $installRoot 'install-result.json'), ($result | ConvertTo-Json), (New-Object Text.UTF8Encoding($false))) } catch { }
    }
    # Keep the protected partial installation for inspection, never erase it
    # recursively or overwrite it on retry. Do not persist exception contents.
    throw 'Installation failed; partial files were retained. Check install-result.json before recovery.'
}
