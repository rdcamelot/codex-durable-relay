$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$source = [IO.File]::ReadAllText((Join-Path $root 'src\Install-CodexRelay.ps1'))
$body = $source.Substring($source.IndexOf('$createdUserTask = $false'))
$testRoot = Join-Path $PSScriptRoot ('.install-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
$passed = 0
try {
    foreach ($case in @('late_failure','cleanup_failure','invalid_runtime','success')) {
        $dir = Join-Path $testRoot $case
        $payload = Join-Path $dir 'payload'
        $install = Join-Path $dir 'install'
        New-Item -ItemType Directory -Path $payload -Force | Out-Null
        $helper = @'
param([switch]$Cleanup)
if ($Cleanup) {
    if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'fail-cleanup')) { exit 1 }
    [IO.File]::WriteAllText((Join-Path (Split-Path $PSScriptRoot -Parent) 'hosts.fixture'), "# preserved`r`n")
}
exit 0
'@
        [IO.File]::WriteAllText((Join-Path $payload 'managed-relay-hosts.ps1'),$helper)
        [IO.File]::WriteAllText((Join-Path $payload 'node.exe'),'fixture only; never executed')
        [IO.File]::WriteAllText((Join-Path $dir 'hosts.fixture'),"# preserved`r`n")
        $escaped = $dir.Replace("'","''")
        $prefix = @'
$ErrorActionPreference = 'Stop'
$dir = '__DIR__'
$case = '__CASE__'
$installRoot = Join-Path $dir 'install'
$PayloadDirectory = Join-Path $dir 'payload'
$NodeSource = Join-Path $PayloadDirectory 'node.exe'
$NodeHash = (Get-FileHash -LiteralPath $NodeSource).Hash
$allowedFiles = @('managed-relay-hosts.ps1')
$manifest = @{files=@(@{name='managed-relay-hosts.ps1';sha256=(Get-FileHash -LiteralPath (Join-Path $PayloadDirectory 'managed-relay-hosts.ps1')).Hash})}
$OwnerSid = 'S-1-5-21-111-222-333-1001'
$OwnerName = 'fixture\用户'
$StateDirectory = 'C:\Users\用户\AppData\Local\CodexDurableRelay'
$ProxyPort = 8899
$hostsPath = Join-Path $dir 'hosts.fixture'
$powerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$userTaskName = 'fixture-user'
$helperTaskName = 'fixture-helper'
$serviceName = 'fixture-service'
$script:tasks = @{}
$script:service = $null
function Set-ProtectedDirectoryAcl { param($Directory,$UserSid,$UserWrite) }
function Get-AuthenticodeSignature {
    param($LiteralPath)
    [pscustomobject]@{Status=$(if($case -eq 'invalid_runtime'){'NotSigned'}else{'Valid'});SignerCertificate=[pscustomobject]@{Subject='CN=Node.js, O=OpenJS Foundation'}}
}
function New-ScheduledTaskAction { param($Execute,$Argument,$WorkingDirectory); @{} }
function New-ScheduledTaskTrigger { param([switch]$AtLogOn,$User,[switch]$AtStartup,[switch]$Once,$At,$RepetitionInterval); @{} }
function New-ScheduledTaskPrincipal { param($UserId,$LogonType,$RunLevel); @{} }
function New-ScheduledTaskSettingsSet { param($MultipleInstances,[switch]$AllowStartIfOnBatteries,[switch]$DontStopIfGoingOnBatteries,$ExecutionTimeLimit,[switch]$StartWhenAvailable); @{} }
function Register-ScheduledTask { param($TaskName,$Action,$Trigger,$Principal,$Settings,$Description); $script:tasks[$TaskName]='Ready' }
function Start-ScheduledTask {
    param($TaskName)
    $script:tasks[$TaskName]='Running'
    if($TaskName -eq $userTaskName) {
        if($case -eq 'cleanup_failure') { [IO.File]::WriteAllText((Join-Path $installRoot 'fail-cleanup'),'fixture') }
        [IO.File]::WriteAllText($hostsPath,"# preserved`r`n127.0.0.2 codex-cloud-backend.chatgpt.com # CODEX-DURABLE-RELAY-V2`r`n")
        if($case -in @('late_failure','cleanup_failure')) { throw 'injected failure with private data' }
    }
}
function Disable-ScheduledTask { param($TaskName); $script:tasks[$TaskName]='Disabled' }
function Stop-ScheduledTask { param($TaskName); if($script:tasks.ContainsKey($TaskName)){$script:tasks[$TaskName]='Stopped'} }
function Unregister-ScheduledTask { param($TaskName,[switch]$Confirm); $script:tasks.Remove($TaskName) }
function Get-ScheduledTask { param($TaskName); if($script:tasks.ContainsKey($TaskName)){[pscustomobject]@{State=$script:tasks[$TaskName]}} }
function New-Service { param($Name,$BinaryPathName,$DisplayName,$Description,$StartupType,$DependsOn); $script:service=[pscustomobject]@{Status='Stopped';StartType=$StartupType} }
function Start-Service { param($Name); $script:service.Status='Running' }
function Set-Service { param($Name,$StartupType); $script:service.StartType=$StartupType }
function Stop-Service { param($Name); $script:service.Status='Stopped' }
function Get-Service { param($Name); $script:service }
function Invoke-FixtureSc { param($Verb,$Name,$Dacl); $global:LASTEXITCODE=0; if($Verb -eq 'delete'){$script:service=$null} }
function New-FixtureScheduler {
    $obj=New-Object psobject
    $obj|Add-Member ScriptMethod Connect {}
    $obj|Add-Member ScriptMethod GetFolder {param($Name);$this}
    $obj|Add-Member ScriptMethod GetTask {param($Name);$this}
    $obj|Add-Member ScriptMethod SetSecurityDescriptor {param($Value,$Flags)}
    return $obj
}
'@
        # Execute the transaction against temporary files and mocked OS boundaries.
        $fixtureBody = $body.Replace('$PSScriptRoot','$PayloadDirectory').Replace('& "$env:SystemRoot\System32\sc.exe"','Invoke-FixtureSc').Replace("New-Object -ComObject 'Schedule.Service'",'New-FixtureScheduler')
        $suffix = @'
} catch { $failed=$true }
@{failed=$failed;tasks=@($script:tasks.Keys);service=$script:service} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $dir 'observed.json') -Encoding UTF8
'@
        $fixture = Join-Path $dir 'entry.ps1'
        [IO.File]::WriteAllText($fixture,($prefix.Replace('__DIR__',$escaped).Replace('__CASE__',$case)+"`n`$failed=`$false`ntry {`n"+$fixtureBody+"`n"+$suffix),(New-Object Text.UTF8Encoding($true)))
        & (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -NoProfile -NonInteractive -File $fixture | Out-Null
        if($LASTEXITCODE -ne 0){throw ($case+': fixture did not complete')}
        $observed = Get-Content -LiteralPath (Join-Path $dir 'observed.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        if($observed.failed -ne ($case -ne 'success')){throw ($case+': wrong transaction outcome')}
        if($case -ne 'success') {
            if(@($observed.tasks).Count -ne 0 -or $null -ne $observed.service){throw ($case+': executable registration remains')}
            $result=Get-Content -LiteralPath (Join-Path $install 'install-result.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            if($result.success -or $result.PSObject.Properties['errorMessage']){throw ($case+': unsafe failure result')}
            if($case -eq 'cleanup_failure') {
                if($result.mappingRemoved){throw 'Cleanup failure claimed success'}
            } elseif([IO.File]::ReadAllText((Join-Path $dir 'hosts.fixture')).Contains('CODEX-DURABLE-RELAY-V2')) {
                throw ($case+': owned hosts mapping remains')
            }
        } else {
            $settings=Get-Content -LiteralPath (Join-Path $install 'settings.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            if($settings.ownerName -ne 'fixture\用户' -or $settings.proxyPort -ne 8899){throw 'Unicode settings or proxyPort not preserved'}
            if($observed.service.StartType -ne 'Automatic'){throw 'Successful service not automatic'}
        }
        $passed++
    }
    Write-Output ($passed.ToString()+' installation transaction cases passed; no OS registration or hosts changes.')
} finally {
    $resolved=[IO.Path]::GetFullPath($testRoot)
    if([IO.Path]::GetDirectoryName($resolved) -ne [IO.Path]::GetFullPath($PSScriptRoot) -or -not [IO.Path]::GetFileName($resolved).StartsWith('.install-test-')){throw 'Unexpected test cleanup path'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
