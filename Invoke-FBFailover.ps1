<#
.SYNOPSIS
    Automates FlashBlade filesystem failover with DNS and SPN updates.

.DESCRIPTION
    Promotes a replica filesystem on the target FlashBlade, optionally demotes
    the source, swings a DNS CNAME, and updates Kerberos SPNs via the
    FlashBlade REST API (v2.25).

    Designed as a prototype -- static values live in a PSD1 config file.

.PARAMETER ConfigPath
    Path to the PSD1 configuration file. Defaults to .\failover-config.psd1.

.EXAMPLE
    .\Invoke-FBFailover.ps1
    .\Invoke-FBFailover.ps1 -ConfigPath .\failback-config.psd1
#>

param(
    [Parameter()]
    [string]$ConfigPath = ".\failover-config.psd1"
)

$ErrorActionPreference = "Stop"
$script:ApiVersion = "2.25"

# -----------------------------------------------------------------------
# Transcript -- automatic log capture
# -----------------------------------------------------------------------
$TranscriptPath = "FBFailover_$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
Start-Transcript -Path $TranscriptPath -Append | Out-Null

# -----------------------------------------------------------------------
# Certificate trust -- FlashBlade uses self-signed certs by default
# -----------------------------------------------------------------------
if ($PSVersionTable.PSEdition -eq "Core") {
    $script:SkipCertParam = @{ SkipCertificateCheck = $true }
} else {
    Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert,
        WebRequest req, int problemIndex) { return true; }
}
"@
    [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
    $script:SkipCertParam = @{}
}

# -----------------------------------------------------------------------
# Step tracker -- collects results for the summary report
# -----------------------------------------------------------------------
$script:StepResults = [System.Collections.Generic.List[PSCustomObject]]::new()

function Add-StepResult {
    param([string]$Step, [string]$Status, [string]$Detail)
    $script:StepResults.Add([PSCustomObject]@{
        Step   = $Step
        Status = $Status
        Detail = $Detail
    })
}

# -----------------------------------------------------------------------
# FlashBlade API Functions
# -----------------------------------------------------------------------

function Connect-FlashBlade {
    param(
        [string]$Hostname,
        [string]$ApiToken
    )
    $BaseUrl = "https://$Hostname"
    Write-Host "  Authenticating to $Hostname..."
    try {
        $LoginResponse = Invoke-WebRequest -Uri "$BaseUrl/api/login" `
            -Method Post `
            -Headers @{ "api-token" = $ApiToken } `
            @script:SkipCertParam

        $Token = $LoginResponse.Headers["x-auth-token"]
        if (-not $Token) {
            Write-Error "No x-auth-token in response headers."
            return $null
        }
        if ($Token -is [array]) { $Token = $Token[0] }

        Write-Host "  Authenticated to $Hostname." -ForegroundColor Green
        return @{
            BaseUrl     = $BaseUrl
            AuthHeaders = @{ "x-auth-token" = $Token }
            Hostname    = $Hostname
        }
    } catch {
        Write-Error "Authentication to $Hostname failed: $_"
        return $null
    }
}

function Disconnect-FlashBlade {
    param([hashtable]$Session)
    if (-not $Session) { return }
    try {
        Invoke-RestMethod -Uri "$($Session.BaseUrl)/api/logout" `
            -Method Post `
            -Headers $Session.AuthHeaders `
            @script:SkipCertParam | Out-Null
        Write-Host "  Logged out from $($Session.Hostname)."
    } catch {
        Write-Warning "Logout from $($Session.Hostname) failed: $_"
    }
}

function Get-FileSystemStatus {
    param(
        [hashtable]$Session,
        [string]$FileSystemName
    )
    $Uri = "$($Session.BaseUrl)/api/$script:ApiVersion/file-systems?names=$FileSystemName"
    try {
        $Response = Invoke-RestMethod -Uri $Uri `
            -Method Get `
            -Headers $Session.AuthHeaders `
            @script:SkipCertParam
        if ($Response.items -and $Response.items.Count -gt 0) {
            return $Response.items[0]
        }
        Write-Error "Filesystem '$FileSystemName' not found on $($Session.Hostname)."
        return $null
    } catch {
        Write-Error "Failed to get filesystem status for '$FileSystemName': $_"
        return $null
    }
}

function Set-FileSystemPromotionState {
    param(
        [hashtable]$Session,
        [string]$FileSystemName,
        [ValidateSet("promoted", "demoted")]
        [string]$State
    )
    $Uri = "$($Session.BaseUrl)/api/$script:ApiVersion/file-systems?names=$FileSystemName"
    if ($State -eq "demoted") {
        $Uri += "&discard_non_snapshotted_data=true"
    }
    $Body = @{ requested_promotion_state = $State } | ConvertTo-Json
    try {
        $Response = Invoke-RestMethod -Uri $Uri `
            -Method Patch `
            -Headers $Session.AuthHeaders `
            -ContentType "application/json" `
            -Body $Body `
            @script:SkipCertParam
        if ($Response.items -and $Response.items.Count -gt 0) {
            return $Response.items[0]
        }
        return $null
    } catch {
        Write-Error "Failed to set '$FileSystemName' to '$State': $_"
        return $null
    }
}

function Wait-FileSystemPromotion {
    param(
        [hashtable]$Session,
        [string]$FileSystemName,
        [int]$IntervalSec = 5,
        [int]$TimeoutSec = 120
    )
    $Elapsed = 0
    while ($Elapsed -lt $TimeoutSec) {
        $Status = Get-FileSystemStatus -Session $Session -FileSystemName $FileSystemName
        if (-not $Status) { return $false }

        if ($Status.promotion_status -eq "promoted") {
            Write-Host "  Filesystem '$FileSystemName' is now promoted." -ForegroundColor Green
            return $true
        }
        if ($Status.promotion_status -eq "demoted") {
            Write-Warning "Filesystem '$FileSystemName' is still demoted -- promotion may not have been accepted."
            return $false
        }
        # status is "promoting" -- keep waiting
        Write-Host "  Status: promoting... ($Elapsed/$TimeoutSec sec)"
        Start-Sleep -Seconds $IntervalSec
        $Elapsed += $IntervalSec
    }
    Write-Warning "Timed out waiting for '$FileSystemName' to promote ($TimeoutSec sec)."
    return $false
}

function Get-ReplicaLinkStatus {
    param(
        [hashtable]$Session,
        [string]$FileSystemName
    )
    $Uri = "$($Session.BaseUrl)/api/$script:ApiVersion/file-system-replica-links?local_file_system_names=$FileSystemName"
    try {
        $Response = Invoke-RestMethod -Uri $Uri `
            -Method Get `
            -Headers $Session.AuthHeaders `
            @script:SkipCertParam
        return $Response.items
    } catch {
        Write-Warning "Failed to get replica link status: $_"
        return $null
    }
}

function Test-SourceReachable {
    param(
        [string]$Hostname,
        [int]$TimeoutSec = 5
    )
    Write-Host "  Testing connectivity to $Hostname..."
    try {
        $Result = Test-Connection -ComputerName $Hostname -Count 1 -TimeoutSeconds $TimeoutSec -Quiet
        return $Result
    } catch {
        return $false
    }
}

# -----------------------------------------------------------------------
# SPN Functions (setspn.exe on Windows, manual instructions elsewhere)
# -----------------------------------------------------------------------
# FlashBlade API can't register SPNs that don't match the computer name
# due to AD's "Validated write to SPN" rules. setspn with domain admin works.

function Get-SpnsForFqdns {
    <# Build SPN strings for both short name and FQDN #>
    param([string[]]$Fqdns)
    $Spns = @()
    foreach ($Fqdn in $Fqdns) {
        $ShortName = $Fqdn.Split(".")[0]
        $Spns += "HOST/$ShortName"
        $Spns += "HOST/$Fqdn"
    }
    return $Spns
}

function Update-SpnsWithSetspn {
    <#
    .SYNOPSIS
        Move SPNs from one AD account to another using setspn.exe.
    .DESCRIPTION
        Removes each SPN from SourceAccount, then adds to TargetAccount.
        Removal failures are warnings (source may already be clean).
        Addition failures are errors.
    #>
    param(
        [string[]]$Spns,
        [string]$SourceAccount,
        [string]$TargetAccount
    )
    $Added = @()
    $Failed = @()

    foreach ($Spn in $Spns) {
        # Remove from source (best-effort)
        Write-Host "    Removing $Spn from $SourceAccount..."
        $RemoveOutput = setspn -D $Spn $SourceAccount 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host "    (not present or already removed)" -ForegroundColor DarkGray
        } else {
            Write-Host "    Removed." -ForegroundColor Green
        }

        # Add to target
        Write-Host "    Adding $Spn to $TargetAccount..."
        $AddOutput = setspn -S $Spn $TargetAccount 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "    Added." -ForegroundColor Green
            $Added += $Spn
        } else {
            Write-Host "    FAILED: $($AddOutput -join ' ')" -ForegroundColor Red
            $Failed += $Spn
        }
    }

    return @{ Added = $Added; Failed = $Failed }
}

# -----------------------------------------------------------------------
# DNS Functions
# -----------------------------------------------------------------------

function Update-DnsCname {
    param([hashtable]$DnsConfig)

    $Zone       = $DnsConfig.ZoneName
    $Name       = $DnsConfig.RecordName
    $OldTarget  = $DnsConfig.SourceTarget
    $NewTarget  = $DnsConfig.FailoverTarget
    $Server     = $DnsConfig.DnsServer
    $TTLString  = $DnsConfig.TTL

    Write-Host "  Updating CNAME: $Name.$Zone -> $NewTarget"

    if ($IsWindows -or ($PSVersionTable.PSEdition -ne "Core")) {
        # Windows: use DnsServer module
        $TTL = [TimeSpan]::Parse($TTLString)
        try {
            $Existing = Get-DnsServerResourceRecord -ZoneName $Zone -Name $Name `
                -RRType CName -ComputerName $Server -ErrorAction Stop
            if ($Existing) {
                Remove-DnsServerResourceRecord -ZoneName $Zone -Name $Name `
                    -RRType CName -ComputerName $Server -Force -ErrorAction Stop
                Write-Host "  Removed old CNAME ($($Existing.RecordData.HostNameAlias))."
            }
        } catch {
            Write-Warning "Could not remove existing CNAME: $_"
        }
        try {
            Add-DnsServerResourceRecordCName -ZoneName $Zone -Name $Name `
                -HostNameAlias $NewTarget -ComputerName $Server -TimeToLive $TTL -ErrorAction Stop
            Write-Host "  Added CNAME: $Name.$Zone -> $NewTarget" -ForegroundColor Green
            return $true
        } catch {
            Write-Warning "Failed to add CNAME record: $_"
            return $false
        }
    } else {
        # macOS/Linux: use nsupdate (RFC 2136 dynamic DNS)
        $NsUpdate = Get-Command nsupdate -ErrorAction SilentlyContinue
        if (-not $NsUpdate) {
            Write-Error "nsupdate not found. Install bind tools (e.g. 'brew install bind' on macOS)."
            return $false
        }
        # Convert HH:MM:SS TTL to seconds for nsupdate
        $TTLSec = [int][TimeSpan]::Parse($TTLString).TotalSeconds
        $Fqdn = "$Name.$Zone"
        $NsCommands = @(
            "server $Server"
            "update delete $Fqdn CNAME"
            "update add $Fqdn $TTLSec CNAME $NewTarget"
            "send"
        ) -join "`n"
        Write-Host "  Running nsupdate against $Server..."
        try {
            $NsCommands | nsupdate 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Host "  Added CNAME: $Name.$Zone -> $NewTarget" -ForegroundColor Green
                return $true
            } else {
                Write-Error "nsupdate exited with code $LASTEXITCODE"
                return $false
            }
        } catch {
            Write-Error "nsupdate failed: $_"
            return $false
        }
    }
}

function Test-DnsResolution {
    param(
        [string]$Fqdn,
        [string]$DnsServer
    )
    if ($IsWindows -or ($PSVersionTable.PSEdition -ne "Core")) {
        # Windows: Resolve-DnsName
        $Result = Resolve-DnsName -Name $Fqdn -Server $DnsServer -Type CNAME -ErrorAction SilentlyContinue
        if ($Result) { return $Result.NameHost }
        return $null
    } else {
        # macOS/Linux: prefer dig (reliable output), fall back to nslookup
        try {
            $DigCmd = Get-Command dig -ErrorAction SilentlyContinue
            if ($DigCmd) {
                $Output = dig CNAME $Fqdn "@$DnsServer" +short 2>&1
                # Filter out error lines and empty results
                $Result = ($Output | Where-Object {
                    $_ -match '\S' -and $_ -notmatch '(couldn|error|timed out|SERVFAIL|NXDOMAIN|;;)'
                } | Select-Object -First 1)
                if ($Result) { return $Result.ToString().TrimEnd(".") }
                return $null
            }
            # Fallback: nslookup
            $Output = nslookup -type=CNAME $Fqdn $DnsServer 2>&1
            $Match = $Output | Select-String "canonical name\s*=\s*(.+)" | Select-Object -First 1
            if ($Match) {
                return $Match.Matches.Groups[1].Value.Trim().TrimEnd(".")
            }
            return $null
        } catch {
            return $null
        }
    }
}

# -----------------------------------------------------------------------
# Main Orchestration
# -----------------------------------------------------------------------

$TargetSession = $null
$SourceSession = $null

try {
    # --- 1. Load config ---
    Write-Host "`n=== FlashBlade Filesystem Failover ===" -ForegroundColor Cyan
    if (-not (Test-Path $ConfigPath)) {
        Write-Error "Config file not found: $ConfigPath"
        exit 1
    }
    $Config = Import-PowerShellDataFile -Path $ConfigPath
    $WhatIf = $Config.Options.WhatIf

    # --- 2. Display summary ---
    Write-Host "`nConfiguration:"
    Write-Host "  Direction:   $($Config.FailoverDirection)"
    Write-Host "  Source:      $($Config.Source.Hostname) / FS: $($Config.Source.FileSystem)"
    Write-Host "  Target:      $($Config.Target.Hostname) / FS: $($Config.Target.FileSystem)"
    Write-Host "  DNS CNAME:   $($Config.Dns.RecordName).$($Config.Dns.ZoneName) -> $($Config.Dns.FailoverTarget)"
    Write-Host "  SPN FQDNs:   $($Config.Spn.FailoverFqdns -join ', ')"
    Write-Host "  WhatIf:      $WhatIf"
    Write-Host ""

    # --- 3. Confirm ---
    if (-not $WhatIf) {
        $Confirm = Read-Host "Proceed with failover? [y/N]"
        if ($Confirm -notmatch '^[Yy]') {
            Write-Host "Aborted by user."
            exit 0
        }
    } else {
        Write-Host "*** DRY RUN MODE -- no changes will be made ***" -ForegroundColor Yellow
    }

    # --- 5. Connect to Target ---
    Write-Host "`n--- Step 1: Connect to Target Array ---" -ForegroundColor Cyan
    $TargetSession = Connect-FlashBlade -Hostname $Config.Target.Hostname -ApiToken $Config.Target.ApiToken
    if (-not $TargetSession) {
        Add-StepResult "Connect Target" "FAIL" "Authentication failed"
        Write-Error "Cannot proceed without target array connection."
        exit 1
    }
    Add-StepResult "Connect Target" "PASS" $Config.Target.Hostname

    # --- 6. Validate Target FS is demoted ---
    Write-Host "`n--- Step 2: Validate Target Filesystem ---" -ForegroundColor Cyan
    $TargetFs = Get-FileSystemStatus -Session $TargetSession -FileSystemName $Config.Target.FileSystem
    if (-not $TargetFs) {
        Add-StepResult "Validate Target FS" "FAIL" "Filesystem not found"
        Write-Error "Target filesystem '$($Config.Target.FileSystem)' not found."
        exit 1
    }
    Write-Host "  Filesystem: $($TargetFs.name)"
    Write-Host "  Promotion status: $($TargetFs.promotion_status)"
    if ($TargetFs.promotion_status -ne "demoted") {
        Add-StepResult "Validate Target FS" "FAIL" "Expected 'demoted', got '$($TargetFs.promotion_status)'"
        Write-Error "Target filesystem is '$($TargetFs.promotion_status)', expected 'demoted'. Cannot promote."
        exit 1
    }
    Add-StepResult "Validate Target FS" "PASS" "Status: demoted"

    # --- 7. Show replica link status (informational) ---
    Write-Host "`n--- Step 3: Replica Link Status ---" -ForegroundColor Cyan
    $ReplicaLinks = Get-ReplicaLinkStatus -Session $TargetSession -FileSystemName $Config.Target.FileSystem
    if ($ReplicaLinks) {
        foreach ($Link in $ReplicaLinks) {
            Write-Host "  Link: $($Link.local_file_system.name) <-> $($Link.remote_file_system.name)"
            Write-Host "  Status: $($Link.status)"
            if ($Link.recovery_point) {
                $RecoveryTime = [DateTimeOffset]::FromUnixTimeMilliseconds($Link.recovery_point).LocalDateTime
                Write-Host "  Recovery point: $RecoveryTime"
            }
        }
    } else {
        Write-Host "  No replica links found (may be normal if queried from replica side)."
    }

    # --- 8. Promote Target FS ---
    Write-Host "`n--- Step 4: Promote Target Filesystem ---" -ForegroundColor Cyan
    if ($WhatIf) {
        Write-Host "  [WhatIf] Would promote '$($Config.Target.FileSystem)' on $($Config.Target.Hostname)"
        Add-StepResult "Promote Target FS" "WHATIF" "Skipped"
    } else {
        Write-Host "  Promoting '$($Config.Target.FileSystem)'..."
        $PromoteResult = Set-FileSystemPromotionState -Session $TargetSession `
            -FileSystemName $Config.Target.FileSystem -State "promoted"
        if (-not $PromoteResult) {
            Add-StepResult "Promote Target FS" "FAIL" "API call failed"
            Write-Error "Failed to promote target filesystem."
            exit 1
        }
        Add-StepResult "Promote Target FS" "PASS" "Promotion requested"

        # --- 9. Poll until promoted ---
        Write-Host "`n--- Step 5: Wait for Promotion ---" -ForegroundColor Cyan
        $Promoted = Wait-FileSystemPromotion -Session $TargetSession `
            -FileSystemName $Config.Target.FileSystem `
            -IntervalSec $Config.Options.PromotionPollInterval `
            -TimeoutSec $Config.Options.PromotionPollTimeout
        if ($Promoted) {
            Add-StepResult "Wait Promotion" "PASS" "Filesystem promoted"
        } else {
            Add-StepResult "Wait Promotion" "WARN" "Timed out or unexpected state"
            Write-Warning "Promotion may still be in progress. Continuing with remaining steps."
        }
    }

    # --- 10. Source operations (if reachable) -- done BEFORE target SPN
    #     update so that failover FQDNs are deregistered from the source
    #     before we try to register them on the target.
    Write-Host "`n--- Step 6: Source Array Operations ---" -ForegroundColor Cyan
    if ($Config.Options.AttemptSourceDemotion) {
        $SourceReachable = Test-SourceReachable -Hostname $Config.Source.Hostname `
            -TimeoutSec $Config.Options.SourceReachabilityTimeout
        if ($SourceReachable) {
            Write-Host "  Source $($Config.Source.Hostname) is reachable."
            $SourceSession = Connect-FlashBlade -Hostname $Config.Source.Hostname -ApiToken $Config.Source.ApiToken
            if ($SourceSession) {
                Add-StepResult "Connect Source" "PASS" $Config.Source.Hostname

                # Demote source filesystem
                $SourceFs = Get-FileSystemStatus -Session $SourceSession -FileSystemName $Config.Source.FileSystem
                if ($SourceFs -and $SourceFs.promotion_status -eq "promoted") {
                    if ($WhatIf) {
                        Write-Host "  [WhatIf] Would demote '$($Config.Source.FileSystem)' on $($Config.Source.Hostname)"
                        Add-StepResult "Demote Source FS" "WHATIF" "Skipped"
                    } else {
                        Write-Host "  Demoting '$($Config.Source.FileSystem)' (discard_non_snapshotted_data=true)..."
                        try {
                            $DemoteResult = Set-FileSystemPromotionState -Session $SourceSession `
                                -FileSystemName $Config.Source.FileSystem -State "demoted"
                            if ($DemoteResult) {
                                Write-Host "  Source filesystem demoted." -ForegroundColor Green
                                Add-StepResult "Demote Source FS" "PASS" "Demoted"
                            } else {
                                Add-StepResult "Demote Source FS" "WARN" "No response from API"
                            }
                        } catch {
                            Write-Warning "Source demotion failed: $_"
                            Add-StepResult "Demote Source FS" "WARN" "$_"
                        }
                    }
                } else {
                    $CurrentState = if ($SourceFs) { $SourceFs.promotion_status } else { "not found" }
                    Write-Host "  Source filesystem is '$CurrentState' -- skipping demotion."
                    Add-StepResult "Demote Source FS" "SKIP" "Status: $CurrentState"
                }

            } else {
                Write-Warning "Could not authenticate to source array."
                Add-StepResult "Connect Source" "WARN" "Auth failed"
                Add-StepResult "Demote Source FS" "SKIP" "No connection"
            }
        } else {
            Write-Warning "Source $($Config.Source.Hostname) is unreachable -- skipping source operations."
            Add-StepResult "Connect Source" "SKIP" "Unreachable"
            Add-StepResult "Demote Source FS" "SKIP" "Source unreachable"
        }
    } else {
        Write-Host "  Source demotion disabled in config."
        Add-StepResult "Source Operations" "SKIP" "Disabled in config"
    }

    # --- 11. Move SPNs (setspn.exe on Windows, manual instructions on macOS/Linux) ---
    Write-Host "`n--- Step 7: Update SPNs ---" -ForegroundColor Cyan
    $FailoverSpns = Get-SpnsForFqdns -Fqdns $Config.Spn.FailoverFqdns
    $SourceAcct = $Config.Spn.SourceAccount
    $TargetAcct = $Config.Spn.TargetAccount
    Write-Host "  SPNs to move:    $($FailoverSpns -join ', ')"
    Write-Host "  From account:    $SourceAcct"
    Write-Host "  To account:      $TargetAcct"

    $CanRunSetspn = ($IsWindows -or ($PSVersionTable.PSEdition -ne "Core")) -and
                    (Get-Command setspn -ErrorAction SilentlyContinue)
    if (-not $CanRunSetspn) {
        Write-Host "  SPN update requires a domain-joined Windows machine with setspn.exe." -ForegroundColor Yellow
        Write-Host "  Manual steps from a domain-joined Windows machine:" -ForegroundColor Yellow
        foreach ($Spn in $FailoverSpns) {
            Write-Host "    setspn -D $Spn $SourceAcct" -ForegroundColor DarkGray
            Write-Host "    setspn -S $Spn $TargetAcct" -ForegroundColor DarkGray
        }
        Add-StepResult "Update SPNs" "SKIP" "Requires Windows. Run setspn manually."
    } elseif ($WhatIf) {
        Write-Host "  [WhatIf] Would move SPNs from $SourceAcct to $TargetAcct"
        Add-StepResult "Update SPNs" "WHATIF" "Skipped"
    } else {
        $SpnResult = Update-SpnsWithSetspn -Spns $FailoverSpns `
            -SourceAccount $SourceAcct -TargetAccount $TargetAcct
        if ($SpnResult.Failed) {
            Write-Warning "Some SPNs failed: $($SpnResult.Failed -join ', ')"
            Add-StepResult "Update SPNs" "WARN" "Added: $($SpnResult.Added -join ', '). Failed: $($SpnResult.Failed -join ', ')"
        } else {
            Write-Host "  All SPNs moved successfully." -ForegroundColor Green
            Add-StepResult "Update SPNs" "PASS" "Moved: $($SpnResult.Added -join ', ')"
        }
    }

    # --- 12. Update DNS CNAME ---
    Write-Host "`n--- Step 8: Update DNS CNAME ---" -ForegroundColor Cyan
    $CanUpdateDns = $IsWindows -or ($PSVersionTable.PSEdition -ne "Core")
    if (-not $CanUpdateDns) {
        Write-Host "  DNS update requires a domain-joined Windows machine (AD-integrated DNS)." -ForegroundColor Yellow
        Write-Host "  Manual step: Update CNAME $($Config.Dns.RecordName).$($Config.Dns.ZoneName) -> $($Config.Dns.FailoverTarget)"
        Add-StepResult "Update DNS CNAME" "SKIP" "Requires Windows (AD DNS). Update manually."
    } elseif ($WhatIf) {
        Write-Host "  [WhatIf] Would update CNAME $($Config.Dns.RecordName).$($Config.Dns.ZoneName) -> $($Config.Dns.FailoverTarget)"
        Add-StepResult "Update DNS CNAME" "WHATIF" "Skipped"
    } else {
        try {
            $DnsResult = Update-DnsCname -DnsConfig $Config.Dns
            if ($DnsResult) {
                Add-StepResult "Update DNS CNAME" "PASS" "$($Config.Dns.RecordName) -> $($Config.Dns.FailoverTarget)"
            } else {
                Add-StepResult "Update DNS CNAME" "WARN" "Update returned false"
            }
        } catch {
            Write-Warning "DNS update failed: $_"
            Add-StepResult "Update DNS CNAME" "WARN" "$_"
        }
    }

    # --- 13. Verify DNS ---
    Write-Host "`n--- Step 9: Verify DNS ---" -ForegroundColor Cyan
    try {
        $Fqdn = "$($Config.Dns.RecordName).$($Config.Dns.ZoneName)"
        $DnsResult = Test-DnsResolution -Fqdn $Fqdn -DnsServer $Config.Dns.DnsServer
        if ($DnsResult) {
            Write-Host "  DNS resolution: $Fqdn -> $DnsResult"
            Add-StepResult "Verify DNS" "PASS" "Resolves to $DnsResult"
        } else {
            Write-Host "  Could not verify (may require domain credentials)."
            Add-StepResult "Verify DNS" "SKIP" "Unable to query AD DNS from this host"
        }
    } catch {
        Write-Host "  Could not verify (may require domain credentials)."
        Add-StepResult "Verify DNS" "SKIP" "Unable to query AD DNS from this host"
    }

} finally {
    # --- 15. Logout ---
    Write-Host "`n--- Cleanup ---"
    if ($TargetSession) { Disconnect-FlashBlade -Session $TargetSession }
    if ($SourceSession) { Disconnect-FlashBlade -Session $SourceSession }
}

# --- 14. Summary Report ---
Write-Host "`n=== Failover Summary ===" -ForegroundColor Cyan
Write-Host "Direction: $($Config.FailoverDirection)"
Write-Host ""
$script:StepResults | Format-Table -Property Step, Status, Detail -AutoSize

$FailCount = ($script:StepResults | Where-Object { $_.Status -eq "FAIL" }).Count
$WarnCount = ($script:StepResults | Where-Object { $_.Status -eq "WARN" }).Count
if ($FailCount -gt 0) {
    Write-Host "Result: FAILED ($FailCount failures, $WarnCount warnings)" -ForegroundColor Red
} elseif ($WarnCount -gt 0) {
    Write-Host "Result: COMPLETED WITH WARNINGS ($WarnCount warnings)" -ForegroundColor Yellow
} else {
    Write-Host "Result: SUCCESS" -ForegroundColor Green
}

Write-Host "`nTranscript saved to: $TranscriptPath"
Stop-Transcript | Out-Null
