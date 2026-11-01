$ErrorActionPreference = 'Stop'
$backupKey = 'HKCU:\Software\GameBoostLite\GamingBackup'

if (-not (Test-Path $backupKey)) {
    Write-Output 'No GameBoost Lite gaming backup was found.'
    exit 0
}

$backup = Get-ItemProperty $backupKey

function Restore-RegistryValue {
    param([string]$Path, [string]$Name, [string]$BackupName)
    New-Item -Path $Path -Force | Out-Null
    $hasName = 'Has_' + $BackupName
    if ([int]$backup.$hasName -eq 1) {
        New-ItemProperty -Path $Path -Name $Name -Value ([int]$backup.$BackupName) `
            -PropertyType DWord -Force | Out-Null
    } else {
        Remove-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
    }
}

Restore-RegistryValue 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled' 'AutoGameModeEnabled'
Restore-RegistryValue 'HKCU:\Software\Microsoft\GameBar' 'AllowAutoGameMode' 'AllowAutoGameMode'
Restore-RegistryValue 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 'GameDVR_Enabled'
Restore-RegistryValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 'AppCaptureEnabled'

Remove-Item -Path $backupKey -Recurse -Force
Write-Output 'Previous Windows gaming settings restored.'
