<#
.SYNOPSIS
    Creates Active Directory user accounts in bulk from a CSV file.

.DESCRIPTION
    Reads a CSV of new users and, for each row, creates an enabled AD account
    with a randomly generated initial password, places it in the target OU,
    and adds it to a security group. Every action is written to a timestamped
    log file, and the generated passwords are exported to a separate CSV so an
    administrator can distribute them securely.

    The script is idempotent-friendly: if an account with the same
    sAMAccountName already exists it is skipped (not overwritten) and the skip
    is logged.

.PARAMETER CsvPath
    Path to the input CSV. Required columns (header row, case-insensitive):
        FirstName, LastName, Department, OU, Group
    'OU' is the full distinguished name of the target OU, e.g.
        OU=Sales,OU=Users,DC=corp,DC=local
    'Group' is the sAMAccountName of a security group (may be blank).

.PARAMETER PasswordLength
    Length of the generated initial password. Default 16, minimum 12.

.PARAMETER LogPath
    Folder for the run log and the password export. Defaults to the script's
    own folder.

.PARAMETER WhatIf
    Supported via SupportsShouldProcess - shows what would happen without
    making changes.

.EXAMPLE
    .\New-BulkADUsers.ps1 -CsvPath .\newhires.csv

    Creates every account listed in newhires.csv using default settings.

.EXAMPLE
    .\New-BulkADUsers.ps1 -CsvPath .\newhires.csv -PasswordLength 20 -WhatIf

    Shows what the script would do with 20-character passwords, changing nothing.

.NOTES
    Requires the ActiveDirectory module (RSAT) and rights to create users in
    the target OUs. Run from a machine joined to the domain.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$CsvPath,

    [ValidateRange(12, 128)]
    [int]$PasswordLength = 16,

    [string]$LogPath = $PSScriptRoot
)

# --- Setup -----------------------------------------------------------------

# Import the AD module up front so we fail fast if RSAT is missing.
Import-Module ActiveDirectory -ErrorAction Stop

$timestamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
$logFile     = Join-Path $LogPath "New-BulkADUsers-$timestamp.log"
$secretsFile = Join-Path $LogPath "New-BulkADUsers-passwords-$timestamp.csv"

# Simple logger that writes to both the console and the log file.
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )
    $line = "{0}  [{1}]  {2}" -f (Get-Date -Format 's'), $Level, $Message
    Add-Content -Path $logFile -Value $line
    switch ($Level) {
        'WARN'  { Write-Warning $Message }
        'ERROR' { Write-Error   $Message }
        default { Write-Host     $line }
    }
}

# Generates a random password guaranteed to contain upper, lower, digit, and
# symbol characters so it satisfies default AD complexity policy.
function New-RandomPassword {
    param([int]$Length = 16)

    $upper  = 'ABCDEFGHJKLMNPQRSTUVWXYZ'      # no I/O to avoid confusion
    $lower  = 'abcdefghijkmnopqrstuvwxyz'      # no l
    $digits = '23456789'                       # no 0/1
    $symbol = '!@#$%^&*-_=+?'
    $all    = $upper + $lower + $digits + $symbol

    # Guarantee one of each required class, then fill the remainder.
    $chars = @(
        $upper[(Get-Random -Maximum $upper.Length)]
        $lower[(Get-Random -Maximum $lower.Length)]
        $digits[(Get-Random -Maximum $digits.Length)]
        $symbol[(Get-Random -Maximum $symbol.Length)]
    )
    for ($i = $chars.Count; $i -lt $Length; $i++) {
        $chars += $all[(Get-Random -Maximum $all.Length)]
    }

    # Shuffle so the guaranteed characters are not always in front.
    -join ($chars | Sort-Object { Get-Random })
}

# --- Main ------------------------------------------------------------------

Write-Log "Run started. Input: $CsvPath  PasswordLength: $PasswordLength"

$users = Import-Csv -Path $CsvPath
$required = @('FirstName', 'LastName', 'Department', 'OU')
$headers  = $users[0].psobject.Properties.Name
foreach ($col in $required) {
    if ($headers -notcontains $col) {
        Write-Log "CSV is missing required column '$col'. Aborting." 'ERROR'
        return
    }
}

$results = New-Object System.Collections.Generic.List[object]
$created = 0; $skipped = 0; $failed = 0

foreach ($row in $users) {
    $first = $row.FirstName.Trim()
    $last  = $row.LastName.Trim()

    if (-not $first -or -not $last) {
        Write-Log "Row skipped: FirstName/LastName is blank." 'WARN'
        $skipped++; continue
    }

    # Build sAMAccountName as first-initial + last name, lowercased and
    # truncated to the 20-character SAM limit.
    $sam = ("{0}{1}" -f $first.Substring(0, 1), $last).ToLower() -replace '[^a-z0-9]', ''
    if ($sam.Length -gt 20) { $sam = $sam.Substring(0, 20) }

    if (Get-ADUser -Filter "sAMAccountName -eq '$sam'" -ErrorAction SilentlyContinue) {
        Write-Log "Skipped '$sam' - account already exists." 'WARN'
        $skipped++; continue
    }

    $password = New-RandomPassword -Length $PasswordLength
    $securePw = ConvertTo-SecureString $password -AsPlainText -Force
    $upn      = "$sam@$((Get-ADDomain).DNSRoot)"

    $params = @{
        Name                  = "$first $last"
        GivenName             = $first
        Surname               = $last
        SamAccountName        = $sam
        UserPrincipalName     = $upn
        DisplayName           = "$first $last"
        Department            = $row.Department.Trim()
        Path                  = $row.OU.Trim()
        AccountPassword       = $securePw
        ChangePasswordAtLogon = $true
        Enabled               = $true
        ErrorAction           = 'Stop'
    }

    if ($PSCmdlet.ShouldProcess($upn, "Create AD user in $($row.OU)")) {
        try {
            New-ADUser @params
            Write-Log "Created '$sam' ($first $last) in $($row.OU)."

            $group = $row.Group.Trim()
            if ($group) {
                try {
                    Add-ADGroupMember -Identity $group -Members $sam -ErrorAction Stop
                    Write-Log "Added '$sam' to group '$group'."
                }
                catch {
                    Write-Log "Created '$sam' but failed to add to group '$group': $($_.Exception.Message)" 'WARN'
                }
            }

            $results.Add([pscustomobject]@{
                SamAccountName    = $sam
                UserPrincipalName = $upn
                InitialPassword   = $password
                OU                = $row.OU
                Group             = $group
            })
            $created++
        }
        catch {
            Write-Log "Failed to create '$sam': $($_.Exception.Message)" 'ERROR'
            $failed++
        }
    }
}

# Export the generated passwords for secure hand-off.
if ($results.Count -gt 0 -and -not $WhatIfPreference) {
    $results | Export-Csv -Path $secretsFile -NoTypeInformation -Encoding UTF8
    Write-Log "Passwords exported to $secretsFile - store securely and delete after distribution."
}

Write-Log "Run complete. Created: $created  Skipped: $skipped  Failed: $failed"
