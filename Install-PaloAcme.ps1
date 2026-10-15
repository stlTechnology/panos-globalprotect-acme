#Requires -Version 5.1
#Requires -RunAsAdministrator
# One-time interactive setup on the on-site Windows box: .\Install-PaloAcme.ps1
# Re-run any time (staging -> production, switch CA, new GoDaddy key); previous answers are offered as defaults.
param(
    [string]$Root = "$env:ProgramData\PaloAcme",
    [string]$At = '03:17'   # daily task time
)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 'Tls12'
$curl = "$env:SystemRoot\System32\curl.exe"
if (-not (Test-Path $curl)) { throw 'curl.exe missing (needs Windows 10 1803+ / Server 2019+).' }
if (-not (Test-Path "$PSScriptRoot\Update-PaloCert.ps1")) { throw "Update-PaloCert.ps1 must be in the same folder as this script ($PSScriptRoot)." }

function Read-Answer($prompt) {   # Read-Host, but stop if input is closed (piped/redirected) instead of looping forever
    $a = Read-Host $prompt
    if ($null -eq $a) { throw 'Input closed; setup is interactive.' }
    $a
}
function Ask($q, $default) {   # Enter = default; no default = required
    $a = Read-Answer $(if ($default) { "$q [$default]" } else { $q })
    if ($a) { $a.Trim() } elseif ($default) { $default } else { Ask $q $default }
}
function Yes($q, [bool]$default = $true) {
    $a = Read-Answer "$q $(if ($default) { '[Y/n]' } else { '[y/N]' })"
    if ($a) { $a -match '^y' } else { $default }
}
$old = if (Test-Path "$Root\config.json") { Get-Content "$Root\config.json" -Raw | ConvertFrom-Json }

# --- Certificate authority -----------------------------------------------------------------------
$ca = $null
while (-not $ca) {
    if (Yes "Get the certificate from Let's Encrypt (free, auto-renewing - recommended)?") {
        $ca = 'LE_PROD'; $caName = "Let's Encrypt"
    } else {
        Write-Host '  1) GoDaddy paid SSL certificate via ACME (ACME details fetched with your GoDaddy API key, or typed in)'
        Write-Host '  2) Cloudflare or another ACME CA, by directory URL'
        Write-Host "     (Cloudflare's public CA was announced Sept 2026 but is not issuing yet; its edge/Origin CA certs can't be used on the Palo)"
        Write-Host "  3) Let's Encrypt STAGING - test run only, clients will NOT trust the cert"
        Write-Host '  4) Back'
        switch (Read-Answer 'Choose 1-4') {
            '1' { $ca = 'GODADDY'; $caName = 'GoDaddy SSL' }
            '2' {
                $u = Ask 'ACME directory URL of the CA'
                if ($u -match '^https://') { $ca = $u; $caName = $u } else { Write-Host 'URL must start with https://' }
            }
            '3' { $ca = 'LE_STAGE'; $caName = "Let's Encrypt STAGING (test)" }
        }
    }
}
$test = $ca -eq 'LE_STAGE'

# --- Names and firewall --------------------------------------------------------------------------
$Domain = @((Ask 'Name(s) on the cert, GP portal FQDN first, comma-separated' $old.Domains) -split '\s*,\s*' | Where-Object { $_ })

# --- DNS host (where the _acme-challenge TXT record gets written) -----------------------------------
# Ask public DNS (1.1.1.1 first: internal AD DNS often hosts a copy of the zone) who serves the zone.
function Find-Zone($name) {
    $labels = $name.Split('.')
    foreach ($srv in '1.1.1.1', $null) {
        for ($i = 0; $i -lt $labels.Count - 1; $i++) {
            $zone = $labels[$i..($labels.Count - 1)] -join '.'
            $q = @{ Name = $zone; Type = 'NS'; DnsOnly = $true; ErrorAction = 'SilentlyContinue' }
            if ($srv) { $q.Server = $srv }
            $ns = @(Resolve-DnsName @q | Where-Object { $_.Type -eq 'NS' -and $_.Name -eq $zone }).NameHost
            if ($ns) { return [pscustomobject]@{ Zone = $zone; NS = $ns } }
        }
    }
}
$z = Find-Zone $Domain[0]
$detected = if (-not $z) { $null } elseif ($z.NS -match '\.cloudflare\.com$') { 'Cloudflare' } elseif ($z.NS -match 'domaincontrol\.com$') { 'GoDaddy' }
$dns = $null
if ($detected) {
    if (Yes "DNS for $($z.Zone) is hosted at $detected (nameservers: $($z.NS -join ', ')). Use the $detected API to prove domain control?") { $dns = $detected }
} elseif ($z) {
    Write-Host "DNS for $($z.Zone) is at $($z.NS -join ', ') - not GoDaddy or Cloudflare."
    Write-Host 'Supported: move the zone, or CNAME _acme-challenge.<name> to a zone at GoDaddy/Cloudflare (see guide).'
} else { Write-Host "Couldn't look up the DNS host for $($Domain[0])." }
while (-not $dns) {
    Write-Host '  1) Cloudflare   2) GoDaddy   3) Cancel'
    switch (Read-Answer 'Which DNS provider should write the validation record? 1-3') {
        '1' { $dns = 'Cloudflare' }
        '2' { $dns = 'GoDaddy' }
        '3' { Write-Host 'Cancelled, nothing changed.'; return }
    }
    if ($dns -and $detected -and $dns -ne $detected) {   # CNAME delegation (-DnsAlias) isn't wired into setup
        Write-Host "The nameservers for $($z.Zone) are $detected, so a $dns record won't be seen by the CA. Pick $detected, or move the zone first."
        $dns = $null
    }
}

$Contact = Ask 'Contact email for CA expiry notices' $old.Contact
$Firewall = Ask 'Firewall management IP or FQDN' $old.Firewall
$defName = if ($test) { 'acme-test' } elseif ($old.CertName -and $old.CertName -ne 'acme-test') { $old.CertName } else { 'gp-acme' }
$CertName = Ask 'Certificate object name on the firewall (a NEW name; point the GP SSL/TLS profile at it once)' $defName

# Is the firewall reachable, and does this box trust its mgmt cert?
& $curl -s -o NUL --max-time 15 "https://$Firewall/api/"
$code = $LASTEXITCODE
$skip = $false
if ($code -in 35, 51, 60) {
    $skip = Yes "This machine doesn't trust the firewall's mgmt certificate. Connect anyway without verifying it (encrypted, not authenticated)?" $false
    if (-not $skip) { throw "Trust the firewall's mgmt cert on this machine (README > Prerequisites > Firewall step 4), then re-run." }
} elseif ($code) { throw "Cannot reach https://$Firewall (curl exit $code). Check Permitted IP on the mgmt interface and routing." }

$v = Ask "After each deploy, connect where to confirm the portal serves the new cert? (name/IP, or 'none')" $(if ($test) { 'none' } else { $Domain[0] })
$verify = if ($v -eq 'none') { '' } else { $v }

Write-Host "`nAbout to set up:"
Write-Host "  Certificate from : $caName"
Write-Host "  Names            : $($Domain -join ', ')"
Write-Host "  DNS validation   : $dns API"
Write-Host "  Firewall         : $Firewall  (mgmt cert verified: $(if ($skip) { 'NO' } else { 'yes' }))"
Write-Host "  Cert object      : $CertName"
Write-Host "  Served-cert check: $(if ($verify) { $verify } else { 'off' })"
Write-Host "  Daily task       : $At as SYSTEM, files in $Root"
if (-not (Yes 'Proceed?')) { Write-Host 'Cancelled, nothing changed.'; return }

# --- Install -------------------------------------------------------------------------------------
# Folder holds the API key and ACME keys: SYSTEM + Administrators only.
New-Item -ItemType Directory -Force "$Root\logs", "$Root\posh-acme" | Out-Null
icacls $Root /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
Copy-Item "$PSScriptRoot\Update-PaloCert.ps1" $Root -Force
Unblock-File "$Root\Update-PaloCert.ps1"
if (-not [Diagnostics.EventLog]::SourceExists('PaloAcme')) { [Diagnostics.EventLog]::CreateEventSource('PaloAcme', 'Application') }

# AllUsers so the SYSTEM task finds it (installs into this PowerShell edition's path; the task uses this same exe).
if ($PSVersionTable.PSVersion.Major -lt 6) { Install-PackageProvider NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null }
Install-Module Posh-ACME -Scope AllUsers -Force
$env:POSHACME_HOME = "$Root\posh-acme"
Import-Module Posh-ACME -Force

# DNS provider credentials, tested before involving the CA.
$gdAuth = $null
if ($dns -eq 'GoDaddy') {
    while ($true) {
        $gdKey = Read-Host 'GoDaddy API key (production, not OTE; must be able to edit DNS)'
        $gdSecret = Read-Host 'GoDaddy API secret' -AsSecureString
        $gdAuth = @{ Authorization = "sso-key ${gdKey}:$((New-Object Net.NetworkCredential('', $gdSecret)).Password)" }
        try {
            # the same zone call the Posh-ACME plugin makes; falls back to a generic check if the zone wasn't detected
            $url = if ($z) { "https://api.godaddy.com/v1/domains/$($z.Zone)/records/TXT" } else { 'https://api.godaddy.com/v1/domains?limit=1' }
            $null = Invoke-RestMethod $url -Headers $gdAuth
            break
        } catch {
            Write-Host "GoDaddy API check failed: $($_.Exception.Message)  (401 = wrong key/secret or OTE key; 403 = account not entitled; 404 = $(if ($z) { $z.Zone } else { 'zone' }) not in this GoDaddy account)"
            if (-not (Yes 'Try a different key?')) { throw 'GoDaddy DNS API unavailable. Re-run and pick Cloudflare, or see the guide (CNAME delegation).' }
        }
    }
    $pluginArgs = @{ GDKey = $gdKey; GDSecretSecure = $gdSecret }
} else {
    while ($true) {
        $cfToken = Read-Host 'Cloudflare API token (permission Zone > DNS > Edit on this zone)' -AsSecureString
        $cfAuth = @{ Authorization = "Bearer $((New-Object Net.NetworkCredential('', $cfToken)).Password)" }
        try {
            $filter = if ($z) { "?name=$($z.Zone)" } else { '' }
            $r = Invoke-RestMethod "https://api.cloudflare.com/client/v4/zones$filter" -Headers $cfAuth
            if (-not $r.result) { throw "token is valid but can't see zone $(if ($z) { $z.Zone })" }
            break
        } catch {
            Write-Host "Cloudflare API check failed: $($_.Exception.Message)  (401/403 = wrong or expired token; zone not visible = token not scoped to this zone)"
            if (-not (Yes 'Try a different token?')) { throw 'Cloudflare DNS API unavailable. See the guide: Cloudflare API token.' }
        }
    }
    $pluginArgs = @{ CFToken = $cfToken }
}

# GoDaddy CA: ACME directory + External Account Binding (ties the ACME account to your cert purchase).
# Try the PKI API (developer.godaddy.com certificates v2) first; fall back to the values on the ACME Setup page.
$ShopperId = $old.ShopperId
$eab = $null
if ($ca -eq 'GODADDY') {
    try {
        if (-not $gdAuth) {   # DNS is on Cloudflare: a GoDaddy key is only needed for this lookup
            if (-not (Yes 'Fetch the GoDaddy ACME details automatically with a GoDaddy API key? (No = type them in)')) { throw 'skipped by choice' }
            $k = Read-Host 'GoDaddy API key (production, not OTE)'
            $s = Read-Host 'GoDaddy API secret' -AsSecureString
            $gdAuth = @{ Authorization = "sso-key ${k}:$((New-Object Net.NetworkCredential('', $s)).Password)" }
        }
        $ShopperId = Ask 'GoDaddy customer number (account menu, top right of godaddy.com)' $old.ShopperId
        $custId = (Invoke-RestMethod "https://api.godaddy.com/v1/shoppers/${ShopperId}?includes=customerId" -Headers $gdAuth).customerId
        $eab = Invoke-RestMethod "https://api.godaddy.com/v2/customers/$custId/certificates/acme/externalAccountBinding" -Headers $gdAuth
        if (-not ($eab.directoryUrl -and $eab.keyId -and $eab.hmacKey)) { throw 'response missing directoryUrl/keyId/hmacKey' }
        Write-Host "Got ACME details from the GoDaddy API: $($eab.directoryUrl)"
    } catch {
        Write-Host "Couldn't get ACME details from the GoDaddy API: $($_.Exception.Message)"
        Write-Host 'Enter them from GoDaddy > SSL > Manage All > ACME Automation > ACME Setup instead.'
        $eab = [pscustomobject]@{
            directoryUrl = Ask 'ACME directory URL'
            keyId        = Ask 'EAB Key ID'
            hmacKey      = (New-Object Net.NetworkCredential('', (Read-Host 'EAB Key Data (HMAC)' -AsSecureString))).Password
        }
    }
    if ($eab.directoryUrl -notmatch '^https://') { throw "ACME directory URL must start with https:// (got '$($eab.directoryUrl)')." }
    $ca = $eab.directoryUrl
} elseif ($ca -notlike 'LE_*') {   # other ACME CA by URL
    if (Yes 'Does this CA require External Account Binding (EAB Key ID + HMAC)?' $false) {
        $eab = [pscustomobject]@{
            keyId   = Ask 'EAB Key ID'
            hmacKey = (New-Object Net.NetworkCredential('', (Read-Host 'EAB HMAC key' -AsSecureString))).Password
        }
    }
}

Set-PAServer $ca
# Alt plugin encryption: the DNS API secret must be readable by SYSTEM, not DPAPI-bound to this admin.
if (-not (Get-PAAccount)) {
    $acct = @{ Contact = $Contact; AcceptTOS = $true; UseAltPluginEncryption = $true }
    if ($eab) { $acct.ExtAcctKID = $eab.keyId; $acct.ExtAcctHMACKey = $eab.hmacKey }
    New-PAAccount @acct | Out-Null
}
$certParams = @{
    Domain = $Domain; Plugin = $dns; PluginArgs = $pluginArgs
    Force = $true   # key is reused on renewal (acme.sh-proven); see README "Key rotation" before enabling AlwaysNewKey
}
# LE 'classic' on purpose: 'tlsserver' certs have an empty subject and PAN-OS rejects them ("missing subject field").
# Passed explicitly because Posh-ACME carries the old order's profile over otherwise.
if ($ca -like 'LE_*') { $certParams.Profile = 'classic' }
Write-Host 'Requesting the certificate. After adding the TXT record this waits about 2 minutes for DNS to update, with no output.'
$cert = New-PACertificate @certParams
$cert | Format-List Subject, AllSANs, NotAfter, Thumbprint

@{ Domain = $Domain[0]; Domains = $Domain -join ','; Contact = $Contact; Firewall = $Firewall; CertName = $CertName; ShopperId = $ShopperId
   ApiUser = $old.ApiUser; VerifyAddress = $verify; SkipCertCheck = $skip } | ConvertTo-Json | Set-Content "$Root\config.json"
while ($true) {   # cert is already issued; a mistyped firewall password shouldn't throw that away
    try { & "$Root\Update-PaloCert.ps1" -Root $Root -NewApiKey; break }
    catch {
        Write-Warning $_.Exception.Message
        if ($_.Exception.Message -match 'Invalid Credential') {
            Write-Host 'Wrong user/password, admin not committed yet, or role has no XML API access. Firewall: Monitor > Logs > System, filter ( subtype eq auth ), shows why.'
        }
        if (-not (Yes 'Try the firewall login again?')) { throw }
    }
}

$exe = (Get-Process -Id $PID).Path   # powershell.exe or pwsh.exe, whichever ran setup
$action = New-ScheduledTaskAction -Execute $exe -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$Root\Update-PaloCert.ps1`""
$trigger = New-ScheduledTaskTrigger -Daily -At $At
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 1)
Register-ScheduledTask 'PaloAcme Renew' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null

if (Yes 'Run the first deploy to the firewall now (as SYSTEM, via the task)?') {
    Start-ScheduledTask 'PaloAcme Renew'
    Write-Host "Started. Result in a minute or two: $Root\logs and Application log, source PaloAcme (1000 = OK, 1001 = failed)."
} else {
    Write-Host "Done. First deploy later: Start-ScheduledTask 'PaloAcme Renew'"
}
