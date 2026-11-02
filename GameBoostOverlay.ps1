param(
    [ValidateSet('Timed', 'Persistent')]
    [string]$Mode = 'Timed',
    [int]$Seconds = 10
)

$ErrorActionPreference = 'SilentlyContinue'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type -ReferencedAssemblies @('System.Windows.Forms.dll','System.Drawing.dll') -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public sealed class GameBoostHudForm : Form {
    public GameBoostHudForm() {
        DoubleBuffered = true;
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        TopMost = true;
    }
    protected override bool ShowWithoutActivation { get { return true; } }
    protected override CreateParams CreateParams {
        get {
            CreateParams cp = base.CreateParams;
            cp.ExStyle |= 0x08000000 | 0x00000020 | 0x00000080;
            return cp;
        }
    }
    protected override void OnResize(EventArgs e) {
        base.OnResize(e);
        int r = 12;
        using (GraphicsPath p = new GraphicsPath()) {
            p.AddArc(0, 0, r, r, 180, 90);
            p.AddArc(Width-r-1, 0, r, r, 270, 90);
            p.AddArc(Width-r-1, Height-r-1, r, r, 0, 90);
            p.AddArc(0, Height-r-1, r, r, 90, 90);
            p.CloseFigure();
            Region old = Region;
            Region = new Region(p);
            if (old != null) old.Dispose();
        }
    }
    protected override void OnPaint(PaintEventArgs e) {
        base.OnPaint(e);
        using (Pen pen = new Pen(Color.FromArgb(35, 226, 132), 1.0f))
            e.Graphics.DrawRectangle(pen, 0, 0, Width-1, Height-1);
    }
}

public static class GameBoostNativeMetrics {
    [StructLayout(LayoutKind.Sequential)]
    struct FILETIME { public uint Low; public uint High; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
    struct MEMORYSTATUSEX {
        public uint Length; public uint MemoryLoad;
        public ulong TotalPhys, AvailPhys, TotalPageFile, AvailPageFile;
        public ulong TotalVirtual, AvailVirtual, AvailExtendedVirtual;
    }
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool GetSystemTimes(out FILETIME idle, out FILETIME kernel, out FILETIME user);
    [DllImport("kernel32.dll", CharSet=CharSet.Auto, SetLastError=true)]
    static extern bool GlobalMemoryStatusEx(ref MEMORYSTATUSEX status);
    static ulong oldIdle, oldTotal;
    static ulong ToUlong(FILETIME value) { return ((ulong)value.High << 32) | value.Low; }
    public static double CpuPercent() {
        FILETIME idle, kernel, user;
        if (!GetSystemTimes(out idle, out kernel, out user)) return 0;
        ulong idleNow = ToUlong(idle), totalNow = ToUlong(kernel) + ToUlong(user);
        ulong idleDelta = idleNow - oldIdle, totalDelta = totalNow - oldTotal;
        oldIdle = idleNow; oldTotal = totalNow;
        if (totalDelta == 0 || oldTotal == totalDelta) return 0;
        return Math.Max(0, Math.Min(100, 100.0 * (totalDelta - idleDelta) / totalDelta));
    }
    public static double[] MemoryGb() {
        MEMORYSTATUSEX s = new MEMORYSTATUSEX(); s.Length = (uint)Marshal.SizeOf(s);
        if (!GlobalMemoryStatusEx(ref s)) return new double[] { 0, 0 };
        return new double[] { (s.TotalPhys-s.AvailPhys)/1073741824.0, s.TotalPhys/1073741824.0 };
    }

    [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern bool QueryFullProcessImageName(IntPtr process, int flags, System.Text.StringBuilder name, ref int size);

    [StructLayout(LayoutKind.Sequential)] struct WindowRect { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out int pid);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr window, out WindowRect rect);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongW")] static extern int GetWindowLong(IntPtr window, int index);

    // Process of the foreground window when it covers its monitor without a title bar, else 0.
    public static int ForegroundFullscreenPid() {
        IntPtr window = GetForegroundWindow();
        if (window == IntPtr.Zero || (GetWindowLong(window, -16) & 0x00C00000) == 0x00C00000) return 0;
        WindowRect rect;
        if (!GetWindowRect(window, out rect)) return 0;
        Rectangle bounds = Screen.FromHandle(window).Bounds;
        if (rect.Left > bounds.Left + 2 || rect.Top > bounds.Top + 2 || rect.Right < bounds.Right - 2 || rect.Bottom < bounds.Bottom - 2) return 0;
        int pid;
        GetWindowThreadProcessId(window, out pid);
        return pid;
    }

    // Limited access only: cheap, and allowed for anti-cheat protected games.
    public static string ProcessPath(int pid) {
        IntPtr handle = OpenProcess(0x1000, false, pid);
        if (handle == IntPtr.Zero) return null;
        try {
            var builder = new System.Text.StringBuilder(1024);
            int size = builder.Capacity;
            return QueryFullProcessImageName(handle, 0, builder, ref size) ? builder.ToString(0, size) : null;
        } finally { CloseHandle(handle); }
    }
}

// Helper processes die with the HUD, even if the HUD itself is killed.
public static class GameBoostChildJob {
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
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode)] static extern IntPtr CreateJobObject(IntPtr attributes, string name);
    [DllImport("kernel32.dll")] static extern bool SetInformationJobObject(IntPtr job, int infoClass, ref ExtendedLimits info, uint size);
    [DllImport("kernel32.dll")] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    static IntPtr job = IntPtr.Zero;

    public static void Assign(System.Diagnostics.Process process) {
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

// One nvidia-smi process that reports every 2 s instead of a new process per update.
public sealed class GameBoostGpuReader {
    System.Diagnostics.Process process;
    volatile string lastLine;
    public string LastLine { get { return lastLine; } }

    public bool Start(string path) {
        try {
            var info = new System.Diagnostics.ProcessStartInfo(path,
                "--query-gpu=utilization.gpu,temperature.gpu,memory.used,memory.total --format=csv,noheader,nounits -lms 2000");
            info.UseShellExecute = false;
            info.CreateNoWindow = true;
            info.RedirectStandardOutput = true;
            process = new System.Diagnostics.Process();
            process.StartInfo = info;
            process.OutputDataReceived += delegate(object sender, System.Diagnostics.DataReceivedEventArgs e) {
                if (!string.IsNullOrEmpty(e.Data) && e.Data.IndexOf(',') > 0) lastLine = e.Data;
            };
            process.Start();
            GameBoostChildJob.Assign(process);
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
'@

$stateDirectory = Join-Path $env:LOCALAPPDATA 'GameBoostLite'
$settingsFile = Join-Path $stateDirectory 'settings.json'
$stopFile = Join-Path $stateDirectory 'overlay-stop.txt'
$extendFile = Join-Path $stateDirectory 'overlay-extend.txt'
$persistentFile = Join-Path $stateDirectory 'overlay-persistent.txt'
$modeFile = Join-Path $stateDirectory 'overlay-mode.txt'
$presentMonPath = 'C:\Program Files\NVIDIA Corporation\FrameViewSDK\bin\PresentMon_x64.exe'
$nvidiaSmiPath = (Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue).Source
$script:presentMonAccess = $false
try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    $script:presentMonAccess = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) -or
        [bool]($identity.Groups | Where-Object { $_.Value -eq 'S-1-5-32-559' })
} catch { }

if (Test-Path $settingsFile) {
    try {
        $settings = Get-Content -LiteralPath $settingsFile -Raw | ConvertFrom-Json
        if (-not [bool]$settings.OverlayEnabled) { exit }
    } catch { exit }
} else { exit }

$createdNew = $false
$mutex = [Threading.Mutex]::new($true, 'Local\GameBoostOverlay.Display', [ref]$createdNew)
if (-not $createdNew) { exit }

New-Item -ItemType Directory -Path $stateDirectory -Force | Out-Null
Remove-Item -LiteralPath $stopFile, $extendFile, $persistentFile, $modeFile -Force -ErrorAction SilentlyContinue
Set-Content -LiteralPath $modeFile -Value $Mode -Encoding ASCII

$script:presentMonProcess = $null
$script:presentMonOutput = $null
$script:presentMonGamePid = 0
$script:lastPresentMonAttempt = [datetime]::MinValue
$script:lastPresentMonAttemptPid = 0
$script:lastFps = $null
$script:cachedGame = $null
$script:lastGameScan = [datetime]::MinValue
$script:lastScreenDevice = ''
$script:persistent = ($Mode -eq 'Persistent')
$script:hideAt = if ($script:persistent) { [datetime]::MaxValue } else { (Get-Date).AddSeconds([math]::Max(3, $Seconds)) }
$script:metricCounter = 0

$excluded = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
@('steam','steamservice','steamwebhelper','EpicGamesLauncher','EpicWebHelper',
  'EpicOnlineServicesUserHelper','EOSOverlayRenderer-Win64-Shipping','EADesktop',
  'EALauncher','EABackgroundService','EALocalHostSvc','EACefSubProcess','UbisoftConnect',
  'upc','UplayWebCore','RockstarService','Launcher','SocialClubHelper','EasyAntiCheat',
  'EasyAntiCheat_EOS','BEService','BEService_x64','CrashReportClient','UnityCrashHandler64',
  'UnityCrashHandler32','explorer','dwm','System','Registry','MsMpEng') |
    ForEach-Object { [void]$excluded.Add($_) }

$currentGameFile = Join-Path $stateDirectory 'current-game.json'
$nonGameNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
@('explorer','mstsc','vmconnect','POWERPNT','Code','devenv','WindowsTerminal','cmd','powershell','pwsh',
  'chrome','msedge','firefox','brave','opera','vivaldi','Discord','Spotify','ms-teams','Teams','Zoom','Slack',
  'obs64','LockApp','claude','ApplicationFrameHost','Photos','vlc','mpc-hc64','PotPlayerMini64','wmplayer') |
    ForEach-Object { [void]$nonGameNames.Add($_) }

# Same game as BOOST when it is running (also games outside the known libraries).
function Get-SharedGameProcess {
    if (-not (Test-Path -LiteralPath $currentGameFile)) { return $null }
    try {
        $shared = Get-Content -LiteralPath $currentGameFile -Raw | ConvertFrom-Json
        $process = [Diagnostics.Process]::GetProcessById([int]$shared.Id)
        if ($process.ProcessName -eq $shared.Name -and -not $process.HasExited) { return $process }
    } catch { }
    return $null
}

function Get-FullscreenGameProcess {
    $foregroundId = [GameBoostNativeMetrics]::ForegroundFullscreenPid()
    if ($foregroundId -le 0 -or $foregroundId -eq $PID) { return $null }
    try {
        $process = [Diagnostics.Process]::GetProcessById($foregroundId)
        if ($excluded.Contains($process.ProcessName) -or $nonGameNames.Contains($process.ProcessName)) { return $null }
        if ($process.ProcessName -match 'player|viewer|browser|video|media|photo|stream|record|capture|remote') { return $null }
        if ($process.WorkingSet64 -ge 400MB) { return $process }
    } catch { }
    return $null
}

function Get-GameProcess {
    if ($script:cachedGame -and ([datetime]::UtcNow - $script:lastGameScan).TotalSeconds -lt 8) {
        try { if (-not $script:cachedGame.HasExited) { return $script:cachedGame } } catch { }
    }
    $script:lastGameScan = [datetime]::UtcNow
    $shared = Get-SharedGameProcess
    if ($shared) { $script:cachedGame = $shared; return $shared }
    $candidates = @()
    foreach ($process in Get-Process -ErrorAction SilentlyContinue) {
        if ($excluded.Contains($process.ProcessName)) { continue }
        $path = [GameBoostNativeMetrics]::ProcessPath($process.Id)
        if (-not $path) { continue }
        $path = $path.ToLowerInvariant()
        if ($path.Contains('\steamworks shared\') -or $path.Contains('\_commonredist\') -or $path.Contains('\redist\')) { continue }
        # Steam tools that are not games (same list as GameBoostEngine.IsGameLibraryPath).
        if ($path.Contains('\steamapps\common\wallpaper_engine\') -or $path.Contains('\steamapps\common\steamvr\') -or
            $path.Contains('\steamapps\common\lossless scaling\') -or $path.Contains('\steamapps\common\soundpad\')) { continue }
        $known =
            $path.Contains('\steamapps\common\') -or
            ($path.Contains('\epic games\') -and -not $path.Contains('\launcher\')) -or
            $path.Contains('\xboxgames\') -or
            $path.Contains('\ea games\') -or
            $path.Contains('\ubisoft game launcher\games\') -or
            ($path.Contains('\rockstar games\') -and -not $path.Contains('\launcher\'))
        if (-not $known -or $path.Contains('anticheat') -or $path.Contains('crashreport')) { continue }
        if ($process.WorkingSet64 -gt 120MB -or $process.MainWindowHandle -ne [IntPtr]::Zero) {
            $candidates += $process
        }
    }
    $script:cachedGame = ($candidates | Sort-Object WorkingSet64 -Descending | Select-Object -First 1)
    if (-not $script:cachedGame) { $script:cachedGame = Get-FullscreenGameProcess }
    return $script:cachedGame
}

function Stop-PresentMon {
    $oldOutput = $script:presentMonOutput
    if ($script:presentMonProcess) {
        try { if (-not $script:presentMonProcess.HasExited) { $script:presentMonProcess.Kill() } } catch { }
        try { $script:presentMonProcess.Dispose() } catch { }
    }
    $script:presentMonProcess = $null
    $script:presentMonOutput = $null
    $script:presentMonGamePid = 0
    $script:lastFps = $null
    if ($oldOutput) { Remove-Item -LiteralPath $oldOutput -Force -ErrorAction SilentlyContinue }
}

function Start-PresentMon {
    param([Diagnostics.Process]$Game)
    if (-not $Game -or -not $script:presentMonAccess -or -not (Test-Path $presentMonPath)) { return }
    if ($script:presentMonProcess -and $script:presentMonGamePid -eq $Game.Id) {
        try { if (-not $script:presentMonProcess.HasExited) { return } } catch { }
    }
    if ($script:lastPresentMonAttemptPid -eq $Game.Id -and
        ([datetime]::UtcNow - $script:lastPresentMonAttempt).TotalSeconds -lt 10) { return }
    Stop-PresentMon
    $script:lastPresentMonAttempt = [datetime]::UtcNow
    $script:lastPresentMonAttemptPid = $Game.Id
    $script:presentMonOutput = Join-Path $stateDirectory "presentmon-$($Game.Id).csv"
    Remove-Item -LiteralPath $script:presentMonOutput -Force -ErrorAction SilentlyContinue
    try {
        $info = [Diagnostics.ProcessStartInfo]::new()
        $info.FileName = $presentMonPath
        $captureSeconds = if ($script:persistent) { 30 } else { 8 }
        $info.Arguments = "--process_id $($Game.Id) --timed $captureSeconds --terminate_after_timed --stop_existing_session --output_file `"$($script:presentMonOutput)`" --no_console_stats --v1_metrics --session_name GameBoostOverlay"
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $script:presentMonProcess = [Diagnostics.Process]::Start($info)
        [GameBoostChildJob]::Assign($script:presentMonProcess)
        $script:presentMonGamePid = $Game.Id
    } catch { Stop-PresentMon }
}

function Read-Fps {
    if (-not $script:presentMonOutput -or -not (Test-Path $script:presentMonOutput)) { return $null }
    try {
        $stream = [IO.File]::Open($script:presentMonOutput, 'Open', 'Read', 'ReadWrite')
        $reader = [IO.StreamReader]::new($stream)
        $content = $reader.ReadToEnd()
        $reader.Dispose(); $stream.Dispose()
        $lines = @($content -split "`r?`n" | Where-Object { $_ })
        if ($lines.Count -lt 3) { return $null }
        $header = @($lines[0].Split(',')); $index = -1
        for ($i = 0; $i -lt $header.Count; $i++) {
            if ($header[$i].Trim('"') -ieq 'MsBetweenPresents') { $index = $i; break }
        }
        if ($index -lt 0) { return $null }
        $values = [Collections.Generic.List[double]]::new()
        foreach ($line in @($lines | Select-Object -Last 60)) {
            $columns = $line.Split(','); if ($columns.Count -le $index) { continue }
            $value = 0.0
            if ([double]::TryParse($columns[$index], [Globalization.NumberStyles]::Float,
                [Globalization.CultureInfo]::InvariantCulture, [ref]$value) -and
                $value -gt 0.1 -and $value -lt 1000) { $values.Add($value) }
        }
        if ($values.Count -eq 0) { return $null }
        $average = ($values | Measure-Object -Average).Average
        return [pscustomobject]@{ FPS=[math]::Round(1000/$average); FrameMs=[math]::Round($average,1) }
    } catch { return $null }
}

$window = [GameBoostHudForm]::new()
$window.Text = 'GameBoost Safe HUD'
$window.Size = [Drawing.Size]::new(332, 128)
$window.BackColor = [Drawing.Color]::FromArgb(10, 16, 24)
$window.Opacity = 0.94
$window.Padding = [Windows.Forms.Padding]::new(14, 10, 14, 10)
$text = [Windows.Forms.Label]::new()
$text.Dock = 'Fill'
$text.Font = [Drawing.Font]::new('Consolas', 11, [Drawing.FontStyle]::Bold)
$text.ForeColor = [Drawing.Color]::FromArgb(220,235,245)
$text.BackColor = [Drawing.Color]::Transparent
$text.Text = "GAMEBOOST SAFE HUD`nFPS --  |  GPU --  |  CPU --"
$text.TextAlign = 'MiddleLeft'
$window.Controls.Add($text)
$work = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$window.Location = [Drawing.Point]::new([math]::Max(10, $work.Right - $window.Width - 20), $work.Top + 20)

function Set-HudScreen {
    param([Diagnostics.Process]$Game)
    $screen = [Windows.Forms.Screen]::PrimaryScreen
    if ($Game) {
        try {
            if ($Game.MainWindowHandle -ne [IntPtr]::Zero) {
                $screen = [Windows.Forms.Screen]::FromHandle($Game.MainWindowHandle)
            }
        } catch { }
    }
    if ($screen -and $screen.DeviceName -ne $script:lastScreenDevice) {
        $workArea = $screen.WorkingArea
        $window.Location = [Drawing.Point]::new(
            [math]::Max($workArea.Left + 10, $workArea.Right - $window.Width - 20),
            $workArea.Top + 20
        )
        $script:lastScreenDevice = $screen.DeviceName
    }
}

function Update-Hud {
    try {
        $game = Get-GameProcess
        Set-HudScreen $game
        if ($game) { Start-PresentMon $game }
        $fps = Read-Fps; if ($fps) { $script:lastFps = $fps }
        $cpu = [math]::Round([GameBoostNativeMetrics]::CpuPercent())
        $memory = [GameBoostNativeMetrics]::MemoryGb()
        $usedRam = [math]::Round($memory[0],1)
        $totalRam = [math]::Round($memory[1],1)
        $gpuText='GPU --'; $gpuTemp='--'; $vramText='--'
        if ($script:gpuReader) {
            $gpu = $script:gpuReader.LastLine
            if ($gpu) {
                $parts=@($gpu -split ','|ForEach-Object{$_.Trim()})
                if ($parts.Count -ge 4) {$gpuText="GPU $($parts[0])%";$gpuTemp="$($parts[1])C";$vramText="$($parts[2])/$($parts[3]) MB"}
            }
        }
        $fpsText=if($script:lastFps){"FPS $($script:lastFps.FPS)  $($script:lastFps.FrameMs) ms"}elseif(-not $script:presentMonAccess){'FPS -- (yetki)'}else{'FPS --'}
        $gameText=if($game){$game.ProcessName}else{'Oyun bekleniyor'}
        $text.Text="GAMEBOOST  $gameText`n$fpsText`n$gpuText  $gpuTemp  VRAM $vramText`nCPU $cpu%  RAM $usedRam/$totalRam GB"
    } catch { $text.Text="GAMEBOOST SAFE HUD`nFPS --  GPU --  CPU --" }
}

$timer = [Windows.Forms.Timer]::new()
$timer.Interval = 250
$timer.Add_Tick({
    if (Test-Path $stopFile) { $window.Close(); return }
    if (Test-Path $persistentFile) {
        Remove-Item -LiteralPath $persistentFile -Force -ErrorAction SilentlyContinue
        $script:persistent = $true
        $script:hideAt = [datetime]::MaxValue
        Set-Content -LiteralPath $modeFile -Value 'Persistent' -Encoding ASCII
    }
    if (Test-Path $extendFile) {
        Remove-Item -LiteralPath $extendFile -Force -ErrorAction SilentlyContinue
        if (-not $script:persistent) { $script:hideAt=(Get-Date).AddSeconds(10) }
    }
    if (-not $script:persistent -and (Get-Date) -ge $script:hideAt) { $window.Close(); return }
    $script:metricCounter++
    if ($script:metricCounter -ge 12) { $script:metricCounter=0; Update-Hud }
})

$script:gpuReader = $null
if ($nvidiaSmiPath) {
    $script:gpuReader = [GameBoostGpuReader]::new()
    if (-not $script:gpuReader.Start($nvidiaSmiPath)) { $script:gpuReader = $null }
}

try {
    Update-Hud
    $timer.Start()
    [void]$window.ShowDialog()
} finally {
    $timer.Stop()
    if ($script:gpuReader) { $script:gpuReader.Stop() }
    Stop-PresentMon
    Remove-Item -LiteralPath $stopFile,$extendFile,$persistentFile,$modeFile -Force -ErrorAction SilentlyContinue
    try { $mutex.ReleaseMutex() } catch { }
    $mutex.Dispose()
}
