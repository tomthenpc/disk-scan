# Helper: pause for user in interactive console, but never block CI/pipelines
function Wait-IfInteractive {
    try {
        $null = Read-Host "Press Enter to exit..."
    } catch {
        # Non-interactive host or pipeline stopped; continue without blocking
    }
}

# Register Win32 API FIRST, before any error preference changes
try {
    if (-not ([System.Management.Automation.PSTypeName]'DiskSpaceAPI').Type) {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class DiskSpaceAPI {
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Auto)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetDiskFreeSpaceEx(
        string lpDirectoryName,
        out ulong lpFreeBytesAvailable,
        out ulong lpTotalNumberOfBytes,
        out ulong lpTotalNumberOfFreeBytes);

    public static long[] GetSpace(string path) {
        ulong free, total, totalFree;
        if (GetDiskFreeSpaceEx(path, out free, out total, out totalFree)) {
            return new long[] { (long)free, (long)total, (long)totalFree };
        }
        return null;
    }
}
"@
    }
} catch {
    Write-Host "FATAL: Failed to register Win32 API. $($_.Exception.Message)" -ForegroundColor Red
    Wait-IfInteractive
    exit 1
}

$ErrorActionPreference = 'SilentlyContinue'

# Set console output to UTF-8 to avoid Chinese garbling; swallow errors in non-console hosts
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

# ============================================================
#  Disk Capacity Scanner - Multi-thread SMB scanner
#  https://github.com/tomthenpc/disk-scan
# ============================================================

# Use script's directory for all files
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ipFile = Join-Path $scriptDir "ip-list.txt"
$credTxtFile = Join-Path $scriptDir "credentials.txt"
$configFile = Join-Path $scriptDir "config.txt"
$reportDir = Join-Path $scriptDir "report"

# Create report directory if it doesn't exist
if (-not (Test-Path $reportDir)) {
    New-Item -ItemType Directory -Path $reportDir | Out-Null
}

# Generate a unique report file name (per-second; append -N if collision)
$ts = Get-Date -Format "yyMMdd_HHmmss"
$outFile = Join-Path $reportDir "disk-report-$ts.csv"
if (Test-Path $outFile) {
    $n = 1
    do {
        $outFile = Join-Path $reportDir "disk-report-$ts-$n.csv"
        $n++
    } while (Test-Path $outFile)
}

# ===== Configuration (defaults, can be overridden by config.txt) =====
$Config = @{
    MaxThreads        = 2
    PingTimeout       = 1000
    SeqDelay          = 500
    ThreadDelay       = 50
    ThresholdWarn     = 50
    ThresholdHigh     = 70
    ThresholdCritical = 85
}

function Read-ConfigInt($value, $min, $max) {
    $parsed = 0
    if (-not [int]::TryParse($value, [ref]$parsed)) {
        return $null
    }
    if ($min -ne $null -and $parsed -lt $min) { return $null }
    if ($max -ne $null -and $parsed -gt $max) { return $null }
    return $parsed
}

# Load user config from config.txt if present
$configErrors = [System.Collections.Generic.List[string]]::new()
if (Test-Path $configFile) {
    foreach ($rawLine in Get-Content $configFile -Encoding UTF8) {
        $line = $rawLine.Trim()
        if ($line -eq '' -or $line.StartsWith('#')) { continue }
        if ($line -match '^(.*?)\s*=\s*(.*)$') {
            $key = $matches[1].Trim()
            $value = $matches[2].Trim()
            switch ($key) {
                'MaxThreads' {
                    $v = Read-ConfigInt $value 1 $null
                    if ($v -eq $null) { $configErrors.Add('MaxThreads must be an integer >= 1') } else { $Config.MaxThreads = $v }
                }
                'PingTimeout' {
                    $v = Read-ConfigInt $value 1 $null
                    if ($v -eq $null) { $configErrors.Add('PingTimeout must be an integer >= 1') } else { $Config.PingTimeout = $v }
                }
                'SeqDelay' {
                    $v = Read-ConfigInt $value 0 $null
                    if ($v -eq $null) { $configErrors.Add('SeqDelay must be an integer >= 0') } else { $Config.SeqDelay = $v }
                }
                'ThreadDelay' {
                    $v = Read-ConfigInt $value 0 $null
                    if ($v -eq $null) { $configErrors.Add('ThreadDelay must be an integer >= 0') } else { $Config.ThreadDelay = $v }
                }
                'ThresholdWarn' {
                    $v = Read-ConfigInt $value 0 100
                    if ($v -eq $null) { $configErrors.Add('ThresholdWarn must be an integer between 0 and 100') } else { $Config.ThresholdWarn = $v }
                }
                'ThresholdHigh' {
                    $v = Read-ConfigInt $value 0 100
                    if ($v -eq $null) { $configErrors.Add('ThresholdHigh must be an integer between 0 and 100') } else { $Config.ThresholdHigh = $v }
                }
                'ThresholdCritical' {
                    $v = Read-ConfigInt $value 0 100
                    if ($v -eq $null) { $configErrors.Add('ThresholdCritical must be an integer between 0 and 100') } else { $Config.ThresholdCritical = $v }
                }
                'Thresholds' {
                    $parts = $value -split ',' | ForEach-Object { $_.Trim() }
                    if ($parts.Count -ge 1 -and $parts[0] -ne '') {
                        $v = Read-ConfigInt $parts[0] 0 100
                        if ($v -eq $null) { $configErrors.Add('Thresholds first value (Warn) must be 0-100') } else { $Config.ThresholdWarn = $v }
                    }
                    if ($parts.Count -ge 2 -and $parts[1] -ne '') {
                        $v = Read-ConfigInt $parts[1] 0 100
                        if ($v -eq $null) { $configErrors.Add('Thresholds second value (High) must be 0-100') } else { $Config.ThresholdHigh = $v }
                    }
                    if ($parts.Count -ge 3 -and $parts[2] -ne '') {
                        $v = Read-ConfigInt $parts[2] 0 100
                        if ($v -eq $null) { $configErrors.Add('Thresholds third value (Critical) must be 0-100') } else { $Config.ThresholdCritical = $v }
                    }
                }
            }
        }
    }
}

# Validate threshold ordering
if ($Config.ThresholdWarn -ge $Config.ThresholdHigh -or $Config.ThresholdHigh -ge $Config.ThresholdCritical) {
    $configErrors.Add('Thresholds must be ordered: Warn < High < Critical')
}

if ($configErrors.Count -gt 0) {
    Write-Host "config.txt has errors:" -ForegroundColor Red
    foreach ($err in $configErrors) { Write-Host "  - $err" -ForegroundColor Yellow }
    Wait-IfInteractive
    exit 1
}

$MaxThreads        = $Config.MaxThreads
$PingTimeout       = $Config.PingTimeout
$SeqDelay          = $Config.SeqDelay
$ThreadDelay       = $Config.ThreadDelay
$Thresholds = @{
    Warn     = $Config.ThresholdWarn
    High     = $Config.ThresholdHigh
    Critical = $Config.ThresholdCritical
}

# ===== Credentials (REQUIRED) =====
# Account and password can ONLY be configured in credentials.txt.
# scan.ps1 does not contain and does not accept hard-coded credentials.
# Format: one credential per line: username,password
# Supported separators: comma, colon, pipe, or tab
# Values may be quoted with double quotes to preserve leading/trailing spaces
# Examples:
#   administrator,mypassword123
#   admin,backup@2025
#   admin,
#   admin," my password with spaces "
if (-not (Test-Path $credTxtFile)) {
    Write-Host "Credentials file not found: $credTxtFile" -ForegroundColor Red
    Write-Host "Please create it with your target device credentials." -ForegroundColor Yellow
    Write-Host "Format: username,password (one per line)" -ForegroundColor Yellow
    Wait-IfInteractive
    exit 1
}

$Credentials = @()
$invalidLines = [System.Collections.Generic.List[string]]::new()
foreach ($rawLine in Get-Content $credTxtFile -Encoding UTF8) {
    $line = $rawLine.Trim()
    if ($line -eq '' -or $line.StartsWith('#')) { continue }
    # Regex supports quoted values to preserve spaces, or unquoted values
    # Also allows empty password:  admin,
    if ($line -match '^\s*(?:"([^"]*)"|([^,\:\|\t]+?))\s*[,\:\|\t]\s*(?:"([^"]*)"|(.*))$') {
        if ($matches[1] -ne $null) {
            $u = $matches[1].Trim()
        } else {
            $u = $matches[2].Trim()
        }
        if ($matches[3] -ne $null) {
            $p = $matches[3]
        } else {
            $p = $matches[4].Trim()
        }
        $Credentials += @{ User = $u; Password = $p }
    } else {
        $invalidLines.Add($rawLine)
    }
}

if ($invalidLines.Count -gt 0) {
    Write-Host "WARNING: credentials.txt has invalid lines (skipped):" -ForegroundColor Yellow
    foreach ($l in $invalidLines) { Write-Host "  $l" -ForegroundColor DarkYellow }
}

if ($Credentials.Count -eq 0) {
    Write-Host "No valid credentials found in: $credTxtFile" -ForegroundColor Red
    Wait-IfInteractive
    exit 1
}

$hasPlaceholder = $false
foreach ($cred in $Credentials) {
    if ($cred.Password -like 'YOUR_PASSWORD_*') { $hasPlaceholder = $true; break }
}
if ($hasPlaceholder) {
    Write-Host "WARNING: credentials.txt still contains placeholders (YOUR_PASSWORD_*)." -ForegroundColor Yellow
    Write-Host "Please edit $credTxtFile with real passwords before running." -ForegroundColor Yellow
    Wait-IfInteractive
    exit 1
}

$credSource = "credentials.txt ($($Credentials.Count) credentials)"

# ===== Check IP file =====
if (-not (Test-Path $ipFile)) {
    Write-Host "IP file not found: $ipFile" -ForegroundColor Red
    Write-Host "Please create ip-list.txt in the same folder as this script." -ForegroundColor Yellow
    Write-Host "One IP per line. Lines starting with # are ignored." -ForegroundColor Yellow
    Wait-IfInteractive
    exit 1
}

# ===== Helper functions =====

function Get-Color($level) {
    if ($level -like '*CRITICAL*') { return 'Red' }
    if ($level -like '*HIGH*')     { return 'Magenta' }
    if ($level -like '*WARN*')     { return 'Yellow' }
    return 'Green'
}

# ===== Worker script block - COMPLETELY self-contained =====
$worker = {
    param($ip, $credentials, $pingTimeout, $thresholds)

    $ErrorActionPreference = 'SilentlyContinue'

    $rows = [System.Collections.Generic.List[PSObject]]::new()

    function New-DriveRow($ip, $status, $drive, $totalGB, $usedGB, $freeGB, $usedPct, $level) {
        return [PSCustomObject]@{
            IP        = $ip
            Status    = $status
            Drive     = $drive
            Total_GB  = $totalGB
            Used_GB   = $usedGB
            Free_GB   = $freeGB
            Used_Pct  = $usedPct
            Level     = $level
        }
    }

    function Get-Level($usePct, $thresholds) {
        if ($usePct -ge $thresholds.Critical) { return '[CRITICAL]' }
        if ($usePct -ge $thresholds.High)     { return '[HIGH]' }
        if ($usePct -ge $thresholds.Warn)     { return '[WARN]' }
        return '[OK]'
    }

    # Ping
    $pingObj = New-Object System.Net.NetworkInformation.Ping
    try { $pingReply = $pingObj.Send($ip, $pingTimeout) } catch { $pingReply = $null }
    if (-not $pingReply -or $pingReply.Status -ne 'Success') {
        $rows.Add((New-DriveRow $ip 'OFFLINE' '-' '' '' '' '' 'N/A'))
        return $rows
    }

    # Try each credential until one works; prefer IPC$ then C$ for broader compatibility
    $connected = $false
    $authPath = $null
    $authCandidates = @("\\$ip\ipc$", "\\$ip\c$")

    :authLoop foreach ($cred in $credentials) {
        foreach ($candidate in $authCandidates) {
            $null = net use $candidate /delete 2>&1
            if ([string]::IsNullOrEmpty($cred.Password)) {
                $out = net use $candidate /user:$($cred.User) '""' 2>&1
            } else {
                $out = net use $candidate /user:$($cred.User) $($cred.Password) 2>&1
            }
            if ($LASTEXITCODE -eq 0) {
                $connected = $true
                $authPath = $candidate
                break authLoop
            }
        }
    }

    if (-not $connected) {
        $rows.Add((New-DriveRow $ip 'AUTH_FAIL' '-' '' '' '' '' 'N/A'))
        return $rows
    }

    # ===== Discover all drives via "net view \\IP" =====
    $driveLetters = [System.Collections.Generic.List[string]]::new()
    $viewOut = net view "\\$ip" 2>&1
    foreach ($line in $viewOut) {
        if ($line -match '^([A-Z])\$\s') {
            $driveLetters.Add($matches[1] + ':')
        }
    }

    # Fallback: if net view didn't find any drives, try C/D/E/F/G directly
    if ($driveLetters.Count -eq 0) {
        $driveLetters.Add('C:')
        $driveLetters.Add('D:')
        $driveLetters.Add('E:')
        $driveLetters.Add('F:')
        $driveLetters.Add('G:')
    }

    # Query each discovered drive via GetDiskFreeSpaceEx
    foreach ($drive in $driveLetters) {
        $driveUnc = "\\$ip\$($drive.Replace(':','$'))"
        try {
            $space = [DiskSpaceAPI]::GetSpace($driveUnc)
            if ($space -ne $null -and $space[1] -gt 0) {
                $freeBytes = $space[0]
                $totalBytes = $space[1]
                $usedBytes = $totalBytes - $freeBytes
                $totalGB = [Math]::Round($totalBytes / 1GB, 1)
                $freeGB = [Math]::Round($freeBytes / 1GB, 1)
                $usedGB = [Math]::Round($usedBytes / 1GB, 1)
                $usedPct = [Math]::Round($usedBytes / $totalBytes * 100, 1)
                $level = Get-Level $usedPct $thresholds
                $rows.Add((New-DriveRow $ip 'ONLINE' $drive $totalGB $usedGB $freeGB $usedPct $level))
            }
        } catch {}
    }

    # If no drives were accessible at all
    if ($rows.Count -eq 0) {
        $rows.Add((New-DriveRow $ip 'ONLINE' '-' '' '' '' '' 'N/A'))
    }

    # Disconnect all - capture ALL output to avoid polluting pipeline
    if ($authPath) {
        $null = net use $authPath /delete 2>&1
    }
    foreach ($drive in $driveLetters) {
        $null = net use "\\$ip\$($drive.Replace(':','$'))" /delete 2>&1
    }

    return $rows
}

# ===== Read IP list (filter comments and empty lines) =====
$ips = Get-Content $ipFile -Encoding UTF8 | ForEach-Object {
    $line = $_.Trim()
    if ($line -ne '' -and -not $line.StartsWith('#')) { $line }
}
$total = @($ips).Count

if ($total -eq 0) {
    Write-Host "No valid IPs found in: $ipFile" -ForegroundColor Red
    Write-Host "Please add at least one IP address." -ForegroundColor Yellow
    Write-Host "Lines starting with # are treated as comments." -ForegroundColor Yellow
    Wait-IfInteractive
    exit 1
}

# ===== Header =====
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host " Disk Capacity Scanner" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "IP file:     $ipFile"
Write-Host "Report:      $outFile"
Write-Host "Total IPs:   $total"
Write-Host "Threads:     $MaxThreads"
Write-Host "Ping:        ${PingTimeout}ms"
Write-Host "Thresholds:  W=$($Thresholds.Warn)% H=$($Thresholds.High)% C=$($Thresholds.Critical)%"
Write-Host "ThreadDelay: ${ThreadDelay}ms (parallel launch pacing)"
Write-Host "Credentials: $credSource"
$estSec = [Math]::Round($total * 1.5 / $MaxThreads, 0)
$estMin = [Math]::Floor($estSec / 60)
$estRem = $estSec % 60
$estStr = if ($estMin -gt 0) { "${estMin}m ${estRem}s" } else { "${estSec}s" }
Write-Host "Est. time:   ~$estStr" -ForegroundColor Yellow
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""

# Results: one row per (IP, Drive) - flat list
$results = [System.Collections.Generic.List[PSObject]]::new()

function Format-Result($rows, $idx, $total) {
    if ($rows.Count -eq 0) { return }
    $ip = $rows[0].IP
    $status = $rows[0].Status

    $color = switch ($status) {
        'OFFLINE'   { 'DarkGray'; break }
        'AUTH_FAIL' { 'Yellow'; break }
        default {
            $worst = '[OK]'
            foreach ($r in $rows) {
                if ($r.Level -like '*CRITICAL*') { $worst = '[CRITICAL]'; break }
                if ($r.Level -like '*HIGH*' -and $worst -notlike '*CRITICAL*') { $worst = '[HIGH]' }
                if ($r.Level -like '*WARN*' -and $worst -notlike '*CRITICAL*' -and $worst -notlike '*HIGH*') { $worst = '[WARN]' }
            }
            if ($worst -like '*CRITICAL*') { 'Red' }
            elseif ($worst -like '*HIGH*') { 'Magenta' }
            elseif ($worst -like '*WARN*') { 'Yellow' }
            else { 'Green' }
        }
    }

    if ($status -eq 'OFFLINE' -or $status -eq 'AUTH_FAIL') {
        Write-Host "[$idx/$total] $ip - $status" -ForegroundColor $color
    } else {
        $parts = @($rows | ForEach-Object { "$($_.Drive):$($_.Used_Pct)%($($_.Level))" })
        $driveStr = $parts -join ' | '
        Write-Host "[$idx/$total] $ip - $status $driveStr" -ForegroundColor $color
    }
}

# ===== Main scan logic (wrapped in try-catch to prevent flash-exit) =====
try {
    if ($MaxThreads -le 1) {
        # Sequential mode
        $done = 0
        foreach ($ip in $ips) {
            $done++
            $rows = & $worker $ip $Credentials $PingTimeout $Thresholds
            foreach ($r in $rows) { $results.Add($r) }
            Format-Result $rows $done $total
            Start-Sleep -Milliseconds $SeqDelay
        }
    } else {
        # Multi-thread mode using RunspacePool
        $runspacePool = [RunspaceFactory]::CreateRunspacePool(1, $MaxThreads)
        $runspacePool.Open()
        $jobs = [System.Collections.Generic.List[PSObject]]::new()

        $submitted = 0
        foreach ($ip in $ips) {
            $submitted++
            $ps = [PowerShell]::Create()
            $ps.RunspacePool = $runspacePool
            $null = $ps.AddScript($worker).AddArgument($ip).AddArgument($Credentials).AddArgument($PingTimeout).AddArgument($Thresholds)
            $job = [PSCustomObject]@{
                IP = $ip
                Pipe = $ps
                Handle = $ps.BeginInvoke()
                Done = $false
            }
            $jobs.Add($job)

            # Pace job submission to avoid a thundering herd when MaxThreads is high
            if ($ThreadDelay -gt 0 -and $submitted -lt $total) {
                Start-Sleep -Milliseconds $ThreadDelay
            }
        }

        # Poll for completed jobs - real-time display
        $completed = 0
        while ($completed -lt $jobs.Count) {
            for ($i = 0; $i -lt $jobs.Count; $i++) {
                $job = $jobs[$i]
                if (-not $job.Done -and $job.Handle.IsCompleted) {
                    $job.Done = $true
                    $completed++
                    $rows = $job.Pipe.EndInvoke($job.Handle)
                    $job.Pipe.Dispose()
                    if ($rows -and $rows.Count -gt 0) {
                        foreach ($r in $rows) { $results.Add($r) }
                        Format-Result $rows $completed $total
                    }
                }
            }
            if ($completed -lt $jobs.Count) {
                Start-Sleep -Milliseconds 100
            }
        }
        $runspacePool.Close()
        $runspacePool.Dispose()
    }

    # ===== Sort by severity =====
    function Get-SeverityRank($r) {
        if ($r.Status -eq 'OFFLINE')   { return 0 }
        if ($r.Status -eq 'AUTH_FAIL') { return 1 }
        if ($r.Level -eq '[CRITICAL]') { return 2 }
        if ($r.Level -eq '[HIGH]')     { return 3 }
        if ($r.Level -eq '[WARN]')     { return 4 }
        if ($r.Level -eq '[OK]')       { return 5 }
        return 6
    }

    $sorted = $results | ForEach-Object {
        $_ | Add-Member -NotePropertyName 'Rank' -NotePropertyValue (Get-SeverityRank $_) -PassThru
    } | Sort-Object @{Expression='Rank'; Ascending=$true},
        @{Expression={ if ($_.Used_Pct -ne '') { [double]$_.Used_Pct } else { 0 } }; Descending=$true}

    # ===== Export CSV =====
    $csvData = $sorted | ForEach-Object {
        [PSCustomObject]@{
            'IP'        = $_.IP
            'Status'    = $_.Status
            'Drive'     = $_.Drive
            'Total_GB'  = $_.Total_GB
            'Used_GB'   = $_.Used_GB
            'Free_GB'   = $_.Free_GB
            'Used_Pct'  = $_.Used_Pct
            'Level'     = $_.Level
        }
    }

    $csvText = $csvData | ConvertTo-Csv -NoTypeInformation
    $utf8bom = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllLines($outFile, $csvText, $utf8bom)

    Write-Host ""
    Write-Host "Done! Report saved to: $outFile" -ForegroundColor Green
    Write-Host ""

    # ===== Summary =====
    $onlineIPs = ($results | Where-Object { $_.Status -eq 'ONLINE' } | Select-Object -ExpandProperty IP -Unique).Count
    $offlineIPs = ($results | Where-Object { $_.Status -eq 'OFFLINE' } | Select-Object -ExpandProperty IP -Unique).Count
    $authFailIPs = ($results | Where-Object { $_.Status -eq 'AUTH_FAIL' } | Select-Object -ExpandProperty IP -Unique).Count

    Write-Host "=== Summary ===" -ForegroundColor Cyan
    Write-Host "Online:      $onlineIPs"
    Write-Host "Offline:     $offlineIPs"
    Write-Host "Auth Fail:   $authFailIPs"
    Write-Host ""

    # Drive level distribution
    Write-Host "=== Drive Levels ===" -ForegroundColor Cyan
    $levels = @('[CRITICAL]','[HIGH]','[WARN]','[OK]')
    foreach ($label in $levels) {
        $cnt = ($results | Where-Object { $_.Level -eq $label }).Count
        $color = Get-Color($label)
        Write-Host "  ${label}: $cnt" -ForegroundColor $color
    }

    # Need Attention
    $attentionIPs = $results | Where-Object {
        $_.Status -ne 'ONLINE' -or
        $_.Level -eq '[HIGH]' -or
        $_.Level -eq '[CRITICAL]'
    } | Select-Object -ExpandProperty IP -Unique

    if ($attentionIPs.Count -gt 0) {
        Write-Host ""
        Write-Host "=== Need Attention ===" -ForegroundColor Red
        Write-Host "  (Offline / Auth Fail / Any drive >= 70%)" -ForegroundColor DarkRed
        Write-Host ""

        $off = $results | Where-Object { $_.Status -eq 'OFFLINE' } | Select-Object -ExpandProperty IP -Unique
        if ($off.Count -gt 0) {
            Write-Host "  --- OFFLINE ---" -ForegroundColor DarkGray
            $off | ForEach-Object { Write-Host "    $_" }
        }

        $af = $results | Where-Object { $_.Status -eq 'AUTH_FAIL' } | Select-Object -ExpandProperty IP -Unique
        if ($af.Count -gt 0) {
            Write-Host "  --- AUTH FAIL ---" -ForegroundColor Yellow
            $af | ForEach-Object { Write-Host "    $_" }
        }

        $alertDrives = $results | Where-Object { $_.Level -eq '[HIGH]' -or $_.Level -eq '[CRITICAL]' } |
            Sort-Object @{Expression={ if ($_.Used_Pct -ne '') { [double]$_.Used_Pct } else { 0 } }; Descending=$true}
        if ($alertDrives.Count -gt 0) {
            Write-Host "  --- Drive >= 70% ---" -ForegroundColor Red
            $alertDrives | Format-Table IP, Drive, Used_Pct, Level, Total_GB, Free_GB -AutoSize
        }
    }

} catch {
    Write-Host ""
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ""
    Write-Host "Full error:" -ForegroundColor DarkRed
    Write-Host $_ -ForegroundColor DarkRed
    Wait-IfInteractive
    exit 1
}

# Pause only in interactive sessions - prevents flash-exit when run via right-click
# while allowing CI/scheduled tasks to exit cleanly
Write-Host ""
Wait-IfInteractive
