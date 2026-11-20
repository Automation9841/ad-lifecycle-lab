# AD Account Lifecycle Lab

PowerShell scripts for the full life of a user account in a hybrid Microsoft environment:
**build the company → onboard → enable new hires → sync to Microsoft 365 → offboard.**

Built and tested in my home lab (Windows Server 2022 domain controller, Microsoft Entra Connect, Microsoft 365 Business Basic).

▶️ **Video walkthrough:** https://youtu.be/61mcKol2YDM?si=s5kFX8R_cUNDGFC8

---

## What's inside

| Script | What it does |
|---|---|
| `Setup-InfranetLab.ps1` | Adds the UPN suffix, builds the OU structure (IT / Non-IT, 8 departments, Groups, Admin Accounts, Disabled Users) and creates AGDLP security groups. Optional `-CreateShares` builds department shares with NTFS permissions through the domain local groups. Safe to re-run. |
| `Onboard-Employees.ps1` | Reads an HR CSV and creates each account in the right OU with all HR attributes, a temporary password (prompted, never stored) and *change at first sign-in*. Adds department, role and license groups. Future start dates are created **disabled**, contractors **expire**, IT staff get a separate **adm-** account. Sets managers, starts a delta sync, writes a log. |
| `Enable-NewHires.ps1` | Enables accounts whose start date has arrived. Run it every morning with Task Scheduler. |
| `Offboard-Employee.ps1` | Saves a snapshot, disables the account, resets the password to a random value, revokes Microsoft 365 sessions, converts the mailbox to shared with manager access and an auto-reply, removes groups (license last, only after the mailbox is safe), stamps the ticket, hides from the address list, moves to Disabled Users, handles the adm- account, syncs and logs. |
| `employees.csv` | 80 sample employees across 8 departments (fake data). |
| `new-hires.csv` | 4 sample new hires with a future start date. |

## Requirements

- Windows Server with the **ActiveDirectory** PowerShell module (run on a DC or a machine with RSAT)
- **Microsoft Entra Connect** for the sync steps (`Start-ADSyncSyncCycle`)
- Optional, for the cloud offboarding steps: `Microsoft.Graph` and `ExchangeOnlineManagement` modules
  ```powershell
  Install-Module Microsoft.Graph, ExchangeOnlineManagement -Scope CurrentUser
  ```

## How to run

Always do a dry run with `-WhatIf` first. It shows what would change and changes nothing.

```powershell
# 1. Build the structure
.\Setup-InfranetLab.ps1 -UpnSuffix 'lab.contoso.com' -WhatIf
.\Setup-InfranetLab.ps1 -UpnSuffix 'lab.contoso.com'

# 2. Onboard everyone from the HR CSV (you will be asked for the temporary password)
.\Onboard-Employees.ps1 -CsvPath .\employees.csv -WhatIf
.\Onboard-Employees.ps1 -CsvPath .\employees.csv -Ticket REQ1001

# 3. New hires (created disabled until their start date)
.\Onboard-Employees.ps1 -CsvPath .\new-hires.csv -Ticket REQ2001
.\Enable-NewHires.ps1          # on their first morning

# 4. Offboard a leaver
.\Offboard-Employee.ps1 -Username customeruser1.test -Ticket LAB-001 -WhatIf
.\Offboard-Employee.ps1 -Username customeruser1.test -Ticket LAB-001
```

## Entra Connect sync scope

- ✅ Sync: `Users`, `Groups`, **`Disabled Users`**. Disabled Users must stay in scope, or the cloud account and mailbox get deleted instead of blocked.
- ❌ Do not sync: `Admin Accounts`. Admin accounts stay on-premises only.

## Lessons learned

- `Start-ADSyncSyncCycle` is one word. `Start -ADSync...` fails.
- The session-revoke step needs the Microsoft Graph module. Without it you get a yellow warning and sessions stay alive until their tokens expire.
- Don't remove the license before the mailbox is converted to shared, or the mailbox is lost.

## Disclaimer

Lab and learning project. Test in a lab first and review every script before running it in production.
