using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using Microsoft.Win32;

[assembly: System.Runtime.Versioning.TargetFramework(".NETFramework,Version=v4.7.2")]

internal static class RelayTrayIcon {
    private static readonly int[] IconSizes = new [] { 16, 24, 32, 48 };
    private const string NormalLight = "#087f76";
    private const string NormalDark = "#2ad4be";
    private const string WarningLight = "#d98b13";
    private const string WarningDark = "#ffc857";

    internal static bool IsDarkMode() {
        try {
            using (RegistryKey key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize")) {
                if (key == null) return false;
                object system = key.GetValue("SystemUsesLightTheme");
                if (system != null) return Convert.ToInt32(system) == 0;
                object apps = key.GetValue("AppsUseLightTheme");
                if (apps != null) return Convert.ToInt32(apps) == 0;
            }
        } catch { }
        return false;
    }

    internal static Icon CreateIcon(bool warning, bool dark) {
        byte[] bytes = BuildIcoBytes(warning, dark);
        try {
            using (var stream = new MemoryStream(bytes, false))
            using (var loaded = new Icon(stream)) return new Icon(loaded, new Size(32, 32));
        } catch {
            // GDI+ on an older Windows image stack may not load PNG-backed ICO
            // frames. A copied HICON keeps the tray usable in that case.
            using (Bitmap bitmap = RenderBitmap(32, warning ? WarningColor(dark) : NormalColor(dark))) {
                IntPtr handle = bitmap.GetHicon();
                try {
                    using (Icon borrowed = Icon.FromHandle(handle)) return (Icon)borrowed.Clone();
                } finally { DestroyIcon(handle); }
            }
        }
    }

    internal static void WriteIco(string path) {
        File.WriteAllBytes(path, BuildIcoBytes(false, false));
    }

    internal static byte[] BuildIcoBytes(bool warning, bool dark) {
        var images = new List<byte[]>();
        try {
            foreach (int size in IconSizes) {
                using (Bitmap bitmap = RenderBitmap(size, warning ? WarningColor(dark) : NormalColor(dark)))
                using (var stream = new MemoryStream()) {
                    bitmap.Save(stream, ImageFormat.Png);
                    images.Add(stream.ToArray());
                }
            }
            using (var output = new MemoryStream())
            using (var writer = new BinaryWriter(output)) {
                writer.Write((short)0); // reserved
                writer.Write((short)1); // icon image type
                writer.Write((short)images.Count);
                int offset = 6 + 16 * images.Count;
                for (int i = 0; i < images.Count; i++) {
                    int size = IconSizes[i];
                    writer.Write((byte)(size >= 256 ? 0 : size));
                    writer.Write((byte)(size >= 256 ? 0 : size));
                    writer.Write((byte)0); // palette
                    writer.Write((byte)0); // reserved
                    writer.Write((short)1); // color planes
                    writer.Write((short)32); // bits per pixel
                    writer.Write(images[i].Length);
                    writer.Write(offset);
                    offset += images[i].Length;
                }
                foreach (byte[] image in images) writer.Write(image);
                return output.ToArray();
            }
        } finally { images.Clear(); }
    }

    private static Bitmap RenderBitmap(int size, Color color) {
        const int supersample = 4;
        int largeSize = size * supersample;
        using (var large = new Bitmap(largeSize, largeSize, PixelFormat.Format32bppArgb)) {
            using (Graphics graphics = Graphics.FromImage(large)) {
                graphics.SmoothingMode = SmoothingMode.HighQuality;
                graphics.PixelOffsetMode = PixelOffsetMode.HighQuality;
                graphics.CompositingQuality = CompositingQuality.HighQuality;
                graphics.CompositingMode = CompositingMode.SourceOver;
                graphics.Clear(Color.Transparent);
                float scale = (float)largeSize / 32f;
                using (var pen = new Pen(color, 3f * scale)) {
                    pen.StartCap = LineCap.Round;
                    pen.EndCap = LineCap.Round;
                    pen.LineJoin = LineJoin.Round;
                    using (var path = new GraphicsPath()) {
                        path.AddLine(9f * scale, 21f * scale, 12f * scale, 21f * scale);
                        path.AddArc(8f * scale, 13f * scale, 8f * scale, 8f * scale, 90f, -90f);
                        path.AddLine(16f * scale, 17f * scale, 16f * scale, 15f * scale);
                        path.AddArc(16f * scale, 11f * scale, 8f * scale, 8f * scale, 180f, 90f);
                        path.AddLine(20f * scale, 11f * scale, 23f * scale, 11f * scale);
                        graphics.DrawPath(pen, path);
                    }
                    graphics.DrawEllipse(pen, 3f * scale, 18f * scale, 6f * scale, 6f * scale);
                    graphics.DrawEllipse(pen, 23f * scale, 8f * scale, 6f * scale, 6f * scale);
                }
            }
            var result = new Bitmap(size, size, PixelFormat.Format32bppArgb);
            using (Graphics graphics = Graphics.FromImage(result)) {
                graphics.SmoothingMode = SmoothingMode.HighQuality;
                graphics.PixelOffsetMode = PixelOffsetMode.HighQuality;
                graphics.InterpolationMode = InterpolationMode.HighQualityBicubic;
                graphics.CompositingQuality = CompositingQuality.HighQuality;
                graphics.CompositingMode = CompositingMode.SourceCopy;
                graphics.Clear(Color.Transparent);
                graphics.DrawImage(large, new Rectangle(0, 0, size, size), 0, 0, largeSize, largeSize, GraphicsUnit.Pixel);
            }
            return result;
        }
    }

    private static Color NormalColor(bool dark) { return ColorTranslator.FromHtml(dark ? NormalDark : NormalLight); }
    private static Color WarningColor(bool dark) { return ColorTranslator.FromHtml(dark ? WarningDark : WarningLight); }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool DestroyIcon(IntPtr handle);
}

internal sealed class TrayIconCache : IDisposable {
    private Icon normal;
    private Icon warning;
    private bool dark;
    private bool initialized;
    private bool? selectedWarning;

    internal void Apply(NotifyIcon target, bool warningState) {
        bool currentDark = RelayTrayIcon.IsDarkMode();
        if (!initialized || currentDark != dark) {
            Icon nextNormal = null, nextWarning = null;
            try {
                nextNormal = RelayTrayIcon.CreateIcon(false, currentDark);
                nextWarning = RelayTrayIcon.CreateIcon(true, currentDark);
                Icon oldNormal = normal, oldWarning = warning;
                normal = nextNormal; warning = nextWarning; dark = currentDark; initialized = true;
                nextNormal = nextWarning = null;
                if (oldNormal != null) oldNormal.Dispose();
                if (oldWarning != null) oldWarning.Dispose();
            } finally {
                if (nextNormal != null) nextNormal.Dispose();
                if (nextWarning != null) nextWarning.Dispose();
            }
            selectedWarning = null;
        }
        if (!selectedWarning.HasValue || selectedWarning.Value != warningState) {
            target.Icon = warningState ? warning : normal;
            selectedWarning = warningState;
        }
    }

    internal void Dispose(NotifyIcon target) {
        try { if (target != null) target.Icon = null; } catch { }
        Dispose();
    }

    public void Dispose() {
        if (normal != null) { normal.Dispose(); normal = null; }
        if (warning != null) { warning.Dispose(); warning = null; }
        initialized = false; selectedWarning = null;
    }
}

internal static class TrayLauncher {
    internal const string InstallRoot = @"C:\Program Files\CodexDurableRelay";
    internal static ProcessStartInfo StartInfo(string root) {
        return new ProcessStartInfo {
            FileName = @"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe",
            Arguments = "-NoProfile -NonInteractive -WindowStyle Hidden -File \"" + Path.Combine(root, "Launch-ManagedRelay.ps1") + "\"",
            WorkingDirectory = root, UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardOutput = true, RedirectStandardError = true
        };
    }
    internal static Process Start(string root) {
        var process = new Process { StartInfo = StartInfo(root) };
        // Drain fixed launcher output; never persist arbitrary child output.
        process.OutputDataReceived += delegate {};
        process.ErrorDataReceived += delegate {};
        try {
            process.Start(); process.BeginOutputReadLine(); process.BeginErrorReadLine();
            return process;
        } catch { process.Dispose(); throw; }
    }
    internal static void RequestStop(string directory) {
        var json = new JavaScriptSerializer();
        int pid = 0;
        try { pid = Convert.ToInt32(json.Deserialize<Dictionary<string, object>>(File.ReadAllText(Path.Combine(directory, "status.json")))["pid"]); } catch { }
        string path = Path.Combine(directory, "stop.json"), stage = path + ".tray.tmp";
        File.WriteAllText(stage, json.Serialize(new { pid = pid, requestedAt = DateTime.UtcNow.ToString("o") }), new System.Text.UTF8Encoding(false));
        if (File.Exists(path)) File.Replace(stage, path, null); else File.Move(stage, path);
    }
    internal static string PrepareState() {
        var identity = WindowsIdentity.GetCurrent();
        if (new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator)) throw new InvalidOperationException("Run as the configured limited user.");
        if (!String.Equals(Path.GetFullPath(Application.ExecutablePath), Path.Combine(InstallRoot, "CodexRelayTrayHost.exe"), StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("Protected installation required.");
        var settings = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(File.ReadAllText(Path.Combine(InstallRoot, "settings.json")));
        string directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CodexDurableRelay");
        if (Convert.ToString(settings["ownerSid"]) != identity.User.Value || !String.Equals(Path.GetFullPath(Convert.ToString(settings["stateDirectory"])), directory, StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("Configured owner mismatch.");
        Directory.CreateDirectory(directory);
        if ((File.GetAttributes(directory) & FileAttributes.ReparsePoint) != 0) throw new InvalidOperationException("Redirected state directory.");
        var acl = new DirectorySecurity(directory, AccessControlSections.Access);
        acl.SetAccessRuleProtection(true, false);
        foreach (FileSystemAccessRule rule in acl.GetAccessRules(true, false, typeof(SecurityIdentifier))) acl.RemoveAccessRuleSpecific(rule);
        foreach (string sid in new [] {"S-1-5-18", "S-1-5-32-544", identity.User.Value}) {
            acl.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(sid), FileSystemRights.FullControl, InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
        }
        Directory.SetAccessControl(directory, acl);
        return directory;
    }
}

internal sealed class TrayExitController {
    private readonly Func<string, bool> cleanup;
    private readonly Func<bool> launcherExited;
    internal TrayExitController(Func<string, bool> cleanup, Func<bool> launcherExited) { this.cleanup = cleanup; this.launcherExited = launcherExited; }
    internal bool TryExit(string trigger) { return cleanup(trigger) && launcherExited(); }
}

internal sealed class RelayTrayContext : ApplicationContext {
    private readonly NotifyIcon icon;
    private readonly ContextMenuStrip menu;
    private readonly ToolStripMenuItem headline, stop;
    private readonly Control dispatcher = new Control();
    private readonly System.Windows.Forms.Timer timer = new System.Windows.Forms.Timer();
    private readonly TrayIconCache iconCache;
    private readonly Process launcher;
    private readonly RelaySessionGuard guard;
    private readonly TrayExitController exitController;
    private readonly string stateDirectory;
    private readonly DateTime launchedAt;
    private bool busy, exitFailed, disposed;
    private string summary = "正在启动";
    private string cleanupSummary = "尚无上次退出记录";

    internal RelayTrayContext(string directory) {
        stateDirectory = directory;
        IntPtr handle = dispatcher.Handle;
        launcher = TrayLauncher.Start(TrayLauncher.InstallRoot);
        launchedAt = launcher.StartTime.ToUniversalTime();
        try { guard = RelaySessionGuard.Start(directory, delegate { return launcher.HasExited; }); }
        catch {
            // Request a normal stop even if the UI could not initialize. This is
            // the fixed owner's ordinary control file, not privileged IPC.
            try {
                for (int i = 0; i < 24 && !launcher.HasExited; i++) { TrayLauncher.RequestStop(directory); Thread.Sleep(250); }
            } catch { }
            launcher.Dispose(); throw;
        }
        exitController = new TrayExitController(guard.StopAndVerify, delegate { return launcher.HasExited; });
        menu = new ContextMenuStrip();
        headline = new ToolStripMenuItem("Codex 中继：正在启动") { Enabled = false };
        menu.Items.Add(headline);
        menu.Items.Add("查看状态", null, delegate { ShowStatus(); });
        menu.Items.Add(new ToolStripSeparator());
        stop = new ToolStripMenuItem("停止并退出");
        stop.Click += delegate { BeginExit("tray_exit"); };
        menu.Items.Add(stop);
        icon = new NotifyIcon { Text = "Codex 中继：正在启动", ContextMenuStrip = menu };
        iconCache = new TrayIconCache();
        iconCache.Apply(icon, false);
        icon.Visible = true;
        icon.DoubleClick += delegate { ShowStatus(); };
        timer.Interval = 1000;
        timer.Tick += delegate {
            if (busy) return;
            if (launcher.HasExited && !exitFailed) { BeginExit("launcher_exit"); return; }
            UpdateStatus();
        };
        timer.Start();
        UpdateStatus();
    }
    private Dictionary<string, object> Read(string path) {
        try { return new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(File.ReadAllText(path)); } catch { return null; }
    }
    private static string Field(Dictionary<string, object> value, string key) {
        object found; return value != null && value.TryGetValue(key, out found) ? Convert.ToString(found) : "";
    }
    private void UpdateStatus() {
        if (exitFailed) return;
        var state = Read(Path.Combine(stateDirectory, "status.json"));
        DateTime updated;
        string value = "starting";
        if (state != null && state.ContainsKey("updatedAt") && DateTime.TryParse(Convert.ToString(state["updatedAt"]), out updated) && updated.ToUniversalTime() >= launchedAt) value = Convert.ToString(state["status"]);
        switch (value) {
            case "ready":
                var helper = Read(Path.Combine(TrayLauncher.InstallRoot, "helper-status.json"));
                summary = Field(helper, "status") == "mapped" && Field(helper, "relayPid") == Field(state, "pid") ? "已连接" : "等待域名映射";
                break;
            case "waiting_proxy": summary = "等待 Clash 或上游恢复"; break;
            case "degraded": summary = "连接异常，等待恢复"; break;
            case "blocked": summary = "监听不可用"; break;
            case "stopping": case "stopped": summary = "正在停止"; break;
            default: summary = "正在启动"; break;
        }
        var stateGuard = Read(Path.Combine(stateDirectory, "session-guard-status.json"));
        var previous = stateGuard != null && stateGuard.ContainsKey("previousExit") ? stateGuard["previousExit"] as Dictionary<string, object> : null;
        string health = previous == null ? "unknown" : Field(previous, "health");
        cleanupSummary = health == "verified" ? "上次运行退出清理已确认" : health == "unknown" ? "尚无上次退出记录" : "上次运行退出清理未确认";
        bool warning = health != "verified" && health != "unknown";
        iconCache.Apply(icon, warning || value == "degraded" || value == "blocked");
        headline.Text = "Codex 中继：" + summary;
        icon.Text = "Codex 中继：" + summary + (warning ? "（退出记录待核对）" : "");
    }
    private void ShowStatus() {
        MessageBox.Show("当前：" + summary + "\n" + cleanupSummary + "\n\n停止并退出只停止本次运行，下次登录仍自动启动。\nTLS 连通不代表业务消息已经送达。", "Codex 中继", MessageBoxButtons.OK, MessageBoxIcon.Information);
    }
    private void BeginExit(string trigger) {
        if (busy || disposed) return;
        busy = true; stop.Enabled = false;
        summary = "正在停止并清理"; headline.Text = "Codex 中继：" + summary; icon.Text = "Codex 中继：" + summary;
        ThreadPool.QueueUserWorkItem(delegate {
            bool success = false;
            try { success = exitController.TryExit(trigger); } catch { }
            try { dispatcher.BeginInvoke((Action)delegate {
                if (disposed) return;
                if (success) { icon.Visible = false; ExitThread(); }
                else {
                    busy = false; exitFailed = true; stop.Enabled = true;
                    summary = "退出清理未完成，请重试";
                    headline.Text = "Codex 中继：" + summary; icon.Text = "Codex 中继：" + summary; iconCache.Apply(icon, true);
                    icon.ShowBalloonTip(5000, "Codex 中继", "退出清理尚未确认，图标保持运行。可以再次选择停止并退出。", ToolTipIcon.Warning);
                }
            }); } catch { }
        });
    }
    protected override void Dispose(bool disposing) {
        if (disposing && !disposed) {
            disposed = true; timer.Stop(); timer.Dispose();
            icon.Visible = false; iconCache.Dispose(icon); icon.Dispose(); menu.Dispose();
            guard.Dispose(); launcher.Dispose(); dispatcher.Dispose();
        }
        base.Dispose(disposing);
    }
}

internal static class CodexRelayTrayHost {
    [STAThread]
    private static int Main(string[] args) {
        if (args.Length != 0) return 2;
        try {
            // Opt in before any WinForms window or DPI-dependent metric is created.
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            string directory = TrayLauncher.PrepareState();
            bool created;
            using (var mutex = new Mutex(true, "Local\\CodexDurableRelayTray-" + WindowsIdentity.GetCurrent().User.Value, out created)) {
                if (!created) return 0;
                try {
                    using (var context = new RelayTrayContext(directory)) Application.Run(context);
                } finally { mutex.ReleaseMutex(); }
            }
            return 0;
        } catch {
            MessageBox.Show("中继托盘启动失败。请通过控制目录查看状态和安装记录。", "Codex 中继", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return 1;
        }
    }
}
