$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'src\managed-hosts-lib.ps1')

$script:assertions = 0
function Assert-Equal {
    param([Parameter(Mandatory = $true)]$Actual, [Parameter(Mandatory = $true)]$Expected, [Parameter(Mandatory = $true)][string]$Message)
    $script:assertions++
    if ($Actual -cne $Expected) { throw "$Message. Expected [$Expected], got [$Actual]." }
}
function Assert-BytesEqual {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Actual, [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Expected, [Parameter(Mandatory = $true)][string]$Message)
    $script:assertions++
    if ($Actual.Length -ne $Expected.Length) { throw "$Message. Length mismatch." }
    for ($index = 0; $index -lt $Actual.Length; $index++) {
        if ($Actual[$index] -ne $Expected[$index]) { throw "$Message. Byte mismatch at $index." }
    }
}
function AsciiBytes([string]$Text) { return [Text.Encoding]::ASCII.GetBytes($Text) }
function Get-AccessSnapshot([string]$Path) {
    $acl = Get-Acl -LiteralPath $Path
    # ReplaceFile may normalize the SE_DACL_AUTO_INHERITED descriptor bit.
    # Compare identities, protection and every ACE, not that bookkeeping bit.
    $rules = @($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]) | ForEach-Object {
        '{0}|{1}|{2}|{3}|{4}|{5}' -f $_.IdentityReference.Value,[int]$_.FileSystemRights,[int]$_.AccessControlType,$_.IsInherited,[int]$_.InheritanceFlags,[int]$_.PropagationFlags
    } | Sort-Object)
    return (@($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value,$acl.GetGroup([Security.Principal.SecurityIdentifier]).Value,$acl.AreAccessRulesProtected,$acl.AreAccessRulesCanonical) + $rules) -join "`n"
}

$owned = Get-ManagedRelayHostsLine
$normal = AsciiBytes "# preserve this comment`r`n127.0.0.1 localhost`r`n"
$appendPlan = Get-ManagedHostsPlan -Bytes $normal -Mode Reconcile
Assert-Equal $appendPlan.Action 'Append' 'A normal hosts file must append the managed mapping'
Assert-BytesEqual ($appendPlan.Bytes[0..($normal.Length - 1)]) $normal 'Appending must preserve every existing byte'
Assert-Equal ([Text.Encoding]::ASCII.GetString($appendPlan.Bytes)).EndsWith($owned + "`r`n") $true 'The appended line must be canonical'

$windowsBlankLines = AsciiBytes "# normal Windows hosts comment`r`n`r`n127.0.0.1 localhost`r`n`r`n# another comment`r`n"
$windowsBlankAppend = Get-ManagedHostsPlan -Bytes $windowsBlankLines -Mode Reconcile
Assert-Equal $windowsBlankAppend.Action 'Append' 'Blank lines in a normal Windows hosts file must be accepted'
Assert-BytesEqual ($windowsBlankAppend.Bytes[0..($windowsBlankLines.Length - 1)]) $windowsBlankLines 'Blank lines and comments must retain their original bytes'
$windowsBlankCleanup = Get-ManagedHostsPlan -Bytes $windowsBlankAppend.Bytes -Mode Cleanup
Assert-Equal $windowsBlankCleanup.Action 'Remove' 'The appended line after blank lines must be removable'
Assert-BytesEqual $windowsBlankCleanup.Bytes $windowsBlankLines 'Blank-line hosts input must round-trip exactly'

$emptyHosts = New-Object byte[] 0
$emptyAppend = Get-ManagedHostsPlan -Bytes $emptyHosts -Mode Reconcile
Assert-Equal $emptyAppend.Action 'Append' 'An empty hosts file must be accepted'
$emptyCleanup = Get-ManagedHostsPlan -Bytes $emptyAppend.Bytes -Mode Cleanup
Assert-Equal $emptyCleanup.Action 'Remove' 'An appended mapping in an empty hosts file must be removable'
Assert-BytesEqual $emptyCleanup.Bytes $emptyHosts 'An empty hosts file must round-trip exactly'

$onlyOwned = AsciiBytes ($owned + "`r`n")
$onlyOwnedCleanup = Get-ManagedHostsPlan -Bytes $onlyOwned -Mode Cleanup
Assert-Equal $onlyOwnedCleanup.Action 'Remove' 'A hosts file containing only the owned line must be cleaned'
Assert-BytesEqual $onlyOwnedCleanup.Bytes $emptyHosts 'Cleaning the only owned line must produce an empty byte array'

$canonical = AsciiBytes ("alpha`n" + $owned + "`n" + 'omega' + "`n")
$presentPlan = Get-ManagedHostsPlan -Bytes $canonical -Mode Reconcile
Assert-Equal $presentPlan.Action 'NoChange' 'The exact managed mapping must be idempotent'
Assert-BytesEqual $presentPlan.Bytes $canonical 'Idempotency must preserve bytes'
$cleanupPlan = Get-ManagedHostsPlan -Bytes $canonical -Mode Cleanup
Assert-Equal $cleanupPlan.Action 'Remove' 'Cleanup must remove the exact managed mapping'
Assert-BytesEqual $cleanupPlan.Bytes (AsciiBytes "alpha`nomega`n") 'Cleanup must preserve unrelated lines byte-for-byte'

$conflict = AsciiBytes "10.1.1.1 codex-cloud-backend.chatgpt.com # legacy`r`n"
$conflictPlan = Get-ManagedHostsPlan -Bytes $conflict -Mode Reconcile
Assert-Equal $conflictPlan.Action 'Reject' 'A foreign target mapping must not be overwritten'
Assert-Equal $conflictPlan.Reason 'hosts_conflicting_mapping' 'Foreign mapping must report the conflict'
Assert-BytesEqual $conflictPlan.Bytes $conflict 'Rejecting a foreign mapping must leave bytes untouched'

$modifiedMarker = AsciiBytes "127.0.0.2 codex-cloud-backend.chatgpt.com # CODEX-DURABLE-RELAY-V2 modified`r`n"
$markerPlan = Get-ManagedHostsPlan -Bytes $modifiedMarker -Mode Reconcile
Assert-Equal $markerPlan.Reason 'hosts_modified_marker' 'A changed marker line must never be adopted'

$nullBytes = New-Object byte[] 4
$nullBytes[0] = 65; $nullBytes[1] = 0; $nullBytes[2] = 66; $nullBytes[3] = 10
$nullPlan = Get-ManagedHostsPlan -Bytes $nullBytes -Mode Reconcile
Assert-Equal $nullPlan.Reason 'hosts_null_bytes' 'A hosts file with NUL bytes must be rejected'

$duplicate = AsciiBytes ($owned + "`r`n" + $owned + "`r`n")
$duplicatePlan = Get-ManagedHostsPlan -Bytes $duplicate -Mode Reconcile
Assert-Equal $duplicatePlan.Reason 'hosts_duplicate_owned_mapping' 'Duplicate owned mappings must be rejected during reconcile'

$noTerminalNewline = AsciiBytes '127.0.0.1 localhost'
$unterminatedPlan = Get-ManagedHostsPlan -Bytes $noTerminalNewline -Mode Reconcile
Assert-Equal $unterminatedPlan.Reason 'hosts_missing_terminal_newline' 'An unterminated foreign line must not be modified'

Assert-Equal (Test-ManagedRelayCommandLine -CommandLine '"C:\Program Files\CodexDurableRelay\node.exe" "C:\Program Files\CodexDurableRelay\managed-relay.cjs" --run' -NodePath 'C:\Program Files\CodexDurableRelay\node.exe' -RelayScriptPath 'C:\Program Files\CodexDurableRelay\managed-relay.cjs') $true 'The exact relay command line must pass'
Assert-Equal (Test-ManagedRelayCommandLine -CommandLine '"C:\Program Files\CodexDurableRelay\node.exe" "C:\Program Files\CodexDurableRelay\managed-relay.cjs" --run --extra' -NodePath 'C:\Program Files\CodexDurableRelay\node.exe' -RelayScriptPath 'C:\Program Files\CodexDurableRelay\managed-relay.cjs') $false 'Additional relay arguments must fail'
Assert-Equal (Test-ManagedRelayCommandLine -CommandLine 'C:\Program Files\CodexDurableRelay\node.exe "C:\Program Files\CodexDurableRelay\managed-relay.cjs" --run' -NodePath 'C:\Program Files\CodexDurableRelay\node.exe' -RelayScriptPath 'C:\Program Files\CodexDurableRelay\managed-relay.cjs') $true 'An unquoted executable path from CIM must keep the exact relay argv valid'

$temporaryHosts = Join-Path $PSScriptRoot ('managed-hosts-' + [Guid]::NewGuid().ToString('N') + '.tmp')
$temporaryBackup = Join-Path $PSScriptRoot ('managed-hosts-backup-' + [Guid]::NewGuid().ToString('N') + '.tmp')
try {
    [IO.File]::WriteAllBytes($temporaryHosts, $normal)
    $hostsAclBefore = Get-AccessSnapshot $temporaryHosts
    $filePlan = Invoke-ManagedHostsFilePlan -HostsPath $temporaryHosts -BackupPath $temporaryBackup -Mode Reconcile
    Assert-Equal $filePlan.Action 'Append' 'The file transaction must append in a temporary hosts file'
    $afterAppend = [IO.File]::ReadAllBytes($temporaryHosts)
    Assert-BytesEqual $afterAppend $filePlan.Bytes 'The transaction result must match the bytes on disk'
    Assert-Equal ((Get-AccessSnapshot $temporaryHosts) -ceq $hostsAclBefore) $true 'Atomic replacement must retain destination ownership and access rules'
    Assert-BytesEqual ([IO.File]::ReadAllBytes($temporaryBackup)) $normal 'Atomic replacement must retain the original hosts bytes in the protected backup'
    $fileCleanup = Invoke-ManagedHostsFilePlan -HostsPath $temporaryHosts -BackupPath $temporaryBackup -Mode Cleanup
    Assert-Equal $fileCleanup.Action 'Remove' 'The file transaction must clean its exact temporary mapping'
    Assert-BytesEqual ([IO.File]::ReadAllBytes($temporaryHosts)) $normal 'Temporary cleanup must restore the original bytes'
    Assert-Equal ((Get-AccessSnapshot $temporaryHosts) -ceq $hostsAclBefore) $true 'Cleanup must retain destination ownership and access rules'

    $protectedAcl = [IO.File]::GetAccessControl($temporaryHosts)
    $protectedAcl.SetAccessRuleProtection($true,$true)
    [IO.File]::SetAccessControl($temporaryHosts,$protectedAcl)
    $protectedBefore = Get-AccessSnapshot $temporaryHosts
    [void](Invoke-ManagedHostsFilePlan -HostsPath $temporaryHosts -BackupPath $temporaryBackup -Mode Reconcile)
    Assert-Equal ((Get-AccessSnapshot $temporaryHosts) -ceq $protectedBefore) $true 'Append must preserve a protected DACL and its explicit rules'
    [void](Invoke-ManagedHostsFilePlan -HostsPath $temporaryHosts -BackupPath $temporaryBackup -Mode Cleanup)
    Assert-Equal ((Get-AccessSnapshot $temporaryHosts) -ceq $protectedBefore) $true 'Cleanup must preserve a protected DACL and its explicit rules'

    # A failure before ReplaceFile must leave the original hosts file intact;
    # this models an unavailable protected backup directory without touching the
    # real hosts file.
    $missingBackup = Join-Path (Join-Path $PSScriptRoot ('missing-' + [Guid]::NewGuid().ToString('N'))) 'backup.bin'
    $replaceFailed = $false
    try { [void](Invoke-ManagedHostsFilePlan -HostsPath $temporaryHosts -BackupPath $missingBackup -Mode Reconcile) } catch { $replaceFailed = $true }
    Assert-Equal $replaceFailed $true 'A replace failure must be surfaced'
    Assert-BytesEqual ([IO.File]::ReadAllBytes($temporaryHosts)) $normal 'A failed replacement must not truncate or alter unrelated hosts bytes'
} finally {
    if (Test-Path -LiteralPath $temporaryHosts) { Remove-Item -LiteralPath $temporaryHosts -Force }
    if (Test-Path -LiteralPath $temporaryBackup) { Remove-Item -LiteralPath $temporaryBackup -Force }
}

Write-Output ("managed-hosts tests passed: " + $script:assertions)
