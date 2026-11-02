# Read-only collectors and smart notices: system, displays, audio, network, devices and the full spec report.
# Nothing here changes the system. Slow collectors run only when their page is opened.

$script:insightCache = @{ Network = $null; NetworkAlerts = @(); Devices = $null; DeviceAlerts = @(); PadResult = $null }

function New-Alert {
    param([string]$Severity, [string]$Title, [string]$Detail = '')
    return [pscustomobject]@{ Severity = $Severity; Title = $Title; Detail = $Detail }
}

function Get-RegistryValue {
    param([string]$Path, [string]$Name)
    try { return (Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop).$Name } catch { return $null }
}

# ---------------------------------------------------------------- system (cheap)

function Get-EnabledStartupCount {
    $count = 0
    $pairs = @(
        @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Run', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'),
        @('HKLM:\Software\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run')
    )
    foreach ($pair in $pairs) {
        $run = Get-ItemProperty -LiteralPath $pair[0] -ErrorAction SilentlyContinue
        if (-not $run) { continue }
        $approved = Get-ItemProperty -LiteralPath $pair[1] -ErrorAction SilentlyContinue
        foreach ($property in $run.PSObject.Properties) {
            if ($property.Name -like 'PS*') { continue }
            $state = if ($approved) { $approved.PSObject.Properties[$property.Name] } else { $null }
            # StartupApproved: odd first byte means disabled.
            if ($state -and $state.Value -is [byte[]] -and ($state.Value[0] % 2) -eq 1) { continue }
            $count++
        }
    }
    return $count
}

function Get-SystemAlerts {
    $alerts = [Collections.Generic.List[object]]::new()
    try {
        $power = [Windows.Forms.SystemInformation]::PowerStatus
        if ($power.PowerLineStatus -eq [Windows.Forms.PowerLineStatus]::Offline) {
            $alerts.Add((New-Alert 'warning' "Pilde çalışıyor (%$([math]::Round($power.BatteryLifePercent * 100)))" 'Oyun için şarja tak; pilde işlemci ve ekran kartı güç sınırı çok düşer.'))
        } else {
            $alerts.Add((New-Alert 'ok' 'Şarj aleti takılı' 'İşlemci ve ekran kartı tam güç alabilir.'))
        }
    } catch { }

    $overlay = Get-RegistryValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes' 'ActiveOverlayAcPowerScheme'
    if ($overlay -eq 'ded574b5-45a0-4f42-8737-46345c09c238') {
        $alerts.Add((New-Alert 'ok' 'Güç modu: En iyi performans' 'Prizdeyken Windows işlemciyi kısmaz.'))
    } elseif ($overlay) {
        $alerts.Add((New-Alert 'warning' 'Güç modu "En iyi performans" değil' 'Ayarlar > Sistem > Güç ve pil > Güç modu: prizdeyken "En iyi performans" seç.'))
    }

    if ((Get-RegistryValue 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled') -eq 0) {
        $alerts.Add((New-Alert 'warning' 'Windows Oyun Modu kapalı' 'BOOST açar; kalıcı açmak için Oyun Ayarları sayfasını kullan.'))
    }
    if ((Get-RegistryValue 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled') -eq 1) {
        $alerts.Add((New-Alert 'warning' 'Arka plan oyun kaydı açık' 'Game DVR sürekli kayıt tutar ve FPS düşürür. Oyun Ayarları sayfasından kapat.'))
    }

    $memory = [GameBoostEngine]::MemoryGb()
    if ($memory[0] -lt 2.5) {
        $alerts.Add((New-Alert 'critical' ('Boş RAM çok az ({0:0.0} GB)' -f $memory[0]) 'Oyun takılır. BOOST, en çok RAM kullanan pencereleri kapatmayı önerir.'))
    } elseif ($memory[0] -lt 4) {
        $alerts.Add((New-Alert 'warning' ('Boş RAM az ({0:0.0} GB)' -f $memory[0]) 'Tarayıcı sekmelerini azalt veya BOOST kullan.'))
    }

    $uptime = [GameBoostEngine]::UptimeDays()
    if ($uptime -ge 7) {
        $detail = if ((Get-RegistryValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'HiberbootEnabled') -eq 1) {
            'Hızlı Başlangıç açık olduğu için Kapat/Aç sistemi sıfırlamaz; "Yeniden başlat" kullan.'
        } else { 'Bir yeniden başlatma belleği ve sürücüleri tazeler.' }
        $alerts.Add((New-Alert 'info' "$([math]::Floor($uptime)) gündür yeniden başlatılmadı" $detail))
    }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
        $alerts.Add((New-Alert 'warning' 'Windows Update yeniden başlatma bekliyor' 'Oyun sırasında güncelleme uyarısı çıkmaması için önce yeniden başlat.'))
    }

    foreach ($drive in [IO.DriveInfo]::GetDrives()) {
        try {
            if ($drive.DriveType -ne 'Fixed' -or -not $drive.IsReady -or $drive.TotalSize -le 0) { continue }
            $freePercent = 100.0 * $drive.AvailableFreeSpace / $drive.TotalSize
            if ($freePercent -lt 10) {
                $alerts.Add((New-Alert 'critical' "$($drive.Name.TrimEnd('\')) sürücüsü dolmak üzere" "Boş: $(Format-ByteSize $drive.AvailableFreeSpace). Akıllı Bakım sayfasından yer aç."))
            } elseif ($freePercent -lt 15 -or $drive.AvailableFreeSpace -lt 20GB) {
                $alerts.Add((New-Alert 'warning' "$($drive.Name.TrimEnd('\')) sürücüsünde yer azalıyor" "Boş: $(Format-ByteSize $drive.AvailableFreeSpace). Oyun güncellemeleri için en az 20 GB bırak."))
            }
        } catch { }
    }

    if (Test-Path 'C:\Program Files (x86)\Infatica') {
        $state = if (Get-Process -Name infatica_agent -ErrorAction SilentlyContinue) { 'kurulu ve şu an çalışıyor' } else { 'kurulu' }
        $alerts.Add((New-Alert 'warning' "Infatica proxy ajanı $state" 'İnternet bağlantını başkalarına kullandırır. Ayarlar > Uygulamalar''dan kaldır (yönetici gerekir).'))
    }
    if ($script:overlayEnabled -and (Test-Path $script:presentMonPath) -and -not (Test-PresentMonRights)) {
        $alerts.Add((New-Alert 'info' 'HUD açık ama FPS ölçülemiyor' 'FPS / HUD sayfasındaki yetki komutunu bir kez çalıştır.'))
    }
    $startup = Get-EnabledStartupCount
    if ($startup -gt 6) {
        $alerts.Add((New-Alert 'info' "Açılışta $startup uygulama başlıyor" 'Görev Yöneticisi > Başlangıç uygulamaları''ndan gereksizleri kapat.'))
    }
    return $alerts
}

# ---------------------------------------------------------------- displays (cheap, native)

function Get-DisplayAlerts {
    param($Monitors)
    $alerts = [Collections.Generic.List[object]]::new()
    $external = @($Monitors | Where-Object { -not $_.Internal })
    $cloned = @($Monitors | Where-Object Cloned)
    if ($cloned.Count -gt 0) {
        $outside = @($cloned | Where-Object { -not $_.Internal } | ForEach-Object Name) -join ', '
        $alerts.Add((New-Alert 'warning' "Ekranlar çoğaltılmış$(if ($outside) { " ($outside)" })" `
            'Çoğalt modunda görüntü Intel GPU üzerinden ve ortak düşük Hz''te verilir. Oyun için "Yalnızca harici" veya "Genişlet" seç.'))
    }
    foreach ($monitor in $Monitors) {
        $hz = [int][math]::Round($monitor.Refresh)
        if ($monitor.Cloned) {
            if ($hz -le 30) { $alerts.Add((New-Alert 'critical' "$($monitor.Name) $hz Hz'te çalışıyor" 'Çoğalt modundan çık; ardından 60 Hz veya üstünü seç.')) }
            continue
        }
        if ($hz -le 30) {
            $alerts.Add((New-Alert 'critical' "$($monitor.Name) $hz Hz'te çalışıyor" 'Görüntü takılır. 60 Hz veya üstünü seç; seçilemiyorsa başka kablo/port dene.'))
        } elseif ($monitor.MaxRefreshAtResolution -gt $hz + 1) {
            $alerts.Add((New-Alert 'warning' "$($monitor.Name) $hz Hz'te, $($monitor.MaxRefreshAtResolution) Hz destekliyor" 'Ekran / TV sayfasındaki "En yüksek Hz''e geç" 15 sn onaylı geçiş yapar.'))
        } elseif ($hz -ge 100) {
            $alerts.Add((New-Alert 'ok' "$($monitor.Name): $hz Hz" 'Bu çözünürlükte en yüksek yenileme hızında.'))
        }
        if (-not $monitor.Internal -and $monitor.Adapter -like '*NVIDIA*') {
            $alerts.Add((New-Alert 'ok' "$($monitor.Name) doğrudan NVIDIA'ya bağlı" 'Oyunlar bu ekranda en düşük gecikmeyle çalışır; görüntü Intel üzerinden kopyalanmaz.'))
        } elseif (-not $monitor.Internal -and $script:hasNvidiaGpu -and $monitor.Adapter -like '*Intel*') {
            $alerts.Add((New-Alert 'info' "$($monitor.Name) Intel GPU üzerinden bağlı" 'Oyun görüntüsü NVIDIA''dan Intel''e kopyalanır; mümkünse HDMI çıkışını kullan.'))
        }
        if ($monitor.Width -ge 3840) {
            $alerts.Add((New-Alert 'info' "$($monitor.Name) 4K masaüstünde" '4 GB VRAM için oyunda 1080p/1440p + DLSS kullan.'))
        }
    }
    if ($cloned.Count -eq 0 -and $external.Count -gt 0 -and @($Monitors | Where-Object Internal).Count -gt 0) {
        $alerts.Add((New-Alert 'info' 'Laptop ekranı ve harici ekran birlikte açık' 'Oyun sırasında "Yalnızca harici ekran" Intel GPU yükünü ve ısıyı azaltır.'))
    }
    if ($Monitors.Count -eq 0) { $alerts.Add((New-Alert 'warning' 'Ekran bilgisi okunamadı' 'Yenile düğmesiyle tekrar dene.')) }
    return $alerts
}

# ---------------------------------------------------------------- audio (cheap, native)

function Get-AudioFormFactorName {
    param([int]$Code)
    switch ($Code) {
        1 { 'Hoparlör' } 2 { 'Hat çıkışı' } 3 { 'Kulaklık' } 4 { 'Mikrofon' } 5 { 'Kulaklık + mikrofon' }
        6 { 'Ahize' } 7 { 'Dijital' } 8 { 'S/PDIF' } 9 { 'HDMI / DisplayPort' } 0 { 'Ağ' } default { 'Diğer' }
    }
}

function Get-AudioFormatText {
    param($Device)
    if ($Device.SampleRate -le 0) { return '—' }
    return '{0:0.#} kHz · {1} bit · {2} kanal' -f ($Device.SampleRate / 1000), $Device.Bits, $Device.Channels
}

function Get-AudioAlerts {
    param($Devices)
    $alerts = [Collections.Generic.List[object]]::new()
    $outputs = @($Devices | Where-Object { -not $_.IsCapture -and $_.Active })
    $default = $outputs | Where-Object IsDefault | Select-Object -First 1
    if (-not $default) {
        $alerts.Add((New-Alert 'warning' 'Varsayılan ses çıkışı yok' 'Ses ayarlarından bir çıkış aygıtı seç.'))
        return $alerts
    }
    if ($default.Muted) {
        $alerts.Add((New-Alert 'warning' "$($default.Name) sessizde" 'Görev çubuğundaki ses simgesinden sesi aç.'))
    } elseif ($default.Volume -ge 0 -and $default.Volume -lt 0.05) {
        $alerts.Add((New-Alert 'warning' 'Ses seviyesi çok düşük' "$($default.Name): %$([math]::Round($default.Volume * 100))"))
    }
    if ($default.Name -match 'Hands-?Free|Eller Serbest') {
        $alerts.Add((New-Alert 'warning' 'Bluetooth kulaklık Hands-Free modunda' 'Ses kalitesi düşük, gecikme yüksek. Aynı kulaklığın "Stereo" çıkışını varsayılan yap.'))
    } elseif ($default.Enumerator -match 'BTH') {
        $alerts.Add((New-Alert 'info' 'Bluetooth kulaklık kullanılıyor' 'Kablosuz seste 100-200 ms gecikme olabilir; rekabetçi oyunda kablolu kulaklık daha iyi.'))
    }
    if ($default.SampleRate -gt 48000) {
        $alerts.Add((New-Alert 'info' ('Çıkış {0:0} kHz' -f ($default.SampleRate / 1000)) 'Oyun için 48 kHz yeterli; daha yüksek değer fayda sağlamaz, işlem yükü ekler.'))
    }
    $alerts.Add((New-Alert 'ok' "Ses çıkışı: $($default.Name)" (Get-AudioFormatText $default)))
    foreach ($display in @($outputs | Where-Object { $_.FormFactor -eq 9 -and -not $_.IsDefault })) {
        $alerts.Add((New-Alert 'info' "$($display.Name) ses çıkışı hazır" 'Sesi monitör/TV''den almak istersen Ses ayarlarından varsayılan yap.'))
    }
    $communications = $outputs | Where-Object IsDefaultCommunications | Select-Object -First 1
    if ($communications -and $communications.Id -ne $default.Id) {
        $alerts.Add((New-Alert 'info' 'Sesli sohbet farklı aygıttan çıkıyor' "Discord/Teams sesi: $($communications.Name)"))
    }
    foreach ($alert in (Get-MicrophoneAlerts $Devices)) { $alerts.Add($alert) }
    return $alerts
}

function Get-DefaultMicrophone {
    param($Devices = @([GameBoostAudio]::GetDevices()))
    return $Devices | Where-Object { $_.IsCapture -and $_.IsDefault -and $_.Active } | Select-Object -First 1
}

function Test-MicrophonePrivacyBlocked {
    $base = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone'
    return (Get-RegistryValue $base 'Value') -eq 'Deny' -or (Get-RegistryValue "$base\NonPackaged" 'Value') -eq 'Deny'
}

function Get-MicrophoneAlerts {
    param($Devices)
    $alerts = [Collections.Generic.List[object]]::new()
    if (Test-MicrophonePrivacyBlocked) {
        $alerts.Add((New-Alert 'warning' 'Masaüstü uygulamalarının mikrofon izni kapalı' 'Discord ve oyunlar mikrofonu kullanamaz. Ayarlar > Gizlilik ve güvenlik > Mikrofon.'))
    }
    $microphone = Get-DefaultMicrophone $Devices
    if (-not $microphone) {
        $alerts.Add((New-Alert 'info' 'Varsayılan mikrofon yok' 'Sesli sohbet için Ses ayarlarından bir mikrofon seç.'))
        return $alerts
    }
    if ($microphone.Muted) {
        $alerts.Add((New-Alert 'warning' 'Mikrofon sessizde' "$($microphone.Name). Ses ayarlarından mikrofonun sesini aç."))
    } elseif ($microphone.Volume -ge 0 -and $microphone.Volume -lt 0.6) {
        $alerts.Add((New-Alert 'info' "Mikrofon seviyesi düşük (%$([math]::Round($microphone.Volume * 100)))" 'Karşı taraf sesini az duyabilir. Ses sayfasındaki "Seviyeyi %100 yap" ile artır.'))
    }
    # A plugged-in headset mic that the chat default ignores is the classic "they can't hear me" cause.
    $headset = $Devices | Where-Object { $_.IsCapture -and $_.Active -and ($_.FormFactor -eq 5 -or $_.Name -match 'Headset|Kulaklık') } | Select-Object -First 1
    $chat = $Devices | Where-Object { $_.IsCapture -and $_.IsDefaultCommunications -and $_.Active } | Select-Object -First 1
    if ($headset -and $chat -and $chat.Id -ne $headset.Id) {
        $alerts.Add((New-Alert 'warning' 'Kulaklık mikrofonu takılı ama sohbette kullanılmıyor' `
            "Varsayılan sohbet mikrofonu: $($chat.Name). Discord ""Varsayılan"" ayarındaysa bu mikrofonu kullanır. Ses ayarlarından kulaklık mikrofonunu varsayılan yap veya Discord > Ses ve Görüntü'den seç."))
    }
    return $alerts
}

# ---------------------------------------------------------------- background audit (on demand)

# Runs in its own runspace (self-contained: no calls to the app's functions). Watches for
# $Seconds and returns findings. Read-only: nothing is closed, paused or changed.
function Invoke-BackgroundAuditScan {
    param([string[]]$IgnoreNames, [int]$Seconds = 10)
    $ignore = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $IgnoreNames) { [void]$ignore.Add($name) }
    $proxyPattern = 'infatica|honeygain|pawns|packetstream|earnapp|iproyal|peer2profit|repocket|traffmonetizer|bitping|mysterium'
    $minerPattern = 'xmrig|nicehash|minergate|phoenixminer|t-rex|lolminer|nbminer|gminer|ethminer|cpuminer|nanominer|teamredminer'
    $oddFolder = '\\AppData\\Local\\Temp\\|\\Downloads\\|\\Users\\Public\\|\\AppData\\Roaming\\'
    $raw = [Collections.Generic.List[object]]::new()
    $signatures = @{}
    function Test-Signed {
        param([string]$Path)
        if (-not $signatures.ContainsKey($Path)) {
            $signature = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction SilentlyContinue
            $signatures[$Path] = $signature -and $signature.Status -eq 'Valid'
        }
        return $signatures[$Path]
    }
    function Add-Finding {
        param([string]$Kind, [string]$Severity, [string]$Name, [string]$Path, [string]$Detail, [double]$Value = 0)
        $raw.Add([pscustomobject]@{ Kind = $Kind; Severity = $Severity; Name = $Name; Path = $Path; Detail = $Detail; Value = $Value })
    }

    # GPU engine counters started now and read at the end give the average use over the window.
    $gpuCounters = [Collections.Generic.List[object]]::new()
    try {
        foreach ($instance in [Diagnostics.PerformanceCounterCategory]::new('GPU Engine').GetInstanceNames()) {
            if ($instance -notmatch '^pid_(\d+)_.*engtype_(3D|Compute)') { continue }
            $counter = [Diagnostics.PerformanceCounter]::new('GPU Engine', 'Utilization Percentage', $instance, $true)
            [void]$counter.NextValue()
            $gpuCounters.Add([pscustomobject]@{ ProcessId = [int]$Matches[1]; Counter = $counter })
        }
    } catch { }
    $started = [datetime]::UtcNow
    $before = @{}
    foreach ($process in [GameBoostEngine]::Snapshot()) { if ($process.CreateTime) { $before[$process.Key] = $process.CpuSeconds } }
    Start-Sleep -Seconds $Seconds
    $snapshot = [GameBoostEngine]::Snapshot()
    $elapsed = ([datetime]::UtcNow - $started).TotalSeconds
    $gpuByPid = @{}
    foreach ($item in $gpuCounters) {
        try { $gpuByPid[$item.ProcessId] = [double]$gpuByPid[$item.ProcessId] + $item.Counter.NextValue() } catch { }
        $item.Counter.Dispose()
    }
    $cores = [Environment]::ProcessorCount

    foreach ($process in $snapshot) {
        if ($process.Id -le 4 -or $process.Id -eq $PID -or -not $process.Path) { continue }
        $name = $process.Name
        $path = $process.Path
        if ($name -match $proxyPattern) {
            Add-Finding 'proxy' 'warning' $name $path 'İnternet bağlantını başkalarına kullandırır. Ayarlar > Uygulamalar''dan kaldır (yönetici gerekir).'
            continue
        }
        if ($name -match $minerPattern) {
            Add-Finding 'miner' 'critical' $name $path 'Kripto madencilik aracı. Sen kurmadıysan zararlı yazılım taraması yap ve kaldır.'
            continue
        }
        if ($ignore.Contains($name) -or $path -like "$env:SystemRoot\*" -or [GameBoostEngine]::IsGameLibraryPath($path)) { continue }
        $cpu = if ($elapsed -gt 0 -and $before.ContainsKey($process.Key)) {
            [math]::Round(($process.CpuSeconds - $before[$process.Key]) / $elapsed / $cores * 100, 1)
        } else { 0 }
        $gpu = [math]::Round([double]$gpuByPid[$process.Id], 1)
        if ($path -match $oddFolder -and -not (Test-Signed $path)) {
            Add-Finding 'odd' 'warning' $name $path 'İmzasız ve alışılmadık bir klasörden çalışıyor. Tanımıyorsan zararlı yazılım taraması yap.'
        }
        if (-not $process.HasWindow) {
            if ($gpu -ge 20) {
                Add-Finding 'gpu' 'warning' $name $path "Penceresi olmadan ekran kartını %$gpu kullanıyor. Tanımıyorsan gizli madenci olabilir." $gpu
            } elseif ($cpu -ge 5) {
                $severity = if (Test-Signed $path) { 'info' } else { 'warning' }
                Add-Finding 'cpu' $severity $name $path "Penceresi olmadan işlemci kullanıyor: %$cpu (yaklaşık $([math]::Round($cpu * $cores / 100, 1)) çekirdek)." $cpu
            } elseif ($process.WorkingSet -ge 1.5GB) {
                Add-Finding 'ram' 'info' $name $path ('Penceresi olmadan {0:0.0} GB RAM tutuyor.' -f ($process.WorkingSet / 1GB)) ($process.WorkingSet / 1GB)
            }
        }
    }

    # Start-up entries: scheduled tasks and Run keys that launch from user-writable folders.
    $startup = [Collections.Generic.List[object]]::new()
    try {
        foreach ($task in Get-ScheduledTask -ErrorAction Stop) {
            if ($task.State -eq 'Disabled') { continue }
            foreach ($action in $task.Actions) {
                if (-not $action.Execute) { continue }
                $startup.Add([pscustomobject]@{ Label = "Zamanlanmış görev $($task.TaskPath)$($task.TaskName)"; Name = $task.TaskName
                    Path = [Environment]::ExpandEnvironmentVariables(([string]$action.Execute).Trim().Trim('"')) })
            }
        }
    } catch { }
    foreach ($key in 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run') {
        $values = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
        if (-not $values) { continue }
        foreach ($property in $values.PSObject.Properties) {
            if ($property.Name -like 'PS*') { continue }
            $command = [Environment]::ExpandEnvironmentVariables([string]$property.Value).Trim()
            $exe = if ($command.StartsWith('"')) { $command.Split('"')[1] } else { ([regex]::Match($command, '^.*?\.exe', 'IgnoreCase')).Value }
            if ($exe) { $startup.Add([pscustomobject]@{ Label = "Başlangıç kaydı $($property.Name)"; Name = $property.Name; Path = $exe }) }
        }
    }
    foreach ($entry in $startup) {
        if ($entry.Path -match $proxyPattern -or $entry.Name -match $proxyPattern) {
            Add-Finding 'proxy-start' 'warning' $entry.Label $entry.Path 'Her oturum açılışında internet paylaşım ajanını başlatır.'
        } elseif ($entry.Path -match $minerPattern) {
            Add-Finding 'miner-start' 'critical' $entry.Label $entry.Path 'Açılışta kripto madencilik aracı başlatıyor.'
        } elseif ($entry.Path -match $oddFolder) {
            if (-not (Test-Path -LiteralPath $entry.Path)) {
                Add-Finding 'start-missing' 'info' $entry.Label $entry.Path 'Artık var olmayan bir dosyayı çalıştırmaya çalışıyor; silinebilir.'
            } elseif (-not (Test-Signed $entry.Path)) {
                Add-Finding 'start-odd' 'warning' $entry.Label $entry.Path 'Alışılmadık klasördeki imzasız bir dosyayı açılışta çalıştırıyor.'
            }
        }
    }

    # One line per app and kind (browsers and editors run many processes).
    $findings = @($raw | Group-Object Kind, Name | ForEach-Object {
        $first = $_.Group[0]
        $total = ($_.Group | Measure-Object Value -Sum).Sum
        $first.Value = $total
        if ($first.Kind -eq 'cpu') { $first.Detail = "Penceresi olmadan işlemci kullanıyor: %$([math]::Round($total, 1)), $($_.Count) süreç." }
        $first
    })
    return [pscustomobject]@{
        Findings = $findings; Scanned = $snapshot.Count; Seconds = [math]::Round($elapsed)
        GpuMeasured = $gpuCounters.Count -gt 0; StartupChecked = $startup.Count
    }
}

# ---------------------------------------------------------------- USB-C display (on demand)

# Windows cannot report whether the USB-C port carries video until something is plugged in.
# What it does leave behind: the port controller (UCSI), USB4/Thunderbolt, and a "Billboard"
# device whenever a USB-C display or adapter asked for video mode and it could not be set up.
function Get-UsbCDisplayInfo {
    $info = [pscustomobject]@{ HasTypeC = $false; Usb4 = $false; BillboardPresent = $false; BillboardAt = $null }
    $devices = @(Get-PnpDevice -Class UCM, USBDevice, USB -ErrorAction SilentlyContinue |
        Where-Object { $_.FriendlyName -match 'UCSI|Billboard|USB4|Thunderbolt' })
    $info.HasTypeC = @($devices | Where-Object { $_.FriendlyName -match 'UCSI' -and $_.Present }).Count -gt 0
    $info.Usb4 = @($devices | Where-Object { $_.FriendlyName -match 'USB4|Thunderbolt' -and $_.Present }).Count -gt 0
    $billboard = $devices | Where-Object FriendlyName -match 'Billboard' | Select-Object -First 1
    if ($billboard) {
        $info.BillboardPresent = [bool]$billboard.Present
        $info.BillboardAt = (Get-PnpDeviceProperty -InstanceId $billboard.InstanceId -KeyName 'DEVPKEY_Device_LastArrivalDate' -ErrorAction SilentlyContinue).Data
    }
    return $info
}

function Get-UsbCAlerts {
    param($Info, $Monitors)
    $alerts = [Collections.Generic.List[object]]::new()
    if (-not $Info -or -not $Info.HasTypeC) { return $alerts }
    if ($Info.BillboardPresent) {
        $alerts.Add((New-Alert 'warning' 'USB-C aygıtı görüntü moduna geçemedi' `
            'Takılı USB-C monitör/adaptör görüntü (DisplayPort Alt Mode) istiyor ama bağlantı kurulamadı. Görüntü destekli USB-C kablo kullan veya monitörü HDMI ile bağla.'))
    } elseif ($Info.BillboardAt -and $Info.BillboardAt -gt (Get-Date).AddDays(-14)) {
        $alerts.Add((New-Alert 'info' "USB-C görüntü denemesi kurulamamış ($($Info.BillboardAt.ToString('dd.MM.yyyy')))" `
            'O gün takılan USB-C aygıtı görüntü modu istedi ama girilemedi: kablo veya adaptör görüntü taşımıyor ya da port bu adaptörü desteklemiyor.'))
    }
    $usbC = @($Monitors | Where-Object { $_.OutputTechnology -in 10, 18 -and -not $_.Internal })
    if ($usbC.Count -gt 0 -and ($usbC | Where-Object { $_.Adapter -like '*Intel*' }) -and $script:hasNvidiaGpu) {
        $alerts.Add((New-Alert 'info' 'USB-C / DisplayPort ekran Intel üzerinden bağlı' 'Oyunlar bu ekranda NVIDIA görüntüsünün kopyasıyla çalışır; oyun için HDMI (doğrudan NVIDIA) daha hızlı.'))
    } elseif ($usbC.Count -eq 0) {
        $alerts.Add((New-Alert 'info' 'USB-C ile ekran bağlamak için' `
            'Monitörde USB-C girişi yoksa USB-C→DisplayPort/HDMI kablosu gerekir ve kablo "görüntü (DP Alt Mode)" desteklemeli; şarj kabloları görüntü taşımaz. Portun görüntü desteği HP''nin model sayfasında yazar. Oyun için HDMI zaten en iyi yol: doğrudan NVIDIA''ya bağlı.'))
    }
    return $alerts
}

# ---------------------------------------------------------------- network (slow: CIM + netsh)

$script:wifiPowerSubgroup = '19cbb8fa-5279-450e-9fac-8a3d5fedd0c1'
$script:wifiPowerSetting = '12bbebe6-58d6-4636-95bb-3217ef867c1a'
$script:wifiRecommendations = @(
    @{ Keyword = 'IEEE11nMode'; Label = 'Kablosuz ağ modu'; Pick = 'max'; Why = 'Wi-Fi 6/6E: daha yüksek hız, daha kararlı gecikme' }
    @{ Keyword = 'RoamingPreferredBandType'; Label = 'Tercih edilen bant'; Prefer = @('4', '2'); Why = '2,4 GHz yerine 5/6 GHz' }
    @{ Keyword = 'RoamAggressiveness'; Label = 'Gezinme hassasiyeti'; Prefer = @('0'); Why = 'Sabit masada gereksiz ağ taramasını azaltır' }
    @{ Keyword = 'MIMOPowerSaveMode'; Label = 'MIMO güç tasarrufu'; Prefer = @('3'); Why = 'Tüm antenler açık kalır' }
    @{ Keyword = '*PacketCoalescing'; Label = 'Paket birleştirme'; Prefer = @('0'); Why = 'Paketler bekletilmez; pil biraz daha çabuk biter' }
    @{ Keyword = 'uAPSDSupport'; Label = 'U-APSD güç tasarrufu'; Prefer = @('0'); Why = 'Uyku kaynaklı gecikmeyi önler' }
)

function Get-WifiGeneration {
    param([string]$Description)
    if ($Description -match 'Wi-?Fi 7|BE2\d\d') { return 'Wi-Fi 7' }
    if ($Description -match '6E|AX21[01]|AX411') { return 'Wi-Fi 6E' }
    if ($Description -match 'Wi-?Fi 6|AX\d{3}') { return 'Wi-Fi 6' }
    if ($Description -match 'AC|Wi-?Fi 5') { return 'Wi-Fi 5' }
    return ''
}

function Get-NetworkInfo {
    $info = [pscustomobject]@{
        Wifi = $null; Ethernet = $null; Props = @(); Rows = @(); LocationBlocked = $false
        Ssid = $null; Signal = $null; Channel = $null; Band = $null; RadioType = $null; ReceiveRate = $null
        PowerSavingAc = -1; PowerScheme = $null; Gateway = $null; IPv4 = $null; Generation = ''; ActiveMode = $null
    }
    $adapters = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue)
    $info.Wifi = $adapters | Where-Object { $_.MediaType -eq 'Native 802.11' -or $_.InterfaceDescription -match 'Wi-?Fi|Wireless|WLAN' } | Select-Object -First 1
    $info.Ethernet = $adapters | Where-Object { $_.MediaType -eq '802.3' -and $_.InterfaceDescription -notmatch 'Virtual|Hyper-V' } | Select-Object -First 1
    # During BOOST the high performance plan is temporary; the user's own plan is the one to show and change.
    $info.PowerScheme = if ($script:boosted -and $script:previousPowerScheme) { $script:previousPowerScheme } else { Get-ActivePowerScheme }
    if ($info.PowerScheme) {
        $info.PowerSavingAc = [GameBoostPower]::ReadValue($info.PowerScheme, $script:wifiPowerSubgroup, $script:wifiPowerSetting, $true)
    }

    if ($info.Wifi) {
        $info.Generation = Get-WifiGeneration $info.Wifi.InterfaceDescription
        $info.Props = @(Get-NetAdapterAdvancedProperty -Name $info.Wifi.Name -ErrorAction SilentlyContinue)
        $mode = $info.Props | Where-Object RegistryKeyword -eq 'IEEE11nMode' | Select-Object -First 1
        if ($mode) { $info.ActiveMode = ($mode.DisplayValue -replace '^\d+\.\s*', '') }
        $netsh = (netsh.exe wlan show interfaces 2>$null | Out-String)
        $info.LocationBlocked = $netsh -match 'location permission|privacy-location|[Kk]onum'
        if (-not $info.LocationBlocked) {
            foreach ($line in ($netsh -split "`r?`n")) {
                if ($line -match '^\s*SSID\s*:\s*(.+)$') { $info.Ssid = $Matches[1].Trim() }
                elseif ($line -match '^\s*(Radio type|Radyo t\S+)\s*:\s*(.+)$') { $info.RadioType = $Matches[2].Trim() }
                elseif ($line -match '^\s*(Channel|Kanal)\s*:\s*(\d+)') { $info.Channel = [int]$Matches[2] }
                elseif ($line -match '^\s*(Band|Bant)\s*:\s*(.+)$') { $info.Band = $Matches[2].Trim() }
                elseif ($line -match '^\s*(Signal|Sinyal)\s*:\s*(\d+)\s*%') { $info.Signal = [int]$Matches[2] }
                elseif ($line -match '^\s*(Receive rate|Alma h\S+)[^:]*:\s*([\d.,]+)') { $info.ReceiveRate = $Matches[2] }
            }
            if (-not $info.Band -and $info.Channel) { $info.Band = if ($info.Channel -le 14) { '2,4 GHz' } else { '5 GHz' } }
        }
        if (-not $info.Band -and $info.Wifi.Status -eq 'Up') {
            # Without location permission: Wi-Fi 5 links above 300 Mbps can only be 5 GHz.
            $mbps = $info.Wifi.ReceiveLinkSpeed / 1e6
            if ($mbps -gt 300) { $info.Band = '5 GHz (bağlantı hızından tahmin)' }
            elseif ($mbps -gt 0 -and $mbps -le 150) { $info.Band = 'Muhtemelen 2,4 GHz' }
        }
        $info.Rows = @(Get-WifiSettingRows $info)
    }

    $active = if ($info.Wifi -and $info.Wifi.Status -eq 'Up') { $info.Wifi } elseif ($info.Ethernet -and $info.Ethernet.Status -eq 'Up') { $info.Ethernet } else { $null }
    if ($active) {
        foreach ($interface in [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
            if ($interface.Name -ne $active.Name) { continue }
            $properties = $interface.GetIPProperties()
            $info.Gateway = @($properties.GatewayAddresses | Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' } | ForEach-Object { $_.Address.IPAddressToString }) | Select-Object -First 1
            $info.IPv4 = @($properties.UnicastAddresses | Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' } | ForEach-Object { $_.Address.IPAddressToString }) | Select-Object -First 1
        }
    }
    return $info
}

function Get-WifiPowerName {
    param([int]$Value)
    switch ($Value) { 0 { 'Maksimum performans' } 1 { 'Düşük tasarruf' } 2 { 'Orta tasarruf' } 3 { 'Maksimum tasarruf' } default { 'Okunamadı' } }
}

function Get-WifiSettingRows {
    param($Info)
    $rows = [Collections.Generic.List[object]]::new()
    foreach ($rule in $script:wifiRecommendations) {
        $property = $Info.Props | Where-Object RegistryKeyword -eq $rule.Keyword | Select-Object -First 1
        if (-not $property -or -not $property.ValidRegistryValues) { continue }
        $valid = @($property.ValidRegistryValues | ForEach-Object { [string]$_ })
        $recommended = $null
        if ($rule.Pick -eq 'max') { $recommended = [string](@($valid | ForEach-Object { [int]$_ }) | Measure-Object -Maximum).Maximum }
        else { $recommended = $rule.Prefer | Where-Object { $_ -in $valid } | Select-Object -First 1 }
        if ($null -eq $recommended) { continue }
        $current = [string](@($property.RegistryValue)[0])
        $index = [array]::IndexOf($valid, $recommended)
        $recommendedText = if ($index -ge 0) { [string]$property.ValidDisplayValues[$index] } else { $recommended }
        $rows.Add([pscustomobject]@{
            Keyword = $rule.Keyword; Label = $rule.Label; Why = $rule.Why
            Current = ($property.DisplayValue -replace '^\d+\.\s*', ''); CurrentValue = $current
            Recommended = ($recommendedText -replace '^\d+\.\s*', ''); RecommendedValue = $recommended
            Ok = ($current -eq $recommended)
        })
    }
    if ($Info.PowerSavingAc -ge 0) {
        $rows.Add([pscustomobject]@{
            Keyword = 'PowerPlan'; Label = 'Güç tasarrufu (prizde)'; Why = 'Wi-Fi kartı uykuya geçip gecikme yaratmaz'
            Current = (Get-WifiPowerName $Info.PowerSavingAc); CurrentValue = [string]$Info.PowerSavingAc
            Recommended = 'Maksimum performans'; RecommendedValue = '0'; Ok = ($Info.PowerSavingAc -eq 0)
        })
    }
    return $rows
}

function Get-NetworkAlerts {
    param($Info)
    $alerts = [Collections.Generic.List[object]]::new()
    if (-not $Info) { return $alerts }
    if ($Info.Wifi -and $Info.Wifi.Status -eq 'Up') {
        $mbps = [math]::Round($Info.Wifi.ReceiveLinkSpeed / 1e6)
        $modeRow = $Info.Rows | Where-Object Keyword -eq 'IEEE11nMode' | Select-Object -First 1
        if ($modeRow -and -not $modeRow.Ok -and $Info.Generation -match 'Wi-Fi [67]') {
            $alerts.Add((New-Alert 'warning' "$($Info.Generation) kartın $($modeRow.Current) modunda sınırlı" 'Ağ / Wi-Fi sayfasındaki "Önerilenleri uygula" ile aç. Modemin Wi-Fi 6 değilse zararı yok.'))
        }
        if ($mbps -gt 0 -and $mbps -lt 150) {
            $alerts.Add((New-Alert 'warning' "Wi-Fi bağlantı hızı düşük ($mbps Mbps)" 'Modeme yaklaş, 5 GHz ağa bağlan veya kablo kullan.'))
        } elseif ($mbps -gt 0) {
            $alerts.Add((New-Alert 'ok' "Wi-Fi bağlantı hızı $mbps Mbps" $(if ($Info.Band) { $Info.Band } else { '' })))
        }
        if ($Info.Band -like '2,4*' -or $Info.Band -like 'Muhtemelen 2,4*') {
            $alerts.Add((New-Alert 'warning' '2,4 GHz banda bağlı' 'Bu bant kalabalıktır ve Bluetooth ile çakışır; 5 GHz ağa geç.'))
        }
        if ($null -ne $Info.Signal -and $Info.Signal -lt 50) {
            $alerts.Add((New-Alert 'warning' "Wi-Fi sinyali zayıf (%$($Info.Signal))" 'Ping dalgalanır. Modeme yaklaş veya arada duvar olmasın.'))
        }
        $pending = @($Info.Rows | Where-Object { -not $_.Ok -and $_.Keyword -ne 'IEEE11nMode' })
        if ($pending.Count -gt 0) {
            $alerts.Add((New-Alert 'info' "$($pending.Count) Wi-Fi sürücü ayarı oyun için iyileştirilebilir" ($pending.Label -join ', ')))
        }
        if ($Info.LocationBlocked) {
            $alerts.Add((New-Alert 'info' 'Ağ adı, kanal ve sinyal gizli' 'Windows bunlar için Konum izni istiyor. İstersen "Konum izni" düğmesinden aç.'))
        }
        if ($Info.Ethernet -and $Info.Ethernet.Status -ne 'Up') {
            $alerts.Add((New-Alert 'info' 'Kablolu bağlantı mümkün' "$($Info.Ethernet.InterfaceDescription) boşta; çevrim içi oyunda en düşük ping kabloyla alınır."))
        }
    } elseif ($Info.Ethernet -and $Info.Ethernet.Status -eq 'Up') {
        $alerts.Add((New-Alert 'ok' 'Kablolu bağlantı kullanılıyor' "Hız: $($Info.Ethernet.LinkSpeed). Oyun için en iyi seçenek."))
    } else {
        $alerts.Add((New-Alert 'warning' 'Ağ bağlantısı yok' 'Wi-Fi veya kablo bağlantısını kontrol et.'))
    }
    return $alerts
}

function Get-PingVerdict {
    param([double[]]$Gateway, [double[]]$Internet)
    if ($Gateway[0] -lt 0) { return @('critical', 'Modem yanıt vermiyor; bağlantıyı kontrol et.') }
    if ($Gateway[4] -gt 0) { return @('warning', 'Modeme giden paketlerde kayıp var: Wi-Fi sinyali veya parazit sorunu.') }
    if ($Gateway[0] -gt 10 -or $Gateway[3] -gt 8) { return @('warning', 'Modeme gecikme yüksek veya dalgalı: Wi-Fi kalitesi zayıf.') }
    if ($Internet[0] -lt 0) { return @('warning', 'İnternet yanıt vermiyor; modem/servis sağlayıcıyı kontrol et.') }
    if ($Internet[4] -gt 10) { return @('warning', 'İnternet tarafında paket kaybı var; sorun modem dışında olabilir.') }
    if ($Internet[0] -gt 60) { return @('info', 'Ev ağı iyi; internet gecikmesi servis sağlayıcıdan geliyor.') }
    return @('ok', 'Ağ oyun için uygun: düşük gecikme, kararlı bağlantı.')
}

# Admin scripts are built in memory and handed to the elevated PowerShell after the UAC prompt.
function Get-WifiBackupPath { return Join-Path $script:settingsDirectory 'wifi-backup.json' }
function Get-WifiResultPath { return Join-Path $script:settingsDirectory 'wifi-result.txt' }

# The first backup is kept until a revert is verified, so the original values are never lost.
function Save-WifiBackup {
    param($Info)
    $path = Get-WifiBackupPath
    if (Test-Path -LiteralPath $path) { return }
    $values = [ordered]@{}
    foreach ($row in $Info.Rows) { $values[$row.Keyword] = $row.CurrentValue }
    [ordered]@{ Adapter = $Info.Wifi.Name; PowerScheme = $Info.PowerScheme; Values = $values; SavedAt = (Get-Date).ToString('o') } |
        ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $path -Encoding UTF8
}

# Text going into the elevated script as a '...' literal; also escapes the typographic quotes
# PowerShell accepts as single quotes.
function ConvertTo-ScriptLiteral {
    param([string]$Text)
    return "'" + [Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($Text) + "'"
}

# Applies the values, then reads them back. The result goes to wifi-result.txt; the backup is
# removed only when a revert is verified. The values may come from wifi-backup.json, which any
# program of this user can edit, so nothing reaches the admin script unchecked or unquoted.
function Get-WifiScriptLines {
    param([string]$Adapter, $Values, [string]$PowerScheme, [string]$RemoveBackupWhenVerified)
    $lines = [Collections.Generic.List[string]]::new()
    $adapterValues = [ordered]@{}
    $power = $null
    $allowedKeywords = @($script:wifiRecommendations | ForEach-Object { $_.Keyword })
    foreach ($entry in $Values.GetEnumerator()) {
        if ($entry.Key -eq 'PowerPlan') { $power = [int]$entry.Value }
        elseif ($entry.Key -in $allowedKeywords) { $adapterValues[$entry.Key] = [string]$entry.Value }
    }
    $schemeGuid = [guid]::Empty
    if ([guid]::TryParse($PowerScheme, [ref]$schemeGuid)) { $PowerScheme = $schemeGuid.ToString() }
    else { $PowerScheme = $null; $power = $null }
    $adapterLiteral = ConvertTo-ScriptLiteral $Adapter
    $resultLiteral = ConvertTo-ScriptLiteral (Get-WifiResultPath)
    $powerQuery = "powercfg /query $PowerScheme $($script:wifiPowerSubgroup) $($script:wifiPowerSetting)"

    foreach ($entry in $adapterValues.GetEnumerator()) {
        $lines.Add("Set-NetAdapterAdvancedProperty -Name $adapterLiteral -RegistryKeyword '$($entry.Key)' -RegistryValue $(ConvertTo-ScriptLiteral $entry.Value) -NoRestart")
    }
    if ($null -ne $power) {
        $lines.Add("powercfg /setacvalueindex $PowerScheme $($script:wifiPowerSubgroup) $($script:wifiPowerSetting) $power")
        $lines.Add("if ((powercfg /getactivescheme | Out-String) -match '$PowerScheme') { powercfg /setactive $PowerScheme }")
    }
    if ($adapterValues.Count -gt 0) {
        $lines.Add("Restart-NetAdapter -Name $adapterLiteral")
        $lines.Add('Start-Sleep -Seconds 3')
    }
    $lines.Add('$failed = @()')
    foreach ($entry in $adapterValues.GetEnumerator()) {
        $lines.Add("if ([string](@((Get-NetAdapterAdvancedProperty -Name $adapterLiteral -RegistryKeyword '$($entry.Key)').RegistryValue)[0]) -ne $(ConvertTo-ScriptLiteral $entry.Value)) { `$failed += '$($entry.Key)' }")
    }
    if ($null -ne $power) {
        $lines.Add("`$current = [regex]::Matches(($powerQuery | Out-String), '0x([0-9a-fA-F]{8})')")
        $lines.Add("if (`$current.Count -lt 1 -or [Convert]::ToInt32(`$current[0].Groups[1].Value, 16) -ne $power) { `$failed += 'PowerPlan' }")
    }
    $success = "'ok' | Set-Content -LiteralPath $resultLiteral -Encoding ASCII"
    if ($RemoveBackupWhenVerified) { $success += "; Remove-Item -LiteralPath $(ConvertTo-ScriptLiteral $RemoveBackupWhenVerified) -Force" }
    $lines.Add("if (`$failed.Count -eq 0) { $success } else { ('failed: ' + (`$failed -join ', ')) | Set-Content -LiteralPath $resultLiteral -Encoding ASCII }")
    return $lines
}

function Show-WifiResult {
    param([string]$Action)
    $path = Get-WifiResultPath
    if (-not (Test-Path -LiteralPath $path)) {
        Add-Log "Wi-Fi $Action henüz tamamlanmadı veya iptal edildi; yedek saklanıyor."
        return
    }
    $result = (Get-Content -LiteralPath $path -Raw).Trim()
    if ($result -eq 'ok') { Add-Log "Wi-Fi $Action tamamlandı ve doğrulandı." }
    else { Add-Log "Wi-Fi $Action kısmen başarısız ($($result -replace '^failed:\s*', '')). Yedek saklandı; Geri al ile dönebilirsin." }
}

# The script goes on the command line (-EncodedCommand), not into a file: a file in this user's
# folder could be swapped by another program while the UAC prompt is open.
function Invoke-AdminScript {
    param([string[]]$Lines)
    New-Item -ItemType Directory -Path $script:settingsDirectory -Force | Out-Null
    $content = @("`$ErrorActionPreference = 'Continue'") + $Lines
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($content -join "`r`n"))
    try {
        # The result is read back from wifi-result.txt, so the elevated window can stay hidden.
        Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -ErrorAction Stop `
            -ArgumentList @('-NoProfile', '-WindowStyle', 'Hidden', '-EncodedCommand', $encoded)
        return $true
    } catch {
        Add-Log 'Yönetici izni verilmedi; değişiklik yapılmadı.'
        return $false
    }
}

# ---------------------------------------------------------------- devices (slow: PnP)

function Get-BluetoothVersionName {
    param($Lmp)
    $map = @{ 6 = '4.0'; 7 = '4.1'; 8 = '4.2'; 9 = '5.0'; 10 = '5.1'; 11 = '5.2'; 12 = '5.3'; 13 = '5.4'; 14 = '6.0' }
    if ($null -ne $Lmp -and $map.ContainsKey([int]$Lmp)) { return "Bluetooth $($map[[int]$Lmp])" }
    return 'Bilinmiyor'
}

function Get-DeviceBus {
    param([string]$InstanceId)
    if ($InstanceId -match 'BTHENUM|BTHLE|00001124-0000-1000-8000-00805F9B34FB|00001812-0000-1000-8000-00805F9B34FB') { return 'Bluetooth' }
    if ($InstanceId -match '^ACPI\\') { return 'Dahili' }
    if ($InstanceId -match '^(USB|HID\\VID_)') { return 'USB' }
    return 'Dahili / sanal'
}

function Get-DeviceInfo {
    $all = @(Get-PnpDevice -ErrorAction SilentlyContinue)
    $present = @($all | Where-Object Present)
    $info = [pscustomobject]@{ Radio = $null; Version = 'Bilinmiyor'; Paired = @(); Inputs = @(); Controllers = @(); Pads = @() }

    $info.Radio = $present | Where-Object { $_.Class -eq 'Bluetooth' -and $_.InstanceId -match '^(USB|PCI)\\' } | Select-Object -First 1
    if ($info.Radio) {
        $lmp = (Get-PnpDeviceProperty -InstanceId $info.Radio.InstanceId -KeyName '{A92F26CA-EDA7-4B1D-9DB2-27B68AA5A2EB} 4' -ErrorAction SilentlyContinue).Data
        $info.Version = Get-BluetoothVersionName $lmp
    }

    $paired = foreach ($device in @($all | Where-Object { $_.InstanceId -match '^BTH(ENUM|LE)\\DEV_([0-9A-F]{12})' })) {
        $address = ([regex]::Match($device.InstanceId, 'DEV_([0-9A-F]{12})')).Groups[1].Value
        $classes = @($present | Where-Object { $_.InstanceId -match $address } | ForEach-Object Class)
        $kind = if ($classes -match 'AudioEndpoint|MEDIA') { 'Ses' }
            elseif ($classes -match 'XboxComposite|XnaComposite') { 'Kumanda' }
            elseif ($classes -match 'HIDClass|Keyboard|Mouse') { 'Giriş aygıtı' }
            else { 'Diğer' }
        $battery = (Get-PnpDeviceProperty -InstanceId $device.InstanceId -KeyName '{104EA319-6EE2-4701-BD47-8DDBF425BBE5} 2' -ErrorAction SilentlyContinue).Data
        [pscustomobject]@{
            Name = $device.FriendlyName; Kind = $kind; Present = $device.Present
            Battery = if ($null -ne $battery) { "%$battery" } else { '—' }
        }
    }
    $info.Paired = @($paired | Where-Object Name | Sort-Object Name -Unique)

    $inputs = foreach ($device in $present) {
        $kind = $null
        if ($device.Class -eq 'Keyboard') { $kind = 'Klavye' }
        elseif ($device.Class -eq 'Mouse') { $kind = if ($device.FriendlyName -match 'touchpad|Precision') { 'Touchpad' } else { 'Fare' } }
        elseif ($device.Class -match 'XnaComposite|XboxComposite' -or $device.FriendlyName -match 'game controller|oyun denetleyicisi|Wireless Controller|DualSense|Xbox') { $kind = 'Kumanda' }
        if (-not $kind) { continue }
        [pscustomobject]@{
            Name = $device.FriendlyName; Kind = $kind; Bus = Get-DeviceBus $device.InstanceId
            XInput = ($device.Class -match 'XnaComposite|XboxComposite' -or $device.FriendlyName -match 'Xbox')
        }
    }
    $info.Inputs = @($inputs | Group-Object Name, Kind, Bus | ForEach-Object {
        $first = $_.Group[0]
        [pscustomobject]@{
            Name = $(if ($_.Count -gt 1) { "$($first.Name)  ×$($_.Count)" } else { $first.Name })
            Kind = $first.Kind; Bus = $first.Bus; XInput = $first.XInput
        }
    } | Sort-Object Kind, Name)
    $info.Controllers = @($info.Inputs | Where-Object Kind -eq 'Kumanda')
    $info.Pads = @([GameBoostXInput]::GetPads())
    return $info
}

function Get-PadBatteryText {
    param($Pad)
    if (-not $Pad.Wireless) { return 'Hazır' }
    switch ($Pad.BatteryLevel) { 0 { 'Pil boş' } 1 { 'Pil düşük' } 2 { 'Pil orta' } 3 { 'Pil dolu' } default { 'Pil bilinmiyor' } }
}

function Get-DeviceAlerts {
    param($Info)
    $alerts = [Collections.Generic.List[object]]::new()
    if (-not $Info) { return $alerts }
    foreach ($pad in $Info.Pads) {
        if ($pad.Wireless -and $pad.BatteryLevel -le 1) {
            $alerts.Add((New-Alert 'warning' "Kumanda $($pad.Slot): $(Get-PadBatteryText $pad)" 'Oyun ortasında kopmaması için şarj et veya pil değiştir.'))
        } elseif (-not $pad.Wireless) {
            $alerts.Add((New-Alert 'ok' "Kumanda $($pad.Slot) kablolu bağlı" 'Kablolu bağlantı en düşük gecikmeyi verir.'))
        } else {
            $alerts.Add((New-Alert 'ok' "Kumanda $($pad.Slot) kablosuz bağlı" (Get-PadBatteryText $pad)))
        }
    }
    if ($Info.Controllers | Where-Object Name -match 'Xbox 360') {
        $alerts.Add((New-Alert 'info' 'Xbox 360 kumandası uyku sırasında güç çekebilir' 'Windows bu kumanda için Modern Standby uyarısı kaydetmiş; uzun beklemede çıkarmak pili korur.'))
    }
    if ($script:insightCache.PadResult) { $alerts.Add($script:insightCache.PadResult) }
    if ($Info.Radio) {
        $alerts.Add((New-Alert 'ok' "$($Info.Version) hazır" $Info.Radio.FriendlyName))
        $btAudio = @($Info.Paired | Where-Object Kind -eq 'Ses')
        $network = $script:insightCache.Network
        if ($btAudio.Count -gt 0 -and $network -and ($network.Band -like '*2,4*')) {
            $alerts.Add((New-Alert 'warning' 'Bluetooth ses ve 2,4 GHz Wi-Fi çakışıyor' 'İkisi aynı frekansı paylaşır; ses kesilir ve ping dalgalanır. 5 GHz ağa geç.'))
        }
    } else {
        $alerts.Add((New-Alert 'info' 'Bluetooth adaptörü bulunamadı' 'Uçak modu veya kapalı adaptör olabilir.'))
    }
    return $alerts
}

# ---------------------------------------------------------------- home summary

# "Ready to play?" at a glance, next to the Akıllı durum title.
function Update-ReadinessLabel {
    param($Alerts)
    if (-not $script:readinessLabel) { return }
    $critical = @($Alerts | Where-Object Severity -eq 'critical').Count
    $warnings = @($Alerts | Where-Object Severity -eq 'warning').Count
    if ($critical + $warnings -eq 0) {
        $script:readinessLabel.Text = '·  Oyuna hazır ✓'
        $script:readinessLabel.ForeColor = $script:theme.Accent
    } else {
        $parts = @()
        if ($critical -gt 0) { $parts += "$critical önemli" }
        if ($warnings -gt 0) { $parts += "$warnings uyarı" }
        $script:readinessLabel.Text = "·  $($parts -join ', ')"
        $script:readinessLabel.ForeColor = if ($critical -gt 0) { $script:theme.Red } else { $script:theme.Amber }
    }
}

# Home shows the most important ones; Akıllı Bakım shows everything.
function Update-HomeAlerts {
    $alerts = [Collections.Generic.List[object]]::new()
    foreach ($alert in (Get-SystemAlerts)) { $alerts.Add($alert) }
    try { foreach ($alert in (Get-DisplayAlerts @([GameBoostDisplay]::GetMonitors()))) { $alerts.Add($alert) } } catch { }
    try { foreach ($alert in (Get-AudioAlerts @([GameBoostAudio]::GetDevices()))) { $alerts.Add($alert) } } catch { }
    foreach ($alert in @($script:insightCache.NetworkAlerts) + @($script:insightCache.DeviceAlerts) + @($script:sessionAlerts) + @($script:trendAlerts) + @($script:auditAlerts)) {
        if ($alert) { $alerts.Add($alert) }
    }
    Update-ReadinessLabel $alerts
    if ($script:homeAlerts) { Set-UiAlerts $script:homeAlerts $alerts 6 }
    if ($script:maintenanceAlerts) { Set-UiAlerts $script:maintenanceAlerts $alerts }
}

# ---------------------------------------------------------------- full spec report

function Add-ReportSection {
    param($Lines, [string]$Title)
    if ($Lines.Count -gt 0) { $Lines.Add('') }
    $Lines.Add($Title)
    $Lines.Add(('─' * 72))
}

function Add-ReportField {
    param($Lines, [string]$Key, $Value)
    if ($null -eq $Value -or "$Value" -eq '') { return }
    $Lines.Add(('  {0,-22} {1}' -f $Key, $Value))
}

function Get-NvidiaDetails {
    $smi = (Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue).Source
    if (-not $smi) { return $null }
    $csv = & $smi --query-gpu=name,driver_version,memory.total,pcie.link.gen.max,pcie.link.width.current,power.max_limit,clocks.max.graphics,clocks.max.memory,vbios_version --format=csv,noheader,nounits 2>$null | Select-Object -First 1
    if (-not $csv) { return $null }
    $parts = @($csv -split ',' | ForEach-Object { $_.Trim() })
    $bar1 = $null
    $memory = (& $smi -q -d MEMORY 2>$null | Out-String)
    $match = [regex]::Match($memory, 'BAR1 Memory Usage\s+Total\s*:\s*(\d+)\s*MiB')
    if ($match.Success) { $bar1 = [int]$match.Groups[1].Value }
    return [pscustomobject]@{
        Name = $parts[0]; Driver = $parts[1]; VramMb = [int]($parts[2] -replace '\D', ''); PcieGen = $parts[3]; PcieWidth = $parts[4]
        PowerMax = $parts[5]; ClockGraphics = $parts[6]; ClockMemory = $parts[7]; Vbios = $parts[8]; Bar1Mb = $bar1
    }
}

function Get-BatteryDetails {
    $path = Join-Path $env:TEMP 'gameboost-battery.xml'
    try {
        & powercfg.exe /batteryreport /xml /output $path /duration 1 2>$null | Out-Null
        [xml]$xml = Get-Content -LiteralPath $path -Raw
        $battery = @($xml.BatteryReport.Batteries.Battery)[0]
        if (-not $battery) { return $null }
        $design = [double]$battery.DesignCapacity
        $full = [double]$battery.FullChargeCapacity
        return [pscustomobject]@{
            Name = "$($battery.Manufacturer) $($battery.Id)".Trim(); Chemistry = $battery.Chemistry
            DesignMwh = $design; FullMwh = $full; Cycles = $battery.CycleCount
            Health = if ($design -gt 0) { [math]::Round(100 * $full / $design, 1) } else { $null }
        }
    } catch { return $null }
    finally { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
}

function Get-SystemReportText {
    $lines = [Collections.Generic.List[string]]::new()
    $features = [Collections.Generic.List[string]]::new()
    $computer = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
    $bios = Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $cpu = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
    $videos = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue)
    $modules = @(Get-CimInstance Win32_PhysicalMemory -ErrorAction SilentlyContinue)
    $slots = (Get-CimInstance Win32_PhysicalMemoryArray -ErrorAction SilentlyContinue | Measure-Object MemoryDevices -Sum).Sum
    $disks = @(Get-PhysicalDisk -ErrorAction SilentlyContinue)
    $nvidia = Get-NvidiaDetails
    $battery = Get-BatteryDetails
    $monitors = @([GameBoostDisplay]::GetMonitors())
    $audio = @([GameBoostAudio]::GetDevices())
    $network = $script:insightCache.Network
    if (-not $network) { $network = Get-NetworkInfo; $script:insightCache.Network = $network }
    $devices = $script:insightCache.Devices
    if (-not $devices) { $devices = Get-DeviceInfo; $script:insightCache.Devices = $devices }

    $lines.Add("GAMEBOOST LITE · SİSTEM BİLGİSİ · $((Get-Date).ToString('dd.MM.yyyy HH:mm'))")

    try {
        if (-not $script:pcScoreData) { $script:pcScoreData = Get-PcScoreData }
        $score = Measure-PcScore $script:pcScoreData
        Add-ReportSection $lines 'PC PUANI (ayrıntı: PC Puanı sayfası)'
        Add-ReportField $lines 'PC gücü' "$($score.Overall)/100 · $($score.Tier)"
        foreach ($component in $score.Components | Where-Object { $null -ne $_.Score }) {
            Add-ReportField $lines "  $($component.Label)" "$($component.Score) · $($component.Model)"
        }
        Add-ReportField $lines 'Kurulum puanı' "$($score.Setup.Score)/100"
    } catch { }

    Add-ReportSection $lines 'CİHAZ'
    Add-ReportField $lines 'Üretici / model' "$($computer.Manufacturer) $($computer.Model)"
    Add-ReportField $lines 'SKU' $computer.SystemSKUNumber
    Add-ReportField $lines 'BIOS' $(if ($bios) { "$($bios.SMBIOSBIOSVersion) ($($bios.ReleaseDate.ToString('dd.MM.yyyy')))" })
    $build = Get-RegistryValue 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' 'CurrentBuild'
    $ubr = Get-RegistryValue 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' 'UBR'
    $displayVersion = Get-RegistryValue 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' 'DisplayVersion'
    Add-ReportField $lines 'Windows' "$($os.Caption -replace '^Microsoft ', '') $displayVersion (derleme $build.$ubr)"
    Add-ReportField $lines 'Açık kalma süresi' ('{0:0.0} gün' -f [GameBoostEngine]::UptimeDays())

    Add-ReportSection $lines 'İŞLEMCİ'
    $cores = [GameBoostSystemInfo]::CoreSummary()
    Add-ReportField $lines 'Model' ($cpu.Name -replace '\s+', ' ').Trim()
    if ($cores[2] -gt 0) {
        Add-ReportField $lines 'Çekirdek yapısı' "$($cores[0]) performans ($($cores[1]) izlek) + $($cores[2]) verimlilik ($($cores[3]) izlek)"
    } else { Add-ReportField $lines 'Çekirdek / izlek' "$($cpu.NumberOfCores) / $($cpu.NumberOfLogicalProcessors)" }
    Add-ReportField $lines 'Toplam' "$($cpu.NumberOfCores) çekirdek, $($cpu.NumberOfLogicalProcessors) izlek"
    Add-ReportField $lines 'Temel hız' "$([math]::Round($cpu.MaxClockSpeed / 1000, 2)) GHz"
    Add-ReportField $lines 'Önbellek' "L2 $([math]::Round($cpu.L2CacheSize / 1024, 1)) MB · L3 $([math]::Round($cpu.L3CacheSize / 1024, 1)) MB"
    Add-ReportField $lines 'Sanallaştırma' $(if ($computer.HypervisorPresent) { 'Açık (Hyper-V / WSL2 çalışabilir)' } elseif ($cpu.VirtualizationFirmwareEnabled) { 'BIOS''ta açık' } else { 'Kapalı' })

    Add-ReportSection $lines 'EKRAN KARTLARI'
    foreach ($video in $videos) {
        $lines.Add("  $($video.Name)")
        Add-ReportField $lines '  Sürücü' "$($video.DriverVersion) ($(if ($video.DriverDate) { $video.DriverDate.ToString('dd.MM.yyyy') }))"
        if ($nvidia -and $video.Name -like '*NVIDIA*') {
            Add-ReportField $lines '  NVIDIA sürücüsü' $nvidia.Driver
            Add-ReportField $lines '  Video belleği' "$($nvidia.VramMb) MB"
            Add-ReportField $lines '  PCIe bağlantısı' "Gen $($nvidia.PcieGen) ×$($nvidia.PcieWidth)"
            Add-ReportField $lines '  En yüksek güç' "$($nvidia.PowerMax) W"
            Add-ReportField $lines '  En yüksek saat' "Grafik $($nvidia.ClockGraphics) MHz · Bellek $($nvidia.ClockMemory) MHz"
            Add-ReportField $lines '  VBIOS' $nvidia.Vbios
        }
    }

    Add-ReportSection $lines 'BELLEK (RAM)'
    $totalRam = ($modules | Measure-Object Capacity -Sum).Sum
    $type = switch (@($modules)[0].SMBIOSMemoryType) { 26 { 'DDR4' } 34 { 'DDR5' } 30 { 'LPDDR4' } 35 { 'LPDDR5' } default { 'DDR' } }
    Add-ReportField $lines 'Toplam' "$([math]::Round($totalRam / 1GB)) GB $type"
    Add-ReportField $lines 'Yuvalar' "$($modules.Count) dolu / $(if ($slots) { $slots } else { '?' }) yuva"
    foreach ($module in $modules) {
        Add-ReportField $lines "  $($module.DeviceLocator -replace '^.*?Slot\s*', 'Yuva ')" "$([math]::Round($module.Capacity / 1GB)) GB · $($module.ConfiguredClockSpeed) MT/s · $($module.Manufacturer) $("$($module.PartNumber)".Trim())"
    }
    $dualChannel = $modules.Count -ge 2 -and @($modules | ForEach-Object Capacity | Sort-Object -Unique).Count -eq 1
    Add-ReportField $lines 'Kanal' $(if ($dualChannel) { 'Çift kanal (eş modüller)' } elseif ($modules.Count -eq 1) { 'Tek kanal' } else { 'Karışık modüller' })

    Add-ReportSection $lines 'DEPOLAMA'
    foreach ($disk in $disks) {
        Add-ReportField $lines $disk.FriendlyName "$(Format-ByteSize $disk.Size) · $($disk.BusType) $($disk.MediaType) · Sağlık: $(if ($disk.HealthStatus -eq 'Healthy') { 'İyi' } else { $disk.HealthStatus })"
    }
    foreach ($drive in [IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady }) {
        Add-ReportField $lines "  Sürücü $($drive.Name.TrimEnd('\'))" "$(Format-ByteSize $drive.AvailableFreeSpace) boş / $(Format-ByteSize $drive.TotalSize) · $($drive.DriveFormat) · $($drive.VolumeLabel)"
    }

    Add-ReportSection $lines 'EKRANLAR'
    foreach ($monitor in $monitors) {
        $lines.Add("  $($monitor.Name)$(if ($monitor.Cloned) { '  (çoğaltılmış)' } elseif ($monitor.Primary) { '  (ana ekran)' })")
        Add-ReportField $lines '  Bağlantı' "$($monitor.Connection) · $($monitor.Adapter)"
        Add-ReportField $lines '  Şu an' "$($monitor.Width)×$($monitor.Height) @ $([math]::Round($monitor.Refresh)) Hz · $($monitor.BitsPerColor) bit renk"
        Add-ReportField $lines '  En yüksek' "$($monitor.MaxRefreshAtResolution) Hz (bu çözünürlükte) · en büyük $($monitor.MaxWidth)×$($monitor.MaxHeight)"
        Add-ReportField $lines '  Hz seçenekleri' (($monitor.RatesAtResolution | ForEach-Object { "$_" }) -join ', ')
        Add-ReportField $lines '  HDR' $(if ($monitor.HdrSupported) { if ($monitor.HdrEnabled) { 'Destekliyor · açık' } else { 'Destekliyor · kapalı' } } else { 'Desteklemiyor' })
    }

    Add-ReportSection $lines 'SES'
    foreach ($device in $audio | Where-Object Active) {
        $role = @()
        if ($device.IsDefault) { $role += 'varsayılan' }
        if ($device.IsDefaultCommunications) { $role += 'iletişim' }
        $direction = if ($device.IsCapture) { 'Giriş' } else { 'Çıkış' }
        Add-ReportField $lines "  $direction" "$($device.Name) · $(Get-AudioFormFactorName $device.FormFactor) · $(Get-AudioFormatText $device)$(if ($role) { ' · ' + ($role -join ', ') })"
    }

    Add-ReportSection $lines 'AĞ'
    foreach ($adapter in @($network.Wifi, $network.Ethernet) | Where-Object { $_ }) {
        Add-ReportField $lines $adapter.Name "$($adapter.InterfaceDescription) · $(if ($adapter.Status -eq 'Up') { $adapter.LinkSpeed } else { 'bağlı değil' }) · sürücü $($adapter.DriverVersion)"
    }
    if ($network.Wifi) {
        Add-ReportField $lines '  Wi-Fi donanımı' $network.Generation
        Add-ReportField $lines '  Etkin mod' $network.ActiveMode
        Add-ReportField $lines '  Bant' $network.Band
        if ($network.Ssid) { Add-ReportField $lines '  Ağ / sinyal' "$($network.Ssid) · %$($network.Signal) · kanal $($network.Channel)" }
    }

    Add-ReportSection $lines 'BLUETOOTH VE GİRİŞ AYGITLARI'
    if ($devices.Radio) { Add-ReportField $lines 'Bluetooth' "$($devices.Version) · $($devices.Radio.FriendlyName)" }
    foreach ($device in $devices.Paired) { Add-ReportField $lines '  Eşleşmiş' "$($device.Name) · $($device.Kind) · pil $($device.Battery)" }
    foreach ($pad in $devices.Pads) { Add-ReportField $lines "  Kumanda $($pad.Slot)" "XInput · $(if ($pad.Wireless) { 'kablosuz · ' + (Get-PadBatteryText $pad) } else { 'kablolu' })" }
    foreach ($device in $devices.Inputs) { Add-ReportField $lines "  $($device.Kind)" "$($device.Name) · $($device.Bus)" }
    $usb = @(Get-CimInstance Win32_USBController -ErrorAction SilentlyContinue | Where-Object Name -notmatch 'Virtual' | ForEach-Object Name)
    foreach ($controller in $usb) { Add-ReportField $lines '  USB denetleyici' ($controller -replace '\s*-\s*[\d.]+\s*\(Microsoft\)', '') }

    if ($battery) {
        Add-ReportSection $lines 'PİL'
        Add-ReportField $lines 'Pil' "$($battery.Name) · $($battery.Chemistry)"
        Add-ReportField $lines 'Kapasite' ('{0:N0} / {1:N0} mWh (tasarım)' -f $battery.FullMwh, $battery.DesignMwh)
        Add-ReportField $lines 'Sağlık' "%$($battery.Health) · $($battery.Cycles) şarj döngüsü"
    }

    # Upgrades worth buying for this machine, most useful first; each says why.
    $history = @(Get-SessionHistory | Select-Object -Last 10)
    $upgrades = [Collections.Generic.List[string]]::new()
    $ramGb = [math]::Round($totalRam / 1GB)
    if ($ramGb -le 16) {
        $evidence = if (@($history | Where-Object { $null -ne $_.MinFreeRamGb -and $_.MinFreeRamGb -lt 1.5 }).Count -ge 2) { ' Son oyunlarda boş RAM 1,5 GB''ın altına indi.' } else { '' }
        $slotText = if ($slots -and $modules.Count -ge $slots) { "iki yuva dolu ($($modules.Count)×$([math]::Round(@($modules)[0].Capacity / 1GB)) GB), ikisi birlikte değişir" } else { 'boş yuvaya eş modül eklenebilir' }
        $speed = @($modules)[0].ConfiguredClockSpeed
        $upgrades.Add("  ★★★  RAM: 2×16 GB $type-$speed SODIMM ($slotText). Oyun + tarayıcı + Discord için en etkili yükseltme.$evidence")
        $upgrades.Add('        (HP bu seri için en fazla 32 GB belirtiyor; almadan önce model sayfasından doğrula.)')
    }
    $defaultMic = $audio | Where-Object { $_.IsCapture -and $_.IsDefault -and $_.Active } | Select-Object -First 1
    if ($defaultMic -and $defaultMic.FormFactor -ne 5 -and $defaultMic.Name -match 'Dizi|Array|Smart Sound|Internal|Dahili') {
        $upgrades.Add('  ★★   Mikrofonlu kulaklık veya USB mikrofon: şu an laptopun dahili mikrofonu kullanılıyor; ağzına uzak ve fan sesini alıyor.')
    }
    if ($network.Ethernet -and $network.Ethernet.Status -ne 'Up' -and $network.Wifi -and $network.Wifi.Status -eq 'Up') {
        $evidence = if (@($history | Where-Object { $_.PingSpikes -ge 3 }).Count -ge 2) { ' Son oyunlarda Wi-Fi gecikmesi dalgalandı.' } else { '' }
        $upgrades.Add("  ★★   Ethernet kablosu (Cat6): kablolu port var ama kullanılmıyor; çevrim içi oyunda en düşük ve en kararlı ping.$evidence")
    }
    if (@($history | Where-Object ChargerWeak).Count -ge 1) {
        $upgrades.Add('  ★★   Laptopun kendi yüksek watt''lı adaptörü: oyun sırasında prizdeyken pil düştü; kullanılan şarj aleti yetmiyor.')
    }
    $hot = @($history | Where-Object { $_.LimitSeconds -ge 30 -or $_.GpuMaxTemp -ge 85 }).Count
    $coolingWhy = if ($hot -gt 0) { "son $($history.Count) oyunun $hot tanesinde ekran kartı ısındı" } else { 'yük altında sıcaklığı birkaç derece düşürür, fan sesini azaltır' }
    $upgrades.Add("  $(if ($hot -gt 0) { '★★  ' } else { '★   ' }) Laptop yükseltici / soğutucu stand: $coolingWhy.")
    $fixed = @([IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady })
    $lowDisk = @($fixed | Where-Object { $_.AvailableFreeSpace -lt 50GB })
    if ($lowDisk.Count -gt 0) {
        $upgrades.Add("  ★★   Daha büyük NVMe SSD: $(($lowDisk | ForEach-Object { $_.Name.TrimEnd('\') }) -join ', ') sürücüsünde 50 GB'tan az yer kaldı.")
    } else {
        $free = ($fixed | ForEach-Object { "$($_.Name.TrimEnd('\')) $(Format-ByteSize $_.AvailableFreeSpace)" }) -join ', '
        $upgrades.Add("  —    Depolama: gerek yok ($free boş).")
        $empty = $fixed | Where-Object { $_.Name -ne "$env:SystemDrive\" -and $_.TotalSize -gt 0 -and $_.AvailableFreeSpace / $_.TotalSize -gt 0.8 } | Select-Object -First 1
        if ($empty) { $upgrades.Add("       İpucu: $($empty.Name.TrimEnd('\')) neredeyse boş; Steam > Ayarlar > Depolama'dan ikinci oyun kütüphanesi yap.") }
    }
    $upgrades.Add('  —    Değiştirilemeyenler: işlemci ve ekran kartı anakarta lehimli.')
    if (-not $script:insightCache.UsbC) {
        $script:insightCache.UsbC = Get-UsbCDisplayInfo
        $script:insightCache.UsbCAt = [datetime]::UtcNow
    }
    $egpu = if ($script:insightCache.UsbC.Usb4) { 'USB4/Thunderbolt var; harici ekran kartı (eGPU) mümkün ama pahalı.' } else { 'Harici ekran kartı (eGPU) için USB4/Thunderbolt gerekir; bu bilgisayarda yok.' }
    $upgrades.Add("       $egpu")
    Add-ReportSection $lines 'YÜKSELTME ÖNERİLERİ (bu bilgisayara göre)'
    foreach ($upgrade in $upgrades) { $lines.Add($upgrade) }

    # What this hardware can do in games.
    $gpuName = if ($nvidia) { $nvidia.Name } else { ($videos | Where-Object Name -like '*NVIDIA*' | Select-Object -First 1).Name }
    $series = 0
    if ($gpuName -match 'RTX\s*(\d)0') { $series = [int]$Matches[1] }
    if ($series -ge 2) {
        $features.Add('  ✓  DLSS Süper Çözünürlük / DLAA: düşük çözünürlükte çizip netleştirir, FPS artar')
        $features.Add('  ✓  NVIDIA Reflex: destekleyen oyunlarda giriş gecikmesini düşürür')
        $features.Add('  ✓  Işın izleme: RT çekirdekleri var; ' + $(if ($nvidia -and $nvidia.VramMb -le 4096) { '4 GB VRAM ile düşük ayar + DLSS önerilir' } else { 'DLSS ile birlikte kullan' }))
        $features.Add('  ✓  NVENC donanım kaydı: H.264 / HEVC, oyunu yavaşlatmadan kayıt ve yayın')
        if ($series -ge 4) { $features.Add('  ✓  DLSS Kare Üretimi ve AV1 kodlama') }
        else { $features.Add('  ✗  DLSS Kare Üretimi ve AV1 kodlama: RTX 40 serisi gerektirir') }
        if ($series -ge 3) { $features.Add('  ✓  AV1 video çözme: YouTube/Netflix AV1 videoları donanımda oynatılır') }
    }
    if ($nvidia -and $nvidia.Bar1Mb) {
        if ($nvidia.Bar1Mb -ge $nvidia.VramMb) { $features.Add('  ✓  Resizable BAR açık: işlemci tüm video belleğine doğrudan erişir') }
        else { $features.Add('  !  Resizable BAR kapalı: BIOS''ta açılabiliyorsa bazı oyunlarda %5-10 kazanç') }
    }
    if ($videos | Where-Object Name -like '*Intel*') { $features.Add('  ✓  Intel Quick Sync: ikinci donanım kodlayıcı (yayın/kayıt için)') }
    foreach ($monitor in $monitors) {
        if ($monitor.MaxRefreshAtResolution -ge 120) { $features.Add("  ✓  $($monitor.Name): $($monitor.MaxRefreshAtResolution) Hz yüksek yenileme hızı") }
        if ($monitor.HdrSupported) { $features.Add("  ✓  $($monitor.Name): HDR destekli$(if (-not $monitor.HdrEnabled) { ' (Windows''ta kapalı)' })") }
        if (-not $monitor.Internal -and $monitor.Adapter -like '*NVIDIA*') { $features.Add("  ✓  $($monitor.Name) doğrudan NVIDIA çıkışında: en düşük gecikme") }
    }
    if ($network.Generation) {
        $limited = $network.Rows | Where-Object { $_.Keyword -eq 'IEEE11nMode' -and -not $_.Ok }
        if ($limited) { $features.Add("  !  $($network.Generation) donanımı var ama $($network.ActiveMode) modunda sınırlı") }
        else { $features.Add("  ✓  $($network.Generation) kablosuz ağ") }
    }
    if ($network.Ethernet) { $features.Add("  ✓  Kablolu Ethernet: $($network.Ethernet.InterfaceDescription)") }
    if ($devices.Version -match '5\.([2-9])|6\.') { $features.Add("  ✓  $($devices.Version): LE Audio destekleyen kulaklıklarla düşük gecikmeli ses") }
    elseif ($devices.Radio) { $features.Add("  ✓  $($devices.Version)") }
    if ($dualChannel) { $features.Add('  ✓  Çift kanal RAM: bellek bant genişliği tam') }
    if ($slots -and $modules.Count -ge $slots) { $features.Add("  i  RAM yuvaları dolu; yükseltme için modülleri $([math]::Round($totalRam / 1GB * 2)) GB setle değiştir") }
    elseif ($slots) { $features.Add("  i  Boş RAM yuvası var: aynı modülden ekleyerek yükseltilebilir") }
    if (@($disks | Where-Object BusType -eq 'NVMe').Count -gt 0) { $features.Add("  ✓  NVMe SSD × $(@($disks | Where-Object BusType -eq 'NVMe').Count): DirectStorage destekleyen oyunlar için uygun") }
    if ($computer.HypervisorPresent) { $features.Add('  ✓  Sanallaştırma açık: WSL2, Docker, Android uygulamaları') }
    if ((Get-RegistryValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'HiberbootEnabled') -eq 1) {
        $features.Add('  i  Hızlı Başlangıç açık: tam sıfırlama için "Yeniden başlat" kullan')
    }
    Add-ReportSection $lines 'KULLANABİLECEĞİN ÖZELLİKLER'
    foreach ($feature in $features) { $lines.Add($feature) }
    $lines.Add('')
    $lines.Add('  ✓ hazır   ✗ bu donanımda yok   ! iyileştirilebilir   i bilgi')
    return ($lines -join "`r`n")
}
