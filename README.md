# FlashBlade Filesystem Failover

**This is a prototype only and is not intended for production use. It is provided as-is with no warranty or support. Use at your own risk.**

Automates Pure Storage FlashBlade filesystem failover and failback using the REST API (v2.25), including DNS CNAME updates and Kerberos SPN management.

## Overview

`Invoke-FBFailover.ps1` performs the following steps:

1. Connects to the target FlashBlade and validates the filesystem is demoted
2. Displays replica link status (informational)
3. Promotes the target filesystem
4. Polls until promotion completes (or times out)
5. If the source array is reachable, demotes the source filesystem
6. Moves Kerberos SPNs between AD computer accounts (`setspn.exe`)
7. Updates the DNS CNAME to point to the target array
8. Verifies DNS resolution
9. Prints a summary report with PASS/FAIL/WARN/SKIP per step

All output is captured to a timestamped transcript log (`FBFailover_*.log`).

## Prerequisites

- **PowerShell 7+** (PowerShell Core) -- tested on Windows and macOS
- **FlashBlade REST API access** -- management VIP hostname and API token for each array
- **Windows (domain-joined)** for full SPN and DNS functionality:
  - `setspn.exe` (included with Windows)
  - `DnsServer` PowerShell module (RSAT: DNS Server Tools)
- **macOS/Linux** -- filesystem promotion and demotion work fully; SPN and DNS updates are skipped with manual instructions displayed

### Installing RSAT DNS Tools (Windows)

```powershell
# Windows 10/11 / Server 2019+
Add-WindowsCapability -Online -Name Rsat.Dns.Tools~~~~0.0.1.0
```

## Configuration

Configuration is stored in PSD1 files (PowerShell Data Files). Two configs are provided:

| File | Direction | Purpose |
|------|-----------|---------|
| `failover-config.psd1` | PrimaryToDR | Fail over from primary to DR site |
| `failback-config.psd1` | DRToPrimary | Fail back from DR to primary site |

### Config Structure

```powershell
@{
    FailoverDirection = "PrimaryToDR"   # or "DRToPrimary"

    Source = @{
        Hostname   = "primary-mgmt.example.com"   # Management VIP
        ApiToken   = "T-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
        FileSystem = "myfs01"
    }

    Target = @{
        Hostname   = "dr-mgmt.example.com"        # Management VIP
        ApiToken   = "T-yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy"
        FileSystem = "myfs01"
    }

    Dns = @{
        ZoneName       = "example.com"
        RecordName     = "fileserver"               # CNAME record name
        SourceTarget   = "primary-a.example.com"    # Current CNAME target
        FailoverTarget = "dr-a.example.com"         # New CNAME target
        DnsServer      = "dc01.example.com"         # AD DNS server (check SOA)
        TTL            = "00:05:00"
    }

    Spn = @{
        FailoverFqdns   = @("fileserver.example.com")
        SourceAccount   = "PRIMARY-COMPUTER$"       # AD computer account on source
        TargetAccount   = "DR-COMPUTER$"            # AD computer account on target
    }

    Options = @{
        AttemptSourceDemotion      = $true
        PromotionPollInterval      = 5       # Seconds between polls
        PromotionPollTimeout       = 120     # Max seconds to wait
        SourceReachabilityTimeout  = 5       # Ping timeout in seconds
        WhatIf                     = $false  # Dry-run mode
    }
}
```

### Important Notes

- **Use management VIPs** for `Hostname`, not data VIPs. The REST API is only available on the management interface.
- **API tokens** are stored in plaintext for this prototype. For production use, store tokens in a secret vault (Azure Key Vault, HashiCorp Vault, or the PowerShell `SecretManagement` module).
- **DNS server** should be the authoritative server for the zone. Verify with:
  ```powershell
  Resolve-DnsName -Name example.com -Type SOA
  ```
- **SPN accounts** must match the AD computer accounts used by each FlashBlade. Verify with:
  ```cmd
  setspn -L <computer-account>
  ```

## Usage

### Failover (Primary to DR)

```powershell
.\Invoke-FBFailover.ps1
# or explicitly:
.\Invoke-FBFailover.ps1 -ConfigPath .\failover-config.psd1
```

### Failback (DR to Primary)

```powershell
.\Invoke-FBFailover.ps1 -ConfigPath .\failback-config.psd1
```

### Dry Run

Set `WhatIf = $true` in the config file's `Options` section. The script will authenticate and read status but skip all mutations.

## Failover Workflow

```
                 Source Array                    Target Array
                 ────────────                    ────────────
Before:          promoted (active)               demoted (replica)
                 CNAME points here               SPNs on source account

Script runs:     1. Validate target is demoted
                 2. Promote target filesystem
                 3. Demote source filesystem (if reachable)
                 4. Move SPNs: source account → target account
                 5. Swing DNS CNAME to target

After:           demoted (replica)               promoted (active)
                 SPNs removed                    CNAME points here
                                                 SPNs on target account
```

To fail back, run the same script with the failback config (Source/Target and SPN accounts are swapped).

## Error Handling

| Failure | Behavior |
|---------|----------|
| Target auth or promotion fails | **ABORT** -- script exits |
| Target FS not in `demoted` state | **ABORT** -- script exits |
| Promotion poll timeout | **WARN** -- continues (may still complete) |
| Source unreachable | **WARN** -- skips source demotion |
| Source demotion fails | **WARN** -- continues |
| SPN update fails | **WARN** -- continues with manual instructions |
| DNS update fails | **WARN** -- continues |

## Cross-Platform Behavior

| Operation | Windows (domain-joined) | macOS / Linux |
|-----------|------------------------|---------------|
| FlashBlade API (promote/demote) | Full support | Full support |
| SPN management | `setspn.exe` | Skipped -- manual instructions shown |
| DNS CNAME update | `DnsServer` module (RSAT) | Skipped -- manual instructions shown |
| DNS verification | `Resolve-DnsName` | `dig` or `nslookup` |

## Known Limitations

- **AD "Validated write to SPN" rules** -- FlashBlade cannot self-register SPNs via its REST API when the SPN doesn't match the array's own computer account name. The script uses `setspn.exe` with domain admin privileges instead.
- **AD-integrated DNS** requires a domain-joined Windows machine. The script cannot update DNS from non-domain-joined hosts.
- **No retry logic** -- this is a prototype. Transient API failures will result in a WARN or FAIL without automatic retry (except for SPN batch conflicts, which fall back to individual SPN testing).
- **Single filesystem** -- each config targets one filesystem. For multiple filesystems, run the script multiple times with different configs.

## Logs

Every run creates a timestamped transcript file in the working directory:

```
FBFailover_20260402-114419.log
```

The log captures all console output including the summary report.
