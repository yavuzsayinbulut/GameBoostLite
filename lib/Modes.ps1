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

function Get-BatteryCapacity {
    try { return [double](Get-CimInstance -Namespace root/wmi -ClassName BatteryStatus -ErrorAction Stop | Select-Object -First 1).RemainingCapacity }
    catch { return -1 }
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
        WifiDownSince = $null; ReconnectTries = 0
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
    Add-Log "İndirme modu açık: bilgisayar uyumaz (ekran kapanabilir), ${wifi}Wi-Fi koparsa yeniden bağlanır."
    Update-ModesUi
}

function Stop-DownloadMode {
    param([string]$Reason = 'İndirme modu kapandı; bilgisayar yeniden uyuyabilir.')
    if (-not $script:download) { return }
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
    if ($mode.RateDown -gt $mode.PeakDown) { $mode.PeakDown = $mode.RateDown }

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

    # Traffic that ran for a while and then stopped: finished, paused or stuck.
    $mbps = [math]::Max($mode.RateDown, $mode.RateUp)
    if ($mode.WifiDownSince) { return }
    if ($mbps -ge 1) { $mode.BusySeconds += $seconds; $mode.QuietSeconds = 0; $mode.Notified = $false }
    elseif ($mbps -lt 0.2) { $mode.QuietSeconds += $seconds }
    if ($mode.BusySeconds -ge 120 -and $mode.QuietSeconds -ge 120 -and -not $mode.Notified) {
        $mode.Notified = $true
        $text = 'Trafik 2 dakikadır durgun: indirme bitti, duraklatıldı veya takıldı ({0} indirildi).' -f (Format-ByteSize $mode.Received)
        if ($script:options.DownloadAutoStop) {
            Stop-DownloadMode 'Trafik durdu; İndirme modu kendiliğinden kapandı, bilgisayar yeniden uyuyabilir.'
            $text += ' İndirme modu kapandı.'
        }
        [void](Send-SmartNotice 'download-quiet' 'İndirme durdu' $text 'modes' 1 -Important)
    }
}

# ---------------------------------------------------------------- Tasarruf / Süper tasarruf

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
    $saver = [pscustomobject]@{
        Level = $Level; Started = Get-ModesNow; Plan = [Collections.Generic.List[object]]::new()
        Display = $null; Brightness = $null; Efficiency = @{}
        ForegroundNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase); LastForeground = 0
        Applied = [Collections.Generic.List[string]]::new()
    }
    $scheme = Get-ActivePowerScheme
    if ($Level -eq 'super' -and $scheme) {
        $boost = Read-PlanValue $scheme $script:processorSubgroup $script:boostModeSetting $false
        if ($boost -gt 0) { $saver.Plan.Add((New-PlanEntry $scheme $script:processorSubgroup $script:boostModeSetting $false $boost 0)) }
        $threshold = Read-PlanValue $scheme $script:energySaverSubgroup $script:energySaverThreshold $false
        if ($threshold -ge 0 -and $threshold -lt 100) { $saver.Plan.Add((New-PlanEntry $scheme $script:energySaverSubgroup $script:energySaverThreshold $false $threshold 100)) }
    }
    if ($script:options.SaverRefresh) {
        $panel = Get-ModeMonitors | Where-Object { $_.Internal -and -not $_.Cloned } | Select-Object -First 1
        if ($panel) {
            $hz = [int][math]::Round($panel.Refresh)
            $rates = @($panel.RatesAtResolution | ForEach-Object { [int]$_ })
            $target = if ($rates -contains 60) { 60 } else { @($rates | Where-Object { $_ -ge 48 -and $_ -lt $hz } | Sort-Object)[0] }
            if ($target -and $hz -gt $target) { $saver.Display = [pscustomobject]@{ Gdi = $panel.GdiName; From = $hz; To = [int]$target } }
        }
    }
    if ($script:options.SaverBrightness) {
        $limit = if ($Level -eq 'super') { 30 } else { 50 }
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
    $what = if ($saver.Applied.Count -gt 0) { $saver.Applied -join ', ' } else { 'ayarlar zaten tasarruflu' }
    Add-Log "$name açık: $what. Arka planda işlemci kullanan uygulamalar verimlilik moduna alınır."
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
    if (-not $script:saver) { return }
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
    $uptime = [GameBoostEngine]::UptimeDays()
    if ($uptime -ge 7) {
        [void](Send-SmartNotice 'uptime' "$([math]::Floor($uptime)) gündür yeniden başlatılmadı" 'Bir yeniden başlatma belleği ve sürücüleri tazeler (Kapat/Aç değil, Yeniden başlat).' 'care' 4320)
    }
}

# ---------------------------------------------------------------- the 5 s modes tick

function Invoke-ModesTick {
    $script:modesTick++
    if ($script:download) { Update-DownloadMode }
    if ($script:saver) { Watch-SaverForeground }
    if ($script:modesTick % 12 -eq 0) { Invoke-ModesMinute }
    if ($script:currentPage -eq 'modes' -and (Test-WindowInUse)) { Update-ModesLive }
}

# Once a minute (one process list, ~20 ms). Nothing runs here while BOOST is on.
function Invoke-ModesMinute {
    Update-BatteryMeter
    if ($script:boosted -or -not ($script:saver -or $script:options.SmartNotices)) { return }
    $sample = Get-ActivitySample
    $script:lastBusy = $sample.Busy
    if ($script:saver) { Update-SaverEfficiency $sample.Busy }
    # The first minute after start has no CPU history yet; notices wait for the second.
    if ($script:modesTick -ge 24) { Invoke-NoticeChecks $sample.Snapshot $sample.Busy }
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
        $detail = if ($estimate) { "Son $($estimate.Minutes) dk: ~$($estimate.Watts) W çekiş, bu hızla ~$(Format-Duration $estimate.Hours) kalır." } else { 'Çekiş ve kalan süre birkaç dakika içinde ölçülür.' }
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
