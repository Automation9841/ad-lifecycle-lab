<#
.SYNOPSIS
    Builds the Infranetcloud Lab structure in Active Directory. Run once on DC1.
    Safe to run again: it skips anything that already exists.
.EXAMPLE
    .\Setup-InfranetLab.ps1 -WhatIf
    .\Setup-InfranetLab.ps1 -CreateShares
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$UpnSuffix = 'lab.contoso.com',
    [string]$ShareRoot = 'C:\Shares',
    [switch]$CreateShares
)

Import-Module ActiveDirectory
$domain   = Get-ADDomain
$domainDN = $domain.DistinguishedName
$netbios  = $domain.NetBIOSName
$root     = "OU=Infranetcloud Lab,$domainDN"

# Department name (as in the CSV)  ->  short code used in group names
$departments = [ordered]@{
    'IT'               = 'IT'
    'Sales'            = 'Sales'
    'Marketing'        = 'Marketing'
    'Human Resources'  = 'HR'
    'Finance'          = 'Finance'
    'Operations'       = 'Operations'
    'Customer Service' = 'CustomerService'
    'Legal'            = 'Legal'
}

function New-LabOU([string]$Name, [string]$Path) {
    $dn = "OU=$Name,$Path"
    if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$dn'" -ErrorAction SilentlyContinue)) {
        if ($PSCmdlet.ShouldProcess($dn, 'Create OU')) {
            New-ADOrganizationalUnit -Name $Name -Path $Path -ProtectedFromAccidentalDeletion $true
            Write-Host "Created OU  $dn"
        }
    }
    $dn
}

function New-LabGroup([string]$Name, [string]$Path, [string]$Scope, [string]$Description) {
    if (-not (Get-ADGroup -Filter "Name -eq '$Name'" -ErrorAction SilentlyContinue)) {
        if ($PSCmdlet.ShouldProcess($Name, "Create $Scope security group")) {
            New-ADGroup -Name $Name -SamAccountName $Name -GroupScope $Scope -GroupCategory Security `
                -Path $Path -Description $Description
            Write-Host "Created group $Name"
        }
    }
}

function Add-Nested([string]$Group, [string]$Member) {
    $members = @(Get-ADGroupMember -Identity $Group -ErrorAction SilentlyContinue | Select-Object -ExpandProperty SamAccountName)
    if ($members -notcontains $Member -and $PSCmdlet.ShouldProcess($Group, "Add $Member")) {
        Add-ADGroupMember -Identity $Group -Members $Member
        Write-Host "Nested $Member into $Group"
    }
}

# 1. UPN suffix so users can sign in as name@lab.contoso.com
$forest = Get-ADForest
if ($forest.UPNSuffixes -notcontains $UpnSuffix -and $PSCmdlet.ShouldProcess($forest.Name, "Add UPN suffix $UpnSuffix")) {
    Set-ADForest -Identity $forest.Name -UPNSuffixes @{ Add = $UpnSuffix }
    Write-Host "Added UPN suffix $UpnSuffix"
}

# 2. OU structure
$null      = New-LabOU 'Infranetcloud Lab' $domainDN
$usersOU   = New-LabOU 'Users' $root
$itOU      = New-LabOU 'IT' $usersOU
$nonItOU   = New-LabOU 'Non-IT' $usersOU
foreach ($dept in $departments.Keys) { if ($dept -ne 'IT') { $null = New-LabOU $dept $nonItOU } }
$groupsOU  = New-LabOU 'Groups' $root
$deptGrpOU = New-LabOU 'Department' $groupsOU
$roleGrpOU = New-LabOU 'Role' $groupsOU
$resGrpOU  = New-LabOU 'Resources' $groupsOU
$licGrpOU  = New-LabOU 'Licensing' $groupsOU
$null      = New-LabOU 'Computers' $root
$null      = New-LabOU 'Admin Accounts' $root
$null      = New-LabOU 'Disabled Users' $root

# 3. Groups (AGDLP: user accounts -> Global groups -> Domain Local groups -> Permissions)
foreach ($dept in $departments.Keys) {
    $code = $departments[$dept]
    New-LabGroup "SG-$code" $deptGrpOU 'Global' "All $dept employees"
    New-LabGroup "DL-FS-$code-Modify" $resGrpOU 'DomainLocal' "Modify access to the $dept shared folder"
}
New-LabGroup 'SG-AllStaff'    $roleGrpOU 'Global' 'Every employee'
New-LabGroup 'SG-Managers'    $roleGrpOU 'Global' 'Department managers'
New-LabGroup 'SG-Contractors' $roleGrpOU 'Global' 'Contractors (accounts expire)'
New-LabGroup 'SG-IT-Admins'   $roleGrpOU 'Global' 'Separate admin accounts of IT staff'
New-LabGroup 'LIC-M365-BusinessBasic' $licGrpOU 'Global' 'Members get Microsoft 365 Business Basic (group-based licensing)'

foreach ($code in $departments.Values) { Add-Nested "DL-FS-$code-Modify" "SG-$code" }

# 4. Optional: department shared folders, permissions through the DL groups
if ($CreateShares) {
    foreach ($code in $departments.Values) {
        $path = Join-Path $ShareRoot $code
        if ($PSCmdlet.ShouldProcess($path, "Create folder and share '$code'")) {
            New-Item -ItemType Directory -Path $path -Force | Out-Null
            $acl = Get-Acl $path
            $acl.SetAccessRuleProtection($true, $false)   # stop inheriting from C:\
            $inherit = 'ContainerInherit,ObjectInherit'
            foreach ($rule in @(
                    @('NT AUTHORITY\SYSTEM', 'FullControl'),
                    @('BUILTIN\Administrators', 'FullControl'),
                    @("$netbios\DL-FS-$code-Modify", 'Modify'))) {
                $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                    $rule[0], $rule[1], $inherit, 'None', 'Allow')))
            }
            Set-Acl -Path $path -AclObject $acl
            if (-not (Get-SmbShare -Name $code -ErrorAction SilentlyContinue)) {
                New-SmbShare -Name $code -Path $path -ChangeAccess 'Authenticated Users' -FullAccess 'BUILTIN\Administrators' | Out-Null
            }
            Write-Host "Share \\$env:COMPUTERNAME\$code ready"
        }
    }
}

Write-Host "`nNext: in Entra Connect, sync 'Infranetcloud Lab\Users', 'Groups' and 'Disabled Users'." -ForegroundColor Yellow
Write-Host "Do NOT sync 'Admin Accounts' (admin accounts stay on-premises only)." -ForegroundColor Yellow
