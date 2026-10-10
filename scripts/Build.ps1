[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
if (-not [Environment]::Is64BitProcess) { throw 'Use 64-bit Windows PowerShell 5.1.' }
$root = Split-Path $PSScriptRoot -Parent
$source = Join-Path $root 'src'
$destination = Join-Path $root 'dist'
if ((Test-Path -LiteralPath $destination) -and ((Get-Item -LiteralPath $destination).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Build directory must not be redirected.' }
New-Item -ItemType Directory -Path $destination -Force | Out-Null
$files = @('codex-durable-relay.cjs','relay-log.cjs','managed-relay.cjs','managed-relay-hosts.ps1','managed-hosts-lib.ps1','Launch-ManagedRelay.ps1','Manage-CodexRelay.ps1','Shutdown-CodexRelay.ps1','CodexRelayLifecycle.cs')
foreach ($name in ($files + @('Install-CodexRelay.ps1'))) {
    $inputPath = Join-Path $source $name
    if ($name.EndsWith('.ps1')) {
        $tokens = $null; $errors = $null
        [void][Management.Automation.Language.Parser]::ParseFile($inputPath,[ref]$tokens,[ref]$errors)
        if ($errors.Count) { throw ('PowerShell syntax error: ' + $name) }
        [IO.File]::WriteAllText((Join-Path $destination $name),[IO.File]::ReadAllText($inputPath),(New-Object Text.UTF8Encoding($true)))
    } else { Copy-Item -LiteralPath $inputPath -Destination (Join-Path $destination $name) -Force }
}
$compiler = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler)) { throw 'The .NET Framework 4 C# compiler is required.' }
& $compiler /nologo /target:winexe /platform:anycpu /optimize+ ('/out:' + (Join-Path $destination 'CodexRelayLifecycle.exe')) (Join-Path $destination 'CodexRelayLifecycle.cs')
if ($LASTEXITCODE -ne 0) { throw 'Lifecycle service compilation failed.' }
$manifestFiles = foreach ($name in ($files + @('CodexRelayLifecycle.exe'))) {
    [ordered]@{name=$name;sha256=(Get-FileHash -LiteralPath (Join-Path $destination $name) -Algorithm SHA256).Hash}
}
[ordered]@{version=2;files=@($manifestFiles)} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $destination 'managed-manifest.json') -Encoding UTF8
Write-Output 'Built dist. No service, task, network setting, or hosts entry was changed.'
