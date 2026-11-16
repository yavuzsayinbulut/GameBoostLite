# Off-screen WinForms checks: no app instance, mutex, tray, timers or system changes are started.
$ErrorActionPreference='Stop'
$appRoot=Split-Path $PSScriptRoot -Parent
$testRoot=Join-Path $PSScriptRoot ('.ui-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
$env:LOCALAPPDATA=$testRoot
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -Path (Join-Path $appRoot 'lib\GameBoostNative.cs') -ReferencedAssemblies System.Windows.Forms.dll,System.Drawing.dll
foreach ($name in 'Ui','Boost','Insights','Pages','Session','Tweaks','Score','Modes','Health') { . (Join-Path $appRoot "lib\$name.ps1") }
function Add-Log { param($Text) }
function Get-DownloadChecks { return @() }
function Get-PowerChecks { return @() }
function Get-ActiveDownloads { return @() }
function Get-Brightness { return -1 }
function Get-ModeMonitors { return @() }
function Get-BatteryEstimate { return $null }
function Get-OmenHub { return $null }
function Get-NvidiaApp { return $null }
function Get-BatteryHealth { return $null }
function Get-FullChargeDays { return 0 }
function Get-SessionHistory { return @([pscustomobject]@{Date=(Get-Date).ToString('o');Minutes=30;Games=@('Fixture');Hitches=4;HitchCauses=@('defender','wifi');GpuMaxTemp=70;LimitSeconds=0}) }
function Set-KeepAwake { throw 'UI test must not change sleep inhibition' }
function Set-PowerScheme { throw 'UI test must not change power plans' }
function Write-PlanValue { throw 'UI test must not write power values' }
function Invoke-SystemSleep { throw 'UI test must not sleep' }
$form=[Windows.Forms.Form]::new()
$form.ClientSize=[Drawing.Size]::new(1180,720)
$form.BackColor=$script:theme.Window
$script:sidebar=[Windows.Forms.Panel]::new()
$script:sidebar.Size=[Drawing.Size]::new(216,720)
$form.Controls.Add($script:sidebar)
try {
    Build-ModesPage
    Build-CarePage
    Update-SaverTab
    Update-ModesUi
    if ($script:downloadSleepToggle.Enabled) { throw 'Sleep toggle must be disabled without a download session' }
    $script:download=[pscustomobject]@{
        Started=[datetime]::UtcNow; RateDown=0.0; RateUp=0.0; Received=100; Sent=0; PeakDown=1
        Profile=$null; Samples=[Collections.Generic.List[object]]::new(); WifiDownSince=$null
        Tracked=@{}; Completed=[Collections.Generic.List[string]]::new(); Connections=''; AutoReason=''
        Unresolved=[Collections.Generic.HashSet[string]]::new(); TrackingOk=$true
    }
    $script:options.DownloadSleepAfter=$true
    $script:sleepCountdown=[pscustomobject]@{Started=[datetime]::UtcNow;Seconds=60}
    Update-ModesUi
    if (-not $script:downloadSleepToggle.Checked -or -not $script:downloadSleepToggle.Enabled) { throw 'Countdown controls are not synchronized' }
    if ($script:downloadStatus.Text -notmatch 'Uyku:') { throw 'Countdown is hidden by the active download status' }
    Update-WeeklyPage
    Update-FixesPage
    Select-UiTab $script:careTabs 3
    if ($script:weeklyBox.Text -notmatch 'ÖZETİ') { throw 'Weekly summary missing' }
    if ($script:fixesPanel.Controls.Count -lt 4) { throw 'Fix recommendations missing' }
    # Draw just the page panels, without displaying a top-level window.
    foreach ($key in @('modes','care')) {
        $entry=$script:pages[$key]
        $panel=$entry.Panel
        if (-not $panel) { $panel=$entry.Page }
        if (-not $panel) { throw "Unknown page container: $key" }
        # A detached Panel has no hidden Form ancestor; drawing it still opens no window.
        $panel.Parent=$null
        $panel.Visible=$true
        $panel.CreateControl()
        $bitmap=[Drawing.Bitmap]::new($panel.Width,$panel.Height)
        try { $panel.DrawToBitmap($bitmap,[Drawing.Rectangle]::new(0,0,$panel.Width,$panel.Height)); $bitmap.Save((Join-Path $testRoot "$key.png"),[Drawing.Imaging.ImageFormat]::Png) }
        finally { $bitmap.Dispose(); $panel.Dispose() }
    }
    Write-Output 'PASS: modes, per-session sleep toggle, countdown, weekly summary and fixes UI'
    Write-Output "Off-screen renders: $testRoot"
} finally {
    $script:pollTimer.Stop(); $script:pollTimer.Dispose()
    $form.Dispose()
}
