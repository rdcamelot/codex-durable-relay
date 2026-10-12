[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
if (-not [Environment]::Is64BitProcess) { throw 'Use 64-bit Windows PowerShell 5.1.' }
$root = Split-Path $PSScriptRoot -Parent
$source = Join-Path $root 'src'
$destination = Join-Path $root 'dist'
if ((Test-Path -LiteralPath $destination) -and ((Get-Item -LiteralPath $destination).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Build directory must not be redirected.' }
New-Item -ItemType Directory -Path $destination -Force | Out-Null
$files = @('codex-durable-relay.cjs','relay-log.cjs','managed-relay.cjs','managed-relay-hosts.ps1','managed-hosts-lib.ps1','Launch-ManagedRelay.ps1','Manage-CodexRelay.ps1','Shutdown-CodexRelay.ps1','CodexRelayLifecycle.cs','RelaySessionGuard.cs','CodexRelayTrayHost.cs','CodexRelayTrayHost.exe.config')
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
& $compiler /nologo /target:library /platform:anycpu /optimize+ /reference:System.Windows.Forms.dll /reference:System.Web.Extensions.dll ('/out:' + (Join-Path $destination 'RelaySessionGuard.dll')) (Join-Path $destination 'RelaySessionGuard.cs')
if ($LASTEXITCODE -ne 0) { throw 'Session guard compilation failed.' }
$iconTemp = Join-Path ([IO.Path]::GetTempPath()) ('CodexRelayIcon-' + [Guid]::NewGuid().ToString('N'))
$iconPath = Join-Path $destination 'CodexRelayTrayHost.ico'
try {
    New-Item -ItemType Directory -Path $iconTemp -Force | Out-Null
    $iconHarnessPath = Join-Path $iconTemp 'IconExportHarness.cs'
    $iconHarness = @'
using System;
internal static class IconExportHarness {
    private static int Main(string[] args) {
        if (args.Length != 1) return 2;
        RelayTrayIcon.WriteIco(args[0]);
        return 0;
    }
}
'@
    [IO.File]::WriteAllText($iconHarnessPath, $iconHarness, (New-Object Text.UTF8Encoding($false)))
    $iconExe = Join-Path $iconTemp 'IconExportHarness.exe'
    & $compiler /nologo /target:exe /main:IconExportHarness /platform:anycpu /optimize+ /reference:System.Windows.Forms.dll /reference:System.Drawing.dll /reference:System.Web.Extensions.dll ('/reference:' + (Join-Path $destination 'RelaySessionGuard.dll')) ('/out:' + $iconExe) (Join-Path $destination 'CodexRelayTrayHost.cs') $iconHarnessPath
    if ($LASTEXITCODE -ne 0) { throw 'Tray icon export compilation failed.' }
    & $iconExe $iconPath
    if ($LASTEXITCODE -ne 0) { throw 'Tray icon export failed.' }
    & $compiler /nologo /target:winexe /platform:anycpu /optimize+ /reference:System.Windows.Forms.dll /reference:System.Drawing.dll /reference:System.Web.Extensions.dll ('/reference:' + (Join-Path $destination 'RelaySessionGuard.dll')) ('/win32manifest:' + (Join-Path $source 'CodexRelayTrayHost.manifest')) ('/win32icon:' + $iconPath) ('/out:' + (Join-Path $destination 'CodexRelayTrayHost.exe')) (Join-Path $destination 'CodexRelayTrayHost.cs')
    if ($LASTEXITCODE -ne 0) { throw 'Tray host compilation failed.' }
} finally {
    if (Test-Path -LiteralPath $iconPath) { Remove-Item -LiteralPath $iconPath -Force }
    if (Test-Path -LiteralPath $iconTemp) {
        $tempResolved = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $iconTemp).Path).TrimEnd('\')
        $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
        $tempLeaf = [IO.Path]::GetFileName($tempResolved)
        $tempItem = Get-Item -LiteralPath $tempResolved -Force
        if ([IO.Path]::GetDirectoryName($tempResolved).TrimEnd('\') -ine $tempRoot -or -not $tempLeaf.StartsWith('CodexRelayIcon-', [StringComparison]::OrdinalIgnoreCase) -or (($tempItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
            throw 'Refusing to recursively remove an unexpected icon build directory.'
        }
        Remove-Item -LiteralPath $tempResolved -Recurse -Force
    }
}
& $compiler /nologo /target:winexe /platform:anycpu /optimize+ ('/out:' + (Join-Path $destination 'CodexRelayLifecycle.exe')) (Join-Path $destination 'CodexRelayLifecycle.cs')
if ($LASTEXITCODE -ne 0) { throw 'Lifecycle service compilation failed.' }
$manifestFiles = foreach ($name in ($files + @('RelaySessionGuard.dll','CodexRelayTrayHost.exe','CodexRelayLifecycle.exe'))) {
    [ordered]@{name=$name;sha256=(Get-FileHash -LiteralPath (Join-Path $destination $name) -Algorithm SHA256).Hash}
}
[ordered]@{version=2;files=@($manifestFiles)} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $destination 'managed-manifest.json') -Encoding UTF8
Write-Output 'Built dist. No service, task, network setting, or hosts entry was changed.'
