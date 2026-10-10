$ErrorActionPreference='Stop'
$outputs=Join-Path (Split-Path $PSScriptRoot -Parent) 'src'
$source=[IO.File]::ReadAllText((Join-Path $outputs 'managed-relay-hosts.ps1'))
$split=$source.IndexOf('$settings = $null')
$prefix=$source.Substring(0,$split).Replace('$PSScriptRoot',("'"+$outputs.Replace("'","''")+"'"))
$main=$source.Substring($split)
$testDirectory=Join-Path $PSScriptRoot ('.helper-entry-test-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testDirectory | Out-Null
try {
    foreach($case in @('absent','cleanup','cleanup_io_failure','shutdown_gate')) {
        $resultFile=Join-Path $testDirectory ($case+'.json')
        $fixture=Join-Path $testDirectory ($case+'.ps1')
        $mockPlan=if($case -eq 'cleanup_io_failure') {"throw (New-Object IO.IOException('injected lock'))"} else {"return [pscustomobject]@{Action='NoChange';Reason='no_owned_mapping'}"}
        $mocks=@"
function Get-ManagedRelaySettings { return [pscustomobject]@{OwnerSid='test'} }
function Get-ManagedRelayListenerSnapshot { param(`$Settings); return [pscustomobject]@{State='Absent';Reason='listener_absent';Identity=`$null} }
function Invoke-ManagedFixedHostsPlan { param(`$Mode); $mockPlan }
function Write-ManagedHelperStatus {
 param(`$Action,`$Status,`$Reason,`$RelayPid)
 @{status=`$Status;reason=`$Reason} | ConvertTo-Json | Set-Content -LiteralPath '$($resultFile.Replace("'","''"))' -Encoding ASCII
 return `$true
}
"@
        if ($case -eq 'shutdown_gate') {
            $mocks += @'

function Test-Path { param($LiteralPath); return $LiteralPath.EndsWith('shutdown-request.flag') }
function Get-ManagedRelayListenerSnapshot { param($Settings); throw 'Shutdown gate must not reconcile a live listener.' }
'@
        }
        [IO.File]::WriteAllText($fixture,($prefix+"`n"+$mocks+"`n"+$main),(New-Object Text.UTF8Encoding($true)))
        $arguments=@('-NoProfile','-NonInteractive','-File',$fixture)
        if($case -eq 'cleanup') {$arguments+='-Cleanup'}
        & (Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe') @arguments
        $expectedExit=if($case -eq 'cleanup_io_failure'){1}else{0}
        if($LASTEXITCODE -ne $expectedExit){throw ($case+': unexpected exit '+$LASTEXITCODE)}
        $result=Get-Content -LiteralPath $resultFile -Raw | ConvertFrom-Json
        $expectedStatus=if($case -eq 'cleanup_io_failure'){'error'}else{'unmapped'}
        if($result.status -ne $expectedStatus){throw ($case+': wrong status')}
    }
    Write-Output '4 helper entrypoint checks passed (no system hosts changes).'
} finally {
    $resolved=[IO.Path]::GetFullPath($testDirectory)
    if([IO.Path]::GetDirectoryName($resolved) -ne [IO.Path]::GetFullPath($PSScriptRoot) -or -not [IO.Path]::GetFileName($resolved).StartsWith('.helper-entry-test-')) {throw 'Unexpected test cleanup path'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
