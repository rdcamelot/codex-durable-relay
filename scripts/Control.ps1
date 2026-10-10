[CmdletBinding()]
param(
    [ValidateSet('Start','Stop','Status','EnableAutostart','DisableAutostart','Uninstall')][string]$Action='Status',
    [switch]$AsJson
)
$ErrorActionPreference='Stop'
$entry='C:\Program Files\CodexDurableRelay\Manage-CodexRelay.ps1'
if (-not (Test-Path -LiteralPath $entry -PathType Leaf)) { throw 'No protected installation found.' }
& $entry -Action $Action -AsJson:$AsJson
