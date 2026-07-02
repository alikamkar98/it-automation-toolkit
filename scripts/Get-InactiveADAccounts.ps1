<#
.SYNOPSIS
    Finds enabled Active Directory user accounts that have been inactive for a
    given number of days, and optionally disables them.

.DESCRIPTION
    Uses Search-ADAccount to identify accounts whose LastLogonDate is older than
    the threshold (default 90 days). Accounts that have never logged on are
    reported separately using their whenCreated date. Results are written to a
    CSV. With -Disable the script disables the accounts and moves them to a
    "disabled" OU if one is supplied; -WhatIf shows the effect without changing
    anything.

.PARAMETER DaysInactive
    Inactivity threshold in days. Default 90.

.PARAMETER SearchBase
    Optional distinguished name to limit the search to one OU/subtree. Defaults
    to the whole domain.

.PARAMETER ReportPath
    Folder for the CSV report. Defaults to the script's folder.

.PARAMETER Disable
    Disable the matched accounts. Combine with -DisabledOU to also relocate them.

.PARAMETER DisabledOU
    Distinguished name of an OU to move disabled accounts into.

.EXAMPLE
    .\Get-InactiveADAccounts.ps1

    Reports every enabled account with no logon in the last 90 days.

.EXAMPLE
    .\Get-InactiveADAccounts.ps1 -DaysInactive 120 -Disable `
        -DisabledOU "OU=Disabled,DC=corp,DC=local" -WhatIf

    Shows which 120-day-inactive accounts would be disabled and moved.

.NOTES
    LastLogonDate is replicated (LastLogonTimestamp) and can lag real activity
    by up to ~14 days by design - fine for a 90-day inactivity check.
    Requires the ActiveDirectory module.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateRange(1, 3650)]
    [int]$DaysInactive = 90,

    [string]$SearchBase,

    [string]$ReportPath = $PSScriptRoot,

    [switch]$Disable,

    [string]$DisabledOU
)

Import-Module ActiveDirectory -ErrorAction Stop

$cutoff    = (Get-Date).AddDays(-$DaysInactive)
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$csvFile   = Join-Path $ReportPath "InactiveAccounts-$timestamp.csv"

Write-Verbose "Cutoff date: $cutoff (accounts inactive >= $DaysInactive days)."

# Search-ADAccount does the heavy lifting for the "stale but has logged on" set.
$searchParams = @{
    AccountInactive = $true
    UsersOnly       = $true
    TimeSpan        = (New-TimeSpan -Days $DaysInactive)
}
if ($SearchBase) { $searchParams.SearchBase = $SearchBase }

$stale = Search-ADAccount @searchParams | Where-Object { $_.Enabled }

# Enrich each account with the properties we want in the report.
$report = foreach ($acct in $stale) {
    $u = Get-ADUser -Identity $acct.DistinguishedName `
        -Properties LastLogonDate, whenCreated, Department, Manager, DistinguishedName

    $lastLogon = if ($u.LastLogonDate) { $u.LastLogonDate } else { $null }
    $idleDays  = if ($lastLogon) {
        [int]((Get-Date) - $lastLogon).TotalDays
    } else {
        [int]((Get-Date) - $u.whenCreated).TotalDays
    }

    [pscustomobject]@{
        SamAccountName = $u.SamAccountName
        Name           = $u.Name
        Department     = $u.Department
        LastLogonDate  = if ($lastLogon) { $lastLogon.ToString('yyyy-MM-dd') } else { 'Never' }
        WhenCreated    = $u.whenCreated.ToString('yyyy-MM-dd')
        IdleDays       = $idleDays
        DN             = $u.DistinguishedName
    }
}

if (-not $report) {
    Write-Host "No enabled accounts inactive for $DaysInactive+ days were found."
    return
}

$report | Sort-Object IdleDays -Descending |
    Export-Csv -Path $csvFile -NoTypeInformation -Encoding UTF8
Write-Host "Found $($report.Count) inactive account(s). Report: $csvFile"

# --- Optional remediation --------------------------------------------------

if ($Disable) {
    foreach ($item in $report) {
        if ($PSCmdlet.ShouldProcess($item.SamAccountName, "Disable account")) {
            try {
                Disable-ADAccount -Identity $item.DN -ErrorAction Stop
                Write-Host "Disabled $($item.SamAccountName)."

                if ($DisabledOU) {
                    Move-ADObject -Identity $item.DN -TargetPath $DisabledOU -ErrorAction Stop
                    Write-Host "Moved $($item.SamAccountName) to $DisabledOU."
                }
            }
            catch {
                Write-Warning "Failed on $($item.SamAccountName): $($_.Exception.Message)"
            }
        }
    }
}

# Emit the report objects for further pipeline use.
$report
