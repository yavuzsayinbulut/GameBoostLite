$ErrorActionPreference = 'Stop'
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$backupKey = 'HKCU:\Software\GameBoostLite\StartupBackup'
$approvedKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
$approvedBackupKey = Join-Path $backupKey 'StartupApprovedRun'

if (-not (Test-Path $backupKey)) {
    Write-Output 'No GameBoost Lite startup backup was found.'
    exit 0
}

$backup = Get-ItemProperty -Path $backupKey
$approvedBackup = Get-ItemProperty -Path $approvedBackupKey -ErrorAction SilentlyContinue
$legacyApprovedWarning = $false
foreach ($property in $backup.PSObject.Properties) {
    if ($property.Name -like 'PS*' -or $property.Name -like '_*') { continue }
    New-ItemProperty -Path $runKey -Name $property.Name -Value ([string]$property.Value) `
        -PropertyType String -Force | Out-Null
    $hasName = 'Has_' + $property.Name
    $dataName = 'Data_' + $property.Name
    if ($approvedBackup -and $approvedBackup.PSObject.Properties[$hasName]) {
        New-Item -Path $approvedKey -Force | Out-Null
        if ([int]$approvedBackup.PSObject.Properties[$hasName].Value -eq 1) {
            $bytes = [byte[]]$approvedBackup.PSObject.Properties[$dataName].Value
            New-ItemProperty -Path $approvedKey -Name $property.Name -Value $bytes `
                -PropertyType Binary -Force | Out-Null
        } else {
            Remove-ItemProperty -Path $approvedKey -Name $property.Name -ErrorAction SilentlyContinue
        }
    } else {
        $legacyApprovedWarning = $true
    }
    Write-Output "Restored startup: $($property.Name)"
}

if ($legacyApprovedWarning) {
    Write-Output 'Legacy backup had no StartupApproved snapshot; verify restored apps in Task Manager > Startup apps.'
}
Remove-Item -Path $backupKey -Recurse -Force
