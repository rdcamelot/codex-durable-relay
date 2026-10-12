$ErrorActionPreference = 'Stop'
$outputs = Join-Path (Split-Path $PSScriptRoot -Parent) 'src'
$source = [IO.File]::ReadAllText((Join-Path $outputs 'Shutdown-CodexRelay.ps1'))
$source = $source.Substring($source.IndexOf(". (Join-Path `$installRoot 'managed-hosts-lib.ps1')"))
$testRoot = Join-Path $PSScriptRoot ('.lifecycle-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
$passed = 0
try {
    foreach ($case in @('stop','initialize','owner_logoff','other_session','wrong_owner','wrong_exe','wrong_command','helper_failure','task_wrong_exe','task_wrong_args','task_wrong_workdir','orphan_node','orphan_launcher','orphan_tray','unrelated_process','unrelated_owner','listener_present','process_query_failure','owner_query_failure','listener_query_failure')) {
        $dir = Join-Path $testRoot $case
        New-Item -ItemType Directory -Path $dir | Out-Null
        Copy-Item -LiteralPath (Join-Path $outputs 'managed-hosts-lib.ps1') -Destination (Join-Path $dir 'managed-hosts-lib.ps1')
        '{"ownerSid":"S-1-5-21-111-222-333-1001"}' | Set-Content -LiteralPath (Join-Path $dir 'settings.json') -Encoding ASCII
        $hosts = Join-Path $dir 'hosts.fixture'
        [IO.File]::WriteAllText($hosts,"# preserved`r`n127.0.0.2 codex-cloud-backend.chatgpt.com # CODEX-DURABLE-RELAY-V2`r`n")
        if ($case -eq 'initialize') { [IO.File]::WriteAllText((Join-Path $dir 'shutdown-request.flag'),'old') }
        $helper = if ($case -eq 'helper_failure') { 'param([switch]$Cleanup); exit 1' } else {
@'
param([switch]$Cleanup)
if ($Cleanup) { [IO.File]::WriteAllText((Join-Path $PSScriptRoot 'hosts.fixture'), "# preserved`r`n") }
exit 0
'@
        }
        [IO.File]::WriteAllText((Join-Path $dir 'managed-relay-hosts.ps1'),$helper)
        $escaped = $dir.Replace("'","''")
        $session = if ($case -eq 'other_session') { 2 } else { 1 }
        $sid = if ($case -in @('wrong_owner','unrelated_owner')) { 'S-1-5-21-111-222-333-9999' } else { 'S-1-5-21-111-222-333-1001' }
        $exe = if ($case -eq 'wrong_exe') { 'other.exe' } else { 'node.exe' }
        $suffix = if ($case -eq 'wrong_command') { '--run --eval malicious' } else { '--run' }
        $taskExe = if ($case -eq 'task_wrong_exe') { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' } else { Join-Path $dir 'CodexRelayTrayHost.exe' }
        $taskArgs = if ($case -eq 'task_wrong_args') { '--legacy' } else { '' }
        $taskWorkingDirectory = if ($case -eq 'task_wrong_workdir') { Join-Path $dir 'other' } else { $dir }
        $nodePath = Join-Path $dir 'node.exe'
        $relayPath = Join-Path $dir 'managed-relay.cjs'
        $launcherPath = Join-Path $dir 'Launch-ManagedRelay.ps1'
        $powerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $trayHostPath = Join-Path $dir 'CodexRelayTrayHost.exe'
        if ($case -eq 'orphan_launcher') {
            $processName = 'powershell.exe'
            $processPath = $powerShellPath
            $processCommand = '"' + $powerShellPath + '" -NoProfile -NonInteractive -WindowStyle Hidden -File "' + $launcherPath + '"'
        } elseif ($case -eq 'orphan_tray') {
            $processName = 'CodexRelayTrayHost.exe'
            $processPath = $trayHostPath
            $processCommand = '"' + $trayHostPath + '"'
        } elseif ($case -eq 'unrelated_process') {
            $processName = 'node.exe'
            $processPath = $nodePath
            $processCommand = '"' + $nodePath + '" "' + $relayPath + '" --other'
        } else {
            $processName = 'node.exe'
            $processPath = $nodePath
            $processCommand = '"' + $nodePath + '" "' + $relayPath + '" ' + $suffix
        }
        $escapedTaskExe = $taskExe.Replace("'","''")
        $escapedTaskArgs = $taskArgs.Replace("'","''")
        $escapedTaskWorkingDirectory = $taskWorkingDirectory.Replace("'","''")
        $escapedProcessName = $processName.Replace("'","''")
        $escapedProcessPath = $processPath.Replace("'","''")
        $escapedProcessCommand = $processCommand.Replace("'","''")
        $prefix = @"
param([string]`$Mode,[uint32]`$SessionId=1)
`$ErrorActionPreference='Stop'
`$installRoot='$escaped'
`$userTaskName='Codex Durable Relay - User'
`$flagPath=Join-Path `$installRoot 'shutdown-request.flag'
`$resultPath=Join-Path `$installRoot 'lifecycle-cleanup-result.json'
`$fixtureCase='$case'
`$script:processQueryCount=0
function Get-CimInstance {
 [CmdletBinding()]
 param(`$ClassName,`$Filter)
 if (`$fixtureCase -eq 'process_query_failure') { throw 'process query fixture failure' }
 `$script:processQueryCount++
 if (`$fixtureCase -eq 'owner_logoff' -and `$script:processQueryCount -gt 1) { return @() }
 if (`$fixtureCase -notin @('owner_logoff','orphan_node','orphan_launcher','orphan_tray','unrelated_process','unrelated_owner','owner_query_failure')) { return @() }
 [pscustomobject]@{Name='$escapedProcessName';ExecutablePath='$escapedProcessPath';SessionId=$session;CommandLine='$escapedProcessCommand';FixtureOwnerSid='$sid'}
}
function Invoke-CimMethod {
 [CmdletBinding()]
 param(`$InputObject,`$MethodName)
 if (`$fixtureCase -eq 'owner_query_failure' -and `$MethodName -eq 'GetOwnerSid') { throw 'owner query fixture failure' }
 [pscustomobject]@{ReturnValue=0;Sid=`$InputObject.FixtureOwnerSid}
}
function Get-NetTCPConnection {
 [CmdletBinding()]
 param([string]`$State)
 if (`$fixtureCase -eq 'listener_query_failure') { throw 'listener query fixture failure' }
 if (`$fixtureCase -eq 'listener_present') { [pscustomobject]@{LocalAddress='127.0.0.2';LocalPort=443} }
}
function Get-ScheduledTask {
 param(`$TaskName)
 [pscustomobject]@{State='Ready';Actions=@([pscustomobject]@{Execute='$escapedTaskExe';Arguments='$escapedTaskArgs';WorkingDirectory='$escapedTaskWorkingDirectory'})}
}
function Stop-ScheduledTask { throw 'Already stopped fixture must not be killed' }
"@
        $body = $source.Replace("(Join-Path `$env:SystemRoot 'System32\drivers\etc\hosts')",("'" + $hosts.Replace("'","''") + "'"))
        $fixture = Join-Path $dir 'entry.ps1'
        [IO.File]::WriteAllText($fixture,($prefix+"`n"+$body),(New-Object Text.UTF8Encoding($true)))
        $stopCases = @('stop','helper_failure','task_wrong_exe','task_wrong_args','task_wrong_workdir','orphan_node','orphan_launcher','orphan_tray','unrelated_process','unrelated_owner','listener_present','process_query_failure','owner_query_failure','listener_query_failure')
        $terminationFailureCases = @('orphan_node','orphan_launcher','orphan_tray','listener_present','process_query_failure','owner_query_failure','listener_query_failure')
        $mode = if ($case -eq 'initialize') { 'Initialize' } elseif ($case -in $stopCases) { 'Stop' } else { 'SessionLogoff' }
        & (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -NoProfile -NonInteractive -File $fixture -Mode $mode -SessionId 1
        $expectedExit = if ($case -in @('helper_failure','task_wrong_exe','task_wrong_args','task_wrong_workdir') + $terminationFailureCases) { 1 } else { 0 }
        if ($LASTEXITCODE -ne $expectedExit) { throw ($case + ': unexpected exit ' + $LASTEXITCODE) }
        $resultName = if ($case -eq 'initialize') { 'lifecycle-initialize-result.json' } elseif ($case -in @('other_session','wrong_owner','wrong_exe','wrong_command')) { 'lifecycle-session-check.json' } else { 'lifecycle-cleanup-result.json' }
        $result = Get-Content -LiteralPath (Join-Path $dir $resultName) -Raw | ConvertFrom-Json
        if ($case -in @('helper_failure','task_wrong_exe','task_wrong_args','task_wrong_workdir') + $terminationFailureCases) {
            if ($result.success) { throw ($case + ': failure must not claim success.') }
            if ($case -in @('task_wrong_exe','task_wrong_args','task_wrong_workdir') -and $result.reason -ne 'task_identity_mismatch') { throw ($case + ': wrong failure reason ' + $result.reason) }
            if ($case -in $terminationFailureCases -and $result.reason -ne 'processes_still_running') { throw ($case + ': wrong termination failure reason ' + $result.reason) }
        }
        elseif (-not $result.success) { throw ($case + ': result failed: ' + $result.reason) }
        $flag = Test-Path -LiteralPath (Join-Path $dir 'shutdown-request.flag')
        if ($flag -ne ($case -in $stopCases)) { throw ($case + ': incorrect shutdown barrier lifetime') }
        $mapped = [IO.File]::ReadAllText($hosts).Contains('CODEX-DURABLE-RELAY-V2')
        if ($mapped -ne ($case -notin @('stop','owner_logoff','task_wrong_exe','task_wrong_args','task_wrong_workdir','orphan_node','orphan_launcher','orphan_tray','unrelated_process','unrelated_owner','listener_present','process_query_failure','owner_query_failure','listener_query_failure'))) { throw ($case + ': wrong mapping result') }
        $passed++
    }
    Write-Output ($passed.ToString() + ' lifecycle entrypoint cases passed; no system hosts or tasks touched.')
} finally {
    $resolved = [IO.Path]::GetFullPath($testRoot)
    if ([IO.Path]::GetDirectoryName($resolved) -ne [IO.Path]::GetFullPath($PSScriptRoot) -or -not [IO.Path]::GetFileName($resolved).StartsWith('.lifecycle-test-')) { throw 'Unexpected test cleanup path' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
