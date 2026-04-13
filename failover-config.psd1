@{
    # -----------------------------------------------------------------------
    # FlashBlade Filesystem Failover Configuration
    # -----------------------------------------------------------------------
    # Safety label -- validated against actual filesystem states before
    # proceeding. To fail back, swap Source/Target values and flip this.
    FailoverDirection = "PrimaryToDR"   # "PrimaryToDR" or "DRToPrimary"

    # --- Source Array (being failed AWAY from) ---
    Source = @{
        Hostname   = "sn1-s200-c09-33.fsa.lab"
        ApiToken   = "T-bc567b5f-f6fe-4c52-9fde-fba72459d1ee"
        FileSystem = "rp-drauto1"
        # NOTE: For production use, store tokens in a secret vault
        #       (e.g. Azure Key Vault, HashiCorp Vault, or SecretManagement module)
    }

    # --- Target Array (being failed TO -- will be promoted) ---
    Target = @{
        Hostname   = "slc6-fbs200-n3-b35-12.fsa.lab"
        ApiToken   = "T-3bf7bcf9-6df6-46d9-a53c-034c5b3a82ab"
        FileSystem = "rp-drauto1"
    }

    # --- DNS CNAME Update ---
    # Swing the CNAME alias to point to the target array's A record.
    Dns = @{
        ZoneName       = "fsa.lab"
        RecordName     = "rp-file1"              # CNAME record: rp-file1.fsa.lab
        SourceTarget   = "fsalab-s200.fsa.lab"   # Current CNAME target (source array)
        FailoverTarget = "fbs200-n3.fsa.lab"     # New CNAME target (DR array)
        DnsServer      = "ad01.fsa.lab"          # AD-integrated DNS server
        TTL            = "00:05:00"              # 5-minute TTL
    }

    # --- SPN Management ---
    # On Windows (domain-joined): uses setspn.exe to move SPNs between accounts.
    # On macOS/Linux: skips with manual instructions.
    # Note: FlashBlade API can't register SPNs that don't match the computer name
    # due to AD's "Validated write to SPN" rules. setspn with domain admin works.
    Spn = @{
        FailoverFqdns   = @("rp-file1.fsa.lab")
        SourceAccount   = "fsalab-s200"          # AD computer account on source array
        TargetAccount   = "UDFSA-NAS-01"         # AD computer account on target array
    }

    # --- Operational Options ---
    Options = @{
        AttemptSourceDemotion      = $true    # Try to demote source if reachable
        PromotionPollInterval      = 5        # Seconds between promotion status checks
        PromotionPollTimeout       = 120      # Max seconds to wait for promotion
        SourceReachabilityTimeout  = 5        # Seconds for source ping timeout
        WhatIf                     = $false   # Dry-run mode: display actions without executing
    }
}
