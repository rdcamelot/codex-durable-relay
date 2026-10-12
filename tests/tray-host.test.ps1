$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$temp = Join-Path $PSScriptRoot ('.tray-host-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
try {
    $resultPath = Join-Path $temp 'console-result.txt'
    $fixture = @'
Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class ConsoleProbe { [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow(); }'
[IO.File]::WriteAllText('__RESULT__', [ConsoleProbe]::GetConsoleWindow().ToInt64().ToString())
'@
    [IO.File]::WriteAllText((Join-Path $temp 'Launch-ManagedRelay.ps1'), $fixture.Replace('__RESULT__',$resultPath.Replace("'","''")))
    $harness = @'
using System;
using System.Drawing;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows.Forms;
internal static class Harness {
    [DllImport("user32.dll")] static extern IntPtr GetThreadDpiAwarenessContext();
    [DllImport("user32.dll")] static extern bool AreDpiAwarenessContextsEqual(IntPtr first, IntPtr second);
    [STAThread]
    static int Main(string[] args) {
        try { return Run(args); }
        catch (Exception error) {
            Console.Error.WriteLine(error.GetType().FullName);
            Console.Error.WriteLine(error.Message);
            return 1;
        }
    }
    static int Run(string[] args) {
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        using (var menu = new ContextMenuStrip()) {
            IntPtr window = menu.Handle;
            if (!AreDpiAwarenessContextsEqual(GetThreadDpiAwarenessContext(), new IntPtr(-4))) throw new Exception("Tray menu must use PerMonitorV2 when its window is created");
        }
        string iconPath = Path.Combine(args[0], "relay.ico");
        RelayTrayIcon.WriteIco(iconPath);
        byte[] iconBytes = File.ReadAllBytes(iconPath);
        if (iconBytes.Length < 70 || BitConverter.ToUInt16(iconBytes, 0) != 0 || BitConverter.ToUInt16(iconBytes, 2) != 1 || BitConverter.ToUInt16(iconBytes, 4) != 4) throw new Exception("B relay ICO header or frame count is invalid");
        using (Icon normal = RelayTrayIcon.CreateIcon(false, false))
        using (Icon dark = RelayTrayIcon.CreateIcon(false, true))
        using (Icon warning = RelayTrayIcon.CreateIcon(true, false)) {
            if (normal.Width <= 0 || dark.Width <= 0 || warning.Width <= 0) throw new Exception("B relay icon could not be loaded");
        }
        using (var child = TrayLauncher.Start(args[0])) {
            if (!child.WaitForExit(15000)) { child.Kill(); throw new Exception("Fixture launcher timed out"); }
            if (child.ExitCode != 0) throw new Exception("Fixture launcher failed");
            if (File.ReadAllText(Path.Combine(args[0], "console-result.txt")) != "0") throw new Exception("Hidden launcher still allocated a console");
        }
        bool cleaned = false, stopped = false;
        var exit = new TrayExitController(delegate(string trigger) { return cleaned; }, delegate { return stopped; });
        if (exit.TryExit("tray_exit")) throw new Exception("Unclean exit accepted");
        cleaned = true;
        if (exit.TryExit("tray_exit")) throw new Exception("Live child exit accepted");
        stopped = true;
        if (!exit.TryExit("tray_exit")) throw new Exception("Confirmed cleanup cannot exit");
        Console.WriteLine("8 tray-host cases passed, including PerMonitorV2, the B relay ICO, theme variants, a console-free PowerShell child, and exit gating.");
        return 0;
    }
}
'@
    [IO.File]::WriteAllText((Join-Path $temp 'harness.cs'), $harness)
    $exe = Join-Path $temp 'test.exe'
    Copy-Item -LiteralPath (Join-Path $root 'src\CodexRelayTrayHost.exe.config') -Destination ($exe + '.config')
    & (Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe') /nologo /target:exe /main:Harness /reference:System.Windows.Forms.dll /reference:System.Drawing.dll /reference:System.Web.Extensions.dll ('/win32manifest:'+(Join-Path $root 'src\CodexRelayTrayHost.manifest')) ('/out:'+$exe) (Join-Path $root 'src\CodexRelayTrayHost.cs') (Join-Path $root 'src\RelaySessionGuard.cs') (Join-Path $temp 'harness.cs')
    if ($LASTEXITCODE -ne 0) { throw 'Tray fixture compilation failed.' }
    & $exe $temp
    if ($LASTEXITCODE -ne 0) { throw 'Tray fixture failed.' }
} finally {
    $resolved = [IO.Path]::GetFullPath($temp)
    if ([IO.Path]::GetDirectoryName($resolved) -ne [IO.Path]::GetFullPath($PSScriptRoot) -or -not [IO.Path]::GetFileName($resolved).StartsWith('.tray-host-test-')) { throw 'Unexpected test cleanup path.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
