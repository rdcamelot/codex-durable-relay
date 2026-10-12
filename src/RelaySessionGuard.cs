using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Net;
using System.Net.NetworkInformation;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;

// Runs inside the limited-user launcher, never inside the SYSTEM service.
// Windows waits for WM_ENDSESSION to return before ending this user session.
public sealed class RelaySessionGuard : IDisposable {
    private const int QueryEndSession = 0x11, EndSession = 0x16, Close = 0x10;
    private readonly SessionCleanup cleanup;
    private readonly ManualResetEvent ready = new ManualResetEvent(false);
    private readonly ManualResetEvent completed = new ManualResetEvent(true);
    private readonly object endGate = new object();
    private readonly Thread thread;
    private GuardWindow window;
    private Exception startupError;
    private int ending;
    private readonly object cleanupGate = new object();
    private Action<string> observe = delegate {};
    private Action<string> setTrigger = delegate {};
    private bool clean;
    public bool IsEnding { get { return Interlocked.CompareExchange(ref ending, 0, 0) != 0; } }
    public IntPtr WindowHandle { get { return window == null ? IntPtr.Zero : window.Handle; } }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern bool ShutdownBlockReasonCreate(IntPtr hwnd, string reason);
    [DllImport("user32.dll")]
    private static extern bool ShutdownBlockReasonDestroy(IntPtr hwnd);
    [DllImport("user32.dll")]
    private static extern bool PostMessage(IntPtr hwnd, int message, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);
    [DllImport("kernel32.dll")]
    private static extern bool SetProcessShutdownParameters(uint level, uint flags);

    public static bool IsWindowForProcess(long handle, int processId) {
        uint owner;
        return GetWindowThreadProcessId(new IntPtr(handle), out owner) != 0 && owner == (uint)processId;
    }

    public static RelaySessionGuard Start(string stateDirectory, Func<bool> launcherStopped) {
        string expected = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CodexDurableRelay");
        if (!String.Equals(Path.GetFullPath(stateDirectory), expected, StringComparison.OrdinalIgnoreCase) ||
            (File.GetAttributes(expected) & FileAttributes.ReparsePoint) != 0 ||
            new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator)) {
            throw new InvalidOperationException("Session cleanup must run in the configured limited-user directory.");
        }
        if (!String.Equals(Path.GetFullPath(Assembly.GetExecutingAssembly().Location),
            @"C:\Program Files\CodexDurableRelay\RelaySessionGuard.dll", StringComparison.OrdinalIgnoreCase)) {
            throw new InvalidOperationException("Session cleanup must use the protected installation.");
        }
        var backend = new UserCleanupBackend(expected);
        var guard = new RelaySessionGuard(new SessionCleanup(backend.RequestStop, backend.RequestMaintenance,
            backend.ListenerAbsent, backend.MappingAbsent, backend.WriteResult, 12000, launcherStopped));
        guard.observe = backend.Observe;
        guard.setTrigger = backend.SetTrigger;
        // Run before ordinary applications/console children at the default 0x280.
        bool prioritySet = SetProcessShutdownParameters(0x3A0, 0);
        backend.WriteGuardStatus(guard.WindowHandle, prioritySet);
        return guard;
    }

    public bool StopAndVerify(string trigger) {
        if (trigger != "tray_exit" && trigger != "launcher_exit" && trigger != "session_end") throw new ArgumentException("Unsupported cleanup trigger.");
        lock (cleanupGate) {
            if (clean) return true;
            setTrigger(trigger);
            clean = cleanup.Run();
            return clean;
        }
    }

    internal RelaySessionGuard(SessionCleanup cleanup) {
        this.cleanup = cleanup;
        thread = new Thread(RunWindow);
        thread.IsBackground = true;
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        if (!ready.WaitOne(5000) || startupError != null) {
            if (WindowHandle != IntPtr.Zero) PostMessage(WindowHandle, Close, IntPtr.Zero, IntPtr.Zero);
            throw new InvalidOperationException("Session cleanup window did not initialize.");
        }
    }
    private void RunWindow() {
        try {
            window = new GuardWindow(this);
            ready.Set();
            Application.Run();
        } catch (Exception error) { startupError = error; ready.Set(); }
        finally { if (window != null) window.DestroyHandle(); }
    }
    private sealed class GuardWindow : NativeWindow {
        private readonly RelaySessionGuard owner;
        internal GuardWindow(RelaySessionGuard owner) {
            this.owner = owner;
            // A hidden top-level window: message-only windows miss broadcasts.
            CreateHandle(new CreateParams { Caption = "Codex Relay Cleanup", Parent = IntPtr.Zero, Style = 0 });
        }
        protected override void WndProc(ref Message message) {
            if (message.Msg == QueryEndSession) {
                owner.observe("query_end_session");
                ShutdownBlockReasonCreate(Handle, "Cleaning up the Codex relay connection.");
                message.Result = new IntPtr(1); // Never veto the user's shutdown.
                return;
            }
            if (message.Msg == EndSession) {
                owner.observe(message.WParam == IntPtr.Zero ? "session_end_canceled" : "session_end_confirmed");
                bool run = false;
                lock (owner.endGate) {
                    if (message.WParam != IntPtr.Zero && owner.ending == 0) {
                        owner.ending = 1;
                        owner.completed.Reset();
                        run = true;
                    }
                }
                if (run) {
                    try { owner.StopAndVerify("session_end"); }
                    finally { owner.completed.Set(); }
                }
                ShutdownBlockReasonDestroy(Handle);
                message.Result = IntPtr.Zero;
                return;
            }
            if (message.Msg == Close) { Application.ExitThread(); message.Result = IntPtr.Zero; return; }
            base.WndProc(ref message);
        }
    }
    public void Dispose() {
        // The Node process may exit while the window is still verifying hosts.
        // Do not let the launcher's main thread tear down that message handler.
        bool wait;
        lock (endGate) { wait = ending != 0; }
        if (wait) completed.WaitOne(15000);
        if (WindowHandle != IntPtr.Zero) PostMessage(WindowHandle, Close, IntPtr.Zero, IntPtr.Zero);
        thread.Join(2000);
    }
}

internal sealed class SessionCleanup {
    private readonly Action requestStop, requestMaintenance;
    private readonly Func<bool> listenerAbsent, mappingAbsent;
    private readonly Action<Dictionary<string, object>> writeResult;
    private readonly int timeoutMs;
    private readonly Func<bool> launcherStopped;
    internal SessionCleanup(Action stop, Action maintain, Func<bool> listener, Func<bool> mapping,
        Action<Dictionary<string, object>> write, int timeout, Func<bool> launcherAbsent = null) {
        requestStop = stop; requestMaintenance = maintain; listenerAbsent = listener;
        mappingAbsent = mapping; writeResult = write; timeoutMs = timeout;
        launcherStopped = launcherAbsent ?? delegate { return true; };
    }
    internal bool Run() {
        var timer = Stopwatch.StartNew();
        var result = new Dictionary<string, object> {
            {"version", 1}, {"startedAtUtc", DateTime.UtcNow.ToString("o")},
            {"success", false}, {"phase", "request_stop"}, {"reason", "in_progress"}
        };
        try {
            writeResult(result);
            requestStop();
            result["phase"] = "wait_for_listener_and_mapping";
            writeResult(result);
            long nextMaintenance = 0;
            long nextStop = 500;
            while (timer.ElapsedMilliseconds < timeoutMs) {
                // Cover a Node start racing the initial request, without allowing launcher retries.
                if (timer.ElapsedMilliseconds >= nextStop) { requestStop(); nextStop = timer.ElapsedMilliseconds + 500; }
                bool stopped = listenerAbsent();
                bool unmapped = mappingAbsent();
                bool launcherGone = launcherStopped();
                result["listenerAbsent"] = stopped;
                result["mappingRemoved"] = unmapped;
                result["launcherStopped"] = launcherGone;
                if (stopped && unmapped && launcherGone) { result["success"] = true; result["reason"] = "clean_session_end"; break; }
                if (stopped && timer.ElapsedMilliseconds >= nextMaintenance) {
                    requestMaintenance();
                    nextMaintenance = timer.ElapsedMilliseconds + 1500;
                }
                Thread.Sleep(100);
            }
            if (!(bool)result["success"]) result["reason"] = "cleanup_deadline_exceeded";
        } catch { result["reason"] = "cleanup_operation_failed"; }
        finally {
            result["completedAtUtc"] = DateTime.UtcNow.ToString("o");
            result["durationMs"] = timer.ElapsedMilliseconds;
            try { writeResult(result); } catch { result["success"] = false; }
        }
        return (bool)result["success"];
    }
}

internal sealed class UserCleanupBackend {
    private const string Marker = "CODEX-DURABLE-RELAY-V2";
    private readonly string directory;
    private readonly JavaScriptSerializer json = new JavaScriptSerializer();
    private readonly object fileGate = new object();
    private readonly string instanceId = Guid.NewGuid().ToString("N");
    private readonly int sessionId = Process.GetCurrentProcess().SessionId;
    private string trigger = "session_end";
    private readonly Dictionary<string, object> previousExit;
    internal UserCleanupBackend(string directory) {
        this.directory = directory;
        previousExit = ClassifyPrevious(Read("session-guard-status.json"), Read("session-end-result.json"));
    }
    private Dictionary<string, object> Read(string name) {
        try { return json.Deserialize<Dictionary<string, object>>(File.ReadAllText(Path.Combine(directory, name))); } catch { return null; }
    }
    internal static Dictionary<string, object> ClassifyPrevious(Dictionary<string, object> guard, Dictionary<string, object> receipt) {
        var result = new Dictionary<string, object> { {"health", "unknown"}, {"reason", "no_previous_run"}, {"observedAtUtc", DateTime.UtcNow.ToString("o")} };
        if (guard == null) return result;
        object id;
        if (!guard.TryGetValue("instanceId", out id) || String.IsNullOrEmpty(Convert.ToString(id))) {
            result["health"] = "unverified"; result["reason"] = "legacy_receipt_not_bound_to_run"; return result;
        }
        result["instanceId"] = id;
        object receiptId;
        if (receipt == null || !receipt.TryGetValue("instanceId", out receiptId) || !String.Equals(Convert.ToString(id), Convert.ToString(receiptId), StringComparison.Ordinal)) {
            result["health"] = "unverified"; result["reason"] = "previous_run_has_no_matching_receipt"; return result;
        }
        object complete, success;
        if (!receipt.TryGetValue("completedAtUtc", out complete) || String.IsNullOrEmpty(Convert.ToString(complete))) {
            result["health"] = "incomplete"; result["reason"] = "previous_cleanup_incomplete"; return result;
        }
        result["completedAtUtc"] = complete;
        result["health"] = receipt.TryGetValue("success", out success) && success is bool && (bool)success ? "verified" : "failed";
        result["reason"] = (string)result["health"] == "verified" ? "previous_run_cleaned" : "previous_cleanup_failed";
        return result;
    }
    private void Write(string name, object value) {
        lock (fileGate) {
        string destination = Path.Combine(directory, name);
        string temporary = destination + "." + Process.GetCurrentProcess().Id.ToString(CultureInfo.InvariantCulture) + ".tmp";
        File.WriteAllText(temporary, json.Serialize(value), new UTF8Encoding(false));
        if (File.Exists(destination)) File.Replace(temporary, destination, null);
        else File.Move(temporary, destination);
        }
    }
    internal void RequestStop() {
        int pid = 0;
        try {
            var state = json.Deserialize<Dictionary<string, object>>(File.ReadAllText(Path.Combine(directory, "status.json")));
            pid = Convert.ToInt32(state["pid"], CultureInfo.InvariantCulture);
        } catch { }
        Write("stop.json", new { pid = pid, requestedAt = DateTime.UtcNow.ToString("o") });
    }
    internal void RequestMaintenance() {
        using (var child = Process.Start(new ProcessStartInfo {
            FileName = @"C:\Windows\System32\schtasks.exe",
            Arguments = "/Run /TN \"Codex Durable Relay - Hosts\"",
            UseShellExecute = false, CreateNoWindow = true, WindowStyle = ProcessWindowStyle.Hidden
        })) {
            if (child != null && !child.WaitForExit(750)) { try { child.Kill(); } catch { } }
        }
    }
    internal bool ListenerAbsent() {
        foreach (var endpoint in IPGlobalProperties.GetIPGlobalProperties().GetActiveTcpListeners()) {
            if (IsRelayEndpoint(endpoint)) return false;
        }
        return true;
    }
    internal static bool IsRelayEndpoint(IPEndPoint endpoint) {
        return endpoint.Port == 443 && endpoint.Address.Equals(IPAddress.Parse("127.0.0.2"));
    }
    internal bool MappingAbsent() {
        return !File.ReadAllText(@"C:\Windows\System32\drivers\etc\hosts").Contains(Marker);
    }
    internal void SetTrigger(string value) { trigger = value; }
    internal void Observe(string value) {
        try { Write("session-notification.json", new { instanceId = instanceId, sessionId = sessionId, notification = value, atUtc = DateTime.UtcNow.ToString("o") }); } catch { }
    }
    internal void WriteResult(Dictionary<string, object> result) {
        result["version"] = 2; result["instanceId"] = instanceId; result["sessionId"] = sessionId; result["trigger"] = trigger;
        Write("session-end-result.json", result);
    }
    internal void WriteGuardStatus(IntPtr handle, bool prioritySet) {
        using (var process = Process.GetCurrentProcess()) {
            Write("session-guard-status.json", new { version = 2, instanceId = instanceId, sessionId = sessionId, previousExit = previousExit, pid = process.Id,
                processStartedAtUtc = process.StartTime.ToUniversalTime().ToString("o"),
                windowHandle = handle.ToInt64(), prioritySet = prioritySet, startedAtUtc = DateTime.UtcNow.ToString("o") });
        }
    }
}
