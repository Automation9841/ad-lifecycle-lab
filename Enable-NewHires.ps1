<#
.SYNOPSIS
    Enables new hires whose start date has arrived. Run on the morning of their first day,
    or schedule it daily with Task Scheduler.
.EXAMPLE
    .\Enable-NewHires.ps1 -WhatIf
    .\Enable-NewHires.ps1
#>
[CmdletBinding(SupportsShouldProcess)]
param([string]$SyncServer = 'DC1')

Import-Module ActiveDirectory
$root  = "OU=Infranetcloud Lab,$((Get-ADDomain).DistinguishedName)"
$today = (Get-Date).Date
$enabled = @()

$pending = Get-ADUser -SearchBase "OU=Users,$root" -Filter 'Enabled -eq $false' -Properties Description |
    Where-Object { $_.Description -match 'Pending start (\d{4}-\d{2}-\d{2})' }

foreach ($user in $pending) {
    $null  = $user.Description -match 'Pending start (\d{4}-\d{2}-\d{2})'
    $start = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd', $null)
    if ($start -gt $today) { continue }

    if ($PSCmdlet.ShouldProcess($user.SamAccountName, 'Enable account (start date reached)')) {
        Enable-ADAccount -Identity $user
        Set-ADUser -Identity $user -Clear Description
        $adm = Get-ADUser -Filter "SamAccountName -eq 'adm-$($user.SamAccountName)'" -SearchBase "OU=Admin Accounts,$root"
        if ($adm) { Enable-ADAccount -Identity $adm }
        $enabled += $user.SamAccountName
    }
}

if ($enabled -and -not $WhatIfPreference) {
    try {
        Invoke-Command -ComputerName $SyncServer -ScriptBlock { Import-Module ADSync; Start-ADSyncSyncCycle -PolicyType Delta } -ErrorAction Stop | Out-Null
    }
    catch { Write-Warning "Sync not started: $($_.Exception.Message)" }
}
if ($enabled) { "Enabled today: $($enabled -join ', ')" } else { 'No new hires start today.' }
