# Weekly health summary, battery care, driver age and one-click fixes for the causes of hitches.
# One cheap reading a day (disk, battery, driver date) plus a minute counter while the battery sits
# at 100 % on the charger. Everything is local. The only change made for you is the one you click;
# the Defender exclusion needs admin, is written down and is undone from the same list.

function Get-HealthFile { return Join-Path $script:settingsDirectory 'health-history.json' }
function Get-GamePathsFile { return Join-Path $script:settingsDirectory 'game-paths.json' }
function Get-DefenderExclusionsFile { return Join-Path $script:settingsDirectory 'defender-exclusions.json' }
function Get-DefenderResultFile { return Join-Path $script:settingsDirectory 'defender-result.txt' }

$script:health = $null
$script:healthSavedAt = [datetime]::MinValue
$script:driverInfo = @()
$script:designJob = $null

function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json } catch { return $null }
}

function Write-JsonFile {
    param([string]$Path, $Data)
    try {
        New-Item -ItemType Directory -Path (Split-Path $Path) -Force | Out-Null
        $temp = "$Path.tmp"
        ConvertTo-Json -InputObject $Data -Depth 5 | Set-Content -LiteralPath $temp -Encoding UTF8
        Move-Item -LiteralPath $temp -Destination $Path -Force
    } catch { }
}

# Seams for the tests.
function Get-HealthToday { return (Get-Date).ToString('yyyy-MM-dd') }
function Get-SystemFreeGb { $drive = [IO.DriveInfo]::new($env:SystemDrive); if ($drive.IsReady) { return [math]::Round($drive.AvailableFreeSpace / 1GB, 1) } return $null }
function Get-BatteryReading { return [GameBoostSystemState]::Battery() }

# { Days = [{ Date, FreeGb, FullMwh, AtFullMinutes }], DesignMwh, DesignAt, LastWeekly }, 60 days kept.
function Get-HealthState {
    if ($script:health) { return $script:health }
    $data = Read-JsonFile (Get-HealthFile)
    $days = [Collections.Generic.List[object]]::new()
    foreach ($day in @($data.Days | ForEach-Object { $_ })) {
        if ($day -and $day.Date) { $days.Add([pscustomobject]@{ Date = [string]$day.Date; FreeGb = $day.FreeGb; FullMwh = $day.FullMwh; AtFullMinutes = [int]$day.AtFullMinutes }) }
    }
    $script:health = [pscustomobject]@{
        Days = $days; DesignMwh = $data.DesignMwh; DesignAt = $data.DesignAt
        LastWeekly = $(if ($data.LastWeekly) { [string]$data.LastWeekly } else { Get-HealthToday })
    }
    return $script:health
}

function Save-HealthState {
    $state = Get-HealthState
    Write-JsonFile (Get-HealthFile) ([ordered]@{ Days = @($state.Days); DesignMwh = $state.DesignMwh; DesignAt = $state.DesignAt; LastWeekly = $state.LastWeekly })
    $script:healthSavedAt = [datetime]::UtcNow
}

function Get-HealthDay {
    $state = Get-HealthState
    $today = Get-HealthToday
    $day = $state.Days | Where-Object Date -eq $today | Select-Object -First 1
    if (-not $day) {
        $day = [pscustomobject]@{ Date = $today; FreeGb = $null; FullMwh = $null; AtFullMinutes = 0 }
        $state.Days.Add($day)
        while ($state.Days.Count -gt 60) { $state.Days.RemoveAt(0) }
    }
    return $day
}

# Once a minute from the modes tick: a few microseconds, a file write at most every 30 minutes.
function Update-HealthMinute {
    $day = Get-HealthDay
    $power = Get-PowerSample
    if ($power.Online -and $power.HasBattery -and $null -ne $power.Percent -and $power.Percent -ge 98) { $day.AtFullMinutes++ }
    $newDay = $null -eq $day.FreeGb
    if ($newDay) {
        $day.FreeGb = Get-SystemFreeGb
        $battery = Get-BatteryReading
        if ($battery -and $battery[1] -gt 0) { $day.FullMwh = $battery[1] }
        $script:driverInfo = @(Get-DriverInfo)
        Start-BatteryDesignRead
    }
    if ($newDay -or ([datetime]::UtcNow - $script:healthSavedAt).TotalMinutes -ge 30) { Save-HealthState }
    if (-not $script:boosted) { Invoke-HealthNotices }
}

# Design capacity comes from Windows' battery report (powercfg, ~0.3 s): read in the background, monthly.
function Start-BatteryDesignRead {
    $state = Get-HealthState
    if ($script:designJob -or -not (Get-BatteryReading)) { return }
    if ($state.DesignAt -and ((Get-Date) - [datetime]$state.DesignAt).TotalDays -lt 30) { return }
    $shell = [powershell]::Create()
    [void]$shell.AddScript("function Get-BatteryDetails {`r`n$(${function:Get-BatteryDetails})`r`n}`r`nGet-BatteryDetails")
    $job = [pscustomobject]@{ Shell = $shell; Handle = $shell.BeginInvoke() }
    $job | Add-Member -MemberType ScriptProperty -Name Done -Value { $this.Handle.IsCompleted }
    $script:designJob = $job
    Wait-UiJob $job {
        param($Job)
        $details = $null
        try { $details = @($Job.Shell.EndInvoke($Job.Handle)) | Select-Object -Last 1 } catch { }
        $Job.Shell.Dispose()
        $script:designJob = $null
        if ($details -and $details.DesignMwh -gt 0) {
            $state = Get-HealthState
            $state.DesignMwh = [double]$details.DesignMwh
            $state.DesignAt = (Get-Date).ToString('yyyy-MM-dd')
            Save-HealthState
        }
    }
}

function Get-BatteryHealth {
    $state = Get-HealthState
    $latest = @($state.Days | Where-Object { $_.FullMwh -gt 0 }) | Select-Object -Last 1
    if (-not $latest -or -not ($state.DesignMwh -gt 0)) { return $null }
    $monthAgo = @($state.Days | Where-Object { $_.FullMwh -gt 0 -and $_.Date -le (Get-Date).AddDays(-25).ToString('yyyy-MM-dd') }) | Select-Object -Last 1
    return [pscustomobject]@{
        Percent = [math]::Round(100 * $latest.FullMwh / $state.DesignMwh); FullWh = [math]::Round($latest.FullMwh / 1000, 1); DesignWh = [math]::Round($state.DesignMwh / 1000, 1)
        MonthAgoPercent = $(if ($monthAgo) { [math]::Round(100 * $monthAgo.FullMwh / $state.DesignMwh) } else { $null })
    }
}

# Days of the last week the laptop sat on the charger at 100 % for 8 hours or more.
function Get-FullChargeDays {
    $since = (Get-Date).AddDays(-7).ToString('yyyy-MM-dd')
    return @((Get-HealthState).Days | Where-Object { $_.Date -gt $since -and $_.AtFullMinutes -ge 480 }).Count
}

# Display drivers and their age, from the registry (no admin, no WMI).
# (Some subkeys of the class are closed to standard users; the .NET registry calls skip them quietly.)
function Get-DriverInfo {
    $drivers = [Collections.Generic.List[object]]::new()
    try { $class = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}') } catch { return @() }
    if (-not $class) { return @() }
    try {
        foreach ($name in $class.GetSubKeyNames()) {
            if ($name -notmatch '^\d{4}$') { continue }
            try { $key = $class.OpenSubKey($name) } catch { continue }
            if (-not $key) { continue }
            try {
                $date = [datetime]::MinValue
                $description = [string]$key.GetValue('DriverDesc')
                # Typed arguments: with an untyped list PowerShell picks the single-format overload and parsing fails.
                $parsed = [datetime]::TryParseExact([string]$key.GetValue('DriverDate'), [string[]]@('M-d-yyyy', 'MM-dd-yyyy'),
                    [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$date)
                if ($description -and $parsed) {
                    $drivers.Add([pscustomobject]@{ Name = $description; Provider = [string]$key.GetValue('ProviderName'); Version = [string]$key.GetValue('DriverVersion'); Date = $date; Days = [int]((Get-Date) - $date).TotalDays })
                }
            } finally { $key.Close() }
        }
    } finally { $class.Close() }
    return @($drivers)
}

function Get-OldGpuDriver {
    return @($script:driverInfo | Where-Object { $_.Name -match 'NVIDIA|Radeon|AMD|Arc' -and $_.Days -gt 120 }) | Select-Object -First 1
}

# ---------------------------------------------------------------- weekly summary

function Format-WeekMinutes { param([double]$Minutes) if ($Minutes -lt 60) { return "$([math]::Round($Minutes)) dk" } return '{0} sa {1} dk' -f [math]::Floor($Minutes / 60), [math]::Round($Minutes % 60) }

function Get-WeeklySummary {
    $now = Get-Date
    $sessions = @(Get-SessionHistory | Where-Object { $_.Date })
    $thisWeek = @($sessions | Where-Object { ([datetime]$_.Date) -gt $now.AddDays(-7) })
    $lastWeek = @($sessions | Where-Object { ([datetime]$_.Date) -le $now.AddDays(-7) -and ([datetime]$_.Date) -gt $now.AddDays(-14) })
    $lines = [Collections.Generic.List[string]]::new()
    $highlights = [Collections.Generic.List[string]]::new()
    $lines.Add("HAFTALIK SAĞLIK ÖZETİ · $($now.AddDays(-7).ToString('dd.MM')) – $($now.ToString('dd.MM'))")
    $lines.Add('')

    $minutes = ($thisWeek | Measure-Object Minutes -Sum).Sum
    $before = ($lastWeek | Measure-Object Minutes -Sum).Sum
    $lines.Add("Oyun: $($thisWeek.Count) oturum, $(Format-WeekMinutes $minutes)$(if ($lastWeek.Count) { " (önceki hafta $(Format-WeekMinutes $before))" })")
    if ($thisWeek.Count) { $highlights.Add("$($thisWeek.Count) oyun, $(Format-WeekMinutes $minutes)") }

    $temps = @($thisWeek | Where-Object { $_.GpuMaxTemp -gt 0 } | ForEach-Object { [double]$_.GpuMaxTemp })
    $oldTemps = @($lastWeek | Where-Object { $_.GpuMaxTemp -gt 0 } | ForEach-Object { [double]$_.GpuMaxTemp })
    if ($temps.Count) {
        $average = [math]::Round(($temps | Measure-Object -Average).Average)
        $text = "Ekran kartı: oyunlarda en yüksek ortalama $average°C"
        if ($oldTemps.Count) {
            $delta = $average - [math]::Round(($oldTemps | Measure-Object -Average).Average)
            $text += " ($(if ($delta -ge 0) { '+' })$delta°C geçen haftaya göre)"
            if ($delta -ge 5) { $text += ' → ısı artıyor: hava girişlerini ve fanları temizlet'; $highlights.Add("ekran kartı $delta°C daha sıcak") }
        }
        $lines.Add($text)
    }
    $limit = ($thisWeek | Measure-Object LimitSeconds -Sum).Sum
    if ($limit -gt 0) { $lines.Add("Isı / güç yavaşlaması: toplam ~$(Format-WeekMinutes ($limit / 60))") }

    $hitchGames = @($thisWeek | Where-Object { $null -ne $_.Hitches })
    if ($hitchGames.Count) {
        $hitches = ($hitchGames | Measure-Object Hitches -Sum).Sum
        $causes = @($hitchGames | ForEach-Object { @($_.HitchCauses) } | Where-Object { $_ } | Group-Object | Sort-Object Count -Descending | Select-Object -First 2 |
            ForEach-Object { (Get-HitchCauseInfo $_.Name)[0] })
        $lines.Add("Takılma: $hitches$(if ($causes) { " · en sık neden: $($causes -join ', ') (Çözümler sekmesi)" })")
        if ($causes) { $highlights.Add("takılma nedeni: $($causes[0])") }
    } elseif ($thisWeek.Count) { $lines.Add('Takılma: ölçülmedi (FPS yetkisi gerekiyor: FPS / HUD sayfası)') }

    $battery = Get-BatteryHealth
    if ($battery) {
        $text = 'Pil: sağlık %{0} ({1:0.#} / {2:0.#} Wh)' -f $battery.Percent, $battery.FullWh, $battery.DesignWh
        if ($null -ne $battery.MonthAgoPercent) { $text += " · bir ay önce %$($battery.MonthAgoPercent)" }
        $lines.Add($text)
    }
    $fullDays = Get-FullChargeDays
    if ($fullDays -gt 0) {
        $lines.Add("Pil $fullDays gün 8 saatten uzun %100'de prizde kaldı$(if ($fullDays -ge 3) { ' → pil korumasını aç (Çözümler)' })")
        if ($fullDays -ge 3) { $highlights.Add('pil sürekli %100''de') }
    }

    $days = (Get-HealthState).Days
    $today = $days | Where-Object { $null -ne $_.FreeGb } | Select-Object -Last 1
    $weekAgo = @($days | Where-Object { $null -ne $_.FreeGb -and $_.Date -le $now.AddDays(-7).ToString('yyyy-MM-dd') }) | Select-Object -Last 1
    if ($today) {
        $text = 'Disk {0} {1:0.#} GB boş' -f $env:SystemDrive, $today.FreeGb
        if ($weekAgo) { $text += ' ({0}{1:0.#} GB, geçen haftaya göre)' -f $(if ($today.FreeGb -ge $weekAgo.FreeGb) { '+' } else { '' }), ($today.FreeGb - $weekAgo.FreeGb) }
        $lines.Add($text)
    }

    $driver = @($script:driverInfo | Where-Object { $_.Name -match 'NVIDIA|Radeon|AMD|Arc' }) | Select-Object -First 1
    if ($driver) {
        $lines.Add("Sürücü: $($driver.Name -replace '^NVIDIA GeForce ', '') · $($driver.Date.ToString('dd.MM.yyyy')) ($($driver.Days) gün)$(if ($driver.Days -gt 120) { ' → güncelle' })")
        if ($driver.Days -gt 120) { $highlights.Add('sürücü eski') }
    }

    $security = @($script:securityQuick | Where-Object { $_.Severity -in 'warning', 'critical' })
    $lines.Add("Güvenlik: $(if ($null -eq $script:securityQuick) { 'henüz kontrol edilmedi' } elseif ($security.Count) { "$($security.Count) bulgu (Güvenlik sekmesi)" } else { 'son kontrolde sorun yok' })")
    if ($security.Count) { $highlights.Add("$($security.Count) güvenlik bulgusu") }

    $fixes = @(Get-FixItems | Where-Object Button)
    $lines.Add('')
    $lines.Add($(if ($fixes.Count) { "Öneriler: Çözümler sekmesinde $($fixes.Count) tek tıklık çözüm var." } else { 'Öneriler: şu an yapılacak bir şey yok.' }))
    return [pscustomobject]@{ Lines = $lines; Highlights = $highlights }
}

# ---------------------------------------------------------------- notices from the daily data

function Invoke-HealthNotices {
    $state = Get-HealthState
    if (((Get-Date) - [datetime]$state.LastWeekly).TotalDays -ge 7) {
        $summary = Get-WeeklySummary
        $text = if ($summary.Highlights.Count) { ($summary.Highlights | Select-Object -First 3) -join ' · ' } else { 'Her şey yolunda görünüyor.' }
        if (Send-SmartNotice 'weekly' 'Haftalık özet hazır' "$text. Ayrıntılar Bakım ve Güvenlik > Haftalık." 'weekly' 10080) {
            $state.LastWeekly = Get-HealthToday
            Save-HealthState
        }
    }
    if ((Get-FullChargeDays) -ge 3) {
        [void](Send-SmartNotice 'battery-care' 'Pil sürekli %100''de prizde' 'Pil böyle daha hızlı yıpranır. HP pil korumasını aç (Bakım ve Güvenlik > Çözümler).' 'fixes' 10080)
    }
    $driver = Get-OldGpuDriver
    if ($driver) {
        [void](Send-SmartNotice 'driver-old' 'Ekran kartı sürücüsü eski' "$($driver.Name): $($driver.Days) gün önceki sürüm. Yeni oyunlarda performans ve hata düzeltmeleri kaçıyor olabilir." 'fixes' 20160)
    }
}

# ---------------------------------------------------------------- games' folders (for the Defender fix)

function Save-GamePath {
    param([string]$Name, [string]$Path)
    if (-not $Name -or -not $Path) { return }
    $map = @{}
    $data = Read-JsonFile (Get-GamePathsFile)
    if ($data) { foreach ($property in $data.PSObject.Properties) { $map[$property.Name] = [string]$property.Value } }
    if ($map[$Name] -eq $Path) { return }
    $map[$Name] = $Path
    Write-JsonFile (Get-GamePathsFile) $map
}

# The game's own folder inside a library (steamapps\common\<game>, Epic Games\<game>...), or nothing:
# a Defender exclusion is never offered for Downloads, Temp or other folders malware likes.
function Get-GameFolder {
    param([string]$Name)
    $data = Read-JsonFile (Get-GamePathsFile)
    $path = if ($data) { [string]$data.$Name } else { $null }
    if (-not $path -or -not [GameBoostEngine]::IsGameLibraryPath($path)) { return $null }
    $match = [regex]::Match($path, '^(.*?\\(steamapps\\common|Epic Games|XboxGames|EA Games|Ubisoft Game Launcher\\games|Rockstar Games)\\[^\\]+)', 'IgnoreCase')
    if ($match.Success) { return $match.Groups[1].Value }
    return $null
}

function Get-DefenderExclusions { return @((Read-JsonFile (Get-DefenderExclusionsFile)) | ForEach-Object { $_ } | Where-Object { $_ }) }

# Elevated (UAC), then read back by the elevated script itself: a standard user cannot see exclusions.
function Set-DefenderExclusion {
    param([string]$Folder, [switch]$Remove)
    $folderLiteral = ConvertTo-ScriptLiteral $Folder
    $resultLiteral = ConvertTo-ScriptLiteral (Get-DefenderResultFile)
    Remove-Item -LiteralPath (Get-DefenderResultFile) -Force -ErrorAction SilentlyContinue
    $lines = if ($Remove) {
        @("Remove-MpPreference -ExclusionPath $folderLiteral",
          "if (@((Get-MpPreference).ExclusionPath) -notcontains $folderLiteral) { 'ok' | Set-Content -LiteralPath $resultLiteral -Encoding ASCII } else { 'failed' | Set-Content -LiteralPath $resultLiteral -Encoding ASCII }")
    } else {
        @("Add-MpPreference -ExclusionPath $folderLiteral",
          "if (@((Get-MpPreference).ExclusionPath) -contains $folderLiteral) { 'ok' | Set-Content -LiteralPath $resultLiteral -Encoding ASCII } else { 'failed' | Set-Content -LiteralPath $resultLiteral -Encoding ASCII }")
    }
    if (-not (Invoke-AdminScript $lines)) { return }
    $script:pendingExclusion = [pscustomobject]@{ Folder = $Folder; Remove = [bool]$Remove }
    Start-DelayedAction 8000 { Complete-DefenderExclusion }
}

function Complete-DefenderExclusion {
    $pending = $script:pendingExclusion
    $script:pendingExclusion = $null
    if (-not $pending) { return }
    $result = (Get-Content -LiteralPath (Get-DefenderResultFile) -Raw -ErrorAction SilentlyContinue)
    Remove-Item -LiteralPath (Get-DefenderResultFile) -Force -ErrorAction SilentlyContinue
    if ("$result".Trim() -ne 'ok') { Add-Log "Defender hariç tutması $(if ($pending.Remove) { 'kaldırılamadı' } else { 'eklenemedi' }): $($pending.Folder)"; return }
    $list = [Collections.Generic.List[string]]::new()
    foreach ($folder in (Get-DefenderExclusions)) { if ($folder -ne $pending.Folder) { $list.Add($folder) } }
    if (-not $pending.Remove) { $list.Add($pending.Folder) }
    if ($list.Count) { Write-JsonFile (Get-DefenderExclusionsFile) @($list) } else { Remove-Item -LiteralPath (Get-DefenderExclusionsFile) -Force -ErrorAction SilentlyContinue }
    Add-Log $(if ($pending.Remove) { "Defender hariç tutması geri alındı: $($pending.Folder)" } else { "Defender bu oyun klasörünü artık taramıyor: $($pending.Folder)" })
    Update-FixesPage
}

# ---------------------------------------------------------------- fixes (one click each)

function Get-OmenHub {
    $package = Get-AppxPackage -Name '*OMENCommandCenter*' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($package) { return "shell:AppsFolder\$($package.PackageFamilyName)!$($package.Name)" }
    return $null
}

function Get-NvidiaApp {
    return @("$env:ProgramFiles\NVIDIA Corporation\NVIDIA app\CEF\NVIDIA App.exe") | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}

function New-FixItem {
    param([string]$Title, [string]$Detail, [string]$Button, [scriptblock]$Action, $Argument)
    return [pscustomobject]@{ Title = $Title; Detail = $Detail; Button = $Button; Action = $Action; Argument = $Argument }
}

# What the hitch analysis, the battery, the driver and the temperatures point at, each with its fix.
function Get-FixItems {
    $items = [Collections.Generic.List[object]]::new()
    $recent = @(Get-SessionHistory | Select-Object -Last 5)
    $seen = @{}
    foreach ($record in ($recent | Sort-Object { [datetime]$_.Date } -Descending)) {
        foreach ($kind in @($record.HitchCauses | Where-Object { $_ })) {
            if ($seen.ContainsKey($kind)) { continue }
            $seen[$kind] = $true
            $count = @($recent | Where-Object { @($_.HitchCauses) -contains $kind }).Count
            $info = Get-HitchCauseInfo $kind
            $where = "Son $($recent.Count) oyunun $count tanesinde takılmalar $($info[0]) sırasında yoğunlaştı."
            switch -Wildcard ($kind) {
                'defender' {
                    $games = @($recent | Where-Object { @($_.HitchCauses) -contains 'defender' } | ForEach-Object { @($_.Games) } | Sort-Object -Unique)
                    $excluded = Get-DefenderExclusions
                    $offered = $false
                    foreach ($game in $games) {
                        $folder = Get-GameFolder $game
                        if (-not $folder -or $excluded -contains $folder) { continue }
                        $offered = $true
                        $items.Add((New-FixItem "Defender: $game klasörünü taramadan hariç tut" `
                            "$where Defender açık kalır, yalnızca bu oyun klasörü taranmaz ($folder). Yalnızca mağazadan kurduğun oyunlar için. Yönetici izni ister; buradan geri alınır." `
                            'Hariç tut' { param($Folder) Set-DefenderExclusion $Folder } $folder))
                    }
                    if (-not $offered) { $items.Add((New-FixItem 'Defender taraması oyunda takılma yapıyor' "$where $($info[1])" 'Windows Güvenliği' { Start-Process 'windowsdefender:' } $null)) }
                }
                'update' { $items.Add((New-FixItem 'Windows Update oyunda takılma yapıyor' "$where Oynadığın saatleri etkin saatlere ekle; güncelleme o sırada kurulmaz." 'Etkin saatler' { Start-Process 'ms-settings:windowsupdate-activehours' } $null)) }
                'ram' { $items.Add((New-FixItem 'RAM oyunda doluyor' "$where Oyunda kapatılacak uygulamaları seç." 'Kapatma listesi' { Show-Page 'close' } $null)) }
                'download' {
                    $steam = Get-RegistryValue 'HKCU:\Software\Valve\Steam' 'SteamPath'
                    $items.Add((New-FixItem 'Arka plan indirmesi oyunda takılma yapıyor' "$where Steam > Ayarlar > İndirmeler > ""Oyun sırasında indirmelere izin ver"" kapalı olsun." `
                        $(if ($steam) { 'Steam indirmeleri' } else { 'Modlar' }) $(if ($steam) { { Start-Process 'steam://open/downloads' } } else { { Show-Page 'modes' } }) $null))
                }
                'gpu' {
                    $omen = Get-OmenHub
                    $items.Add((New-FixItem 'Ekran kartı ısınınca takılıyor' "$where Laptopu yükselt, hava girişlerini temizlet; OMEN Gaming Hub'da performans / fan modunu kontrol et." `
                        $(if ($omen) { 'OMEN Hub' } else { '' }) { param($Uri) Start-Process $Uri } $omen))
                }
                'wifi' { $items.Add((New-FixItem 'Wi-Fi ping sıçramaları takılma yapıyor' "$where Wi-Fi sürücü önerilerini uygula veya kablo kullan." 'Ağ / Wi-Fi' { Show-Page 'network' } $null)) }
                'cpu:*' {
                    $name = $kind.Substring(4)
                    $protected = Test-ProtectedCloseName $name
                    $listed = $script:customCloseNames.Contains($name)
                    $items.Add((New-FixItem "$name oyunda işlemciyi yoruyor" $(if ($protected) { "$where Bu uygulama korunuyor (ses, sohbet veya sistem); kapatılmaz." } elseif ($listed) { "$where Zaten BOOST'ta kapatılıyor." } else { "$where BOOST başlarken nazikçe kapatılsın." }) `
                        $(if ($protected -or $listed) { '' } else { 'Oyunda kapat' }) { param($Name) [void]$script:customCloseNames.Add($Name); Save-CustomSettings -Quiet; Add-Log "$Name BOOST kapatma listesine eklendi."; Update-FixesPage } $name))
                }
            }
        }
    }

    $driver = Get-OldGpuDriver
    if ($driver) {
        $app = Get-NvidiaApp
        $items.Add((New-FixItem "Ekran kartı sürücüsü $($driver.Days) günlük" "$($driver.Name) · $($driver.Version) · $($driver.Date.ToString('dd.MM.yyyy')). Yeni oyunlar için yeni sürücüler performans ve hata düzeltmesi getirir." `
            $(if ($app) { 'NVIDIA App' } else { 'Sürücü sayfası' }) { param($App) if ($App) { Start-Process $App } else { Start-Process 'https://www.nvidia.com/Download/index.aspx' } } $app))
    }
    if ((Get-FullChargeDays) -ge 3) {
        $omen = Get-OmenHub
        $items.Add((New-FixItem 'Pil sürekli %100''de prizde' "Son bir haftada $(Get-FullChargeDays) gün 8 saatten uzun. Pil böyle daha hızlı yıpranır. HP: BIOS (açılışta F10) > Gelişmiş > ""Adaptive Battery Optimizer"" veya OMEN Gaming Hub pil ayarı." `
            $(if ($omen) { 'OMEN Hub' } else { '' }) { param($Uri) Start-Process $Uri } $omen))
    }
    $battery = Get-BatteryHealth
    if ($battery -and $battery.Percent -lt 80) {
        $items.Add((New-FixItem "Pil sağlığı %$($battery.Percent)" ('Tam kapasite {0:0.#} / {1:0.#} Wh. %80 altında pil süresi belirgin kısalır; uzun pil süresi gerekiyorsa pil değişimi düşünülebilir.' -f $battery.FullWh, $battery.DesignWh) '' $null $null))
    }
    foreach ($folder in (Get-DefenderExclusions)) {
        $items.Add((New-FixItem 'Defender hariç tutması (GameBoost ekledi)' "$folder taranmıyor. Geri almak için tıkla (yönetici izni ister)." 'Geri al' { param($Folder) Set-DefenderExclusion $Folder -Remove } $folder))
    }
    return $items
}
