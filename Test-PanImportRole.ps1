#Requires -Version 5.1
# Minimal repro: can this PAN-OS admin import a certificate through the XML API?
# Generates an API key for the admin you enter, then imports a throwaway self-signed cert as -CertName.
#   -Category certificate  PEM cert only (the first call Update-PaloCert.ps1 / acme.sh deploy/panos.sh make)
#   -Category keypair      cert + private key in one PKCS#12 upload
# Nothing is committed.
param(
    [Parameter(Mandatory)][string]$Firewall,
    [string]$CertName = 'api-import-test',
    [ValidateSet('certificate', 'keypair')][string]$Category = 'certificate',
    [switch]$SkipCertCheck
)
$ErrorActionPreference = 'Stop'
$cred = Get-Credential -Message "PAN-OS admin to test on $Firewall"

# Fields go to curl on stdin (-K -) so the password and key never show up on a command line.
function Pan([string[]]$lines, [string]$query = '') {
    $curlArgs = @('-sS', '--max-time', '60', '-K', '-', "https://$Firewall/api/$query")
    if ($SkipCertCheck) { $curlArgs = @('-k') + $curlArgs }
    $out = ($lines -join "`n") | & "$env:SystemRoot\System32\curl.exe" @curlArgs
    if ($LASTEXITCODE) { throw "curl exit $LASTEXITCODE talking to $Firewall" }
    [xml]($out -join "`n")
}
function Q($s) { '"' + ($s -replace '\\', '\\' -replace '"', '\"') + '"' }

$r = Pan @(('data-urlencode = ' + (Q 'type=keygen')),
    ('data-urlencode = ' + (Q "user=$($cred.UserName)")),
    ('data-urlencode = ' + (Q "password=$($cred.GetNetworkCredential().Password)")))
if ($r.response.status -ne 'success') { "keygen: $($r.response.OuterXml)"; exit 1 }
$key = $r.response.result.key
'keygen: success'

$rsa = [Security.Cryptography.RSA]::Create(2048)
$req = New-Object Security.Cryptography.X509Certificates.CertificateRequest("CN=$CertName", $rsa,
    [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
$c = $req.CreateSelfSigned((Get-Date), (Get-Date).AddDays(1))
$file = Join-Path ([IO.Path]::GetTempPath()) "$CertName.tmp"
if ($Category -eq 'keypair') {
    $pass = [guid]::NewGuid().ToString('N')
    [IO.File]::WriteAllBytes($file, $c.Export('Pfx', $pass))
    $extra = @(('form-string = ' + (Q 'format=pkcs12')), ('form-string = ' + (Q "passphrase=$pass")))
} else {
    "-----BEGIN CERTIFICATE-----`n$([Convert]::ToBase64String($c.RawData, 'InsertLineBreaks'))`n-----END CERTIFICATE-----" |
        Set-Content $file -Encoding Ascii
    $extra = @(('form-string = ' + (Q 'format=pem')))
}
try {
    $r = Pan (@(('form-string = ' + (Q "key=$key")), ('form-string = ' + (Q "category=$Category")),
        ('form-string = ' + (Q "certificate-name=$CertName")), ('form = ' + (Q "file=@$file"))) + $extra) '?type=import'
    "import ${Category}: $($r.response.OuterXml)"
} finally { Remove-Item $file }
"Nothing was committed. If the import succeeded, '$CertName' is in the candidate config: revert it or delete it."
