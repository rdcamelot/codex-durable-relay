$ErrorActionPreference = 'Stop'
$outputs = Join-Path (Split-Path $PSScriptRoot -Parent) 'src'
$source = [IO.File]::ReadAllText((Join-Path $outputs 'Shutdown-CodexRelay.ps1'))
$source = $source.Substring($source.IndexOf(". (Join-Path `$installRoot 'managed-hosts-lib.ps1')"))
$testRoot = Join-Path $PSScriptRoot ('.lifecycle-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
$passed = 0
try {
    foreach ($case in @('stop','initialize','owner_logoff','other_session','wrong_owner','wrong_exe','wrong_command','helper_failure')) {
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
        $sid = if ($case -eq 'wrong_owner') { 'S-1-5-21-111-222-333-9999' } else { 'S-1-5-21-111-222-333-1001' }
        $exe = if ($case -eq 'wrong_exe') { 'other.exe' } else { 'node.exe' }
        $suffix = if ($case -eq 'wrong_command') { '--run --eval malicious' } else { '--run' }
        $prefix = @"
param([string]`$Mode,[uint32]`$SessionId=1)
`$ErrorActionPreference='Stop'
`$installRoot='$escaped'
`$userTaskName='Codex Durable Relay - User'
`$flagPath=Join-Path `$installRoot 'shutdown-request.flag'
`$resultPath=Join-Path `$installRoot 'lifecycle-cleanup-result.json'
function Get-CimInstance {
 param(`$ClassName,`$Filter)
 [pscustomobject]@{ExecutablePath=(Join-Path `$installRoot '$exe');SessionId=$session;CommandLine=('"'+(Join-Path `$installRoot 'node.exe')+'" "'+(Join-Path `$installRoot 'managed-relay.cjs')+'" $suffix')}
}
function Invoke-CimMethod { param(`$InputObject,`$MethodName); [pscustomobject]@{ReturnValue=0;Sid='$sid'} }
function Get-ScheduledTask {
 param(`$TaskName)
 [pscustomobject]@{State='Ready';Actions=@([pscustomobject]@{Execute=(Join-Path `$env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe');Arguments='-NoProfile -NonInteractive -WindowStyle Hidden -File "C:\Program Files\CodexDurableRelay\Launch-ManagedRelay.ps1"'})}
}
function Stop-ScheduledTask { throw 'Already stopped fixture must not be killed' }
"@
        $body = $source.Replace("(Join-Path `$env:SystemRoot 'System32\drivers\etc\hosts')",("'" + $hosts.Replace("'","''") + "'"))
        $fixture = Join-Path $dir 'entry.ps1'
        [IO.File]::WriteAllText($fixture,($prefix+"`n"+$body),(New-Object Text.UTF8Encoding($true)))
        $mode = if ($case -eq 'initialize') { 'Initialize' } elseif ($case -in @('stop','helper_failure')) { 'Stop' } else { 'SessionLogoff' }
        & (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -NoProfile -NonInteractive -File $fixture -Mode $mode -SessionId 1
        $expectedExit = if ($case -eq 'helper_failure') { 1 } else { 0 }
        if ($LASTEXITCODE -ne $expectedExit) { throw ($case + ': unexpected exit ' + $LASTEXITCODE) }
        $resultName = if ($case -eq 'initialize') { 'lifecycle-initialize-result.json' } elseif ($case -in @('other_session','wrong_owner','wrong_exe','wrong_command')) { 'lifecycle-session-check.json' } else { 'lifecycle-cleanup-result.json' }
        $result = Get-Content -LiteralPath (Join-Path $dir $resultName) -Raw | ConvertFrom-Json
        if ($case -eq 'helper_failure') { if ($result.success) { throw 'Failure must not claim success.' } }
        elseif (-not $result.success) { throw ($case + ': result failed: ' + $result.reason) }
        $flag = Test-Path -LiteralPath (Join-Path $dir 'shutdown-request.flag')
        if ($flag -ne ($case -in @('stop','helper_failure'))) { throw ($case + ': incorrect shutdown barrier lifetime') }
        $mapped = [IO.File]::ReadAllText($hosts).Contains('CODEX-DURABLE-RELAY-V2')
        if ($mapped -ne ($case -notin @('stop','owner_logoff'))) { throw ($case + ': wrong mapping result') }
        $passed++
    }
    Write-Output ($passed.ToString() + ' lifecycle entrypoint cases passed; no system hosts or tasks touched.')
} finally {
    $resolved = [IO.Path]::GetFullPath($testRoot)
    if ([IO.Path]::GetDirectoryName($resolved) -ne [IO.Path]::GetFullPath($PSScriptRoot) -or -not [IO.Path]::GetFileName($resolved).StartsWith('.lifecycle-test-')) { throw 'Unexpected test cleanup path' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
