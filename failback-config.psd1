@{
    # -----------------------------------------------------------------------
    # FlashBlade Filesystem Failback Configuration
    # -----------------------------------------------------------------------
    # Reverses a prior failover: promotes the primary and demotes the DR site.
    FailoverDirection = "DRToPrimary"   # "PrimaryToDR" or "DRToPrimary"

    # --- Source Array (DR site -- being failed AWAY from) ---
    Source = @{
        Hostname   = "slc6-fbs200-n3-b35-12.fsa.lab"
        ApiToken   = "T-YOURTOKENHERE"
        FileSystem = "rp-drauto1"
        # NOTE: For production use, store tokens in a secret vault
        #       (e.g. Azure Key Vault, HashiCorp Vault, or SecretManagement module)
    }

    # --- Target Array (Primary site -- being restored, will be promoted) ---
    Target = @{
        Hostname   = "sn1-s200-c09-33.fsa.lab"
        ApiToken   = "T-YOUROTHERTOKENHERE"
        FileSystem = "rp-drauto1"
    }

    # --- DNS CNAME Update ---
    # Swing the CNAME alias back to the primary array's A record.
    Dns = @{
        ZoneName       = "fsa.lab"
        RecordName     = "rp-file1"              # CNAME record: rp-file1.fsa.lab
        SourceTarget   = "fbs200-n3.fsa.lab"     # Current CNAME target (DR array)
        FailoverTarget = "fsalab-s200.fsa.lab"   # Restore CNAME to primary array
        DnsServer      = "ad01.fsa.lab"          # AD-integrated DNS server
        TTL            = "00:05:00"              # 5-minute TTL
    }

    # --- SPN Management via FlashBlade REST API ---
    # On Windows (domain-joined): uses setspn.exe to move SPNs between accounts.
    # On macOS/Linux: skips with manual instructions.
    Spn = @{
        FailoverFqdns   = @("rp-file1.fsa.lab")
        SourceAccount   = "UDFSA-NAS-01"         # AD computer account on DR array (source for failback)
        TargetAccount   = "fsalab-s200"           # AD computer account on primary array (target for failback)
    }

    # --- Operational Options ---
    Options = @{
        AttemptSourceDemotion      = $true    # Try to demote DR site if reachable
        PromotionPollInterval      = 5        # Seconds between promotion status checks
        PromotionPollTimeout       = 120      # Max seconds to wait for promotion
        SourceReachabilityTimeout  = 5        # Seconds for source ping timeout
        WhatIf                     = $false   # Dry-run mode: display actions without executing
    }
}
