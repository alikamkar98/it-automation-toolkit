# IT Automation Toolkit

A collection of production-style **PowerShell** and **Bash** scripts for common
Windows/Active Directory and Linux system-administration tasks. Every script
includes comment-based help, parameter validation, error handling, logging, and
a usage example — written to be read, explained, and reused.

> Built as a portfolio to demonstrate day-to-day sysadmin automation:
> onboarding, monitoring, backups, and account hygiene.

---

## Scripts

| Script | Platform | Purpose |
| --- | --- | --- |
| [`New-BulkADUsers.ps1`](scripts/New-BulkADUsers.ps1) | PowerShell / AD | Create AD users in bulk from a CSV with random initial passwords, OU placement, and group assignment. Exports generated passwords for secure hand-off. |
| [`Get-DiskSpaceReport.ps1`](scripts/Get-DiskSpaceReport.ps1) | PowerShell / CIM | Check disk usage across a server list and email a highlighted HTML report when any drive exceeds a threshold (default 85%). |
| [`backup-rotate.sh`](scripts/backup-rotate.sh) | Bash | Create compressed backups and enforce a 7-daily / 4-weekly retention policy, with logging and a dry-run mode. |
| [`Get-InactiveADAccounts.ps1`](scripts/Get-InactiveADAccounts.ps1) | PowerShell / AD | Find AD accounts inactive for 90+ days, export a report, and optionally disable and relocate them. |

---

## Requirements

- **PowerShell scripts:** Windows PowerShell 5.1 or PowerShell 7+, the
  [RSAT ActiveDirectory module](https://learn.microsoft.com/en-us/windows-server/administration/rsat/rsat-overview),
  and rights in the target OUs. `Get-DiskSpaceReport.ps1` also needs WinRM/CIM
  access to the target servers and an SMTP relay.
- **Bash script:** any modern Linux/macOS with `bash`, `tar`, and `gzip`.
  Tested on Ubuntu 22.04.

---

## Quick start

```powershell
# Bulk-create users (preview first with -WhatIf)
.\scripts\New-BulkADUsers.ps1 -CsvPath .\examples\newhires.csv -WhatIf
.\scripts\New-BulkADUsers.ps1 -CsvPath .\examples\newhires.csv

# Disk report for a server list
.\scripts\Get-DiskSpaceReport.ps1 -ServerListPath .\examples\servers.txt `
    -SmtpServer smtp.corp.local -From alerts@corp.local -To ops@corp.local

# Inactive accounts (report only)
.\scripts\Get-InactiveADAccounts.ps1 -DaysInactive 90
```

```bash
# Nightly backup with rotation (dry run shown)
./scripts/backup-rotate.sh -s /var/www -d /mnt/backups -r
```

Every script supports `Get-Help .\script.ps1 -Full` (PowerShell) or `-h` (Bash)
for full documentation.

---

## Sample input files

See [`examples/`](examples/) for a sample `newhires.csv` and `servers.txt` you
can copy and adapt.

---

## Screenshots

_To be added: each script running against a live lab AD/domain. Planned:_

- `New-BulkADUsers.ps1` creating users (with `-WhatIf` preview and real run)
- The HTML disk-space report email
- `Get-InactiveADAccounts.ps1` report output
- `backup-rotate.sh` daily/weekly rotation in action

---

## Safety notes

- PowerShell scripts that change state support `-WhatIf`; always preview first.
- `New-BulkADUsers.ps1` writes generated passwords to a CSV — store it securely
  and delete after distribution.
- Test in a lab or non-production OU before running against a live domain.

## License

MIT — see [LICENSE](LICENSE).
