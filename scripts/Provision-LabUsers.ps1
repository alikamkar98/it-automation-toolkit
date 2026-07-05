<#
.SYNOPSIS
    Bulk-provisions a realistic organisation in Active Directory: departments (OUs),
    role-based security groups, ~50 users (regular staff, IT, and privileged admins),
    then generates a summary and an HTML user-directory report.

.DESCRIPTION
    Demonstrates identity management at scale. Creates the OU/group structure if it
    does not exist, then loops through name pools to create users, places each in its
    department OU, assigns the matching security group, and promotes a subset of IT
    staff into Domain Admins. Idempotent-friendly (skips accounts that already exist).

.PARAMETER Count
    Number of users to create (default 50).

.PARAMETER ReportPath
    Folder for the log and the HTML directory report (default: the script folder).

.EXAMPLE
    .\Provision-LabUsers.ps1 -WhatIf      # preview, change nothing
    .\Provision-LabUsers.ps1              # create the accounts

.NOTES
    Lab use. Requires the ActiveDirectory module and rights to create objects.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateRange(1, 500)] [int]$Count = 50,
    [string]$ReportPath = $PSScriptRoot
)

Import-Module ActiveDirectory -ErrorAction Stop
$dn  = (Get-ADDomain).DistinguishedName
$log = Join-Path $ReportPath ("Provision-LabUsers-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))
function Log($m){ $l="{0}  {1}" -f (Get-Date -Format s),$m; Add-Content $log $l; Write-Host $l }

# --- Departments (OUs) and their security groups ---
$deptGroup = [ordered]@{
    "IT"          = "IT-Admins"
    "Sales"       = "Sales-Team"
    "HR"          = "HR-Team"
    "Finance"     = "Finance-Team"
    "Engineering" = "Engineering-Team"
    "Marketing"   = "Marketing-Team"
}
$depts = @($deptGroup.Keys)

foreach ($ou in $depts) {
    if (-not (Get-ADOrganizationalUnit -Filter "Name -eq '$ou'" -SearchBase $dn -ErrorAction SilentlyContinue)) {
        if ($PSCmdlet.ShouldProcess("OU=$ou", "Create OU")) {
            New-ADOrganizationalUnit -Name $ou -Path $dn -ProtectedFromAccidentalDeletion $false
            Log "Created OU '$ou'."
        }
    }
}
foreach ($ou in $depts) {
    $g = $deptGroup[$ou]
    if (-not (Get-ADGroup -Filter "Name -eq '$g'" -ErrorAction SilentlyContinue)) {
        if ($PSCmdlet.ShouldProcess($g, "Create group")) {
            New-ADGroup -Name $g -GroupScope Global -Path "OU=$ou,$dn"
            Log "Created group '$g'."
        }
    }
}

# --- Name pools (50 each) ---
$firsts = "James","Mary","John","Patricia","Robert","Jennifer","Michael","Linda","William","Elizabeth",
          "David","Barbara","Richard","Susan","Joseph","Jessica","Thomas","Sarah","Charles","Karen",
          "Christopher","Nancy","Daniel","Lisa","Matthew","Betty","Anthony","Sandra","Mark","Ashley",
          "Donald","Kimberly","Steven","Emily","Paul","Donna","Andrew","Michelle","Joshua","Carol",
          "Kenneth","Amanda","Kevin","Melissa","Brian","Deborah","George","Stephanie","Edward","Rebecca"
$lasts  = "Smith","Johnson","Williams","Brown","Jones","Garcia","Miller","Davis","Rodriguez","Martinez",
          "Hernandez","Lopez","Gonzalez","Wilson","Anderson","Thomas","Taylor","Moore","Jackson","Martin",
          "Lee","Perez","Thompson","White","Harris","Sanchez","Clark","Ramirez","Lewis","Robinson",
          "Walker","Young","Allen","King","Wright","Scott","Torres","Nguyen","Hill","Flores",
          "Green","Adams","Nelson","Baker","Hall","Rivera","Campbell","Mitchell","Carter","Roberts"

$pw = ConvertTo-SecureString "P@ssw0rd-Lab!" -AsPlainText -Force
$made = 0; $admins = 0; $skipped = 0

for ($i = 0; $i -lt $Count; $i++) {
    $f = $firsts[$i % $firsts.Count]
    $l = $lasts[$i % $lasts.Count]
    $dept = $depts[$i % $depts.Count]
    $isAdmin = ($dept -eq "IT" -and ($i % 12 -eq 0))   # a few IT staff are privileged admins

    $sam = ("{0}{1}" -f $f.Substring(0,1), $l).ToLower() -replace '[^a-z0-9]',''
    $base = $sam; $n = 1
    while (Get-ADUser -Filter "SamAccountName -eq '$sam'" -ErrorAction SilentlyContinue) { $sam = "$base$n"; $n++ }

    $title = if ($isAdmin) { "IT Administrator" } else { "$dept Specialist" }
    if ($PSCmdlet.ShouldProcess("$sam ($dept)", "Create AD user")) {
        try {
            New-ADUser -Name "$f $l" -GivenName $f -Surname $l -SamAccountName $sam `
                -UserPrincipalName "$sam@$((Get-ADDomain).DNSRoot)" -DisplayName "$f $l" `
                -Department $dept -Title $title -Company "RITZ Lab" `
                -Path "OU=$dept,$dn" -AccountPassword $pw -Enabled $true -ChangePasswordAtLogon $true -ErrorAction Stop
            Add-ADGroupMember -Identity $deptGroup[$dept] -Members $sam -ErrorAction SilentlyContinue
            if ($isAdmin) { Add-ADGroupMember -Identity "Domain Admins" -Members $sam -ErrorAction SilentlyContinue; $admins++ }
            $made++
        } catch { Log "SKIP $sam : $($_.Exception.Message)"; $skipped++ }
    }
}
Log "Provisioning complete. Created: $made  Admins: $admins  Skipped: $skipped  Departments: $($depts.Count)"

if (-not $WhatIfPreference) {
    # --- Summary tables ---
    Write-Host "`n=== Users per department ==="
    $depts | ForEach-Object {
        [pscustomobject]@{ Department=$_; Users=(Get-ADUser -Filter * -SearchBase "OU=$_,$dn").Count }
    } | Format-Table -AutoSize

    Write-Host "=== Security group membership ==="
    ($deptGroup.Values + "Domain Admins") | ForEach-Object {
        [pscustomobject]@{ Group=$_; Members=(Get-ADGroupMember $_ -ErrorAction SilentlyContinue | Measure-Object).Count }
    } | Format-Table -AutoSize

    "`nTotal enabled users in domain: " + (Get-ADUser -Filter 'Enabled -eq $true').Count | Write-Host

    # --- HTML user directory report (nice artifact to screenshot) ---
    $html = Join-Path $ReportPath "lab-user-directory.html"
    $style = "<style>body{font-family:Segoe UI,Arial;font-size:13px} h2{color:#16324f}
              table{border-collapse:collapse;width:100%} th{background:#16324f;color:#fff;text-align:left;padding:6px}
              td{padding:6px;border-bottom:1px solid #ddd}</style>"
    Get-ADUser -Filter * -Properties Department,Title -SearchBase $dn |
        Where-Object { $_.Department } |
        Select-Object @{N='Name';E={$_.Name}}, SamAccountName, Department, Title |
        Sort-Object Department, Name |
        ConvertTo-Html -Head $style -PreContent "<h2>lab.local &mdash; User Directory ($((Get-ADUser -Filter 'Enabled -eq $true').Count) accounts)</h2><p>Auto-generated by Provision-LabUsers.ps1 on $(Get-Date -Format 'yyyy-MM-dd HH:mm')</p>" |
        Out-File $html -Encoding UTF8
    Log "HTML directory written to $html"
    Write-Host "`nOpen the report:  start $html"
}
