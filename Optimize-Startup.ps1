$ErrorActionPreference = 'Stop'
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$backupKey = 'HKCU:\Software\GameBoostLite\StartupBackup'
$approvedKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
$approvedBackupKey = Join-Path $backupKey 'StartupApprovedRun'

$exactNames = @(
    'Steam',
    'EADM',
    'DAEMON Tools Lite Automount',
    'Docker Desktop',
    'Teams',
    'Discord',
    'EpicGamesLauncher'
)

New-Item -Path $backupKey -Force | Out-Null
New-Item -Path $approvedBackupKey -Force | Out-Null

function Backup-StartupApprovedValue {
    param([string]$Name)
    $hasName = 'Has_' + $Name
    $dataName = 'Data_' + $Name
    $existingBackup = Get-ItemProperty -Path $approvedBackupKey -ErrorAction SilentlyContinue
    if ($existingBackup -and $existingBackup.PSObject.Properties[$hasName]) { return }
    $approved = Get-ItemProperty -Path $approvedKey -ErrorAction SilentlyContinue
    $property = if ($approved) { $approved.PSObject.Properties[$Name] } else { $null }
    New-ItemProperty -Path $approvedBackupKey -Name $hasName -Value ([int]($null -ne $property)) `
        -PropertyType DWord -Force | Out-Null
    if ($property) {
        New-ItemProperty -Path $approvedBackupKey -Name $dataName -Value ([byte[]]$property.Value) `
            -PropertyType Binary -Force | Out-Null
    }
}

$runValues = Get-ItemProperty -Path $runKey
$names = @($exactNames)
$names += $runValues.PSObject.Properties.Name | Where-Object {
    $_ -like 'MicrosoftEdgeAutoLaunch_*'
}

foreach ($name in ($names | Select-Object -Unique)) {
    $property = $runValues.PSObject.Properties[$name]
    if ($null -eq $property) { continue }
    $existingBackup = Get-ItemProperty -Path $backupKey -ErrorAction SilentlyContinue
    if (-not $existingBackup.PSObject.Properties[$name]) {
        New-ItemProperty -Path $backupKey -Name $name -Value ([string]$property.Value) `
            -PropertyType String -Force | Out-Null
        Backup-StartupApprovedValue $name
    }
    Remove-ItemProperty -Path $runKey -Name $name -ErrorAction SilentlyContinue
    Write-Output "Disabled startup: $name"
}

if (-not (Get-ItemProperty -Path $backupKey -Name '_BackupCreated' -ErrorAction SilentlyContinue)) {
    New-ItemProperty -Path $backupKey -Name '_BackupCreated' `
        -Value (Get-Date).ToString('o') -PropertyType String -Force | Out-Null
}
