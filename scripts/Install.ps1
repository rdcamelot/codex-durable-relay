[CmdletBinding()]
param(
    [string]$NodePath = '',
    [ValidateRange(1,65535)][int]$ProxyPort = 7890,
    [switch]$ReviewOnly
)
$ErrorActionPreference = 'Stop'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run this entrypoint from an ordinary PowerShell session; it requests UAC after inspection.' }
if (-not [Environment]::Is64BitProcess -or $env:ProgramFiles -ne 'C:\Program Files' -or $env:SystemRoot -ne 'C:\Windows') { throw 'This experimental version requires 64-bit Windows with standard C:\Windows and C:\Program Files paths.' }
$root = Split-Path $PSScriptRoot -Parent
$dist = Join-Path $root 'dist'
if (-not $NodePath) { $NodePath = (Get-Command node.exe -ErrorAction Stop).Source }
$NodePath = (Resolve-Path -LiteralPath $NodePath).Path
if ((Get-Item -LiteralPath $NodePath).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Use an actual signed Node executable, not a link.' }
$signature = Get-AuthenticodeSignature -LiteralPath $NodePath
if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=OpenJS Foundation') { throw 'Install the signed official Node.js runtime first.' }
$nodeHash = (Get-FileHash -LiteralPath $NodePath).Hash
$installerPath = Join-Path $dist 'Install-CodexRelay.ps1'
$installerHash = (Get-FileHash -LiteralPath $installerPath).Hash
$manifestHash = (Get-FileHash -LiteralPath (Join-Path $dist 'managed-manifest.json')).Hash
$settings = [ordered]@{OwnerSid=$identity.User.Value;OwnerName=$identity.Name;StateDirectory=(Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CodexDurableRelay');NodeSource=$NodePath;NodeHash=$nodeHash;ManifestHash=$manifestHash;ProxyPort=$ProxyPort;PayloadDirectory=$dist}
Write-Output ('Install: C:\Program Files\CodexDurableRelay; proxy: 127.0.0.1:' + $ProxyPort)
Write-Output 'Changes: one fixed hosts mapping when ready; one ordinary-user login task; one SYSTEM hosts task; one SYSTEM lifecycle service.'
Write-Output 'No TLS decryption, driver, automatic message replay, or change to the Codex application.'
Write-Output ('Reviewed installer SHA256: ' + $installerHash)
Write-Output ('Reviewed payload manifest SHA256: ' + $manifestHash)
if ($ReviewOnly) { return }
# Encode structured arguments, not shell fragments. The elevated process checks
# and executes the same bytes, then the installer verifies protected copies.
$encodedSettings = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($settings | ConvertTo-Json -Compress)))
$pathLiteral = $installerPath.Replace("'","''")
$script = @'
$ErrorActionPreference='Stop'
$bytes=[IO.File]::ReadAllBytes('__INSTALLER__')
$sha=[Security.Cryptography.SHA256]::Create()
try{$hash=[BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','')}finally{$sha.Dispose()}
if($hash -ne '__HASH__'){throw 'Installer changed after review.'}
$data=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__SETTINGS__'))|ConvertFrom-Json
$parameters=@{};foreach($p in $data.PSObject.Properties){$parameters[$p.Name]=$p.Value}
& ([scriptblock]::Create([Text.Encoding]::UTF8.GetString($bytes).TrimStart([char]0xFEFF))) @parameters
'@
$script = $script.Replace('__INSTALLER__',$pathLiteral).Replace('__HASH__',$installerHash).Replace('__SETTINGS__',$encodedSettings)
$encodedScript = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
$child = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -Verb RunAs -WindowStyle Hidden -ArgumentList ('-NoProfile -NonInteractive -EncodedCommand ' + $encodedScript) -Wait -PassThru
if ($child.ExitCode -ne 0) { throw 'Installation did not complete. Inspect the protected installation result; do not repeatedly retry over a partial installation.' }
Write-Output 'Installed. Use scripts\Control.ps1 -Action Status to check proxy readiness.'
