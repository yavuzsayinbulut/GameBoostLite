# Run with Windows PowerShell 5.1 -NoProfile -STA -File tests\Safety.Tests.ps1.
# Every system-changing seam is replaced. Only a GUID-named temporary directory is written, plus a
# GUID-named HKCU\Software\GameBoostLiteTests-* key for the recent-items check (removed afterwards).
$ErrorActionPreference = 'Stop'
$appRoot = Split-Path $PSScriptRoot -Parent
$testRoot = Join-Path $PSScriptRoot ('.fixtures-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
$oldLocal = $env:LOCALAPPDATA
$env:LOCALAPPDATA = $testRoot
$script:checks = 0
function Assert { param([bool]$Condition, [string]$Message) if (-not $Condition) { Write-Output ($script:log -join [Environment]::NewLine); throw "FAIL: $Message" }; $script:checks++; Write-Output "PASS: $Message" }
try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    Add-Type -Path (Join-Path $appRoot 'lib\GameBoostNative.cs') -ReferencedAssemblies System.Windows.Forms.dll,System.Drawing.dll
    foreach ($name in 'Boost','Insights','Session','Modes','Health') { . (Join-Path $appRoot "lib\$name.ps1") }
    New-Item -ItemType Directory -Path $script:settingsDirectory -Force | Out-Null
    $originalTracking = ${function:Update-DownloadTracking}
    $originalActiveDownloads = ${function:Get-ActiveDownloads}
    $originalStartSleep = ${function:Start-SleepCountdown}
    $script:clock = [datetime]::UtcNow
    $script:log = [Collections.Generic.List[string]]::new()
    function Get-ModesNow { return $script:clock }
    function Add-Log { param($Text) $script:log.Add([string]$Text) }
    function Update-ModesUi { }
    function Update-ModesLive { }
    function Update-HomeAlerts { }
    function Test-ModesVisible { return $false }
    function Send-SmartNotice { return $true }
    function Set-KeepAwake { param([bool]$On) $script:awake = $On }
    function Get-ConnectionProfileInfo { return $null }
    function Get-NetworkTotals { return @($script:rx, $script:tx) }
    function Get-ActivePowerScheme { return $script:activePlan }
    function Set-PowerScheme { param($Scheme) if (-not $script:failPower) { $script:activePlan = $Scheme } }
    function Read-PlanValue { param($Scheme,$Subgroup,$Setting,$PluggedIn) return $script:planValue }
    function Write-PlanValue { param($Scheme,$Subgroup,$Setting,$PluggedIn,$Value) $script:planWrites++; if ($script:failWrite) { return $false }; $script:planValue = $Value; return $true }
    function Update-ActivePlan { }
    function Update-DownloadConnections { }
    function New-PlanSpeedTest { throw 'Unexpected active network test' }
    function Test-WifiConnected { return $true }
    function Test-SleepBusy { return $script:busy }
    function Get-IdleSeconds { return $script:idle }
    function Get-SleepNetworkSnapshot { if (-not $script:network) { return $null }; return [pscustomobject]@{ Ids=$script:network.Ids; Received=$script:network.Received; Sent=$script:network.Sent } }
    function Invoke-SystemSleep { $script:sleeps++; return $script:sleepResult }
    function Get-ActivitySample { return [pscustomobject]@{ Snapshot=@(); Busy=@() } }
    function Get-Brightness { return $script:light }
    function Set-Brightness { param($Level) if ($script:failLight) { return $false }; $script:light=$Level; return $true }
    function Get-ModeMonitors { return @($script:monitor) }
    function Set-DisplayRefresh { param($Gdi,$Hz) $script:displayWrites++; if ($script:failDisplay) { return $false }; $script:monitor.Refresh=$Hz; return $true }
    function Restore-ModeEfficiency { param($Target) return -not $script:failEfficiency }
    function Get-ActiveDownloads { return @($script:activeDownloads) }
    function Reset-Case {
        $script:download=$null; $script:saver=$null; $script:sleepCountdown=$null
        $script:options.DownloadSleepAfter=$false; $script:options.DownloadAutoStop=$true
        $script:boosted=$false; $script:modeRecoveryPending=$false; $script:runtimeRecoveryPending=$false
        $script:speedTest=$null; $script:planTest=$null; $script:lastSpeedResult=$null
        $script:rx=[int64]0; $script:tx=[int64]0; $script:sleeps=0; $script:idle=1000
        $script:busy=$false; $script:planValue=0; $script:planWrites=0; $script:activePlan='base'
        $script:failWrite=$false; $script:failPower=$false; $script:failLight=$false; $script:failDisplay=$false; $script:failEfficiency=$false
        $script:sleepResult=$true; $script:activeDownloads=@(); $script:displayWrites=0
        $script:network=[pscustomobject]@{ Ids='ethernet'; Received=[int64]0; Sent=[int64]0 }
        $script:monitor=[pscustomobject]@{ GdiName='DISPLAY1'; Refresh=60; Width=1920; Height=1080; Internal=$true; Cloned=$false; RatesAtResolution=@(60,144) }
    }
    function New-ReadyDownload {
        Start-DownloadMode
        $script:download.TrackingOk=$true; $script:download.SawTracked=$true
        $script:download.Completed.Add('verified game')
        $script:download.QuietSeconds=120
        $script:options.DownloadSleepAfter=$true
    }
    function Tick-Countdown {
        param([int]$Seconds=60)
        for ($i=0; $i -lt $Seconds; $i+=5) { $script:clock=$script:clock.AddSeconds(5); Update-SleepCountdown }
    }

    Reset-Case; Start-DownloadMode
    $script:options.DownloadSleepAfter=$true
    Complete-DownloadMode 'idle, unconfirmed' 'Traffic stopped'
    Assert (-not $script:sleepCountdown -and $null -ne $script:download -and $script:awake) 'Unconfirmed idle traffic neither sleeps nor releases keep-awake'
    $script:download.BusySeconds=130; $script:download.QuietSeconds=120
    $script:clock=$script:clock.AddSeconds(5); Update-DownloadMode
    Assert (-not $script:sleepCountdown -and $null -ne $script:download) 'Real idle-detection path retains download protection'
    $script:download.QuietSeconds=100; $script:rx+=100000; $script:clock=$script:clock.AddSeconds(5); Update-DownloadMode
    Assert ($script:download.QuietSeconds -eq 0) 'Slow transfer resets quiet interval'
    $script:download.PlanChecked=$false; Start-PlanSpeedCheck
    Assert ($script:download.PlanChecked -and -not $script:planTest) 'Download mode does not launch a bandwidth test'

    Reset-Case; New-ReadyDownload; Complete-DownloadMode 'done' 'Done' -Confirmed
    Assert ($null -ne $script:sleepCountdown -and $script:awake) 'Confirmed completion keeps awake through countdown'
    Tick-Countdown
    Assert ($script:sleeps -eq 1 -and -not $script:download -and -not $script:options.DownloadSleepAfter) 'Verified idle batch requests sleep once and consumes permission'
    foreach ($condition in 'upload','download','interface','unknown','input','game','timer-gap','new-download','scan-error','option-off') {
        Reset-Case; New-ReadyDownload; Complete-DownloadMode 'done' 'Done' -Confirmed
        switch ($condition) {
            'upload' { $script:network.Sent=5MB }
            'download' { $script:network.Received=5MB }
            'interface' { $script:network.Ids='vpn' }
            'unknown' { $script:network=$null }
            'input' { $script:idle=0 }
            'game' { $script:busy=$true }
            'timer-gap' { $script:clock=$script:clock.AddMinutes(2) }
            'new-download' { $script:download.Tracked.new=[pscustomobject]@{ Name='new' } }
            'scan-error' { $script:download.TrackingOk=$false }
            'option-off' { $script:options.DownloadSleepAfter=$false }
        }
        Tick-Countdown
        Assert ($script:sleeps -eq 0 -and -not $script:sleepCountdown -and $null -ne $script:download) "Countdown cancels on $condition and keeps transfer protection"
    }
    # Windows never goes fully silent: a few KB/s at rest must neither cancel sleep nor reset quiet time.
    Reset-Case; New-ReadyDownload; Complete-DownloadMode 'done' 'Done' -Confirmed
    $script:network.Received=40KB; $script:network.Sent=30KB; Tick-Countdown
    Assert ($script:sleeps -eq 1) 'Background traffic at rest (~1 KB/s) does not cancel the countdown'
    Reset-Case; Start-DownloadMode
    for ($i=0; $i -lt 25; $i++) { $script:rx+=1500; $script:tx+=1200; $script:clock=$script:clock.AddSeconds(5); Update-DownloadMode }
    Assert ($script:download.QuietSeconds -ge 120) 'Background traffic at rest counts as a quiet line'
    # Steam unpacks for minutes without traffic, so "not progressing" can come before the real finish.
    Reset-Case; Start-DownloadMode
    $script:download.TrackingOk=$true; $script:download.SawTracked=$true; $script:download.Notified=$true
    $script:download.Completed.Add('Steam · Fixture'); $script:download.QuietSeconds=120
    $script:clock=$script:clock.AddSeconds(5); Update-DownloadMode
    Assert (-not $script:download) 'Verified completion is announced after an earlier stall notice'
    Reset-Case; $script:options.DownloadAutoStop=$false; Start-DownloadMode
    $script:download.TrackingOk=$true; $script:download.SawTracked=$true
    $script:download.Completed.Add('Steam · Fixture'); $script:download.QuietSeconds=120; $script:download.BusySeconds=130
    $script:noticeCalls=0
    function Send-SmartNotice { $script:noticeCalls++; return $true }
    for ($i=0; $i -lt 30; $i++) { $script:clock=$script:clock.AddSeconds(5); Update-DownloadMode }
    function Send-SmartNotice { return $true }
    Assert ($null -ne $script:download -and $script:noticeCalls -eq 1) 'Completion is announced once, with no extra unverified notice after it'

    Reset-Case; New-ReadyDownload; Complete-DownloadMode 'done' 'Done' -Confirmed
    $script:sleepResult=$false; Tick-Countdown
    Assert (($script:log -join ' ') -match 'Windows uyku isteğini kabul etmedi') 'Sleep rejection is reported honestly'

    Reset-Case
    $downloadDir=Join-Path $testRoot 'downloads'; New-Item -ItemType Directory -Path $downloadDir | Out-Null
    $item=[pscustomobject]@{ Key='file:test'; Source='Browser'; Name='test'; Path=(Join-Path $downloadDir 'test.crdownload'); Done=3; FirstSeenLocal=(Get-Date).AddMinutes(-1); FinalAbsent=$true }
    Set-Content -LiteralPath (Join-Path $downloadDir 'unrelated.txt') -Value 'unrelated'
    Assert ($null -eq (Resolve-FinishedDownload $item)) 'Unrelated new file cannot confirm a browser download'
    Set-Content -LiteralPath (Join-Path $downloadDir 'test') -Value 'data'
    Assert ($null -ne (Resolve-FinishedDownload $item)) 'Exact new final file can confirm completion'
    $item.FinalAbsent=$false
    Assert ($null -eq (Resolve-FinishedDownload $item)) 'Preexisting final file cannot confirm completion'
    $manifest=Join-Path $testRoot 'appmanifest.acf'
    Set-Content -LiteralPath $manifest -Value '"StateFlags" "1024" "BytesDownloaded" "100" "BytesToDownload" "100"'
    $steam=[pscustomobject]@{ Key='steam:1'; Source='Steam'; Name='Fixture'; Path=$manifest }
    Assert ($null -eq (Resolve-FinishedDownload $steam)) 'Steam bytes complete while installing does not confirm completion'
    Set-Content -LiteralPath $manifest -Value '"StateFlags" "4"'
    Assert ($null -ne (Resolve-FinishedDownload $steam)) 'Steam installed state confirms completion'
    $epic=Join-Path $testRoot 'fixture.item'; Set-Content -LiteralPath $epic -Value '{}'
    Assert ($null -eq (Resolve-FinishedDownload ([pscustomobject]@{ Source='Epic'; Path=$epic }))) 'Missing Epic completion field is unknown'
    $epicDir=Join-Path $testRoot 'epic-manifests'; New-Item -ItemType Directory -Path $epicDir | Out-Null
    Set-Content -LiteralPath (Join-Path $epicDir 'broken.item') -Value '{broken'
    function Get-SteamLibraries { return @() }
    function Get-EpicManifestFolder { return $epicDir }
    function Get-DownloadsFolder { return $downloadDir }
    Set-Item -Path Function:Get-ActiveDownloads -Value $originalActiveDownloads
    $null=Get-ActiveDownloads
    Assert (-not $script:downloadScanOk) 'Unreadable manifest prevents a trusted completion scan'
    function Get-ActiveDownloads { return @($script:activeDownloads) }
    Reset-Case; Start-DownloadMode
    $script:download.Tracked['file:test']=$item
    Update-DownloadTracking
    Assert ($script:download.Unresolved.Count -eq 1) 'Disappeared but unconfirmed item blocks entire batch completion'
    $script:download.Completed.Add('other game'); $script:download.SawTracked=$true; $script:download.QuietSeconds=130
    $script:clock=$script:clock.AddSeconds(5); Update-DownloadMode
    Assert ($null -ne $script:download -and -not $script:sleepCountdown) 'One completed item cannot hide another unconfirmed item'

    Reset-Case
    $entry=New-PlanEntry 'base' 'sub' 'setting' $true 3 0
    $script:planValue=2
    Assert ((Restore-PlanEntries @($entry)) -and $script:planValue -eq 2 -and $script:planWrites -eq 0) 'User power-plan changes are preserved'
    $script:planValue=0; $script:failWrite=$true
    Assert (-not (Restore-PlanEntries @($entry))) 'Failed power restoration reports failure'
    $script:failWrite=$false
    Assert ((Restore-PlanEntries @($entry)) -and $script:planValue -eq 3) 'Power restoration verifies original value'
    Reset-Case; $script:planValue=3; Start-DownloadMode; $script:failWrite=$true
    Stop-DownloadMode
    Assert ($null -ne $script:download -and (Test-Path -LiteralPath $script:modesStateFile)) 'Failed download restoration retains mode and backup'
    $script:failWrite=$false; Stop-DownloadMode
    Assert (-not $script:download -and -not (Test-Path -LiteralPath $script:modesStateFile)) 'Verified retry clears backup'
    Set-Content -LiteralPath $script:modesStateFile -Value '{corrupt'
    Assert (-not (Restore-StaleModes)) 'Corrupt modes backup does not report success'
    Assert ((Test-Path -LiteralPath $script:modesStateFile) -and $script:modeRecoveryPending) 'Corrupt backup remains available for recovery'
    Start-DownloadMode
    Assert (-not $script:download) 'New mode cannot overwrite a pending recovery'
    Remove-Item -LiteralPath $script:modesStateFile
    Reset-Case; $script:activePlan='user-chosen'
    Assert ((Restore-BoostPowerScheme 'base') -and $script:activePlan -eq 'user-chosen') 'BOOST preserves a later user-selected power plan'
    $script:activePlan=$script:highPerformanceGuid; $script:failPower=$true
    Assert (-not (Restore-BoostPowerScheme 'base')) 'BOOST detects failed power restore'
    Reset-Case; $script:efficiencyTargets=@{ one=[pscustomobject]@{Id=123;CreateTime=42;Priority=32;Control=0;State=0;Name='fixture'} }; $script:failEfficiency=$true
    Assert ((Restore-EfficiencyTargets) -eq 0 -and $script:efficiencyTargets.Count -eq 1) 'Failed efficiency restore retains original state'
    $script:failEfficiency=$false
    Assert ((Restore-EfficiencyTargets) -eq 1 -and $script:efficiencyTargets.Count -eq 0) 'Successful efficiency retry releases original state'
    $display=[pscustomobject]@{ Gdi='DISPLAY1'; From=144; To=60; Width=1920; Height=1080 }
    $script:monitor.Width=1280
    Assert ((Restore-ModeDisplay $display) -and $script:displayWrites -eq 0) 'Display restoration preserves a later resolution change'
    $script:monitor.Width=1920; $script:failDisplay=$true
    Assert (-not (Restore-ModeDisplay $display)) 'Display failure retains recovery state'
    $script:failDisplay=$false
    Assert ((Restore-ModeDisplay $display) -and $script:monitor.Refresh -eq 144) 'Display refresh returns to captured value'
    $script:light=70
    Assert ((Restore-ModeBrightness ([pscustomobject]@{Old=80;New=30})) -and $script:light -eq 70) 'User brightness change is preserved'
    $script:light=30; $script:failLight=$true
    Assert (-not (Restore-ModeBrightness ([pscustomobject]@{Old=80;New=30}))) 'Brightness failure is not discarded'

    $script:options.DownloadSleepAfter=$true; Save-CustomSettings -Quiet
    $saved=Get-Content -LiteralPath $script:settingsFile -Raw | ConvertFrom-Json
    Assert ($null -eq $saved.Options.DownloadSleepAfter) 'Sleep permission is not persisted'
    Set-Content -LiteralPath $script:settingsFile -Value '{"Options":{"DownloadSleepAfter":true,"AutoBoost":false}}'
    Load-CustomSettings
    Assert (-not $script:options.DownloadSleepAfter) 'Legacy saved sleep permission is ignored'

    Reset-Case
    $modeTemp="$($script:modesStateFile).tmp"
    New-Item -ItemType Directory -Path $modeTemp -Force | Out-Null
    $script:planValue=3
    Start-DownloadMode
    Assert (-not $script:download -and $script:planWrites -eq 0) 'Backup write failure prevents all download power changes'
    Remove-Item -LiteralPath $modeTemp
    Set-Content -LiteralPath $script:modesStateFile -Value '{}'
    Assert (-not (Restore-StaleModes) -and (Test-Path -LiteralPath $script:modesStateFile)) 'Invalid backup schema is retained'
    Remove-Item -LiteralPath $script:modesStateFile
    Set-Content -LiteralPath $script:runtimeStateFile -Value '{}'
    Assert (-not (Restore-StaleBoostState) -and (Test-Path -LiteralPath $script:runtimeStateFile)) 'Invalid BOOST backup schema is retained'
    Remove-Item -LiteralPath $script:runtimeStateFile
    Reset-Case
    function Get-EfficiencyBackup { param($Process) return [pscustomobject]@{Id=$Process.Id;CreateTime=$Process.CreateTime;Priority=32;Control=0;State=0;Name=$Process.Name} }
    function Apply-EfficiencyBackup {
        param($Target)
        $script:efficiencyApplied++
        $saved=Get-Content -LiteralPath $script:runtimeStateFile -Raw | ConvertFrom-Json
        if (@($saved.Efficiency | Where-Object Id -eq $Target.Id).Count -ne 1) { throw 'Efficiency changed before journal was written' }
        return $true
    }
    $script:efficiencyApplied=0; $script:efficiencyTargets=@{}
    $fake=[pscustomobject]@{Id=123;CreateTime=42;Name='fixture';Key='123:42'}
    $runtimeTemp="$($script:runtimeStateFile).tmp"
    New-Item -ItemType Directory -Path $runtimeTemp -Force | Out-Null
    Assert (-not (Add-EfficiencyTarget $fake) -and $script:efficiencyApplied -eq 0) 'BOOST never changes efficiency without a saved original'
    Remove-Item -LiteralPath $runtimeTemp
    Assert ((Add-EfficiencyTarget $fake) -and $script:efficiencyApplied -eq 1) 'Efficiency journal exists before native mutation'

    function Get-OmenHub { return $null }
    function Get-NvidiaApp { return $null }
    function Get-SessionHistory { return @($script:historyFixture) }
    function Get-FullChargeDays { return 0 }
    function Get-BatteryHealth { return $null }
    $script:historyFixture=@([pscustomobject]@{ Date=(Get-Date).ToString('o'); Games=@('Game A'); Minutes=5; GpuMaxTemp=85; Hitches=4; HitchCauses=@('defender','wifi'); LimitSeconds=0 },[pscustomobject]@{ Date=(Get-Date).AddDays(-8).ToString('o'); Games=@('Game B'); Minutes=5; GpuMaxTemp=60; Hitches=$null; HitchCauses=@(); LimitSeconds=0 })
    $script:driverInfo=@([pscustomobject]@{Name='AMD Radeon';Version='fixture';Date=(Get-Date).AddDays(-200);Days=200})
    $summary=(Get-WeeklySummary).Lines -join ' '
    Assert ($summary -notmatch 'fanları temizlet|en sık neden|→ güncelle') 'Weekly summary does not infer maintenance or an available driver from unrelated data'
    Assert ($summary -match 'olası ilişkiler' -and $summary -match 'dahil değildir') 'Weekly summary distinguishes evidence and coverage'
    $fixes=@(Get-FixItems)
    Assert (-not ($fixes | Where-Object { $_.Button -eq 'Hariç tut' })) 'No Defender exclusion action is offered'
    Assert (($fixes | Where-Object Title -like '*Defender*').Detail -match 'tek başına kanıtlamaz') 'Defender correlation is not presented as a proven cause'
    $driverFix=$fixes | Where-Object Title -like 'Sürücü tarihi*'
    Assert ($driverFix.Button -eq 'Güncellemeler') 'Non-NVIDIA GPU is not sent to NVIDIA tooling'
    $unsafe=Get-ChildItem (Join-Path $appRoot 'lib') -Filter '*.ps1' | Select-String -Pattern 'Add-MpPreference\s+-ExclusionPath'
    Assert (-not $unsafe) 'Production code cannot add Defender path exclusions'

    # Game detection: launcher services are not games (they started automatic BOOST with no game).
    Assert (-not [GameBoostEngine]::IsGameLibraryPath('C:\Program Files (x86)\Epic Games\Epic Online Services\EpicOnlineServicesInstallHelper.exe')) 'Epic Online Services helper is not a game'
    Assert (-not [GameBoostEngine]::IsGameLibraryPath('C:\Program Files\Epic Games\Fortnite\Engine\Extras\Redist\en-us\UEPrereqSetup_x64.exe')) 'Game prerequisite installers are not games'
    Assert ([GameBoostEngine]::IsGameLibraryPath('D:\SteamLibrary\steamapps\common\Max Payne 3\Max Payne 3\MaxPayne3.exe') -and
        [GameBoostEngine]::IsGameLibraryPath('C:\Program Files\Epic Games\GTAV\GTA5.exe')) 'Steam and Epic games are still detected'
    Assert ($script:excludedNames.Contains('EpicOnlineServicesInstallHelper')) 'Epic helper is excluded by name too'

    # Crash log: written, and rotated instead of growing without limit.
    $crashLog=Join-Path $testRoot 'crash.log'
    [GameBoostCrashLog]::Install($crashLog)
    [GameBoostCrashLog]::Write('fixture error')
    Assert ((Get-Content -LiteralPath $crashLog -Raw) -match 'fixture error') 'Crash log records caught errors'

    # Shortcuts: $null from PowerShell arrives as "" and must leave a field unchanged.
    $shell=New-Object -ComObject WScript.Shell
    $lnk=Join-Path $testRoot 'fixture.lnk'
    $link=$shell.CreateShortcut($lnk); $link.TargetPath="$env:SystemRoot\System32\conhost.exe"; $link.Arguments='--headless fixture.ps1'
    $link.WorkingDirectory=$testRoot; $link.IconLocation='Z:\moved-away\old.ico,0'; $link.Save()
    $newIcon=Join-Path $appRoot 'assets\gameboost-icon.ico'
    Assert ([GameBoostShell]::WriteShortcut($lnk, $null, $null, $null, $newIcon, $null, 'GameBoostLite.Tests')) 'Shortcut update succeeds'
    $read=[GameBoostShell]::ReadShortcut($lnk)
    Assert ($read[0] -like '*conhost.exe' -and $read[1] -eq '--headless fixture.ps1' -and $read[2] -eq $testRoot) 'Shortcut update keeps target, arguments and folder'
    Assert ($read[3] -eq $newIcon -and $read[4] -eq 'GameBoostLite.Tests') 'Shortcut gets the new icon and taskbar ID (read back intact)'
    Assert (-not [GameBoostShell]::WriteShortcut((Join-Path $testRoot 'empty.lnk'), $null, 'x', $null, $null, $null, $null) -and
        -not (Test-Path -LiteralPath (Join-Path $testRoot 'empty.lnk'))) 'A shortcut without a target is never written'

    # Recent items: only list entries in the given keys go; files, other keys and a "No" answer are respected.
    $regRoot="HKCU:\Software\GameBoostLiteTests-$([guid]::NewGuid().ToString('N'))"
    try {
        $script:explorerKey=$regRoot
        New-Item -Path "$regRoot\RunMRU" -Force | Out-Null
        New-ItemProperty -Path "$regRoot\RunMRU" -Name 'a' -Value 'notepad\1' | Out-Null
        New-ItemProperty -Path "$regRoot\RunMRU" -Name 'MRUList' -Value 'a' | Out-Null
        New-Item -Path "$regRoot\RecentDocs\.txt" -Force | Out-Null
        New-ItemProperty -Path "$regRoot\RecentDocs\.txt" -Name '0' -Value ([byte[]](1,2,3)) -PropertyType Binary | Out-Null
        New-Item -Path "$regRoot\Unrelated" -Force | Out-Null
        New-ItemProperty -Path "$regRoot\Unrelated" -Name 'Keep' -Value 'yes' | Out-Null
        $recentDir=Join-Path $testRoot 'Recent'; New-Item -ItemType Directory -Path $recentDir | Out-Null
        $realFile=Join-Path $testRoot 'document.txt'; Set-Content -LiteralPath $realFile -Value 'user data'
        Set-Content -LiteralPath (Join-Path $recentDir 'document.txt.lnk') -Value 'fixture'
        function Get-RecentShortcutFiles { return @(Get-ChildItem -LiteralPath $recentDir -Filter '*.lnk' -File) }
        $script:shellClears=0
        function Clear-ShellRecentDocuments { $script:shellClears++ }
        $script:answer='No'
        function Show-UiMessage { param($Text) $script:lastMessage=$Text; return $script:answer }
        Invoke-RecentItemsCleanup
        Assert ($script:shellClears -eq 0 -and (Get-ItemProperty -Path "$regRoot\RunMRU").a -and @(Get-RecentShortcutFiles).Count -eq 1) 'Answering No changes nothing'
        Assert ($script:lastMessage -match 'Çalıştır' -and $script:lastMessage -match 'Dosyaların kendisi silinmez') 'Confirmation lists what goes and what stays'
        $script:answer='Yes'
        Invoke-RecentItemsCleanup
        Assert ($script:shellClears -eq 1 -and @(Get-RecentShortcutFiles).Count -eq 0) 'Recent file shortcuts are cleared'
        Assert (@((Get-Item "$regRoot\RunMRU").GetValueNames()).Count -eq 0 -and @((Get-Item "$regRoot\RecentDocs\.txt").GetValueNames()).Count -eq 0) 'History lists are emptied'
        Assert ((Test-Path "$regRoot\RecentDocs\.txt") -and (Get-ItemProperty -Path "$regRoot\Unrelated").Keep -eq 'yes') 'List keys and unrelated values stay'
        Assert ((Test-Path -LiteralPath $realFile)) 'The documents themselves are never deleted'
    } finally { Remove-Item -Path $regRoot -Recurse -Force -ErrorAction SilentlyContinue }
    Write-Output "RESULT: $script:checks checks passed; native compile passed; all system actions mocked."
} finally {
    $env:LOCALAPPDATA=$oldLocal
    # Keep fixtures for inspection; no production app-data path was used.
    Write-Output "Isolated fixtures: $testRoot"
}
