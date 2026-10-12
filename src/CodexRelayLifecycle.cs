using System;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
using System.Threading;
// Narrow fixed-script lifecycle service; no traffic, user-state, or content handling.
internal static class CodexRelayLifecycle {
    private const string ServiceName = "CodexDurableRelayLifecycle";
    private const string InstallDirectory = @"C:\Program Files\CodexDurableRelay";
    private const string ExpectedAssemblyPath = InstallDirectory + @"\CodexRelayLifecycle.exe";
    private const string ScriptPath = InstallDirectory + @"\Shutdown-CodexRelay.ps1";
    private const string PowerShellPath = @"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe";
    private const string StatusPath = InstallDirectory + @"\lifecycle-service-status.json";
    private const string StatusTempPath = InstallDirectory + @"\lifecycle-service-status.tmp";
    private const string SystemSid = "S-1-5-18";
    private const int ChildTimeoutMilliseconds = 20000;
    private const int ScriptGateWaitMilliseconds = 21000;
    private const int StopWaitHintMilliseconds = 45000;
    private const uint SERVICE_START_PENDING = 2, SERVICE_STOP_PENDING = 3, SERVICE_RUNNING = 4, SERVICE_STOPPED = 1;
    private const uint SERVICE_WIN32_OWN_PROCESS = 0x00000010;
    private const uint SERVICE_ACCEPT_STOP = 0x00000001, SERVICE_ACCEPT_SHUTDOWN = 0x00000004, SERVICE_ACCEPT_PRESHUTDOWN = 0x00000100;
    private const uint SERVICE_CONTROL_STOP = 1, SERVICE_CONTROL_SHUTDOWN = 5, SERVICE_CONTROL_PRESHUTDOWN = 15;
    private const uint ERROR_SERVICE_SPECIFIC_ERROR = 1066;
    private enum ScriptMode { Initialize, Stop }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct SERVICE_TABLE_ENTRY {
        [MarshalAs(UnmanagedType.LPWStr)] public string lpServiceName; public ServiceMainDelegate lpServiceProc;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct SERVICE_STATUS {
        public uint dwServiceType, dwCurrentState, dwControlsAccepted, dwWin32ExitCode;
        public uint dwServiceSpecificExitCode, dwCheckPoint, dwWaitHint;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct SERVICE_PRESHUTDOWN_INFO {
        public uint dwPreshutdownTimeout;
    }
    private delegate void ServiceMainDelegate(uint argc, IntPtr argv);
    private delegate uint HandlerExDelegate(uint control, uint eventType, IntPtr eventData, IntPtr context);
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool StartServiceCtrlDispatcher([In] SERVICE_TABLE_ENTRY[] serviceStartTable);
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern IntPtr RegisterServiceCtrlHandlerEx(string serviceName, HandlerExDelegate callback, IntPtr context);
    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetServiceStatus(IntPtr statusHandle, ref SERVICE_STATUS serviceStatus);
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern IntPtr OpenSCManager(string machineName, string databaseName, uint desiredAccess);
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern IntPtr OpenService(IntPtr manager, string serviceName, uint desiredAccess);
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ChangeServiceConfig2(IntPtr service, uint infoLevel, ref SERVICE_PRESHUTDOWN_INFO info);
    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseServiceHandle(IntPtr handle);
    private static readonly object StateGate = new object();
    private static readonly object StatusGate = new object();
    private static readonly SemaphoreSlim ScriptGate = new SemaphoreSlim(1, 1);
    private static readonly ManualResetEvent Stopped = new ManualResetEvent(false);
    private static ServiceMainDelegate serviceMainRoot;
    private static HandlerExDelegate controlHandlerRoot;
    private static IntPtr serviceStatusHandle;
    private static uint checkpoint;
    private static bool stopRequested;
    public static void Main() {
        serviceMainRoot = ServiceMain;
        SERVICE_TABLE_ENTRY[] table = new SERVICE_TABLE_ENTRY[] {
            new SERVICE_TABLE_ENTRY { lpServiceName = ServiceName, lpServiceProc = serviceMainRoot },
            new SERVICE_TABLE_ENTRY { lpServiceName = null, lpServiceProc = null }
        };
        StartServiceCtrlDispatcher(table);
    }
    private static void ServiceMain(uint argc, IntPtr argv) {
        controlHandlerRoot = ServiceControlHandler;
        serviceStatusHandle = RegisterServiceCtrlHandlerEx(ServiceName, controlHandlerRoot, IntPtr.Zero);
        if (serviceStatusHandle == IntPtr.Zero) {
            return;
        }
        if (!IsExpectedSystemService()) {
            WriteStatus(0, "rejected", -1, 0);
            ReportServiceStatus(SERVICE_STOPPED, 5, 0, 0);
            return;
        }
        WriteStatus(0, "initializing", -1, 0);
        if (!ReportServiceStatus(SERVICE_START_PENDING, 0, 0, ChildTimeoutMilliseconds + 5000)) {
            WriteStatus(0, "status_update_failed", -1, 0);
            return;
        }
        // Configure our own fixed preshutdown budget with the Windows API;
        // sc.exe does not expose this setting on every Windows installation.
        if (!ConfigurePreshutdownBudget()) {
            WriteStatus(0, "preshutdown_config_failed", -1, 0);
            ReportServiceStatus(SERVICE_STOPPED, ERROR_SERVICE_SPECIFIC_ERROR, 1, 0);
            return;
        }
        int initializeExit = RunFixedScript(ScriptMode.Initialize, 0, delegate { ReportServiceStatus(SERVICE_START_PENDING, 0, 0, ChildTimeoutMilliseconds + 5000); });
        bool canRun;
        lock (StateGate) { canRun = !stopRequested && initializeExit == 0; }
        if (canRun) {
            WriteStatus(0, "running", initializeExit, 0);
            if (!ReportServiceStatus(SERVICE_RUNNING, 0, 0, 0)) {
                WriteStatus(0, "status_update_failed", -1, 0);
                RequestStop(SERVICE_CONTROL_STOP);
            }
        }
        if (initializeExit != 0) {
            WriteStatus(0, "initialize_failed", initializeExit, 0);
            bool stopping;
            lock (StateGate) { stopping = stopRequested; }
            if (!stopping) {
                ReportServiceStatus(SERVICE_STOPPED, ERROR_SERVICE_SPECIFIC_ERROR, ToServiceExitCode(initializeExit), 0);
                return;
            }
        }
        Stopped.WaitOne();
    }
    private static uint ServiceControlHandler(uint control, uint eventType, IntPtr eventData, IntPtr context) {
        if (control == SERVICE_CONTROL_STOP || control == SERVICE_CONTROL_SHUTDOWN || control == SERVICE_CONTROL_PRESHUTDOWN) {
            RequestStop(control);
            return 0;
        }
        return 0;
    }
    private static void RequestStop(uint eventCode) {
        bool startWorker = false;
        lock (StateGate) {
            if (!stopRequested) {
                stopRequested = true;
                startWorker = true;
            }
        }
        if (startWorker) {
            Thread worker = new Thread(new ThreadStart(delegate { StopWorker(eventCode); }));
            worker.IsBackground = true;
            worker.Start();
        }
    }
    private static void StopWorker(uint eventCode) {
        int exitCode = -1;
        try {
            ReportServiceStatus(SERVICE_STOP_PENDING, 0, 0, StopWaitHintMilliseconds);
            WriteStatus((int)eventCode, "stop_requested", -1, 0);
            WriteStatus((int)eventCode, "stopping", -1, 0);
            exitCode = RunFixedScript(ScriptMode.Stop, 0, delegate { ReportServiceStatus(SERVICE_STOP_PENDING, 0, 0, StopWaitHintMilliseconds); });
        }
        catch { }
        finally {
            WriteStatus((int)eventCode, "stopped", exitCode, 0);
            ReportServiceStatus(SERVICE_STOPPED, exitCode == 0 ? 0 : ERROR_SERVICE_SPECIFIC_ERROR, ToServiceExitCode(exitCode), 0);
            Stopped.Set();
        }
    }
    private static int RunFixedScript(ScriptMode mode, uint sessionId, Action progress) {
        Stopwatch acquireTimer = Stopwatch.StartNew();
        while (!ScriptGate.Wait(250)) {
            if (progress != null) { progress(); }
            if (acquireTimer.ElapsedMilliseconds >= ScriptGateWaitMilliseconds) {
                return -3;
            }
        }
        Process child = null;
        try {
            ProcessStartInfo startInfo = new ProcessStartInfo();
            startInfo.FileName = PowerShellPath;
            startInfo.Arguments = BuildArguments(mode, sessionId);
            startInfo.WorkingDirectory = InstallDirectory;
            startInfo.UseShellExecute = false;
            startInfo.CreateNoWindow = true;
            startInfo.WindowStyle = ProcessWindowStyle.Hidden;
            startInfo.RedirectStandardOutput = true;
            startInfo.RedirectStandardError = true;
            child = new Process();
            child.StartInfo = startInfo;
            child.OutputDataReceived += delegate(object sender, DataReceivedEventArgs args) { };
            child.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs args) { };
            if (!child.Start()) { return -1; }
            child.BeginOutputReadLine();
            child.BeginErrorReadLine();
            Stopwatch childTimer = Stopwatch.StartNew();
            while (!child.WaitForExit(250)) {
                if (progress != null) { progress(); }
                if (childTimer.ElapsedMilliseconds >= ChildTimeoutMilliseconds) {
                    try { child.Kill(); } catch { }
                    return -2;
                }
            }
            return child.ExitCode;
        }
        catch {
            return -1;
        }
        finally {
            if (child != null) { child.Dispose(); }
            ScriptGate.Release();
        }
    }
    private static string BuildArguments(ScriptMode mode, uint sessionId) {
        string prefix = "-NoProfile -NonInteractive -WindowStyle Hidden -File \"" + ScriptPath + "\" -Mode ";
        if (mode == ScriptMode.Initialize) { return prefix + "Initialize"; } if (mode == ScriptMode.Stop) { return prefix + "Stop"; }
        throw new InvalidOperationException();
    }
    private static bool IsExpectedSystemService() {
        try {
            WindowsIdentity identity = WindowsIdentity.GetCurrent();
            string sid = identity.User == null ? null : identity.User.Value;
            string actualPath = Path.GetFullPath(Assembly.GetExecutingAssembly().Location);
            return String.Equals(sid, SystemSid, StringComparison.Ordinal) &&
                String.Equals(actualPath, Path.GetFullPath(ExpectedAssemblyPath), StringComparison.OrdinalIgnoreCase);
        }
        catch {
            return false;
        }
    }
    private static bool ConfigurePreshutdownBudget() {
        IntPtr manager = IntPtr.Zero, service = IntPtr.Zero;
        try {
            manager = OpenSCManager(null, null, 0x0001); // SC_MANAGER_CONNECT
            if (manager == IntPtr.Zero) { return false; }
            service = OpenService(manager, ServiceName, 0x0002); // SERVICE_CHANGE_CONFIG
            if (service == IntPtr.Zero) { return false; }
            SERVICE_PRESHUTDOWN_INFO info = new SERVICE_PRESHUTDOWN_INFO { dwPreshutdownTimeout = StopWaitHintMilliseconds };
            return ChangeServiceConfig2(service, 7, ref info); // SERVICE_CONFIG_PRESHUTDOWN_INFO
        }
        catch { return false; }
        finally {
            if (service != IntPtr.Zero) { CloseServiceHandle(service); }
            if (manager != IntPtr.Zero) { CloseServiceHandle(manager); }
        }
    }
    private static bool ReportServiceStatus(uint state, uint win32ExitCode, uint serviceExitCode, uint waitHint) {
        if (serviceStatusHandle == IntPtr.Zero) { return false; }
        SERVICE_STATUS status = new SERVICE_STATUS();
        status.dwServiceType = SERVICE_WIN32_OWN_PROCESS;
        status.dwCurrentState = state;
        status.dwControlsAccepted = state == SERVICE_RUNNING
            ? SERVICE_ACCEPT_STOP | SERVICE_ACCEPT_SHUTDOWN | SERVICE_ACCEPT_PRESHUTDOWN
            : 0;
        status.dwWin32ExitCode = win32ExitCode;
        status.dwServiceSpecificExitCode = serviceExitCode;
        status.dwWaitHint = waitHint;
        status.dwCheckPoint = (state == SERVICE_START_PENDING || state == SERVICE_STOP_PENDING) ? ++checkpoint : 0;
        try { return SetServiceStatus(serviceStatusHandle, ref status); } catch { return false; }
    }
    private static uint ToServiceExitCode(int exitCode) {
        if (exitCode == 0) { return 0; } if (exitCode < 0) { return 1; }
        return (uint)exitCode;
    }
    private static void WriteStatus(int eventCode, string state, int exitCode, uint sessionId) {
        try {
            string json = "{\"eventCode\":" + eventCode.ToString(CultureInfo.InvariantCulture) +
                ",\"status\":\"" + state + "\",\"utc\":\"" + DateTime.UtcNow.ToString("o", CultureInfo.InvariantCulture) +
                "\",\"exitCode\":" + exitCode.ToString(CultureInfo.InvariantCulture) +
                ",\"sessionId\":" + sessionId.ToString(CultureInfo.InvariantCulture) + "}";
            lock (StatusGate) {
                File.WriteAllText(StatusTempPath, json, new UTF8Encoding(false));
                if (File.Exists(StatusPath)) { File.Replace(StatusTempPath, StatusPath, null); }
                else { File.Move(StatusTempPath, StatusPath); }
                // Startup must not erase the result of the last actual cleanup.
                if (eventCode != 0) {
                    string operationPath = InstallDirectory + @"\lifecycle-last-operation.json";
                    File.WriteAllText(StatusTempPath, json, new UTF8Encoding(false));
                    if (File.Exists(operationPath)) File.Replace(StatusTempPath, operationPath, null);
                    else File.Move(StatusTempPath, operationPath);
                }
            }
        }
        catch {
        }
    }
}
