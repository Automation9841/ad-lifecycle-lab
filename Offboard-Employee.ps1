<#
.SYNOPSIS
    Offboards a leaver from Infranetcloud Lab the way a real service desk does.
.DESCRIPTION
    1. Saves a snapshot of the account and its groups (for audit, rehire or HR mistakes)
    2. Disables the account and resets the password to a random value
    3. Revokes all Microsoft 365 sign-in sessions
    4. Licensed users: converts the mailbox to a SHARED mailbox, gives the manager Full Access,
       and sets an automatic reply pointing to the manager
    5. Removes all groups. The license group is removed ONLY after the mailbox is converted,
       so no email is ever lost
    6. Stamps the description, hides from the address list, moves to Disabled Users
    7. Does the same for the person's adm- account, if they are IT
    8. Syncs and writes a log
    'Disabled Users' MUST be in the Entra Connect sync scope, or the cloud account (and mailbox) is deleted.
.EXAMPLE
    .\Offboard-Employee.ps1 -Username dave.ghost -Ticket INC3001 -WhatIf
    .\Offboard-Employee.ps1 -Username dave.ghost -Ticket INC3001
    .\Offboard-Employee.ps1 -Username dave.ghost -Ticket INC3001 -SkipCloud   # AD steps only
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$Username,
    [Parameter(Mandatory)][string]$Ticket,
    [string]$SyncServer   = 'DC1',
    [string]$LogFolder    = 'C:\Scripts\Lifecycle\Logs',
    [string]$LicenseGroup = 'LIC-M365-BusinessBasic',
    [switch]$SkipCloud
)

Import-Module ActiveDirectory
$root       = "OU=Infranetcloud Lab,$((Get-ADDomain).DistinguishedName)"
$disabledOU = "OU=Disabled Users,$root"
$stamp      = Get-Date -Format 'yyyyMMdd-HHmmss'
$steps      = @()

function New-RandomSecret {
    ConvertTo-SecureString ("$([guid]::NewGuid())$([guid]::NewGuid())".Replace('-', '') + 'Aa1!') -AsPlainText -Force
}

$user = Get-ADUser -Identity $Username -Properties * -ErrorAction Stop
$groupNames = @($user.MemberOf | ForEach-Object { (Get-ADGroup $_).Name })
$licensed   = $groupNames -contains $LicenseGroup
$manager    = if ($user.Manager) { Get-ADUser $user.Manager -Properties DisplayName, UserPrincipalName } else { $null }

# 1. Snapshot first: nothing is removed before it is recorded
New-Item -ItemType Directory -Path $LogFolder -Force -WhatIf:$false | Out-Null
$user | Select-Object SamAccountName, UserPrincipalName, DisplayName, EmployeeID, Department, Title, Office,
    @{ n = 'Manager'; e = { $manager.SamAccountName } }, DistinguishedName, Enabled |
    Export-Csv (Join-Path $LogFolder "Snapshot-$Username-$stamp.csv") -NoTypeInformation -WhatIf:$false
$groupNames | Set-Content (Join-Path $LogFolder "Groups-$Username-$stamp.txt") -WhatIf:$false
Write-Host "Saved snapshot and $($groupNames.Count) groups for $Username"

# 2. Lock the door
if ($PSCmdlet.ShouldProcess($Username, 'Disable account and reset password')) {
    Disable-ADAccount -Identity $user
    Set-ADAccountPassword -Identity $user -Reset -NewPassword (New-RandomSecret)
    $steps += 'Account disabled', 'Password reset to random value'
}

# 3-4. Cloud: end sessions, convert mailbox, give manager access
$mailboxConverted = $false
if (-not $SkipCloud) {
    if ($PSCmdlet.ShouldProcess($user.UserPrincipalName, 'Revoke all Microsoft 365 sign-in sessions')) {
        try {
            Connect-MgGraph -Scopes 'User.RevokeSessions.All' -NoWelcome -ErrorAction Stop
            Revoke-MgUserSignInSession -UserId $user.UserPrincipalName -ErrorAction Stop | Out-Null
            $steps += 'Microsoft 365 sessions revoked'
        }
        catch { Write-Warning "Session revoke failed: $($_.Exception.Message)" }
    }

    if ($licensed -and $PSCmdlet.ShouldProcess($user.UserPrincipalName, 'Convert mailbox to shared, grant manager Full Access, set auto-reply')) {
        try {
            Connect-ExchangeOnline -ShowBanner:$false -ErrorAction Stop
            Set-Mailbox -Identity $user.UserPrincipalName -Type Shared -ErrorAction Stop
            $steps += 'Mailbox converted to shared'
            $mailboxConverted = $true
            if ($manager) {
                Add-MailboxPermission -Identity $user.UserPrincipalName -User $manager.UserPrincipalName `
                    -AccessRights FullAccess -InheritanceType All -AutoMapping $true -ErrorAction Stop | Out-Null
                $msg = "Thank you for your email. $($user.DisplayName) is no longer with Infranetcloud Lab. " +
                       "Please contact $($manager.DisplayName) at $($manager.UserPrincipalName)."
                Set-MailboxAutoReplyConfiguration -Identity $user.UserPrincipalName -AutoReplyState Enabled `
                    -InternalMessage $msg -ExternalMessage $msg -ErrorAction Stop
                $steps += "Manager $($manager.SamAccountName) given Full Access", 'Auto-reply set'
            }
        }
        catch { Write-Warning "Mailbox step failed: $($_.Exception.Message)" }
    }
}

# 5. Remove groups (license last, and only if the mailbox is safe)
foreach ($g in $user.MemberOf) {
    $name = (Get-ADGroup $g).Name
    if ($name -eq $LicenseGroup -and -not $mailboxConverted) {
        Write-Warning "Keeping ${LicenseGroup}: mailbox not converted yet, removing the license now could lose email."
        $steps += "Kept $LicenseGroup (mailbox not converted)"
        continue
    }
    if ($PSCmdlet.ShouldProcess($Username, "Remove from $name")) {
        Remove-ADGroupMember -Identity $g -Members $user -Confirm:$false
        $steps += "Removed from $name"
    }
}

# 6. Stamp, hide, move
if ($PSCmdlet.ShouldProcess($Username, 'Stamp description, hide from address lists, move to Disabled Users')) {
    $desc = "Disabled $(Get-Date -Format 'yyyy-MM-dd') | Ticket $Ticket | by $env:USERNAME"
    Set-ADUser -Identity $user -Description $desc -Clear Manager
    $steps += "Description: $desc", 'Manager link cleared'
    try {
        Set-ADUser -Identity $user -Replace @{ msExchHideFromAddressLists = $true } -ErrorAction Stop
        $steps += 'Hidden from address lists'
    }
    catch { Write-Warning 'Could not hide from address lists (Exchange schema attributes not in AD).' }
    Move-ADObject -Identity $user.DistinguishedName -TargetPath $disabledOU
    $steps += 'Moved to Disabled Users'
}

# 7. IT staff: their admin account goes too
$adm = Get-ADUser -Filter "SamAccountName -eq 'adm-$Username'" -Properties MemberOf
if ($adm -and $PSCmdlet.ShouldProcess($adm.SamAccountName, 'Disable admin account, remove groups, move to Disabled Users')) {
    Disable-ADAccount -Identity $adm
    Set-ADAccountPassword -Identity $adm -Reset -NewPassword (New-RandomSecret)
    foreach ($g in $adm.MemberOf) { Remove-ADGroupMember -Identity $g -Members $adm -Confirm:$false }
    Set-ADUser -Identity $adm -Description "Disabled $(Get-Date -Format 'yyyy-MM-dd') | Ticket $Ticket"
    Move-ADObject -Identity $adm.DistinguishedName -TargetPath $disabledOU
    $steps += "Admin account $($adm.SamAccountName) disabled"
}

# 8. Sync and log
if (-not $WhatIfPreference) {
    try {
        Invoke-Command -ComputerName $SyncServer -ScriptBlock { Import-Module ADSync; Start-ADSyncSyncCycle -PolicyType Delta } -ErrorAction Stop | Out-Null
        $steps += "Delta sync started on $SyncServer"
    }
    catch { Write-Warning "Sync not started: $($_.Exception.Message)" }

    $logFile = Join-Path $LogFolder "Offboarding-$Username-$stamp.txt"
    @("Offboarding $($user.DisplayName) ($Username) | Ticket $Ticket | $(Get-Date)") + $steps | Set-Content $logFile
    Write-Host "Done. Log saved to $logFile" -ForegroundColor Green
}
$steps
