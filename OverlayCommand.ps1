param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Show10', 'Toggle')]
    [string]$Command
)

$ErrorActionPreference = 'SilentlyContinue'
$stateDirectory = Join-Path $env:LOCALAPPDATA 'GameBoostLite'
$settingsFile = Join-Path $stateDirectory 'settings.json'
$stopFile = Join-Path $stateDirectory 'overlay-stop.txt'
$extendFile = Join-Path $stateDirectory 'overlay-extend.txt'
$persistentFile = Join-Path $stateDirectory 'overlay-persistent.txt'
$modeFile = Join-Path $stateDirectory 'overlay-mode.txt'
$overlayScript = Join-Path $PSScriptRoot 'GameBoostOverlay.ps1'
New-Item -ItemType Directory -Path $stateDirectory -Force | Out-Null

$enabled = $false
$prompted = $false
if (Test-Path $settingsFile) {
    try {
        $settings = Get-Content $settingsFile -Raw | ConvertFrom-Json
        $enabled = [bool]$settings.OverlayEnabled
        $prompted = [bool]$settings.OverlayPrompted
    } catch { }
}

if (-not $enabled) {
    if (-not $prompted) {
        $shortcut = Join-Path ([Environment]::GetFolderPath('Desktop')) 'GameBoost Lite.lnk'
        if (Test-Path -LiteralPath $shortcut) { Start-Process -FilePath $shortcut }
    }
    exit
}

$overlayRunning = $false
try {
    $mutex = [System.Threading.Mutex]::OpenExisting('Local\GameBoostOverlay.Display')
    $overlayRunning = $true
    $mutex.Dispose()
} catch { }

if ($Command -eq 'Show10') {
    if ($overlayRunning) {
        Set-Content -LiteralPath $extendFile -Value 'extend' -Encoding ASCII
    } else {
        Start-Process powershell.exe -ArgumentList @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',$overlayScript,'-Mode','Timed','-Seconds','10')
    }
} elseif ($Command -eq 'Toggle') {
    if ($overlayRunning) {
        $currentMode = if (Test-Path -LiteralPath $modeFile) {
            (Get-Content -LiteralPath $modeFile -Raw).Trim()
        } else { 'Timed' }
        if ($currentMode -eq 'Persistent') {
            Set-Content -LiteralPath $stopFile -Value 'stop' -Encoding ASCII
        } else {
            Set-Content -LiteralPath $persistentFile -Value 'persistent' -Encoding ASCII
        }
    } else {
        Start-Process powershell.exe -ArgumentList @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',$overlayScript,'-Mode','Persistent')
    }
}
