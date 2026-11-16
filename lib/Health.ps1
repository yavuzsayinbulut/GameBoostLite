# Weekly health summary, battery care, driver age and one-click fixes for the causes of hitches.
# One cheap reading a day (disk, battery, driver date) plus a minute counter while the battery sits
# at 100 % on the charger. Everything is local. The only change made for you is the one you click;
# Legacy Defender exclusions are listed for manual review; no new exclusions are created.

function Get-HealthFile { return Join-Path $script:settingsDirectory 'health-history.json' }
function Get-GamePathsFile { return Join-Path $script:settingsDirectory 'game-paths.json' }
function Get-DefenderExclusionsFile { return Join-Path $script:settingsDirectory 'defender-exclusions.json' }

$script:health = $null
$script:healthSavedAt = [datetime]::MinValue
$script:driverInfo = @()
$script:designJob = $null
$script:healthReadDate = $null

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
    $newDay = $script:healthReadDate -ne (Get-HealthToday)
    if ($newDay) {
        $script:healthReadDate = Get-HealthToday
        $day.FreeGb = Get-SystemFreeGb
        $battery = Get-BatteryReading
        if ($battery -and $battery[1] -gt 0) { $day.FullMwh = $battery[1] }
    }
    # Defer registry and report work until the game has finished. Populate after app restart too.
    if (-not $script:boosted -and $script:driverReadDate -ne (Get-HealthToday)) {
        $script:driverReadDate = Get-HealthToday
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
    if (-not $latest -or -not ($state.DesignMwh -gt 0) -or $latest.Date -lt (Get-Date).AddDays(-2).ToString('yyyy-MM-dd')) { return $null }
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
    $lines.Add('Yerel kayıtlardaki oturumlar; ölçülmeyen süreler ve eski silinmiş kayıtlar dahil değildir.')
    $lines.Add('')

    $minutes = ($thisWeek | Measure-Object Minutes -Sum).Sum
    $before = ($lastWeek | Measure-Object Minutes -Sum).Sum
    $lines.Add("Oyun: $($thisWeek.Count) oturum, $(Format-WeekMinutes $minutes)$(if ($lastWeek.Count) { " (önceki hafta $(Format-WeekMinutes $before))" })")
    if ($thisWeek.Count) { $highlights.Add("$($thisWeek.Count) oyun, $(Format-WeekMinutes $minutes)") }

    $temps = @($thisWeek | Where-Object { $_.GpuMaxTemp -gt 0 } | ForEach-Object { [double]$_.GpuMaxTemp })
    $oldTemps = @($lastWeek | Where-Object { $_.GpuMaxTemp -gt 0 } | ForEach-Object { [double]$_.GpuMaxTemp })
    if ($temps.Count) {
        $average = [math]::Round(($temps | Measure-Object -Average).Average)
        $text = "Ölçüldü: $($temps.Count) oturumun en yüksek GPU sıcaklıklarının ortalaması $average°C"
        if ($oldTemps.Count) {
            $delta = $average - [math]::Round(($oldTemps | Measure-Object -Average).Average)
            $text += " ($(if ($delta -ge 0) { '+' })$delta°C geçen haftaya göre)"
            $text += ' · oyun, ayar, süre ve ortam farklı olabilir; bu fark tek başına arıza kanıtı değildir.'
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
        $lines.Add("Ölçüldü: $($hitchGames.Count) oturumda $hitches takılma$(if ($causes) { " · olası ilişkiler: $($causes -join ', ') (Çözümler sekmesi)" })")
        if ($causes) { $highlights.Add("takılmalarla olası ilişki: $($causes[0])") }
    } elseif ($thisWeek.Count) { $lines.Add('Takılma: yeterli ölçüm yok; izin ve ölçüm durumuna FPS / HUD sayfasından bak.') }

    $battery = Get-BatteryHealth
    if ($battery) {
        $text = 'Pil: Windows kapasite tahmini %{0} ({1:0.#} / {2:0.#} Wh); laboratuvar sağlık testi değildir.' -f $battery.Percent, $battery.FullWh, $battery.DesignWh
        if ($null -ne $battery.MonthAgoPercent) { $text += " · bir ay önce %$($battery.MonthAgoPercent)" }
        $lines.Add($text)
    }
    $fullDays = Get-FullChargeDays
    if ($fullDays -gt 0) {
        $lines.Add("Uygulama açıkken $fullDays gün en az 8 saat pil ≥%98 ve prizde gözlendi; kesintisiz süre ölçümü değildir.")
        if ($fullDays -ge 3) { $highlights.Add('pil yüksek dolulukta uzun süre prizde gözlendi') }
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
        $lines.Add("Sürücü: $($driver.Name) · $($driver.Date.ToString('dd.MM.yyyy')) ($($driver.Days) gün). Yeni sürüm bulunup bulunmadığı kontrol edilmedi.")
        if ($driver.Days -gt 120) { $highlights.Add('sürücü güncellemesini kontrol edebilirsin') }
    }

    $security = @($script:securityQuick | Where-Object { $_.Severity -in 'warning', 'critical' })
    $lines.Add("Güvenlik: $(if ($null -eq $script:securityQuick) { 'henüz kontrol edilmedi' } elseif ($security.Count) { "$($security.Count) bulgu (Güvenlik sekmesi)" } else { 'son kontrolde sorun yok' })")
    if ($security.Count) { $highlights.Add("$($security.Count) güvenlik bulgusu") }

    $lines.Add('')
    $lines.Add('Öneriler: Çözümler sekmesinde gözlemleri ve ilgili ayarlara bağlantıları görebilirsin.')
    return [pscustomobject]@{ Lines = $lines; Highlights = $highlights }
}

# ---------------------------------------------------------------- notices from the daily data

function Invoke-HealthNotices {
    $state = Get-HealthState
    if (((Get-Date) - [datetime]$state.LastWeekly).TotalDays -ge 7) {
        $summary = Get-WeeklySummary
        $text = if ($summary.Highlights.Count) { ($summary.Highlights | Select-Object -First 3) -join ' · ' } else { 'Henüz yeterli ölçüm yok' }
        if (Send-SmartNotice 'weekly' 'Haftalık özet hazır' "$text. Ayrıntılar Bakım ve Güvenlik > Haftalık." 'weekly' 10080) {
            $state.LastWeekly = Get-HealthToday
            Save-HealthState
        }
    }
    if ((Get-FullChargeDays) -ge 3) {
        [void](Send-SmartNotice 'battery-care' 'Pil yüksek dolulukta uzun süre prizde' 'Uygulama açıkken ≥%98 doluluk sık gözlendi. Modelinin desteklediği pil koruma seçeneklerini kontrol edebilirsin (Çözümler).' 'fixes' 10080)
    }
    $driver = Get-OldGpuDriver
    if ($driver) {
        [void](Send-SmartNotice 'driver-old' 'Sürücü güncellemesini kontrol et' "$($driver.Name): sürücü tarihi $($driver.Days) gün önce. Bu, yeni sürüm bulunduğu veya mevcut sürücünün sorunlu olduğu anlamına gelmez." 'fixes' 20160)
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
            $where = "Olası ilişki: Son $($recent.Count) oturumun $count tanesinde takılmalar $($info[0]) sırasında yoğunlaştı. Bu, nedenini tek başına kanıtlamaz."
            switch -Wildcard ($kind) {
                'defender' {
                    $items.Add((New-FixItem 'Defender etkinliği ile takılmalar örtüştü' "$where Koruma geçmişini kontrol et; korumayı azaltan klasör istisnası önerilmez." 'Güvenlik' { Start-Process 'windowsdefender:' } $null))
                }
                'update' { $items.Add((New-FixItem 'Güncelleme etkinliği ile takılmalar örtüştü' "$where Etkin saatler otomatik yeniden başlatmayı düzenler; indirme ve kurulumun tümünü engellemez." 'Etkin saatler' { Start-Process 'ms-settings:windowsupdate-activehours' } $null)) }
                'ram' { $items.Add((New-FixItem 'RAM oyunda doluyor' "$where Oyunda kapatılacak uygulamaları seç." 'Kapatma listesi' { Show-Page 'close' } $null)) }
                'download' {
                    $steam = Get-RegistryValue 'HKCU:\Software\Valve\Steam' 'SteamPath'
                    $items.Add((New-FixItem 'Ağ trafiği ile takılmalar örtüştü' "$where İndirme uygulamasındaki oyun sırasında indirme seçeneğini kontrol et." `
                        $(if ($steam) { 'Steam indirmeleri' } else { 'Modlar' }) $(if ($steam) { { Start-Process 'steam://open/downloads' } } else { { Show-Page 'modes' } }) $null))
                }
                'gpu' {
                    $omen = Get-OmenHub
                    $items.Add((New-FixItem 'GPU sınır bildirimi ile takılmalar örtüştü' "$where Havalandırmanın açık olduğunu ve üreticinin güç / fan ayarlarını kontrol et." `
                        $(if ($omen) { 'OMEN Hub' } else { '' }) { param($Uri) Start-Process $Uri } $omen))
                }
                'wifi' { $items.Add((New-FixItem 'Ping sıçramaları ile takılmalar örtüştü' "$where Ağ sayfasından bağlantıyı kontrol et; mümkünse kablolu bağlantıyla karşılaştır." 'Ağ / Wi-Fi' { Show-Page 'network' } $null)) }
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
        $app = if ($driver.Name -match 'NVIDIA') { Get-NvidiaApp } else { $null }
        $items.Add((New-FixItem "Sürücü tarihi: $($driver.Days) gün önce" "Genel öneri: $($driver.Name) · $($driver.Version) · $($driver.Date.ToString('dd.MM.yyyy')). Daha yeni sürüm olup olmadığı doğrulanmadı; tarihi tek başına sorun göstermez." `
            $(if ($app) { 'NVIDIA App' } else { 'Güncellemeler' }) { param($App) if ($App) { Start-Process $App } else { Start-Process 'ms-settings:windowsupdate' } } $app))
    }
    if ((Get-FullChargeDays) -ge 3) {
        $items.Add((New-FixItem 'Pil yüksek dolulukta uzun süre prizde' "Ölçüldü: uygulama açıkken $(Get-FullChargeDays) gün en az 8 saat ≥%98 doluluk gözlendi. Genel öneri: üreticinin bu model için desteklediği pil koruma ayarlarını kontrol et; destek varsayılmaz." 'Pil ayarları' { Start-Process 'ms-settings:batterysaver' } $null))
    }
    $battery = Get-BatteryHealth
    if ($battery -and $battery.Percent -lt 80) {
        $items.Add((New-FixItem "Pil kapasite tahmini %$($battery.Percent)" ('Windows bildirimi: {0:0.#} / {1:0.#} Wh. Değer değişebilir; tek ölçümle pil arızası veya değişim kararı verilmez.' -f $battery.FullWh, $battery.DesignWh) '' $null $null))
    }
    foreach ($folder in (Get-DefenderExclusions)) {
        $items.Add((New-FixItem 'Önceki sürümün Defender istisna kaydı' "$folder için eski bir kayıt var; güncel durum doğrulanmadı. Windows Güvenliği > Virüs ve tehdit koruması > Dışlamalar bölümünde kontrol et. Bu sürüm istisna eklemez." 'Güvenlik' { Start-Process 'windowsdefender:' } $null))
    }
    return $items
}
