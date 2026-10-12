$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$temp = Join-Path $PSScriptRoot ('.session-guard-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
try {
    $harness = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Net;
using System.Runtime.InteropServices;
using System.Threading;
internal static class Harness {
    [DllImport("user32.dll", SetLastError=true)]
    static extern IntPtr SendMessageTimeout(IntPtr window, uint message, IntPtr w, IntPtr l, uint flags, uint timeout, out IntPtr result);
    static IntPtr Send(RelaySessionGuard guard, uint message, int value) {
        IntPtr result;
        if (SendMessageTimeout(guard.WindowHandle, message, new IntPtr(value), IntPtr.Zero, 2, 5000, out result) == IntPtr.Zero) throw new Exception("Window did not respond");
        return result;
    }
    static void Check(bool value, string message) { if (!value) throw new Exception(message); }
    static int Main() {
        int calls = 0, maintenance = 0;
        Check(!UserCleanupBackend.IsRelayEndpoint(new IPEndPoint(IPAddress.IPv6Any, 443)), "Unrelated IPv6 listener blocks hosts cleanup");
        Check(UserCleanupBackend.IsRelayEndpoint(new IPEndPoint(IPAddress.Parse("127.0.0.2"), 443)), "Fixed relay listener not detected");
        bool gone = false;
        Dictionary<string,object> last = null;
        var timer = new Stopwatch();
        var cleanup = new SessionCleanup(delegate { calls++; timer.Start(); }, delegate { maintenance++; gone = true; },
            delegate { return timer.ElapsedMilliseconds >= 120; }, delegate { return gone; },
            delegate(Dictionary<string,object> value) { last = new Dictionary<string,object>(value); }, 1500);
        using (var guard = new RelaySessionGuard(cleanup)) {
            Check(Send(guard, 0x11, 0) == new IntPtr(1), "Query vetoed shutdown");
            Check(calls == 0 && last == null, "Query performed cleanup before confirmation");
            Send(guard, 0x16, 0);
            Check(calls == 0, "Canceled shutdown stopped relay");
            Send(guard, 0x218, 4); // Power broadcast is not user-session end.
            Check(calls == 0, "Sleep stopped relay");
            Send(guard, 0x11, 0);
            Send(guard, 0x16, 1);
            Check(calls == 1 && maintenance == 1 && (bool)last["success"] && gone, "End returned before cleanup");
            Send(guard, 0x16, 1);
            Check(calls == 1, "Duplicate end repeated cleanup");
        }
        last = null;
        var failure = new SessionCleanup(delegate {}, delegate {}, delegate { return false; }, delegate { return false; },
            delegate(Dictionary<string,object> value) { last = new Dictionary<string,object>(value); }, 150);
        using (var guard = new RelaySessionGuard(failure)) {
            var elapsed = Stopwatch.StartNew();
            Send(guard, 0x16, 1);
            Check(!(bool)last["success"] && (string)last["reason"] == "cleanup_deadline_exceeded" && elapsed.ElapsedMilliseconds < 1500, "Timeout was hidden or unbounded");
        }
        last = null;
        new SessionCleanup(delegate { throw new Exception("private-data"); }, delegate {}, delegate { return false; }, delegate { return false; },
            delegate(Dictionary<string,object> value) { last = new Dictionary<string,object>(value); }, 100).Run();
        Check(!(bool)last["success"] && (string)last["reason"] == "cleanup_operation_failed", "Operation failure was not sanitized");
        new SessionCleanup(delegate {}, delegate {}, delegate { return true; }, delegate { return true; },
            delegate(Dictionary<string,object> value) { throw new Exception("disk unavailable"); }, 100).Run();
        Check((string)UserCleanupBackend.ClassifyPrevious(null, null)["health"] == "unknown", "First launch incorrectly failed");
        Check((string)UserCleanupBackend.ClassifyPrevious(new Dictionary<string,object>(), last)["health"] == "unverified", "Legacy receipt falsely verified");
        var old = new Dictionary<string,object> {{"instanceId", "old-run"}};
        var stale = new Dictionary<string,object> {{"instanceId", "test-run"}, {"success", true}, {"completedAtUtc", "2026-01-01T00:00:00Z"}};
        Check((string)UserCleanupBackend.ClassifyPrevious(old, stale)["health"] == "unverified", "Unrelated test receipt verified another run");
        stale["instanceId"] = "old-run";
        Check((string)UserCleanupBackend.ClassifyPrevious(old, stale)["health"] == "verified", "Matching successful exit lost");
        last = null;
        bool childGone = false;
        var waitChild = new SessionCleanup(delegate {}, delegate {}, delegate { return true; }, delegate { return true; },
            delegate(Dictionary<string,object> value) { last = new Dictionary<string,object>(value); }, 100, delegate { return childGone; });
        using (var guard = new RelaySessionGuard(waitChild)) {
            Check(!guard.StopAndVerify("tray_exit"), "Tray exited with child still alive");
            childGone = true;
            Check(guard.StopAndVerify("tray_exit"), "Manual cleanup could not retry after failure");
        }
        Console.WriteLine("16 session-guard cases passed, including run identity, retry, child lifetime and targeted window messages; no system shutdown, tasks or hosts touched.");
        return 0;
    }
}
'@
    $harnessPath = Join-Path $temp 'harness.cs'
    [IO.File]::WriteAllText($harnessPath, $harness)
    $exe = Join-Path $temp 'test.exe'
    & (Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe') /nologo /target:exe /reference:System.Windows.Forms.dll /reference:System.Web.Extensions.dll ('/out:'+$exe) (Join-Path $root 'src\RelaySessionGuard.cs') $harnessPath
    if ($LASTEXITCODE -ne 0) { throw 'Guard fixture compilation failed.' }
    & $exe
    if ($LASTEXITCODE -ne 0) { throw 'Guard fixture failed.' }
} finally {
    $resolved = [IO.Path]::GetFullPath($temp)
    if ([IO.Path]::GetDirectoryName($resolved) -ne [IO.Path]::GetFullPath($PSScriptRoot) -or -not [IO.Path]::GetFileName($resolved).StartsWith('.session-guard-test-')) { throw 'Unexpected test cleanup path.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
