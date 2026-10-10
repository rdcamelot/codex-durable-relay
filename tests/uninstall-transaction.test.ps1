$ErrorActionPreference = 'Stop'
$root=Split-Path $PSScriptRoot -Parent
$source=[IO.File]::ReadAllText((Join-Path $root 'src\Manage-CodexRelay.ps1'))
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'src\Manage-CodexRelay.ps1'),[ref]$tokens,[ref]$errors)
$switch=$ast.FindAll({param($n) $n -is [Management.Automation.Language.SwitchStatementAst] -and $n.Condition.Extent.Text -eq '$Action'},$true)[0]
$block=($switch.Clauses | Where-Object {$_.Item1.Value -eq 'Uninstall'}).Item2.Extent.Text
$body=$block.Substring(1,$block.Length-2)
$testRoot=Join-Path $PSScriptRoot ('.uninstall-test-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
    foreach($case in @('cleanup_failure','success','service_delete_failure','service_delete_pending')) {
        $dir=Join-Path $testRoot $case
        $install=Join-Path $dir 'CodexDurableRelay'
        New-Item -ItemType Directory -Path $install -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $install 'managed-relay-hosts.ps1'),$(if($case -eq 'cleanup_failure'){'param([switch]$Cleanup); exit 1'}else{'param([switch]$Cleanup); exit 0'}))
        $prefix=@'
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.ServiceProcess
$dir='__DIR__'
$case='__CASE__'
$installRoot=Join-Path $dir 'CodexDurableRelay'
$userTaskName='fixture-user'; $helperTaskName='fixture-helper'
$script:registered=$true; $script:tasks=@($userTaskName,$helperTaskName)
$script:firstDelete=$true
function Get-Service {
    param($Name)
    if($script:registered){
        $value=[pscustomobject]@{Status='Stopped'}
        $value|Add-Member ScriptMethod WaitForStatus {param($Status,$Timeout)}
        $value|Add-Member ScriptMethod Dispose {}
        return $value
    }
}
function Stop-Service {param($Name)}
function Stop-ScheduledTask {param($TaskName)}
function Get-ScheduledTask {param($TaskName);if($TaskName -in $script:tasks){[pscustomobject]@{TaskName=$TaskName}}}
function Get-NetTCPConnection {param($LocalAddress,$LocalPort,$State)}
function Start-Sleep {param($Seconds,$Milliseconds)}
function Unregister-ScheduledTask {param($TaskName,[switch]$Confirm);if($TaskName -notin $script:tasks){throw 'Missing task'};$script:tasks=@($script:tasks|Where-Object {$_ -ne $TaskName})}
function Invoke-FixtureSc {
    param($Verb,$Name)
    $global:LASTEXITCODE=0
    if($Verb -eq 'delete') {
        if($script:firstDelete -and $case -eq 'service_delete_failure') {$script:firstDelete=$false;$global:LASTEXITCODE=5;return}
        if($script:firstDelete -and $case -eq 'service_delete_pending') {$script:firstDelete=$false;return}
        $script:registered=$false
    }
}
$failed=$false
function Invoke-FixtureUninstall {
'@
        $suffix=@'
}
try {Invoke-FixtureUninstall} catch {$failed=$true}
if($case -in @('service_delete_failure','service_delete_pending')) {
    if(-not $failed -or -not $script:registered -or -not (Test-Path -LiteralPath $installRoot)){throw 'Failure must keep repair files'}
    $failed=$false
    try {Invoke-FixtureUninstall} catch {$failed=$true}
}
@{failed=$failed;registered=$script:registered;tasks=$script:tasks;directoryPresent=(Test-Path -LiteralPath $installRoot)}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $dir 'observed.json') -Encoding UTF8
'@
        $fixtureBody=$body.Replace('$PSScriptRoot','$installRoot').Replace('$env:ProgramFiles','$dir').Replace('& "$env:SystemRoot\System32\sc.exe"','Invoke-FixtureSc')
        if($case -eq 'service_delete_pending') {$fixtureBody=$fixtureBody.Replace('.AddSeconds(10)','.AddSeconds(-1)')}
        $fixture=Join-Path $dir 'entry.ps1'
        [IO.File]::WriteAllText($fixture,($prefix.Replace('__DIR__',$dir.Replace("'","''")).Replace('__CASE__',$case)+"`n"+$fixtureBody+"`n"+$suffix),(New-Object Text.UTF8Encoding($true)))
        & (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -NoProfile -NonInteractive -File $fixture | Out-Null
        if($LASTEXITCODE -ne 0){throw 'Uninstall fixture did not finish'}
        $result=Get-Content -LiteralPath (Join-Path $dir 'observed.json') -Raw -Encoding UTF8|ConvertFrom-Json
        if($case -eq 'cleanup_failure') {
            if(-not $result.failed -or -not $result.registered -or @($result.tasks).Count -ne 2 -or -not $result.directoryPresent){throw 'Failed cleanup must retain the service, tasks and installation for recovery'}
        } elseif($result.failed -or $result.registered -or @($result.tasks).Count -ne 0 -or $result.directoryPresent){throw 'Successful uninstall must remove only its registrations and directory'}
    }
    $start=$source.IndexOf("if (`$Action -in @('EnableAutostart'")
    $end=$source.IndexOf('switch ($Action)', $start)
    $elevation=$source.Substring($start,$end-$start)
    $preflight=@'
$Action='Uninstall'
$ErrorActionPreference='Stop'
$principal=New-Object psobject
$principal|Add-Member ScriptMethod IsInRole {param($Role);return $false}
function Stop-Relay {throw 'Missing tasks must not prevent uninstall elevation'}
function Start-Process {param($FilePath,$Verb,$WindowStyle,$ArgumentList,[switch]$Wait,[switch]$PassThru);[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'elevated.fixture'),'called');[pscustomobject]@{ExitCode=0}}
'@
    $fixture=Join-Path $testRoot 'preflight.ps1'
    [IO.File]::WriteAllText($fixture,($preflight+"`n"+$elevation),(New-Object Text.UTF8Encoding($true)))
    & (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -NoProfile -NonInteractive -File $fixture | Out-Null
    if($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath (Join-Path $testRoot 'elevated.fixture'))){throw 'Normal-user retry must reach the protected uninstaller without missing-task failure'}
    Write-Output '5 uninstall transaction cases passed; only temporary files and mocked registrations were used.'
} finally {
    $resolved=[IO.Path]::GetFullPath($testRoot)
    if([IO.Path]::GetDirectoryName($resolved) -ne [IO.Path]::GetFullPath($PSScriptRoot) -or -not [IO.Path]::GetFileName($resolved).StartsWith('.uninstall-test-')){throw 'Unexpected test cleanup path'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
