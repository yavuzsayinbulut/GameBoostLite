# BOOST engine: settings, process policy, efficiency mode, game detection, HUD control and cleanup.

$script:boosted = $false
$script:gameWasDetected = $false
$script:lastGameSeenUtc = [datetime]::MinValue
$script:previousPowerScheme = $null
$script:detectedGames = @{}
$script:efficiencyTargets = @{}
$script:foregroundNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$script:lastForegroundPid = 0
$script:activityStrikes = @{}
$script:activityLastAlert = @{}
$script:fullscreenCandidate = 0
$script:boostTick = 0
$script:highPerformanceGuid = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
$script:settingsDirectory = Join-Path $env:LOCALAPPDATA 'GameBoostLite'
$script:settingsFile = Join-Path $script:settingsDirectory 'settings.json'
$script:runtimeStateFile = Join-Path $script:settingsDirectory 'runtime-state.json'
$script:staleBoostRestored = $false
$script:settingsLoaded = $false
$script:recommendationsInitialized = $false
$script:overlayPrompted = $true
$script:overlayEnabled = $true
$script:trayHintShown = $false
$script:presentMonPath = 'C:\Program Files\NVIDIA Corporation\FrameViewSDK\bin\PresentMon_x64.exe'
$script:customCloseNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$script:customDisplayMap = @{}
$script:options = [ordered]@{
    CloseWorkApps   = $true
    CloseGameBar    = $true
    CloseDiscord    = $false
    CloseDocker     = $true
    EfficiencyMode  = $true
    AutoRestore     = $true
    MinimizeOnBoost = $true
    AutoStart       = $false
    StartInTray     = $false
    AutoBoost       = $false
    SmartNotices    = $true
    DownloadAutoStop = $true
    SaverRefresh    = $true
    SaverBrightness = $true
}
$script:boostMode = $null
$script:autoBoostCandidate = $null
$script:autoBoostSuppressed = [Collections.Generic.HashSet[string]]::new()

$script:workAppNames = @('Code', 'codex', 'codex-code-mode-host', 'msedge', 'ms-teams', 'Teams')
$script:gameBarNames = @('GameBar', 'GameBarFTServer', 'GameBarPresenceWriter', 'XboxGameBarWidgets',
    'XboxPcAppFT', 'SpotifyXboxGamebarWebView', 'EdgeGameAssist')
$script:dockerNames = @('Docker Desktop', 'com.docker.backend', 'com.docker.build', 'docker')
$script:dockerDisplayNames = $script:dockerNames + @('vmmemWSL')

function New-NameSet {
    param([string[]]$Names)
    $set = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $Names) { [void]$set.Add($name) }
    return ,$set
}

$script:recommendedCloseNames = New-NameSet @(
    'chrome', 'firefox', 'brave', 'opera', 'Spotify', 'WhatsApp', 'Telegram',
    'Slack', 'Zoom', 'Notion', 'Figma', 'claude'
)

$script:excludedNames = New-NameSet @(
    'powershell', 'powershell_ise', 'steam', 'steamservice', 'steamwebhelper', 'GameOverlayUI',
    'EpicGamesLauncher', 'EpicWebHelper', 'EpicOnlineServicesUserHelper',
    'EOSOverlayRenderer-Win64-Shipping', 'EADesktop', 'EALauncher',
    'EABackgroundService', 'EALocalHostSvc', 'EACefSubProcess', 'UbisoftConnect',
    'upc', 'UplayWebCore', 'RockstarService', 'Launcher', 'SocialClubHelper',
    'EasyAntiCheat', 'EasyAntiCheat_EOS', 'BEService', 'BEService_x64',
    'CrashReportClient', 'UnityCrashHandler64', 'UnityCrashHandler32', 'conhost',
    'explorer', 'dwm', 'System', 'Registry', 'MsMpEng'
)
foreach ($name in $script:excludedNames) { [void][GameBoostEngine]::ExcludedNames.Add($name) }

$script:protectedCloseNames = New-NameSet @(
    'powershell', 'powershell_ise', 'System', 'Idle', 'Registry', 'smss', 'csrss',
    'wininit', 'winlogon', 'services', 'lsass', 'svchost', 'fontdrvhost', 'dwm',
    'explorer', 'sihost', 'taskhostw', 'conhost', 'audiodg', 'MsMpEng', 'NisSrv',
    'SecurityHealthService', 'SecurityHealthSystray', 'Memory Compression', 'WmiPrvSE',
    'RuntimeBroker', 'StartMenuExperienceHost', 'ShellExperienceHost', 'SearchHost',
    'SearchIndexer', 'SearchProtocolHost', 'SearchFilterHost', 'ctfmon', 'spoolsv',
    'WUDFHost', 'dasHost', 'LsaIso', 'Secure System', 'SystemSettings',
    'ApplicationFrameHost', 'UserOOBEBroker', 'LockApp', 'TextInputHost', 'dllhost',
    'sppsvc', 'TiWorker', 'TrustedInstaller', 'MoUsoCoreWorker', 'smartscreen',
    'SgrmBroker', 'NVDisplay.Container', 'NVIDIA Share', 'PresentMon_x64', 'nvidia-smi',
    'OmenCap', 'OmenCommandCenterBackground', 'steam', 'steamservice', 'steamwebhelper',
    'GameOverlayUI', 'EpicGamesLauncher', 'EpicWebHelper', 'EpicOnlineServicesUserHelper',
    'EOSOverlayRenderer-Win64-Shipping', 'EADesktop', 'EALauncher', 'EABackgroundService',
    'EALocalHostSvc', 'EACefSubProcess', 'UbisoftConnect', 'upc', 'UplayWebCore',
    'RockstarService', 'Launcher', 'SocialClubHelper', 'EasyAntiCheat',
    'EasyAntiCheat_EOS', 'BEService', 'BEService_x64'
)

# Background apps that get efficiency mode during BOOST. Bringing one to the front undoes it.
# Chat apps are not here: a call during a game must not turn choppy.
$script:efficiencyNames = New-NameSet @(
    'chrome', 'msedge', 'firefox', 'brave', 'opera', 'Code',
    'Notion', 'Figma', 'claude', 'OneDrive', 'Dropbox', 'GoogleDriveFS',
    'PhoneExperienceHost', 'Widgets', 'WidgetService', 'Docker Desktop', 'com.docker.backend'
)

# Never slowed down: voice, chat, music, streaming, peripherals, overlays, anti-cheat, our own helpers.
$script:neverThrottlePattern = '^(obs|Streamlabs|XSplit|vlc|mpc-|PotPlayer|ts3client|TeamSpeak|mumble|voicemeeter|SteelSeries|lghub|Razer|iCUE|Corsair|MSIAfterburner|RTSS|EncoderServer|HWiNFO|Overwolf|Medal|nvidia|NV|PresentMon|Discord|Spotify|Teams|ms-teams|Slack|WhatsApp|Telegram|Zoom|Skype|Signal)|audio|sound|voice|sonar|nahimic|dolby|anticheat|battleye|faceit|vanguard|^vg|ricochet|xigncode|gameguard|nprotect|crash'
$script:neverThrottlePathPattern = '^[A-Za-z]:\\Windows\\|\\WindowsApps\\|\\(NVIDIA Corporation|NVIDIA|Realtek|Intel|AMD|HP|HP Inc|OMEN|SteelSeries|Logitech|LGHUB|Razer|Corsair|ASUS|MSI|Dolby|Nahimic|Waves|Steam|Epic Games|EA|Electronic Arts|Ubisoft|Rockstar Games|GOG Galaxy|Battle\.net|Riot Games)\\'

# Fullscreen apps that are not games.
$script:nonGameFullscreenNames = New-NameSet @(
    'explorer', 'mstsc', 'vmconnect', 'POWERPNT', 'WINWORD', 'EXCEL', 'ONENOTE', 'Acrobat', 'AcroRd32',
    'Code', 'devenv', 'idea64', 'pycharm64', 'WindowsTerminal', 'cmd', 'powershell', 'pwsh',
    'chrome', 'msedge', 'firefox', 'brave', 'opera', 'vivaldi', 'Discord', 'Spotify', 'ms-teams',
    'Teams', 'Zoom', 'Slack', 'obs64', 'LockApp', 'claude', 'Notion', 'Figma', 'WhatsApp',
    'Telegram', 'ApplicationFrameHost', 'Photos', 'Microsoft.Photos', 'Video.UI',
    'Microsoft.Media.Player', 'vlc', 'mpc-hc64', 'PotPlayerMini64', 'wmplayer', 'msedgewebview2'
)
$script:nonGamePattern = 'player|viewer|browser|video|media|photo|movie|stream|record|capture|remote|vnc|anydesk|teamviewer|vmware|virtualbox|terminal|snipping|screenclip'

# ---------------------------------------------------------------- log and power

function Add-Log {
    param([string]$Text)
    if ($null -eq $script:logBox) { return }
    $script:logBox.AppendText("$((Get-Date).ToString('HH:mm:ss'))  $Text`r`n")
    $script:logBox.SelectionStart = $script:logBox.TextLength
    $script:logBox.ScrollToCaret()
}

# Console helpers start with no window at all; Windows Terminal ignores "hidden" for new consoles.
function Start-HiddenProcess {
    param([string]$FilePath, [string]$Arguments)
    try {
        $info = [Diagnostics.ProcessStartInfo]::new($FilePath, $Arguments)
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        [void][Diagnostics.Process]::Start($info)
        return $true
    } catch { return $false }
}

function Get-ActivePowerScheme { return [GameBoostPower]::ActiveScheme() }

function Set-PowerScheme {
    param([string]$Scheme)
    if ([string]::IsNullOrWhiteSpace($Scheme)) { return }
    if (-not [GameBoostPower]::SetActiveScheme($Scheme)) { powercfg.exe /setactive $Scheme 2>$null | Out-Null }
}

function Get-PowerSchemeLabel {
    param([string]$Scheme = (Get-ActivePowerScheme))
    switch ($Scheme) {
        '381b4222-f694-41f0-9685-ff5bb260df2e' { return 'Dengeli' }
        '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c' { return 'Yüksek performans' }
        'a1841308-3541-4fab-bc81-f71556f20b4a' { return 'Güç tasarrufu' }
        'e9a42b02-d5df-448d-aa00-03f14749eb61' { return 'Nihai performans' }
        default { return 'Özel plan' }
    }
}

function Update-Metrics {
    $cpu = [math]::Round([GameBoostEngine]::CpuPercent())
    $memory = [GameBoostEngine]::MemoryGb()
    $text = 'CPU %{0}   ·   RAM {1:0.0} / {2:0.0} GB' -f $cpu, ($memory[1] - $memory[0]), $memory[1]
    if ($script:sidebarMetrics) { $script:sidebarMetrics.Text = $text }
    if ($script:metricsLabel) {
        $script:metricsLabel.Text = '{0}   ·   Güç planı: {1}' -f $text, (Get-PowerSchemeLabel)
    }
}

# ---------------------------------------------------------------- runtime state (crash recovery)

function Save-RuntimeState {
    try {
        New-Item -ItemType Directory -Path $script:settingsDirectory -Force | Out-Null
        $efficiency = @($script:efficiencyTargets.Values | ForEach-Object {
            [ordered]@{ Id = $_.Id; CreateTime = [string]$_.CreateTime; Priority = $_.Priority; Control = $_.Control; State = $_.State }
        })
        # Temp file first, then swapped in: a crash mid-write must not lose the power plan to restore.
        $temp = "$($script:runtimeStateFile).tmp"
        [ordered]@{
            BoostActive = $true
            PreviousPowerScheme = $script:previousPowerScheme
            Efficiency = $efficiency
            SavedAt = (Get-Date).ToString('o')
        } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $temp -Encoding UTF8
        Move-Item -LiteralPath $temp -Destination $script:runtimeStateFile -Force
    } catch { }
}

function Clear-RuntimeState {
    Remove-Item -LiteralPath $script:runtimeStateFile -Force -ErrorAction SilentlyContinue
}

# The HUD reads this to measure the same game BOOST found, including games outside the known libraries.
$script:currentGameFile = Join-Path $script:settingsDirectory 'current-game.json'

function Set-CurrentGameFile {
    param([int]$Id, [string]$Name)
    try {
        [ordered]@{ Id = $Id; Name = $Name } | ConvertTo-Json | Set-Content -LiteralPath $script:currentGameFile -Encoding UTF8
    } catch { }
}

function Clear-CurrentGameFile {
    Remove-Item -LiteralPath $script:currentGameFile -Force -ErrorAction SilentlyContinue
}

function Restore-StaleBoostState {
    if (-not (Test-Path $script:runtimeStateFile)) { return $false }
    try {
        $state = Get-Content -LiteralPath $script:runtimeStateFile -Raw | ConvertFrom-Json
        if ($state.BoostActive -and $state.PreviousPowerScheme) { Set-PowerScheme ([string]$state.PreviousPowerScheme) }
        foreach ($item in @($state.Efficiency)) {
            if ($null -eq $item) { continue }
            [void][GameBoostEngine]::TryRestoreEfficiency([int]$item.Id, [long]$item.CreateTime, [uint32]$item.Priority,
                [uint32]$item.Control, [uint32]$item.State)
        }
        Clear-RuntimeState
        Clear-CurrentGameFile
        return $true
    } catch {
        Clear-RuntimeState
        return $false
    }
}

# Through the Oyun Ayarları backup, so "Hepsini eski haline döndür" puts the original value back.
function Enable-GameMode {
    $tweak = $script:windowsTweaks | Where-Object Key -eq 'GameMode' | Select-Object -First 1
    if (-not (Test-TweakOn $tweak)) { [void](Enable-Tweak $tweak) }
}

# ---------------------------------------------------------------- closing apps

function Get-RunningGroups {
    param($Snapshot)
    $groups = @{}
    foreach ($process in $Snapshot) {
        $group = $groups[$process.Name]
        if ($null -eq $group) {
            $group = [pscustomobject]@{ Name = $process.Name; Count = 0; Bytes = [int64]0; HasWindow = $false; IsGame = $false }
            $groups[$process.Name] = $group
        }
        $group.Count++
        $group.Bytes += $process.WorkingSet
        if ($process.HasWindow) { $group.HasWindow = $true }
        if ($process.Path -and [GameBoostEngine]::IsGameLibraryPath($process.Path)) { $group.IsGame = $true }
    }
    return $groups
}

# Graceful names get a close request only; forced names are ended if they ignore it.
function Close-ProcessGroups {
    param([string[]]$GracefulNames, [string[]]$ForcedNames)
    $graceful = @(foreach ($name in $GracefulNames) { if ($name) { Get-Process -Name $name -ErrorAction SilentlyContinue } })
    $forced = @(foreach ($name in $ForcedNames) { if ($name) { Get-Process -Name $name -ErrorAction SilentlyContinue } })
    $all = @($graceful) + @($forced)
    if ($all.Count -eq 0) { return }
    foreach ($process in $all) {
        try { if ($process.MainWindowHandle -ne [IntPtr]::Zero) { [void]$process.CloseMainWindow() } } catch { }
    }
    $deadline = [datetime]::UtcNow.AddMilliseconds(1500)
    while ([datetime]::UtcNow -lt $deadline) {
        $pending = @($all | Where-Object { try { -not $_.HasExited } catch { $false } })
        if ($pending.Count -eq 0) { break }
        Start-Sleep -Milliseconds 150
    }
    foreach ($process in $forced) {
        try { if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue } } catch { }
    }
    $remaining = @($graceful | Where-Object { try { -not $_.HasExited } catch { $false } })
    if ($remaining.Count -gt 0) {
        $names = @($remaining | ForEach-Object ProcessName | Sort-Object -Unique) -join ', '
        Add-Log "Nazikçe kapanmayanlar açık bırakıldı: $names"
    }
}

function Stop-InfaticaIfRunning {
    $processes = Get-Process -Name infatica_agent -ErrorAction SilentlyContinue
    if (-not $processes) { return }
    $processes | Stop-Process -Force -ErrorAction SilentlyContinue
    Add-Log 'Infatica ağ paylaşım ajanı durduruldu.'
}

function Test-ProtectedCloseName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $true }
    $baseName = [IO.Path]::GetFileNameWithoutExtension($Name.Trim())
    if ($script:protectedCloseNames.Contains($baseName)) { return $true }
    if ($baseName -match '^(SecurityHealth|RtkAudio|RtkAudU|Omen|HPSystem|HPAudio|igfx)') { return $true }
    return $false
}

function Test-ExpectedClosedName {
    param([string]$Name)
    if ($script:customCloseNames.Contains($Name)) { return $true }
    if ($script:options.CloseWorkApps -and $Name -in $script:workAppNames) { return $true }
    if ($script:options.CloseGameBar -and $Name -in $script:gameBarNames) { return $true }
    if ($script:options.CloseDiscord -and $Name -eq 'Discord') { return $true }
    if ($script:options.CloseDocker -and $Name -in $script:dockerDisplayNames) { return $true }
    return $false
}

function Test-EfficiencyActive {
    param([string]$Name)
    foreach ($target in $script:efficiencyTargets.Values) { if ($target.Name -eq $Name) { return $true } }
    return $false
}

function Get-ProcessAction {
    param([string]$Name, [int[]]$Ids)
    if (Test-ProtectedCloseName $Name) { return 'Korunuyor' }
    foreach ($id in $Ids) { if ($script:detectedGames.ContainsKey($id)) { return 'Oyun · öncelik verildi' } }
    if ($script:customCloseNames.Contains($Name)) { return 'Kapanacak (özel liste)' }
    if ($Name -eq 'infatica_agent') { return 'Kapanacak' }
    if ($script:options.CloseWorkApps -and $Name -in $script:workAppNames) { return 'Kapanacak (nazikçe)' }
    if ($script:options.CloseGameBar -and $Name -in $script:gameBarNames) { return 'Kapanacak' }
    if ($script:options.CloseDiscord -and $Name -eq 'Discord') { return 'Kapanacak' }
    if ($script:options.CloseDocker -and $Name -in $script:dockerDisplayNames) { return 'Kapanacak' }
    if (Test-EfficiencyActive $Name) { return 'Verimlilik modunda' }
    if ($script:options.EfficiencyMode -and $script:efficiencyNames.Contains($Name)) { return 'Verimlilik modu (BOOST)' }
    return 'Açık kalacak'
}

# ---------------------------------------------------------------- settings

function Load-CustomSettings {
    if (-not (Test-Path $script:settingsFile)) { return }
    try {
        $settings = Get-Content -LiteralPath $script:settingsFile -Raw | ConvertFrom-Json
        foreach ($name in @($settings.CustomCloseNames)) {
            $normalized = [IO.Path]::GetFileNameWithoutExtension(([string]$name).Trim())
            if ($normalized -and -not (Test-ProtectedCloseName $normalized)) { [void]$script:customCloseNames.Add($normalized) }
        }
        if ($null -ne $settings.OverlayPrompted) { $script:overlayPrompted = [bool]$settings.OverlayPrompted }
        if ($null -ne $settings.OverlayEnabled) { $script:overlayEnabled = [bool]$settings.OverlayEnabled }
        if ($null -ne $settings.TrayHintShown) { $script:trayHintShown = [bool]$settings.TrayHintShown }
        if ($null -ne $settings.RecommendationsInitialized) {
            $script:recommendationsInitialized = [bool]$settings.RecommendationsInitialized
        }
        # Earlier versions stored the options at the top level; read both.
        foreach ($key in @($script:options.Keys)) {
            $value = if ($settings.Options -and $null -ne $settings.Options.$key) { $settings.Options.$key } else { $settings.$key }
            if ($null -ne $value) { $script:options[$key] = [bool]$value }
        }
        $script:settingsLoaded = $true
    } catch { }
}

function Initialize-RecommendedCloseNames {
    if ($script:recommendationsInitialized) { return }
    $running = New-NameSet @(Get-Process -ErrorAction SilentlyContinue | ForEach-Object ProcessName)
    foreach ($name in $script:recommendedCloseNames) {
        if ($running.Contains($name) -and -not (Test-ProtectedCloseName $name)) { [void]$script:customCloseNames.Add($name) }
    }
    $script:recommendationsInitialized = $true
}

function Save-CustomSettings {
    param([switch]$Quiet)
    try {
        New-Item -ItemType Directory -Path $script:settingsDirectory -Force | Out-Null
        [ordered]@{
            CustomCloseNames = @($script:customCloseNames | Sort-Object)
            RecommendationsInitialized = $script:recommendationsInitialized
            OverlayPrompted = $script:overlayPrompted
            OverlayEnabled = $script:overlayEnabled
            TrayHintShown = [bool]$script:trayHintShown
            Options = $script:options
        } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $script:settingsFile -Encoding UTF8
        if (-not $Quiet) { Add-Log "Kapatma listesi kaydedildi ($($script:customCloseNames.Count) uygulama)." }
    } catch { Add-Log 'Ayarlar kaydedilemedi.' }
}

# ---------------------------------------------------------------- live view and custom list

function Refresh-ProcessGrid {
    if ($null -eq $script:processGrid) { return }
    $groups = @(Get-Process -ErrorAction SilentlyContinue | Group-Object ProcessName | ForEach-Object {
        [pscustomobject]@{
            Name = $_.Name
            Count = $_.Count
            RAM = [math]::Round(($_.Group | Measure-Object WorkingSet64 -Sum).Sum / 1MB)
            Ids = @($_.Group.Id)
        }
    } | Sort-Object RAM -Descending | Select-Object -First 45)

    $closingRam = 0
    $rows = foreach ($group in $groups) {
        $action = Get-ProcessAction $group.Name $group.Ids
        $color = $null
        if ($action -like 'Kapanacak*') { $color = $script:theme.Amber; $closingRam += $group.RAM }
        elseif ($action -eq 'Korunuyor') { $color = $script:theme.Blue }
        elseif ($action -like 'Oyun*') { $color = $script:theme.Accent }
        elseif ($action -like 'Verimlilik*') { $color = [Drawing.Color]::FromArgb(176, 150, 255) }
        New-UiRow @($group.Name, $group.Count, $group.RAM, $action) $color
    }
    Set-UiGridRows $script:processGrid $rows
    $script:processSummary.Text = "En çok RAM kullanan $($groups.Count) uygulama   ·   BOOST ile boşalacak: ~$closingRam MB"
}

function Refresh-CustomList {
    if ($null -eq $script:customList) { return }
    $ramByName = @{}
    foreach ($group in (Get-Process -ErrorAction SilentlyContinue | Group-Object ProcessName)) {
        $ramByName[$group.Name] = [math]::Round(($group.Group | Measure-Object WorkingSet64 -Sum).Sum / 1MB)
    }
    $names = @(@($ramByName.Keys) + @($script:customCloseNames) | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_) -and -not (Test-ProtectedCloseName $_)
    } | Sort-Object -Unique)

    $script:customDisplayMap = @{}
    $script:customList.BeginUpdate()
    $script:customList.Items.Clear()
    foreach ($name in $names) {
        $ram = if ($ramByName.ContainsKey($name)) { $ramByName[$name] } else { 0 }
        $prefix = if ($script:recommendedCloseNames.Contains($name)) { '★ ' } else { '' }
        $display = "$prefix$name   ·   $ram MB"
        $script:customDisplayMap[$display] = $name
        $index = $script:customList.Items.Add($display)
        if ($script:customCloseNames.Contains($name)) { $script:customList.SetItemChecked($index, $true) }
    }
    $script:customList.EndUpdate()
}

function Select-RecommendedCustomItems {
    for ($index = 0; $index -lt $script:customList.Items.Count; $index++) {
        $name = $script:customDisplayMap[[string]$script:customList.Items[$index]]
        if ($name -and $script:recommendedCloseNames.Contains($name)) { $script:customList.SetItemChecked($index, $true) }
    }
}

function Save-CustomListFromUi {
    $newNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($item in $script:customList.CheckedItems) {
        $name = $script:customDisplayMap[[string]$item]
        if ($name -and -not (Test-ProtectedCloseName $name)) { [void]$newNames.Add($name) }
    }
    $manual = [IO.Path]::GetFileNameWithoutExtension($script:customNameBox.Text.Trim())
    if ($manual) {
        if (Test-ProtectedCloseName $manual) { Add-Log "$manual korunan bir süreç; listeye eklenmedi." }
        else { [void]$newNames.Add($manual) }
    }
    $script:customCloseNames = $newNames
    $script:customNameBox.Clear()
    Save-CustomSettings
    Refresh-CustomList
    Refresh-ProcessGrid
}

# ---------------------------------------------------------------- game detection

function Register-DetectedGame {
    param([int]$Id, [long]$CreateTime, [string]$Name, [string]$Path)
    $script:detectedGames[$Id] = $CreateTime
    $script:gameWasDetected = $true
    $script:lastGameSeenUtc = [datetime]::UtcNow
    if (-not [GameBoostEngine]::TrySetPriority($Id, $CreateTime, 0x8000)) {
        Add-Log 'Oyun önceliği değiştirilemedi (anti-cheat koruması olabilir).'
    }
    if ($Path -and -not (Set-GameGpuPreference $Path)) { Add-Log 'Yüksek performanslı GPU tercihi kaydedilemedi.' }
    [void](Restore-EfficiencyTargets $Name)
    Set-CurrentGameFile $Id $Name
    Add-SessionGame $Id $Name
    $script:gameLabel.Text = "Oyun: $Name · öncelik verildi"
    Add-Log "Oyun algılandı: $Name"
}

function Detect-AndOptimizeGames {
    param($Snapshot)
    $alive = @{}
    if ($null -ne $Snapshot) {
        foreach ($game in (Find-RunningGames $Snapshot)) {
            $alive[$game.Id] = $true
            $script:lastGameSeenUtc = [datetime]::UtcNow
            if (-not $script:detectedGames.ContainsKey($game.Id)) {
                Register-DetectedGame $game.Id $game.CreateTime $game.Name $game.Path
            }
        }
    }
    foreach ($id in @($script:detectedGames.Keys)) {
        if ($alive.ContainsKey($id)) { continue }
        if ([GameBoostEngine]::IsAlive($id, [long]$script:detectedGames[$id])) { $script:lastGameSeenUtc = [datetime]::UtcNow }
        else {
            $script:detectedGames.Remove($id)
            if ($script:detectedGames.Count -eq 0) { Clear-CurrentGameFile }
        }
    }

    # Launchers hand off from a short-lived bootstrapper; wait before calling the game closed.
    if ($script:gameWasDetected -and $script:detectedGames.Count -eq 0 -and $script:options.AutoRestore -and
        ([datetime]::UtcNow - $script:lastGameSeenUtc).TotalSeconds -gt 12) {
        Restore-NormalMode 'Oyun kapandı; normal moda dönüldü.'
    }
}

# Games outside the known libraries (GOG, Battle.net, Riot, standalone) are recognized
# when they stay fullscreen in front for two checks in a row. They only get priority.
function Detect-FullscreenGame {
    if ($script:detectedGames.Count -gt 0 -or -not [GameBoostEngine]::IsForegroundFullscreen()) {
        $script:fullscreenCandidate = 0
        return
    }
    $foreground = [GameBoostEngine]::ForegroundProcessId()
    if ($foreground -le 0 -or $foreground -eq $PID) { return }
    try { $process = [Diagnostics.Process]::GetProcessById($foreground) } catch { return }
    $name = $process.ProcessName
    $path = [GameBoostEngine]::ProcessPath($foreground)
    if ((Test-ProtectedCloseName $name) -or $script:excludedNames.Contains($name) -or
        $script:nonGameFullscreenNames.Contains($name) -or $name -match $script:nonGamePattern -or
        $process.WorkingSet64 -lt 400MB -or -not $path -or $path -like "$env:SystemRoot\*") {
        $script:fullscreenCandidate = 0
        return
    }
    if ($script:fullscreenCandidate -ne $foreground) { $script:fullscreenCandidate = $foreground; return }
    Register-DetectedGame $foreground ([GameBoostEngine]::CreateTime($foreground)) $name $null
}

# ---------------------------------------------------------------- efficiency mode

function Add-EfficiencyTarget {
    param($Process)
    if ($script:efficiencyTargets.ContainsKey($Process.Key)) { return $false }
    $control = [uint32]0
    $state = [uint32]0
    $previous = [GameBoostEngine]::TryEnableEfficiency($Process.Id, $Process.CreateTime, [ref]$control, [ref]$state)
    if ($previous -eq 0) { return $false }
    $script:efficiencyTargets[$Process.Key] = [pscustomobject]@{
        Id = $Process.Id; CreateTime = $Process.CreateTime; Priority = $previous; Name = $Process.Name
        Control = $control; State = $state
    }
    return $true
}

function Restore-EfficiencyTargets {
    param([string]$Name)
    $restored = 0
    foreach ($key in @($script:efficiencyTargets.Keys)) {
        $target = $script:efficiencyTargets[$key]
        if ($Name -and $target.Name -ne $Name) { continue }
        [void][GameBoostEngine]::TryRestoreEfficiency($target.Id, [long]$target.CreateTime, [uint32]$target.Priority,
            [uint32]$target.Control, [uint32]$target.State)
        $script:efficiencyTargets.Remove($key)
        $restored++
    }
    if ($restored -gt 0 -and $script:boosted) { Save-RuntimeState }
    return $restored
}

function Enable-BackgroundEfficiency {
    param($Snapshot)
    $foreground = [GameBoostEngine]::ForegroundProcessId()
    $names = New-NameSet @()
    $count = 0
    foreach ($process in $Snapshot) {
        if (-not $script:efficiencyNames.Contains($process.Name)) { continue }
        if ($process.Id -eq $foreground -or $process.CreateTime -eq 0) { continue }
        if (Add-EfficiencyTarget $process) { $count++; [void]$names.Add($process.Name) }
    }
    if ($count -gt 0) {
        Add-Log "Verimlilik modu: $(@($names) -join ', ') ($count süreç)."
        Save-RuntimeState
    }
}

function Watch-Foreground {
    $foreground = [GameBoostEngine]::ForegroundProcessId()
    if ($foreground -le 0 -or $foreground -eq $script:lastForegroundPid) { return }
    $script:lastForegroundPid = $foreground
    try { $name = [Diagnostics.Process]::GetProcessById($foreground).ProcessName } catch { return }
    [void]$script:foregroundNames.Add($name)
    $restored = Restore-EfficiencyTargets $name
    if ($restored -gt 0) { Add-Log "$name öne geldi; verimlilik modu kaldırıldı." }
}

function Test-AutoEfficiencyCandidate {
    param($Process)
    if ($script:efficiencyTargets.ContainsKey($Process.Key)) { return $false }
    if ($Process.Id -eq [GameBoostEngine]::ForegroundProcessId()) { return $false }
    if ($script:foregroundNames.Contains($Process.Name)) { return $false }
    if ($script:excludedNames.Contains($Process.Name)) { return $false }
    if ($Process.Name -match $script:neverThrottlePattern) { return $false }
    $path = [string]$Process.Path
    if (-not $path -or [GameBoostEngine]::IsGameLibraryPath($path)) { return $false }
    if ($path -match $script:neverThrottlePathPattern) { return $false }
    return $true
}

function Set-ActivityNotice {
    param([string]$Text)
    if ($script:activityNoticeLabel) {
        $script:activityNoticeLabel.Text = $Text
        $script:activityNoticeLabel.ForeColor = $script:theme.Amber
    }
    if ($script:pages -and $script:pages.Contains('live')) { $script:pages['live'].Button.Text = 'Canlı İzleme  •' }
    Add-Log $Text
}

function Watch-BackgroundActivity {
    param($Snapshot)
    $busy = [GameBoostEngine]::SampleActivity($Snapshot, 5.0, 1200MB)
    $now = [datetime]::UtcNow
    $strikes = @{}
    $alerts = [Collections.Generic.List[object]]::new()
    foreach ($process in $busy) {
        if ($process.Id -eq $PID -or $script:detectedGames.ContainsKey($process.Id) -or
            $script:detectedGames.ContainsKey($process.ParentId)) { continue }
        if ($script:efficiencyTargets.ContainsKey($process.Key) -or (Test-ProtectedCloseName $process.Name)) { continue }
        # A busy background app twice in a row gets efficiency mode instead of a kill.
        if ($process.CpuPercent -ge 5 -and $script:options.EfficiencyMode -and (Test-AutoEfficiencyCandidate $process)) {
            $count = 1 + [int]$script:activityStrikes[$process.Key]
            $strikes[$process.Key] = $count
            if ($count -ge 2 -and (Add-EfficiencyTarget $process)) {
                Set-ActivityNotice "$($process.Name) arka planda CPU %$($process.CpuPercent) kullanıyordu; verimlilik moduna alındı."
                Save-RuntimeState
                continue
            }
        }
        if ($process.CpuPercent -ge 8 -or $process.WorkingSet -ge 1200MB) {
            $alerts.Add([pscustomobject]@{
                Name = $process.Name; CPU = $process.CpuPercent; RAM = [math]::Round($process.WorkingSet / 1MB)
                Returned = $false; Score = ($process.CpuPercent * 20) + ($process.WorkingSet / 1MB)
            })
        }
    }
    $script:activityStrikes = $strikes
    foreach ($process in $Snapshot) {
        if (Test-ExpectedClosedName $process.Name) {
            $alerts.Add([pscustomobject]@{ Name = $process.Name; CPU = 0; RAM = 0; Returned = $true; Score = 5000 })
            break
        }
    }

    $alert = $alerts | Sort-Object Score -Descending | Select-Object -First 1
    if (-not $alert) { return }
    $key = "$($alert.Name):$($alert.Returned)"
    $lastAlert = $script:activityLastAlert[$key]
    if ($lastAlert -and ($now - $lastAlert).TotalSeconds -lt 120) { return }
    $script:activityLastAlert[$key] = $now
    if ($alert.Returned) { Set-ActivityNotice "$($alert.Name) hâlâ açık veya yeniden açıldı; kendiliğinden kapatılmadı." }
    else { Set-ActivityNotice "$($alert.Name) yük oluşturuyor (CPU %$($alert.CPU), RAM $($alert.RAM) MB)." }
}

# ---------------------------------------------------------------- Windows startup

$script:runKeyPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$script:startupApprovedPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
$script:autoStartName = 'GameBoostLite'

function Get-AutoStartCommand {
    $mainScript = Join-Path $script:appRoot 'GameBoostLite.ps1'
    return "`"$env:SystemRoot\System32\conhost.exe`" --headless powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File `"$mainScript`" -Startup"
}

# Only this user's Run entry for GameBoost itself is written or removed.
function Set-AutoStart {
    param([bool]$Enabled)
    try {
        if ($Enabled) {
            New-ItemProperty -Path $script:runKeyPath -Name $script:autoStartName -Value (Get-AutoStartCommand) `
                -PropertyType String -Force -ErrorAction Stop | Out-Null
            # Switched off earlier in Task Manager: turning the toggle on means "on" there too.
            # (@() because PowerShell unrolls the returned byte array.)
            $state = @(Get-RegistryValue $script:startupApprovedPath $script:autoStartName)
            if ($state.Count -gt 0 -and $null -ne $state[0] -and ([int]$state[0] % 2) -eq 1) {
                Set-ItemProperty -Path $script:startupApprovedPath -Name $script:autoStartName `
                    -Value ([byte[]](2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) -ErrorAction Stop
            }
        } else {
            Remove-ItemProperty -Path $script:runKeyPath -Name $script:autoStartName -ErrorAction SilentlyContinue
        }
        return $true
    } catch { return $false }
}

# The registry is the truth; keep the entry pointing at this folder if it exists.
function Sync-AutoStartOption {
    $current = Get-RegistryValue $script:runKeyPath $script:autoStartName
    $script:options.AutoStart = $null -ne $current
    if ($current -and $current -ne (Get-AutoStartCommand)) { [void](Set-AutoStart $true) }
}

# ---------------------------------------------------------------- automatic BOOST

function Test-OnBattery {
    return [Windows.Forms.SystemInformation]::PowerStatus.PowerLineStatus -eq [Windows.Forms.PowerLineStatus]::Offline
}

function Find-RunningGames {
    param($Snapshot)
    return @([GameBoostEngine]::FindGames($Snapshot))
}

function Stop-AutoBoostGameBar {
    Get-Process -Name $script:gameBarNames -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}

function Update-AutoBoostWatcher {
    if (-not $script:autoBoostTimer) { return }
    if ($script:options.AutoBoost -and -not $script:boosted) { $script:autoBoostTimer.Start() }
    else {
        $script:autoBoostTimer.Stop()
        $script:autoBoostCandidate = $null
    }
}

# Every 5 s while automatic BOOST is on and BOOST is off: one process snapshot (~20-40 ms).
function Invoke-AutoBoostWatch {
    if ($script:boosted -or -not $script:options.AutoBoost) { return }
    $snapshot = [GameBoostEngine]::Snapshot()
    if ($script:autoBoostSuppressed.Count -gt 0) {
        $alive = [Collections.Generic.HashSet[string]]::new()
        foreach ($process in $snapshot) { [void]$alive.Add($process.Key) }
        foreach ($key in @($script:autoBoostSuppressed)) { if (-not $alive.Contains($key)) { [void]$script:autoBoostSuppressed.Remove($key) } }
    }
    $candidate = Find-RunningGames $snapshot | Where-Object { -not $script:autoBoostSuppressed.Contains($_.Key) } |
        Sort-Object WorkingSet -Descending | Select-Object -First 1
    if (-not $candidate) { $script:autoBoostCandidate = $null; return }
    # Seen twice in a row: launcher hand-offs and short-lived helpers do not start BOOST.
    if ($script:autoBoostCandidate -ne $candidate.Key) { $script:autoBoostCandidate = $candidate.Key; return }
    $script:autoBoostCandidate = $null
    Start-AutoBoost $candidate $snapshot
}

# No questions, no focus change, no app is closed (they may hold unsaved work or a call).
function Start-AutoBoost {
    param($Game, $Snapshot)
    if ($script:boosted) { return }
    Stop-SaverForBoost
    $script:boostMode = 'auto'
    $onBattery = Test-OnBattery
    $script:previousPowerScheme = Get-ActivePowerScheme
    if (-not $onBattery) { Set-PowerScheme $script:highPerformanceGuid }
    $script:efficiencyTargets = @{}
    Save-RuntimeState
    Enable-GameMode
    if ($script:options.CloseGameBar) { Stop-AutoBoostGameBar }
    Stop-InfaticaIfRunning
    Reset-BoostSession
    $script:boosted = $true
    Start-GameSession
    if ($script:options.EfficiencyMode) { Enable-BackgroundEfficiency $Snapshot }
    Update-BoostUi
    $power = if ($onBattery) { 'pilde olduğu için güç planı değiştirilmedi' } else { 'yüksek performans planı' }
    Add-Log "Otomatik BOOST: $($Game.Name) algılandı ($power). Hiçbir uygulama kapatılmadı."
    Detect-AndOptimizeGames $Snapshot
    if ($script:boosted) { $script:boostTimer.Start() }
    Update-AutoBoostWatcher
    if (-not $form.Visible) { [GameBoostEngine]::TrimCurrentProcess() }
}

function Reset-BoostSession {
    $script:gameWasDetected = $false
    $script:lastGameSeenUtc = [datetime]::MinValue
    $script:detectedGames = @{}
    $script:activityStrikes = @{}
    $script:activityLastAlert = @{}
    $script:foregroundNames.Clear()
    $script:lastForegroundPid = 0
    $script:fullscreenCandidate = 0
    $script:boostTick = 0
    [GameBoostEngine]::ResetActivity()
    if ($script:activityNoticeLabel) {
        $script:activityNoticeLabel.Text = 'Sessiz izleme açık; oyunun odağı bölünmez.'
        $script:activityNoticeLabel.ForeColor = $script:theme.SubText
    }
    if ($script:pages -and $script:pages.Contains('live')) { $script:pages['live'].Button.Text = 'Canlı İzleme' }
}

# ---------------------------------------------------------------- BOOST

function Get-BoostStatusText {
    if (-not $script:boosted) { return 'NORMAL MOD' }
    if ($script:boostMode -eq 'auto') { return 'OTOMATİK BOOST' }
    return 'BOOST AKTİF'
}

function Update-BoostUi {
    if ($script:boosted) {
        $script:statusLabel.Text = Get-BoostStatusText
        $script:statusLabel.ForeColor = $script:theme.Accent
        $script:boostButton.Enabled = $false
        $script:restoreButton.Enabled = $true
        if ($script:detectedGames.Count -eq 0) { $script:gameLabel.Text = 'Oyun: Steam / Epic / EA üzerinden açman bekleniyor' }
        $script:sidebarStatus.Text = "●  $(Get-BoostStatusText)"
        $script:sidebarStatus.ForeColor = $script:theme.Accent
    } else {
        $script:statusLabel.Text = 'NORMAL MOD'
        $script:statusLabel.ForeColor = $script:theme.Blue
        $script:boostButton.Enabled = $true
        $script:restoreButton.Enabled = $false
        $script:gameLabel.Text = 'Oyun: bekleniyor'
        $script:sidebarStatus.Text = '●  NORMAL MOD'
        $script:sidebarStatus.ForeColor = $script:theme.Blue
    }
    Update-OverlayHotkeys
    Update-ModesUi
    Update-Metrics
}

function Start-Boost {
    if ($script:boosted) { return }
    $snapshot = [GameBoostEngine]::Snapshot()
    $running = Get-RunningGroups $snapshot

    $graceful = [Collections.Generic.List[string]]::new()
    $forced = [Collections.Generic.List[string]]::new()
    if ($script:options.CloseWorkApps) { foreach ($name in $script:workAppNames) { $graceful.Add($name) } }
    foreach ($name in $script:customCloseNames) { if (-not (Test-ProtectedCloseName $name)) { $graceful.Add($name) } }
    if ($script:options.CloseGameBar) { foreach ($name in $script:gameBarNames) { $forced.Add($name) } }
    if ($script:options.CloseDiscord) { $forced.Add('Discord') }
    if ($script:options.CloseDocker) { foreach ($name in $script:dockerNames) { $forced.Add($name) } }
    $gracefulRunning = @($graceful | Where-Object { $running.ContainsKey($_) } | Sort-Object -Unique)
    $forcedRunning = @($forced | Where-Object { $running.ContainsKey($_) } | Sort-Object -Unique)
    $wslRunning = $script:options.CloseDocker -and ($running.ContainsKey('vmmemWSL') -or $running.ContainsKey('vmmem'))

    # With little free RAM, offer the largest windows that are safe to close.
    $memory = [GameBoostEngine]::MemoryGb()
    $suggested = @()
    if ($memory[0] -lt 4) {
        $suggested = @($running.Values | Where-Object {
            $_.HasWindow -and -not $_.IsGame -and $_.Bytes -ge 400MB -and
            $_.Name -notin $gracefulRunning -and $_.Name -notin $forcedRunning -and
            -not (Test-ProtectedCloseName $_.Name) -and $_.Name -notmatch $script:neverThrottlePattern
        } | Sort-Object Bytes -Descending | Select-Object -First 3)
    }
    $onBattery = Test-OnBattery

    $lines = [Collections.Generic.List[string]]::new()
    if ($onBattery) {
        $lines.Add('Şarj aleti takılı değil. Pilde işlemci ve ekran kartı güç sınırına takılır; oyun için şarja tak.')
        $lines.Add('')
    }
    if ($gracefulRunning.Count -gt 0) {
        $lines.Add('Nazikçe kapatılacak (kaydetmen istenebilir):')
        foreach ($name in $gracefulRunning) { $lines.Add("   •  $name   ($(Format-ByteSize $running[$name].Bytes))") }
    }
    if ($forcedRunning.Count -gt 0) { $lines.Add("Arka planda kapatılacak: $($forcedRunning -join ', ')") }
    if ($wslRunning) { $lines.Add('Docker / WSL durdurulacak; açık container ve WSL oturumları kapanır.') }
    $freed = [int64]0
    foreach ($name in @($gracefulRunning) + @($forcedRunning) + @('vmmemWSL', 'vmmem')) {
        if ($running.ContainsKey($name) -and ($name -notlike 'vmmem*' -or $wslRunning)) { $freed += $running[$name].Bytes }
    }
    if ($freed -gt 0) { $lines.Add(''); $lines.Add("Tahmini boşalacak RAM: ~$(Format-ByteSize $freed)") }
    if ($suggested.Count -gt 0) {
        $lines.Add('')
        $lines.Add(('Boş RAM az ({0:0.0} GB). En çok RAM kullanan pencereler:' -f $memory[0]))
        foreach ($item in $suggested) { $lines.Add("   •  $($item.Name)   ($(Format-ByteSize $item.Bytes))") }
        $lines.Add('')
        $lines.Add('Evet: bunları da nazikçe kapat     Hayır: yalnızca seçilileri kapat')
    }

    $includeSuggested = $false
    if ($suggested.Count -gt 0) {
        $answer = Show-UiMessage ($lines -join "`r`n") 'BOOST' 'YesNoCancel' 'Question'
        if ($answer -eq 'Cancel') { return }
        $includeSuggested = $answer -eq 'Yes'
    } elseif ($lines.Count -gt 0) {
        $lines.Add('')
        $lines.Add('BOOST başlatılsın mı?')
        if ((Show-UiMessage ($lines -join "`r`n") 'BOOST' 'YesNo' 'Question') -ne 'Yes') { return }
    }

    Stop-SaverForBoost
    $script:boostButton.Enabled = $false
    $form.UseWaitCursor = $true
    $freeBefore = $memory[0]
    try {
        $script:boostMode = 'manual'
        $script:previousPowerScheme = Get-ActivePowerScheme
        Set-PowerScheme $script:highPerformanceGuid
        $script:efficiencyTargets = @{}
        Save-RuntimeState
        Enable-GameMode

        $closing = @($gracefulRunning)
        if ($includeSuggested) { $closing += @($suggested | ForEach-Object Name) }
        Close-ProcessGroups $closing $forcedRunning
        if ($wslRunning) {
            [void](Start-HiddenProcess 'wsl.exe' '--shutdown')
            Add-Log 'Docker / WSL durduruluyor.'
        }
        Stop-InfaticaIfRunning

        Reset-BoostSession
        $script:boosted = $true
        Update-AutoBoostWatcher
        Start-GameSession

        $after = [GameBoostEngine]::Snapshot()
        if ($script:options.EfficiencyMode) { Enable-BackgroundEfficiency $after }
        Update-BoostUi
        Add-Log ('BOOST aktif. Boş RAM {0:0.0} → {1:0.0} GB. Launcher''lar korunuyor.' -f $freeBefore, [GameBoostEngine]::MemoryGb()[0])
        foreach ($monitor in [GameBoostDisplay]::GetMonitors()) {
            if ([math]::Round($monitor.Refresh) -le 30) {
                Set-ActivityNotice "$($monitor.Name) $([math]::Round($monitor.Refresh)) Hz'te çalışıyor; görüntü ağır akabilir."
            }
        }
        Detect-AndOptimizeGames $after
        if ($script:boosted) { $script:boostTimer.Start() }
    } finally { $form.UseWaitCursor = $false }

    if ($script:boosted -and $script:options.MinimizeOnBoost) { Hide-ToTray }
    [GameBoostEngine]::TrimCurrentProcess()
    Update-HomeAlerts
}

function Restore-NormalMode {
    param([string]$Reason, [switch]$Manual)
    if (-not $script:boosted) { return }
    # NORMAL MOD by hand: automatic BOOST leaves these game processes alone until they exit.
    if ($Manual) {
        foreach ($id in @($script:detectedGames.Keys)) { [void]$script:autoBoostSuppressed.Add("${id}:$($script:detectedGames[$id])") }
    }
    Complete-GameSession
    if ($script:previousPowerScheme) { Set-PowerScheme $script:previousPowerScheme }
    $restored = Restore-EfficiencyTargets
    Clear-RuntimeState
    Clear-CurrentGameFile
    if ($script:boostTimer) { $script:boostTimer.Stop() }
    $script:boosted = $false
    $script:detectedGames = @{}
    $script:activityStrikes = @{}
    $script:activityLastAlert = @{}
    $script:foregroundNames.Clear()
    $script:lastForegroundPid = 0
    $script:fullscreenCandidate = 0
    $script:boostMode = $null
    [GameBoostEngine]::ResetActivity()
    Update-BoostUi
    # F10 / Ctrl+F10 are released with BOOST; a persistent HUD would be left with no key to close it.
    Stop-ExternalOverlay
    if ($restored -gt 0) { Add-Log "$restored süreç normal hızına döndü." }
    Add-Log $Reason
    Update-AutoBoostWatcher
    if ($form.Visible) { Update-HomeAlerts }
}

# Every 3 s while BOOST is on. Full scans are rare once the game is running.
function Invoke-BoostTick {
    if (-not $script:boosted) { return }
    $script:boostTick++
    Watch-Foreground
    $fullScan = ($script:detectedGames.Count -eq 0) -or ($script:boostTick % 5 -eq 0)
    $sampleActivity = ($script:boostTick % 4 -eq 0)
    # Plain assignments only: an if-expression would unroll the List into an array.
    $snapshot = $null
    $scanSnapshot = $null
    if ($fullScan -or $sampleActivity) {
        $snapshot = [GameBoostEngine]::Snapshot()
        Stop-InfaticaIfRunning
    }
    if ($fullScan) { $scanSnapshot = $snapshot }
    Detect-AndOptimizeGames $scanSnapshot
    if ($script:boosted -and $script:detectedGames.Count -eq 0) { Detect-FullscreenGame }
    if ($script:boosted -and $sampleActivity) { Watch-BackgroundActivity $snapshot }
    if ($script:boosted) { Update-GameSession $scanSnapshot }
    if ($script:boosted -and $sampleActivity) { Update-SessionSystemWork }
}

# ---------------------------------------------------------------- HUD

function Test-PresentMonRights {
    try {
        $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) -or
            $principal.IsInRole([Security.Principal.SecurityIdentifier]::new('S-1-5-32-559'))
    } catch { return $false }
}

function Set-OverlayHotkeys {
    param([bool]$Enabled)
    if ($Enabled) {
        if (-not $script:f10Registered) { $script:f10Registered = [GameBoostHotkeyNative]::RegisterHotKey($form.Handle, 5101, 0x4000, 0x79) }
        if (-not $script:ctrlF10Registered) { $script:ctrlF10Registered = [GameBoostHotkeyNative]::RegisterHotKey($form.Handle, 5102, 0x4002, 0x79) }
        if (-not $script:f10Registered -or -not $script:ctrlF10Registered) {
            Add-Log 'HUD tuşlarından biri başka bir uygulama tarafından kullanılıyor.'
        }
    } else {
        if ($script:f10Registered) { [void][GameBoostHotkeyNative]::UnregisterHotKey($form.Handle, 5101); $script:f10Registered = $false }
        if ($script:ctrlF10Registered) { [void][GameBoostHotkeyNative]::UnregisterHotKey($form.Handle, 5102); $script:ctrlF10Registered = $false }
    }
}

# F10 is a system-wide key (Step Over, menu bar), so the HUD holds it only while BOOST runs.
function Update-OverlayHotkeys { Set-OverlayHotkeys ($script:overlayEnabled -and $script:boosted) }

function Invoke-OverlayCommand {
    param([ValidateSet('Show10', 'Toggle')][string]$Command)
    if (-not $script:overlayEnabled) { Add-Log 'HUD kapalı; FPS / HUD sayfasından aç.'; return }
    $overlayScript = Join-Path $script:appRoot 'GameBoostOverlay.ps1'
    if (-not (Test-Path -LiteralPath $overlayScript)) { Add-Log 'HUD betiği bulunamadı.'; return }
    $running = $false
    try {
        $mutex = [Threading.Mutex]::OpenExisting('Local\GameBoostOverlay.Display')
        $running = $true
        $mutex.Dispose()
    } catch { }
    New-Item -ItemType Directory -Path $script:settingsDirectory -Force | Out-Null
    if ($running) {
        if ($Command -eq 'Show10') {
            Set-Content -LiteralPath (Join-Path $script:settingsDirectory 'overlay-extend.txt') -Value 'extend' -Encoding ASCII
        } else {
            $modeFile = Join-Path $script:settingsDirectory 'overlay-mode.txt'
            $mode = if (Test-Path -LiteralPath $modeFile) { (Get-Content -LiteralPath $modeFile -Raw).Trim() } else { 'Timed' }
            $target = if ($mode -eq 'Persistent') { 'overlay-stop.txt' } else { 'overlay-persistent.txt' }
            Set-Content -LiteralPath (Join-Path $script:settingsDirectory $target) -Value 'x' -Encoding ASCII
        }
        return
    }
    $mode = if ($Command -eq 'Show10') { '-Mode Timed -Seconds 10' } else { '-Mode Persistent' }
    if (-not (Start-HiddenProcess 'powershell.exe' "-NoProfile -STA -ExecutionPolicy Bypass -File `"$overlayScript`" $mode")) {
        Add-Log 'HUD başlatılamadı.'
    }
}

function Stop-ExternalOverlay {
    try {
        New-Item -ItemType Directory -Path $script:settingsDirectory -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:settingsDirectory 'overlay-stop.txt') -Value 'stop' -Encoding ASCII
    } catch { }
}

# ---------------------------------------------------------------- storage and cleanup

function Format-ByteSize {
    param([int64]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:0.0} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:0} MB' -f ($Bytes / 1MB)) }
    return ('{0:0} KB' -f ($Bytes / 1KB))
}

function Get-FolderSizeBytes {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return [int64]0 }
    try {
        $total = [int64]0
        $pending = [Collections.Generic.Stack[string]]::new()
        $pending.Push([IO.Path]::GetFullPath($Path))
        while ($pending.Count -gt 0) {
            $directory = $pending.Pop()
            foreach ($item in Get-ChildItem -LiteralPath $directory -Force -ErrorAction SilentlyContinue) {
                if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                if ($item.PSIsContainer) { $pending.Push($item.FullName) } else { $total += [int64]$item.Length }
            }
        }
        return $total
    } catch { return [int64]0 }
}

function Get-LargeStorageCandidates {
    param([string[]]$Paths, [int64]$MinimumBytes = 500MB, [int]$Maximum = 6)
    $found = [Collections.Generic.List[object]]::new()
    foreach ($path in $Paths) {
        if (-not (Test-Path -LiteralPath $path)) { continue }
        try {
            $pending = [Collections.Generic.Stack[string]]::new()
            $pending.Push([IO.Path]::GetFullPath($path))
            while ($pending.Count -gt 0) {
                $directory = $pending.Pop()
                foreach ($item in Get-ChildItem -LiteralPath $directory -Force -ErrorAction SilentlyContinue) {
                    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                    if ($item.PSIsContainer) { $pending.Push($item.FullName) }
                    elseif ($item.Length -ge $MinimumBytes) { $found.Add([pscustomobject]@{ Path = $item.FullName; Bytes = [int64]$item.Length }) }
                }
            }
        } catch { }
    }
    return @($found | Sort-Object Bytes -Descending | Select-Object -First $Maximum)
}

# The only folders cleanup is ever allowed to touch.
function Get-SafeCleanupTargets {
    $wer = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\WER'
    return @(
        [pscustomobject]@{ Path = $env:TEMP; Days = 1 }
        [pscustomobject]@{ Path = (Join-Path $env:LOCALAPPDATA 'CrashDumps'); Days = 7 }
        [pscustomobject]@{ Path = (Join-Path $wer 'ReportArchive'); Days = 7 }
        [pscustomobject]@{ Path = (Join-Path $wer 'ReportQueue'); Days = 7 }
    )
}

function Remove-SafeOldFiles {
    param([string]$Path, [int]$OlderThanDays, [switch]$Preview)
    $result = [pscustomobject]@{ Files = 0; Bytes = [int64]0; Folders = 0 }
    if (-not (Test-Path -LiteralPath $Path)) { return $result }
    try {
        $root = [IO.Path]::GetFullPath($Path).TrimEnd('\')
        $allowed = @(Get-SafeCleanupTargets | ForEach-Object { [IO.Path]::GetFullPath($_.Path).TrimEnd('\') })
        if ($root -notin $allowed) { return $result }
        $cutoff = (Get-Date).AddDays(-[math]::Max(1, $OlderThanDays))
        $folderCutoff = (Get-Date).AddDays(-7)
        $directories = [Collections.Generic.List[string]]::new()
        $pending = [Collections.Generic.Stack[string]]::new()
        $pending.Push($root)
        while ($pending.Count -gt 0) {
            $directory = $pending.Pop()
            foreach ($item in Get-ChildItem -LiteralPath $directory -Force -ErrorAction SilentlyContinue) {
                if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                if ($item.PSIsContainer) {
                    $pending.Push($item.FullName)
                    $directories.Add($item.FullName)
                } elseif ($item.LastWriteTime -lt $cutoff) {
                    $length = [int64]$item.Length
                    if ($Preview) { $result.Files++; $result.Bytes += $length; continue }
                    try {
                        Remove-Item -LiteralPath $item.FullName -Force -ErrorAction Stop
                        $result.Files++
                        $result.Bytes += $length
                    } catch { }
                }
            }
        }
        if (-not $Preview) {
            # Deepest first; only folders that are empty and untouched for a week.
            foreach ($directory in ($directories | Sort-Object Length -Descending)) {
                try {
                    $info = [IO.DirectoryInfo]::new($directory)
                    if ($info.CreationTime -lt $folderCutoff -and $info.LastWriteTime -lt $folderCutoff -and
                        -not ([IO.Directory]::EnumerateFileSystemEntries($directory) | Select-Object -First 1)) {
                        $info.Delete()
                        $result.Folders++
                    }
                } catch { }
            }
        }
    } catch { }
    return $result
}

function Invoke-SafeMaintenanceCleanup {
    $script:maintenanceCleanButton.Enabled = $false
    $form.UseWaitCursor = $true
    try {
        $files = 0; $bytes = [int64]0
        foreach ($target in Get-SafeCleanupTargets) {
            $preview = Remove-SafeOldFiles $target.Path $target.Days -Preview
            $files += $preview.Files
            $bytes += $preview.Bytes
        }
        $leftovers = @(Get-ChildItem -LiteralPath $script:settingsDirectory -Filter 'presentmon-*.csv' -File -ErrorAction SilentlyContinue)
        if ($files + $leftovers.Count -eq 0) {
            [void](Show-UiMessage 'Temizlenecek eski geçici dosya bulunmadı.')
            return
        }
        $message = "$files eski dosya ($(Format-ByteSize $bytes)) silinecek:`r`n`r`n" +
            "   •  24 saatten eski kullanıcı Temp dosyaları`r`n" +
            "   •  7 günden eski çökme dökümleri ve hata raporları`r`n" +
            "   •  Bir haftadır boş duran Temp klasörleri`r`n`r`n" +
            "Kullanımdaki dosyalar atlanır. Shader önbelleği, tarayıcı ve kişisel dosyalara dokunulmaz.`r`n`r`nDevam edilsin mi?"
        if ((Show-UiMessage $message 'Güvenli temizlik' 'YesNo' 'Question') -ne 'Yes') { return }
        $files = 0; $bytes = [int64]0; $folders = 0
        foreach ($target in Get-SafeCleanupTargets) {
            $done = Remove-SafeOldFiles $target.Path $target.Days
            $files += $done.Files
            $bytes += $done.Bytes
            $folders += $done.Folders
        }
        $leftovers | Remove-Item -Force -ErrorAction SilentlyContinue
        $summary = "GÜVENLİ TEMİZLİK TAMAMLANDI`r`n$files dosya ve $folders boş klasör silindi, $(Format-ByteSize $bytes) yer açıldı.`r`n`r`n"
        $script:maintenanceBox.Text = $summary + $script:maintenanceBox.Text
        Add-Log "Güvenli temizlik: $files dosya, $(Format-ByteSize $bytes)."
    } finally {
        $script:maintenanceCleanButton.Enabled = $true
        $form.UseWaitCursor = $false
    }
}

function Clear-UserRecycleBin {
    try { $count = (New-Object -ComObject Shell.Application).NameSpace(10).Items().Count } catch { $count = -1 }
    if ($count -eq 0) { [void](Show-UiMessage 'Geri Dönüşüm Kutusu zaten boş.'); return }
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $bytes = [int64]0
    foreach ($drive in [IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady }) {
        $bytes += Get-FolderSizeBytes (Join-Path $drive.RootDirectory.FullName ('$Recycle.Bin\' + $sid))
    }
    $what = if ($count -gt 0) { "$count öğe, $(Format-ByteSize $bytes)" } else { Format-ByteSize $bytes }
    $message = "Geri Dönüşüm Kutusu boşaltılacak ($what).`r`nBu dosyalar geri getirilemez. Devam edilsin mi?"
    if ((Show-UiMessage $message 'Geri Dönüşüm Kutusu' 'YesNo' 'Warning') -ne 'Yes') { return }
    Clear-RecycleBin -Force -ErrorAction SilentlyContinue
    Add-Log "Geri Dönüşüm Kutusu boşaltıldı ($what)."
}

function Update-MaintenanceRecommendations {
    if ($null -eq $script:maintenanceBox) { return }
    $script:maintenanceScanButton.Enabled = $false
    $form.UseWaitCursor = $true
    $script:maintenanceBox.Text = 'Analiz ediliyor...'
    [Windows.Forms.Application]::DoEvents()
    try {
        $cachePaths = [ordered]@{
            'Kullanıcı Temp' = $env:TEMP
            'Çökme dökümleri' = (Join-Path $env:LOCALAPPDATA 'CrashDumps')
            'NVIDIA DXCache' = (Join-Path $env:LOCALAPPDATA 'NVIDIA\DXCache')
            'NVIDIA GLCache' = (Join-Path $env:LOCALAPPDATA 'NVIDIA\GLCache')
            'DirectX shader önbelleği' = (Join-Path $env:LOCALAPPDATA 'D3DSCache')
            'Chrome önbelleği' = (Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data\Default\Cache\Cache_Data')
            'Edge önbelleği' = (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data\Default\Cache\Cache_Data')
        }
        $cacheSizes = [ordered]@{}
        foreach ($item in $cachePaths.GetEnumerator()) {
            $script:maintenanceBox.Text = "Analiz ediliyor: $($item.Key)..."
            [Windows.Forms.Application]::DoEvents()
            $cacheSizes[$item.Key] = Get-FolderSizeBytes $item.Value
        }

        $profile = [Environment]::GetFolderPath('UserProfile')
        $desktop = [Environment]::GetFolderPath('Desktop')
        $documents = [Environment]::GetFolderPath('MyDocuments')
        $videos = [Environment]::GetFolderPath('MyVideos')
        $downloads = Join-Path $profile 'Downloads'
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $systemDrive = [IO.Path]::GetPathRoot($env:SystemRoot)
        $storagePaths = [ordered]@{
            'İndirilenler' = $downloads
            'Masaüstü' = $desktop
            'Belgeler' = $documents
            'Videolar' = $videos
            'Geri Dönüşüm Kutusu (C:)' = (Join-Path $systemDrive ('$Recycle.Bin\' + $sid))
            'Windows Update indirmeleri' = (Join-Path $env:SystemRoot 'SoftwareDistribution\Download')
            'NVIDIA kurulum dosyaları' = (Join-Path $env:ProgramData 'NVIDIA Corporation\Downloader')
        }
        $storageSizes = [ordered]@{}
        foreach ($item in $storagePaths.GetEnumerator()) {
            $script:maintenanceBox.Text = "Depolama analiz ediliyor: $($item.Key)..."
            [Windows.Forms.Application]::DoEvents()
            $storageSizes[$item.Key] = Get-FolderSizeBytes $item.Value
        }
        $largeFiles = Get-LargeStorageCandidates @($downloads, $desktop, $documents, $videos)
        $drives = @([IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady })

        $lines = [Collections.Generic.List[string]]::new()
        $lines.Add('SÜRÜCÜLER')
        foreach ($drive in $drives) {
            $used = [int64]($drive.TotalSize - $drive.AvailableFreeSpace)
            $freePercent = if ($drive.TotalSize -gt 0) { [math]::Round(($drive.AvailableFreeSpace / $drive.TotalSize) * 100) } else { 0 }
            $lines.Add(('  {0,-4} {1,10} / {2,-10} boş %{3}' -f $drive.Name, (Format-ByteSize $used), (Format-ByteSize $drive.TotalSize), $freePercent))
        }
        $lines.Add('')
        $lines.Add('KİŞİSEL KLASÖRLER')
        foreach ($name in $storageSizes.Keys) { $lines.Add(('  {0,-28} {1}' -f $name, (Format-ByteSize $storageSizes[$name]))) }
        $lines.Add('')
        $lines.Add('ÖNBELLEK VE GEÇİCİ DOSYALAR')
        foreach ($name in $cacheSizes.Keys) { $lines.Add(('  {0,-28} {1}' -f $name, (Format-ByteSize $cacheSizes[$name]))) }
        $lines.Add('')
        $lines.Add('500 MB ÜSTÜ KİŞİSEL DOSYALAR')
        if ($largeFiles.Count -eq 0) { $lines.Add('  Aday bulunmadı.') }
        foreach ($file in $largeFiles) { $lines.Add(('  {0,8}  {1}' -f (Format-ByteSize $file.Bytes), $file.Path)) }
        $lines.Add('')
        $lines.Add('ÖNERİLER')
        if ($cacheSizes['Kullanıcı Temp'] -gt 1GB) { $lines.Add('  • Temp büyük: Güvenli Temizle kullanılabilir.') }
        if ($cacheSizes['Çökme dökümleri'] -gt 256MB) { $lines.Add('  • Çökme dökümleri büyük; Güvenli Temizle 7 günden eskileri siler.') }
        if (($cacheSizes['Chrome önbelleği'] + $cacheSizes['Edge önbelleği']) -gt 2GB) { $lines.Add('  • Tarayıcı önbelleği büyük; tarayıcı ayarlarından temizlenebilir.') }
        if ($storageSizes['İndirilenler'] -gt 10GB) { $lines.Add('  • İndirilenler 10 GB üstünde; büyük dosyaları elle kontrol et.') }
        if ($storageSizes['Geri Dönüşüm Kutusu (C:)'] -gt 2GB) { $lines.Add('  • Geri Dönüşüm Kutusu 2 GB üstünde.') }
        if ($storageSizes['Windows Update indirmeleri'] -gt 2GB) { $lines.Add('  • Windows Update artıkları büyük; Windows Depolama ile temizle.') }
        $shaderTotal = $cacheSizes['NVIDIA DXCache'] + $cacheSizes['NVIDIA GLCache'] + $cacheSizes['DirectX shader önbelleği']
        if ($shaderTotal -gt 2GB) { $lines.Add('  • Shader önbelleği büyük; yalnızca grafik hatası varsa temizle.') }
        $lines.Add('  • Shader önbelleğini oyun öncesi silme: ilk açılışta takılma yapar.')
        $lines.Add('  • Pagefile, SysMain ve bellek sıkıştırma açık kalmalı.')
        $lines.Add('  • RAM "temizleyici" araçlar oyunu hızlandırmaz; veriyi diske itip takılma yaratır.')
        $script:maintenanceBox.Text = ($lines -join "`r`n")
    } catch {
        $script:maintenanceBox.Text = 'Analiz tamamlanamadı; sistemde değişiklik yapılmadı.'
    } finally {
        $script:maintenanceScanButton.Enabled = $true
        $form.UseWaitCursor = $false
    }
}
