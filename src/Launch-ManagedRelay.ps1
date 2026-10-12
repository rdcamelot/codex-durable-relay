$ErrorActionPreference = 'Stop'
$settings = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'settings.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if ($identity.User.Value -ne $settings.ownerSid -or $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'The relay must run as its configured user without elevation.'
}
# Diagnostics contain connection metadata. Do not inherit other accounts' access.
$expectedState = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CodexDurableRelay'
if ([IO.Path]::GetFullPath($settings.stateDirectory) -ne [IO.Path]::GetFullPath($expectedState)) { throw 'Unexpected diagnostics directory.' }
if (-not (Test-Path -LiteralPath $expectedState)) { New-Item -ItemType Directory -Path $expectedState | Out-Null }
if ((Get-Item -LiteralPath $expectedState -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Diagnostics directory must not be a reparse point.' }
$stateAcl = New-Object Security.AccessControl.DirectorySecurity($expectedState, [Security.AccessControl.AccessControlSections]::Access)
$stateAcl.SetAccessRuleProtection($true,$false)
foreach ($existingRule in @($stateAcl.GetAccessRules($true,$false,[Security.Principal.SecurityIdentifier]))) {
    $stateAcl.RemoveAccessRuleSpecific($existingRule)
}
foreach ($sid in @('S-1-5-18','S-1-5-32-544',$identity.User.Value)) {
    $rule = New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier($sid)), 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
    $stateAcl.AddAccessRule($rule)
}
# Persist only the DACL. A new full security descriptor through PowerShell 5.1
# Set-Acl can try to write the SACL and require SeSecurityPrivilege.
[IO.Directory]::SetAccessControl($expectedState,$stateAcl)
# A limited user can start this fixed service, but cannot stop or reconfigure it.
$lifecycle = Get-Service -Name 'CodexDurableRelayLifecycle' -ErrorAction Stop
if ($lifecycle.Status -eq 'Stopped') { Start-Service -Name 'CodexDurableRelayLifecycle' }
$lifecycle.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Running, [TimeSpan]::FromSeconds(25))
# A general Node runtime must not inherit module injection or TLS overrides.
foreach ($name in @('NODE_OPTIONS','NODE_PATH','NODE_EXTRA_CA_CERTS','NODE_TLS_REJECT_UNAUTHORIZED','SSL_CERT_FILE','SSL_CERT_DIR','OPENSSL_CONF')) {
    [Environment]::SetEnvironmentVariable($name, $null, 'Process')
}
$code = 1
$launchStarted = (Get-Process -Id $PID).StartTime.ToUniversalTime()
function Test-UserStopRequested {
    if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'shutdown-request.flag')) { return $true }
    try {
        $request = Get-Content -LiteralPath (Join-Path $settings.stateDirectory 'stop.json') -Raw | ConvertFrom-Json
        return [DateTime]::Parse($request.requestedAt).ToUniversalTime() -ge $launchStarted
    } catch { return $false }
}
for ($attempt = 0; $attempt -le 3; $attempt++) {
    if (Test-UserStopRequested) { $code = 0; break }
    try {
        $startInfo = New-Object Diagnostics.ProcessStartInfo
        $startInfo.FileName = Join-Path $PSScriptRoot 'node.exe'
        $startInfo.Arguments = '"' + (Join-Path $PSScriptRoot 'managed-relay.cjs') + '" --run'
        $startInfo.WorkingDirectory = $PSScriptRoot
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $process = [Diagnostics.Process]::Start($startInfo)
        $process.WaitForExit()
        $code = $process.ExitCode
        $process.Dispose()
    } finally {
        Start-ScheduledTask -TaskName 'Codex Durable Relay - Hosts' -ErrorAction SilentlyContinue
    }
    if ($code -eq 0 -or $attempt -eq 3) { break }
    # Task Scheduler's RestartOnFailure did not restart a killed Node in the
    # on-device acceptance test. Handle a bounded number of child failures here.
    $retryAt = (Get-Date).AddSeconds(5 * [Math]::Pow(2,$attempt))
    while ((Get-Date) -lt $retryAt) {
        if (Test-UserStopRequested) { $code = 0; break }
        Start-Sleep -Milliseconds 500
    }
    if ($code -eq 0) { break }
}
exit $code
