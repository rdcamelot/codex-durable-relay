$ErrorActionPreference = 'Stop'

# Import only the helper functions.  The privileged entrypoint is deliberately
# excluded so this test cannot create a task, alter hosts, or read an install.
$outputs = Join-Path (Split-Path $PSScriptRoot -Parent) 'src'
$source = [IO.File]::ReadAllText((Join-Path $outputs 'managed-relay-hosts.ps1'))
$split = $source.IndexOf('$settings = $null')
if ($split -lt 0) { throw 'Could not isolate managed helper functions.' }
$prefix = $source.Substring(0, $split).Replace('$PSScriptRoot', ("'" + $outputs.Replace("'", "''") + "'"))
. ([scriptblock]::Create($prefix))

$script:assertions = 0
function Assert-Equal {
    param([Parameter(Mandatory = $true)]$Actual, [Parameter(Mandatory = $true)]$Expected, [Parameter(Mandatory = $true)][string]$Message)
    $script:assertions++
    if ($Actual -cne $Expected) { throw "$Message. Expected [$Expected], got [$Actual]." }
}

$script:nodePath = 'C:\Program Files\CodexDurableRelay\node.exe'
$script:relayPath = 'C:\Program Files\CodexDurableRelay\managed-relay.cjs'
$script:launcherPath = 'C:\Program Files\CodexDurableRelay\Launch-ManagedRelay.ps1'
$script:powerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$script:ownerSid = 'S-1-5-21-1000'
$script:ownerDomain = 'EXAMPLE'
$script:ownerUser = 'relay-user'
$script:settings = [pscustomobject]@{
    OwnerSid = $script:ownerSid
    OwnerName = ($script:ownerDomain + '\' + $script:ownerUser)
    NodePath = $script:nodePath
    RelayScriptPath = $script:relayPath
}

function New-FixtureProcess {
    param(
        [int]$ProcessId,
        [int]$ParentProcessId,
        [string]$ExecutablePath,
        [string]$CommandLine,
        [DateTime]$CreationDate,
        [string]$OwnerSid = $script:ownerSid,
        [string]$OwnerDomain = $script:ownerDomain,
        [string]$OwnerUser = $script:ownerUser
    )
    return [pscustomobject]@{
        ProcessId = $ProcessId
        ParentProcessId = $ParentProcessId
        ExecutablePath = $ExecutablePath
        CommandLine = $CommandLine
        CreationDate = $CreationDate
        ProcessStartTime = $CreationDate
        OwnerSid = $OwnerSid
        OwnerDomain = $OwnerDomain
        OwnerUser = $OwnerUser
    }
}

function Set-IdentityFixture {
    param([Parameter(Mandatory = $true)][string]$Case)

    $parentStart = New-Object DateTime(2026, 10, 10, 0, 0, 0, [DateTimeKind]::Utc)
    $nodeStart = $parentStart.AddSeconds(10)
    $parentCommand = ('"' + $script:powerShellPath + '" -NoProfile -NonInteractive -WindowStyle Hidden -File "' + $script:launcherPath + '"')
    $parent = New-FixtureProcess -ProcessId 202 -ParentProcessId 1 -ExecutablePath $script:powerShellPath -CommandLine $parentCommand -CreationDate $parentStart
    $node = New-FixtureProcess -ProcessId 101 -ParentProcessId 202 -ExecutablePath $script:nodePath -CommandLine ('"' + $script:nodePath + '" "' + $script:relayPath + '" --run') -CreationDate $nodeStart
    $script:fixtures = @{}
    $script:fixtures[101] = $node
    $script:fixtures[202] = $parent

    switch ($Case) {
        'valid' { break }
        'valid_unquoted_launcher_exe' {
            $parent.CommandLine = ($script:powerShellPath + ' -NoProfile -NonInteractive -WindowStyle Hidden -File "' + $script:launcherPath + '"')
            break
        }
        'direct_node_wrong_parent' {
            $parent.ExecutablePath = (Join-Path $env:SystemRoot 'System32\cmd.exe')
            $parent.CommandLine = ('"' + $parent.ExecutablePath + '" /c start node')
            break
        }
        'missing_parent' {
            $node.ParentProcessId = 0
            break
        }
        'launcher_extra_argument' {
            $parent.CommandLine += ' -Command "Write-Output injected"'
            break
        }
        'parent_owner_mismatch' {
            $parent.OwnerSid = 'S-1-5-21-2000'
            $parent.OwnerUser = 'another-user'
            break
        }
        'parent_created_after_node' {
            $parent.CreationDate = $node.CreationDate.AddSeconds(1)
            $parent.ProcessStartTime = $parent.CreationDate
            break
        }
        'parent_process_start_mismatch' {
            $parent.ProcessStartTime = $parent.CreationDate.AddSeconds(3)
            break
        }
        default { throw 'Unknown fixture case.' }
    }
}

function Test-Path {
    param([string]$LiteralPath, [string]$PathType)
    return $true
}

function Get-CimInstance {
    [CmdletBinding()]
    param([string]$ClassName, [string]$Filter)
    if ($ClassName -ne 'Win32_Process') { throw 'Unexpected CIM class.' }
    $match = [Regex]::Match($Filter, 'ProcessId\s*=\s*(\d+)$')
    if (-not $match.Success) { throw 'Unexpected CIM filter.' }
    return $script:fixtures[[int]$match.Groups[1].Value]
}

function Invoke-CimMethod {
    [CmdletBinding()]
    param($InputObject, [string]$MethodName)
    switch ($MethodName) {
        'GetOwnerSid' { return [pscustomobject]@{ ReturnValue = 0; Sid = $InputObject.OwnerSid } }
        'GetOwner' { return [pscustomobject]@{ ReturnValue = 0; Domain = $InputObject.OwnerDomain; User = $InputObject.OwnerUser } }
        default { throw 'Unexpected CIM method.' }
    }
}

function Get-Process {
    [CmdletBinding()]
    param([int]$Id)
    $fixture = $script:fixtures[$Id]
    if ($null -eq $fixture) { throw 'Fixture process is missing.' }
    return [pscustomobject]@{ StartTime = $fixture.ProcessStartTime }
}

function Get-NetTCPConnection {
    [CmdletBinding()]
    param([string]$State)
    return [pscustomobject]@{ LocalAddress = '127.0.0.2'; LocalPort = 443; OwningProcess = 101 }
}

$cases = @(
    @{ Name = 'valid'; ExpectedState = 'Valid' },
    @{ Name = 'valid_unquoted_launcher_exe'; ExpectedState = 'Valid' },
    @{ Name = 'direct_node_wrong_parent'; ExpectedState = 'Invalid' },
    @{ Name = 'missing_parent'; ExpectedState = 'Invalid' },
    @{ Name = 'launcher_extra_argument'; ExpectedState = 'Invalid' },
    @{ Name = 'parent_owner_mismatch'; ExpectedState = 'Invalid' },
    @{ Name = 'parent_created_after_node'; ExpectedState = 'Invalid' },
    @{ Name = 'parent_process_start_mismatch'; ExpectedState = 'Invalid' }
)
foreach ($case in $cases) {
    Set-IdentityFixture -Case $case.Name
    $snapshot = Get-ManagedRelayListenerSnapshot -Settings $script:settings
    Assert-Equal $snapshot.State $case.ExpectedState ($case.Name + ' listener identity')
}

Set-IdentityFixture -Case 'valid'
$initial = (Get-ManagedRelayListenerSnapshot -Settings $script:settings).Identity
Assert-Equal $initial.ParentProcessId 202 'A valid identity must retain its launcher PID'
Assert-Equal $initial.ParentCommandLine ('"' + $script:powerShellPath + '" -NoProfile -NonInteractive -WindowStyle Hidden -File "' + $script:launcherPath + '"') 'A valid identity must retain its launcher command line'

# The Node PID and its immutable identity stay unchanged, while a different
# otherwise valid launcher becomes its parent between the two helper reads.
$script:fixtures[303] = New-FixtureProcess -ProcessId 303 -ParentProcessId 1 -ExecutablePath $script:powerShellPath -CommandLine ('"' + $script:powerShellPath + '" -NoProfile -NonInteractive -WindowStyle Hidden -File "' + $script:launcherPath + '"') -CreationDate $script:fixtures[202].CreationDate
$script:fixtures[101].ParentProcessId = 303
Assert-Equal (Test-ManagedSameRelayIdentity -InitialIdentity $initial -Settings $script:settings) $false 'Changing only the trusted launcher identity after the write must fail revalidation'

Write-Output ($script:assertions.ToString() + ' managed helper parent checks passed (isolated command mocks only).')
