$ErrorActionPreference = 'Stop'
$backupKey = 'HKCU:\Software\GameBoostLite\GamingBackup'
$gameBarKey = 'HKCU:\Software\Microsoft\GameBar'
$configKey = 'HKCU:\System\GameConfigStore'
$captureKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR'

New-Item -Path $backupKey -Force | Out-Null

function Backup-RegistryValue {
    param([string]$Path, [string]$Name, [string]$BackupName)
    $existingBackup = Get-ItemProperty -Path $backupKey -ErrorAction SilentlyContinue
    if ($existingBackup -and $existingBackup.PSObject.Properties['Has_' + $BackupName]) {
        return
    }
    $item = Get-ItemProperty -Path $Path -ErrorAction SilentlyContinue
    $property = if ($item) { $item.PSObject.Properties[$Name] } else { $null }
    New-ItemProperty -Path $backupKey -Name ("Has_" + $BackupName) `
        -Value ([int]($null -ne $property)) -PropertyType DWord -Force | Out-Null
    if ($null -ne $property) {
        New-ItemProperty -Path $backupKey -Name $BackupName -Value ([int]$property.Value) `
            -PropertyType DWord -Force | Out-Null
    }
}

New-Item -Path $gameBarKey -Force | Out-Null
New-Item -Path $configKey -Force | Out-Null
New-Item -Path $captureKey -Force | Out-Null

Backup-RegistryValue $gameBarKey 'AutoGameModeEnabled' 'AutoGameModeEnabled'
Backup-RegistryValue $gameBarKey 'AllowAutoGameMode' 'AllowAutoGameMode'
Backup-RegistryValue $configKey 'GameDVR_Enabled' 'GameDVR_Enabled'
Backup-RegistryValue $captureKey 'AppCaptureEnabled' 'AppCaptureEnabled'

if (-not (Get-ItemProperty -Path $backupKey -Name '_BackupCreated' -ErrorAction SilentlyContinue)) {
    New-ItemProperty -Path $backupKey -Name '_BackupCreated' -Value (Get-Date).ToString('o') `
        -PropertyType String -Force | Out-Null
}

New-ItemProperty -Path $gameBarKey -Name 'AutoGameModeEnabled' -Value 1 -PropertyType DWord -Force | Out-Null
New-ItemProperty -Path $gameBarKey -Name 'AllowAutoGameMode' -Value 1 -PropertyType DWord -Force | Out-Null
New-ItemProperty -Path $configKey -Name 'GameDVR_Enabled' -Value 0 -PropertyType DWord -Force | Out-Null
New-ItemProperty -Path $captureKey -Name 'AppCaptureEnabled' -Value 0 -PropertyType DWord -Force | Out-Null

Write-Output 'Windows Game Mode enabled.'
Write-Output 'Background Game DVR capture disabled.'
