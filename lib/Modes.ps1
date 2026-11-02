# İndirme modu, Tasarruf / Süper tasarruf and smart notifications.
# Every change is written to modes-state.json before it is made and put back exactly when the mode
# ends, when the app closes, or (after a crash) at the next start. Nothing is closed or killed.

$script:modesStateFile = Join-Path $script:settingsDirectory 'modes-state.json'
$script:download = $null
$script:saver = $null
$script:modesTick = 0
$script:processorSubgroup = '54533251-82be-4824-96c1-47b60b740d00'
$script:boostModeSetting = 'be337238-0d82-4146-a960-4f3749d470c7'
$script:energySaverSubgroup = 'de830923-a562-41af-a086-e3a2c6bad2da'
$script:energySaverThreshold = 'e69653ca-cf7f-4f05-aa73-cb833fa90ad4'
$script:buttonsSubgroup = '4f971e89-eebd-4455-a8de-9e59040e7347'
$script:lidActionSetting = '5ca83367-6e45-459f-a27b-476b1d01c936'
$script:lastBusy = @()

# ---------------------------------------------------------------- seams (tests replace these)

function Get-ModesNow { return [datetime]::UtcNow }
function Set-KeepAwake { param([bool]$On) [void][GameBoostSystemState]::KeepAwake($On) }
function Read-PlanValue { param([string]$Scheme, [string]$Subgroup, [string]$Setting, [bool]$PluggedIn) return [GameBoostPower]::ReadValue($Scheme, $Subgroup, $Setting, $PluggedIn) }
function Write-PlanValue { param([string]$Scheme, [string]$Subgroup, [string]$Setting, [bool]$PluggedIn, [int]$Value) return [GameBoostPower]::WriteValue($Scheme, $Subgroup, $Setting, $PluggedIn, $Value) }
function Update-ActivePlan { [void][GameBoostPower]::ApplyActive() }
function Set-DisplayRefresh { param([string]$Gdi, [int]$Hz) return [GameBoostDisplay]::ApplyRefresh($Gdi, $Hz, $false) -eq 0 }
function Undo-DisplayRefresh { param([string]$Gdi) return [GameBoostDisplay]::RevertToPrevious($Gdi) -eq 0 }
function Reset-DisplayRefresh { param([string]$Gdi) return [GameBoostDisplay]::RevertToSaved($Gdi) -eq 0 }
function Get-ModeMonitors { return @([GameBoostDisplay]::GetMonitors()) }
function Get-ForegroundId { return [GameBoostEngine]::ForegroundProcessId() }

# One process list plus CPU use since the previous sample (shared with BOOST's sampler).
function Get-ActivitySample {
    $snapshot = [GameBoostEngine]::Snapshot()
    $busy = [GameBoostEngine]::SampleActivity($snapshot, 0.5, [int64]::MaxValue)
    return [pscustomobject]@{ Snapshot = $snapshot; Busy = $busy }
}
function Connect-WifiProfile { param([string]$Profile) return Start-HiddenProcess 'netsh.exe' "wlan connect name=`"$Profile`"" }

function Get-Brightness {
    try { return [int](Get-CimInstance -Namespace root/wmi -ClassName WmiMonitorBrightness -ErrorAction Stop | Select-Object -First 1).CurrentBrightness }
    catch { return -1 }
}

function Set-Brightness {
    param([int]$Level)
    try {
        $methods = Get-CimInstance -Namespace root/wmi -ClassName WmiMonitorBrightnessMethods -ErrorAction Stop | Select-Object -First 1
        [void](Invoke-CimMethod -InputObject $methods -MethodName WmiSetBrightness -Arguments @{ Timeout = [uint32]0; Brightness = [byte]$Level } -ErrorAction Stop)
        return $true
    } catch { return $false }
}

# Windows' own battery call first (microseconds on the UI thread); WMI only if it has no answer.
function Get-BatteryCapacity {
    $state = [GameBoostSystemState]::Battery()
    if ($state -and $state[0] -gt 0) { return $state[0] }
    try { return [double](Get-CimInstance -Namespace root/wmi -ClassName BatteryStatus -ErrorAction Stop | Select-Object -First 1).RemainingCapacity }
    catch { return -1 }
}

function Get-BatteryRate {
    $state = [GameBoostSystemState]::Battery()
    if ($state) { return $state[2] }
    return 0
}

function Test-WifiConnected {
    foreach ($interface in [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($interface.NetworkInterfaceType -ne 'Wireless80211' -or $interface.Description -match 'Virtual|Direct') { continue }
        if ($interface.OperationalStatus -eq 'Up') { return $true }
    }
    return $false
}

# Windows' own view of the internet connection: name and whether it is metered.
function Get-ConnectionProfileInfo {
    try {
        $null = [Windows.Networking.Connectivity.NetworkInformation, Windows, ContentType = WindowsRuntime]
        $profile = [Windows.Networking.Connectivity.NetworkInformation]::GetInternetConnectionProfile()
        if (-not $profile) { return $null }
        $cost = $profile.GetConnectionCost()
        return [pscustomobject]@{ Name = $profile.ProfileName; Cost = "$($cost.NetworkCostType)"; Wlan = [bool]$profile.IsWlanConnectionProfile }
    } catch { return $null }
}

$script:modeInterfaces = @()
$script:modeInterfacesAt = [datetime]::MinValue

# { received bytes, sent bytes } over the active physical adapters.
function Get-NetworkTotals {
    if (([datetime]::UtcNow - $script:modeInterfacesAt).TotalSeconds -ge 60) {
        $script:modeInterfaces = Get-ActiveNetworkInterfaces
        $script:modeInterfacesAt = [datetime]::UtcNow
    }
    $received = [int64]0; $sent = [int64]0
    foreach ($interface in $script:modeInterfaces) {
        try { $stats = $interface.GetIPStatistics(); $received += $stats.BytesReceived; $sent += $stats.BytesSent }
        catch { $script:modeInterfacesAt = [datetime]::MinValue }
    }
    return @($received, $sent)
}

# ---------------------------------------------------------------- state file (crash recovery)

function Save-ModesState {
    try {
        if (-not $script:download -and -not $script:saver) {
            Remove-Item -LiteralPath $script:modesStateFile -Force -ErrorAction SilentlyContinue
            return
        }
        $state = [ordered]@{ SavedAt = (Get-Date).ToString('o'); Download = $null; Saver = $null }
        if ($script:download) { $state.Download = [ordered]@{ Plan = @($script:download.Plan) } }
        if ($script:saver) {
            $state.Saver = [ordered]@{
                Level = $script:saver.Level; Plan = @($script:saver.Plan); Display = $script:saver.Display; Brightness = $script:saver.Brightness
                Efficiency = @($script:saver.Efficiency.Values | ForEach-Object {
                    [ordered]@{ Id = $_.Id; CreateTime = [string]$_.CreateTime; Priority = $_.Priority; Control = $_.Control; State = $_.State } })
            }
        }
        New-Item -ItemType Directory -Path $script:settingsDirectory -Force | Out-Null
        $temp = "$($script:modesStateFile).tmp"
        ConvertTo-Json -InputObject $state -Depth 5 | Set-Content -LiteralPath $temp -Encoding UTF8
        Move-Item -LiteralPath $temp -Destination $script:modesStateFile -Force
    } catch { }
}

function Restore-PlanEntries {
    param($Entries)
    $changed = $false
    foreach ($entry in @($Entries | ForEach-Object { $_ })) {
        if ($null -eq $entry -or -not $entry.Scheme) { continue }
        if (Write-PlanValue ([string]$entry.Scheme) ([string]$entry.Subgroup) ([string]$entry.Setting) ([bool]$entry.PluggedIn) ([int]$entry.Old)) { $changed = $true }
    }
    if ($changed) { Update-ActivePlan }
}

# After a crash: put back whatever the modes had changed.
function Restore-StaleModes {
    if (-not (Test-Path -LiteralPath $script:modesStateFile)) { return $false }
    try {
        $state = Get-Content -LiteralPath $script:modesStateFile -Raw | ConvertFrom-Json
        Restore-PlanEntries (@($state.Download.Plan) + @($state.Saver.Plan))
        if ($state.Saver.Display -and $state.Saver.Display.Gdi) { [void](Reset-DisplayRefresh ([string]$state.Saver.Display.Gdi)) }
        $light = $state.Saver.Brightness
        if ($light -and (Get-Brightness) -eq [int]$light.New) { [void](Set-Brightness ([int]$light.Old)) }
        foreach ($item in @($state.Saver.Efficiency | ForEach-Object { $_ })) {
            if ($null -eq $item) { continue }
            [void][GameBoostEngine]::TryRestoreEfficiency([int]$item.Id, [long]$item.CreateTime, [uint32]$item.Priority, [uint32]$item.Control, [uint32]$item.State)
        }
    } catch { }
    Remove-Item -LiteralPath $script:modesStateFile -Force -ErrorAction SilentlyContinue
    return $true
}

function New-PlanEntry {
    param([string]$Scheme, [string]$Subgroup, [string]$Setting, [bool]$PluggedIn, [int]$Old, [int]$New)
    return [pscustomobject]@{ Scheme = $Scheme; Subgroup = $Subgroup; Setting = $Setting; PluggedIn = $PluggedIn; Old = $Old; New = $New }
}

# ---------------------------------------------------------------- İndirme modu

function Start-DownloadMode {
    param([string]$AutoReason)
    if ($script:download) { return }
    $scheme = if ($script:boosted -and $script:previousPowerScheme) { $script:previousPowerScheme } else { Get-ActivePowerScheme }
    $connection = Get-ConnectionProfileInfo
    $totals = Get-NetworkTotals
    $download = [pscustomobject]@{
        Started = Get-ModesNow; Plan = [Collections.Generic.List[object]]::new()
        Profile = if ($connection -and $connection.Wlan) { $connection.Name } else { $null }
        LastReceived = $totals[0]; LastSent = $totals[1]; LastAt = Get-ModesNow
        Received = [int64]0; Sent = [int64]0; RateDown = 0.0; RateUp = 0.0; PeakDown = 0.0
        BusySeconds = 0.0; QuietSeconds = 0.0; Notified = $false
        WifiDownSince = $null; ReconnectTries = 0; TrackedAt = $null; ConnectionsAt = $null
        Samples = [Collections.Generic.List[object]]::new()
        Tracked = @{}; Completed = [Collections.Generic.List[string]]::new(); SawTracked = $false; Connections = ''
        Metered = [bool]($connection -and $connection.Cost -in 'Fixed', 'Variable'); PlanChecked = $false; AutoReason = $AutoReason
    }
    # Wi-Fi power saving off (plugged in and on battery) on the user's own plan.
    foreach ($pluggedIn in $true, $false) {
        $old = Read-PlanValue $scheme $script:wifiPowerSubgroup $script:wifiPowerSetting $pluggedIn
        if ($scheme -and $old -gt 0) { $download.Plan.Add((New-PlanEntry $scheme $script:wifiPowerSubgroup $script:wifiPowerSetting $pluggedIn $old 0)) }
    }
    $script:download = $download
    Save-ModesState
    $written = 0
    foreach ($entry in $download.Plan) { if (Write-PlanValue $entry.Scheme $entry.Subgroup $entry.Setting $entry.PluggedIn 0) { $written++ } }
    if ($written -gt 0) { Update-ActivePlan }
    Set-KeepAwake $true
    $wifi = if ($download.Plan.Count -gt 0) { 'Wi-Fi güç tasarrufu kapalı, ' } else { '' }
    $how = if ($AutoReason) { "otomatik açıldı ($AutoReason)" } else { 'açık' }
    Add-Log "İndirme modu ${how}: bilgisayar uyumaz (ekran kapanabilir), ${wifi}Wi-Fi koparsa yeniden bağlanır."
    Update-ModesUi
}

function Stop-DownloadMode {
    param([string]$Reason = 'İndirme modu kapandı; bilgisayar yeniden uyuyabilir.', [switch]$Manual)
    if (-not $script:download) { return }
    # Turned off by hand: the automatic start leaves the same download alone for half an hour.
    if ($Manual) { $script:downloadAutoPausedUntil = (Get-ModesNow).AddMinutes(30) }
    Restore-PlanEntries $script:download.Plan
    $totals = 'toplam ↓ {0} · ↑ {1}' -f (Format-ByteSize $script:download.Received), (Format-ByteSize $script:download.Sent)
    $script:download = $null
    Set-KeepAwake $false
    Save-ModesState
    Add-Log "$Reason ($totals)"
    Update-ModesUi
}

# Every 5 s while the mode is on: speed, end of traffic, Wi-Fi drops.
function Update-DownloadMode {
    $mode = $script:download
    if (-not $mode) { return }
    $now = Get-ModesNow
    $seconds = ($now - $mode.LastAt).TotalSeconds
    if ($seconds -le 0) { return }
    $totals = Get-NetworkTotals
    $down = [math]::Max(0, $totals[0] - $mode.LastReceived)
    $up = [math]::Max(0, $totals[1] - $mode.LastSent)
    $mode.LastReceived = $totals[0]; $mode.LastSent = $totals[1]; $mode.LastAt = $now
    $mode.Received += $down; $mode.Sent += $up
    $mode.RateDown = $down * 8 / $seconds / 1e6
    $mode.RateUp = $up * 8 / $seconds / 1e6
    # The plan speed test's own traffic is not a download.
    if ($script:planTest) { return }
    if ($mode.RateDown -gt $mode.PeakDown) { $mode.PeakDown = $mode.RateDown }
    # One minute of samples (1 s apart while the page is open, 5 s otherwise).
    $mode.Samples.Add([pscustomobject]@{ At = $now; Down = $mode.RateDown; Up = $mode.RateUp })
    while ($mode.Samples.Count -gt 0 -and ($now - $mode.Samples[0].At).TotalSeconds -gt 60) { $mode.Samples.RemoveAt(0) }
    $visible = Test-ModesVisible
    $trackEvery = if ($visible) { 3 } else { 15 }
    if (-not $mode.TrackedAt -or ($now - $mode.TrackedAt).TotalSeconds -ge $trackEvery) { $mode.TrackedAt = $now; Update-DownloadTracking }
    $connectionsEvery = if ($visible) { 10 } else { 30 }
    if (-not $mode.ConnectionsAt -or ($now - $mode.ConnectionsAt).TotalSeconds -ge $connectionsEvery) { $mode.ConnectionsAt = $now; Update-DownloadConnections }
    if (-not $mode.PlanChecked -and ($now - $mode.Started).TotalSeconds -ge 10) { Start-PlanSpeedCheck }

    if ($mode.Profile) {
        if (Test-WifiConnected) {
            if ($mode.WifiDownSince) {
                Add-Log "Wi-Fi yeniden bağlandı ($($mode.Profile))."
                if ($mode.ReconnectTries -gt 0) { [void](Send-SmartNotice 'wifi-back' 'Wi-Fi geri geldi' "$($mode.Profile) ağına yeniden bağlanıldı. İndirme kaldığı yerden devam etmiyorsa uygulamasında yeniden başlat." 'modes' 1 -Important) }
                $mode.WifiDownSince = $null; $mode.ReconnectTries = 0
            }
        } elseif (-not $mode.WifiDownSince) {
            $mode.WifiDownSince = $now
            Add-Log 'Wi-Fi bağlantısı koptu.'
        } elseif ($mode.ReconnectTries -lt 3 -and ($now - $mode.WifiDownSince).TotalSeconds -ge 10 * ($mode.ReconnectTries + 1)) {
            $mode.ReconnectTries++
            [void](Connect-WifiProfile $mode.Profile)
            Add-Log "Wi-Fi'a yeniden bağlanılıyor: $($mode.Profile) (deneme $($mode.ReconnectTries)/3)."
            if ($mode.ReconnectTries -eq 1) {
                [void](Send-SmartNotice 'wifi-lost' 'Wi-Fi koptu' "İndirme modu $($mode.Profile) ağına yeniden bağlanmayı deniyor." 'modes' 1 -Important)
            }
        }
    }

    $mbps = [math]::Max($mode.RateDown, $mode.RateUp)
    if ($mode.WifiDownSince) { return }
    if ($mbps -ge 1) { $mode.BusySeconds += $seconds; $mode.QuietSeconds = 0; $mode.Notified = $false }
    elseif ($mbps -lt 0.2) { $mode.QuietSeconds += $seconds }
    $active = $mode.Tracked.Count

    # Every download Steam, Epic or the browser showed has finished and the line is quiet: done.
    # (Announced even after an earlier "not progressing" notice; the list is emptied once said.)
    if ($mode.SawTracked -and $active -eq 0 -and $mode.Completed.Count -gt 0 -and $mode.QuietSeconds -ge 60) {
        $mode.Notified = $true
        $text = "Tamamlandı: $($mode.Completed -join ', ')."
        $mode.Completed.Clear()
        Complete-DownloadMode $text 'İndirmeler tamamlandı'
        return
    }
    # Traffic that ran for a while and then stopped: finished, paused or stuck.
    if ($mode.BusySeconds -ge 120 -and $mode.QuietSeconds -ge 120 -and -not $mode.Notified) {
        $mode.Notified = $true
        if ($active -gt 0) {
            # Still listed by Steam / the browser: paused or stuck, not finished. The mode stays on.
            $first = @($mode.Tracked.Values)[0]
            [void](Send-SmartNotice 'download-stalled' 'İndirme ilerlemiyor' `
                "Trafik 2 dakikadır durgun ama $(Format-TrackedDownload $first 0) bitmedi: duraklatılmış veya takılmış olabilir." 'modes' 1 -Important)
            return
        }
        $text = 'Trafik 2 dakikadır durgun: indirme bitti, duraklatıldı veya takıldı ({0} indirildi).' -f (Format-ByteSize $mode.Received)
        Complete-DownloadMode $text 'Trafik durdu' 'download-quiet' 'İndirme durdu'
    }
}

# The download is over: tell, switch the mode off when asked, and with "Bitince uyut" count down to sleep.
function Complete-DownloadMode {
    param([string]$Text, [string]$Reason, [string]$Key = 'download-done', [string]$Title = 'İndirme tamamlandı')
    $sleep = [bool]$script:options.DownloadSleepAfter
    if ($script:options.DownloadAutoStop -or $sleep) {
        Stop-DownloadMode "$Reason; İndirme modu kapandı, bilgisayar yeniden uyuyabilir."
        $Text += ' İndirme modu kapandı.'
    }
    if ($sleep) { Start-SleepCountdown $Text }
    else { [void](Send-SmartNotice $Key $Title $Text 'modes' 1 -Important) }
}

# ---------------------------------------------------------------- sleep after the download

$script:sleepCountdown = $null
function Get-IdleSeconds { return [GameBoostSystemState]::IdleSeconds() }
function Invoke-SystemSleep { return [GameBoostSystemState]::Sleep() }

# 60 s to change your mind: any keyboard or mouse input, a game or a new download cancels it.
function Start-SleepCountdown {
    param([string]$What)
    if ($script:sleepCountdown) { return }
    $script:sleepCountdown = [pscustomobject]@{ Started = Get-ModesNow; Seconds = 60 }
    Add-Log 'İndirme bitti; 60 sn sonra uyku moduna geçilecek (fare / klavye kullanılırsa iptal).'
    [void](Send-SmartNotice 'sleep-countdown' 'Bilgisayar 60 sn sonra uyuyacak' "$What Fareyi oynatırsan veya bir tuşa basarsan iptal olur." 'modes' 1 -Important)
    Update-ModesUi
}

function Stop-SleepCountdown {
    param([string]$Reason = 'Uyku iptal edildi.')
    if (-not $script:sleepCountdown) { return }
    $script:sleepCountdown = $null
    Add-Log $Reason
    Update-ModesUi
}

function Update-SleepCountdown {
    $countdown = $script:sleepCountdown
    if (-not $countdown) { return }
    $elapsed = ((Get-ModesNow) - $countdown.Started).TotalSeconds
    # Idle time shorter than the countdown means someone touched the PC after it began.
    if ((Get-IdleSeconds) + 2 -lt $elapsed) { Stop-SleepCountdown 'Fare / klavye kullanıldı; uyku iptal edildi.'; return }
    if ($script:boosted -or $script:download -or [GameBoostEngine]::IsForegroundFullscreen()) {
        Stop-SleepCountdown 'Bilgisayar kullanımda (oyun, tam ekran veya yeni indirme); uyku iptal edildi.'
        return
    }
    if ($elapsed -lt $countdown.Seconds) { return }
    $script:sleepCountdown = $null
    Add-Log 'İndirme bittiği için bilgisayar uyku moduna alınıyor.'
    Update-ModesUi
    [void](Invoke-SystemSleep)
}

# ---------------------------------------------------------------- what is downloading

$script:partialFilePattern = '\.(crdownload|part|partial|download|opdownload|!ut|!qb)$'

function Get-DownloadsFolder {
    $path = Get-RegistryValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders' '{374DE290-123F-4565-9164-39C4925E467B}'
    if ($path) { return $path }
    return Join-Path $env:USERPROFILE 'Downloads'
}

function Read-SteamManifest {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { $text = [IO.File]::ReadAllText($Path) } catch { return $null }
    $field = { param($Key) if ($text -match ('"' + $Key + '"\s+"([^"]*)"')) { $Matches[1] } else { $null } }
    return [pscustomobject]@{ Name = (& $field 'name'); State = [int](& $field 'StateFlags'); Done = [double](& $field 'BytesDownloaded'); Total = [double](& $field 'BytesToDownload') }
}

# Steam keeps a steamapps\downloading\<id> folder while it downloads, Epic marks unfinished installs,
# browsers and torrent apps write .crdownload / .part files until the file is complete.
function Get-ActiveDownloads {
    $items = [Collections.Generic.List[object]]::new()
    foreach ($library in (Get-SteamLibraries)) {
        $downloading = Join-Path $library 'steamapps\downloading'
        if (-not [IO.Directory]::Exists($downloading)) { continue }
        foreach ($folder in @(Get-ChildItem -LiteralPath $downloading -Directory -ErrorAction SilentlyContinue)) {
            if ($folder.Name -notmatch '^\d+$') { continue }
            $path = Join-Path $library "steamapps\appmanifest_$($folder.Name).acf"
            $manifest = Read-SteamManifest $path
            $name = if ($manifest -and $manifest.Name) { $manifest.Name } else { "Uygulama $($folder.Name)" }
            $items.Add([pscustomobject]@{ Key = "steam:$($folder.Name)"; Source = 'Steam'; Name = $name; Done = [double]$manifest.Done; Total = [double]$manifest.Total; Path = $path })
        }
    }
    $epic = Get-EpicManifestFolder
    foreach ($item in @(if ([IO.Directory]::Exists($epic)) { Get-ChildItem -LiteralPath $epic -Filter '*.item' -ErrorAction SilentlyContinue })) {
        try { $json = [IO.File]::ReadAllText($item.FullName) | ConvertFrom-Json } catch { continue }
        if (-not $json.bIsIncompleteInstall) { continue }
        $items.Add([pscustomobject]@{ Key = "epic:$($json.AppName)"; Source = 'Epic'; Name = $json.DisplayName; Done = 0.0; Total = [double]$json.InstallSize; Path = $item.FullName })
    }
    try {
        foreach ($file in [IO.Directory]::EnumerateFiles((Get-DownloadsFolder))) {
            if ($file -notmatch $script:partialFilePattern) { continue }
            $info = [IO.FileInfo]::new($file)
            # A leftover from a download abandoned days ago is not running.
            if ($info.LastWriteTime -lt (Get-Date).AddDays(-1)) { continue }
            $items.Add([pscustomobject]@{
                Key = "file:$($info.Name)"; Source = $(if ($file -match '\.(!ut|!qb)$') { 'Torrent' } else { 'Tarayıcı' })
                Name = ($info.Name -replace $script:partialFilePattern, ''); Done = [double]$info.Length; Total = 0.0; Path = $file; Modified = $info.LastWriteTime
            })
        }
    } catch { }
    return $items
}

# Gone from the list: finished, or cancelled / paused / moved.
function Resolve-FinishedDownload {
    param($Item)
    if ($Item.Source -eq 'Steam') {
        $manifest = Read-SteamManifest $Item.Path
        if ($manifest -and ($manifest.State -eq 4 -or ($manifest.Total -gt 0 -and $manifest.Done -ge $manifest.Total))) { return "Steam · $($Item.Name)" }
        return $null
    }
    if ($Item.Source -eq 'Epic') {
        try { if (-not ([IO.File]::ReadAllText($Item.Path) | ConvertFrom-Json).bIsIncompleteInstall) { return "Epic · $($Item.Name)" } } catch { }
        return $null
    }
    $final = $Item.Path -replace $script:partialFilePattern, ''
    if (Test-Path -LiteralPath $final) { return '{0} ({1})' -f $Item.Name, (Format-ByteSize (Get-Item -LiteralPath $final).Length) }
    # Chrome renames "Unconfirmed 123.crdownload" only at the end: take the newest file that appeared since.
    $newest = Get-ChildItem -LiteralPath (Split-Path $Item.Path) -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch $script:partialFilePattern -and $_.LastWriteTime -ge $Item.FirstSeenLocal } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($newest) { return '{0} ({1})' -f $newest.Name, (Format-ByteSize $newest.Length) }
    return $null
}

function Update-DownloadTracking {
    $mode = $script:download
    if (-not $mode) { return }
    $current = @{}
    foreach ($item in (Get-ActiveDownloads)) { $current[$item.Key] = $item }
    foreach ($key in @($mode.Tracked.Keys)) {
        if ($current.ContainsKey($key)) { continue }
        $item = $mode.Tracked[$key]
        $mode.Tracked.Remove($key)
        $finished = Resolve-FinishedDownload $item
        if ($finished) { $mode.Completed.Add($finished); Add-Log "İndirme tamamlandı: $finished" }
        else { Add-Log "İndirme listeden çıktı (iptal edildi, duraklatıldı veya taşındı): $($item.Source) · $($item.Name)" }
    }
    $now = Get-ModesNow
    foreach ($key in @($current.Keys)) {
        $item = $current[$key]
        $old = $mode.Tracked[$key]
        if ($old) {
            $seconds = ($now - $old.SeenAt).TotalSeconds
            $rate = if ($item.Done -gt $old.Done -and $seconds -gt 0) { ($item.Done - $old.Done) / $seconds } else { $old.Rate }
            $item | Add-Member -NotePropertyMembers @{ FirstSeenLocal = $old.FirstSeenLocal; Rate = $rate; SeenAt = $now } -Force
        } else {
            $item | Add-Member -NotePropertyMembers @{ FirstSeenLocal = (Get-Date).AddSeconds(-5); Rate = 0.0; SeenAt = $now } -Force
            Add-Log "İndirme izleniyor: $($item.Source) · $($item.Name)"
        }
        $mode.Tracked[$key] = $item
    }
    if ($current.Count -gt 0) { $mode.SawTracked = $true }
}

# "Steam · RDR2 · %45 · 54 / 120 GB · ~25 dk"
function Format-TrackedDownload {
    param($Item, [double]$LineMbps)
    $text = "$($Item.Source) · $($Item.Name)"
    if ($Item.Total -gt 0 -and $Item.Done -gt 0) {
        $text += ' · %{0} · {1} / {2}' -f [math]::Min(100, [math]::Floor(100 * $Item.Done / $Item.Total)), (Format-ByteSize $Item.Done), (Format-ByteSize $Item.Total)
        $bytesPerSecond = if ($Item.Rate -gt 0) { $Item.Rate } elseif ($LineMbps -ge 1) { $LineMbps * 1e6 / 8 } else { 0 }
        if ($bytesPerSecond -gt 0) { $text += " · ~$(Format-Duration (($Item.Total - $Item.Done) / $bytesPerSecond / 3600))" }
    } elseif ($Item.Done -gt 0) { $text += " · $(Format-ByteSize $Item.Done)" }
    return $text
}

function Get-ConnectionCounts { return [GameBoostConnections]::CountByProcess() }

# Apps with the most open internet connections: a hint at who is downloading (bytes need admin rights).
function Update-DownloadConnections {
    $mode = $script:download
    if (-not $mode) { return }
    try { $counts = Get-ConnectionCounts } catch { return }
    $top = @($counts.GetEnumerator() | Where-Object { $_.Key -ne $PID } | Sort-Object Value -Descending | Select-Object -First 3 | ForEach-Object {
        $name = try { [Diagnostics.Process]::GetProcessById($_.Key).ProcessName } catch { "PID $($_.Key)" }
        "$name $($_.Value)"
    })
    $mode.Connections = $top -join ' · '
}

$script:wifiLink = [pscustomobject]@{ Mbps = 0; At = [datetime]::MinValue }

# Re-read every 10 s at most (listing the adapters costs a few ms).
function Get-WifiLinkMbps {
    if (([datetime]::UtcNow - $script:wifiLink.At).TotalSeconds -lt 10) { return $script:wifiLink.Mbps }
    $mbps = 0
    foreach ($interface in [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($interface.NetworkInterfaceType -ne 'Wireless80211' -or $interface.Description -match 'Virtual|Direct' -or $interface.OperationalStatus -ne 'Up') { continue }
        $mbps = [math]::Round($interface.Speed / 1e6)
        break
    }
    $script:wifiLink = [pscustomobject]@{ Mbps = $mbps; At = [datetime]::UtcNow }
    return $mbps
}

# Average speed over the last seconds: { Down, Up, Count }.
function Get-DownloadRate {
    param([int]$Seconds)
    $mode = $script:download
    if (-not $mode) { return [pscustomobject]@{ Down = 0.0; Up = 0.0; Count = 0 } }
    $now = Get-ModesNow
    $recent = @($mode.Samples | Where-Object { ($now - $_.At).TotalSeconds -le $Seconds })
    if ($recent.Count -eq 0) { return [pscustomobject]@{ Down = $mode.RateDown; Up = $mode.RateUp; Count = 0 } }
    return [pscustomobject]@{
        Down = ($recent | Measure-Object Down -Average).Average; Up = ($recent | Measure-Object Up -Average).Average; Count = $recent.Count
    }
}

function Test-ModesVisible { return $script:currentPage -eq 'modes' -and (Test-WindowInUse) }

# What limits the download right now, from the live speed, the last speed test, the Wi-Fi link and the upload.
# Driver changes need admin and drop Wi-Fi for seconds, so they are only offered when Wi-Fi is the limit.
function Get-DownloadVerdict {
    $mode = $script:download
    if (-not $mode) { return $null }
    $verdict = { param($Severity, $Title, $Detail, $Action) [pscustomobject]@{ Severity = $Severity; Title = $Title; Detail = $Detail; Action = $Action } }
    $rates = Get-DownloadRate 30
    if ($rates.Count -lt 3 -or ((Get-ModesNow) - $mode.Started).TotalSeconds -lt 15) { return & $verdict 'info' 'Hız ölçülüyor' 'Darboğaz 15 saniye içinde değerlendirilir.' $null }
    $down = $rates.Down
    $up = $rates.Up
    if ($down -lt 1) { return & $verdict 'info' 'İndirme bekleniyor' 'Trafik başlayınca neyin sınırladığı burada görünür.' $null }
    $test = $script:lastSpeedResult
    if ($test -and ((Get-Date) - $test.At).TotalDays -gt 7) { $test = $null }
    $link = if ($mode.Profile) { Get-WifiLinkMbps } else { 0 }
    $network = $script:insightCache.Network
    $pending = @($network.Rows | Where-Object { -not $_.Ok }).Count
    if ($test -and $test.Down -gt 0 -and $down -ge 0.8 * $test.Down) {
        return & $verdict 'ok' "İnternet paketinin sınırında (~$(Format-Mbps $down))" "Hız testi ↓ $(Format-Mbps $test.Down). Ayar değiştirmek hızlandırmaz; mod bağlantıyı açık ve uyanık tutar." $null
    }
    if ($link -gt 0 -and $down -ge 0.5 * $link) {
        $hints = @()
        if ($network.Band -like '*2,4*') { $hints += '2,4 GHz: 5 GHz ağa geç.' }
        if ($pending -gt 0) { $hints += "$pending Wi-Fi sürücü ayarı hızı artırabilir (Wi-Fi birkaç sn kopar)." }
        $hints += 'Kablo en hızlısı.'
        return & $verdict 'warning' "Wi-Fi sınırlıyor (bağlantı $link Mbps)" ($hints -join ' ') $(if ($pending -gt 0) { 'wifi-fix' } else { $null })
    }
    if ($up -ge 2 -and (($test -and $test.Up -gt 0 -and $up -ge 0.7 * $test.Up) -or (-not $test -and $up -ge 0.5 * $down))) {
        return & $verdict 'warning' "Yükleme hattı dolu (↑ $(Format-Mbps $up))" 'İndirme onayları gecikir, indirme yavaşlar. Yükleme yapan uygulamayı (OneDrive, yedekleme, torrent) duraklat.' $null
    }
    if ($test -and $test.Down -gt 0 -and $down -lt 0.5 * $test.Down) {
        return & $verdict 'info' "Kaynak yavaş: hattın ~$(Format-Mbps $test.Down) kaldırıyor" 'Sunucu veya uygulama sınırlıyor olabilir. Steam''de İndirme bölgesini değiştir, hız sınırını kaldır; aynı anda birden çok indirme varsa sırayla indir.' $null
    }
    if (-not $test) { return & $verdict 'info' "↓ $(Format-Mbps $down)" 'Sınırın internet paketi mi Wi-Fi mı olduğunu ayırmak için bir kez Hız testi yap.' $null }
    return & $verdict 'ok' "↓ $(Format-Mbps $down) · beklenen aralıkta" "Hız testi ↓ $(Format-Mbps $test.Down)." $null
}

# The last speed test is kept, so download decisions can compare against it later.
$script:speedResultFile = Join-Path $script:settingsDirectory 'speed-last.json'

function Save-SpeedResult {
    param($Result)
    if (-not $Result -or $Result.Down -le 0) { return }
    $script:lastSpeedResult = $Result
    try {
        New-Item -ItemType Directory -Path $script:settingsDirectory -Force | Out-Null
        ConvertTo-Json -InputObject ([ordered]@{ At = $Result.At.ToString('o'); Down = $Result.Down; Up = $Result.Up; Ping = $Result.Ping }) |
            Set-Content -LiteralPath $script:speedResultFile -Encoding UTF8
    } catch { }
}

function Read-SpeedResult {
    if (-not (Test-Path -LiteralPath $script:speedResultFile)) { return $null }
    try {
        $data = Get-Content -LiteralPath $script:speedResultFile -Raw | ConvertFrom-Json
        # A test whose download could not be measured says nothing about the plan.
        if ([double]$data.Down -le 0) { return $null }
        return [pscustomobject]@{ At = [datetime]$data.At; Down = [double]$data.Down; Up = [double]$data.Up; Ping = [double]$data.Ping }
    } catch { return $null }
}

$script:lastSpeedResult = Read-SpeedResult
$script:planTest = $null

function New-PlanSpeedTest {
    $test = [GameBoostSpeedTest]::new()
    $test.DownSeconds = 4; $test.UpSeconds = 3; $test.DownCapBytes = 150000000; $test.UpCapBytes = 40000000
    $test.Start()
    return $test
}

# The plan's top speed is measured at most once a week, only while the line is idle (a test during a
# download would split the line and measure neither), never on a metered connection. Short: ~10 s.
function Start-PlanSpeedCheck {
    $mode = $script:download
    if (-not $mode -or $mode.PlanChecked -or $script:speedTest -or $script:planTest) { return }
    # Never while a game runs: a full line for 10 s is a lag spike online. Tried again later.
    if ($script:boosted -or [GameBoostEngine]::IsForegroundFullscreen()) { return }
    $mode.PlanChecked = $true
    if ($script:lastSpeedResult -and ((Get-Date) - $script:lastSpeedResult.At).TotalDays -le 7) { return }
    if ($mode.Metered -or $mode.RateDown -ge 1 -or $mode.RateUp -ge 1) {
        Add-Log 'Paket hızı ölçülmedi: hat şu an kullanımda (veya bağlantı ölçülü). Uygun bir anda Hız testi yap.'
        return
    }
    $script:planTest = New-PlanSpeedTest
    Add-Log 'İndirme modu: hat boşta, paket hızı ölçülüyor (~10 sn, en fazla ~190 MB).'
    Wait-UiJob $script:planTest { param($Job) Complete-PlanSpeedCheck $Job }
}

function Complete-PlanSpeedCheck {
    param($Test)
    $script:planTest = $null
    if ($Test.DownMbps -gt 0) {
        Save-SpeedResult ([pscustomobject]@{ At = Get-Date; Down = $Test.DownMbps; Up = $Test.UpMbps; Ping = $Test.PingMs })
        Add-Log "Paket hızı ölçüldü: ↓ $(Format-Speed $Test.DownMbps) · ↑ $(Format-Mbps $Test.UpMbps) ($(Format-ByteSize $Test.BytesUsed) veri)."
    } else { Add-Log "Paket hızı ölçülemedi$(if ($Test.Error) { ": $($Test.Error)" })." }
    Update-ModesLive
}

# ---------------------------------------------------------------- Tasarruf / Süper tasarruf

# Each level has its own switches (options SaverX / SuperX); these are the recommended ones.
$script:saverDefaults = @{
    Saver = [ordered]@{ Efficiency = $true; Refresh = $true; Brightness = $true; Turbo = $false; Energy = $false }
    Super = [ordered]@{ Efficiency = $true; Refresh = $true; Brightness = $true; Turbo = $true; Energy = $true }
}
$script:saverHelp = [ordered]@{
    Efficiency = 'Arka plandaki uygulamalar verimli çekirdeklerde ve düşük öncelikte çalışır. Öne aldığın uygulama hemen normale döner.'
    Refresh    = 'Oyun dışında 60 Hz biraz daha az güç harcar; kaydırma biraz daha az akıcı görünür. Harici ekranlara dokunmaz.'
    Brightness = 'Pilde en çok enerjiyi ekran harcar. Mod sırasında parlaklığı kendin değiştirirsen kapanınca senin ayarın kalır.'
    Turbo      = 'Pilde işlemci en yüksek hızına çıkmaz: ısı ve tüketim belirgin düşer, derleme / video gibi ağır işler yavaşlar. Prizde etkisi yok.'
    Energy     = 'Windows Enerji tasarrufu pilde hemen açılır: arka plan eşitleme ve bildirimler azalır, ekran biraz kısılır.'
}

function Get-SaverPrefix { param([string]$Level) if ($Level -eq 'super') { return 'Super' } return 'Saver' }
function Get-SaverBrightnessLimit { param([string]$Level) if ($Level -eq 'super') { return 30 } return 50 }

# One switch per step, labelled "now → in the mode" with this PC's current values.
function Get-SaverItems {
    param([string]$Level)
    $prefix = Get-SaverPrefix $Level
    $panel = Get-ModeMonitors | Where-Object Internal | Select-Object -First 1
    $hz = if ($panel) { [int][math]::Round($panel.Refresh) } else { 0 }
    $limit = Get-SaverBrightnessLimit $Level
    $light = Get-Brightness
    $scheme = Get-ActivePowerScheme
    $boost = if ($scheme) { Read-PlanValue $scheme $script:processorSubgroup $script:boostModeSetting $false } else { -1 }
    $threshold = if ($scheme) { Read-PlanValue $scheme $script:energySaverSubgroup $script:energySaverThreshold $false } else { -1 }
    $texts = [ordered]@{
        Efficiency = 'Arka plan uygulamaları → verimlilik modu'
        Refresh    = $(if ($hz -gt 60) { "Dahili ekran: $hz → 60 Hz" } else { "Dahili ekran 60 Hz (şu an $hz Hz)" })
        Brightness = $(if ($light -gt $limit) { "Parlaklık: %$light → %$limit" } elseif ($light -ge 0) { "Parlaklık en fazla %$limit (şu an %$light)" } else { "Parlaklık en fazla %$limit" })
        Turbo      = $(if ($boost -gt 0) { 'Pilde işlemci turbosu: açık → kapalı' } else { 'Pilde işlemci turbosu kapalı (zaten kapalı)' })
        Energy     = $(if ($threshold -ge 0 -and $threshold -lt 100) { "Pilde Enerji tasarrufu: pil %$threshold altında → hemen" } else { 'Pilde Enerji tasarrufu hemen (zaten öyle)' })
    }
    return @(foreach ($step in $texts.Keys) {
        [pscustomobject]@{ Step = $step; Key = "$prefix$step"; Text = $texts[$step]; Help = $script:saverHelp[$step]; Recommended = $script:saverDefaults[$prefix][$step] }
    })
}

# "Önerilene dön": the level's switches back to the recommended set.
function Reset-SaverOptions {
    param([string]$Level)
    $prefix = Get-SaverPrefix $Level
    foreach ($step in $script:saverDefaults[$prefix].Keys) { $script:options["$prefix$step"] = $script:saverDefaults[$prefix][$step] }
    Save-CustomSettings -Quiet
}

function Get-SaverEffect {
    param([string]$Level)
    if ($Level -eq 'super') { return 'Etkisi: pil belirgin uzar; derleme, video gibi ağır işler yavaşlar, ekran daha karanlık. Oyun başlarsa kapanır.' }
    return 'Etkisi: günlük kullanımda fark edilmez; pil bir miktar uzar. Öne aldığın uygulama tam hızda çalışır.'
}

function Get-SaverDescription {
    param([string]$Level)
    if ($Level -eq 'super') {
        return 'Tasarruf modunun hepsi; ayrıca parlaklık en fazla %30, pilde işlemci turbosu kapalı ve pilde Windows Enerji tasarrufu açık.'
    }
    return 'Arka planda işlemci kullanan uygulamalar verimlilik modunda, dahili ekran 60 Hz, parlaklık en fazla %50. Öne aldığın uygulama hemen normale döner.'
}

function Start-SaverMode {
    param([ValidateSet('normal', 'super')][string]$Level = 'normal')
    if ($script:boosted) {
        Add-Log 'BOOST açıkken tasarruf modu başlatılmaz.'
        return $false
    }
    if ($script:saver) { Stop-SaverMode -Quiet }
    $prefix = Get-SaverPrefix $Level
    $use = @{}
    foreach ($step in $script:saverDefaults[$prefix].Keys) { $use[$step] = [bool]$script:options["$prefix$step"] }
    $saver = [pscustomobject]@{
        Level = $Level; Started = Get-ModesNow; Plan = [Collections.Generic.List[object]]::new()
        Display = $null; Brightness = $null; Efficiency = @{}; UseEfficiency = $use.Efficiency
        ForegroundNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase); LastForeground = 0
        Applied = [Collections.Generic.List[string]]::new()
    }
    $scheme = Get-ActivePowerScheme
    if ($scheme -and $use.Turbo) {
        $boost = Read-PlanValue $scheme $script:processorSubgroup $script:boostModeSetting $false
        if ($boost -gt 0) { $saver.Plan.Add((New-PlanEntry $scheme $script:processorSubgroup $script:boostModeSetting $false $boost 0)) }
    }
    if ($scheme -and $use.Energy) {
        $threshold = Read-PlanValue $scheme $script:energySaverSubgroup $script:energySaverThreshold $false
        if ($threshold -ge 0 -and $threshold -lt 100) { $saver.Plan.Add((New-PlanEntry $scheme $script:energySaverSubgroup $script:energySaverThreshold $false $threshold 100)) }
    }
    if ($use.Refresh) {
        $panel = Get-ModeMonitors | Where-Object { $_.Internal -and -not $_.Cloned } | Select-Object -First 1
        if ($panel) {
            $hz = [int][math]::Round($panel.Refresh)
            $rates = @($panel.RatesAtResolution | ForEach-Object { [int]$_ })
            $target = if ($rates -contains 60) { 60 } else { @($rates | Where-Object { $_ -ge 48 -and $_ -lt $hz } | Sort-Object)[0] }
            if ($target -and $hz -gt $target) { $saver.Display = [pscustomobject]@{ Gdi = $panel.GdiName; From = $hz; To = [int]$target } }
        }
    }
    if ($use.Brightness) {
        $limit = Get-SaverBrightnessLimit $Level
        $old = Get-Brightness
        if ($old -gt $limit) { $saver.Brightness = [pscustomobject]@{ Old = $old; New = $limit } }
    }

    # Write down what will change, then change it.
    $script:saver = $saver
    Save-ModesState
    $written = 0
    foreach ($entry in $saver.Plan) { if (Write-PlanValue $entry.Scheme $entry.Subgroup $entry.Setting $entry.PluggedIn $entry.New) { $written++ } }
    if ($written -gt 0) {
        Update-ActivePlan
        if ($saver.Plan | Where-Object Setting -eq $script:boostModeSetting) { $saver.Applied.Add('pilde turbo kapalı') }
        if ($saver.Plan | Where-Object Setting -eq $script:energySaverThreshold) { $saver.Applied.Add('pilde Enerji tasarrufu açık') }
    }
    if ($saver.Display) {
        if (Set-DisplayRefresh $saver.Display.Gdi $saver.Display.To) { $saver.Applied.Add("ekran $($saver.Display.From) → $($saver.Display.To) Hz") }
        else { $saver.Display = $null }
    }
    if ($saver.Brightness) {
        if (Set-Brightness $saver.Brightness.New) { $saver.Applied.Add("parlaklık %$($saver.Brightness.Old) → %$($saver.Brightness.New)") }
        else { $saver.Brightness = $null }
    }
    Save-ModesState
    $name = if ($Level -eq 'super') { 'Süper tasarruf' } else { 'Tasarruf modu' }
    if ($use.Efficiency) { $saver.Applied.Insert(0, 'arka plan verimlilik modunda') }
    $what = if ($saver.Applied.Count -gt 0) { $saver.Applied -join ', ' } else { 'seçili adımların hepsi zaten tasarruflu' }
    Add-Log "$name açık: $what."
    # Background apps seen busy since the last minute check get efficiency mode right away.
    $sample = Get-ActivitySample
    $script:lastBusy = $sample.Busy
    Update-SaverEfficiency $sample.Busy
    Update-ModesUi
    return $true
}

function Stop-SaverMode {
    param([string]$Reason, [switch]$Quiet)
    $saver = $script:saver
    if (-not $saver) { return }
    $restored = 0
    foreach ($target in @($saver.Efficiency.Values)) {
        [void][GameBoostEngine]::TryRestoreEfficiency($target.Id, [long]$target.CreateTime, [uint32]$target.Priority, [uint32]$target.Control, [uint32]$target.State)
        $restored++
    }
    # A brightness the user changed in the meantime is theirs; only ours is put back.
    if ($saver.Brightness -and (Get-Brightness) -eq $saver.Brightness.New) { [void](Set-Brightness $saver.Brightness.Old) }
    if ($saver.Display) { [void](Undo-DisplayRefresh $saver.Display.Gdi) }
    Restore-PlanEntries $saver.Plan
    $script:saver = $null
    Save-ModesState
    if (-not $Quiet) {
        if (-not $Reason) { $Reason = 'Tasarruf modu kapandı; ayarlar eski haline döndü.' }
        Add-Log "$Reason$(if ($restored -gt 0) { " $restored süreç normal hızına döndü." })"
    }
    Update-ModesUi
}

function Test-SaverCandidate {
    param($Process, [int]$Foreground)
    if ($Process.Id -eq $PID -or $Process.Id -eq $Foreground -or $Process.CreateTime -eq 0) { return $false }
    if ($script:saver.Efficiency.ContainsKey($Process.Key) -or $script:saver.ForegroundNames.Contains($Process.Name)) { return $false }
    if ($script:excludedNames.Contains($Process.Name) -or $Process.Name -match $script:neverThrottlePattern) { return $false }
    $path = [string]$Process.Path
    if (-not $path -or [GameBoostEngine]::IsGameLibraryPath($path) -or $path -match $script:neverThrottlePathPattern) { return $false }
    return $true
}

# Once a minute: background apps that used the CPU get efficiency mode.
function Update-SaverEfficiency {
    param($Busy)
    if (-not $script:saver -or -not $script:saver.UseEfficiency) { return }
    $foreground = Get-ForegroundId
    $added = [Collections.Generic.List[string]]::new()
    foreach ($process in $Busy) {
        if ($process.CpuPercent -lt 0.5 -or -not (Test-SaverCandidate $process $foreground)) { continue }
        $control = [uint32]0; $state = [uint32]0
        $previous = [GameBoostEngine]::TryEnableEfficiency($process.Id, $process.CreateTime, [ref]$control, [ref]$state)
        if ($previous -eq 0) { continue }
        $script:saver.Efficiency[$process.Key] = [pscustomobject]@{
            Id = $process.Id; CreateTime = $process.CreateTime; Priority = $previous; Name = $process.Name; Control = $control; State = $state
        }
        if (-not $added.Contains($process.Name)) { $added.Add($process.Name) }
    }
    if ($added.Count -gt 0) {
        Save-ModesState
        Add-Log "Tasarruf: $($added -join ', ') verimlilik moduna alındı."
    }
}

# Every 5 s: the app brought to the front runs at full speed again.
function Watch-SaverForeground {
    $saver = $script:saver
    if (-not $saver) { return }
    $foreground = Get-ForegroundId
    if ($foreground -le 0 -or $foreground -eq $saver.LastForeground) { return }
    $saver.LastForeground = $foreground
    $hit = @($saver.Efficiency.GetEnumerator() | Where-Object { $_.Value.Id -eq $foreground })
    if ($hit.Count -eq 0) { return }
    $name = $hit[0].Value.Name
    [void]$saver.ForegroundNames.Add($name)
    foreach ($key in @($saver.Efficiency.Keys)) {
        $target = $saver.Efficiency[$key]
        if ($target.Name -ne $name) { continue }
        [void][GameBoostEngine]::TryRestoreEfficiency($target.Id, [long]$target.CreateTime, [uint32]$target.Priority, [uint32]$target.Control, [uint32]$target.State)
        $saver.Efficiency.Remove($key)
    }
    Save-ModesState
}

# A game needs full power: BOOST ends the saver first.
function Stop-SaverForBoost {
    if ($script:saver) { Stop-SaverMode 'Oyun için tasarruf modu kapatıldı; ayarlar eski haline döndü.' }
}

# ---------------------------------------------------------------- battery meter

$script:batterySamples = [Collections.Generic.List[object]]::new()

# Windows does not report the drain here, so it is measured: capacity change over the last minutes.
function Update-BatteryMeter {
    if (-not (Test-OnBattery)) { $script:batterySamples.Clear(); return }
    $capacity = Get-BatteryCapacity
    if ($capacity -le 0) { return }
    $script:batterySamples.Add([pscustomobject]@{ At = Get-ModesNow; MWh = $capacity })
    while ($script:batterySamples.Count -gt 16) { $script:batterySamples.RemoveAt(0) }
}

function Get-BatteryEstimate {
    # Some laptops report the drain themselves: use it at once.
    $rate = Get-BatteryRate
    if ($rate -lt 0 -and (Test-OnBattery)) {
        $capacity = Get-BatteryCapacity
        $watts = -$rate / 1000
        if ($capacity -gt 0) { return [pscustomobject]@{ Watts = [math]::Round($watts, 1); Hours = $capacity / 1000 / $watts; Minutes = 0 } }
    }
    if ($script:batterySamples.Count -lt 2) { return $null }
    $first = $script:batterySamples[0]; $last = $script:batterySamples[$script:batterySamples.Count - 1]
    $hours = ($last.At - $first.At).TotalHours
    if ($hours * 60 -lt 3 -or $first.MWh -le $last.MWh) { return $null }
    $watts = ($first.MWh - $last.MWh) / 1000 / $hours
    return [pscustomobject]@{ Watts = [math]::Round($watts, 1); Hours = $last.MWh / 1000 / $watts; Minutes = [math]::Round($hours * 60) }
}

function Format-Duration {
    param([double]$Hours)
    $minutes = [int][math]::Round($Hours * 60)
    if ($minutes -lt 60) { return "$minutes dk" }
    return '{0} sa {1} dk' -f [math]::Floor($minutes / 60), ($minutes % 60)
}

# ---------------------------------------------------------------- smart notifications

$script:noticeLast = @{}
$script:noticeLog = [Collections.Generic.List[object]]::new()
$script:noticeDay = (Get-Date).Date
$script:noticeCount = 0
$script:noticeTarget = $null
$script:cpuStrikes = @{}
$script:ramStrikes = 0

# Quiet while a game or any full-screen app runs, during Focus / Do not disturb, and while BOOST is on.
function Test-NoticeQuiet {
    if ($script:boosted) { return $true }
    if ([GameBoostSystemState]::NotificationState() -ne 5) { return $true }
    return [GameBoostEngine]::IsForegroundFullscreen()
}

function Show-TrayNotice {
    param([string]$Title, [string]$Text, [bool]$Warning)
    if (-not $script:trayIcon) { return }
    $icon = if ($Warning) { [Windows.Forms.ToolTipIcon]::Warning } else { [Windows.Forms.ToolTipIcon]::Info }
    $script:trayIcon.ShowBalloonTip(8000, "GameBoost · $Title", $Text, $icon)
}

# Each topic has its own cooldown; at most 8 ordinary notices a day.
function Send-SmartNotice {
    param([string]$Key, [string]$Title, [string]$Text, [string]$Page = 'modes', [int]$CooldownMinutes = 360, [switch]$Important, [switch]$Warning)
    if (-not $script:options.SmartNotices) { return $false }
    $now = Get-Date
    if ($script:noticeLast.ContainsKey($Key) -and ($now - $script:noticeLast[$Key]).TotalMinutes -lt $CooldownMinutes) { return $false }
    if ($now.Date -ne $script:noticeDay) { $script:noticeDay = $now.Date; $script:noticeCount = 0 }
    if (-not $Important -and $script:noticeCount -ge 8) { return $false }
    $quiet = Test-NoticeQuiet
    # Ordinary notices wait for a better moment; important ones are only listed, never shown over a game.
    if ($quiet -and -not $Important) { return $false }
    $script:noticeLast[$Key] = $now
    if (-not $Important) { $script:noticeCount++ }
    $script:noticeLog.Insert(0, [pscustomobject]@{ At = $now; Title = $Title; Text = $Text; Page = $Page; Shown = -not $quiet })
    while ($script:noticeLog.Count -gt 30) { $script:noticeLog.RemoveAt($script:noticeLog.Count - 1) }
    if (-not $quiet) {
        $script:noticeTarget = $Page
        Show-TrayNotice $Title $Text $Warning.IsPresent
    }
    Add-Log "Bildirim: $Title$(if ($quiet) { ' (oyun / tam ekran sırasında gösterilmedi)' })"
    Update-NoticeList
    return $true
}

function Invoke-NoticeChecks {
    param($Snapshot, $Busy)
    if (-not $script:options.SmartNotices -or $script:boosted) { return }
    $power = Get-PowerSample
    if (-not $power.Online -and $null -ne $power.Percent) {
        $percent = $power.Percent
        if ($percent -le 10) {
            [void](Send-SmartNotice 'battery-10' "Pil %$percent" 'Şarja tak; pil bitince bilgisayar uyku moduna geçer ve kaydedilmemiş işler risk altında kalır.' 'modes' 720 -Important -Warning)
        } elseif ($percent -le 20 -and -not $script:saver) {
            [void](Send-SmartNotice 'battery-20' "Pil %$percent" 'Tasarruf modu pili uzatır: arka plan uygulamaları yavaşlar, ekran 60 Hz ve daha az parlak olur.' 'modes' 720)
        }
    } else {
        # Plugged in: the next discharge may warn again.
        [void]$script:noticeLast.Remove('battery-10'); [void]$script:noticeLast.Remove('battery-20')
    }

    $memory = [GameBoostEngine]::MemoryGb()
    if ($memory[0] -lt 1.5) { $script:ramStrikes++ } else { $script:ramStrikes = 0 }
    if ($script:ramStrikes -ge 2 -and $Snapshot) {
        $top = @($Snapshot | Where-Object { $_.Id -ne $PID -and $_.Name -notin 'MemCompression', 'System', 'Registry' } | Sort-Object WorkingSet -Descending | Select-Object -First 2)
        $names = ($top | ForEach-Object { '{0} {1}' -f $_.Name, (Format-ByteSize $_.WorkingSet) }) -join ', '
        [void](Send-SmartNotice 'ram' ('RAM doldu (boş {0:0.0} GB)' -f $memory[0]) "En çok kullananlar: $names. Kullanmadığın sekmeleri veya uygulamaları kapat." 'live' 120)
    }

    # A background app that keeps the CPU busy for three minutes in a row.
    $foreground = Get-ForegroundId
    $strikes = @{}
    foreach ($process in $Busy) {
        if ($process.CpuPercent -lt 15 -or $process.Id -eq $PID -or $process.Id -eq $foreground) { continue }
        if (-not $process.Path -or $process.Path -match '^[A-Za-z]:\\Windows\\' -or $script:excludedNames.Contains($process.Name)) { continue }
        $count = 1 + [int]$script:cpuStrikes[$process.Name]
        $strikes[$process.Name] = $count
        if ($count -ge 3) {
            [void](Send-SmartNotice "cpu:$($process.Name)" "$($process.Name) arka planda yoruyor" `
                "3 dakikadır işlemcinin yaklaşık %$([math]::Round($process.CpuPercent)) kadarını kullanıyor. Canlı İzleme'de gör; gerekmiyorsa kapat." 'live' 360)
        }
    }
    $script:cpuStrikes = $strikes

    # Something big is downloading and the PC could fall asleep: suggest the download mode
    # (with the automatic start on, it has already been switched on instead).
    if (-not $script:download -and -not $script:options.DownloadAutoStart) {
        $recent = (Get-Date).AddMinutes(-5)
        $active = @(Get-ActiveDownloads | Where-Object { ($_.Source -in 'Steam', 'Epic' -and $script:lastTrafficDown -ge 2) -or ($_.Done -ge 50MB -and $_.Modified -ge $recent) })
        if ($active.Count -gt 0) {
            [void](Send-SmartNotice 'download-suggest' "$($active[0].Source) indiriyor" "$($active[0].Name): İndirme modunu aç; bilgisayar uyumasın, bitince haber vereyim." 'modes' 360)
        }
    }

    $system = [IO.DriveInfo]::new($env:SystemDrive)
    if ($system.IsReady -and $system.TotalSize -gt 0 -and ($system.AvailableFreeSpace / $system.TotalSize -lt 0.1 -or $system.AvailableFreeSpace -lt 15GB)) {
        [void](Send-SmartNotice 'disk' "$($env:SystemDrive) sürücüsü dolmak üzere" "Boş: $(Format-ByteSize $system.AvailableFreeSpace). Akıllı Bakım'dan güvenli temizlik yap." 'care' 1440 -Warning)
    }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
        [void](Send-SmartNotice 'reboot' 'Güncelleme yeniden başlatma bekliyor' 'Uygun bir anda yeniden başlat; oyun sırasında güncelleme uyarısı çıkmasın.' 'care' 1440)
    }
    if (Get-Process -Name infatica_agent -ErrorAction SilentlyContinue) {
        [void](Send-SmartNotice 'infatica' 'Infatica çalışıyor' 'İnternet bağlantını başkalarına kullandırıyor; hızını ve pingini düşürür. Ayarlar > Uygulamalar''dan kaldır.' 'care' 1440 -Warning)
    }
    # Watched, mining or infected: a light check every 10 minutes (~50 ms).
    if ($script:minuteCount % 10 -eq 2) { Invoke-SecurityQuick }

    $uptime = [GameBoostEngine]::UptimeDays()
    if ($uptime -ge 7) {
        [void](Send-SmartNotice 'uptime' "$([math]::Floor($uptime)) gündür yeniden başlatılmadı" 'Bir yeniden başlatma belleği ve sürücüleri tazeler (Kapat/Aç değil, Yeniden başlat).' 'care' 4320)
    }
}

# The checks run in their own runspace (the antivirus query alone can take a few hundred ms),
# so the window never waits for them.
function Invoke-SecurityQuick {
    if ($script:securityQuickJob) { return }
    $shell = [powershell]::Create()
    [void]$shell.AddScript("function Invoke-SecurityChecks {`r`n$(${function:Invoke-SecurityChecks})`r`n}`r`nInvoke-SecurityChecks -Quick")
    $job = [pscustomobject]@{ Shell = $shell; Handle = $shell.BeginInvoke() }
    $job | Add-Member -MemberType ScriptProperty -Name Done -Value { $this.Handle.IsCompleted }
    $script:securityQuickJob = $job
    Wait-UiJob $job {
        param($Job)
        $findings = @()
        try { $findings = @($Job.Shell.EndInvoke($Job.Handle)) } catch { }
        $Job.Shell.Dispose()
        $script:securityQuickJob = $null
        Complete-SecurityQuick $findings
    }
}

# Only what needs action is announced; a remote access tool you use yourself is mentioned once a week.
function Complete-SecurityQuick {
    param($Findings)
    $findings = @($Findings | Where-Object { $_ })
    $script:securityQuick = $findings
    foreach ($finding in $findings) {
        if ($finding.Severity -notin 'warning', 'critical') { continue }
        $cooldown = switch ($finding.Kind) { 'privacy-now' { 120 } 'remote' { 10080 } default { 1440 } }
        [void](Send-SmartNotice "security:$($finding.Kind):$($finding.Name)" "Güvenlik: $($finding.Name)" "$($finding.Detail) Öneri: $($finding.Action)" 'security' $cooldown `
            -Important:($finding.Severity -eq 'critical') -Warning)
    }
}

# ---------------------------------------------------------------- the 5 s modes tick

$script:lastMinuteAt = [datetime]::UtcNow
$script:minuteCount = 0

# 1 s while the Modlar page is in front with a download running (network counters, ~0.2 ms),
# 2 s with the page open, 5 s otherwise. Minute work goes by the clock, not by ticks.
function Invoke-ModesTick {
    $script:modesTick++
    if ($script:download) { Update-DownloadMode }
    if ($script:saver) { Watch-SaverForeground }
    if ($script:sleepCountdown) { Update-SleepCountdown }
    $now = [datetime]::UtcNow
    if (($now - $script:lastMinuteAt).TotalSeconds -ge 60) { $script:lastMinuteAt = $now; Invoke-ModesMinute }
    $visible = Test-ModesVisible
    if ($visible) { Update-ModesLive }
    Set-ModesInterval $visible
}

function Set-ModesInterval {
    param([bool]$Visible)
    if (-not $script:modesTimer) { return }
    $interval = if (($Visible -and $script:download) -or $script:sleepCountdown) { 1000 } elseif ($Visible) { 2000 } else { 5000 }
    if ($script:modesTimer.Interval -ne $interval) { $script:modesTimer.Interval = $interval }
}

$script:trafficSample = $null
$script:lastTrafficDown = 0.0
$script:securityQuickJob = $null
$script:busyMinutes = 0
$script:downloadAutoPausedUntil = [datetime]::MinValue

# "İndirme / yükleme başlayınca otomatik aç": a Steam / Epic download, a big browser download or
# two minutes of heavy traffic (↓ 30+ Mbps or ↑ 8+ Mbps, more than video streaming) turn the mode on.
function Invoke-DownloadAutoStart {
    $now = Get-ModesNow
    $totals = Get-NetworkTotals
    $down = 0.0; $up = 0.0
    if ($script:trafficSample) {
        $seconds = ($now - $script:trafficSample.At).TotalSeconds
        if ($seconds -gt 0) {
            $down = [math]::Max(0, $totals[0] - $script:trafficSample.Received) * 8 / $seconds / 1e6
            $up = [math]::Max(0, $totals[1] - $script:trafficSample.Sent) * 8 / $seconds / 1e6
        }
    }
    $script:trafficSample = [pscustomobject]@{ Received = $totals[0]; Sent = $totals[1]; At = $now }
    $script:lastTrafficDown = $down
    if ($down -ge 30 -or $up -ge 8) { $script:busyMinutes++ } else { $script:busyMinutes = 0 }
    if ($script:download -or -not $script:options.DownloadAutoStart -or $now -lt $script:downloadAutoPausedUntil) { return }
    # Not during a game: Steam pauses its download while you play but keeps the folder.
    if ($script:boosted -or [GameBoostEngine]::IsForegroundFullscreen()) { return }
    $recent = (Get-Date).AddMinutes(-2)
    # A Steam / Epic entry counts only while the line actually moves (a paused download keeps its folder).
    $active = @(Get-ActiveDownloads | Where-Object { ($_.Source -in 'Steam', 'Epic' -and $down -ge 2) -or ($_.Done -ge 50MB -and $_.Modified -ge $recent) })
    $reason = if ($active.Count -gt 0) { Format-TrackedDownload $active[0] 0 }
        elseif ($script:busyMinutes -ge 2) { if ($up -ge 8 -and $down -lt 30) { "yükleme ↑ $(Format-Mbps $up)" } else { "indirme ↓ $(Format-Speed $down)" } }
        else { $null }
    if (-not $reason) { return }
    Start-DownloadMode $reason
    $end = if ($script:options.DownloadAutoStop) { 'bitince kendiliğinden kapanır ve haber veririm.' } else { 'Modlar sayfasından kapatabilirsin.' }
    [void](Send-SmartNotice 'download-auto' 'İndirme modu açıldı' "Algılanan: $reason. Bilgisayar uyumaz; $end" 'modes' 1 -Important)
}

# Once a minute (one process list, ~20 ms). Nothing runs here while BOOST is on.
function Invoke-ModesMinute {
    $script:minuteCount++
    Update-BatteryMeter
    Update-HealthMinute
    Invoke-DownloadAutoStart
    if ($script:boosted -or -not ($script:saver -or $script:options.SmartNotices)) { return }
    $sample = Get-ActivitySample
    $script:lastBusy = $sample.Busy
    if ($script:saver) { Update-SaverEfficiency $sample.Busy }
    # The first minute after start has no CPU history yet; notices wait for the second.
    if ($script:minuteCount -ge 2) { Invoke-NoticeChecks $sample.Snapshot $sample.Busy }
}

function Stop-AllModes {
    if ($script:saver) { Stop-SaverMode 'Uygulama kapandı; tasarruf ayarları geri alındı.' }
    if ($script:download) { Stop-DownloadMode 'Uygulama kapandı; İndirme modu kapandı.' }
}

# ---------------------------------------------------------------- checks shown on the Modlar page

function Get-TcpAutoTuning {
    $line = @(netsh.exe int tcp show global 2>$null | Where-Object { $_ -match 'Auto-Tuning|Otomatik' } | Select-Object -First 1)
    if ($line.Count -and $line[0] -match ':\s*(\S+)\s*$') { return $Matches[1] }
    return $null
}

function Get-DownloadChecks {
    $alerts = [Collections.Generic.List[object]]::new()
    $connection = Get-ConnectionProfileInfo
    if (-not $connection) { $alerts.Add((New-Alert 'warning' 'İnternet bağlantısı görünmüyor' 'Wi-Fi veya kabloyu kontrol et.')) }
    elseif ($connection.Cost -in 'Fixed', 'Variable') {
        $alerts.Add((New-Alert 'warning' "Ölçülü bağlantı: $($connection.Name)" 'Windows Update, OneDrive ve Store indirmeleri durur veya yavaşlar. Ayarlar > Ağ ve İnternet > Wi-Fi > ağın > Ölçülü bağlantı: kapalı.'))
    } else { $alerts.Add((New-Alert 'ok' "Ölçülü bağlantı değil: $($connection.Name)" 'Windows indirmeleri kısmaz.')) }
    if (Test-OnBattery) { $alerts.Add((New-Alert 'warning' 'Pilde çalışıyor' 'Uzun indirmede pil biter; şarja tak.')) }
    $scheme = Get-ActivePowerScheme
    if ($scheme) {
        $lid = Read-PlanValue $scheme $script:buttonsSubgroup $script:lidActionSetting (-not (Test-OnBattery))
        if ($lid -gt 0) { $alerts.Add((New-Alert 'info' 'Kapak kapanınca bilgisayar uyur' 'İndirme modu kapak kapanmasını engelleyemez; kapağı açık bırak (ekran kendiliğinden kapanabilir).')) }
    }
    $steam = Get-RegistryValue 'HKCU:\Software\Valve\Steam' 'SteamPath'
    $steamConfig = if ($steam) { Join-Path ($steam -replace '/', '\') 'config\config.vdf' } else { $null }
    if ($steamConfig -and (Test-Path -LiteralPath $steamConfig)) {
        if ([IO.File]::ReadAllText($steamConfig) -match '"DownloadThrottleKbps"\s+"(\d+)"' -and [int]$Matches[1] -gt 0) {
            $alerts.Add((New-Alert 'warning' 'Steam indirme hızı sınırlı' 'Steam > Ayarlar > İndirmeler > "İndirme hızını sınırla" kapalı olsun; yoksa paketin tamamı kullanılmaz.'))
        }
    }
    $tuning = Get-TcpAutoTuning
    if ($tuning -and $tuning -ne 'normal') {
        $alerts.Add((New-Alert 'warning' "TCP otomatik ayarı: $tuning" 'İndirme hızını ciddi düşürür. Yönetici komut isteminde: netsh int tcp set global autotuninglevel=normal'))
    }
    $vpn = [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() | Where-Object {
        $_.OperationalStatus -eq 'Up' -and $_.Description -match 'VPN|TAP-|WireGuard|OpenVPN|NordLynx|Proton|Tunnel'
    } | Select-Object -First 1
    if ($vpn) { $alerts.Add((New-Alert 'info' 'VPN açık' "$($vpn.Description): hız ve ping VPN sunucusuna bağlı.")) }
    if (Get-Process -Name infatica_agent -ErrorAction SilentlyContinue) {
        $alerts.Add((New-Alert 'warning' 'Infatica bağlantını paylaşıyor' 'İndirme hızını düşürür; Ayarlar > Uygulamalar''dan kaldır.'))
    }
    foreach ($alert in @($script:insightCache.NetworkAlerts)) {
        if ($alert -and ($alert.Severity -eq 'warning' -or $alert.Title -like 'Kablolu*')) { $alerts.Add($alert) }
    }
    return $alerts
}

function Get-PowerChecks {
    $alerts = [Collections.Generic.List[object]]::new()
    $power = [Windows.Forms.SystemInformation]::PowerStatus
    if ($power.PowerLineStatus -eq [Windows.Forms.PowerLineStatus]::Offline) {
        $estimate = Get-BatteryEstimate
        $source = if ($estimate.Minutes -gt 0) { "Son $($estimate.Minutes) dk" } else { 'Windows' }
        $detail = if ($estimate) { "${source}: ~$($estimate.Watts) W çekiş, bu hızla ~$(Format-Duration $estimate.Hours) kalır." } else { 'Çekiş ve kalan süre birkaç dakika içinde ölçülür.' }
        $alerts.Add((New-Alert 'info' "Pilde: %$([math]::Round($power.BatteryLifePercent * 100))" $detail))
    } else { $alerts.Add((New-Alert 'ok' 'Prizde' 'Tasarruf ayarları pildeyken daha çok fark eder.')) }
    $light = Get-Brightness
    if ($light -ge 70) { $alerts.Add((New-Alert 'warning' "Parlaklık %$light" 'Pilde en çok enerjiyi ekran harcar; %40-50 pili belirgin uzatır.')) }
    elseif ($light -ge 0) { $alerts.Add((New-Alert 'ok' "Parlaklık %$light" '')) }
    $panel = Get-ModeMonitors | Where-Object Internal | Select-Object -First 1
    if ($panel -and [math]::Round($panel.Refresh) -gt 60) {
        $alerts.Add((New-Alert 'info' "Dahili ekran $([math]::Round($panel.Refresh)) Hz" 'Oyun dışında 60 Hz biraz daha az güç harcar; Tasarruf modu geçici olarak 60 Hz yapar.'))
    }
    if ([GameBoostSystemState]::EnergySaverOn()) { $alerts.Add((New-Alert 'ok' 'Windows Enerji tasarrufu açık' '')) }
    else {
        $scheme = Get-ActivePowerScheme
        $threshold = if ($scheme) { Read-PlanValue $scheme $script:energySaverSubgroup $script:energySaverThreshold $false } else { -1 }
        if ($threshold -ge 0) { $alerts.Add((New-Alert 'info' "Windows Enerji tasarrufu pil %$threshold altında açılır" 'Süper tasarruf onu pilde hemen açar.')) }
    }
    $busy = @($script:lastBusy | Where-Object { $_.CpuPercent -ge 3 -and $_.Id -ne $PID } | Sort-Object CpuPercent -Descending | Select-Object -First 3)
    if ($busy.Count -gt 0) {
        $alerts.Add((New-Alert 'info' 'Arka planda işlemci kullananlar' (($busy | ForEach-Object { "$($_.Name) %$($_.CpuPercent)" }) -join ' · ')))
    }
    if ($script:gpuUsersResult) { foreach ($alert in $script:gpuUsersResult) { $alerts.Add($alert) } }
    return $alerts
}

# Which apps keep the NVIDIA card awake (it draws several watts even when idle).
function Start-GpuUsersScan {
    param([scriptblock]$OnDone)
    $nvidia = @([GameBoostGpuInfo]::Adapters() | Where-Object { $_.VendorId -eq 0x10DE }) | Select-Object -First 1
    if (-not $nvidia) {
        $script:gpuUsersResult = @(New-Alert 'ok' 'Ayrı NVIDIA kartı yok' '')
        if ($OnDone) { & $OnDone }
        return
    }
    $scan = [GameBoostGpuUsers]::new()
    $scan.Start($nvidia.LuidKey)
    $script:gpuUsersDone = $OnDone
    Wait-UiJob $scan {
        param($Job)
        if ($Job.Error) { $script:gpuUsersResult = @(New-Alert 'info' 'NVIDIA kartı kullanımı okunamadı' $Job.Error) }
        elseif ($Job.Ids.Count -eq 0) { $script:gpuUsersResult = @(New-Alert 'ok' 'NVIDIA kartını kullanan uygulama yok' 'Kart uyuyabilir; pil için en iyisi.') }
        else {
            $names = for ($i = 0; $i -lt $Job.Ids.Count; $i++) {
                $name = try { [Diagnostics.Process]::GetProcessById($Job.Ids[$i]).ProcessName } catch { "PID $($Job.Ids[$i])" }
                '{0} ({1})' -f $name, (Format-ByteSize $Job.Bytes[$i])
            }
            $script:gpuUsersResult = @(New-Alert 'warning' "NVIDIA kartını uyanık tutanlar: $(@($names).Count)" `
                "$($names -join ', '). Pilde gerekmiyorsa kapat veya Ayarlar > Ekran > Grafik'ten 'Güç tasarrufu' seç.")
        }
        if ($script:gpuUsersDone) { & $script:gpuUsersDone }
    }
}
