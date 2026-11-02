# Recommended Windows settings for gaming. Only per-user settings with a clear on/off are offered.
# Before the first change of a setting its original value is saved; switching it off puts that
# value back (or the Windows default when nothing was saved).

$script:tweakBackupFile = Join-Path $script:settingsDirectory 'windows-settings-backup.json'
$script:gpuPreferencesPath = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
$script:gpuPreferencesSubkey = 'Software\Microsoft\DirectX\UserGpuPreferences'

$script:windowsTweaks = @(
    [pscustomobject]@{
        Key = 'GameMode'; Kind = 'registry'; Label = 'Windows Oyun Modu'
        Help = 'Oyun açıkken Windows arka plan işlerini ve güncelleme kurulumlarını geri çeker.'
        Values = @([pscustomobject]@{ Path = 'HKCU:\Software\Microsoft\GameBar'; Name = 'AutoGameModeEnabled'; Type = 'DWord'; On = 1; Off = 0 })
    }
    [pscustomobject]@{
        Key = 'NoGameDvr'; Kind = 'registry'; Label = 'Arka plan oyun kaydını kapat'
        Help = 'Game DVR son dakikaları sürekli kaydeder; kapatınca FPS ve disk yükü azalır.'
        Values = @(
            [pscustomobject]@{ Path = 'HKCU:\System\GameConfigStore'; Name = 'GameDVR_Enabled'; Type = 'DWord'; On = 0; Off = 1 },
            [pscustomobject]@{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR'; Name = 'AppCaptureEnabled'; Type = 'DWord'; On = 0; Off = 1 })
    }
    [pscustomobject]@{
        Key = 'NoDucking'; Kind = 'registry'; Label = 'Sesli sohbette oyun sesi kısılmasın'
        Help = 'Windows, Discord/Teams görüşmesi başlayınca diğer sesleri varsayılan olarak %80 kısar.'
        Values = @([pscustomobject]@{ Path = 'HKCU:\Software\Microsoft\Multimedia\Audio'; Name = 'UserDuckingPreference'; Type = 'DWord'; On = 3; Off = 1 })
    }
    [pscustomobject]@{
        Key = 'NoMouseAccel'; Kind = 'mouse'; Label = 'Fare hızlandırmasını kapat'
        Help = '"İşaretçi hassasiyetini artır" kapanır: fare, hareket hızından bağımsız aynı mesafeyi gider; nişan tutarlı olur.'
    }
    [pscustomobject]@{
        Key = 'NoStickyKeys'; Kind = 'sticky'; Label = 'Shift×5 Yapışkan Tuşlar penceresini kapat'
        Help = 'Oyunda Shift''e art arda basınca açılıp oyundan atan pencere gelmez. Yapışkan Tuşlar özelliği yine kullanılabilir.'
    }
    [pscustomobject]@{
        Key = 'WindowedOptimizations'; Kind = 'swapeffect'; Label = 'Pencereli oyunlar için iyileştirmeler'
        Help = 'Kenarlıksız pencere modundaki DirectX 10/11 oyunlarında gecikmeyi azaltır (Windows 11 ayarı).'
    }
)

# Small seams so the logic can be checked without touching the real mouse or keyboard settings.
function Get-MouseSetting { return @([GameBoostInputSettings]::GetMouse()) }
function Set-MouseSetting { param([int[]]$Values) return [GameBoostInputSettings]::SetMouse($Values[0], $Values[1], $Values[2]) }
function Get-StickyFlags { return [GameBoostInputSettings]::GetStickyFlags() }
function Set-StickyFlags { param([int]$Flags) return [GameBoostInputSettings]::SetStickyFlags($Flags) }

function Get-TweakRegistry {
    param([string]$Path, [string]$Name)
    try { return (Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop).$Name } catch { return $null }
}

function Set-TweakRegistry {
    param([string]$Path, [string]$Name, [string]$Type, $Data)
    if ($null -eq $Data) { Remove-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue; return }
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force -ErrorAction Stop | Out-Null }
    New-ItemProperty -LiteralPath $Path -Name $Name -Value $Data -PropertyType $Type -Force -ErrorAction Stop | Out-Null
}

# "SwapEffectUpgradeEnable=1;VRROptimizeEnable=0;" <-> ordered map, other entries kept as they are.
function Get-DirectXGlobalMap {
    $map = [ordered]@{}
    $text = [string](Get-TweakRegistry $script:gpuPreferencesPath 'DirectXUserGlobalSettings')
    foreach ($part in $text.Split(';')) {
        if ($part -match '^\s*([^=]+)=(.*)$') { $map[$Matches[1].Trim()] = $Matches[2].Trim() }
    }
    return $map
}

function Set-DirectXGlobalMap {
    param($Map)
    $text = (@($Map.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ';')
    if ($text) { $text += ';' } else { $text = $null }
    Set-TweakRegistry $script:gpuPreferencesPath 'DirectXUserGlobalSettings' 'String' $text
}

function Test-TweakOn {
    param($Tweak)
    switch ($Tweak.Kind) {
        'registry' {
            foreach ($value in $Tweak.Values) {
                if ([string](Get-TweakRegistry $value.Path $value.Name) -ne [string]$value.On) { return $false }
            }
            return $true
        }
        'mouse' { $mouse = @(Get-MouseSetting); return $mouse.Count -eq 3 -and $mouse[2] -eq 0 }
        'sticky' { $flags = Get-StickyFlags; return $flags -ge 0 -and ($flags -band 4) -eq 0 }
        'swapeffect' { return (Get-DirectXGlobalMap)['SwapEffectUpgradeEnable'] -eq '1' }
    }
    return $false
}

# ---------------------------------------------------------------- backup file

function Read-TweakBackup {
    $backup = @{}
    if (-not (Test-Path -LiteralPath $script:tweakBackupFile)) { return $backup }
    try {
        $data = Get-Content -LiteralPath $script:tweakBackupFile -Raw | ConvertFrom-Json
        foreach ($property in $data.PSObject.Properties) { $backup[$property.Name] = $property.Value }
    } catch { }
    return $backup
}

function Write-TweakBackup {
    param($Backup)
    New-Item -ItemType Directory -Path $script:settingsDirectory -Force | Out-Null
    if ($Backup.Count -eq 0) { Remove-Item -LiteralPath $script:tweakBackupFile -Force -ErrorAction SilentlyContinue; return }
    $temp = "$($script:tweakBackupFile).tmp"
    ConvertTo-Json -InputObject $Backup -Depth 5 | Set-Content -LiteralPath $temp -Encoding UTF8
    Move-Item -LiteralPath $temp -Destination $script:tweakBackupFile -Force
}

function Get-TweakOriginal {
    param($Tweak)
    switch ($Tweak.Kind) {
        'registry' { return [ordered]@{ Values = @($Tweak.Values | ForEach-Object { [ordered]@{ Name = $_.Name; Data = (Get-TweakRegistry $_.Path $_.Name) } }) } }
        'mouse' { return [ordered]@{ Mouse = @(Get-MouseSetting) } }
        'sticky' { return [ordered]@{ Flags = (Get-StickyFlags) } }
        'swapeffect' { return [ordered]@{ Data = (Get-TweakRegistry $script:gpuPreferencesPath 'DirectXUserGlobalSettings') } }
    }
}

# ---------------------------------------------------------------- switch on / back

function Enable-Tweak {
    param($Tweak)
    try {
        $backup = Read-TweakBackup
        if (-not $backup.ContainsKey($Tweak.Key)) {
            $backup[$Tweak.Key] = Get-TweakOriginal $Tweak
            Write-TweakBackup $backup
        }
        switch ($Tweak.Kind) {
            'registry' { foreach ($value in $Tweak.Values) { Set-TweakRegistry $value.Path $value.Name $value.Type $value.On } }
            'mouse' { if (-not (Set-MouseSetting @(0, 0, 0))) { return $false } }
            'sticky' {
                $flags = Get-StickyFlags
                if ($flags -lt 0 -or -not (Set-StickyFlags ($flags -band (-bnot 4)))) { return $false }
            }
            'swapeffect' { $map = Get-DirectXGlobalMap; $map['SwapEffectUpgradeEnable'] = '1'; Set-DirectXGlobalMap $map }
        }
        return Test-TweakOn $Tweak
    } catch { return $false }
}

function Restore-Tweak {
    param($Tweak)
    try {
        $backup = Read-TweakBackup
        $saved = $backup[$Tweak.Key]
        switch ($Tweak.Kind) {
            'registry' {
                foreach ($value in $Tweak.Values) {
                    $original = if ($saved) { @($saved.Values | Where-Object Name -eq $value.Name)[0] } else { $null }
                    $data = if ($saved) { $original.Data } else { $value.Off }
                    Set-TweakRegistry $value.Path $value.Name $value.Type $data
                }
            }
            'mouse' {
                $values = if ($saved -and @($saved.Mouse).Count -eq 3) { [int[]]@($saved.Mouse) } else { [int[]]@(6, 10, 1) }
                if (-not (Set-MouseSetting $values)) { return $false }
            }
            'sticky' {
                $flags = if ($saved -and $saved.Flags -ge 0) { [int]$saved.Flags } else { (Get-StickyFlags) -bor 4 }
                if (-not (Set-StickyFlags $flags)) { return $false }
            }
            'swapeffect' {
                if ($saved) { Set-TweakRegistry $script:gpuPreferencesPath 'DirectXUserGlobalSettings' 'String' $saved.Data }
                else { $map = Get-DirectXGlobalMap; $map.Remove('SwapEffectUpgradeEnable'); Set-DirectXGlobalMap $map }
            }
        }
        if ($backup.ContainsKey($Tweak.Key)) { $backup.Remove($Tweak.Key); Write-TweakBackup $backup }
        return $true
    } catch { return $false }
}

# ---------------------------------------------------------------- GPU preference of detected games

# BOOST asks Windows to run a detected game on the high performance GPU. A choice already made for
# that game is left alone; the games BOOST set are listed in the backup so they can be put back.
# The registry is used directly: game paths may contain [ ], which -Name treats as wildcards.
function Set-GameGpuPreference {
    param([string]$Path)
    try {
        $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($script:gpuPreferencesSubkey)
        try {
            if ($null -ne $key.GetValue($Path)) { return $true }
            $backup = Read-TweakBackup
            $backup['GameGpuPaths'] = @(@($backup['GameGpuPaths']) + $Path | Where-Object { $_ } | Sort-Object -Unique)
            Write-TweakBackup $backup
            $key.SetValue($Path, 'GpuPreference=2;', [Microsoft.Win32.RegistryValueKind]::String)
            return $true
        } finally { $key.Dispose() }
    } catch { return $false }
}

# Removes the preferences BOOST added, except the ones the user has changed since.
function Restore-GameGpuPreferences {
    $backup = Read-TweakBackup
    if (-not $backup.ContainsKey('GameGpuPaths')) { return 0 }
    $removed = 0
    try {
        $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($script:gpuPreferencesSubkey, $true)
        if ($key) {
            try {
                foreach ($path in @($backup['GameGpuPaths'])) {
                    if ([string]$key.GetValue($path) -eq 'GpuPreference=2;') { $key.DeleteValue($path, $false); $removed++ }
                }
            } finally { $key.Dispose() }
        }
        $backup.Remove('GameGpuPaths')
        Write-TweakBackup $backup
    } catch { }
    return $removed
}

# ---------------------------------------------------------------- noise suppression helpers on this PC

function Get-MicToolsInfo {
    $broadcast = @("$env:ProgramFiles\NVIDIA Corporation\NVIDIA Broadcast\NVIDIA Broadcast UI.exe") | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    $steelSeries = @("$env:ProgramFiles\SteelSeries\GG\SteelSeriesGG.exe") | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    $rtx = @([GameBoostGpuInfo]::Adapters() | Where-Object { $_.Name -match 'RTX' }) | Select-Object -First 1
    return [pscustomobject]@{
        BroadcastPath = $broadcast; SteelSeriesPath = $steelSeries
        RtxName = if ($rtx) { $rtx.Name -replace 'NVIDIA GeForce ', '' } else { $null }
        DiscordInstalled = Test-Path -LiteralPath (Join-Path $env:LOCALAPPDATA 'Discord')
    }
}
