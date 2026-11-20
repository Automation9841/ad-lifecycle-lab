<#
.SYNOPSIS
    Onboards employees from an HR CSV into Infranetcloud Lab (Active Directory + Microsoft 365).
.DESCRIPTION
    For each row:
      - creates the account in the right department OU with every HR attribute
      - sets a temporary password (prompted, never stored in the script) and forces a change at first sign-in
      - future start date  -> account created DISABLED, enabled on day one by Enable-NewHires.ps1
      - contractors        -> account expires after -ContractMonths
      - groups: department, SG-AllStaff, SG-Managers / SG-Contractors, license group
      - IT staff           -> also a separate admin account (adm-first.last), never synced to the cloud
    Then sets every manager, starts an Entra Connect sync and writes a log.
.EXAMPLE
    .\Onboard-Employees.ps1 -CsvPath .\infranetcloud-employees.csv -WhatIf
    .\Onboard-Employees.ps1 -CsvPath .\new-hires.csv -Ticket REQ2001
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$CsvPath,
    [string]$Ticket          = 'BULK-IMPORT',
    [securestring]$DefaultPassword,   # temporary password for new accounts; prompted if not given
    [int]$ContractMonths     = 6,
    [string]$SyncServer      = 'DC1',
    [string]$LogFolder       = 'C:\Scripts\Lifecycle\Logs',
    [switch]$NoAdminAccounts
)

Import-Module ActiveDirectory
$domain    = Get-ADDomain
$root      = "OU=Infranetcloud Lab,$($domain.DistinguishedName)"
$adminOU   = "OU=Admin Accounts,$root"
$today     = (Get-Date).Date
$stamp     = Get-Date -Format 'yyyyMMdd-HHmmss'
$results   = @()
$adminPws  = @()

$deptCode = @{
    'IT' = 'IT'; 'Sales' = 'Sales'; 'Marketing' = 'Marketing'; 'Human Resources' = 'HR'
    'Finance' = 'Finance'; 'Operations' = 'Operations'; 'Customer Service' = 'CustomerService'; 'Legal' = 'Legal'
}

function Get-DeptOU([string]$Dept) {
    if ($Dept -eq 'IT') { "OU=IT,OU=Users,$root" } else { "OU=$Dept,OU=Non-IT,OU=Users,$root" }
}

function New-RandomPassword([int]$Length = 20) {
    $sets = 'ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnopqrstuvwxyz', '23456789', '!@#$%*?'
    $rng  = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $pick = { param($s) $b = [byte[]]::new(1); $rng.GetBytes($b); $s[$b[0] % $s.Length] }
    $chars = @(foreach ($s in $sets) { & $pick $s })
    $all   = -join $sets
    $chars += 1..($Length - 4) | ForEach-Object { & $pick $all }
    -join ($chars | Sort-Object { Get-Random })
}

if (-not $DefaultPassword) {
    $DefaultPassword = Read-Host -AsSecureString 'Temporary password for new accounts (users must change it at first sign-in)'
}
$securePw = $DefaultPassword
$rows     = Import-Csv $CsvPath

# ---------- Pass 1: create accounts and add groups ----------
foreach ($u in $rows) {
    $sam  = $u.SamAccountName.Trim()
    $dept = $u.Department.Trim()
    $status = ''
    try {
        if (-not $deptCode.ContainsKey($dept)) { throw "Unknown department '$dept'" }
        if (Get-ADUser -Filter "SamAccountName -eq '$sam'") {
            $results += [pscustomobject]@{ EmployeeID = $u.EmployeeID; Name = $u.DisplayName; Username = $sam; Department = $dept; Status = 'Skipped: already exists' }
            continue
        }

        $start    = [datetime]::ParseExact($u.StartDate.Trim(), 'yyyy-MM-dd', $null)
        $startNow = $start -le $today
        $params = @{
            Name                  = $u.DisplayName
            GivenName             = $u.FirstName
            Surname               = $u.LastName
            DisplayName           = $u.DisplayName
            SamAccountName        = $sam
            UserPrincipalName     = $u.UserPrincipalName
            EmailAddress          = $u.Email
            EmployeeID            = $u.EmployeeID
            Division              = $u.Division
            Department            = $dept
            Title                 = $u.Title
            Company               = $u.Company
            Office                = $u.Office
            StreetAddress         = $u.StreetAddress
            City                  = $u.City
            State                 = $u.State
            PostalCode            = $u.PostalCode
            Country               = $u.Country
            OfficePhone           = $u.OfficePhone
            Path                  = (Get-DeptOU $dept)
            AccountPassword       = $securePw
            ChangePasswordAtLogon = $true
            Enabled               = $startNow
            OtherAttributes       = @{ employeeType = $u.EmployeeType }
        }
        if ($u.MobilePhone) { $params.MobilePhone = $u.MobilePhone }
        if (-not $startNow) { $params.Description = "Pending start $($start.ToString('yyyy-MM-dd')) | $Ticket" }
        if ($u.EmployeeType -eq 'Contractor') {
            $base = if ($start -gt $today) { $start } else { $today }
            $params.AccountExpirationDate = $base.AddMonths($ContractMonths)
        }

        $groups = @("SG-$($deptCode[$dept])", 'SG-AllStaff')
        if (-not $u.Manager)                 { $groups += 'SG-Managers' }
        if ($u.EmployeeType -eq 'Contractor') { $groups += 'SG-Contractors' }
        if ($u.License -and $u.License -ne 'None') { $groups += 'LIC-M365-BusinessBasic' }

        if ($PSCmdlet.ShouldProcess("$($u.DisplayName) ($sam)", "Create in $dept, groups: $($groups -join ', ')")) {
            New-ADUser @params -ErrorAction Stop
            foreach ($g in $groups) { Add-ADGroupMember -Identity $g -Members $sam -ErrorAction Stop }
            $status = if ($startNow) { 'Created (enabled)' } else { "Created (disabled until $($start.ToString('yyyy-MM-dd')))" }

            # Separate admin account for IT staff (on-premises only, never licensed)
            if ($u.Division -eq 'IT' -and -not $NoAdminAccounts) {
                $admSam = "adm-$sam"
                if ($admSam.Length -gt 20) { $admSam = $admSam.Substring(0, 20) }
                if (-not (Get-ADUser -Filter "SamAccountName -eq '$admSam'")) {
                    $admPw = New-RandomPassword
                    New-ADUser -Name "$($u.DisplayName) (Admin)" -GivenName $u.FirstName -Surname $u.LastName `
                        -DisplayName "$($u.DisplayName) (Admin)" -SamAccountName $admSam `
                        -UserPrincipalName "$admSam@$($domain.DNSRoot)" -Department $dept -Title "$($u.Title) - Admin" `
                        -Company $u.Company -Path $adminOU -AccountPassword (ConvertTo-SecureString $admPw -AsPlainText -Force) `
                        -ChangePasswordAtLogon $true -Enabled $startNow -ErrorAction Stop
                    Add-ADGroupMember -Identity 'SG-IT-Admins' -Members $admSam -ErrorAction Stop
                    $adminPws += [pscustomobject]@{ AdminAccount = $admSam; TempPassword = $admPw }
                    $status += ' + admin account'
                }
            }
        }
        else { $status = 'WhatIf' }
    }
    catch { $status = "FAILED: $($_.Exception.Message)" }

    $results += [pscustomobject]@{ EmployeeID = $u.EmployeeID; Name = $u.DisplayName; Username = $sam; Department = $dept; Status = $status }
}

# ---------- Pass 2: managers (after everyone exists) ----------
foreach ($u in $rows | Where-Object { $_.Manager }) {
    if ($WhatIfPreference) { Write-Host "What if: Set manager of $($u.SamAccountName) to $($u.Manager)"; continue }
    $mgr = Get-ADUser -Filter "SamAccountName -eq '$($u.Manager.Trim())'"
    if (-not $mgr) { Write-Warning "Manager '$($u.Manager)' not found for $($u.DisplayName)"; continue }
    if ($PSCmdlet.ShouldProcess($u.SamAccountName, "Set manager to $($u.Manager)")) {
        try { Set-ADUser -Identity $u.SamAccountName -Manager $mgr.DistinguishedName -ErrorAction Stop }
        catch { Write-Warning "Could not set manager for $($u.SamAccountName): $($_.Exception.Message)" }
    }
}

# ---------- Sync to Microsoft 365 ----------
if (-not $WhatIfPreference -and ($results | Where-Object Status -like 'Created*')) {
    try {
        Invoke-Command -ComputerName $SyncServer -ScriptBlock {
            Import-Module ADSync; Start-ADSyncSyncCycle -PolicyType Delta
        } -ErrorAction Stop | Out-Null
        Write-Host "Delta sync started on $SyncServer" -ForegroundColor Green
    }
    catch { Write-Warning "Sync not started: $($_.Exception.Message). Run Start-ADSyncSyncCycle -PolicyType Delta manually." }
}

# ---------- Log (no passwords) ----------
New-Item -ItemType Directory -Path $LogFolder -Force -WhatIf:$false | Out-Null
$logFile = Join-Path $LogFolder "Onboarding-$Ticket-$stamp.csv"
$results | Export-Csv $logFile -NoTypeInformation -WhatIf:$false

$results | Format-Table -AutoSize
$results | Group-Object { ($_.Status -split ' ')[0] } | Select-Object Name, Count | Format-Table -AutoSize
if ($adminPws) {
    Write-Host 'Admin account temporary passwords (shown once, not logged):' -ForegroundColor Yellow
    $adminPws | Format-Table -AutoSize
}
Write-Host "Log saved to $logFile"
