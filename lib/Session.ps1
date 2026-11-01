# Game session watch. Runs only while BOOST is on and stops with it:
# GPU heat/limits (one nvidia-smi process, every 5 s), which GPU the game draws with (one check),
# charger strength, router ping, background download volume and Windows Update / Defender activity.
# Everything is reported silently inside the app; nothing is closed or changed.

$script:session = $null
$script:sessionAlerts = @()
$script:gpuTelemetry = $null
$script:pingMonitor = $null
$script:updateProcessNames = New-NameSet @('TiWorker', 'TrustedInstaller', 'MoUsoCoreWorker', 'wuauclt', 'UsoClient', 'WaaSMedicAgent', 'SIHClient')
$script:defenderProcessNames = New-NameSet @('MsMpEng', 'MpDefenderCoreService', 'MsMpEngCP')
foreach ($name in @($script:updateProcessNames) + @($script:defenderProcessNames)) { [void][GameBoostEngine]::SystemWatchNames.Add($name) }
$script:gpuTelemetryArguments = '--query-gpu=temperature.gpu,utilization.gpu,memory.used,memory.total,' +
    'clocks_event_reasons.sw_power_cap,clocks_event_reasons.hw_slowdown,clocks_event_reasons.sw_thermal_slowdown,' +
    'clocks_event_reasons.hw_thermal_slowdown --format=csv,noheader,nounits -lms 5000'

# Small seams so the session logic can be checked without touching the system.
function Get-SessionNow { return [datetime]::UtcNow }

function Get-PowerSample {
    $status = [Windows.Forms.SystemInformation]::PowerStatus
    return [pscustomobject]@{
        Online = $status.PowerLineStatus -eq [Windows.Forms.PowerLineStatus]::Online
        Percent = if ($status.BatteryLifePercent -le 1) { [int][math]::Round($status.BatteryLifePercent * 100) } else { $null }
        HasBattery = -not ($status.BatteryChargeStatus -band [Windows.Forms.BatteryChargeStatus]::NoSystemBattery)
    }
}

$script:networkInterfaces = @()
$script:networkInterfacesAt = [datetime]::MinValue

function Get-ActiveNetworkInterfaces {
    return @([Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() | Where-Object {
        $_.OperationalStatus -eq 'Up' -and "$($_.NetworkInterfaceType)" -notin 'Loopback', 'Tunnel' -and
        $_.Description -notmatch 'Virtual|Hyper-V|VPN|TAP'
    })
}

function Get-NetworkReceivedBytes {
    # Building the interface list costs ~15 ms; reading cached interfaces ~0.2 ms. Rebuild once a minute.
    if (([datetime]::UtcNow - $script:networkInterfacesAt).TotalSeconds -ge 60) {
        $script:networkInterfaces = Get-ActiveNetworkInterfaces
        $script:networkInterfacesAt = [datetime]::UtcNow
    }
    $total = [int64]0
    foreach ($interface in $script:networkInterfaces) {
        try { $total += $interface.GetIPStatistics().BytesReceived } catch { $script:networkInterfacesAt = [datetime]::MinValue }
    }
    return $total
}

function Get-SystemWorkCpu { return [GameBoostEngine]::SystemCpuSeconds() }

function New-GpuTelemetryReader {
    $smi = (Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue).Source
    if (-not $smi) { return $null }
    $reader = [GameBoostLineReader]::new()
    if ($reader.Start($smi, $script:gpuTelemetryArguments)) { return $reader }
    return $null
}

function New-PingMonitor {
    $gateway = Get-DefaultGateway
    if (-not $gateway) { return $null }
    $monitor = [GameBoostPingMonitor]::new()
    $monitor.Start($gateway, 5000, 1000)
    return $monitor
}

function Start-PlacementCheck {
    param([int]$ProcessId)
    $check = [GameBoostGpuPlacementCheck]::new()
    $check.Start($ProcessId)
    return $check
}

# ---------------------------------------------------------------- session lifetime

function Start-GameSession {
    Stop-SessionMonitors
    $script:pingMonitor = $null
    $now = Get-SessionNow
    $script:sessionAlerts = @()
    $script:session = [pscustomobject]@{
        Started = $now; Mode = $script:boostMode; Games = [Collections.Generic.List[string]]::new(); FirstGameAt = $null; GamePid = 0
        MinFreeRamGb = [double]::MaxValue; PeakGameRamBytes = [int64]0
        GpuLines = 0; GpuSamples = 0; GpuMaxTemp = $null; GpuMaxVramMb = $null; GpuVramTotalMb = $null
        BusySamples = 0; PowerCapBusySamples = 0; ThermalSamples = 0; SlowdownSamples = 0; LimitStreak = 0; LimitAlerted = $false
        Placement = 'pending'; PlacementRetried = $false; PlacementRetryAt = $null; PlacementText = $null
        AcPercent = $null; AcSince = $null; ChargerDrop = $null; ChargerAlerted = $false; PlayedOnBattery = $false
        NetBytes = (Get-NetworkReceivedBytes); NetAt = $now; NetHeavySeconds = 0.0; NetHeavyBits = 0.0; NetMaxMbps = 0.0
        SysCpuAt = $null; SysCpuUpdate = 0.0; SysCpuDefender = 0.0; UpdateSeconds = 0.0; DefenderSeconds = 0.0
    }
    $script:gpuTelemetry = New-GpuTelemetryReader
    $script:pingMonitor = New-PingMonitor
}

function Stop-SessionMonitors {
    if ($script:gpuTelemetry) { $script:gpuTelemetry.Stop(); $script:gpuTelemetry = $null }
    if ($script:pingMonitor) { $script:pingMonitor.Stop() }
}

function Add-SessionGame {
    param([int]$Id, [string]$Name)
    $s = $script:session
    if (-not $s) { return }
    if (-not $s.Games.Contains($Name)) { $s.Games.Add($Name) }
    if (-not $s.FirstGameAt) { $s.FirstGameAt = Get-SessionNow }
    $s.GamePid = $Id
}

function Add-SessionAlert {
    param($Alert, [switch]$Notice)
    $script:sessionAlerts = @($script:sessionAlerts) + @($Alert)
    if ($Notice) { Set-ActivityNotice "$($Alert.Title). $($Alert.Detail)" }
}

# Every BOOST tick (3 s). Light: memory, one parsed nvidia-smi line, power status, byte counters.
function Update-GameSession {
    param($Snapshot)
    $s = $script:session
    if (-not $s) { return }
    $now = Get-SessionNow
    $free = [GameBoostEngine]::MemoryGb()[0]
    if ($free -gt 0 -and $free -lt $s.MinFreeRamGb) { $s.MinFreeRamGb = $free }
    if ($null -ne $Snapshot -and $script:detectedGames.Count -gt 0) {
        # The game's own processes only; launchers and helpers are not added in.
        foreach ($process in $Snapshot) {
            if ($script:detectedGames.ContainsKey($process.Id) -and $process.WorkingSet -gt $s.PeakGameRamBytes) { $s.PeakGameRamBytes = $process.WorkingSet }
        }
    }
    Update-SessionGpu
    Update-SessionCharger $now
    Update-SessionNetwork $now
    Update-SessionPlacement $now
}

function Update-SessionGpu {
    $s = $script:session
    if (-not $script:gpuTelemetry) { return }
    $count = $script:gpuTelemetry.LineCount
    if ($count -eq $s.GpuLines) { return }
    $s.GpuLines = $count
    $parts = @(([string]$script:gpuTelemetry.LastLine).Split(',') | ForEach-Object { $_.Trim() })
    if ($parts.Count -lt 8) { return }
    $s.GpuSamples++
    $temp = 0; $util = 0; $used = 0; $total = 0
    if ([int]::TryParse($parts[0], [ref]$temp) -and ($null -eq $s.GpuMaxTemp -or $temp -gt $s.GpuMaxTemp)) { $s.GpuMaxTemp = $temp }
    [void][int]::TryParse($parts[1], [ref]$util)
    if ([int]::TryParse($parts[2], [ref]$used) -and ($null -eq $s.GpuMaxVramMb -or $used -gt $s.GpuMaxVramMb)) { $s.GpuMaxVramMb = $used }
    if ([int]::TryParse($parts[3], [ref]$total)) { $s.GpuVramTotalMb = $total }
    $powerCap = $parts[4] -eq 'Active'
    $slowdown = $parts[5] -eq 'Active'
    $thermal = $parts[6] -eq 'Active' -or $parts[7] -eq 'Active'
    # Running at the power limit under load is normal for laptop GPUs; it is only summarized.
    if ($util -ge 50) { $s.BusySamples++; if ($powerCap) { $s.PowerCapBusySamples++ } }
    if ($thermal) { $s.ThermalSamples++ }
    if ($slowdown) { $s.SlowdownSamples++ }
    # Heat or hardware slowdown is reported once, and only when it lasts two readings (~10 s).
    if ($thermal -or $slowdown) { $s.LimitStreak++ } else { $s.LimitStreak = 0 }
    if ($s.LimitStreak -ge 2 -and -not $s.LimitAlerted) {
        $s.LimitAlerted = $true
        $detail = if ($thermal) {
            "GPU $temp°C'de ısıdan yavaşlıyor. Laptopu sert ve yüksek bir zemine koy, hava girişlerini açık tut."
        } else { 'GPU donanım yavaşlatmasında (aşırı ısı ya da yetersiz güç kaynağı). Laptopun kendi adaptörünü kullan, havalandırmayı kontrol et.' }
        Add-SessionAlert (New-Alert 'warning' 'Ekran kartı yavaşlıyor' $detail) -Notice
    }
}

function Update-SessionCharger {
    param([datetime]$Now)
    $s = $script:session
    $power = Get-PowerSample
    if (-not $power.HasBattery -or $null -eq $power.Percent) { return }
    if (-not $power.Online) { $s.PlayedOnBattery = $true; $s.AcPercent = $null; return }
    # Plugged in, the battery should hold or rise. A steady drop means the charger cannot keep up.
    if ($null -eq $s.AcPercent -or $power.Percent -gt $s.AcPercent) { $s.AcPercent = $power.Percent; $s.AcSince = $Now; return }
    $drop = $s.AcPercent - $power.Percent
    if ($drop -ge 3 -and ($Now - $s.AcSince).TotalMinutes -ge 2) {
        $s.ChargerDrop = "%$($s.AcPercent) → %$($power.Percent)"
        if (-not $s.ChargerAlerted) {
            $s.ChargerAlerted = $true
            Add-SessionAlert (New-Alert 'warning' 'Şarj aleti oyunun gücüne yetmiyor' `
                "Prize takılıyken pil $($s.ChargerDrop) düştü. Laptopun kendi yüksek watt'lı adaptörünü kullan; USB-C şarj oyunda yetmeyebilir.") -Notice
        }
    }
}

function Update-SessionNetwork {
    param([datetime]$Now)
    $s = $script:session
    $bytes = Get-NetworkReceivedBytes
    $seconds = ($Now - $s.NetAt).TotalSeconds
    if ($seconds -gt 0 -and $bytes -ge $s.NetBytes) {
        $bits = ($bytes - $s.NetBytes) * 8.0
        $mbps = $bits / 1e6 / $seconds
        if ($mbps -gt $s.NetMaxMbps) { $s.NetMaxMbps = $mbps }
        # 16 Mbps and up is far beyond what online games use; something is downloading.
        if ($mbps -ge 16) { $s.NetHeavySeconds += $seconds; $s.NetHeavyBits += $bits }
    }
    $s.NetBytes = $bytes
    $s.NetAt = $Now
}

function Update-SessionPlacement {
    param([datetime]$Now)
    $s = $script:session
    if ($s.Placement -notin 'pending', 'retry' -or -not $s.FirstGameAt -or $s.GamePid -le 0) { return }
    $due = if ($s.Placement -eq 'retry') { $s.PlacementRetryAt } else { $s.FirstGameAt.AddSeconds(20) }
    if ($Now -lt $due) { return }
    $s.Placement = 'running'
    $check = Start-PlacementCheck $s.GamePid
    Wait-UiJob $check { param($Job) Complete-SessionPlacement $Job }
}

function Complete-SessionPlacement {
    param($Job)
    $s = $script:session
    if (-not $s) { return }
    if ($Job.Error -or $Job.Utilization -lt 1) {
        # Menus and loading screens barely use the GPU: look once more a minute later.
        if (-not $s.PlacementRetried) {
            $s.PlacementRetried = $true
            $s.Placement = 'retry'
            $s.PlacementRetryAt = (Get-SessionNow).AddSeconds(60)
            return
        }
        $s.Placement = 'done'
        $s.PlacementText = 'ölçülemedi (oyun GPU''yu kullanmıyordu)'
        return
    }
    $s.Placement = 'done'
    $name = if ($Job.AdapterName) { $Job.AdapterName } else { 'bilinmeyen GPU' }
    $vram = if ($Job.GameDedicatedBytes -ge 0) { ", oyunun kendi VRAM'i ~$([math]::Round($Job.GameDedicatedBytes / 1MB)) MB" } else { '' }
    $s.PlacementText = "$name (kullanım %$('{0:0}' -f $Job.Utilization)$vram)"
    if ($Job.VendorId -eq 0x8086 -and $script:hasNvidiaGpu) {
        Add-SessionAlert (New-Alert 'warning' 'Oyun Intel ekran kartında çalışıyor' `
            'Güçlü NVIDIA kart kullanılmıyor. Ayarlar > Sistem > Ekran > Grafik''ten bu oyuna "Yüksek performans" seç; oyunu yeniden başlatınca geçerli olur.') -Notice
    }
}

# Every activity sample (12 s): Windows Update and Defender CPU, read without touching them.
function Update-SessionSystemWork {
    $s = $script:session
    if (-not $s) { return }
    $now = Get-SessionNow
    $update = 0.0
    $defender = 0.0
    foreach ($pair in (Get-SystemWorkCpu).GetEnumerator()) {
        if ($script:updateProcessNames.Contains($pair.Key)) { $update += $pair.Value }
        elseif ($script:defenderProcessNames.Contains($pair.Key)) { $defender += $pair.Value }
    }
    if ($s.SysCpuAt) {
        $elapsed = ($now - $s.SysCpuAt).TotalSeconds
        # Busy = at least half a core on average over the interval.
        if ($elapsed -gt 0 -and ($update - $s.SysCpuUpdate) / $elapsed -ge 0.5) { $s.UpdateSeconds += $elapsed }
        if ($elapsed -gt 0 -and ($defender - $s.SysCpuDefender) / $elapsed -ge 0.5) { $s.DefenderSeconds += $elapsed }
    }
    $s.SysCpuAt = $now
    $s.SysCpuUpdate = $update
    $s.SysCpuDefender = $defender
}

# ---------------------------------------------------------------- summary

function Format-Minutes {
    param([double]$Seconds)
    if ($Seconds -lt 90) { return "$([math]::Round($Seconds)) sn" }
    return "$([math]::Round($Seconds / 60)) dk"
}

# Called when BOOST ends. Writes the summary to the activity log and keeps short notices for the
# Akıllı durum lists until the next session.
function Complete-GameSession {
    $s = $script:session
    if (-not $s) { return }
    Stop-SessionMonitors
    $script:session = $null
    $ping = $script:pingMonitor
    $script:pingMonitor = $null
    if ($s.Games.Count -eq 0) { return }

    $now = Get-SessionNow
    $minutes = [math]::Max(1, [math]::Round(($now - $s.Started).TotalMinutes))
    $mode = if ($s.Mode -eq 'auto') { 'otomatik BOOST' } else { 'BOOST' }
    $title = "$($s.Games -join ', ') · $minutes dk · $mode"
    $lines = [Collections.Generic.List[string]]::new()
    $notes = [Collections.Generic.List[object]]::new()
    $lines.Add("OYUN ÖZETİ: $title")

    if ($s.GpuSamples -gt 0) {
        $vram = if ($s.GpuMaxVramMb -gt 0 -and $s.GpuVramTotalMb) { " · GPU belleği en yüksek $($s.GpuMaxVramMb) / $($s.GpuVramTotalMb) MB (tüm uygulamalar)" } else { '' }
        $lines.Add("  Ekran kartı: en yüksek $($s.GpuMaxTemp)°C$vram")
        $limitSeconds = ($s.ThermalSamples + $s.SlowdownSamples) * 5
        if ($limitSeconds -gt 0) { $lines.Add("  Isı / donanım yavaşlaması: ~$(Format-Minutes $limitSeconds)") }
        if ($s.BusySamples -ge 6) {
            $share = [math]::Round(100 * $s.PowerCapBusySamples / $s.BusySamples)
            $lines.Add("  Güç sınırı: yüksek yükte sürenin %$share'i (dizüstü ekran kartlarında normal; en yüksek güç prizde)")
        }
    } else { $lines.Add('  Ekran kartı: veri okunamadı') }
    $lines.Add("  Oyunun ekran kartı: $(if ($s.PlacementText) { $s.PlacementText } else { 'ölçülmedi (oyun kısa sürdü)' })")

    $ram = if ($s.MinFreeRamGb -lt [double]::MaxValue) { 'boş RAM en düşük {0:0.0} GB' -f $s.MinFreeRamGb } else { 'boş RAM ölçülmedi' }
    if ($s.PeakGameRamBytes -gt 0) { $ram += ' · oyunun RAM''i en yüksek {0:0.0} GB' -f ($s.PeakGameRamBytes / 1GB) }
    $lines.Add("  RAM: $ram")

    if ($ping) {
        $stats = $ping.Stats(50)
        if ($stats[0] -gt 0) {
            $average = if ($stats[2] -ge 0) { 'ortalama {0:0.#} ms, en yüksek {1:0} ms' -f $stats[2], $stats[3] } else { 'yanıt yok' }
            $lines.Add("  Modem gecikmesi: $average, $($stats[4]) sıçrama (50 ms üstü), kayıp $($stats[1])/$($stats[0])")
            # One lost ping in a short session is noise; warn on repeated loss or spikes.
            if ($stats[4] -ge 3 -or ($stats[1] -ge 2 -and ($stats[1] / $stats[0]) -gt 0.02)) {
                $notes.Add((New-Alert 'warning' 'Oyun sırasında Wi-Fi gecikmesi dalgalandı' `
                    "Modeme giden pingde $($stats[4]) sıçrama, $($stats[1]) kayıp. Ağ / Wi-Fi sayfasındaki önerileri uygula veya kablo kullan."))
            }
        }
    }

    if ($s.NetHeavySeconds -ge 60) {
        $average = [math]::Round($s.NetHeavyBits / 1e6 / $s.NetHeavySeconds)
        $lines.Add("  Arka plan indirme: ~$(Format-Minutes $s.NetHeavySeconds) boyunca ortalama $average Mbps (en yüksek $([math]::Round($s.NetMaxMbps)))")
        $notes.Add((New-Alert 'info' 'Oyun sırasında büyük indirme vardı' `
            "~$(Format-Minutes $s.NetHeavySeconds) boyunca $average Mbps. Oyunun kendisi, Steam, OneDrive veya Windows Update olabilir; hangisi olduğu yönetici izni olmadan görülemez."))
    }
    if ($s.UpdateSeconds -ge 60) {
        $lines.Add("  Windows Update: ~$(Format-Minutes $s.UpdateSeconds) arka planda çalıştı")
        $notes.Add((New-Alert 'info' 'Oyun sırasında Windows Update çalıştı' 'Ani takılmaların sebebi olabilir. Güncellemeleri oyun dışında bitir; Ayarlar > Windows Update > Etkin saatler.'))
    }
    if ($s.DefenderSeconds -ge 60) {
        $lines.Add("  Defender: ~$(Format-Minutes $s.DefenderSeconds) tarama yaptı")
        $notes.Add((New-Alert 'info' 'Oyun sırasında Defender taraması çalıştı' 'Takılmaların sebebi olabilir. Defender kapatılmamalı; taramalar genelde bilgisayar boştayken yapılır.'))
    }

    if ($s.ChargerDrop) { $lines.Add("  Güç: şarj aleti yetersiz (prizdeyken pil $($s.ChargerDrop))") }
    elseif ($s.PlayedOnBattery) { $lines.Add('  Güç: pilde oynandı (işlemci ve ekran kartı güç sınırında)') }
    else { $lines.Add('  Güç: prizde, sorun görülmedi') }

    foreach ($line in $lines) { Add-Log $line }
    $summary = New-Alert 'ok' "Son oyun: $title" 'Özet Etkinlik kutusunda.'
    $script:sessionAlerts = @($summary) + @($script:sessionAlerts) + @($notes)

    $pingStats = if ($ping) { $ping.Stats(50) } else { @(0, 0, -1, 0, 0) }
    Add-SessionHistory ([ordered]@{
        Date = $now.ToString('o'); Games = @($s.Games); Minutes = $minutes
        MinFreeRamGb = $(if ($s.MinFreeRamGb -lt [double]::MaxValue) { [math]::Round($s.MinFreeRamGb, 2) } else { $null })
        GpuMaxTemp = $s.GpuMaxTemp; LimitSeconds = ($s.ThermalSamples + $s.SlowdownSamples) * 5
        PingSent = $pingStats[0]; PingLost = $pingStats[1]; PingSpikes = $pingStats[4]
        ChargerWeak = [bool]$s.ChargerDrop; OnBattery = [bool]$s.PlayedOnBattery
        DownloadSeconds = [math]::Round($s.NetHeavySeconds); UpdateSeconds = [math]::Round($s.UpdateSeconds)
    })
    Update-TrendAlerts
}

# ---------------------------------------------------------------- history and trends

$script:sessionHistoryFile = Join-Path $script:settingsDirectory 'sessions.json'
$script:trendAlerts = @()

function Get-SessionHistory {
    if (-not (Test-Path -LiteralPath $script:sessionHistoryFile)) { return @() }
    # PowerShell 5.1 hands a JSON array back as one object; enumerate it into records.
    try {
        $data = Get-Content -LiteralPath $script:sessionHistoryFile -Raw | ConvertFrom-Json
        return @($data | ForEach-Object { $_ })
    } catch { return @() }
}

# Last 20 games, written to a temp file first and then swapped in, so a crash never leaves half a file.
function Add-SessionHistory {
    param($Record)
    try {
        $records = @(Get-SessionHistory) + @([pscustomobject]$Record)
        if ($records.Count -gt 20) { $records = @($records | Select-Object -Last 20) }
        $temp = "$($script:sessionHistoryFile).tmp"
        ConvertTo-Json -InputObject $records -Depth 4 | Set-Content -LiteralPath $temp -Encoding UTF8
        Move-Item -LiteralPath $temp -Destination $script:sessionHistoryFile -Force
    } catch { }
}

# Long-term advice from the last five games. Needs a pattern, never a single bad game.
function Update-TrendAlerts {
    $recent = @(Get-SessionHistory | Select-Object -Last 5)
    $alerts = [Collections.Generic.List[object]]::new()
    $n = $recent.Count
    if ($n -ge 3) {
        $lowRam = @($recent | Where-Object { $null -ne $_.MinFreeRamGb -and $_.MinFreeRamGb -lt 1.5 }).Count
        if ($lowRam -ge 3) {
            $alerts.Add((New-Alert 'info' 'RAM oyunlarda sık sık doluyor' "Son $n oyunun $lowRam tanesinde boş RAM 1,5 GB'ın altına indi. 2×16 GB DDR5-4800'e yükseltmek en etkili iyileştirme."))
        }
        $spiky = @($recent | Where-Object { $_.PingSpikes -ge 3 -or ($_.PingLost -ge 2 -and $_.PingLost / $_.PingSent -gt 0.02) }).Count
        if ($spiky -ge 3) {
            $alerts.Add((New-Alert 'info' 'Wi-Fi gecikmesi oyunlarda düzenli dalgalanıyor' "Son $n oyunun $spiky tanesinde. Ağ / Wi-Fi sayfasındaki önerileri uygula veya kablo kullan."))
        }
        $battery = @($recent | Where-Object OnBattery).Count
        if ($battery -ge 3) {
            $alerts.Add((New-Alert 'info' 'Oyunlar çoğunlukla pilde oynanıyor' "Son $n oyunun $battery tanesinde. Prizde işlemci ve ekran kartı çok daha yüksek güçle çalışır."))
        }
    }
    if ($n -ge 2) {
        $hot = @($recent | Where-Object { $_.LimitSeconds -ge 30 }).Count
        if ($hot -ge 2) {
            $alerts.Add((New-Alert 'warning' 'Ekran kartı oyunlarda sık ısınıyor' "Son $n oyunun $hot tanesinde ısıdan yavaşladı. Laptopu yükselt, hava girişlerini ve fanları temizlet; OMEN Gaming Hub'da fan/performans modunu kontrol et."))
        }
        $charger = @($recent | Where-Object ChargerWeak).Count
        if ($charger -ge 2) {
            $alerts.Add((New-Alert 'warning' 'Şarj aleti oyunlarda yetmiyor' "Son $n oyunun $charger tanesinde prizdeyken pil düştü. Laptopun kendi yüksek watt'lı adaptörünü kullan."))
        }
    }
    $script:trendAlerts = @($alerts)
}

Update-TrendAlerts
