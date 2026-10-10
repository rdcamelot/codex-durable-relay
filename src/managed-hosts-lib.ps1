Set-StrictMode -Version 2.0

# This library deliberately operates on bytes.  A hosts file is normally an
# ASCII-compatible text file, but rewriting it through a text encoding could
# alter unrelated comments or mappings.  The privileged helper only appends or
# removes its exact ASCII line and otherwise keeps the original bytes intact.

$script:ManagedRelayDomain = 'codex-cloud-backend.chatgpt.com'
$script:ManagedRelayAddress = '127.0.0.2'
$script:ManagedRelayMarker = 'CODEX-DURABLE-RELAY-V2'
$script:ManagedHostsMaximumBytes = 4MB

function Get-ManagedRelayHostsLine {
    [CmdletBinding()]
    param()

    return ($script:ManagedRelayAddress + ' ' + $script:ManagedRelayDomain + ' # ' + $script:ManagedRelayMarker)
}

function Get-ManagedByteSlice {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][int]$Start,
        [Parameter(Mandatory = $true)][int]$Length
    )

    if ($Start -lt 0 -or $Length -lt 0 -or ($Start + $Length) -gt $Bytes.Length) {
        throw 'Invalid byte slice.'
    }
    $copy = New-Object byte[] $Length
    if ($Length -gt 0) { [Array]::Copy($Bytes, $Start, $copy, 0, $Length) }
    return ,$copy
}

function Test-ManagedHostsHasNullByte {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Bytes)

    foreach ($value in $Bytes) {
        if ($value -eq 0) { return $true }
    }
    return $false
}

function Get-ManagedHostsLineRecords {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Bytes)

    $records = New-Object 'System.Collections.Generic.List[object]'
    $lineStart = 0
    for ($index = 0; $index -lt $Bytes.Length; $index++) {
        if ($Bytes[$index] -ne 10) { continue }

        $contentLength = $index - $lineStart
        if ($contentLength -gt 0 -and $Bytes[$index - 1] -eq 13) { $contentLength-- }
        $records.Add([pscustomobject]@{
                Start = $lineStart
                Length = ($index - $lineStart + 1)
                ContentStart = $lineStart
                ContentLength = $contentLength
            }) | Out-Null
        $lineStart = $index + 1
    }
    if ($lineStart -lt $Bytes.Length) {
        $records.Add([pscustomobject]@{
                Start = $lineStart
                Length = ($Bytes.Length - $lineStart)
                ContentStart = $lineStart
                ContentLength = ($Bytes.Length - $lineStart)
            }) | Out-Null
    }
    # Records are objects, so pipeline enumeration is wanted here.  (Byte
    # arrays use a unary comma in their helpers to avoid becoming byte streams.)
    return $records.ToArray()
}

function Get-ManagedAsciiText {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Bytes)

    return [Text.Encoding]::ASCII.GetString($Bytes)
}

function Test-ManagedActiveTargetMapping {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Line)

    $commentIndex = $Line.IndexOf('#')
    if ($commentIndex -ge 0) { $Line = $Line.Substring(0, $commentIndex) }
    $trimmed = $Line.Trim()
    if ($trimmed.Length -eq 0) { return $false }
    $parts = $trimmed -split '[ \t]+'
    if ($parts.Count -lt 2) { return $false }
    for ($index = 1; $index -lt $parts.Count; $index++) {
        if ([String]::Equals($parts[$index], $script:ManagedRelayDomain, [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

function New-ManagedByteArray {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Parts)

    $length = 0
    foreach ($part in $Parts) {
        if ($null -ne $part) { $length += ([byte[]]$part).Length }
    }
    $result = New-Object byte[] $length
    $offset = 0
    foreach ($part in $Parts) {
        if ($null -eq $part) { continue }
        [byte[]]$bytes = $part
        if ($bytes.Length -gt 0) {
            [Array]::Copy($bytes, 0, $result, $offset, $bytes.Length)
            $offset += $bytes.Length
        }
    }
    return ,$result
}

function Get-ManagedHostsPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Bytes,
        [ValidateSet('Reconcile', 'Cleanup')][string]$Mode = 'Reconcile'
    )

    $unchanged = [pscustomobject]@{
        Action = 'NoChange'; Reason = 'no_owned_mapping'; Bytes = $Bytes; OwnedLineCount = 0
    }
    if ($Bytes.Length -gt $script:ManagedHostsMaximumBytes) {
        return [pscustomobject]@{ Action = 'Reject'; Reason = 'hosts_too_large'; Bytes = $Bytes; OwnedLineCount = 0 }
    }
    if (Test-ManagedHostsHasNullByte -Bytes $Bytes) {
        return [pscustomobject]@{ Action = 'Reject'; Reason = 'hosts_null_bytes'; Bytes = $Bytes; OwnedLineCount = 0 }
    }

    $canonicalLine = Get-ManagedRelayHostsLine
    $canonicalLineBytes = [Text.Encoding]::ASCII.GetBytes($canonicalLine)
    $records = @(Get-ManagedHostsLineRecords -Bytes $Bytes)
    $ownedRecords = New-Object 'System.Collections.Generic.List[object]'
    $hasModifiedMarker = $false
    $hasForeignTargetMapping = $false

    foreach ($record in $records) {
        [byte[]]$contentBytes = Get-ManagedByteSlice -Bytes $Bytes -Start $record.ContentStart -Length $record.ContentLength
        $line = Get-ManagedAsciiText -Bytes $contentBytes
        $hasMarker = $line.IndexOf($script:ManagedRelayMarker, [StringComparison]::OrdinalIgnoreCase) -ge 0
        $isCanonical = [String]::Equals($line, $canonicalLine, [StringComparison]::Ordinal)
        if ($hasMarker) {
            if ($isCanonical) { $ownedRecords.Add($record) | Out-Null } else { $hasModifiedMarker = $true }
            continue
        }
        if (Test-ManagedActiveTargetMapping -Line $line) { $hasForeignTargetMapping = $true }
    }

    if ($hasModifiedMarker) {
        return [pscustomobject]@{ Action = 'Reject'; Reason = 'hosts_modified_marker'; Bytes = $Bytes; OwnedLineCount = $ownedRecords.Count }
    }

    if ($Mode -eq 'Reconcile') {
        if ($hasForeignTargetMapping) {
            return [pscustomobject]@{ Action = 'Reject'; Reason = 'hosts_conflicting_mapping'; Bytes = $Bytes; OwnedLineCount = $ownedRecords.Count }
        }
        if ($ownedRecords.Count -gt 1) {
            return [pscustomobject]@{ Action = 'Reject'; Reason = 'hosts_duplicate_owned_mapping'; Bytes = $Bytes; OwnedLineCount = $ownedRecords.Count }
        }
        if ($ownedRecords.Count -eq 1) {
            return [pscustomobject]@{ Action = 'NoChange'; Reason = 'mapping_present'; Bytes = $Bytes; OwnedLineCount = 1 }
        }

        # Refuse a file whose final line has no line ending.  Adding a separator
        # would change an unrelated line, and then cannot be distinguished from
        # the original bytes during cleanup.
        if ($Bytes.Length -gt 0 -and $Bytes[$Bytes.Length - 1] -ne 10) {
            return [pscustomobject]@{ Action = 'Reject'; Reason = 'hosts_missing_terminal_newline'; Bytes = $Bytes; OwnedLineCount = 0 }
        }
        $lineEnding = [Text.Encoding]::ASCII.GetBytes("`r`n")
        foreach ($record in $records) {
            if ($record.Length -ge 2 -and $Bytes[$record.Start + $record.Length - 2] -ne 13) {
                $lineEnding = [Text.Encoding]::ASCII.GetBytes("`n")
                break
            }
        }
        [byte[]]$appendBytes = New-ManagedByteArray -Parts @($canonicalLineBytes, $lineEnding)
        [byte[]]$nextBytes = New-ManagedByteArray -Parts @($Bytes, $appendBytes)
        return [pscustomobject]@{ Action = 'Append'; Reason = 'mapping_added'; Bytes = $nextBytes; OwnedLineCount = 0 }
    }

    # Cleanup changes only exact canonical lines.  A foreign legacy mapping is
    # left alone, because this helper did not create it and must not take it over.
    if ($ownedRecords.Count -eq 0) {
        if ($hasForeignTargetMapping) { $unchanged.Reason = 'foreign_mapping_untouched' }
        return $unchanged
    }

    $cursor = 0
    $parts = New-Object 'System.Collections.Generic.List[object]'
    foreach ($record in $ownedRecords) {
        if ($record.Start -gt $cursor) {
            $parts.Add((Get-ManagedByteSlice -Bytes $Bytes -Start $cursor -Length ($record.Start - $cursor))) | Out-Null
        }
        $cursor = $record.Start + $record.Length
    }
    if ($cursor -lt $Bytes.Length) {
        $parts.Add((Get-ManagedByteSlice -Bytes $Bytes -Start $cursor -Length ($Bytes.Length - $cursor))) | Out-Null
    }
    [byte[]]$cleanedBytes = New-ManagedByteArray -Parts $parts.ToArray()
    return [pscustomobject]@{ Action = 'Remove'; Reason = 'mapping_removed'; Bytes = $cleanedBytes; OwnedLineCount = $ownedRecords.Count }
}

function Read-ManagedHostsStreamBytes {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][IO.FileStream]$Stream)

    if ($Stream.Length -gt $script:ManagedHostsMaximumBytes) { throw 'hosts_too_large' }
    $length = [int]$Stream.Length
    $bytes = New-Object byte[] $length
    $offset = 0
    while ($offset -lt $length) {
        $count = $Stream.Read($bytes, $offset, $length - $offset)
        if ($count -le 0) { throw 'hosts_read_incomplete' }
        $offset += $count
    }
    return ,$bytes
}

function Test-ManagedByteArraysEqual {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Left,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Right
    )

    if ($Left.Length -ne $Right.Length) { return $false }
    for ($index = 0; $index -lt $Left.Length; $index++) {
        if ($Left[$index] -ne $Right[$index]) { return $false }
    }
    return $true
}

function New-ManagedHostsTempPath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$HostsPath)

    $directory = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($HostsPath))
    for ($attempt = 0; $attempt -lt 8; $attempt++) {
        $path = Join-Path $directory ('.codex-durable-relay-' + [Guid]::NewGuid().ToString('N') + '.tmp')
        if (-not (Test-Path -LiteralPath $path)) { return $path }
    }
    throw 'hosts_temp_name_unavailable'
}

function Write-ManagedHostsTempFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Bytes
    )

    $stream = $null
    try {
        $stream = New-Object IO.FileStream($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $stream.Write($Bytes, 0, $Bytes.Length)
        try { $stream.Flush($true) } catch { $stream.Flush() }
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Read-ManagedHostsPathBytes {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $stream = $null
    try {
        # This second open follows the current pathname, unlike the original
        # lock handle. It detects replacements that precede this read, but
        # cannot exclude another privileged replacement after the read.
        $stream = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        return Read-ManagedHostsStreamBytes -Stream $stream
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Invoke-ManagedHostsFilePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$HostsPath,
        [Parameter(Mandatory = $true)][string]$BackupPath,
        [ValidateSet('Reconcile', 'Cleanup')][string]$Mode = 'Reconcile'
    )

    $stream = $null
    $temporaryPath = $null
    try {
        # Keep the original open for reading while refusing writers.  Delete
        # sharing is intentional: ReplaceFile needs it to swap the name without
        # any destructive in-place truncate/write window.
        $share = [IO.FileShare]::Read -bor [IO.FileShare]::Delete
        $stream = New-Object IO.FileStream($HostsPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
        [byte[]]$before = Read-ManagedHostsStreamBytes -Stream $stream
        $plan = Get-ManagedHostsPlan -Bytes $before -Mode $Mode
        if ($plan.Action -eq 'Append' -or $plan.Action -eq 'Remove') {
            $temporaryPath = New-ManagedHostsTempPath -HostsPath $HostsPath
            [byte[]]$after = $plan.Bytes
            Write-ManagedHostsTempFile -Path $temporaryPath -Bytes $after

            # The original lock excludes writes.  Re-open the current pathname
            # immediately before ReplaceFile to narrow the race window. This
            # is not an atomic compare-and-swap with other hosts managers:
            # concurrent privileged pathname replacements are unsupported.
            $stream.Position = 0
            [byte[]]$verified = Read-ManagedHostsStreamBytes -Stream $stream
            [byte[]]$pathVerified = Read-ManagedHostsPathBytes -Path $HostsPath
            if (-not (Test-ManagedByteArraysEqual -Left $before -Right $verified) -or -not (Test-ManagedByteArraysEqual -Left $before -Right $pathVerified)) { throw 'hosts_changed_before_replace' }

            # Source and destination are on the hosts volume.  ReplaceFile is
            # atomic on NTFS and preserves the destination's ACL; BackupPath is
            # supplied only by the fixed privileged helper for recovery.
            # Metadata preservation is part of the safety contract.  Do not
            # accept a successful content swap that failed to retain the
            # destination metadata/ACL.
            [IO.File]::Replace($temporaryPath, $HostsPath, $BackupPath, $false)
            $temporaryPath = $null
        }
        return $plan
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
        if ($null -ne $temporaryPath -and (Test-Path -LiteralPath $temporaryPath)) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Test-ManagedRelayCommandLine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$CommandLine,
        [Parameter(Mandatory = $true)][string]$NodePath,
        [Parameter(Mandatory = $true)][string]$RelayScriptPath
    )

    # Win32_Process.CommandLine can omit the executable's outer quotes even
    # when ProcessStartInfo was given a path containing spaces.  The relay argv
    # itself remains strict: exactly the quoted installed script plus --run,
    # with no configuration flags or injected JavaScript arguments.
    $node = [Regex]::Escape($NodePath)
    $relay = [Regex]::Escape($RelayScriptPath)
    $pattern = '^\s*(?:"' + $node + '"|' + $node + ')\s+"' + $relay + '"\s+--run\s*$'
    return [Regex]::IsMatch($CommandLine, $pattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
}
