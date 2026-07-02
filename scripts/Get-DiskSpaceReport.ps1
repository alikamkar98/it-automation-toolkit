<#
.SYNOPSIS
    Checks free disk space across one or more servers and emails an HTML report
    when any fixed drive falls below a free-space threshold.

.DESCRIPTION
    Queries each target computer with CIM for its fixed (type 3) logical disks,
    calculates the percentage used, and builds a single HTML table. Rows for
    drives over the threshold are highlighted red. If at least one drive breaches
    the threshold the report is emailed; otherwise the script can optionally send
    an all-clear or stay silent.

    Uses Get-CimInstance (WSMan) rather than the deprecated Get-WmiObject, and
    accepts a PSCredential for querying remote servers.

.PARAMETER ComputerName
    One or more server names to query. Defaults to the local computer.

.PARAMETER ServerListPath
    Optional path to a text file with one server name per line. Combined with
    -ComputerName if both are supplied.

.PARAMETER ThresholdPercent
    Percent-used value that triggers an alert. Default 85.

.PARAMETER SmtpServer
    SMTP relay host used to send the report.

.PARAMETER From
    Sender address for the report email.

.PARAMETER To
    One or more recipient addresses.

.PARAMETER Credential
    Optional credential used for the remote CIM sessions.

.PARAMETER AlwaysSend
    Send the report even when no drive breaches the threshold (all-clear email).

.EXAMPLE
    .\Get-DiskSpaceReport.ps1 -ServerListPath .\servers.txt `
        -SmtpServer smtp.corp.local -From alerts@corp.local -To ops@corp.local

    Checks every server in servers.txt and emails ops if any drive is >85% full.

.EXAMPLE
    .\Get-DiskSpaceReport.ps1 -ComputerName DC01,FS01 -ThresholdPercent 90 `
        -SmtpServer smtp.corp.local -From alerts@corp.local -To me@corp.local -AlwaysSend

    Checks two named servers at a 90% threshold and always sends the report.

.NOTES
    Requires WinRM/CIM access to the targets and network access to the SMTP relay.
#>

[CmdletBinding()]
param(
    [string[]]$ComputerName = $env:COMPUTERNAME,

    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$ServerListPath,

    [ValidateRange(1, 99)]
    [int]$ThresholdPercent = 85,

    [Parameter(Mandatory = $true)]
    [string]$SmtpServer,

    [Parameter(Mandatory = $true)]
    [string]$From,

    [Parameter(Mandatory = $true)]
    [string[]]$To,

    [System.Management.Automation.PSCredential]$Credential,

    [switch]$AlwaysSend
)

# Build the final target list from the parameter and/or the file.
$targets = [System.Collections.Generic.List[string]]::new()
$ComputerName | ForEach-Object { $targets.Add($_) }
if ($ServerListPath) {
    Get-Content $ServerListPath |
        Where-Object { $_.Trim() -and -not $_.StartsWith('#') } |
        ForEach-Object { $targets.Add($_.Trim()) }
}
$targets = $targets | Select-Object -Unique

Write-Verbose "Checking $($targets.Count) target(s) at $ThresholdPercent% threshold."

$rows    = New-Object System.Collections.Generic.List[object]
$breach  = $false

foreach ($server in $targets) {
    try {
        $cimParams = @{
            ComputerName = $server
            ClassName    = 'Win32_LogicalDisk'
            Filter       = 'DriveType = 3'   # fixed local disks only
            ErrorAction  = 'Stop'
        }
        if ($Credential) { $cimParams.Credential = $Credential }

        $disks = Get-CimInstance @cimParams
        foreach ($d in $disks) {
            if (-not $d.Size) { continue }   # skip drives that report 0 size
            $usedPct  = [math]::Round((($d.Size - $d.FreeSpace) / $d.Size) * 100, 1)
            $freeGb   = [math]::Round($d.FreeSpace / 1GB, 1)
            $sizeGb   = [math]::Round($d.Size / 1GB, 1)
            $isBreach = $usedPct -ge $ThresholdPercent
            if ($isBreach) { $breach = $true }

            $rows.Add([pscustomobject]@{
                Server    = $server
                Drive     = $d.DeviceID
                'Size GB' = $sizeGb
                'Free GB' = $freeGb
                'Used %'  = $usedPct
                Breach    = $isBreach
            })
        }
    }
    catch {
        Write-Warning "Could not query '$server': $($_.Exception.Message)"
        $rows.Add([pscustomobject]@{
            Server = $server; Drive = 'N/A'; 'Size GB' = 0; 'Free GB' = 0
            'Used %' = 0; Breach = $true
        })
        $breach = $true
    }
}

# --- Build the HTML report -------------------------------------------------

$style = @"
<style>
    body  { font-family: Segoe UI, Arial, sans-serif; font-size: 14px; }
    table { border-collapse: collapse; width: 100%; }
    th    { background: #2c3e50; color: #fff; text-align: left; padding: 8px; }
    td    { padding: 8px; border-bottom: 1px solid #ddd; }
    tr.breach td { background: #f8d7da; color: #721c24; font-weight: bold; }
    .ok   { color: #155724; }
</style>
"@

$bodyRows = foreach ($r in ($rows | Sort-Object Server, Drive)) {
    $class = if ($r.Breach) { ' class="breach"' } else { '' }
    "<tr$class><td>$($r.Server)</td><td>$($r.Drive)</td><td>$($r.'Size GB')</td>" +
    "<td>$($r.'Free GB')</td><td>$($r.'Used %')</td></tr>"
}

$html = @"
<html><head>$style</head><body>
<h2>Disk Space Report - $(Get-Date -Format 'yyyy-MM-dd HH:mm')</h2>
<p>Threshold: <b>$ThresholdPercent%</b> used. Highlighted rows require attention.</p>
<table>
<tr><th>Server</th><th>Drive</th><th>Size GB</th><th>Free GB</th><th>Used %</th></tr>
$($bodyRows -join "`n")
</table>
<p class="ok">$(if ($breach) { '' } else { 'All drives are within limits.' })</p>
</body></html>
"@

# --- Send (or skip) --------------------------------------------------------

if ($breach -or $AlwaysSend) {
    $subject = if ($breach) {
        "[ALERT] Disk space breach on one or more servers"
    } else {
        "[OK] Disk space report - all clear"
    }
    try {
        Send-MailMessage -SmtpServer $SmtpServer -From $From -To $To `
            -Subject $subject -Body $html -BodyAsHtml -ErrorAction Stop
        Write-Host "Report emailed to $($To -join ', ')."
    }
    catch {
        Write-Error "Failed to send report: $($_.Exception.Message)"
    }
}
else {
    Write-Host "No breaches found and -AlwaysSend not set; no email sent."
}

# Also emit the objects so the script is usable in a pipeline.
$rows
