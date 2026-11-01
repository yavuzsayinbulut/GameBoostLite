# PC Puanı: how strong this PC is for games (from its parts) and how ready it is right now.
# Part scores come from model names and a small table of approximate published results;
# nothing is benchmarked on this PC. The setup score counts the open smart notices.

# Approximate 3DMark Time Spy graphics score in thousands, at typical power limits. Used only to rank cards.
$script:gpuPerformanceText = @'
RTX 5090 LAPTOP=22
RTX 5080 LAPTOP=19
RTX 5070 TI LAPTOP=15
RTX 5070 LAPTOP=12.5
RTX 5060 LAPTOP=12
RTX 5050 LAPTOP=9.5
RTX 4090 LAPTOP=20
RTX 4080 LAPTOP=17.5
RTX 4070 LAPTOP=11.5
RTX 4060 LAPTOP=10.5
RTX 4050 LAPTOP=8.8
RTX 3080 TI LAPTOP=13
RTX 3080 LAPTOP=11.5
RTX 3070 TI LAPTOP=11
RTX 3070 LAPTOP=10
RTX 3060 LAPTOP=8.5
RTX 3050 6GB LAPTOP=5.6
RTX 3050 TI LAPTOP=5.2
RTX 3050 LAPTOP=4.9
RTX 2050=3.7
RTX 5090=48
RTX 5080=32
RTX 5070 TI=27
RTX 5070=22
RTX 5060 TI=15.5
RTX 5060=13
RTX 5050=9.5
RTX 4090=36
RTX 4080 SUPER=28.5
RTX 4080=28
RTX 4070 TI SUPER=24
RTX 4070 TI=22.5
RTX 4070 SUPER=21
RTX 4070=17.8
RTX 4060 TI=13.5
RTX 4060=10.6
RTX 3090 TI=21.5
RTX 3090=19.5
RTX 3080 TI=19
RTX 3080=17.5
RTX 3070 TI=14.7
RTX 3070=13.5
RTX 3060 TI=11.7
RTX 3060=8.7
RTX 3050=6.2
RTX 2080 TI=14.5
RTX 2080 SUPER=11.6
RTX 2080=11
RTX 2070 SUPER=10.2
RTX 2070=9
RTX 2060 SUPER=8.7
RTX 2060=7.5
GTX 1660 TI=6.3
GTX 1660 SUPER=6.1
GTX 1660=5.4
GTX 1650 TI=3.7
GTX 1650 SUPER=4.7
GTX 1650=3.6
GTX 1080 TI=9.5
GTX 1080=7.3
GTX 1070 TI=6.8
GTX 1070=6
GTX 1060=4
GTX 1050 TI=2.4
GTX 1050=1.8
MX570=2.8
MX550=2.4
MX450=2
MX350=1.2
MX250=1.1
MX150=1
RX 9070 XT=29
RX 9070=26
RX 9060 XT=15
RX 7900 XTX=30
RX 7900 XT=26.5
RX 7900 GRE=22
RX 7800 XT=20
RX 7700 XT=17
RX 7700S=10.5
RX 7600 XT=11.3
RX 7600M XT=10.5
RX 7600M=9
RX 7600S=9
RX 7600=11
RX 6950 XT=22
RX 6900 XT=20.5
RX 6850M XT=13
RX 6800 XT=19
RX 6800M=12
RX 6800=16.5
RX 6750 XT=13.5
RX 6700 XT=12.5
RX 6700M=10
RX 6700=11
RX 6650 XT=10.5
RX 6600 XT=10
RX 6600M=8.5
RX 6600=8.6
RX 6500 XT=5
RX 6500M=5
RX 6400=3.8
RX 5700 XT=9.3
RX 5700=8.3
RX 5600 XT=7.5
RX 5500 XT=5
RX 590=4.8
RX 580=4.4
RX 570=3.8
RADEON 8060S=10
RADEON 8050S=8
RADEON 890M=4
RADEON 880M=3.5
RADEON 780M=2.8
RADEON 760M=2.4
RADEON 680M=2.4
RADEON 660M=1.7
VEGA 8=1
ARC B580=14.5
ARC B570=12.5
ARC A770M=10
ARC A730M=8
ARC A570M=7
ARC A550M=6
ARC A370M=4
ARC A350M=3
ARC A770=13.5
ARC A750=12.5
ARC A580=11
ARC A380=4.7
ARC A310=3.3
ARC 140V=4
ARC 130V=3.4
ARC 140T=3.6
ARC 130T=3.1
ARC GRAPHICS=3.5
IRIS XE=1.5
IRIS PLUS=0.9
UHD GRAPHICS=0.7
HD GRAPHICS=0.5
'@

# Most specific names first, so "RTX 4060 TI" wins over "RTX 4060".
$script:gpuPerformance = @(foreach ($line in ($script:gpuPerformanceText -split "`r?`n")) {
    if ($line -notmatch '^(.+)=([\d.]+)$') { continue }
    $key = $Matches[1].Trim()
    [pscustomobject]@{
        Key = $key; Tokens = $key.Split(' ').Count
        Perf = [double]::Parse($Matches[2], [Globalization.CultureInfo]::InvariantCulture)
        Pattern = '(?<![A-Z0-9])' + ([regex]::Escape($key) -replace '\\ ', '\s+') + '(?![A-Z0-9])'
    }
}) | Sort-Object Tokens -Descending

# 100 = RTX 5090 desktop. Logarithmic, so every doubling of speed adds the same number of points.
$script:gpuTopPerformance = 48

function ConvertTo-ScoreKey {
    param([string]$Name)
    return ((($Name -replace '\((R|TM)\)', ' ') -replace '\s+', ' ').Trim().ToUpperInvariant())
}

function Limit-Score {
    param([double]$Value, [int]$Minimum = 3)
    return [int][math]::Max($Minimum, [math]::Min(100, [math]::Round($Value)))
}

function ConvertTo-GpuScore {
    param([double]$Perf)
    if ($Perf -le 1) { return 3 }
    return Limit-Score (100 * [math]::Log($Perf) / [math]::Log($script:gpuTopPerformance))
}

# Approximate Time Spy graphics score (thousands) of a card, from the table or guessed from its memory.
function Get-GpuPerformance {
    param([string]$Name, [double]$VramGb)
    $key = ConvertTo-ScoreKey $Name
    foreach ($entry in $script:gpuPerformance) {
        if ($key -match $entry.Pattern) { return [pscustomobject]@{ Perf = $entry.Perf; Known = $true } }
    }
    # Not in the table: a rough guess from video memory (integrated chips have almost none).
    $perf = if ($VramGb -ge 12) { 15 } elseif ($VramGb -ge 8) { 10 } elseif ($VramGb -ge 6) { 7 } elseif ($VramGb -ge 3.5) { 4.5 } else { 1.2 }
    return [pscustomobject]@{ Perf = $perf; Known = $false }
}

function Measure-GpuScore {
    param([string]$Name, [double]$VramGb)
    $performance = Get-GpuPerformance $Name $VramGb
    return [pscustomobject]@{ Score = (ConvertTo-GpuScore $performance.Perf); Known = $performance.Known }
}

# Gaming leans on single-core speed (architecture) and on up to ~8 fast cores; laptop chips get less power.
function Measure-CpuScore {
    param([string]$Name, [int[]]$CoreSummary, [int]$CoreCount)
    $key = ConvertTo-ScoreKey $Name
    $single = 60; $suffix = ''; $known = $true
    if ($key -match 'CORE ULTRA [3579] (\d)\d{2}([A-Z0-9]*)') {
        $single = if ($Matches[1] -eq '1') { 80 } else { 93 }
        $suffix = $Matches[2]
    } elseif ($key -match 'CORE I[3579]-(\d{4,5})([A-Z0-9]*)') {
        $digits = $Matches[1]; $suffix = $Matches[2]
        $gen = if ($digits.Length -eq 5 -or $digits.StartsWith('1')) { [int]$digits.Substring(0, 2) } else { [int]$digits.Substring(0, 1) }
        $single = if ($gen -ge 14) { 94 } elseif ($gen -eq 13) { 92 } elseif ($gen -eq 12) { 84 } elseif ($gen -eq 11) { 68 } elseif ($gen -eq 10) { 58 } elseif ($gen -ge 6) { 55 } else { 40 }
    } elseif ($key -match 'CORE [357] [12]\d{2}([A-Z0-9]*)') {
        $single = 90; $suffix = $Matches[1]
    } elseif ($key -match 'RYZEN AI (MAX\+? )?(?:PRO )?(?:[3579] )?(HX )?\d{3}') {
        $single = 92
        $suffix = if ($Matches[2]) { 'HX' } elseif ($Matches[1]) { 'MAX' } else { 'H' }
    } elseif ($key -match 'RYZEN [3579] (?:PRO )?(\d)\d(\d)\d([A-Z0-9]*)') {
        $series = [int]$Matches[1]; $third = [int]$Matches[2]; $suffix = $Matches[3]
        $mobile = $suffix -match '^(U|H|HS|HX|HK)$'
        $single = switch ($series) {
            1 { 40 }
            2 { if ($mobile) { 40 } else { 46 } }
            3 { if ($mobile) { 46 } else { 56 } }
            4 { 56 }
            5 { 70 }
            6 { 72 }
            7 { if ($mobile -and $third -le 2) { 56 } elseif ($mobile -and $third -eq 3) { 70 } else { 86 } }
            8 { 86 }
            default { 96 }
        }
    } elseif ($key -match 'CELERON|PENTIUM|ATOM|ATHLON|INTEL PROCESSOR N') {
        $single = 30; $known = $false
    } else { $known = $false }

    $power = if ($suffix -match '^HX') { 0.95 } elseif ($suffix -match '^(H|MAX)') { 0.85 } elseif ($suffix -match '^P') { 0.75 }
        elseif ($suffix -match '^(U|Y|V|G\d)') { 0.7 } elseif ($suffix -match '^T') { 0.85 } else { 1.0 }
    # Efficiency cores help games about half as much as performance cores.
    $effective = if ($CoreSummary.Count -ge 4 -and $CoreSummary[2] -gt 0) { $CoreSummary[0] + 0.5 * $CoreSummary[2] } else { $CoreCount }
    $multi = 100 * [math]::Min(1, $effective / 8)
    $score = (0.7 * $single + 0.3 * $multi) * $power
    if ($suffix -match 'X3D') { $score += 10 }
    return [pscustomobject]@{ Score = (Limit-Score $score 5); Known = $known; Suffix = $suffix; Mobile = $power -lt 1 }
}

function Measure-RamScore {
    param([double]$TotalGb, [int]$Modules, [string]$Type, [int]$Speed)
    $gb = [math]::Round($TotalGb)
    $score = if ($gb -le 4) { 10 } elseif ($gb -le 8) { 35 } elseif ($gb -le 12) { 50 } elseif ($gb -le 16) { 70 } elseif ($gb -le 24) { 82 } elseif ($gb -le 32) { 95 } else { 100 }
    if ($Modules -eq 1 -and $Type -notlike 'LP*') { $score -= 15 }
    if ($Type -eq 'DDR4' -and $Speed -gt 0 -and $Speed -lt 2666) { $score -= 5 }
    if ($Type -like '*DDR5' -and $Speed -ge 6000) { $score += 3 }
    if ($Type -like '*DDR4' -and $Speed -ge 3600) { $score += 2 }
    return Limit-Score $score 5
}

function Measure-StorageScore {
    param($Disks)
    $nvme = @($Disks | Where-Object { $_.BusType -in 'NVMe', '17' })
    $ssd = @($Disks | Where-Object { $_.BusType -in 'NVMe', '17' -or $_.MediaType -in 'SSD', '4' })
    $score = 60; $kind = 'tür okunamadı'
    if ($nvme.Count -gt 0) { $score = 92; $kind = 'NVMe SSD' }
    elseif ($ssd.Count -gt 0) { $score = 75; $kind = 'SATA SSD' }
    elseif (@($Disks | Where-Object { $_.MediaType -in 'HDD', '3' }).Count -gt 0) { $score = 25; $kind = 'sabit disk (HDD)' }
    $ssdBytes = [double](($ssd | Measure-Object Size -Sum).Sum)
    if ($ssd.Count -gt 0) { if ($ssdBytes -lt 400GB) { $score -= 15 } elseif ($ssdBytes -lt 900GB) { $score -= 5 } }
    $count = if ($nvme.Count -gt 0) { $nvme.Count } else { $ssd.Count }
    return [pscustomobject]@{ Score = $score; Kind = $kind; Count = $count; SsdBytes = $ssdBytes }
}

# The best of the connected screens: refresh rate matters most for games, then resolution and HDR.
function Measure-DisplayScore {
    param($Monitors)
    $best = $null
    foreach ($monitor in $Monitors) {
        $hz = [int]$monitor.MaxRefreshAtResolution
        if ($hz -le 0) { $hz = [int][math]::Round($monitor.Refresh) }
        $score = if ($hz -ge 360) { 100 } elseif ($hz -ge 240) { 95 } elseif ($hz -ge 165) { 85 } elseif ($hz -ge 144) { 80 }
            elseif ($hz -ge 120) { 72 } elseif ($hz -ge 100) { 60 } elseif ($hz -ge 75) { 45 } else { 35 }
        $width = [math]::Max([int]$monitor.MaxWidth, [int]$monitor.Width)
        $height = [math]::Max([int]$monitor.MaxHeight, [int]$monitor.Height)
        if ($height -ge 2160) { $score += 8 } elseif ($height -ge 1440) { $score += 5 } elseif ($height -gt 0 -and $height -lt 1000) { $score -= 10 }
        if ($monitor.HdrSupported) { $score += 2 }
        $score = Limit-Score $score
        if (-not $best -or $score -gt $best.Score) {
            $best = [pscustomobject]@{ Score = $score; Name = $monitor.Name; Hz = $hz; Width = $width; Height = $height; Hdr = [bool]$monitor.HdrSupported }
        }
    }
    return $best
}

function Measure-NetworkScore {
    param($Network)
    if (-not $Network -or -not ($Network.Wifi -or $Network.Ethernet)) { return $null }
    $score = if ($Network.Generation -eq 'Wi-Fi 7') { 100 } elseif ($Network.Generation -eq 'Wi-Fi 6E') { 95 } elseif ($Network.Generation -eq 'Wi-Fi 6') { 88 }
        elseif ($Network.Generation -eq 'Wi-Fi 5') { 70 } elseif ($Network.Wifi) { 50 } else { 0 }
    # A wired port gives the steadiest ping whatever the Wi-Fi card is.
    if ($Network.Ethernet) { $score = [math]::Min(100, [math]::Max($score, 90) + 5) }
    return $score
}

function Get-OverallScore {
    param([int]$Gpu, [int]$Cpu, [int]$Ram, [int]$Storage)
    $weighted = 0.5 * $Gpu + 0.25 * $Cpu + 0.15 * $Ram + 0.10 * $Storage
    # The weakest of the three main parts holds the whole PC back.
    $ceiling = [math]::Min($Gpu, [math]::Min($Cpu, $Ram)) + 20
    return Limit-Score ([math]::Min($weighted, $ceiling))
}

function Get-ScoreWord {
    param([int]$Score)
    if ($Score -ge 85) { return 'Çok iyi' }
    if ($Score -ge 70) { return 'İyi' }
    if ($Score -ge 55) { return 'Yeterli' }
    if ($Score -ge 40) { return 'Orta' }
    if ($Score -ge 25) { return 'Zayıf' }
    return 'Çok zayıf'
}

# Setup is a checklist: anything short of (nearly) everything done is not green.
function Get-SetupColor {
    param([int]$Score)
    if ($Score -ge 90) { return $script:theme.Accent }
    if ($Score -ge 70) { return $script:theme.Blue }
    if ($Score -ge 50) { return $script:theme.Amber }
    return $script:theme.Red
}

function Get-ScoreColor {
    param($Score)
    if ($null -eq $Score) { return $script:theme.Muted }
    if ($Score -ge 70) { return $script:theme.Accent }
    if ($Score -ge 40) { return $script:theme.Blue }
    if ($Score -ge 25) { return $script:theme.Amber }
    return $script:theme.Red
}

# ---------------------------------------------------------------- data

# CPU, RAM and disks do not change while the app runs; read them once. Win32_Processor and the Storage
# module take seconds here, so the CPU name comes from the registry and disks straight from CIM.
function Get-PcScoreData {
    $cpuName = Get-RegistryValue 'HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0' 'ProcessorNameString'
    $cores = [int[]]@([GameBoostSystemInfo]::CoreSummary())
    $coreCount = $cores[0] + $cores[2]
    if ($coreCount -le 0) { $coreCount = [Environment]::ProcessorCount }
    $network = $script:insightCache.Network
    if (-not $network) {
        $network = Get-NetworkInfo
        $script:insightCache.Network = $network
        $script:insightCache.NetworkAlerts = @(Get-NetworkAlerts $network)
    }
    $power = [Windows.Forms.SystemInformation]::PowerStatus
    return [pscustomobject]@{
        CpuName = ("$cpuName" -replace '\s+', ' ').Trim(); CpuCores = $coreCount; CoreSummary = $cores
        Adapters = @([GameBoostGpuInfo]::Adapters() | ForEach-Object { [pscustomobject]@{ Name = $_.Name; VramGb = $_.DedicatedBytes / 1GB } })
        Modules = @(Get-CimInstance Win32_PhysicalMemory -ErrorAction SilentlyContinue | ForEach-Object {
            [pscustomobject]@{ Capacity = [double]$_.Capacity; Speed = [int]$_.ConfiguredClockSpeed; Type = [int]$_.SMBIOSMemoryType } })
        Disks = @(Get-CimInstance -Namespace root/Microsoft/Windows/Storage -ClassName MSFT_PhysicalDisk -Property BusType, MediaType, Size -ErrorAction SilentlyContinue | ForEach-Object {
            [pscustomobject]@{ BusType = "$($_.BusType)"; MediaType = "$($_.MediaType)"; Size = [double]$_.Size } })
        Monitors = @([GameBoostDisplay]::GetMonitors())
        Network = $network
        Laptop = $power.BatteryChargeStatus -ne [Windows.Forms.BatteryChargeStatus]::NoSystemBattery
    }
}

# Notices that hold this PC back right now and can be fixed without new hardware.
function Get-SetupAlerts {
    param($Monitors)
    $alerts = [Collections.Generic.List[object]]::new()
    foreach ($alert in (Get-SystemAlerts)) { $alerts.Add($alert) }
    try { foreach ($alert in (Get-DisplayAlerts $Monitors)) { $alerts.Add($alert) } } catch { }
    foreach ($alert in @($script:insightCache.NetworkAlerts) + @($script:auditAlerts)) { if ($alert) { $alerts.Add($alert) } }
    return $alerts
}

function Measure-SetupScore {
    param($Alerts)
    $items = [Collections.Generic.List[object]]::new()
    $score = 100
    foreach ($alert in $Alerts) {
        $points = if ($alert.Severity -eq 'critical') { 20 } elseif ($alert.Severity -eq 'warning') { 10 } else { 0 }
        if ($points -eq 0) { continue }
        $score -= $points
        $items.Add((New-Alert $alert.Severity "−$points · $($alert.Title)" $alert.Detail))
    }
    return [pscustomobject]@{ Score = [math]::Max(0, $score); Items = $items }
}

# ---------------------------------------------------------------- scoring

function Measure-PcScore {
    param($Data, $SetupAlerts)
    $components = [Collections.Generic.List[object]]::new()

    $gpu = $null
    foreach ($adapter in $Data.Adapters) {
        $result = Measure-GpuScore $adapter.Name $adapter.VramGb
        if (-not $gpu -or $result.Score -gt $gpu.Score) {
            $gpu = [pscustomobject]@{ Score = $result.Score; Known = $result.Known; Name = $adapter.Name; VramGb = $adapter.VramGb }
        }
    }
    if (-not $gpu) { $gpu = [pscustomobject]@{ Score = 3; Known = $false; Name = 'okunamadı'; VramGb = 0 } }
    $gpuParts = @(Get-ScoreWord $gpu.Score)
    if ($gpu.VramGb -ge 1) { $gpuParts += "$([math]::Round($gpu.VramGb)) GB video belleği" }
    if ($gpu.Name -match 'Laptop|\d{4}[MS]\b|\bMX\d') { $gpuParts += 'dizüstü sürümü, güç sınırına bağlı' }
    if (-not $gpu.Known) { $gpuParts += 'tahmini (model tabloda yok)' }
    $components.Add([pscustomobject]@{
        Key = 'gpu'; Label = 'Ekran kartı'; Score = $gpu.Score; InOverall = $true; Detail = ($gpuParts -join ' · ')
        Model = (($gpu.Name -replace '\((R|TM)\)', '') -replace '^(NVIDIA|AMD|Intel)\s+', '' -replace 'GeForce\s+', '').Trim()
    })

    $cpu = Measure-CpuScore $Data.CpuName $Data.CoreSummary $Data.CpuCores
    $cores = $Data.CoreSummary
    $coreText = if ($cores.Count -ge 4 -and $cores[2] -gt 0) { "$($cores[0])P + $($cores[2])E çekirdek, $($cores[1] + $cores[3]) izlek" } else { "$($Data.CpuCores) çekirdek" }
    $cpuParts = @((Get-ScoreWord $cpu.Score), $coreText)
    if ($cpu.Mobile -and $cpu.Suffix) { $cpuParts += "dizüstü ($($cpu.Suffix) serisi)" }
    if (-not $cpu.Known) { $cpuParts += 'tahmini (model tanınmadı)' }
    $components.Add([pscustomobject]@{
        Key = 'cpu'; Label = 'İşlemci'; Score = $cpu.Score; InOverall = $true; Detail = ($cpuParts -join ' · ')
        Model = ((($Data.CpuName -replace '^\d+th Gen\s+', '') -replace '\((R|TM)\)', '') -replace '\s+(CPU\s+)?@.*$', '' -replace '\s+', ' ').Trim()
    })

    $modules = @($Data.Modules)
    $ramGb = ($modules | Measure-Object Capacity -Sum).Sum / 1GB
    $ramType = switch (@($modules)[0].Type) { 26 { 'DDR4' } 34 { 'DDR5' } 30 { 'LPDDR4' } 35 { 'LPDDR5' } default { 'DDR' } }
    $ramSpeed = [int]@($modules)[0].Speed
    $ramScore = Measure-RamScore $ramGb $modules.Count $ramType $ramSpeed
    $sizes = @($modules | ForEach-Object { [math]::Round($_.Capacity / 1GB) } | Sort-Object -Unique)
    $channel = if ($modules.Count -ge 2) { if ($sizes.Count -eq 1) { "çift kanal ($($modules.Count)×$($sizes[0]) GB)" } else { 'karışık modüller' } } elseif ($ramType -like 'LP*') { 'lehimli' } else { 'tek kanal (tek modül)' }
    $ramParts = @((Get-ScoreWord $ramScore), $channel)
    if ([math]::Round($ramGb) -le 16) { $ramParts += "yeni oyunlarda $([math]::Round($ramGb)) GB sınırda" }
    $components.Add([pscustomobject]@{
        Key = 'ram'; Label = 'RAM'; Score = $ramScore; InOverall = $true; Detail = ($ramParts -join ' · ')
        Model = "$([math]::Round($ramGb)) GB $ramType$(if ($ramSpeed -gt 0) { "-$ramSpeed" })"
    })

    $storage = Measure-StorageScore $Data.Disks
    # Decimal units, as on the drive's label (1 TB + 512 GB = 1,5 TB).
    $storageSize = if ($storage.SsdBytes -ge 1e12) { '{0:0.#} TB' -f ($storage.SsdBytes / 1e12) } elseif ($storage.SsdBytes -gt 0) { '{0:0} GB' -f ($storage.SsdBytes / 1e9) } else { '' }
    $storageWhy = switch ($storage.Kind) { 'NVMe SSD' { 'oyunlar hızlı yüklenir' } 'SATA SSD' { 'yeterli; NVMe daha hızlı yükler' } 'sabit disk (HDD)' { 'oyunlar yavaş yüklenir, dokular geç gelir' } default { '' } }
    $components.Add([pscustomobject]@{
        Key = 'storage'; Label = 'Depolama'; Score = $storage.Score; InOverall = $true
        Detail = (@((Get-ScoreWord $storage.Score), $storageWhy) | Where-Object { $_ }) -join ' · '
        Model = "$($storage.Kind)$(if ($storage.Count -gt 1) { " × $($storage.Count)" })$(if ($storageSize) { " · $storageSize" })"
    })

    $display = Measure-DisplayScore $Data.Monitors
    $components.Add([pscustomobject]@{
        Key = 'display'; Label = 'Ekran'; InOverall = $false
        Score = if ($display) { $display.Score } else { $null }
        Model = if ($display) { "$($display.Name) · $($display.Hz) Hz · $($display.Width)×$($display.Height)" } else { 'okunamadı' }
        Detail = if ($display) { (@((Get-ScoreWord $display.Score), 'bağlı ekranların en iyisi') + @(if ($display.Hdr) { 'HDR' })) -join ' · ' } else { '' }
    })

    $network = $Data.Network
    $networkScore = Measure-NetworkScore $network
    $networkKinds = @()
    if ($network.Wifi) { $networkKinds += $(if ($network.Generation) { $network.Generation } else { 'Wi-Fi' }) }
    if ($network.Ethernet) { $networkKinds += 'kablolu Ethernet' }
    $card = if ($network.Wifi) { $network.Wifi } else { $network.Ethernet }
    $networkModel = if ($card) { ("$($card.InterfaceDescription)" -replace '\((R|TM)\)', '').Trim() } else { 'okunamadı' }
    $components.Add([pscustomobject]@{
        Key = 'network'; Label = 'Ağ'; InOverall = $false; Score = $networkScore; Model = $networkModel
        Detail = if ($null -ne $networkScore) { "$(Get-ScoreWord $networkScore) · $($networkKinds -join ' + ')" } else { '' }
    })

    $overall = Get-OverallScore $gpu.Score $cpu.Score $ramScore $storage.Score
    $tier = if ($overall -ge 85) { 'Üst seviye oyun bilgisayarı' } elseif ($overall -ge 70) { 'Güçlü oyun bilgisayarı' } elseif ($overall -ge 55) { 'Orta seviye oyun bilgisayarı' }
        elseif ($overall -ge 40) { 'Giriş seviyesi oyun bilgisayarı' } else { 'Hafif oyunlar için' }

    # A rough idea of what to expect, led by the graphics card. No FPS numbers: nothing was measured.
    $expect = if ($gpu.Score -ge 85) { '4K ve yüksek Hz''de yeni oyunlar' } elseif ($gpu.Score -ge 70) { '1440p yüksek ayarlar; 1080p''de yüksek Hz' }
        elseif ($gpu.Score -ge 55) { '1080p yüksek ayarlar; e-spor oyunlarında yüksek Hz' } elseif ($gpu.Score -ge 40) { '1080p orta ayarlar; e-spor oyunlarında yüksek Hz' }
        elseif ($gpu.Score -ge 25) { '1080p düşük-orta ayarlar; hafif ve e-spor oyunları' } else { 'Hafif ve eski oyunlar; yeni oyunlar zorlanır' }
    $upscaler = if ($gpu.Name -match 'RTX') { 'DLSS' } else { 'FSR' }
    if ($gpu.VramGb -ge 1 -and $gpu.VramGb -le 4.5) { $expect += ". $([math]::Round($gpu.VramGb)) GB video belleği yeni oyunlarda doku ayarını sınırlar; $upscaler kullan." }
    else { $expect += '.' }

    $main = @($components | Where-Object InOverall | Where-Object Key -ne 'storage' | Sort-Object Score)
    $weak = $main[0]; $strong = $main[-1]
    $bottleneck = if ($strong.Score - $weak.Score -lt 12) { 'Dengeli: ana parçalar birbirine uygun, hiçbiri diğerini belirgin kısıtlamıyor.' }
    else {
        switch ($weak.Key) {
            'gpu' { "En zayıf halka ekran kartı ($($weak.Score)). Oyunlarda sınırı genelde o çizer; işlemci onu rahat besler. Ayarları ekran kartına göre seç ($upscaler, gölge, doku)." }
            'cpu' { "En zayıf halka işlemci ($($weak.Score)). Yüksek Hz'li e-spor oyunlarında ekran kartını tam besleyemeyebilir." }
            'ram' { "En zayıf halka RAM ($($weak.Score)). Oyun + tarayıcı + Discord birlikte takılmaya yol açabilir; en ucuz yükseltme bu." }
        }
    }

    # What an upgrade would change, in the same points.
    $whatIf = [Collections.Generic.List[string]]::new()
    if ([math]::Round($ramGb) -le 16) {
        $newRam = Measure-RamScore 32 2 $ramType $ramSpeed
        $newOverall = Get-OverallScore $gpu.Score $cpu.Score $newRam $storage.Score
        $short = @(Get-SessionHistory | Select-Object -Last 10 | Where-Object { $null -ne $_.MinFreeRamGb -and $_.MinFreeRamGb -lt 1.5 }).Count
        $evidence = if ($short -ge 2) { " Son oyunların $short tanesinde boş RAM 1,5 GB'ın altına indi." } else { '' }
        $whatIf.Add("• RAM 32 GB (2×16 GB $ramType): RAM $ramScore → $newRam, genel $overall → $newOverall.$evidence")
    }
    if ($storage.Score -lt 85) {
        $newOverall = Get-OverallScore $gpu.Score $cpu.Score $ramScore 92
        $whatIf.Add("• NVMe SSD: depolama $($storage.Score) → 92, genel $overall → $newOverall")
    }
    if ($Data.Laptop) {
        $whatIf.Add('• İşlemci ve ekran kartı lehimli; genel puan yükseltmeyle ancak birkaç puan artar.')
    } elseif ($gpu.Score -lt 70) {
        $target = if ($gpu.Score -lt 55) { 'RTX 5060' } else { 'RTX 5070' }
        $targetScore = (Measure-GpuScore $target 8).Score
        $whatIf.Add("• Ekran kartı $target seviyesi: ekran kartı $($gpu.Score) → $targetScore, genel $overall → $(Get-OverallScore $targetScore $cpu.Score $ramScore $storage.Score)")
    }
    if ($display -and $display.Hz -lt 144) { $whatIf.Add("• 144 Hz veya üstü monitör: genel puanı değiştirmez ama akıcılıkta en hissedilir fark ($($display.Hz) Hz → 144+)") }
    if ($whatIf.Count -eq 0) { $whatIf.Add('• Bu bilgisayar için puanı belirgin artıracak ucuz bir yükseltme yok.') }

    $scale = 'Ölçek: 100 = RTX 5090 masaüstü · RTX 4090 ≈ {0} · RTX 4060 ≈ {1} · Iris Xe ≈ {2}. Laptopta gerçek performans güç sınırına ve soğutmaya göre değişir.' -f `
        (Measure-GpuScore 'RTX 4090' 24).Score, (Measure-GpuScore 'RTX 4060' 8).Score, (Measure-GpuScore 'Intel Iris Xe Graphics' 0).Score

    if ($null -eq $SetupAlerts) { $SetupAlerts = Get-SetupAlerts $Data.Monitors }
    return [pscustomobject]@{
        Overall = $overall; Tier = $tier; Expectation = $expect; Bottleneck = $bottleneck
        Components = $components; Setup = (Measure-SetupScore $SetupAlerts); WhatIf = $whatIf; Scale = $scale
    }
}

# ---------------------------------------------------------------- how a game would run

# Publishers' 1080p minimum and recommended specs (approximate), with the cards turned into the same
# graphics scale as above. Name|aliases (exe / short names)|min GPU|rec GPU|VRAM min|VRAM rec|RAM min|RAM rec|flags
# flags: ssd, dlss, fsr, esports (high refresh matters most), rt (needs a ray-tracing card)
$script:gameRequirementsText = @'
Counter-Strike 2|cs2|1.8|4.0|1|2|8|16|esports,fsr
VALORANT|valorant-win64-shipping|0.3|2.4|1|1|4|4|esports
League of Legends|league of legends|0.3|1.0|1|1|4|8|esports
Dota 2|dota2|0.5|2.0|1|2|4|8|esports,fsr
Fortnite|fortniteclient-win64-shipping|0.3|2.6|1|4|8|16|esports,dlss,fsr
Apex Legends|r5apex,r5apex_dx12|0.6|3.4|1|4|6|8|esports
PUBG: BATTLEGROUNDS|tslgame|2.2|3.8|2|3|8|16|esports,dlss,fsr
Rocket League|rocketleague|1.8|4.0|2|2|8|8|esports
Overwatch 2|overwatch|0.8|4.0|2|3|6|8|esports,fsr
Tom Clancy's Rainbow Six Siege|rainbowsix,rainbowsix_vulkan|2.4|5.4|4|6|8|16|esports,dlss,fsr
Marvel Rivals|marvel-win64-shipping|4.0|8.7|6|8|16|16|esports,ssd,dlss,fsr
Call of Duty|cod,blackops6|2.2|7.3|3|8|8|16|ssd,dlss,fsr
Minecraft|javaw|0.5|1.5|1|2|4|8|
Grand Theft Auto V|gta5,gta5_enhanced|1.0|2.4|1|2|4|8|
Red Dead Redemption 2|rdr2|2.2|4.0|2|6|8|12|ssd,dlss,fsr
Cyberpunk 2077|cyberpunk2077|4.0|8.7|6|8|12|16|ssd,dlss,fsr
ELDEN RING|eldenring|3.8|6.0|3|8|12|16|ssd
Baldur's Gate 3|bg3,bg3_dx11|3.4|8.7|4|8|8|16|ssd,dlss,fsr
Hogwarts Legacy|hogwartslegacy|2.2|9.5|4|8|16|16|ssd,dlss,fsr
Forza Horizon 5|forzahorizon5|3.4|6.0|4|8|8|16|ssd,dlss,fsr
The Witcher 3: Wild Hunt|witcher3|1.6|4.0|2|4|6|8|dlss,fsr
Euro Truck Simulator 2|eurotrucks2|1.0|2.4|1|2|4|8|
EA SPORTS FC 25|fc25|2.4|5.4|4|6|8|12|
Black Myth: Wukong|b1-win64-shipping|4.0|7.5|6|6|16|16|ssd,dlss,fsr
HELLDIVERS 2|helldivers2|2.4|7.5|4|6|8|16|ssd,fsr
Palworld|palworld-win64-shipping|1.8|9.0|2|8|16|32|ssd,dlss,fsr
Rust|rustclient|1.4|4.0|2|4|10|16|ssd,dlss
Mount & Blade II: Bannerlord|bannerlord|1.6|3.8|2|3|6|8|ssd,dlss,fsr
Valheim|valheim|1.6|3.4|2|4|8|16|
Genshin Impact|genshinimpact,yuanshen|0.8|4.0|2|4|8|16|
Diablo IV|diabloiv|1.6|3.4|2|4|8|16|ssd,dlss,fsr
Path of Exile 2|pathofexile_x64steam|2.2|7.5|4|6|8|16|ssd,dlss,fsr
Monster Hunter Wilds|monsterhunterwilds|6.1|10.2|6|8|16|16|ssd,dlss,fsr
Starfield|starfield|6.8|11|8|8|16|16|ssd,dlss,fsr
Alan Wake 2|alanwake2|7.5|13.5|6|8|16|16|ssd,dlss
The Last of Us Part I|tlou-i|3.4|10.2|4|8|16|16|ssd,dlss,fsr
Ghost of Tsushima|ghostoftsushima|2.2|7.5|4|6|8|16|ssd,dlss,fsr
God of War|gow|2.2|4.0|4|6|8|8|dlss,fsr
Marvel's Spider-Man Remastered|spider-man|1.6|4.0|4|6|8|16|ssd,dlss,fsr
Assassin's Creed Valhalla|acvalhalla|2.2|7.3|4|8|8|8|ssd
Battlefield 2042|bf2042|2.4|8.7|4|8|8|16|ssd,dlss
Battlefield 6|bf6|7.5|11.7|6|8|16|16|ssd,dlss,fsr
Sons Of The Forest|sonsoftheforest|4.0|9.5|4|8|8|16|ssd,dlss
ARK: Survival Ascended|arkascended|7.3|17.5|8|10|16|32|ssd,dlss
DayZ|dayz_x64|1.8|4.0|2|4|8|12|
S.T.A.L.K.E.R. 2: Heart of Chornobyl|stalker2-win64-shipping|4.0|14.7|6|8|16|32|ssd,dlss,fsr
Kingdom Come: Deliverance II|kingdomcome|4.0|8.7|6|8|16|16|ssd,dlss,fsr
Indiana Jones and the Great Circle|thegreatcircle|8.7|19|8|12|16|32|ssd,dlss,rt
DOOM: The Dark Ages|doomthedarkages|8.7|17.8|8|10|16|32|ssd,dlss,rt
Zula|zula|0.5|1.0|1|1|2|4|esports
Metin2|metin2client|0.2|0.5|1|1|2|4|
'@

function ConvertTo-GameKey {
    param([string]$Name)
    return (($Name -replace '[^\p{L}\p{N}]', '').ToLowerInvariant())
}

$script:gameRequirements = @(foreach ($line in ($script:gameRequirementsText -split "`r?`n")) {
    $parts = $line.Split('|')
    if ($parts.Count -lt 9) { continue }
    $number = { param($Text) [double]::Parse($Text, [Globalization.CultureInfo]::InvariantCulture) }
    [pscustomobject]@{
        Name = $parts[0]; Key = ConvertTo-GameKey $parts[0]
        Aliases = @($parts[1].Split(',') | Where-Object { $_ } | ForEach-Object { ConvertTo-GameKey $_ })
        MinGpu = & $number $parts[2]; RecGpu = & $number $parts[3]
        VramMin = & $number $parts[4]; VramRec = & $number $parts[5]; RamMin = & $number $parts[6]; RamRec = & $number $parts[7]
        Flags = @($parts[8].Split(',') | Where-Object { $_ })
    }
})

function Find-GameRequirement {
    param([string]$Name)
    $key = ConvertTo-GameKey $Name
    if (-not $key) { return $null }
    foreach ($game in $script:gameRequirements) {
        if ($key -eq $game.Key -or $game.Aliases -contains $key) { return $game }
    }
    # "Grand Theft Auto V Enhanced", "Call of Duty: Black Ops 6"...
    foreach ($game in $script:gameRequirements) {
        if ($game.Key.Length -ge 6 -and $key.StartsWith($game.Key)) { return $game }
    }
    return $null
}

# Game names from the Steam and Epic libraries, the Riot folder and earlier sessions.
function Get-InstalledGameNames {
    $names = [Collections.Generic.List[string]]::new()
    $steam = Get-RegistryValue 'HKCU:\Software\Valve\Steam' 'SteamPath'
    if ($steam) {
        $libraries = [Collections.Generic.List[string]]::new()
        $libraries.Add(($steam -replace '/', '\'))
        $folders = Join-Path $libraries[0] 'steamapps\libraryfolders.vdf'
        if (Test-Path -LiteralPath $folders) {
            foreach ($match in [regex]::Matches([IO.File]::ReadAllText($folders), '"path"\s+"([^"]+)"')) { $libraries.Add(($match.Groups[1].Value -replace '\\\\', '\')) }
        }
        foreach ($library in ($libraries | Sort-Object -Unique)) {
            foreach ($manifest in @(Get-ChildItem -LiteralPath (Join-Path $library 'steamapps') -Filter 'appmanifest_*.acf' -ErrorAction SilentlyContinue)) {
                $text = [IO.File]::ReadAllText($manifest.FullName)
                if ($text -match '"name"\s+"([^"]+)"') { $names.Add($Matches[1]) }
            }
        }
    }
    $epic = Join-Path $env:ProgramData 'Epic\EpicGamesLauncher\Data\Manifests'
    foreach ($item in @(Get-ChildItem -LiteralPath $epic -Filter '*.item' -ErrorAction SilentlyContinue)) {
        try { $json = [IO.File]::ReadAllText($item.FullName) | ConvertFrom-Json; if ($json.DisplayName) { $names.Add($json.DisplayName) } } catch { }
    }
    foreach ($riot in @('VALORANT', 'League of Legends')) {
        if (Test-Path -LiteralPath (Join-Path "$env:SystemDrive\Riot Games" $riot)) { $names.Add($riot) }
    }
    foreach ($record in @(Get-SessionHistory)) { foreach ($game in @($record.Games)) { if ($game) { $names.Add([string]$game) } } }
    return $names
}

# Table games, the ones found on this PC first.
function Get-GameChoices {
    $installed = [Collections.Generic.HashSet[string]]::new()
    foreach ($name in (Get-InstalledGameNames)) {
        $game = Find-GameRequirement $name
        if ($game) { [void]$installed.Add($game.Name) }
    }
    return @($script:gameRequirements | Sort-Object @{ Expression = { -not $installed.Contains($_.Name) } }, Name | ForEach-Object {
        [pscustomobject]@{ Game = $_; Installed = $installed.Contains($_.Name); Text = $(if ($installed.Contains($_.Name)) { "✓  $($_.Name)" } else { "    $($_.Name)" }) }
    })
}

$script:gameLevels = @('Çalışmaz', 'Zorlanır', 'Düşük', 'Orta', 'Yüksek', 'Çok yüksek')

# A rough expectation at 1080p from the publisher's specs. Not an FPS measurement.
function Measure-GameEstimate {
    param($Game, $Data)
    $best = $null
    foreach ($adapter in $Data.Adapters) {
        $performance = Get-GpuPerformance $adapter.Name $adapter.VramGb
        if (-not $best -or $performance.Perf -gt $best.Perf) { $best = [pscustomobject]@{ Perf = $performance.Perf; Name = $adapter.Name; VramGb = $adapter.VramGb } }
    }
    $ramGb = [math]::Round((@($Data.Modules) | Measure-Object Capacity -Sum).Sum / 1GB)
    $vram = [math]::Round($best.VramGb)
    $notes = [Collections.Generic.List[string]]::new()
    $ratio = $best.Perf / $Game.RecGpu

    $level = if ($best.Perf -lt $Game.MinGpu * 0.9) { 1 } elseif ($best.Perf -lt $Game.MinGpu * 1.3 -or $ratio -lt 0.6) { 2 }
        elseif ($ratio -lt 0.95) { 3 } elseif ($ratio -lt 1.5) { 4 } else { 5 }
    $notes.Add(('Ekran kartı gücü: önerilenin {0:0.0} katı (en düşüğün {1:0.0} katı)' -f $ratio, ($best.Perf / $Game.MinGpu)))

    if ($vram -lt $Game.VramMin) {
        $level = [math]::Min($level, 2)
        $notes.Add("Video belleği: $vram GB, en az $($Game.VramMin) GB isteniyor → doku ayarı en düşükte")
    } elseif ($vram -lt $Game.VramRec) {
        $level = [math]::Min($level, 3)
        $notes.Add("Video belleği: $vram GB (önerilen $($Game.VramRec)) → doku ayarını Orta veya altında tut")
    } else { $notes.Add("Video belleği: $vram GB ✓") }

    if ($ramGb -lt $Game.RamMin) { $level = [math]::Min($level, 1); $notes.Add("RAM: $ramGb GB, en az $($Game.RamMin) GB isteniyor") }
    elseif ($ramGb -lt $Game.RamRec) { $notes.Add("RAM: $ramGb GB (önerilen $($Game.RamRec)) → oyunda tarayıcı ve gereksizleri kapat") }
    else { $notes.Add("RAM: $ramGb GB ✓") }

    $rtCard = $best.Name -match 'RTX|RX\s*[679]\d{3}|Arc'
    if ($Game.Flags -contains 'rt' -and (-not $rtCard -or $vram -lt $Game.VramMin)) {
        $level = 0
        $notes.Insert(0, "Işın izlemeli ekran kartı ve en az $($Game.VramMin) GB video belleği zorunlu")
    }
    if ($Game.Flags -contains 'ssd' -and -not (@($Data.Disks | Where-Object { $_.BusType -in 'NVMe', '17' -or $_.MediaType -in 'SSD', '4' }).Count)) {
        $notes.Add('SSD isteniyor; sabit diskte uzun yüklemeler ve takılmalar olur')
    }
    if ($level -ge 2 -and $level -le 4) {
        if ($Game.Flags -contains 'dlss' -and $best.Name -match 'RTX') { $notes.Add('DLSS destekli: Kalite modunda bir kademe yukarı çıkabilirsin') }
        elseif ($Game.Flags -contains 'fsr') { $notes.Add('FSR destekli: biraz daha akıcılık için açabilirsin') }
    }

    $esports = $Game.Flags -contains 'esports'
    $summary = switch ($level) {
        0 { 'Bu bilgisayarda çalışmaz' }
        1 { 'En düşük gereksinimin altında; takılarak çalışır' }
        2 { if ($esports) { 'Düşük ayarlarda oynanır' } else { '1080p Düşük ayarlarda oynanır' } }
        3 { if ($esports) { 'Rahat oynanır; 144+ Hz için ayarları düşür' } else { '1080p Orta ayarlarda oynanır' } }
        4 { if ($esports) { 'Rekabetçi ayarlarda yüksek Hz (144+) için uygun' } else { '1080p Yüksek ayarlarda rahat' } }
        default { if ($esports) { 'Yüksek ayarlarda bile yüksek Hz (144+)' } else { '1080p en yüksek ayarlarda rahat' } }
    }
    if ($Data.Laptop) { $notes.Add('Dizüstü: prizde ve iyi soğutmada geçerli; pilde belirgin düşer') }

    # What this PC actually did in this game before.
    $sessions = @(Get-SessionHistory | Where-Object { @($_.Games | Where-Object { (Find-GameRequirement ([string]$_)) -and (Find-GameRequirement ([string]$_)).Name -eq $Game.Name }).Count -gt 0 })
    if ($sessions.Count -gt 0) {
        $last = $sessions[-1]
        $parts = @("$($last.Minutes) dk")
        if ($last.GpuMaxTemp) { $parts += "GPU en yüksek $($last.GpuMaxTemp)°C" }
        if ($last.LimitSeconds -gt 0) { $parts += "ısı/güç yavaşlaması ~$($last.LimitSeconds) sn" }
        if ($null -ne $last.MinFreeRamGb) { $parts += ('boş RAM en az {0:0.0} GB' -f $last.MinFreeRamGb) }
        if ($last.OnBattery) { $parts += 'pilde' }
        $notes.Add("Bu PC'de son oturum: $($parts -join ' · ')")
    }
    return [pscustomobject]@{ Game = $Game.Name; Level = $level; LevelName = $script:gameLevels[$level]; Summary = $summary; Notes = $notes }
}

function Format-PcScoreText {
    param($Score, $Estimate)
    if (-not $Score) { return '' }
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add("GAMEBOOST LITE · PC PUANI · $((Get-Date).ToString('dd.MM.yyyy HH:mm'))")
    $lines.Add('')
    $lines.Add("PC gücü: $($Score.Overall)/100 · $($Score.Tier)")
    $lines.Add("Genel beklenti: $($Score.Expectation)")
    $lines.Add($Score.Bottleneck)
    $lines.Add('')
    $lines.Add('BİLEŞENLER (genel puan: ekran kartı %50, işlemci %25, RAM %15, depolama %10)')
    foreach ($component in $Score.Components) {
        if ($component.Key -eq 'display') { $lines.Add('  Oyun deneyimi (genel puana katılmaz):') }
        $value = if ($null -ne $component.Score) { '{0,3}' -f $component.Score } else { '  —' }
        $lines.Add(('  {0,-12} {1}  {2}' -f $component.Label, $value, $component.Model))
        if ($component.Detail) { $lines.Add("                    $($component.Detail)") }
    }
    $lines.Add('')
    $lines.Add("KURULUM PUANI: $($Score.Setup.Score)/100")
    if ($Score.Setup.Items.Count -eq 0) { $lines.Add('  Puanı düşüren bir şey yok.') }
    foreach ($item in $Score.Setup.Items) { $lines.Add("  $($item.Title)"); if ($item.Detail) { $lines.Add("      $($item.Detail)") } }
    $lines.Add('')
    $lines.Add('YÜKSELTİRSEN')
    foreach ($line in $Score.WhatIf) { $lines.Add("  $line") }
    if ($Estimate) {
        $lines.Add('')
        $lines.Add("OYUN TAHMİNİ: $($Estimate.Game) · $($Estimate.Summary)")
        foreach ($note in $Estimate.Notes) { $lines.Add("  • $note") }
        $lines.Add('  Yayıncının 1080p gereksinimlerine göre tahmin; FPS ölçümü değildir.')
    }
    $lines.Add('')
    $lines.Add($Score.Scale)
    $lines.Add('Puanlar model adından ve bilinen yaklaşık test sonuçlarından hesaplanır; bu bilgisayarda yük testi yapılmadı.')
    return ($lines -join "`r`n")
}
