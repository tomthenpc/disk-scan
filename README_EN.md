# Disk Scan - Multi-thread Disk Capacity Scanner

English | [中文](README.md)

A PowerShell-based multi-threaded disk capacity scanner that queries remote devices' disk usage via SMB administrative shares, **automatically discovering all disk partitions**, and generating a CSV report sorted by severity.

> **Just want to run it?** After downloading, see [USAGE.txt](USAGE.txt) for a 3-step quick start (bilingual).

## Features

- **Multi-threaded scanning**: Based on RunspacePool, supports any number of concurrent threads; `ThreadDelay` paces job launch
- **Multi-credential support**: Configure multiple account/password combinations, automatically tries each until successful
- **External configuration**: Thread count, timeout, thresholds via `config.txt`; no script edits needed
- **Dynamic disk discovery**: Automatically enumerates all disk partitions on remote devices (C/D/E/F...), not limited to fixed drive letters
- **Unified classification**: All drives use the same level system (OK/WARN/HIGH/CRITICAL)
- **Pure Win32 API**: Uses `GetDiskFreeSpaceEx` for disk space queries, no COM dependency, thread-safe
- **Real-time progress**: Outputs results as each device completes, no waiting for full scan
- **Severity-sorted report**: CSV sorted by alert severity, most critical first
- **English headers**: CSV uses English headers for universal compatibility
- **Offline device tracking**: Offline devices listed separately in Need Attention section
- **Excel-friendly**: CSV with UTF-8 BOM encoding, opens correctly in Excel
- **Report directory**: Auto-creates `report/` folder, CSV saved inside
- **Portable deployment**: Extract and run, no external modules required
- **Non-interactive mode**: Auto-detects piped/CI environments, won't block on input

## Quick Start

### 1. Configure Credentials

**Only way: Edit `credentials.txt`**

`scan.ps1` does not contain any built-in credentials and does not support `credentials.ps1`. All credentials must be configured in `credentials.txt` only.

The project includes `credentials.txt` with placeholders. Open it in Notepad and fill in your real passwords, one credential per line:

```
# username,password (comma-separated)
administrator,your_password_1
administrator,your_password_2
admin,backup@2025

# No password:
administrator,

# Password with spaces, use quotes:
administrator," my password "
```

Lines starting with `#` are comments (auto-ignored). Supported separators: `,` `:` `|` or tab. **Security note: DO NOT commit real passwords to GitHub.**

### 2. Edit IP List

Edit `ip-list.txt`, one IP per line. Lines starting with `#` are comments (auto-ignored):

```
# Production network
192.168.1.10
192.168.1.11

# Test machines
172.16.0.100
```

### 3. Run

```powershell
# If you get "running scripts is disabled", run this once (one-time only):
# Set-ExecutionPolicy -Scope CurrentUser RemoteSigned

# Option 1: Right-click scan.ps1 → "Run with PowerShell"
# Option 2: Command line
.\scan.ps1
```

### 4. View Report

After scanning completes, a `report/` folder is auto-created and the CSV is saved as `report/disk-report-yyMMdd_HHmmss.csv` (per-second; if a collision occurs, a `-N` suffix is added).

## Configuration

Runtime settings are read from `config.txt`. Credentials stay in `credentials.txt`.

| Setting | File | Description | Default |
|---------|------|-------------|---------|
| `MaxThreads` | `config.txt` | Concurrent threads (1=sequential, >1=multi-thread) | 2 |
| `PingTimeout` | `config.txt` | Ping timeout (ms) | 1000 |
| `SeqDelay` | `config.txt` | Sequential mode delay (ms) | 500 |
| `ThreadDelay` | `config.txt` | Parallel mode launch interval (ms) | 50 |
| `Thresholds` | `config.txt` | Disk classification thresholds Warn/High/Critical | 50/70/85 |
| `Credentials` | `credentials.txt` | Account/password list, supports multiple | Placeholders |

**Note on `MaxThreads`:** There is no hard limit, but more threads means more concurrent SMB/network connections. For production networks use `2-4`; stable LANs can use `10-20`; above `50` may stress the network. Use `ThreadDelay` to reduce launch bursts.

## Status Codes

| Status | Meaning |
|--------|---------|
| `ONLINE` | Device online, disk info retrieved |
| `OFFLINE` | Ping failed (device off or network unreachable) |
| `AUTH_FAIL` | Ping succeeded but all credentials failed |

## Disk Classification

All drives use a unified classification system:

| Level | Condition | Meaning |
|-------|-----------|---------|
| `[OK]` | Usage < 50% | Healthy |
| `[WARN]` | 50% - 70% | Needs attention |
| `[HIGH]` | 70% - 85% | High usage |
| `[CRITICAL]` | >= 85% | Critical |

Thresholds are customizable via `config.txt` (`Thresholds`, `ThresholdWarn`, `ThresholdHigh`, `ThresholdCritical`).

## CSV Report

**Headers:**

```
IP, Status, Drive, Total_GB, Used_GB, Free_GB, Used_Pct, Level
```

**Note:** One row per drive. An IP with multiple partitions will have multiple rows. Offline/auth-fail devices have a single row (Drive is `-`).

**Sort order (by severity, highest first):**

1. OFFLINE devices
2. AUTH_FAIL (authentication failure)
3. Any drive [CRITICAL] (>= 85%)
4. Any drive [HIGH] (70% - 85%)
5. Any drive [WARN] (50% - 70%)
6. Drive [OK] (< 50%)

Within the same level, sorted by usage percentage descending.

## Requirements

- **Scanner**: Windows + PowerShell 5.1 or later (PowerShell 7 also compatible)
- **Target devices**: Windows with SMB administrative shares enabled (`C$`, `D$`, etc.)
- **Network**: SMB port 445 reachable from scanner to targets
- **Credentials**: Administrator account on target devices

### Troubleshooting

**"Running scripts is disabled on this system"**

Windows disables PowerShell scripts by default. Run this once:

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

**Target device has no admin shares (C$, etc.)**

Some systems disable admin shares by default. Enable via registry on the target:

```
HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System
LocalAccountTokenFilterPolicy = 1 (DWORD)
```

**Firewall blocking access**

Ensure the target firewall allows SMB (port 445) inbound. Domain environments typically allow this by default.

## Technical Details

| Component | Approach |
|-----------|----------|
| Multi-threading | RunspacePool (PowerShell 5.1 compatible) |
| Disk discovery | `net view \\IP` parses admin shares, auto-enumerates all drive letters |
| Network connection | `net use` (all output captured to avoid pipeline pollution) |
| Disk query | Win32 API `GetDiskFreeSpaceEx` (P/Invoke, no COM dependency) |
| Ping | `System.Net.NetworkInformation.Ping` (.NET, configurable timeout) |
| Credentials | Only `credentials.txt` (plain text); `scan.ps1` has no built-in credentials |

## Files

| File | Purpose |
|------|---------|
| `scan.ps1` | Main script |
| `ip-list.txt` | IP list (supports `#` comments) |
| `credentials.txt` | Credentials file (plain text, placeholders, only config source; DO NOT commit real passwords) |
| `report/` | Auto-created, holds CSV reports |
| `USAGE.txt` | Quick start guide (bilingual) |
| `README.md` | Full Chinese documentation |
| `README_EN.md` | This file (full English documentation) |
| `LICENSE` | MIT License |

## License

MIT License - see [LICENSE](LICENSE)

## Links

- [GitHub Repository](https://github.com/tomthenpc/disk-scan)
- [Report Issues](https://github.com/tomthenpc/disk-scan/issues)
