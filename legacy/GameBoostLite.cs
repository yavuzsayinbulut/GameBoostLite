using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

namespace GameBoostLite
{
    internal static class Program
    {
        [STAThread]
        private static void Main()
        {
            bool created;
            using (var mutex = new Mutex(true, "Local\\GameBoostLite.SingleInstance", out created))
            {
                if (!created)
                {
                    MessageBox.Show("GameBoost Lite zaten acik.", "GameBoost Lite",
                        MessageBoxButtons.OK, MessageBoxIcon.Information);
                    return;
                }

                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                Application.Run(new MainForm());
            }
        }
    }

    internal sealed class MainForm : Form
    {
        private const string HighPerformanceGuid = "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c";

        private readonly Label statusLabel;
        private readonly Label metricsLabel;
        private readonly Label gameLabel;
        private readonly Button boostButton;
        private readonly Button restoreButton;
        private readonly CheckBox closeWorkApps;
        private readonly CheckBox closeGameBar;
        private readonly CheckBox closeDiscord;
        private readonly CheckBox closeDocker;
        private readonly CheckBox autoRestore;
        private readonly RichTextBox logBox;
        private readonly System.Windows.Forms.Timer monitorTimer;
        private readonly HashSet<int> detectedGames = new HashSet<int>();

        private bool boosted;
        private bool gameWasDetected;
        private string previousPowerScheme;
        private DateTime lastGameSeenUtc = DateTime.MinValue;
        private ulong lastIdle;
        private ulong lastKernel;
        private ulong lastUser;

        private static readonly HashSet<string> ExcludedNames = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            "GameBoostLite", "steam", "steamservice", "steamwebhelper", "GameOverlayUI",
            "EpicGamesLauncher", "EpicWebHelper", "EpicOnlineServicesUserHelper",
            "EOSOverlayRenderer-Win64-Shipping", "EADesktop", "EALauncher",
            "EABackgroundService", "EALocalHostSvc", "EACefSubProcess",
            "UbisoftConnect", "upc", "UplayWebCore", "RockstarService", "Launcher",
            "SocialClubHelper", "EasyAntiCheat", "EasyAntiCheat_EOS", "BEService",
            "BEService_x64", "CrashReportClient", "UnityCrashHandler64", "UnityCrashHandler32",
            "conhost", "explorer", "dwm", "System", "Registry", "MsMpEng"
        };

        public MainForm()
        {
            Text = "GameBoost Lite";
            ClientSize = new Size(520, 650);
            MinimumSize = new Size(536, 689);
            MaximizeBox = false;
            StartPosition = FormStartPosition.CenterScreen;
            BackColor = Color.FromArgb(17, 20, 27);
            ForeColor = Color.White;
            Font = new Font("Segoe UI", 10F);

            var title = new Label
            {
                Text = "GAMEBOOST LITE",
                Font = new Font("Segoe UI Semibold", 22F, FontStyle.Bold),
                ForeColor = Color.FromArgb(102, 255, 174),
                AutoSize = true,
                Location = new Point(24, 20)
            };
            Controls.Add(title);

            var subtitle = new Label
            {
                Text = "Launcher'i korur, oyunu algilar, kaynaklari oyuna birakir.",
                ForeColor = Color.FromArgb(175, 183, 198),
                AutoSize = true,
                Location = new Point(27, 63)
            };
            Controls.Add(subtitle);

            statusLabel = new Label
            {
                Text = "NORMAL MOD",
                Font = new Font("Segoe UI Semibold", 12F, FontStyle.Bold),
                ForeColor = Color.FromArgb(140, 185, 255),
                AutoSize = true,
                Location = new Point(28, 100)
            };
            Controls.Add(statusLabel);

            metricsLabel = new Label
            {
                Text = "CPU: olculuyor  |  RAM: olculuyor",
                ForeColor = Color.FromArgb(212, 217, 228),
                AutoSize = true,
                Location = new Point(28, 130)
            };
            Controls.Add(metricsLabel);

            gameLabel = new Label
            {
                Text = "Oyun: bekleniyor",
                ForeColor = Color.FromArgb(175, 183, 198),
                AutoEllipsis = true,
                Location = new Point(28, 155),
                Size = new Size(460, 24)
            };
            Controls.Add(gameLabel);

            boostButton = MakeButton("BOOST'U BASLAT", new Point(28, 192), new Size(300, 64),
                Color.FromArgb(43, 205, 125));
            boostButton.Click += BoostButton_Click;
            Controls.Add(boostButton);

            restoreButton = MakeButton("NORMAL MOD", new Point(340, 192), new Size(148, 64),
                Color.FromArgb(60, 68, 84));
            restoreButton.Enabled = false;
            restoreButton.Click += delegate { RestoreNormalMode("Kullanici normal moda dondu."); };
            Controls.Add(restoreButton);

            var optionsTitle = new Label
            {
                Text = "Tek tik ayarlari",
                Font = new Font("Segoe UI Semibold", 11F, FontStyle.Bold),
                ForeColor = Color.White,
                AutoSize = true,
                Location = new Point(28, 280)
            };
            Controls.Add(optionsTitle);

            closeWorkApps = MakeCheckBox("Calisma uygulamalarini kapat (Code, Codex, Edge, Teams)", true, 311);
            closeGameBar = MakeCheckBox("Game Bar / Xbox arka planini kapat", true, 345);
            closeDiscord = MakeCheckBox("Discord'u kapat", false, 379);
            closeDocker = MakeCheckBox("Docker + WSL'yi kapat (container'lar durur)", true, 413);
            autoRestore = MakeCheckBox("Oyun kapaninca guc planini geri yukle", true, 447);
            Controls.Add(closeWorkApps);
            Controls.Add(closeGameBar);
            Controls.Add(closeDiscord);
            Controls.Add(closeDocker);
            Controls.Add(autoRestore);

            var launcherNote = new Label
            {
                Text = "Steam, Epic, EA, Ubisoft ve Rockstar launcher'lari kapatilmaz.\n" +
                       "BOOST'tan sonra oyunu launcher veya kisayolundan normal ac.",
                ForeColor = Color.FromArgb(255, 204, 112),
                Location = new Point(29, 489),
                Size = new Size(460, 45)
            };
            Controls.Add(launcherNote);

            logBox = new RichTextBox
            {
                ReadOnly = true,
                BorderStyle = BorderStyle.None,
                BackColor = Color.FromArgb(11, 13, 18),
                ForeColor = Color.FromArgb(178, 190, 207),
                Font = new Font("Consolas", 9F),
                Location = new Point(28, 546),
                Size = new Size(460, 76),
                TabStop = false
            };
            Controls.Add(logBox);

            monitorTimer = new System.Windows.Forms.Timer { Interval = 1500 };
            monitorTimer.Tick += MonitorTimer_Tick;
            monitorTimer.Start();

            GetSystemTimes(out lastIdle, out lastKernel, out lastUser);
            AddLog("Hazir. Once calismalarini kaydet.");
            FormClosing += MainForm_FormClosing;
        }

        private Button MakeButton(string text, Point location, Size size, Color color)
        {
            return new Button
            {
                Text = text,
                Location = location,
                Size = size,
                BackColor = color,
                ForeColor = Color.White,
                FlatStyle = FlatStyle.Flat,
                Font = new Font("Segoe UI Semibold", 11F, FontStyle.Bold),
                Cursor = Cursors.Hand,
                UseVisualStyleBackColor = false
            };
        }

        private CheckBox MakeCheckBox(string text, bool isChecked, int top)
        {
            return new CheckBox
            {
                Text = text,
                Checked = isChecked,
                AutoSize = true,
                Location = new Point(31, top),
                ForeColor = Color.FromArgb(212, 217, 228)
            };
        }

        private void BoostButton_Click(object sender, EventArgs e)
        {
            if (boosted) return;

            if (closeWorkApps.Checked || closeDocker.Checked)
            {
                string dockerWarning = closeDocker.Checked
                    ? "\nDocker/WSL ve acik container'lar da durdurulacak."
                    : "";
                string workWarning = closeWorkApps.Checked
                    ? "Code, Codex, Edge ve Teams kapatilabilir.\n\n"
                    : "";
                var answer = MessageBox.Show(
                    workWarning +
                    "Kaydedilmemis calismalarini kaydettin mi?\n" +
                    "Steam/Epic/EA launcher'lari acik kalacak." + dockerWarning,
                    "BOOST onayi", MessageBoxButtons.YesNo, MessageBoxIcon.Warning);
                if (answer != DialogResult.Yes) return;
            }

            previousPowerScheme = GetActivePowerScheme();
            SetPowerScheme(HighPerformanceGuid);
            EnableWindowsGameMode();

            if (closeGameBar.Checked)
                CloseProcesses(new[] { "GameBar", "GameBarFTServer", "GameBarPresenceWriter",
                    "XboxGameBarWidgets", "XboxPcAppFT", "SpotifyXboxGamebarWebView", "EdgeGameAssist" }, true);

            if (closeDiscord.Checked)
                CloseProcesses(new[] { "Discord" }, true);

            if (closeDocker.Checked)
                StopDockerAndWsl();

            StopInfaticaIfRunning();

            if (closeWorkApps.Checked)
                CloseProcesses(new[] { "Code", "codex", "codex-code-mode-host", "msedge",
                    "ms-teams", "Teams" }, true);

            boosted = true;
            gameWasDetected = false;
            lastGameSeenUtc = DateTime.MinValue;
            detectedGames.Clear();
            boostButton.Enabled = false;
            restoreButton.Enabled = true;
            statusLabel.Text = "BOOST AKTIF";
            statusLabel.ForeColor = Color.FromArgb(102, 255, 174);
            gameLabel.Text = "Oyun: Steam/Epic/EA uzerinden acman bekleniyor";
            AddLog("BOOST aktif. Launcher'lar korunuyor.");
            DetectAndOptimizeGames();
        }

        private void MonitorTimer_Tick(object sender, EventArgs e)
        {
            UpdateMetrics();
            if (boosted)
            {
                StopInfaticaIfRunning();
                DetectAndOptimizeGames();
            }
        }

        private void DetectAndOptimizeGames()
        {
            var alive = new HashSet<int>();
            foreach (var process in Process.GetProcesses())
            {
                try
                {
                    if (!IsGameProcess(process)) continue;
                    alive.Add(process.Id);
                    lastGameSeenUtc = DateTime.UtcNow;
                    if (detectedGames.Add(process.Id))
                    {
                        gameWasDetected = true;
                        TryOptimize(process);
                        gameLabel.Text = "Oyun: " + process.ProcessName + " (optimize edildi)";
                        AddLog("Oyun algilandi: " + process.ProcessName);
                    }
                }
                catch { }
                finally { process.Dispose(); }
            }

            detectedGames.RemoveWhere(delegate(int id) { return !alive.Contains(id); });

            // Launchers sometimes hand off from a short-lived bootstrap process to the real game.
            // Wait before restoring so that transition is not mistaken for the game closing.
            if (gameWasDetected && detectedGames.Count == 0 && autoRestore.Checked &&
                DateTime.UtcNow - lastGameSeenUtc > TimeSpan.FromSeconds(12))
                RestoreNormalMode("Oyun kapandi; normal moda donuldu.");
        }

        private bool IsGameProcess(Process process)
        {
            if (ExcludedNames.Contains(process.ProcessName)) return false;
            string path;
            try { path = process.MainModule.FileName; }
            catch { return false; }
            if (string.IsNullOrEmpty(path)) return false;

            string p = path.ToLowerInvariant();
            bool knownLibrary =
                p.Contains("\\steamapps\\common\\") ||
                (p.Contains("\\epic games\\") && !p.Contains("\\launcher\\")) ||
                p.Contains("\\xboxgames\\") ||
                p.Contains("\\ea games\\") ||
                p.Contains("\\ubisoft game launcher\\games\\") ||
                (p.Contains("\\rockstar games\\") && !p.Contains("\\launcher\\"));

            if (!knownLibrary) return false;
            if (p.Contains("crashreport") || p.Contains("anticheat") || p.Contains("easyanticheat"))
                return false;

            try
            {
                return process.WorkingSet64 > 120L * 1024L * 1024L || process.MainWindowHandle != IntPtr.Zero;
            }
            catch { return false; }
        }

        private void TryOptimize(Process process)
        {
            try { process.PriorityClass = ProcessPriorityClass.AboveNormal; }
            catch { AddLog("Oncelik degistirilemedi (anti-cheat korumasi olabilir)."); }

            try
            {
                string exe = process.MainModule.FileName;
                using (var key = Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\DirectX\UserGpuPreferences"))
                {
                    if (key != null) key.SetValue(exe, "GpuPreference=2;", RegistryValueKind.String);
                }
            }
            catch { AddLog("GPU tercihi kaydedilemedi."); }
        }

        private void RestoreNormalMode(string reason)
        {
            if (!boosted) return;
            if (!string.IsNullOrEmpty(previousPowerScheme)) SetPowerScheme(previousPowerScheme);
            boosted = false;
            detectedGames.Clear();
            boostButton.Enabled = true;
            restoreButton.Enabled = false;
            statusLabel.Text = "NORMAL MOD";
            statusLabel.ForeColor = Color.FromArgb(140, 185, 255);
            gameLabel.Text = "Oyun: bekleniyor";
            AddLog(reason);
        }

        private void CloseProcesses(IEnumerable<string> names, bool forceAfterGracefulClose)
        {
            var wanted = new HashSet<string>(names, StringComparer.OrdinalIgnoreCase);
            var targets = Process.GetProcesses().Where(p => wanted.Contains(p.ProcessName)).ToList();

            foreach (var process in targets)
            {
                try
                {
                    if (process.MainWindowHandle != IntPtr.Zero) process.CloseMainWindow();
                }
                catch { }
            }

            if (forceAfterGracefulClose) Thread.Sleep(700);
            foreach (var process in targets)
            {
                try
                {
                    if (forceAfterGracefulClose && !process.HasExited) process.Kill();
                }
                catch { }
                finally { process.Dispose(); }
            }
        }

        private void EnableWindowsGameMode()
        {
            try
            {
                using (var key = Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\GameBar"))
                {
                    if (key != null)
                    {
                        key.SetValue("AutoGameModeEnabled", 1, RegistryValueKind.DWord);
                        key.SetValue("AllowAutoGameMode", 1, RegistryValueKind.DWord);
                    }
                }
                AddLog("Windows Oyun Modu etkin.");
            }
            catch { AddLog("Windows Oyun Modu ayarlanamadi."); }
        }

        private void StopDockerAndWsl()
        {
            CloseProcesses(new[] { "Docker Desktop", "com.docker.backend", "com.docker.build", "docker" }, true);
            try
            {
                var info = new ProcessStartInfo
                {
                    FileName = "wsl.exe",
                    Arguments = "--shutdown",
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true
                };
                using (var process = Process.Start(info))
                {
                    process.WaitForExit(5000);
                }
                AddLog("Docker/WSL durduruldu.");
            }
            catch { AddLog("Docker/WSL tamamen durdurulamadi."); }
        }

        private void StopInfaticaIfRunning()
        {
            var processes = Process.GetProcessesByName("infatica_agent");
            if (processes.Length == 0) return;
            foreach (var process in processes)
            {
                try { process.Kill(); }
                catch { }
                finally { process.Dispose(); }
            }
            AddLog("Infatica ag paylasim ajani durduruldu.");
        }

        private string GetActivePowerScheme()
        {
            try
            {
                string output = RunPowerCfg("/getactivescheme");
                var match = Regex.Match(output, "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}");
                return match.Success ? match.Value : null;
            }
            catch { return null; }
        }

        private void SetPowerScheme(string scheme)
        {
            try
            {
                RunPowerCfg("/setactive " + scheme);
                AddLog("Guc plani ayarlandi.");
            }
            catch { AddLog("Guc plani degistirilemedi."); }
        }

        private string RunPowerCfg(string arguments)
        {
            var info = new ProcessStartInfo
            {
                FileName = "powercfg.exe",
                Arguments = arguments,
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true
            };
            using (var process = Process.Start(info))
            {
                string output = process.StandardOutput.ReadToEnd();
                process.WaitForExit(3000);
                return output;
            }
        }

        private void UpdateMetrics()
        {
            double cpu = ReadCpuUsage();
            var mem = new MemoryStatusEx();
            mem.dwLength = (uint)Marshal.SizeOf(typeof(MemoryStatusEx));
            GlobalMemoryStatusEx(ref mem);
            double available = mem.ullAvailPhys / 1073741824.0;
            double total = mem.ullTotalPhys / 1073741824.0;
            metricsLabel.Text = string.Format("CPU: %{0:0}  |  Kullanilabilir RAM: {1:0.0}/{2:0.0} GiB", cpu, available, total);
        }

        private double ReadCpuUsage()
        {
            ulong idle, kernel, user;
            if (!GetSystemTimes(out idle, out kernel, out user)) return 0;
            ulong idleDiff = idle - lastIdle;
            ulong kernelDiff = kernel - lastKernel;
            ulong userDiff = user - lastUser;
            ulong total = kernelDiff + userDiff;
            lastIdle = idle;
            lastKernel = kernel;
            lastUser = user;
            if (total == 0) return 0;
            return Math.Max(0, Math.Min(100, (total - idleDiff) * 100.0 / total));
        }

        private void AddLog(string text)
        {
            if (logBox == null) return;
            logBox.AppendText(DateTime.Now.ToString("HH:mm:ss") + "  " + text + Environment.NewLine);
            logBox.SelectionStart = logBox.TextLength;
            logBox.ScrollToCaret();
        }

        private void MainForm_FormClosing(object sender, FormClosingEventArgs e)
        {
            if (boosted) RestoreNormalMode("Uygulama kapandi; normal moda donuldu.");
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetSystemTimes(out ulong idleTime, out ulong kernelTime, out ulong userTime);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GlobalMemoryStatusEx(ref MemoryStatusEx buffer);

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
        private struct MemoryStatusEx
        {
            public uint dwLength;
            public uint dwMemoryLoad;
            public ulong ullTotalPhys;
            public ulong ullAvailPhys;
            public ulong ullTotalPageFile;
            public ulong ullAvailPageFile;
            public ulong ullTotalVirtual;
            public ulong ullAvailVirtual;
            public ulong ullAvailExtendedVirtual;
        }
    }
}
