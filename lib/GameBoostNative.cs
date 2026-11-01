// Native helpers for GameBoost Lite. Compiled in memory by GameBoostLite.ps1 (Add-Type -Path).
// Keep this file C# 5 compatible: Windows PowerShell 5.1 compiles it with the .NET Framework compiler.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Net;
using System.Net.NetworkInformation;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;

// ---------------------------------------------------------------- hotkeys

public sealed class GameBoostHotkeyEventArgs : EventArgs {
    public int Id { get; private set; }
    public GameBoostHotkeyEventArgs(int id) { Id = id; }
}

public sealed class GameBoostHotkeyFilter : IMessageFilter {
    public event EventHandler<GameBoostHotkeyEventArgs> Pressed;
    public bool PreFilterMessage(ref Message message) {
        if (message.Msg == 0x0312 && Pressed != null)
            Pressed(this, new GameBoostHotkeyEventArgs(message.WParam.ToInt32()));
        return false;
    }
}

public static class GameBoostHotkeyNative {
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool RegisterHotKey(IntPtr window, int id, uint modifiers, uint key);
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool UnregisterHotKey(IntPtr window, int id);
}

// ---------------------------------------------------------------- processes

public sealed class GameBoostProcessInfo {
    public int Id;
    public int ParentId;
    public string Name;
    public string Path;
    public long CreateTime;
    public double CpuSeconds;
    public double CpuPercent;
    public long WorkingSet;
    public bool HasWindow;
    public string Key { get { return Id.ToString() + ":" + CreateTime.ToString(); } }
}

public static class GameBoostEngine {
    const uint QueryLimited = 0x1000;
    const uint SetInformation = 0x0200;
    const uint NormalPriority = 0x20;
    const uint BelowNormalPriority = 0x4000;

    public static readonly HashSet<string> ExcludedNames = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
    // System processes whose CPU time is read for the session summary (Windows Update, Defender).
    public static readonly HashSet<string> SystemWatchNames = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

    [DllImport("ntdll.dll")] static extern int NtQuerySystemInformation(int infoClass, IntPtr buffer, int length, out int returnLength);

    // CPU seconds per watched process name, read the way Task Manager does: one system call,
    // no handle to any process (protected services like Defender included).
    public static Dictionary<string, double> SystemCpuSeconds() {
        var result = new Dictionary<string, double>(StringComparer.OrdinalIgnoreCase);
        if (SystemWatchNames.Count == 0 || IntPtr.Size != 8) return result;
        int length = 1 << 20;
        IntPtr buffer = Marshal.AllocHGlobal(length);
        try {
            int needed;
            int status = NtQuerySystemInformation(5, buffer, length, out needed);
            for (int attempt = 0; status == unchecked((int)0xC0000004) && attempt < 4; attempt++) {
                Marshal.FreeHGlobal(buffer);
                length = Math.Max(needed + 65536, length * 2);
                buffer = Marshal.AllocHGlobal(length);
                status = NtQuerySystemInformation(5, buffer, length, out needed);
            }
            if (status != 0) return result;
            int offset = 0;
            while (offset >= 0 && offset + 88 <= length) {
                IntPtr entry = IntPtr.Add(buffer, offset);
                int next = Marshal.ReadInt32(entry, 0);
                int nameBytes = (ushort)Marshal.ReadInt16(entry, 56);
                IntPtr namePointer = Marshal.ReadIntPtr(entry, 64);
                if (nameBytes > 0 && namePointer != IntPtr.Zero) {
                    string name = Marshal.PtrToStringUni(namePointer, nameBytes / 2);
                    if (name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) name = name.Substring(0, name.Length - 4);
                    if (SystemWatchNames.Contains(name)) {
                        double seconds = (Marshal.ReadInt64(entry, 40) + Marshal.ReadInt64(entry, 48)) / 10000000.0;
                        double existing;
                        result.TryGetValue(name, out existing);
                        result[name] = existing + seconds;
                    }
                }
                if (next <= 0) break;
                offset += next;
            }
        } catch { }
        finally { Marshal.FreeHGlobal(buffer); }
        return result;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct ProcessEntry {
        public uint Size; public uint Usage; public uint ProcessId; public IntPtr DefaultHeapId;
        public uint ModuleId; public uint Threads; public uint ParentProcessId; public int PriorityBase;
        public uint Flags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string ExeFile;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct PowerThrottlingState { public uint Version; public uint ControlMask; public uint StateMask; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
    struct MemoryStatus {
        public uint Length; public uint MemoryLoad;
        public ulong TotalPhys, AvailPhys, TotalPageFile, AvailPageFile, TotalVirtual, AvailVirtual, AvailExtendedVirtual;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct Rect { public int Left, Top, Right, Bottom; }
    delegate bool EnumWindowsCallback(IntPtr window, IntPtr parameter);

    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr OpenProcess(uint access, bool inherit, int processId);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool QueryFullProcessImageName(IntPtr process, int flags, StringBuilder name, ref int size);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetProcessTimes(IntPtr process, out long creation, out long exit, out long kernel, out long user);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetExitCodeProcess(IntPtr process, out uint exitCode);
    [DllImport("kernel32.dll", SetLastError = true)] static extern uint GetPriorityClass(IntPtr process);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetPriorityClass(IntPtr process, uint priority);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetProcessInformation(IntPtr process, int infoClass, ref PowerThrottlingState info, uint size);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetProcessInformation(IntPtr process, int infoClass, ref PowerThrottlingState info, uint size);
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint processId);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool Process32FirstW(IntPtr snapshot, ref ProcessEntry entry);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool Process32NextW(IntPtr snapshot, ref ProcessEntry entry);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetSystemTimes(out long idle, out long kernel, out long user);
    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)] static extern bool GlobalMemoryStatusEx(ref MemoryStatus status);
    [DllImport("kernel32.dll")] static extern ulong GetTickCount64();
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetProcessWorkingSetSize(IntPtr process, IntPtr minimum, IntPtr maximum);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out int processId);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsCallback callback, IntPtr parameter);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr window, uint command);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr window, out Rect rect);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongW")] static extern int GetWindowLong(IntPtr window, int index);

    // One cheap pass over all processes. Paths and CPU times are read with limited access,
    // which anti-cheat protected games still allow.
    public static List<GameBoostProcessInfo> Snapshot() {
        var parents = new Dictionary<int, int>();
        IntPtr snapshot = CreateToolhelp32Snapshot(0x2, 0);
        if (snapshot != IntPtr.Zero && snapshot != new IntPtr(-1)) {
            try {
                var entry = new ProcessEntry();
                entry.Size = (uint)Marshal.SizeOf(typeof(ProcessEntry));
                if (Process32FirstW(snapshot, ref entry)) {
                    do { parents[(int)entry.ProcessId] = (int)entry.ParentProcessId; }
                    while (Process32NextW(snapshot, ref entry));
                }
            } finally { CloseHandle(snapshot); }
        }

        HashSet<int> windowOwners = WindowProcessIds();
        int session;
        using (Process current = Process.GetCurrentProcess()) session = current.SessionId;
        var result = new List<GameBoostProcessInfo>();
        foreach (Process process in Process.GetProcesses()) {
            try {
                var info = new GameBoostProcessInfo();
                info.Id = process.Id;
                info.Name = process.ProcessName;
                info.WorkingSet = process.WorkingSet64;
                int parent;
                if (parents.TryGetValue(info.Id, out parent)) info.ParentId = parent;
                info.HasWindow = windowOwners.Contains(info.Id);
                if (info.Id > 4 && process.SessionId == session) ReadHandleDetails(info);
                result.Add(info);
            } catch { }
            finally { process.Dispose(); }
        }
        return result;
    }

    static void ReadHandleDetails(GameBoostProcessInfo info) {
        IntPtr handle = OpenProcess(QueryLimited, false, info.Id);
        if (handle == IntPtr.Zero) return;
        try {
            var builder = new StringBuilder(1024);
            int size = builder.Capacity;
            if (QueryFullProcessImageName(handle, 0, builder, ref size)) info.Path = builder.ToString(0, size);
            long creation, exit, kernel, user;
            if (GetProcessTimes(handle, out creation, out exit, out kernel, out user)) {
                info.CreateTime = creation;
                info.CpuSeconds = (kernel + user) / 10000000.0;
            }
        } finally { CloseHandle(handle); }
    }

    static HashSet<int> WindowProcessIds() {
        var owners = new HashSet<int>();
        EnumWindowsCallback callback = delegate(IntPtr window, IntPtr parameter) {
            if (IsWindowVisible(window) && GetWindow(window, 4) == IntPtr.Zero) {
                int processId;
                GetWindowThreadProcessId(window, out processId);
                owners.Add(processId);
            }
            return true;
        };
        EnumWindows(callback, IntPtr.Zero);
        GC.KeepAlive(callback);
        return owners;
    }

    public static string ProcessPath(int processId) {
        var info = new GameBoostProcessInfo();
        info.Id = processId;
        ReadHandleDetails(info);
        return info.Path;
    }

    public static long CreateTime(int processId) {
        var info = new GameBoostProcessInfo();
        info.Id = processId;
        ReadHandleDetails(info);
        return info.CreateTime;
    }

    public static bool IsGameLibraryPath(string path) {
        if (string.IsNullOrEmpty(path)) return false;
        string p = path.ToLowerInvariant();
        bool known =
            p.Contains("\\steamapps\\common\\") ||
            (p.Contains("\\epic games\\") && !p.Contains("\\launcher\\")) ||
            p.Contains("\\xboxgames\\") ||
            p.Contains("\\ea games\\") ||
            p.Contains("\\ubisoft game launcher\\games\\") ||
            (p.Contains("\\rockstar games\\") && !p.Contains("\\launcher\\"));
        if (!known) return false;
        // Installers and helpers that live inside game folders are not the game.
        return !(p.Contains("crashreport") || p.Contains("anticheat") || p.Contains("crashhandler") ||
                 p.Contains("\\steamworks shared\\") || p.Contains("\\_commonredist\\") || p.Contains("\\redist\\"));
    }

    public static List<GameBoostProcessInfo> FindGames(List<GameBoostProcessInfo> snapshot) {
        var games = new List<GameBoostProcessInfo>();
        foreach (GameBoostProcessInfo info in snapshot) {
            if (info.Path == null || ExcludedNames.Contains(info.Name)) continue;
            if (!IsGameLibraryPath(info.Path)) continue;
            if (info.WorkingSet > 120L * 1024 * 1024 || info.HasWindow) games.Add(info);
        }
        return games;
    }

    public static bool IsAlive(int processId, long createTime) {
        IntPtr handle = OpenProcess(QueryLimited, false, processId);
        if (handle == IntPtr.Zero) return false;
        try {
            uint code;
            if (!GetExitCodeProcess(handle, out code) || code != 259) return false;
            return SameProcess(handle, createTime);
        } finally { CloseHandle(handle); }
    }

    static bool SameProcess(IntPtr handle, long createTime) {
        if (createTime == 0) return false;
        long creation, exit, kernel, user;
        return GetProcessTimes(handle, out creation, out exit, out kernel, out user) && creation == createTime;
    }

    public static bool TrySetPriority(int processId, long createTime, uint priority) {
        IntPtr handle = OpenProcess(QueryLimited | SetInformation, false, processId);
        if (handle == IntPtr.Zero) return false;
        try { return SameProcess(handle, createTime) && SetPriorityClass(handle, priority); }
        finally { CloseHandle(handle); }
    }

    static bool ReadThrottling(IntPtr handle, out uint control, out uint state) {
        var current = new PowerThrottlingState();
        current.Version = 1;
        bool ok = GetProcessInformation(handle, 4, ref current, (uint)Marshal.SizeOf(typeof(PowerThrottlingState)));
        control = ok ? current.ControlMask : 0;
        state = ok ? current.StateMask : 0;
        return ok;
    }

    // Efficiency mode = EcoQoS + below normal priority (what Task Manager does, one step milder).
    // Only processes running at normal priority are touched. The app's own EcoQoS choice is returned
    // so it can be put back exactly. Returns the previous priority, 0 when skipped.
    public static uint TryEnableEfficiency(int processId, long createTime, out uint previousControl, out uint previousState) {
        previousControl = 0;
        previousState = 0;
        IntPtr handle = OpenProcess(QueryLimited | SetInformation, false, processId);
        if (handle == IntPtr.Zero) return 0;
        try {
            if (!SameProcess(handle, createTime)) return 0;
            uint previous = GetPriorityClass(handle);
            if (previous != NormalPriority) return 0;
            ReadThrottling(handle, out previousControl, out previousState);
            var state = new PowerThrottlingState();
            state.Version = 1; state.ControlMask = 1; state.StateMask = 1;
            bool eco = SetProcessInformation(handle, 4, ref state, (uint)Marshal.SizeOf(typeof(PowerThrottlingState)));
            bool lowered = SetPriorityClass(handle, BelowNormalPriority);
            return (eco || lowered) ? previous : 0;
        } finally { CloseHandle(handle); }
    }

    // { control mask, state mask } or null when Windows does not report it.
    public static uint[] GetThrottling(int processId) {
        IntPtr handle = OpenProcess(QueryLimited, false, processId);
        if (handle == IntPtr.Zero) return null;
        try {
            uint control, state;
            return ReadThrottling(handle, out control, out state) ? new uint[] { control, state } : null;
        } finally { CloseHandle(handle); }
    }

    public static bool TryRestoreEfficiency(int processId, long createTime, uint previousPriority, uint previousControl, uint previousState) {
        IntPtr handle = OpenProcess(QueryLimited | SetInformation, false, processId);
        if (handle == IntPtr.Zero) return false;
        try {
            if (!SameProcess(handle, createTime)) return false;
            // Put back the app's own EcoQoS choice; 0/0 hands it back to Windows.
            var state = new PowerThrottlingState();
            state.Version = 1;
            state.ControlMask = previousControl;
            state.StateMask = previousState;
            SetProcessInformation(handle, 4, ref state, (uint)Marshal.SizeOf(typeof(PowerThrottlingState)));
            if (GetPriorityClass(handle) == BelowNormalPriority)
                SetPriorityClass(handle, previousPriority == 0 ? NormalPriority : previousPriority);
            return true;
        } finally { CloseHandle(handle); }
    }

    public static uint GetPriority(int processId) {
        IntPtr handle = OpenProcess(QueryLimited, false, processId);
        if (handle == IntPtr.Zero) return 0;
        try { return GetPriorityClass(handle); } finally { CloseHandle(handle); }
    }

    static Dictionary<string, double> previousCpu = new Dictionary<string, double>();
    static DateTime previousSampleUtc = DateTime.MinValue;

    public static void ResetActivity() {
        previousCpu = new Dictionary<string, double>();
        previousSampleUtc = DateTime.MinValue;
    }

    // Fills CpuPercent (share of the whole CPU since the previous sample) and returns busy or large processes.
    public static List<GameBoostProcessInfo> SampleActivity(List<GameBoostProcessInfo> snapshot, double cpuThreshold, long workingSetThreshold) {
        DateTime now = DateTime.UtcNow;
        double elapsed = previousSampleUtc == DateTime.MinValue ? 0 : (now - previousSampleUtc).TotalSeconds;
        var next = new Dictionary<string, double>();
        var busy = new List<GameBoostProcessInfo>();
        foreach (GameBoostProcessInfo info in snapshot) {
            if (info.CreateTime == 0) continue;
            next[info.Key] = info.CpuSeconds;
            double before;
            if (elapsed > 0 && previousCpu.TryGetValue(info.Key, out before))
                info.CpuPercent = Math.Round(Math.Max(0, (info.CpuSeconds - before) / elapsed / Environment.ProcessorCount * 100.0), 1);
            if (info.CpuPercent >= cpuThreshold || info.WorkingSet >= workingSetThreshold) busy.Add(info);
        }
        previousCpu = next;
        previousSampleUtc = now;
        return busy;
    }

    public static int ForegroundProcessId() {
        IntPtr window = GetForegroundWindow();
        if (window == IntPtr.Zero) return 0;
        int processId;
        GetWindowThreadProcessId(window, out processId);
        return processId;
    }

    // True when the foreground window covers its whole monitor without a title bar
    // (exclusive or borderless fullscreen).
    public static bool IsForegroundFullscreen() {
        IntPtr window = GetForegroundWindow();
        if (window == IntPtr.Zero) return false;
        const int Caption = 0x00C00000;
        if ((GetWindowLong(window, -16) & Caption) == Caption) return false;
        Rect rect;
        if (!GetWindowRect(window, out rect)) return false;
        Rectangle bounds = Screen.FromHandle(window).Bounds;
        return rect.Left <= bounds.Left + 2 && rect.Top <= bounds.Top + 2 &&
               rect.Right >= bounds.Right - 2 && rect.Bottom >= bounds.Bottom - 2;
    }

    static long lastIdle, lastTotal;

    // Average CPU use since the previous call.
    public static double CpuPercent() {
        long idle, kernel, user;
        if (!GetSystemTimes(out idle, out kernel, out user)) return 0;
        long total = kernel + user;
        long idleDelta = idle - lastIdle, totalDelta = total - lastTotal;
        bool first = lastTotal == 0;
        lastIdle = idle; lastTotal = total;
        if (first || totalDelta <= 0) return 0;
        return Math.Max(0, Math.Min(100, 100.0 * (totalDelta - idleDelta) / totalDelta));
    }

    // { available GiB, total GiB }
    public static double[] MemoryGb() {
        var status = new MemoryStatus();
        status.Length = (uint)Marshal.SizeOf(typeof(MemoryStatus));
        if (!GlobalMemoryStatusEx(ref status)) return new double[] { 0, 0 };
        return new double[] { status.AvailPhys / 1073741824.0, status.TotalPhys / 1073741824.0 };
    }

    public static double UptimeDays() { return GetTickCount64() / 86400000.0; }

    public static void TrimCurrentProcess() {
        SetProcessWorkingSetSize(GetCurrentProcess(), new IntPtr(-1), new IntPtr(-1));
    }
}

// ---------------------------------------------------------------- displays

public sealed class GameBoostMonitor {
    public string Name;
    public string GdiName;
    public string Adapter;
    public string Connection;
    public uint OutputTechnology;
    public bool Internal;
    public bool Primary;
    public int Width, Height;
    public int PositionX, PositionY;
    public double Refresh;
    public int MaxRefreshAtResolution;
    public int MaxWidth, MaxHeight;
    public bool HdrSupported, HdrEnabled;
    public bool Cloned;
    public int BitsPerColor;
    public List<int> RatesAtResolution = new List<int>();
    public List<string> Modes = new List<string>();
}

public static class GameBoostDisplay {
    [StructLayout(LayoutKind.Sequential)] struct Luid { public uint LowPart; public int HighPart; }
    [StructLayout(LayoutKind.Sequential)] struct Rational { public uint Numerator; public uint Denominator; }
    [StructLayout(LayoutKind.Sequential)] struct PathSourceInfo { public Luid AdapterId; public uint Id; public uint ModeInfoIdx; public uint StatusFlags; }
    [StructLayout(LayoutKind.Sequential)]
    struct PathTargetInfo {
        public Luid AdapterId; public uint Id; public uint ModeInfoIdx; public uint OutputTechnology;
        public uint Rotation; public uint Scaling; public Rational RefreshRate; public uint ScanLineOrdering;
        public int TargetAvailable; public uint StatusFlags;
    }
    [StructLayout(LayoutKind.Sequential)] struct PathInfo { public PathSourceInfo SourceInfo; public PathTargetInfo TargetInfo; public uint Flags; }
    [StructLayout(LayoutKind.Explicit, Size = 64)]
    struct ModeInfo {
        [FieldOffset(0)] public uint InfoType;
        [FieldOffset(4)] public uint Id;
        [FieldOffset(16)] public uint SourceWidth;
        [FieldOffset(20)] public uint SourceHeight;
        [FieldOffset(28)] public int PositionX;
        [FieldOffset(32)] public int PositionY;
    }
    [StructLayout(LayoutKind.Sequential)] struct DeviceInfoHeader { public int Type; public int Size; public Luid AdapterId; public uint Id; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct TargetDeviceName {
        public DeviceInfoHeader Header; public uint Flags; public uint OutputTechnology;
        public ushort EdidManufactureId; public ushort EdidProductCodeId; public uint ConnectorInstance;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string FriendlyName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DevicePath;
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct SourceDeviceName {
        public DeviceInfoHeader Header;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string GdiName;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct AdvancedColorInfo { public DeviceInfoHeader Header; public uint Value; public uint ColorEncoding; public uint BitsPerColorChannel; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct DisplayDevice {
        public int Cb;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
        public int StateFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceId;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct DevMode {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
        public short SpecVersion; public short DriverVersion; public short Size; public short DriverExtra; public int Fields;
        public int PositionX; public int PositionY; public int DisplayOrientation; public int DisplayFixedOutput;
        public short Color; public short Duplex; public short YResolution; public short TTOption; public short Collate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string FormName;
        public short LogPixels; public int BitsPerPel; public int PelsWidth; public int PelsHeight; public int DisplayFlags; public int DisplayFrequency;
        public int ICMMethod; public int ICMIntent; public int MediaType; public int DitherType; public int Reserved1; public int Reserved2; public int PanningWidth; public int PanningHeight;
    }

    [DllImport("user32.dll")] static extern int GetDisplayConfigBufferSizes(uint flags, out uint pathCount, out uint modeCount);
    [DllImport("user32.dll")] static extern int QueryDisplayConfig(uint flags, ref uint pathCount, [Out] PathInfo[] paths, ref uint modeCount, [Out] ModeInfo[] modes, IntPtr topology);
    [DllImport("user32.dll")] static extern int DisplayConfigGetDeviceInfo(ref TargetDeviceName info);
    [DllImport("user32.dll")] static extern int DisplayConfigGetDeviceInfo(ref SourceDeviceName info);
    [DllImport("user32.dll")] static extern int DisplayConfigGetDeviceInfo(ref AdvancedColorInfo info);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool EnumDisplayDevices(string device, uint index, ref DisplayDevice info, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool EnumDisplaySettings(string device, int mode, ref DevMode devMode);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int ChangeDisplaySettingsEx(string device, ref DevMode devMode, IntPtr window, uint flags, IntPtr parameter);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "ChangeDisplaySettingsExW")] static extern int ChangeDisplaySettingsExReset(string device, IntPtr devMode, IntPtr window, uint flags, IntPtr parameter);

    public static string ConnectionName(uint technology) {
        switch (technology) {
            case 0: return "VGA";
            case 4: return "DVI";
            case 5: return "HDMI";
            case 6: return "Dahili (LVDS)";
            case 10: return "DisplayPort";
            case 11: return "Dahili (eDP)";
            case 13: return "Dahili";
            case 15: return "Miracast";
            case 16: return "USB / Dock";
            case 17: return "Sanal";
            case 18: return "USB-C DisplayPort";
            case 0x80000000: return "Dahili";
            default: return "Diger";
        }
    }

    static bool IsInternal(uint technology) {
        return technology == 6 || technology == 11 || technology == 13 || technology == 0x80000000;
    }

    static DevMode NewDevMode() {
        var mode = new DevMode();
        mode.Size = (short)Marshal.SizeOf(typeof(DevMode));
        return mode;
    }

    public static List<GameBoostMonitor> GetMonitors() {
        var result = new List<GameBoostMonitor>();
        uint pathCount, modeCount;
        if (GetDisplayConfigBufferSizes(2, out pathCount, out modeCount) != 0) return result;
        var paths = new PathInfo[pathCount];
        var modes = new ModeInfo[modeCount];
        if (QueryDisplayConfig(2, ref pathCount, paths, ref modeCount, modes, IntPtr.Zero) != 0) return result;

        var adapters = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        var primaries = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var device = new DisplayDevice();
        device.Cb = Marshal.SizeOf(typeof(DisplayDevice));
        for (uint index = 0; EnumDisplayDevices(null, index, ref device, 0); index++) {
            adapters[device.DeviceName] = device.DeviceString;
            if ((device.StateFlags & 0x4) != 0) primaries.Add(device.DeviceName);
            device = new DisplayDevice();
            device.Cb = Marshal.SizeOf(typeof(DisplayDevice));
        }

        for (int i = 0; i < pathCount; i++) {
            PathInfo path = paths[i];
            var monitor = new GameBoostMonitor();

            var target = new TargetDeviceName();
            target.Header.Type = 2;
            target.Header.Size = Marshal.SizeOf(typeof(TargetDeviceName));
            target.Header.AdapterId = path.TargetInfo.AdapterId;
            target.Header.Id = path.TargetInfo.Id;
            if (DisplayConfigGetDeviceInfo(ref target) == 0) monitor.Name = target.FriendlyName;

            var source = new SourceDeviceName();
            source.Header.Type = 1;
            source.Header.Size = Marshal.SizeOf(typeof(SourceDeviceName));
            source.Header.AdapterId = path.SourceInfo.AdapterId;
            source.Header.Id = path.SourceInfo.Id;
            if (DisplayConfigGetDeviceInfo(ref source) == 0) monitor.GdiName = source.GdiName;

            monitor.OutputTechnology = path.TargetInfo.OutputTechnology;
            monitor.Connection = ConnectionName(monitor.OutputTechnology);
            monitor.Internal = IsInternal(monitor.OutputTechnology);
            if (string.IsNullOrEmpty(monitor.Name)) monitor.Name = monitor.Internal ? "Dahili ekran" : "Harici ekran";

            Rational rate = path.TargetInfo.RefreshRate;
            if (rate.Denominator != 0) monitor.Refresh = Math.Round((double)rate.Numerator / rate.Denominator, 2);
            uint sourceIndex = path.SourceInfo.ModeInfoIdx;
            if (sourceIndex < modeCount && modes[sourceIndex].InfoType == 1) {
                monitor.Width = (int)modes[sourceIndex].SourceWidth;
                monitor.Height = (int)modes[sourceIndex].SourceHeight;
                monitor.PositionX = modes[sourceIndex].PositionX;
                monitor.PositionY = modes[sourceIndex].PositionY;
            }

            var color = new AdvancedColorInfo();
            color.Header.Type = 9;
            color.Header.Size = Marshal.SizeOf(typeof(AdvancedColorInfo));
            color.Header.AdapterId = path.TargetInfo.AdapterId;
            color.Header.Id = path.TargetInfo.Id;
            if (DisplayConfigGetDeviceInfo(ref color) == 0) {
                monitor.HdrSupported = (color.Value & 1) != 0;
                monitor.HdrEnabled = (color.Value & 2) != 0;
                monitor.BitsPerColor = (int)color.BitsPerColorChannel;
            }

            if (monitor.GdiName != null) {
                string adapter;
                if (adapters.TryGetValue(monitor.GdiName, out adapter)) monitor.Adapter = adapter;
                monitor.Primary = primaries.Contains(monitor.GdiName);
                ReadModes(monitor);
            }
            result.Add(monitor);
        }
        // Duplicate (clone) mode: several screens share one desktop source.
        foreach (GameBoostMonitor monitor in result) {
            int sharing = 0;
            foreach (GameBoostMonitor other in result) if (other.GdiName != null && other.GdiName == monitor.GdiName) sharing++;
            monitor.Cloned = sharing > 1;
        }
        return result;
    }

    static void ReadModes(GameBoostMonitor monitor) {
        var best = new Dictionary<string, int>();
        var order = new List<string>();
        var rates = new HashSet<int>();
        DevMode mode = NewDevMode();
        for (int index = 0; EnumDisplaySettings(monitor.GdiName, index, ref mode); index++) {
            if ((mode.DisplayFlags & 0x2) == 0 && mode.BitsPerPel >= 24 && mode.DisplayFrequency > 1) {
                string key = mode.PelsWidth + "x" + mode.PelsHeight;
                int existing;
                if (!best.TryGetValue(key, out existing)) { best[key] = mode.DisplayFrequency; order.Add(key); }
                else if (mode.DisplayFrequency > existing) best[key] = mode.DisplayFrequency;
                if (mode.PelsWidth == monitor.Width && mode.PelsHeight == monitor.Height) {
                    rates.Add(mode.DisplayFrequency);
                    if (mode.DisplayFrequency > monitor.MaxRefreshAtResolution) monitor.MaxRefreshAtResolution = mode.DisplayFrequency;
                }
                if ((long)mode.PelsWidth * mode.PelsHeight > (long)monitor.MaxWidth * monitor.MaxHeight) {
                    monitor.MaxWidth = mode.PelsWidth;
                    monitor.MaxHeight = mode.PelsHeight;
                }
            }
            mode = NewDevMode();
        }
        order.Sort(delegate(string a, string b) { return Pixels(b).CompareTo(Pixels(a)); });
        foreach (string key in order) monitor.Modes.Add(key + " @ " + best[key] + " Hz");
        monitor.RatesAtResolution.AddRange(rates);
        monitor.RatesAtResolution.Sort();
    }

    static long Pixels(string key) {
        string[] parts = key.Split('x');
        return long.Parse(parts[0]) * long.Parse(parts[1]);
    }

    static readonly Dictionary<string, DevMode> modesBeforeChange = new Dictionary<string, DevMode>(StringComparer.OrdinalIgnoreCase);

    // Changes only the refresh rate. persist=false is a temporary change; RevertToPrevious puts back
    // the exact mode that was on screen before it (also a game's temporary resolution).
    public static int ApplyRefresh(string gdiName, int refresh, bool persist) {
        DevMode previous = NewDevMode();
        if (!EnumDisplaySettings(gdiName, -1, ref previous)) return -100;
        DevMode mode = previous;
        mode.DisplayFrequency = refresh;
        mode.Fields = 0x80000 | 0x100000 | 0x400000;
        int test = ChangeDisplaySettingsEx(gdiName, ref mode, IntPtr.Zero, 2, IntPtr.Zero);
        if (test != 0) return test;
        int result = ChangeDisplaySettingsEx(gdiName, ref mode, IntPtr.Zero, persist ? 1u : 0u, IntPtr.Zero);
        if (persist) modesBeforeChange.Remove(gdiName);
        else if (result == 0 && !modesBeforeChange.ContainsKey(gdiName)) modesBeforeChange[gdiName] = previous;
        return result;
    }

    public static int RevertToPrevious(string gdiName) {
        DevMode previous;
        if (modesBeforeChange.TryGetValue(gdiName, out previous)) {
            modesBeforeChange.Remove(gdiName);
            if (ChangeDisplaySettingsEx(gdiName, ref previous, IntPtr.Zero, 0, IntPtr.Zero) == 0) return 0;
        }
        return RevertToSaved(gdiName);
    }

    public static int RevertToSaved(string gdiName) {
        return ChangeDisplaySettingsExReset(gdiName, IntPtr.Zero, IntPtr.Zero, 0, IntPtr.Zero);
    }
}

// ---------------------------------------------------------------- audio (Core Audio)

[StructLayout(LayoutKind.Sequential)]
struct GbPropertyKey { public Guid FormatId; public int PropertyId; }

[StructLayout(LayoutKind.Explicit)]
struct GbPropVariant {
    [FieldOffset(0)] public ushort Type;
    [FieldOffset(8)] public IntPtr Pointer;
    [FieldOffset(8)] public uint UInt;
    [FieldOffset(8)] public int BlobSize;
    [FieldOffset(16)] public IntPtr BlobData;
}

[ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
class GbMMDeviceEnumeratorCom { }

[ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IGbMMDeviceEnumerator {
    [PreserveSig] int EnumAudioEndpoints(int dataFlow, int stateMask, out IGbMMDeviceCollection devices);
    [PreserveSig] int GetDefaultAudioEndpoint(int dataFlow, int role, out IGbMMDevice device);
    [PreserveSig] int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IGbMMDevice device);
    [PreserveSig] int RegisterEndpointNotificationCallback(IntPtr client);
    [PreserveSig] int UnregisterEndpointNotificationCallback(IntPtr client);
}

[ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IGbMMDeviceCollection {
    [PreserveSig] int GetCount(out uint count);
    [PreserveSig] int Item(uint index, out IGbMMDevice device);
}

[ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IGbMMDevice {
    [PreserveSig] int Activate(ref Guid iid, int context, IntPtr parameters, [MarshalAs(UnmanagedType.IUnknown)] out object instance);
    [PreserveSig] int OpenPropertyStore(int access, out IGbPropertyStore store);
    [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
    [PreserveSig] int GetState(out int state);
}

[ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IGbPropertyStore {
    [PreserveSig] int GetCount(out uint count);
    [PreserveSig] int GetAt(uint index, out GbPropertyKey key);
    [PreserveSig] int GetValue(ref GbPropertyKey key, out GbPropVariant value);
    [PreserveSig] int SetValue(ref GbPropertyKey key, ref GbPropVariant value);
    [PreserveSig] int Commit();
}

[ComImport, Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IGbAudioEndpointVolume {
    [PreserveSig] int RegisterControlChangeNotify(IntPtr notify);
    [PreserveSig] int UnregisterControlChangeNotify(IntPtr notify);
    [PreserveSig] int GetChannelCount(out uint count);
    [PreserveSig] int SetMasterVolumeLevel(float level, ref Guid context);
    [PreserveSig] int SetMasterVolumeLevelScalar(float level, ref Guid context);
    [PreserveSig] int GetMasterVolumeLevel(out float level);
    [PreserveSig] int GetMasterVolumeLevelScalar(out float level);
    [PreserveSig] int SetChannelVolumeLevel(uint channel, float level, ref Guid context);
    [PreserveSig] int SetChannelVolumeLevelScalar(uint channel, float level, ref Guid context);
    [PreserveSig] int GetChannelVolumeLevel(uint channel, out float level);
    [PreserveSig] int GetChannelVolumeLevelScalar(uint channel, out float level);
    [PreserveSig] int SetMute([MarshalAs(UnmanagedType.Bool)] bool mute, ref Guid context);
    [PreserveSig] int GetMute([MarshalAs(UnmanagedType.Bool)] out bool mute);
}

public sealed class GameBoostAudioDevice {
    public string Id;
    public string Name;
    public string Description;
    public string Adapter;
    public string Enumerator;
    public bool IsCapture;
    public bool IsDefault;
    public bool IsDefaultCommunications;
    public bool Active;
    public int FormFactor = 10;
    public int SampleRate;
    public int Bits;
    public int Channels;
    public double Volume = -1;
    public bool Muted;
}

public static class GameBoostAudio {
    static readonly Guid DeviceFormatId = new Guid("a45c254e-df1c-4efd-8020-67d146a850e0");
    static readonly Guid InterfaceFormatId = new Guid("026e516e-b814-414b-83cd-856d6fef4822");
    static readonly Guid FormFactorId = new Guid("1da5d803-d492-4edd-8c23-e0c0ffee7f0e");
    static readonly Guid EngineFormatId = new Guid("f19f064d-082c-4e27-bc73-6882a1bb8e4c");

    [DllImport("ole32.dll")] static extern int PropVariantClear(ref GbPropVariant value);

    public static List<GameBoostAudioDevice> GetDevices() {
        var result = new List<GameBoostAudioDevice>();
        IGbMMDeviceEnumerator enumerator = null;
        try {
            enumerator = (IGbMMDeviceEnumerator)new GbMMDeviceEnumeratorCom();
            for (int flow = 0; flow <= 1; flow++) {
                string defaultId = DefaultId(enumerator, flow, 0);
                string communicationsId = DefaultId(enumerator, flow, 2);
                IGbMMDeviceCollection collection;
                // Active (1) and unplugged (8) endpoints.
                if (enumerator.EnumAudioEndpoints(flow, 1 | 8, out collection) != 0 || collection == null) continue;
                uint count;
                collection.GetCount(out count);
                for (uint i = 0; i < count; i++) {
                    IGbMMDevice device;
                    if (collection.Item(i, out device) != 0 || device == null) continue;
                    try {
                        var info = new GameBoostAudioDevice();
                        device.GetId(out info.Id);
                        int state;
                        device.GetState(out state);
                        info.Active = state == 1;
                        info.IsCapture = flow == 1;
                        info.IsDefault = info.Id != null && info.Id == defaultId;
                        info.IsDefaultCommunications = info.Id != null && info.Id == communicationsId;
                        ReadProperties(device, info);
                        if (info.IsDefault && info.Active) ReadVolume(device, info);
                        result.Add(info);
                    } finally { Marshal.ReleaseComObject(device); }
                }
                Marshal.ReleaseComObject(collection);
            }
        } catch { }
        finally { if (enumerator != null) Marshal.ReleaseComObject(enumerator); }
        return result;
    }

    static string DefaultId(IGbMMDeviceEnumerator enumerator, int flow, int role) {
        IGbMMDevice device;
        if (enumerator.GetDefaultAudioEndpoint(flow, role, out device) != 0 || device == null) return null;
        try { string id; device.GetId(out id); return id; }
        finally { Marshal.ReleaseComObject(device); }
    }

    static void ReadProperties(IGbMMDevice device, GameBoostAudioDevice info) {
        IGbPropertyStore store;
        if (device.OpenPropertyStore(0, out store) != 0 || store == null) return;
        try {
            info.Name = ReadString(store, DeviceFormatId, 14);
            info.Description = ReadString(store, DeviceFormatId, 2);
            info.Enumerator = ReadString(store, DeviceFormatId, 24);
            info.Adapter = ReadString(store, InterfaceFormatId, 2);
            uint formFactor;
            if (ReadUInt(store, FormFactorId, 0, out formFactor)) info.FormFactor = (int)formFactor;
            var key = NewKey(EngineFormatId, 0);
            GbPropVariant value;
            if (store.GetValue(ref key, out value) == 0) {
                try {
                    if (value.Type == 65 && value.BlobSize >= 16 && value.BlobData != IntPtr.Zero) {
                        int tag = (ushort)Marshal.ReadInt16(value.BlobData, 0);
                        info.Channels = (ushort)Marshal.ReadInt16(value.BlobData, 2);
                        info.SampleRate = Marshal.ReadInt32(value.BlobData, 4);
                        info.Bits = (ushort)Marshal.ReadInt16(value.BlobData, 14);
                        if (tag == 0xFFFE && value.BlobSize >= 20) {
                            int valid = (ushort)Marshal.ReadInt16(value.BlobData, 18);
                            if (valid > 0) info.Bits = valid;
                        }
                    }
                } finally { PropVariantClear(ref value); }
            }
        } finally { Marshal.ReleaseComObject(store); }
    }

    static void ReadVolume(IGbMMDevice device, GameBoostAudioDevice info) {
        try {
            Guid iid = typeof(IGbAudioEndpointVolume).GUID;
            object instance;
            if (device.Activate(ref iid, 23, IntPtr.Zero, out instance) != 0 || instance == null) return;
            var volume = (IGbAudioEndpointVolume)instance;
            try {
                float level;
                if (volume.GetMasterVolumeLevelScalar(out level) == 0) info.Volume = level;
                bool muted;
                if (volume.GetMute(out muted) == 0) info.Muted = muted;
            } finally { Marshal.ReleaseComObject(volume); }
        } catch { }
    }

    // Sets a capture or render endpoint's level (0..1). Returns the previous level, -1 on failure.
    public static double SetEndpointVolume(string deviceId, double level) {
        IGbMMDeviceEnumerator enumerator = null;
        IGbMMDevice device = null;
        try {
            enumerator = (IGbMMDeviceEnumerator)new GbMMDeviceEnumeratorCom();
            if (enumerator.GetDevice(deviceId, out device) != 0 || device == null) return -1;
            Guid iid = typeof(IGbAudioEndpointVolume).GUID;
            object instance;
            if (device.Activate(ref iid, 23, IntPtr.Zero, out instance) != 0 || instance == null) return -1;
            var volume = (IGbAudioEndpointVolume)instance;
            try {
                float previous;
                if (volume.GetMasterVolumeLevelScalar(out previous) != 0) return -1;
                Guid context = Guid.Empty;
                if (volume.SetMasterVolumeLevelScalar((float)Math.Max(0, Math.Min(1, level)), ref context) != 0) return -1;
                return previous;
            } finally { Marshal.ReleaseComObject(volume); }
        } catch { return -1; }
        finally {
            if (device != null) Marshal.ReleaseComObject(device);
            if (enumerator != null) Marshal.ReleaseComObject(enumerator);
        }
    }

    static GbPropertyKey NewKey(Guid formatId, int propertyId) {
        var key = new GbPropertyKey();
        key.FormatId = formatId;
        key.PropertyId = propertyId;
        return key;
    }

    static string ReadString(IGbPropertyStore store, Guid formatId, int propertyId) {
        var key = NewKey(formatId, propertyId);
        GbPropVariant value;
        if (store.GetValue(ref key, out value) != 0) return null;
        try { return value.Type == 31 && value.Pointer != IntPtr.Zero ? Marshal.PtrToStringUni(value.Pointer) : null; }
        finally { PropVariantClear(ref value); }
    }

    static bool ReadUInt(IGbPropertyStore store, Guid formatId, int propertyId, out uint result) {
        result = 0;
        var key = NewKey(formatId, propertyId);
        GbPropVariant value;
        if (store.GetValue(ref key, out value) != 0) return false;
        try {
            if (value.Type != 19) return false;
            result = value.UInt;
            return true;
        } finally { PropVariantClear(ref value); }
    }
}

// Records a few seconds from the default microphone (classic waveIn, 48 kHz mono 16-bit) and
// reports levels in dBFS. Nothing is saved; the samples are dropped after measuring.
public sealed class GameBoostMicTest {
    [StructLayout(LayoutKind.Sequential)]
    struct WaveFormat { public ushort Tag; public ushort Channels; public uint SamplesPerSec; public uint AvgBytesPerSec; public ushort BlockAlign; public ushort BitsPerSample; public ushort Size; }
    [StructLayout(LayoutKind.Sequential)]
    struct WaveHeader { public IntPtr Data; public uint BufferLength; public uint BytesRecorded; public IntPtr User; public uint Flags; public uint Loops; public IntPtr Next; public IntPtr Reserved; }
    [DllImport("winmm.dll")] static extern int waveInOpen(out IntPtr handle, int deviceId, ref WaveFormat format, IntPtr callback, IntPtr instance, int flags);
    [DllImport("winmm.dll")] static extern int waveInPrepareHeader(IntPtr handle, IntPtr header, int size);
    [DllImport("winmm.dll")] static extern int waveInUnprepareHeader(IntPtr handle, IntPtr header, int size);
    [DllImport("winmm.dll")] static extern int waveInAddBuffer(IntPtr handle, IntPtr header, int size);
    [DllImport("winmm.dll")] static extern int waveInStart(IntPtr handle);
    [DllImport("winmm.dll")] static extern int waveInStop(IntPtr handle);
    [DllImport("winmm.dll")] static extern int waveInReset(IntPtr handle);
    [DllImport("winmm.dll")] static extern int waveInClose(IntPtr handle);

    volatile bool done;
    public bool Done { get { return done; } }
    public string Error;
    public bool Silent;
    public double PeakDb = -120;
    public double SpeechDb = -120;
    public double NoiseDb = -120;

    public void Start(int seconds) {
        var thread = new Thread(delegate() { Run(seconds); });
        thread.IsBackground = true;
        thread.Start();
    }

    static double ToDb(double value) { return value > 0 ? Math.Round(20 * Math.Log10(value), 1) : -120; }

    void Run(int seconds) {
        const int rate = 48000;
        const int chunkMs = 250;
        int chunks = seconds * 1000 / chunkMs;
        int chunkBytes = rate * 2 * chunkMs / 1000;
        int headerSize = Marshal.SizeOf(typeof(WaveHeader));
        var headers = new IntPtr[chunks];
        var buffers = new IntPtr[chunks];
        IntPtr handle = IntPtr.Zero;
        try {
            var format = new WaveFormat();
            format.Tag = 1; format.Channels = 1; format.SamplesPerSec = rate; format.BitsPerSample = 16;
            format.BlockAlign = 2; format.AvgBytesPerSec = rate * 2;
            int opened = waveInOpen(out handle, -1, ref format, IntPtr.Zero, IntPtr.Zero, 0);
            if (opened != 0) { Error = "open " + opened; handle = IntPtr.Zero; return; }
            for (int i = 0; i < chunks; i++) {
                buffers[i] = Marshal.AllocHGlobal(chunkBytes);
                var header = new WaveHeader();
                header.Data = buffers[i];
                header.BufferLength = (uint)chunkBytes;
                headers[i] = Marshal.AllocHGlobal(headerSize);
                Marshal.StructureToPtr(header, headers[i], false);
                waveInPrepareHeader(handle, headers[i], headerSize);
                waveInAddBuffer(handle, headers[i], headerSize);
            }
            waveInStart(handle);
            Thread.Sleep(seconds * 1000 + 400);
            waveInStop(handle);
            waveInReset(handle);

            var levels = new List<double>();
            double peak = 0;
            long nonZero = 0;
            var samples = new short[chunkBytes / 2];
            for (int i = 0; i < chunks; i++) {
                var header = (WaveHeader)Marshal.PtrToStructure(headers[i], typeof(WaveHeader));
                int count = (int)header.BytesRecorded / 2;
                if (count <= 0) continue;
                Marshal.Copy(buffers[i], samples, 0, count);
                double squares = 0;
                for (int s = 0; s < count; s++) {
                    double x = samples[s] / 32768.0;
                    squares += x * x;
                    if (Math.Abs(x) > peak) peak = Math.Abs(x);
                    if (samples[s] != 0) nonZero++;
                }
                levels.Add(Math.Sqrt(squares / count));
            }
            if (levels.Count == 0) { Error = "nodata"; return; }
            Silent = nonZero == 0;
            levels.Sort();
            PeakDb = ToDb(peak);
            SpeechDb = ToDb(levels[(int)(levels.Count * 0.8)]);   // the louder part: speech
            NoiseDb = ToDb(levels[(int)(levels.Count * 0.1)]);    // the quieter part: room / fan noise
        } catch (Exception e) { Error = e.Message; }
        finally {
            for (int i = 0; i < chunks; i++) {
                if (headers[i] != IntPtr.Zero) {
                    if (handle != IntPtr.Zero) waveInUnprepareHeader(handle, headers[i], headerSize);
                    Marshal.FreeHGlobal(headers[i]);
                }
                if (buffers[i] != IntPtr.Zero) Marshal.FreeHGlobal(buffers[i]);
            }
            if (handle != IntPtr.Zero) waveInClose(handle);
            done = true;
        }
    }
}

// ---------------------------------------------------------------- power settings, network

public static class GameBoostPower {
    [DllImport("powrprof.dll")] static extern uint PowerGetActiveScheme(IntPtr root, out IntPtr scheme);
    [DllImport("powrprof.dll")] static extern uint PowerReadACValueIndex(IntPtr root, ref Guid scheme, ref Guid subgroup, ref Guid setting, out uint value);
    [DllImport("powrprof.dll")] static extern uint PowerReadDCValueIndex(IntPtr root, ref Guid scheme, ref Guid subgroup, ref Guid setting, out uint value);
    [DllImport("powrprof.dll")] static extern uint PowerSetActiveScheme(IntPtr root, ref Guid scheme);
    [DllImport("powrprof.dll")] static extern uint PowerWriteACValueIndex(IntPtr root, ref Guid scheme, ref Guid subgroup, ref Guid setting, uint value);
    [DllImport("powrprof.dll")] static extern uint PowerWriteDCValueIndex(IntPtr root, ref Guid scheme, ref Guid subgroup, ref Guid setting, uint value);
    [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr memory);

    // Writes a setting of a power plan (allowed for this user, like the Control Panel).
    // Changes to the active plan take effect after ApplyActive().
    public static bool WriteValue(string schemeId, string subgroup, string setting, bool pluggedIn, int value) {
        try {
            Guid scheme = new Guid(schemeId);
            Guid group = new Guid(subgroup);
            Guid item = new Guid(setting);
            uint status = pluggedIn
                ? PowerWriteACValueIndex(IntPtr.Zero, ref scheme, ref group, ref item, (uint)value)
                : PowerWriteDCValueIndex(IntPtr.Zero, ref scheme, ref group, ref item, (uint)value);
            return status == 0;
        } catch { return false; }
    }

    public static bool ApplyActive() {
        string scheme = ActiveScheme();
        return scheme != null && SetActiveScheme(scheme);
    }

    public static string ActiveScheme() {
        IntPtr schemePointer;
        if (PowerGetActiveScheme(IntPtr.Zero, out schemePointer) != 0) return null;
        try { return ((Guid)Marshal.PtrToStructure(schemePointer, typeof(Guid))).ToString(); }
        finally { LocalFree(schemePointer); }
    }

    public static bool SetActiveScheme(string scheme) {
        Guid guid;
        try { guid = new Guid(scheme); } catch { return false; }
        return PowerSetActiveScheme(IntPtr.Zero, ref guid) == 0;
    }

    // Reads a setting of the active power plan. Returns -1 when Windows does not expose it.
    public static int ReadActiveValue(string subgroup, string setting, bool pluggedIn) {
        string scheme = ActiveScheme();
        return scheme == null ? -1 : ReadValue(scheme, subgroup, setting, pluggedIn);
    }

    // Reads a setting of a given power plan.
    public static int ReadValue(string schemeId, string subgroup, string setting, bool pluggedIn) {
        try {
            Guid scheme = new Guid(schemeId);
            Guid group = new Guid(subgroup);
            Guid item = new Guid(setting);
            uint value;
            uint status = pluggedIn
                ? PowerReadACValueIndex(IntPtr.Zero, ref scheme, ref group, ref item, out value)
                : PowerReadDCValueIndex(IntPtr.Zero, ref scheme, ref group, ref item, out value);
            return status == 0 ? (int)value : -1;
        } catch { return -1; }
    }
}

public sealed class GameBoostPingTest {
    volatile bool done;
    double[][] results;
    public bool Done { get { return done; } }
    // Per host: { average ms, minimum, maximum, jitter, loss % }. Average is -1 when nothing answered.
    public double[][] Results { get { return results; } }

    public void Start(string[] hosts, int count, int timeoutMs) {
        results = new double[hosts.Length][];
        var thread = new Thread(delegate() {
            var workers = new Thread[hosts.Length];
            for (int i = 0; i < hosts.Length; i++) {
                int index = i;
                workers[i] = new Thread(delegate() { results[index] = Measure(hosts[index], count, timeoutMs); });
                workers[i].IsBackground = true;
                workers[i].Start();
            }
            foreach (Thread worker in workers) worker.Join();
            done = true;
        });
        thread.IsBackground = true;
        thread.Start();
    }

    static double[] Measure(string host, int count, int timeoutMs) {
        var times = new List<double>();
        int lost = 0;
        using (var ping = new Ping()) {
            for (int i = 0; i < count; i++) {
                try {
                    PingReply reply = ping.Send(host, timeoutMs);
                    if (reply != null && reply.Status == IPStatus.Success) times.Add(reply.RoundtripTime); else lost++;
                } catch { lost++; }
                if (i < count - 1) Thread.Sleep(120);
            }
        }
        if (times.Count == 0) return new double[] { -1, 0, 0, 0, 100 };
        double sum = 0, min = double.MaxValue, max = 0, jitter = 0;
        for (int i = 0; i < times.Count; i++) {
            sum += times[i];
            min = Math.Min(min, times[i]);
            max = Math.Max(max, times[i]);
            if (i > 0) jitter += Math.Abs(times[i] - times[i - 1]);
        }
        return new double[] {
            Math.Round(sum / times.Count, 1), min, max,
            times.Count > 1 ? Math.Round(jitter / (times.Count - 1), 1) : 0,
            Math.Round(100.0 * lost / count)
        };
    }
}

// ---------------------------------------------------------------- game session telemetry

// Helper processes die with GameBoost, even if GameBoost itself is killed.
public static class GameBoostProcessJob {
    [StructLayout(LayoutKind.Sequential)]
    struct BasicLimits {
        public long PerProcessUserTimeLimit; public long PerJobUserTimeLimit; public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize; public UIntPtr MaximumWorkingSetSize; public uint ActiveProcessLimit;
        public UIntPtr Affinity; public uint PriorityClass; public uint SchedulingClass;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct IoCounters { public ulong Read, Write, Other, ReadBytes, WriteBytes, OtherBytes; }
    [StructLayout(LayoutKind.Sequential)]
    struct ExtendedLimits {
        public BasicLimits Basic; public IoCounters Io; public UIntPtr ProcessMemoryLimit; public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed; public UIntPtr PeakJobMemoryUsed;
    }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr CreateJobObject(IntPtr attributes, string name);
    [DllImport("kernel32.dll")] static extern bool SetInformationJobObject(IntPtr job, int infoClass, ref ExtendedLimits info, uint size);
    [DllImport("kernel32.dll")] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    static IntPtr job = IntPtr.Zero;

    public static void Assign(Process process) {
        try {
            if (job == IntPtr.Zero) {
                job = CreateJobObject(IntPtr.Zero, null);
                var limits = new ExtendedLimits();
                limits.Basic.LimitFlags = 0x2000;
                SetInformationJobObject(job, 9, ref limits, (uint)Marshal.SizeOf(typeof(ExtendedLimits)));
            }
            AssignProcessToJobObject(job, process.Handle);
        } catch { }
    }
}

// One long-running console tool (nvidia-smi -lms) instead of a new process per reading.
public sealed class GameBoostLineReader {
    Process process;
    volatile string lastLine;
    int lineCount;
    public string LastLine { get { return lastLine; } }
    public int LineCount { get { return Thread.VolatileRead(ref lineCount); } }

    public bool Start(string path, string arguments) {
        try {
            var info = new ProcessStartInfo(path, arguments);
            info.UseShellExecute = false;
            info.CreateNoWindow = true;
            info.RedirectStandardOutput = true;
            process = new Process();
            process.StartInfo = info;
            process.OutputDataReceived += delegate(object sender, DataReceivedEventArgs e) {
                if (string.IsNullOrEmpty(e.Data) || e.Data.IndexOf(',') < 0) return;
                lastLine = e.Data;
                Interlocked.Increment(ref lineCount);
            };
            process.Start();
            GameBoostProcessJob.Assign(process);
            process.BeginOutputReadLine();
            return true;
        } catch { Stop(); return false; }
    }

    public void Stop() {
        if (process == null) return;
        try { if (!process.HasExited) process.Kill(); } catch { }
        try { process.Dispose(); } catch { }
        process = null;
    }
}

// Pings the router every few seconds on a background thread; Wi-Fi spikes show up here first.
public sealed class GameBoostPingMonitor {
    readonly object sync = new object();
    readonly List<double> times = new List<double>();
    int sent, lost;
    volatile bool stopped;

    public void Start(string host, int intervalMs, int timeoutMs) {
        var thread = new Thread(delegate() {
            using (var ping = new Ping()) {
                while (!stopped) {
                    try {
                        PingReply reply = ping.Send(host, timeoutMs);
                        lock (sync) {
                            sent++;
                            if (reply != null && reply.Status == IPStatus.Success) { if (times.Count < 5000) times.Add(reply.RoundtripTime); }
                            else lost++;
                        }
                    } catch { lock (sync) { sent++; lost++; } }
                    for (int waited = 0; waited < intervalMs && !stopped; waited += 250) Thread.Sleep(250);
                }
            }
        });
        thread.IsBackground = true;
        thread.Priority = ThreadPriority.BelowNormal;
        thread.Start();
    }

    public void Stop() { stopped = true; }

    // { sent, lost, average ms, maximum ms, replies at or above spikeMs }
    public double[] Stats(double spikeMs) {
        lock (sync) {
            double sum = 0, max = 0; int spikes = 0;
            foreach (double time in times) { sum += time; if (time > max) max = time; if (time >= spikeMs) spikes++; }
            return new double[] { sent, lost, times.Count > 0 ? Math.Round(sum / times.Count, 1) : -1, max, spikes };
        }
    }
}

public sealed class GameBoostAdapter {
    public string Name;
    public uint VendorId;
    public string LuidKey;
    public long DedicatedBytes;
}

[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
struct GbAdapterDesc1 {
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string Description;
    public uint VendorId, DeviceId, SubSysId, Revision;
    public UIntPtr DedicatedVideoMemory, DedicatedSystemMemory, SharedSystemMemory;
    public uint LuidLow; public int LuidHigh;
    public uint Flags;
}

[ComImport, Guid("29038f61-3839-4626-91fd-086879011a05"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IGbDxgiAdapter1 {
    [PreserveSig] int SetPrivateData(ref Guid name, uint size, IntPtr data);
    [PreserveSig] int SetPrivateDataInterface(ref Guid name, IntPtr unknown);
    [PreserveSig] int GetPrivateData(ref Guid name, ref uint size, IntPtr data);
    [PreserveSig] int GetParent(ref Guid riid, out IntPtr parent);
    [PreserveSig] int EnumOutputs(uint index, out IntPtr output);
    [PreserveSig] int GetDesc(IntPtr desc);
    [PreserveSig] int CheckInterfaceSupport(ref Guid name, out long version);
    [PreserveSig] int GetDesc1(out GbAdapterDesc1 desc);
}

[ComImport, Guid("770aae78-f26f-4dba-a829-253c83d1b387"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IGbDxgiFactory1 {
    [PreserveSig] int SetPrivateData(ref Guid name, uint size, IntPtr data);
    [PreserveSig] int SetPrivateDataInterface(ref Guid name, IntPtr unknown);
    [PreserveSig] int GetPrivateData(ref Guid name, ref uint size, IntPtr data);
    [PreserveSig] int GetParent(ref Guid riid, out IntPtr parent);
    [PreserveSig] int EnumAdapters(uint index, out IntPtr adapter);
    [PreserveSig] int MakeWindowAssociation(IntPtr window, uint flags);
    [PreserveSig] int GetWindowAssociation(out IntPtr window);
    [PreserveSig] int CreateSwapChain(IntPtr device, IntPtr desc, out IntPtr swapChain);
    [PreserveSig] int CreateSoftwareAdapter(IntPtr module, out IntPtr adapter);
    [PreserveSig] int EnumAdapters1(uint index, out IGbDxgiAdapter1 adapter);
    [PreserveSig] bool IsCurrent();
}

public static class GameBoostGpuInfo {
    [DllImport("dxgi.dll")] static extern int CreateDXGIFactory1(ref Guid riid, out IGbDxgiFactory1 factory);

    public static string LuidKey(uint low, int high) { return string.Format("0x{0:x8}_0x{1:x8}", high, low); }

    // Counter instances look like pid_1234_luid_0x00000000_0x00018d13_phys_0_eng_0_engtype_3D.
    public static string LuidKeyFromInstance(string instance) {
        int index = instance.IndexOf("luid_", StringComparison.OrdinalIgnoreCase);
        return index < 0 || instance.Length < index + 26 ? "" : instance.Substring(index + 5, 21).ToLowerInvariant();
    }

    public static List<GameBoostAdapter> Adapters() {
        var result = new List<GameBoostAdapter>();
        IGbDxgiFactory1 factory = null;
        try {
            Guid iid = typeof(IGbDxgiFactory1).GUID;
            if (CreateDXGIFactory1(ref iid, out factory) != 0 || factory == null) return result;
            for (uint index = 0; index < 16; index++) {
                IGbDxgiAdapter1 adapter;
                if (factory.EnumAdapters1(index, out adapter) != 0 || adapter == null) break;
                try {
                    GbAdapterDesc1 desc;
                    if (adapter.GetDesc1(out desc) != 0 || (desc.Flags & 2) != 0) continue;   // skip software adapters
                    var item = new GameBoostAdapter();
                    item.Name = desc.Description;
                    item.VendorId = desc.VendorId;
                    item.LuidKey = LuidKey(desc.LuidLow, desc.LuidHigh);
                    item.DedicatedBytes = (long)desc.DedicatedVideoMemory.ToUInt64();
                    result.Add(item);
                } finally { Marshal.ReleaseComObject(adapter); }
            }
        } catch { }
        finally { if (factory != null) Marshal.ReleaseComObject(factory); }
        return result;
    }
}

// One-off check on a background thread: which GPU does the game draw with, and how much of
// that GPU's memory the game itself holds (not the whole card).
public sealed class GameBoostGpuPlacementCheck {
    volatile bool done;
    public bool Done { get { return done; } }
    public string Error;
    public string AdapterName;
    public uint VendorId;
    public double Utilization;
    public double OtherUtilization;
    public long GameDedicatedBytes = -1;

    public void Start(int processId) {
        var thread = new Thread(delegate() { Run(processId); });
        thread.IsBackground = true;
        thread.Priority = ThreadPriority.BelowNormal;
        thread.Start();
    }

    void Run(int processId) {
        var counters = new List<KeyValuePair<string, PerformanceCounter>>();
        try {
            string marker = "pid_" + processId + "_";
            foreach (string instance in new PerformanceCounterCategory("GPU Engine").GetInstanceNames()) {
                if (!instance.StartsWith(marker, StringComparison.OrdinalIgnoreCase)) continue;
                if (!instance.EndsWith("engtype_3D", StringComparison.OrdinalIgnoreCase)) continue;
                counters.Add(new KeyValuePair<string, PerformanceCounter>(GameBoostGpuInfo.LuidKeyFromInstance(instance),
                    new PerformanceCounter("GPU Engine", "Utilization Percentage", instance, true)));
            }
            if (counters.Count == 0) { Error = "nodata"; return; }
            foreach (var counter in counters) counter.Value.NextValue();
            Thread.Sleep(1500);
            var usage = new Dictionary<string, double>();
            foreach (var counter in counters) {
                double value = counter.Value.NextValue();
                double existing;
                usage.TryGetValue(counter.Key, out existing);
                usage[counter.Key] = existing + value;
            }
            string best = null;
            foreach (var pair in usage) if (best == null || pair.Value > usage[best]) best = pair.Key;
            Utilization = Math.Round(usage[best], 1);
            foreach (var pair in usage) if (pair.Key != best) OtherUtilization = Math.Max(OtherUtilization, Math.Round(pair.Value, 1));
            foreach (GameBoostAdapter adapter in GameBoostGpuInfo.Adapters()) {
                if (adapter.LuidKey == best) { AdapterName = adapter.Name; VendorId = adapter.VendorId; }
            }
            long dedicated = 0;
            bool found = false;
            foreach (string instance in new PerformanceCounterCategory("GPU Process Memory").GetInstanceNames()) {
                if (!instance.StartsWith(marker, StringComparison.OrdinalIgnoreCase) || GameBoostGpuInfo.LuidKeyFromInstance(instance) != best) continue;
                using (var counter = new PerformanceCounter("GPU Process Memory", "Dedicated Usage", instance, true)) { dedicated += counter.RawValue; found = true; }
            }
            if (found) GameDedicatedBytes = dedicated;
        } catch (Exception e) { Error = e.Message; }
        finally {
            foreach (var counter in counters) { try { counter.Value.Dispose(); } catch { } }
            done = true;
        }
    }
}

// Which processes hold memory on one graphics card (they keep a laptop's NVIDIA card awake).
// Listing the counters takes a few seconds, so it runs on its own thread.
public sealed class GameBoostGpuUsers {
    volatile bool done;
    public bool Done { get { return done; } }
    public string Error;
    public List<int> Ids = new List<int>();
    public List<long> Bytes = new List<long>();

    public void Start(string luidKey) {
        var thread = new Thread(delegate() { Run(luidKey); });
        thread.IsBackground = true;
        thread.Priority = ThreadPriority.BelowNormal;
        thread.Start();
    }

    void Run(string luidKey) {
        try {
            var totals = new Dictionary<int, long>();
            foreach (string instance in new PerformanceCounterCategory("GPU Process Memory").GetInstanceNames()) {
                if (GameBoostGpuInfo.LuidKeyFromInstance(instance) != luidKey) continue;
                if (!instance.StartsWith("pid_", StringComparison.OrdinalIgnoreCase)) continue;
                int end = instance.IndexOf('_', 4);
                int id;
                if (end < 0 || !int.TryParse(instance.Substring(4, end - 4), out id) || id <= 0) continue;
                long value;
                using (var counter = new PerformanceCounter("GPU Process Memory", "Dedicated Usage", instance, true)) value = counter.RawValue;
                if (value <= 0) continue;
                long existing;
                totals.TryGetValue(id, out existing);
                totals[id] = existing + value;
            }
            foreach (var pair in totals) { Ids.Add(pair.Key); Bytes.Add(pair.Value); }
        } catch (Exception e) { Error = e.Message; }
        finally { done = true; }
    }
}

// Open internet connections per process (no admin needed). Not bytes, but a good hint at who downloads.
public static class GameBoostConnections {
    [DllImport("iphlpapi.dll")] static extern uint GetExtendedTcpTable(IntPtr table, ref int size, bool sort, int family, int tableClass, uint reserved);

    public static Dictionary<int, int> CountByProcess() {
        var counts = new Dictionary<int, int>();
        Read(2, 24, counts);
        Read(23, 56, counts);
        return counts;
    }

    // family 2 = IPv4 (row: state, local addr, local port, remote addr, remote port, pid),
    // 23 = IPv6 (row: local addr[16], scope, port, remote addr[16], scope, port, state, pid).
    static void Read(int family, int rowSize, Dictionary<int, int> counts) {
        int size = 0;
        GetExtendedTcpTable(IntPtr.Zero, ref size, false, family, 4, 0);
        if (size <= 0) return;
        IntPtr table = Marshal.AllocHGlobal(size);
        try {
            if (GetExtendedTcpTable(table, ref size, false, family, 4, 0) != 0) return;
            int entries = Marshal.ReadInt32(table);
            for (int i = 0; i < entries; i++) {
                IntPtr row = IntPtr.Add(table, 4 + i * rowSize);
                int state, pid;
                bool loopback;
                if (family == 2) {
                    state = Marshal.ReadInt32(row, 0);
                    loopback = Marshal.ReadByte(row, 12) == 127;
                    pid = Marshal.ReadInt32(row, 20);
                } else {
                    state = Marshal.ReadInt32(row, 48);
                    pid = Marshal.ReadInt32(row, 52);
                    loopback = true;
                    for (int b = 0; b < 15; b++) if (Marshal.ReadByte(row, 24 + b) != 0) { loopback = false; break; }
                    if (loopback && Marshal.ReadByte(row, 39) != 1) loopback = false;
                }
                if (state != 5 || loopback || pid <= 4) continue;
                int count;
                counts.TryGetValue(pid, out count);
                counts[pid] = count + 1;
            }
        } finally { Marshal.FreeHGlobal(table); }
    }
}

// ---------------------------------------------------------------- keep awake, quiet time, energy saver

public static class GameBoostSystemState {
    [DllImport("kernel32.dll")] static extern uint SetThreadExecutionState(uint flags);
    [DllImport("shell32.dll")] static extern int SHQueryUserNotificationState(out int state);
    [StructLayout(LayoutKind.Sequential)]
    struct PowerStatus { public byte AcLine; public byte BatteryFlag; public byte BatteryPercent; public byte SystemStatusFlag; public int LifeTime; public int FullLifeTime; }
    [DllImport("kernel32.dll")] static extern bool GetSystemPowerStatus(out PowerStatus status);

    // Keeps the PC from sleeping; the screen may still turn off. Windows ties the request to the
    // calling thread (the UI thread here) and drops it when the app ends.
    public static bool KeepAwake(bool on) {
        const uint Continuous = 0x80000000, SystemRequired = 0x00000001;
        return SetThreadExecutionState(on ? (Continuous | SystemRequired) : Continuous) != 0;
    }

    // 5: notifications welcome. 2 busy, 3 full-screen game, 4 presentation, 6 Focus / quiet hours, 7 full-screen app.
    public static int NotificationState() {
        int state;
        return SHQueryUserNotificationState(out state) == 0 ? state : 0;
    }

    public static bool EnergySaverOn() {
        PowerStatus status;
        return GetSystemPowerStatus(out status) && status.SystemStatusFlag == 1;
    }
}

// ---------------------------------------------------------------- internet speed test

// Latency, download and upload against Cloudflare's public speed test, several connections at once,
// capped in time and data. Runs on its own threads; the UI reads Phase / LiveMbps / results.
public sealed class GameBoostSpeedTest {
    public string BaseUrl = "https://speed.cloudflare.com";
    public int Streams = 4;
    public double DownSeconds = 8, UpSeconds = 6;
    public long DownCapBytes = 300000000, UpCapBytes = 60000000;
    const int UploadChunk = 4000000;

    volatile bool done, cancel, stopPhase;
    public bool Done { get { return done; } }
    public volatile string Phase = "";
    public string Error, Server;
    public double PingMs = -1, JitterMs = -1, DownMbps = -1, UpMbps = -1, LiveMbps;
    public long BytesUsed;
    long phaseBytes, phaseCap;
    readonly List<HttpWebRequest> active = new List<HttpWebRequest>();
    readonly byte[] payload = new byte[65536];

    public void Start() {
        new Random().NextBytes(payload);
        var thread = new Thread(Run);
        thread.IsBackground = true;
        thread.Start();
    }

    public void Cancel() { cancel = true; stopPhase = true; AbortAll(); }

    void Run() {
        try {
            ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
            ServicePoint point = ServicePointManager.FindServicePoint(new Uri(BaseUrl));
            point.ConnectionLimit = Math.Max(point.ConnectionLimit, Streams * 2 + 2);
            Phase = "ping";
            MeasureLatency();
            if (!cancel) { Phase = "down"; DownMbps = Transfer(true); }
            if (!cancel) { Phase = "up"; UpMbps = Transfer(false); }
            if (cancel && Error == null) Error = "cancelled";
        } catch (Exception e) { Error = e.Message; }
        finally { AbortAll(); Phase = "done"; done = true; }
    }

    HttpWebRequest NewRequest(string path, string method) {
        var request = (HttpWebRequest)WebRequest.Create(BaseUrl + path);
        request.Method = method;
        request.Timeout = 10000;
        request.ReadWriteTimeout = 10000;
        request.KeepAlive = true;
        request.UserAgent = "GameBoostLite";
        lock (active) active.Add(request);
        return request;
    }

    void Forget(HttpWebRequest request) { lock (active) active.Remove(request); }

    void AbortAll() {
        lock (active) {
            foreach (HttpWebRequest request in active) { try { request.Abort(); } catch { } }
            active.Clear();
        }
    }

    static double ServerMilliseconds(string timing) {
        if (string.IsNullOrEmpty(timing)) return 0;
        int index = timing.IndexOf("dur=", StringComparison.OrdinalIgnoreCase);
        if (index < 0) return 0;
        int end = index + 4;
        while (end < timing.Length && (char.IsDigit(timing[end]) || timing[end] == '.')) end++;
        double value;
        return double.TryParse(timing.Substring(index + 4, end - index - 4), System.Globalization.NumberStyles.Float,
            System.Globalization.CultureInfo.InvariantCulture, out value) ? value : 0;
    }

    // Cloudflare's data center: "cf-meta-colo", or the end of "cf-ray" (8f3a...-IST).
    static string Colo(WebHeaderCollection headers) {
        string colo = headers["cf-meta-colo"];
        if (!string.IsNullOrEmpty(colo)) return colo;
        string ray = headers["cf-ray"];
        int dash = ray == null ? -1 : ray.LastIndexOf('-');
        return dash > 0 && dash < ray.Length - 1 ? ray.Substring(dash + 1) : null;
    }

    // Round trips of tiny requests on one kept-alive connection; the first (TLS handshake) is dropped.
    void MeasureLatency() {
        var samples = new List<double>();
        for (int i = 0; i < 7 && !cancel; i++) {
            HttpWebRequest request = NewRequest("/__down?bytes=0", "GET");
            try {
                var watch = Stopwatch.StartNew();
                using (var response = (HttpWebResponse)request.GetResponse()) {
                    double ms = watch.Elapsed.TotalMilliseconds - ServerMilliseconds(response.Headers["server-timing"]);
                    if (Server == null) Server = Colo(response.Headers);
                    if (i > 0) samples.Add(Math.Max(0.1, ms));
                }
            } finally { Forget(request); }
        }
        if (samples.Count == 0) return;
        var sorted = new List<double>(samples);
        sorted.Sort();
        PingMs = Math.Round(sorted[sorted.Count / 2], 1);
        double jitter = 0;
        for (int i = 1; i < samples.Count; i++) jitter += Math.Abs(samples[i] - samples[i - 1]);
        JitterMs = samples.Count > 1 ? Math.Round(jitter / (samples.Count - 1), 1) : 0;
    }

    // Mbps after a one second warm-up (from the start if the data cap came first), or -1 when nothing moved.
    double Transfer(bool download) {
        long cap = download ? DownCapBytes : UpCapBytes;
        double seconds = download ? DownSeconds : UpSeconds;
        Interlocked.Exchange(ref phaseCap, cap);
        Interlocked.Exchange(ref phaseBytes, 0);
        stopPhase = false;
        var threads = new List<Thread>();
        for (int i = 0; i < Streams; i++) {
            var thread = new Thread(delegate() { Pump(download); });
            thread.IsBackground = true;
            thread.Start();
            threads.Add(thread);
        }
        var watch = Stopwatch.StartNew();
        long warmBytes = -1, lastBytes = 0, total = 0;
        double warmAt = 0, lastAt = 0, end = 0;
        while (!cancel) {
            Thread.Sleep(200);
            end = watch.Elapsed.TotalSeconds;
            total = Interlocked.Read(ref phaseBytes);
            if (warmBytes < 0 && end >= 1.0) { warmBytes = total; warmAt = end; }
            if (end - lastAt >= 0.5) {
                LiveMbps = Math.Round((total - lastBytes) * 8 / (end - lastAt) / 1e6, 1);
                lastBytes = total;
                lastAt = end;
            }
            if (end >= seconds || total >= cap || stopPhase) break;
        }
        end = watch.Elapsed.TotalSeconds;
        total = Interlocked.Read(ref phaseBytes);
        stopPhase = true;
        AbortAll();
        foreach (Thread thread in threads) thread.Join(3000);
        BytesUsed += Interlocked.Read(ref phaseBytes);
        LiveMbps = 0;
        if (warmBytes >= 0 && end - warmAt >= 0.5 && total > warmBytes) return Math.Round((total - warmBytes) * 8 / (end - warmAt) / 1e6, 1);
        if (end >= 0.2 && total > 0) return Math.Round(total * 8 / end / 1e6, 1);
        return -1;
    }

    // Counts bytes; the stream that reaches the data cap ends the phase for all.
    void Count(int bytes) {
        if (Interlocked.Add(ref phaseBytes, bytes) >= Interlocked.Read(ref phaseCap)) stopPhase = true;
    }

    void Pump(bool download) {
        var buffer = new byte[65536];
        int failures = 0;
        while (!stopPhase && !cancel && failures < 3) {
            HttpWebRequest request = null;
            try {
                if (download) {
                    request = NewRequest("/__down?bytes=25000000", "GET");
                    using (WebResponse response = request.GetResponse())
                    using (Stream stream = response.GetResponseStream()) {
                        int read;
                        while (!stopPhase && (read = stream.Read(buffer, 0, buffer.Length)) > 0) Count(read);
                    }
                } else {
                    request = NewRequest("/__up", "POST");
                    request.ContentType = "application/octet-stream";
                    request.ContentLength = UploadChunk;
                    request.AllowWriteStreamBuffering = false;
                    using (Stream stream = request.GetRequestStream()) {
                        long sent = 0;
                        while (!stopPhase && sent < UploadChunk) {
                            int count = (int)Math.Min(payload.Length, UploadChunk - sent);
                            stream.Write(payload, 0, count);
                            sent += count;
                            Count(count);
                        }
                    }
                    if (!stopPhase) using (request.GetResponse()) { }
                }
            } catch {
                if (stopPhase || cancel) return;
                failures++;
                Thread.Sleep(200);
            } finally { if (request != null) Forget(request); }
        }
    }
}

// ---------------------------------------------------------------- per-user input settings

// Mouse acceleration and the Sticky Keys shortcut, through Windows' own settings call
// (applies at once and is saved for the user, exactly like the Settings app).
public static class GameBoostInputSettings {
    [StructLayout(LayoutKind.Sequential)] struct StickyKeys { public uint Size; public uint Flags; }
    [DllImport("user32.dll", EntryPoint = "SystemParametersInfoW", SetLastError = true)]
    static extern bool SystemParametersInfoArray(uint action, uint param, int[] value, uint update);
    [DllImport("user32.dll", EntryPoint = "SystemParametersInfoW", SetLastError = true)]
    static extern bool SystemParametersInfoSticky(uint action, uint param, ref StickyKeys value, uint update);

    // { threshold 1, threshold 2, acceleration } - acceleration 0 means "Enhance pointer precision" is off.
    public static int[] GetMouse() {
        var values = new int[3];
        return SystemParametersInfoArray(0x0003, 0, values, 0) ? values : null;
    }

    public static bool SetMouse(int threshold1, int threshold2, int acceleration) {
        return SystemParametersInfoArray(0x0004, 0, new int[] { threshold1, threshold2, acceleration }, 3);
    }

    public static int GetStickyFlags() {
        var keys = new StickyKeys();
        keys.Size = (uint)Marshal.SizeOf(typeof(StickyKeys));
        return SystemParametersInfoSticky(0x003A, keys.Size, ref keys, 0) ? (int)keys.Flags : -1;
    }

    public static bool SetStickyFlags(int flags) {
        var keys = new StickyKeys();
        keys.Size = (uint)Marshal.SizeOf(typeof(StickyKeys));
        keys.Flags = (uint)flags;
        return SystemParametersInfoSticky(0x003B, keys.Size, ref keys, 3);
    }
}

// ---------------------------------------------------------------- input devices

public sealed class GameBoostPadInfo {
    public int Slot;
    public bool Wireless;
    public int BatteryType;   // 0 disconnected, 1 wired, 2 alkaline, 3 NiMH, 255 unknown
    public int BatteryLevel;  // 0 empty .. 3 full
}

public static class GameBoostXInput {
    [StructLayout(LayoutKind.Sequential)]
    struct Gamepad { public ushort Buttons; public byte LeftTrigger; public byte RightTrigger; public short ThumbLX; public short ThumbLY; public short ThumbRX; public short ThumbRY; }
    [StructLayout(LayoutKind.Sequential)] struct State { public uint PacketNumber; public Gamepad Pad; }
    [StructLayout(LayoutKind.Sequential)] struct Vibration { public ushort Left; public ushort Right; }
    [StructLayout(LayoutKind.Sequential)] struct Capabilities { public byte Type; public byte SubType; public ushort Flags; public Gamepad Pad; public Vibration Rumble; }
    [StructLayout(LayoutKind.Sequential)] struct Battery { public byte Type; public byte Level; }

    [DllImport("xinput1_4.dll")] static extern int XInputGetState(int user, out State state);
    [DllImport("xinput1_4.dll")] static extern int XInputGetCapabilities(int user, int flags, out Capabilities capabilities);
    [DllImport("xinput1_4.dll")] static extern int XInputGetBatteryInformation(int user, byte deviceType, out Battery battery);

    public static List<GameBoostPadInfo> GetPads() {
        var pads = new List<GameBoostPadInfo>();
        try {
            for (int slot = 0; slot < 4; slot++) {
                State state;
                if (XInputGetState(slot, out state) != 0) continue;
                var info = new GameBoostPadInfo();
                info.Slot = slot + 1;
                Capabilities capabilities;
                if (XInputGetCapabilities(slot, 0, out capabilities) == 0) info.Wireless = (capabilities.Flags & 0x2) != 0;
                Battery battery;
                if (XInputGetBatteryInformation(slot, 0, out battery) == 0) {
                    info.BatteryType = battery.Type;
                    info.BatteryLevel = battery.Level;
                    if (battery.Type >= 2 && battery.Type != 255) info.Wireless = true;
                }
                pads.Add(info);
            }
        } catch { }
        return pads;
    }

    internal static bool TryPacket(int slot, out uint packet) {
        State state;
        packet = 0;
        if (XInputGetState(slot, out state) != 0) return false;
        packet = state.PacketNumber;
        return true;
    }
}

public static class GameBoostRate {
    // Average report rate from arrival times, ignoring pauses longer than 50 ms.
    internal static double ReportRate(List<double> stamps, out int used) {
        double total = 0;
        used = 0;
        for (int i = 1; i < stamps.Count; i++) {
            double gap = stamps[i] - stamps[i - 1];
            if (gap > 0 && gap <= 50) { total += gap; used++; }
        }
        return used > 0 && total > 0 ? Math.Round(1000.0 * used / total) : 0;
    }

    // Stick noise only changes some reports, so gaps are multiples of the polling interval.
    // The short end of the gap distribution is the real interval.
    internal static double PollingRate(List<double> stamps, out int used) {
        var gaps = new List<double>();
        for (int i = 1; i < stamps.Count; i++) {
            double gap = stamps[i] - stamps[i - 1];
            if (gap > 0.2 && gap <= 50) gaps.Add(gap);
        }
        used = gaps.Count;
        if (gaps.Count == 0) return 0;
        gaps.Sort();
        double interval = gaps[gaps.Count / 5];
        return interval > 0 ? Math.Round(1000.0 / interval) : 0;
    }
}

public sealed class GameBoostGamepadRateTest {
    [DllImport("winmm.dll")] static extern uint timeBeginPeriod(uint period);
    [DllImport("winmm.dll")] static extern uint timeEndPeriod(uint period);

    volatile bool done;
    public bool Done { get { return done; } }
    public double Hz;
    public int Reports;
    public string Error;

    public void Start(int slot, int milliseconds) {
        var thread = new Thread(delegate() { Run(slot - 1, milliseconds); });
        thread.IsBackground = true;
        thread.Priority = ThreadPriority.AboveNormal;
        thread.Start();
    }

    void Run(int slot, int milliseconds) {
        timeBeginPeriod(1);
        try {
            var stamps = new List<double>();
            var watch = Stopwatch.StartNew();
            uint last = 0;
            bool first = true;
            while (watch.ElapsedMilliseconds < milliseconds) {
                uint packet;
                if (!GameBoostXInput.TryPacket(slot, out packet)) { Error = "disconnected"; break; }
                if (first) { last = packet; first = false; }
                else if (packet != last) { last = packet; stamps.Add(watch.Elapsed.TotalMilliseconds); }
                Thread.SpinWait(100);
            }
            int used;
            Hz = GameBoostRate.PollingRate(stamps, out used);
            Reports = used;
            if (Error == null && used < 30) Error = "nomotion";
        } catch (Exception e) { Error = e.Message; }
        finally { timeEndPeriod(1); done = true; }
    }
}

public sealed class GameBoostMouseRateTest : NativeWindow {
    [StructLayout(LayoutKind.Sequential)] struct RawInputDevice { public ushort UsagePage; public ushort Usage; public uint Flags; public IntPtr Target; }
    [StructLayout(LayoutKind.Sequential)] struct RawInputHeader { public uint Type; public uint Size; public IntPtr Device; public IntPtr WParam; }
    [DllImport("user32.dll", SetLastError = true)] static extern bool RegisterRawInputDevices(RawInputDevice[] devices, uint count, uint size);
    [DllImport("user32.dll")] static extern uint GetRawInputData(IntPtr rawInput, uint command, out RawInputHeader data, ref uint size, uint headerSize);

    readonly Dictionary<IntPtr, List<double>> stamps = new Dictionary<IntPtr, List<double>>();
    Stopwatch watch;
    System.Windows.Forms.Timer stopTimer;
    volatile bool done;
    public bool Done { get { return done; } }
    public double Hz;
    public int Reports;
    public string Error;

    public void Start(int milliseconds) {
        var parameters = new CreateParams();
        parameters.Parent = new IntPtr(-3);
        CreateHandle(parameters);
        if (!Register(0x100, Handle)) { Error = "register"; done = true; DestroyHandle(); return; }
        watch = Stopwatch.StartNew();
        stopTimer = new System.Windows.Forms.Timer();
        stopTimer.Interval = milliseconds;
        stopTimer.Tick += delegate { Finish(); };
        stopTimer.Start();
    }

    static bool Register(uint flags, IntPtr target) {
        var device = new RawInputDevice();
        device.UsagePage = 1;
        device.Usage = 2;
        device.Flags = flags;
        device.Target = target;
        return RegisterRawInputDevices(new RawInputDevice[] { device }, 1, (uint)Marshal.SizeOf(typeof(RawInputDevice)));
    }

    protected override void WndProc(ref Message message) {
        if (message.Msg == 0x00FF && watch != null && !done) {
            var header = new RawInputHeader();
            uint size = (uint)Marshal.SizeOf(typeof(RawInputHeader));
            if (GetRawInputData(message.LParam, 0x10000005, out header, ref size, size) != uint.MaxValue) {
                List<double> list;
                if (!stamps.TryGetValue(header.Device, out list)) { list = new List<double>(); stamps[header.Device] = list; }
                list.Add(watch.Elapsed.TotalMilliseconds);
            }
        }
        base.WndProc(ref message);
    }

    void Finish() {
        if (done) return;
        stopTimer.Stop();
        stopTimer.Dispose();
        Register(0x1, IntPtr.Zero);
        foreach (List<double> list in stamps.Values) {
            int used;
            double hz = GameBoostRate.ReportRate(list, out used);
            if (used > Reports) { Reports = used; Hz = hz; }
        }
        if (Reports < 30) Error = "nomotion";
        DestroyHandle();
        done = true;
    }
}

// ---------------------------------------------------------------- system

public static class GameBoostSystemInfo {
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetLogicalProcessorInformationEx(int relationship, IntPtr buffer, ref uint length);

    // { performance cores, performance threads, efficient cores, efficient threads }
    public static int[] CoreSummary() {
        var summary = new int[4];
        uint length = 0;
        GetLogicalProcessorInformationEx(0, IntPtr.Zero, ref length);
        if (length == 0) return summary;
        IntPtr buffer = Marshal.AllocHGlobal((int)length);
        try {
            if (!GetLogicalProcessorInformationEx(0, buffer, ref length)) return summary;
            var cores = new List<int[]>();
            int maxClass = 0;
            int offset = 0;
            while (offset < length) {
                IntPtr entry = IntPtr.Add(buffer, offset);
                int size = Marshal.ReadInt32(entry, 4);
                if (size <= 0) break;
                int efficiency = Marshal.ReadByte(entry, 9);
                long mask = Marshal.ReadInt64(entry, 32);
                int threads = 0;
                for (int bit = 0; bit < 64; bit++) if (((mask >> bit) & 1) != 0) threads++;
                cores.Add(new int[] { efficiency, threads });
                maxClass = Math.Max(maxClass, efficiency);
                offset += size;
            }
            foreach (int[] core in cores) {
                bool performance = core[0] == maxClass;
                summary[performance ? 0 : 2]++;
                summary[performance ? 1 : 3] += core[1];
            }
        } finally { Marshal.FreeHGlobal(buffer); }
        return summary;
    }
}

// ---------------------------------------------------------------- main window

// StartHidden keeps the very first Show() from making the window visible (start in the tray, no flash).
public class GameBoostMainForm : Form {
    public bool StartHidden;
    protected override void SetVisibleCore(bool value) {
        if (StartHidden && value) {
            StartHidden = false;
            if (!IsHandleCreated) CreateHandle();
            base.SetVisibleCore(false);
            return;
        }
        base.SetVisibleCore(value);
    }
}

// ---------------------------------------------------------------- single instance, tray

// Lets a second launch bring the running window back instead of showing "already open".
// Waits on a background thread; the event is raised on the UI thread.
public sealed class GameBoostShowSignal : IDisposable {
    readonly EventWaitHandle handle;
    readonly Control owner;
    volatile bool stopped;
    public event EventHandler Signaled;

    public GameBoostShowSignal(string name, Control owner) {
        this.owner = owner;
        handle = new EventWaitHandle(false, EventResetMode.AutoReset, name);
        var thread = new Thread(Wait);
        thread.IsBackground = true;
        thread.Start();
    }

    void Wait() {
        while (true) {
            try { handle.WaitOne(); } catch { return; }
            if (stopped) return;
            try { owner.BeginInvoke(new MethodInvoker(Raise)); } catch { }
        }
    }

    void Raise() {
        EventHandler handler = Signaled;
        if (handler != null) handler(this, EventArgs.Empty);
    }

    public static bool Signal(string name) {
        try { using (EventWaitHandle existing = EventWaitHandle.OpenExisting(name)) { existing.Set(); return true; } }
        catch { return false; }
    }

    public void Dispose() {
        stopped = true;
        try { handle.Set(); } catch { }
    }
}

public sealed class GameBoostMenuColors : ProfessionalColorTable {
    readonly Color back, hover, border;
    public GameBoostMenuColors(Color back, Color hover, Color border) {
        this.back = back; this.hover = hover; this.border = border;
        UseSystemColors = false;
    }
    public override Color ToolStripDropDownBackground { get { return back; } }
    public override Color MenuBorder { get { return border; } }
    public override Color MenuItemBorder { get { return hover; } }
    public override Color MenuItemSelected { get { return hover; } }
    public override Color MenuItemSelectedGradientBegin { get { return hover; } }
    public override Color MenuItemSelectedGradientEnd { get { return hover; } }
    public override Color ImageMarginGradientBegin { get { return back; } }
    public override Color ImageMarginGradientMiddle { get { return back; } }
    public override Color ImageMarginGradientEnd { get { return back; } }
    public override Color SeparatorDark { get { return border; } }
    public override Color SeparatorLight { get { return border; } }
}

public sealed class GameBoostMenuRenderer : ToolStripProfessionalRenderer {
    readonly Color disabledText;
    public GameBoostMenuRenderer(Color back, Color hover, Color border, Color disabledText)
        : base(new GameBoostMenuColors(back, hover, border)) {
        this.disabledText = disabledText;
        RoundedEdges = false;
    }
    protected override void OnRenderItemText(ToolStripItemTextRenderEventArgs e) {
        if (!e.Item.Enabled) e.TextColor = disabledText;
        base.OnRenderItemText(e);
    }
}

// ---------------------------------------------------------------- UI controls

public static class GameBoostWindow {
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr window, int attribute, ref int value, int size);
    [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)] static extern int SetWindowTheme(IntPtr window, string appName, string idList);

    // Dark scroll bars for lists, grids and text boxes (including a grid's own scroll bar children).
    public static void UseDarkScrollbars(Control control) {
        try {
            SetWindowTheme(control.Handle, "DarkMode_Explorer", null);
            foreach (Control child in control.Controls)
                if (child is ScrollBar) SetWindowTheme(child.Handle, "DarkMode_Explorer", null);
        } catch { }
    }

    // Dark title bar in the app's own color (Windows 11; ignored elsewhere).
    public static void UseDarkTitleBar(IntPtr window, Color caption) {
        int on = 1;
        if (DwmSetWindowAttribute(window, 20, ref on, 4) != 0) DwmSetWindowAttribute(window, 19, ref on, 4);
        int color = caption.R | (caption.G << 8) | (caption.B << 16);
        DwmSetWindowAttribute(window, 35, ref color, 4);
    }
}

public static class GameBoostDraw {
    public static GraphicsPath RoundedRect(Rectangle bounds, int radius) {
        var path = new GraphicsPath();
        if (radius <= 0) { path.AddRectangle(bounds); return path; }
        int d = Math.Min(radius * 2, Math.Min(bounds.Width, bounds.Height));
        path.AddArc(bounds.X, bounds.Y, d, d, 180, 90);
        path.AddArc(bounds.Right - d, bounds.Y, d, d, 270, 90);
        path.AddArc(bounds.Right - d, bounds.Bottom - d, d, d, 0, 90);
        path.AddArc(bounds.X, bounds.Bottom - d, d, d, 90, 90);
        path.CloseFigure();
        return path;
    }

    public static Color Blend(Color from, Color to, double amount) {
        return Color.FromArgb(
            (int)(from.R + (to.R - from.R) * amount),
            (int)(from.G + (to.G - from.G) * amount),
            (int)(from.B + (to.B - from.B) * amount));
    }
}

public class GameBoostCard : Panel {
    public Color FillColor = Color.FromArgb(23, 28, 37);
    public Color BorderColor = Color.FromArgb(36, 43, 56);
    public int Radius = 12;

    public GameBoostCard() {
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer |
                 ControlStyles.ResizeRedraw | ControlStyles.UserPaint, true);
    }

    protected override void OnPaint(PaintEventArgs e) {
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        using (GraphicsPath path = GameBoostDraw.RoundedRect(new Rectangle(0, 0, Width - 1, Height - 1), Radius))
        using (var brush = new SolidBrush(FillColor))
        using (var pen = new Pen(BorderColor)) {
            e.Graphics.FillPath(brush, path);
            e.Graphics.DrawPath(pen, path);
        }
        base.OnPaint(e);
    }
}

// Thin rounded 0-100 bar for the PC score page.
public class GameBoostScoreBar : Control {
    Color fillColor = Color.FromArgb(46, 204, 128);
    Color trackColor = Color.FromArgb(36, 43, 56);
    int score;

    public GameBoostScoreBar() {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer |
                 ControlStyles.ResizeRedraw, true);
    }

    public Color FillColor { get { return fillColor; } set { fillColor = value; Invalidate(); } }
    public Color TrackColor { get { return trackColor; } set { trackColor = value; Invalidate(); } }
    public int Value { get { return score; } set { score = Math.Max(0, Math.Min(100, value)); Invalidate(); } }

    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = e.Graphics;
        g.Clear(BackColor);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        int radius = Height / 2;
        using (GraphicsPath track = GameBoostDraw.RoundedRect(new Rectangle(0, 0, Width - 1, Height - 1), radius))
        using (var brush = new SolidBrush(trackColor)) g.FillPath(brush, track);
        int fill = (int)Math.Round((Width - 1) * score / 100.0);
        if (fill < Height) return;
        using (GraphicsPath bar = GameBoostDraw.RoundedRect(new Rectangle(0, 0, fill, Height - 1), radius))
        using (var brush = new SolidBrush(fillColor)) g.FillPath(brush, bar);
    }
}

public class GameBoostButton : Button {
    public Color AccentColor = Color.FromArgb(52, 61, 78);
    public Color TextColor = Color.White;
    public int Radius = 8;
    bool hover, pressed;

    public GameBoostButton() {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer |
                 ControlStyles.ResizeRedraw, true);
        FlatStyle = FlatStyle.Flat;
        FlatAppearance.BorderSize = 0;
        Cursor = Cursors.Hand;
    }

    protected override void OnMouseEnter(EventArgs e) { hover = true; Invalidate(); base.OnMouseEnter(e); }
    protected override void OnMouseLeave(EventArgs e) { hover = false; pressed = false; Invalidate(); base.OnMouseLeave(e); }
    protected override void OnMouseDown(MouseEventArgs e) { pressed = true; Invalidate(); base.OnMouseDown(e); }
    protected override void OnMouseUp(MouseEventArgs e) { pressed = false; Invalidate(); base.OnMouseUp(e); }
    protected override void OnEnabledChanged(EventArgs e) { Invalidate(); base.OnEnabledChanged(e); }
    protected override void OnTextChanged(EventArgs e) { Invalidate(); base.OnTextChanged(e); }

    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = e.Graphics;
        g.Clear(BackColor);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        Color fill = AccentColor;
        if (!Enabled) fill = GameBoostDraw.Blend(AccentColor, BackColor, 0.6);
        else if (pressed) fill = GameBoostDraw.Blend(AccentColor, Color.Black, 0.18);
        else if (hover) fill = GameBoostDraw.Blend(AccentColor, Color.White, 0.12);
        using (GraphicsPath path = GameBoostDraw.RoundedRect(new Rectangle(0, 0, Width - 1, Height - 1), Radius))
        using (var brush = new SolidBrush(fill)) g.FillPath(brush, path);
        Color text = Enabled ? TextColor : GameBoostDraw.Blend(TextColor, fill, 0.55);
        TextRenderer.DrawText(g, Text, Font, new Rectangle(6, 0, Width - 12, Height), text,
            TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.WordBreak | TextFormatFlags.NoPrefix);
    }
}

public class GameBoostToggle : CheckBox {
    public Color OnColor = Color.FromArgb(46, 204, 128);
    public Color OffColor = Color.FromArgb(62, 70, 86);
    public Color TextColor = Color.FromArgb(230, 235, 243);

    public GameBoostToggle() {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer |
                 ControlStyles.ResizeRedraw, true);
        AutoSize = false;
        Height = 30;
        Cursor = Cursors.Hand;
    }

    protected override void OnCheckedChanged(EventArgs e) { Invalidate(); base.OnCheckedChanged(e); }
    protected override void OnEnabledChanged(EventArgs e) { Invalidate(); base.OnEnabledChanged(e); }

    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = e.Graphics;
        g.Clear(BackColor);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        const int trackWidth = 38, trackHeight = 20;
        int top = (Height - trackHeight) / 2;
        var track = new Rectangle(0, top, trackWidth, trackHeight);
        Color fill = Checked ? OnColor : OffColor;
        if (!Enabled) fill = GameBoostDraw.Blend(fill, BackColor, 0.5);
        using (GraphicsPath path = GameBoostDraw.RoundedRect(track, trackHeight / 2))
        using (var brush = new SolidBrush(fill)) g.FillPath(brush, path);
        int knob = trackHeight - 6;
        int x = Checked ? track.Right - knob - 3 : track.X + 3;
        using (var brush = new SolidBrush(Color.White)) g.FillEllipse(brush, x, top + 3, knob, knob);
        Color text = Enabled ? TextColor : GameBoostDraw.Blend(TextColor, BackColor, 0.5);
        TextRenderer.DrawText(g, Text, Font, new Rectangle(trackWidth + 12, 0, Width - trackWidth - 12, Height), text,
            TextFormatFlags.VerticalCenter | TextFormatFlags.Left | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix);
    }
}

public class GameBoostNavButton : Control {
    public string Glyph = "";
    public string IconFontName = "Segoe Fluent Icons";
    public Color AccentColor = Color.FromArgb(46, 204, 128);
    public Color SelectedBackColor = Color.FromArgb(30, 37, 49);
    public Color HoverBackColor = Color.FromArgb(24, 30, 40);
    public Color TextColor = Color.FromArgb(150, 160, 178);
    public Color SelectedTextColor = Color.FromArgb(240, 244, 250);
    bool selected, hover;
    Font iconFont;

    public GameBoostNavButton() {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer |
                 ControlStyles.ResizeRedraw, true);
        Cursor = Cursors.Hand;
        Height = 40;
    }

    public bool Selected { get { return selected; } set { selected = value; Invalidate(); } }

    protected override void OnMouseEnter(EventArgs e) { hover = true; Invalidate(); base.OnMouseEnter(e); }
    protected override void OnMouseLeave(EventArgs e) { hover = false; Invalidate(); base.OnMouseLeave(e); }

    protected override void Dispose(bool disposing) {
        if (disposing && iconFont != null) iconFont.Dispose();
        base.Dispose(disposing);
    }

    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = e.Graphics;
        g.Clear(BackColor);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        if (selected || hover) {
            using (GraphicsPath path = GameBoostDraw.RoundedRect(new Rectangle(0, 2, Width - 1, Height - 5), 8))
            using (var brush = new SolidBrush(selected ? SelectedBackColor : HoverBackColor)) g.FillPath(brush, path);
        }
        if (selected) {
            using (GraphicsPath path = GameBoostDraw.RoundedRect(new Rectangle(2, 11, 3, Height - 23), 2))
            using (var brush = new SolidBrush(AccentColor)) g.FillPath(brush, path);
        }
        if (iconFont == null) iconFont = new Font(IconFontName, 11.5f);
        Color text = selected ? SelectedTextColor : TextColor;
        TextRenderer.DrawText(g, Glyph, iconFont, new Rectangle(12, 0, 28, Height), selected ? AccentColor : text,
            TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);
        TextRenderer.DrawText(g, Text, Font, new Rectangle(46, 0, Width - 50, Height), text,
            TextFormatFlags.VerticalCenter | TextFormatFlags.Left | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix);
    }
}

// A list of smart notices: colored dot, bold title, one short detail line.
public class GameBoostAlertView : Panel {
    public Color TextColor = Color.FromArgb(230, 235, 243);
    public Color DetailColor = Color.FromArgb(150, 160, 178);
    public Color CriticalColor = Color.FromArgb(255, 99, 99);
    public Color WarningColor = Color.FromArgb(255, 186, 84);
    public Color InfoColor = Color.FromArgb(92, 160, 255);
    public Color OkColor = Color.FromArgb(46, 204, 128);
    public Font TitleFont = new Font("Segoe UI Semibold", 9.5f);
    public Font DetailFont = new Font("Segoe UI", 9f);

    sealed class Item { public string Severity, Title, Detail; public int TitleHeight, DetailHeight; }
    readonly List<Item> items = new List<Item>();

    public GameBoostAlertView() {
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer |
                 ControlStyles.ResizeRedraw | ControlStyles.UserPaint, true);
        AutoScroll = true;
    }

    public void ClearItems() { items.Clear(); }

    public void AddItem(string severity, string title, string detail) {
        var item = new Item();
        item.Severity = severity;
        item.Title = title ?? "";
        item.Detail = detail ?? "";
        items.Add(item);
    }

    public void Commit() { Relayout(); Invalidate(); }

    protected override void OnResize(EventArgs e) { base.OnResize(e); Relayout(); }

    void Relayout() {
        int width = Math.Max(40, ClientSize.Width - 26);
        int total = 0;
        foreach (Item item in items) {
            const TextFormatFlags flags = TextFormatFlags.WordBreak | TextFormatFlags.NoPadding | TextFormatFlags.NoPrefix;
            item.TitleHeight = TextRenderer.MeasureText(item.Title, TitleFont, new Size(width, 0), flags).Height;
            item.DetailHeight = item.Detail.Length == 0 ? 0 : TextRenderer.MeasureText(item.Detail, DetailFont, new Size(width, 0), flags).Height;
            total += item.TitleHeight + item.DetailHeight + 14;
        }
        AutoScrollMinSize = new Size(0, total);
    }

    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = e.Graphics;
        g.Clear(BackColor);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        int width = Math.Max(40, ClientSize.Width - 26);
        int y = AutoScrollPosition.Y + 2;
        const TextFormatFlags flags = TextFormatFlags.WordBreak | TextFormatFlags.NoPadding | TextFormatFlags.NoPrefix;
        foreach (Item item in items) {
            Color dot = item.Severity == "critical" ? CriticalColor
                      : item.Severity == "warning" ? WarningColor
                      : item.Severity == "ok" ? OkColor : InfoColor;
            using (var brush = new SolidBrush(dot)) g.FillEllipse(brush, 2, y + 5, 9, 9);
            TextRenderer.DrawText(g, item.Title, TitleFont, new Rectangle(20, y, width, item.TitleHeight), TextColor, flags);
            if (item.DetailHeight > 0)
                TextRenderer.DrawText(g, item.Detail, DetailFont, new Rectangle(20, y + item.TitleHeight + 2, width, item.DetailHeight), DetailColor, flags);
            y += item.TitleHeight + item.DetailHeight + 14;
        }
    }
}
