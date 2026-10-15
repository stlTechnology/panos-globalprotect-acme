#Requires -Version 5.1
# Renews the ACME cert when due (Posh-ACME) and pushes it to the Palo Alto when it changed.
# Run daily as SYSTEM by the "PaloAcme Renew" scheduled task. Works on Windows PowerShell 5.1 and pwsh 7.
#   -NewApiKey  prompt for the PAN-OS API admin and (re)generate the stored API key
#   -Force      re-import + commit even if the firewall already has the current cert
param(
    [string]$Root = "$env:ProgramData\PaloAcme",
    [switch]$NewApiKey,
    [switch]$Force
)
$ErrorActionPreference = 'Stop'
$env:POSHACME_HOME = "$Root\posh-acme"
$cfg = Get-Content "$Root\config.json" -Raw | ConvertFrom-Json

function Log($msg, $type = 'Information', $id = 1000) {
    Write-Output $msg
    [Diagnostics.EventLog]::WriteEntry('PaloAcme', $msg, $type, $id)
}

# POST to the PAN-OS XML API. Fields go to curl on stdin (-K -) so the API key never shows up
# on a command line (process auditing / 4688 would log it). Same calls as acme.sh deploy/panos.sh.
function Pan([hashtable]$fields, [string]$file, [string]$query = '') {
    $q = { '"' + ($args[0] -replace '\\', '\\' -replace '"', '\"') + '"' }
    $verb = if ($file) { 'form-string' } else { 'data-urlencode' }
    $lines = @(foreach ($k in $fields.Keys) { "$verb = " + (& $q "$k=$($fields[$k])") })
    if ($file) { $lines += 'form = ' + (& $q "file=@$file") }
    $curlArgs = @('-sS', '--max-time', '300', '-K', '-', "https://$($cfg.Firewall)/api/$query")
    if ($cfg.SkipCertCheck) { $curlArgs = @('-k') + $curlArgs }
    $out = ($lines -join "`n") | & "$env:SystemRoot\System32\curl.exe" @curlArgs
    if ($LASTEXITCODE) { throw "curl exit $LASTEXITCODE talking to $($cfg.Firewall)" }
    $x = [xml]($out -join "`n")
    $what = if ($file) { "import $($fields.category)" } else { $fields.type }   # names the denied step when tuning the role
    if ($x.response.status -ne 'success') { throw "PAN-OS error ($what): $($out -join ' ')" }
    $x
}

if ($NewApiKey) {
    $cred = Get-Credential -Message "PAN-OS XML-API admin on $($cfg.Firewall)"
    $r = Pan @{ type = 'keygen'; user = $cred.UserName; password = $cred.GetNetworkCredential().Password }
    Set-Content "$Root\apikey.txt" $r.response.result.key -NoNewline
    $cfg.ApiUser = $cred.UserName
    $cfg | ConvertTo-Json | Set-Content "$Root\config.json"
    Write-Output "API key stored for $($cred.UserName)."
    return
}

Start-Transcript "$Root\logs\$(Get-Date -Format yyyyMMdd-HHmmss).log" | Out-Null
Get-ChildItem "$Root\logs" | Where-Object LastWriteTime -lt (Get-Date).AddDays(-90) | Remove-Item
$imported = $false
try {
    Import-Module Posh-ACME
    Submit-Renewal -MainDomain $cfg.Domain -WarningAction SilentlyContinue | Out-Null  # no-op until due
    $cert = Get-PACertificate $cfg.Domain
    if (-not $cert) { throw "Posh-ACME has no certificate for $($cfg.Domain). Re-run Install-PaloAcme.ps1." }
    if ($cert.NotAfter -lt (Get-Date).AddDays(10)) {
        Log "Certificate $($cert.Thumbprint) expires $($cert.NotAfter) and has not renewed." 'Error' 1003
    }

    $stateFile = "$Root\deployed-thumbprint.txt"
    $deployed = if (Test-Path $stateFile) { (Get-Content $stateFile -Raw).Trim() } else { '' }
    if ($cert.Thumbprint -eq $deployed -and -not $Force) {
        Log "Up to date: $($cert.Thumbprint), expires $($cert.NotAfter)." 'Information' 1002
        return
    }

    $key = (Get-Content "$Root\apikey.txt" -Raw).Trim()
    $common = @{ key = $key; 'certificate-name' = $cfg.CertName; format = 'pem' }
    Pan ($common + @{ category = 'certificate' }) $cert.FullChainFile '?type=import' | Out-Null
    $imported = $true   # candidate config now changed; revert on any later failure
    # key from Posh-ACME is unencrypted; PAN-OS wants a passphrase field anyway (acme.sh does the same)
    Pan ($common + @{ category = 'private-key'; passphrase = 'unused' }) $cert.KeyFile '?type=import' | Out-Null

    # Partial commit: only this admin's changes, never someone's half-finished work.
    $r = Pan @{ type = 'commit'; action = 'partial'; key = $key
        cmd = "<commit><partial><admin><member>$($cfg.ApiUser)</member></admin></partial></commit>" }
    $job = $r.response.result.job
    if ($job) {
        for ($i = 0; $i -lt 60; $i++) {
            Start-Sleep 10
            # if this cert is also the admin UI cert, the mgmt web server restarts mid-commit: ride out the drop
            try { $j = (Pan @{ type = 'op'; key = $key; cmd = "<show><jobs><id>$job</id></jobs></show>" }).response.result.job }
            catch { Write-Output "Job poll retry: $($_.Exception.Message)"; continue }
            if ($j.status -eq 'FIN') { break }
        }
        if ($j.status -ne 'FIN') { throw "Commit job $job still $($j.status) after 10 minutes." }
        if ($j.result -ne 'OK') { throw "Commit job $job failed: $($j.details.OuterXml)" }
    } else {
        Write-Output "No commit job returned: $($r.response.OuterXml)"
    }
    $imported = $false

    # Prove the portal now serves the new cert (exact thumbprint match beats chain validation here).
    if ($cfg.VerifyAddress) {
        for ($i = 1; $true; $i++) {
            $tcp = New-Object Net.Sockets.TcpClient($cfg.VerifyAddress, 443)
            try {
                $ssl = New-Object Net.Security.SslStream($tcp.GetStream(), $false, { $true })
                $ssl.AuthenticateAsClient($cfg.Domain, $null, [Security.Authentication.SslProtocols]::Tls12, $false)
                $served = ([Security.Cryptography.X509Certificates.X509Certificate2]$ssl.RemoteCertificate).Thumbprint
            } finally { $tcp.Dispose() }
            if ($served -eq $cert.Thumbprint) { break }
            if ($i -ge 3) { throw "$($cfg.VerifyAddress) serves $served, expected $($cert.Thumbprint)." }
            Start-Sleep 20
        }
    }

    Set-Content $stateFile $cert.Thumbprint -NoNewline
    Log "Deployed $($cert.Thumbprint) as '$($cfg.CertName)' to $($cfg.Firewall), expires $($cert.NotAfter)."
} catch {
    $msg = "PaloAcme failed: $($_.Exception.Message)"
    if ($_.Exception.Message -match 'Invalid credential') { $msg += ' (API key bad/expired? run Update-PaloCert.ps1 -NewApiKey)' }
    if ($_.Exception.Message -match 'not authorized') { $msg += ' (acme-api role is missing a permission; see README Prerequisites > Firewall)' }
    if ($imported) {
        # Don't leave a half-imported cert/key in the candidate config for the next human commit.
        try {
            Pan @{ type = 'op'; key = $key
                cmd = "<revert><config><partial><admin><member>$($cfg.ApiUser)</member></admin></partial></config></revert>" } | Out-Null
            $msg += ' Candidate changes reverted.'
        } catch { $msg += " REVERT ALSO FAILED, check candidate config before any commit: $($_.Exception.Message)" }
    }
    Log $msg 'Error' 1001
    exit 1
} finally {
    Stop-Transcript | Out-Null
}
