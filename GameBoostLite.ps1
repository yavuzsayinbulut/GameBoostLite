# -Startup: launched by Windows at sign-in (see "Windows açılınca başlat").
# -Restart: launched by "Yeniden başlat" in the tray menu; waits for the old copy to close.
param([switch]$Startup, [switch]$Restart)

$ErrorActionPreference = 'SilentlyContinue'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$script:appRoot = $PSScriptRoot

try {
    Add-Type -Path (Join-Path $script:appRoot 'lib\GameBoostNative.cs') `
        -ReferencedAssemblies @('System.Windows.Forms.dll', 'System.Drawing.dll') -ErrorAction Stop
} catch {
    [void][Windows.Forms.MessageBox]::Show("GameBoost bileşenleri yüklenemedi:`r`n$($_.Exception.Message)", 'GameBoost Lite', 'OK', 'Error')
    exit 1
}
[Windows.Forms.Application]::EnableVisualStyles()

$createdNew = $false
$script:instanceMutex = [Threading.Mutex]::new($true, 'Local\GameBoostLite.PowerShell.SingleInstance', [ref]$createdNew)
$ownsInstance = $createdNew
if (-not $ownsInstance -and $Restart) {
    # The old copy is still undoing BOOST; it lets go of the lock as its very last step.
    try { $ownsInstance = $script:instanceMutex.WaitOne(20000) } catch [Threading.AbandonedMutexException] { $ownsInstance = $true }
}
if (-not $ownsInstance) {
    # Already running (maybe hidden in the tray): bring that window back instead.
    if (-not [GameBoostShowSignal]::Signal('Local\GameBoostLite.Show')) {
        [void][Windows.Forms.MessageBox]::Show('GameBoost Lite zaten açık.', 'GameBoost Lite', 'OK', 'Information')
    }
    exit
}

. (Join-Path $script:appRoot 'lib\Ui.ps1')
. (Join-Path $script:appRoot 'lib\Boost.ps1')
. (Join-Path $script:appRoot 'lib\Insights.ps1')
. (Join-Path $script:appRoot 'lib\Pages.ps1')
. (Join-Path $script:appRoot 'lib\Session.ps1')
. (Join-Path $script:appRoot 'lib\Tweaks.ps1')
. (Join-Path $script:appRoot 'lib\Score.ps1')
. (Join-Path $script:appRoot 'lib\Modes.ps1')

$script:hasNvidiaGpu = [bool](Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue)
[void][GameBoostEngine]::CpuPercent()

$script:staleBoostRestored = Restore-StaleBoostState
$script:staleModesRestored = Restore-StaleModes
Load-CustomSettings
$recommendationMigrationNeeded = -not $script:recommendationsInitialized
Initialize-RecommendedCloseNames
if (-not $script:settingsLoaded -or $recommendationMigrationNeeded) {
    Save-CustomSettings -Quiet
    $script:settingsLoaded = $true
}
Sync-AutoStartOption
$script:startHidden = $Startup -and $script:options.StartInTray

# ---------------------------------------------------------------- window shell

$form = [GameBoostMainForm]::new()
$form.StartHidden = $script:startHidden
$form.Text = 'GameBoost Lite'
$form.ClientSize = [Drawing.Size]::new(1180, 720)
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.StartPosition = 'CenterScreen'
$form.BackColor = $script:theme.Window
$form.ForeColor = $script:theme.Text
$form.Font = $script:fonts.Body
$iconPath = Join-Path $script:appRoot 'assets\gameboost-icon.ico'
if (Test-Path $iconPath) {
    try {
        $script:appIcon = [Drawing.Icon]::new($iconPath)
        $form.Icon = $script:appIcon
    } catch { }
}
$form.Add_HandleCreated({ [GameBoostWindow]::UseDarkTitleBar($form.Handle, $script:theme.Sidebar) })

$script:sidebar = [Windows.Forms.Panel]::new()
$script:sidebar.Location = [Drawing.Point]::new(0, 0)
$script:sidebar.Size = [Drawing.Size]::new(216, 720)
$script:sidebar.BackColor = $script:theme.Sidebar
$form.Controls.Add($script:sidebar)

$logo = New-UiLabel $script:sidebar 'GAMEBOOST' 20 24 -Font $script:fonts.Logo -Color $script:theme.Accent
[void](New-UiLabel $script:sidebar 'LITE' ($logo.Left + $logo.PreferredWidth + 2) 33 -Font $script:fonts.Small -Color $script:theme.SubText)
[void](New-UiLabel $script:sidebar 'Oyun performans merkezi' 22 54 -Font $script:fonts.Small -Color $script:theme.Muted)

$script:sidebarStatus = New-UiLabel $script:sidebar '●  NORMAL MOD' 22 628 180 22 -Font $script:fonts.BodyBold -Color $script:theme.Blue
$script:sidebarMetrics = New-UiLabel $script:sidebar '' 22 652 186 20 -Font $script:fonts.Small -Color $script:theme.SubText
$script:sidebarFooter = New-UiLabel $script:sidebar 'v2.0 · değişiklikler geri alınır' 22 684 186 20 -Font $script:fonts.Small -Color $script:theme.Muted

Build-HomePage
Build-ModesPage
Build-TweaksPage
Build-LivePage
Build-ClosePage
Build-DisplayPage
Build-AudioPage
Build-NetworkPage
Build-DevicesPage
Build-SystemPage
Build-ScorePage
Build-CarePage
Build-HudPage

# ---------------------------------------------------------------- timers and hotkeys

# Live data refreshes only while the window is in front; nothing runs while you play.
$script:lastUiRefreshUtc = [datetime]::MinValue
function Update-VisibleData {
    $script:lastUiRefreshUtc = [datetime]::UtcNow
    Update-Metrics
    if ($script:currentPage -eq 'live') { Refresh-ProcessGrid }
}

$script:uiTimer = [Windows.Forms.Timer]::new()
$script:uiTimer.Interval = 6000
$script:uiTimer.Add_Tick({ if (Test-WindowInUse) { Update-VisibleData } })
$script:uiTimer.Start()

$form.Add_Activated({
    if (([datetime]::UtcNow - $script:lastUiRefreshUtc).TotalSeconds -ge 3) { Update-VisibleData }
})

$script:boostTimer = [Windows.Forms.Timer]::new()
$script:boostTimer.Interval = 3000
$script:boostTimer.Add_Tick({ Invoke-BoostTick })

# Runs only while "Oyun algılanınca otomatik BOOST" is on and BOOST is off.
$script:autoBoostTimer = [Windows.Forms.Timer]::new()
$script:autoBoostTimer.Interval = 5000
$script:autoBoostTimer.Add_Tick({ Invoke-AutoBoostWatch })

# Modes and notices: cheap checks every 5 s, one process list a minute (see Modes.ps1).
$script:modesTimer = [Windows.Forms.Timer]::new()
$script:modesTimer.Interval = 5000
$script:modesTimer.Add_Tick({ Invoke-ModesTick })
$script:modesTimer.Start()

$script:hotkeyFilter = [GameBoostHotkeyFilter]::new()
$script:hotkeyFilter.Add_Pressed({
    param($sender, $eventArgs)
    if ($eventArgs.Id -eq 5101) { Invoke-OverlayCommand 'Show10' }
    elseif ($eventArgs.Id -eq 5102) { Invoke-OverlayCommand 'Toggle' }
})
[Windows.Forms.Application]::AddMessageFilter($script:hotkeyFilter)
[void]$form.Handle
Set-OverlayHotkeys $script:overlayEnabled

$script:showSignal = [GameBoostShowSignal]::new('Local\GameBoostLite.Show', $form)
$script:showSignal.Add_Signaled({ Show-FromTray })
New-TrayIcon

# X hides to the tray. Only Çıkış, Windows shutdown or Task Manager really end the app (and undo BOOST).
$script:exitRequested = $false
$form.Add_FormClosing({
    param($sender, $e)
    if (-not $script:exitRequested -and $e.CloseReason -eq [Windows.Forms.CloseReason]::UserClosing) {
        $e.Cancel = $true
        Hide-ToTray
        return
    }
    if ($script:boosted) { Restore-NormalMode 'Uygulama kapandı; normal moda dönüldü.' }
    Stop-AllModes
})

# Network details need a CIM query; read them once, shortly after the window appears.
$form.Add_Shown({
    Start-DelayedAction 1200 {
        $script:insightCache.Network = Get-NetworkInfo
        $script:insightCache.NetworkAlerts = @(Get-NetworkAlerts $script:insightCache.Network)
        if ($script:currentPage -in 'home', 'care') { Update-HomeAlerts }
    }
})

Update-BoostUi
Add-Log 'Hazır. Oyundan önce açık çalışmalarını kaydet.'
if ($script:staleBoostRestored) { Add-Log 'Beklenmeyen kapanıştan kalan ayarlar geri yüklendi.' }
if ($script:staleModesRestored) { Add-Log 'Beklenmeyen kapanıştan kalan İndirme / Tasarruf ayarları geri alındı.' }
if ($Restart) { Add-Log 'Yeniden başlatıldı.' }
if ($script:options.AutoBoost) { Add-Log 'Otomatik BOOST açık: desteklenen bir oyun algılanınca başlar.' }
Show-Page 'home'
Update-AutoBoostWatcher
if ($script:startHidden) {
    Add-Log 'Windows ile başladı; tepside bekliyor.'
    Start-DelayedAction 4000 { if (-not $form.Visible) { [GameBoostEngine]::TrimCurrentProcess() } }
}
[GC]::Collect()

# Application.Run (not ShowDialog): hiding the window must not end the message loop.
try {
    [Windows.Forms.Application]::Run($form)
} finally {
    if ($script:boosted) { Restore-NormalMode 'Uygulama kapandı; normal moda dönüldü.' }
    Stop-AllModes
    Stop-SessionMonitors
    if ($script:modesTimer) { $script:modesTimer.Stop(); $script:modesTimer.Dispose() }
    if ($script:speedTest) { $script:speedTest.Cancel() }
    if ($script:trayIcon) { $script:trayIcon.Visible = $false; $script:trayIcon.Dispose() }
    if ($script:showSignal) { $script:showSignal.Dispose() }
    if ($script:uiTimer) { $script:uiTimer.Stop(); $script:uiTimer.Dispose() }
    if ($script:boostTimer) { $script:boostTimer.Stop(); $script:boostTimer.Dispose() }
    if ($script:autoBoostTimer) { $script:autoBoostTimer.Stop(); $script:autoBoostTimer.Dispose() }
    if ($script:pollTimer) { $script:pollTimer.Stop(); $script:pollTimer.Dispose() }
    Set-OverlayHotkeys $false
    if ($script:hotkeyFilter) { [Windows.Forms.Application]::RemoveMessageFilter($script:hotkeyFilter) }
    if ($script:appIcon) { $script:appIcon.Dispose() }
    try { $script:instanceMutex.ReleaseMutex() } catch { }
    $script:instanceMutex.Dispose()
}
