# Palo Alto GlobalProtect – auto-renewing ACME certificate

Short-lived public cert for the GlobalProtect portal/gateway on a standalone PAN-OS 11.2 firewall, renewed and pushed by a
Windows scheduled task. Chosen at setup:

- **Certificate from:** Let's Encrypt (recommended), GoDaddy paid SSL, or Cloudflare / any other ACME CA by URL
- **DNS validation via:** GoDaddy DNS or Cloudflare DNS (auto-detected from the domain's nameservers)

**Why:** CA/B Forum max public TLS lifetime drops to 200 days (Mar 2026), 100 days (Mar 2027), 47 days (Mar 2029).
Setup uses the Let's Encrypt `classic` profile (90 days now, 64 days Feb 2027, 45 days Feb 2028). The 45-day `tlsserver` profile can't be used: its certs have no subject, and PAN-OS rejects them.
Manual renewal is no longer viable.

## Status

**Field-tested** (2026-10, PAN-OS 11.2 standalone, Windows Server 2022, PowerShell 7.6): Let's Encrypt production cert
with Cloudflare DNS, deployed to GlobalProtect and confirmed working with the Windows GP client and on iOS.

**Not yet field-tested:** a real renewal replacing an existing cert (T2b), the failure-revert call (T2c), GoDaddy DNS,
GoDaddy SSL (ACME/EAB), other ACME CAs, and Windows PowerShell 5.1 on a real server (syntax and mock tests only).

**Open issue:** least-privilege firewall role. Only Superuser works; custom roles, `cryptoadmin` and Device administrator all fail the import. See *Prerequisites → Firewall*.

## How it works

```
Windows box (daily task, SYSTEM)
  Posh-ACME ── DNS-01 TXT ──> GoDaddy DNS API  or  Cloudflare DNS API
     │  <── cert ───────────── Let's Encrypt  or  GoDaddy SSL (ACME + EAB)  or  other ACME CA
  Update-PaloCert.ps1 ── XML API (import cert, import key, partial commit) ──> firewall mgmt
     └── TLS handshake to portal FQDN: served thumbprint must match ──> event log
```

| Piece | What | Off-the-shelf? |
|---|---|---|
| [Posh-ACME](https://poshac.me) | ACME client, GoDaddy + Cloudflare DNS plugins, renewal timing (ARI) | Yes, PowerShell Gallery, maintained since 2018 |
| PAN-OS XML API calls | import cert / key, partial commit, job poll | Same calls as [acme.sh `deploy/panos.sh`](https://github.com/acmesh-official/acme.sh/blob/master/deploy/panos.sh) |
| `Update-PaloCert.ps1` | ~120 lines of glue: renew → deploy if changed → verify → log | Custom (no Windows-native PAN-OS deployer exists) |
| `Install-PaloAcme.ps1` | interactive one-time setup + scheduled task | Custom |

Renewal happens when Posh-ACME says it's due (about 2/3 of lifetime, or earlier if the CA's ARI says so). The
firewall only gets touched when the cert thumbprint differs from the last one successfully deployed, so a failed
push retries the next day automatically.

### Supported combinations

| Cert from ↓ / DNS at → | GoDaddy DNS | Cloudflare DNS |
|---|---|---|
| **Let's Encrypt** (free, auto-renewing) | GoDaddy API key | Cloudflare token |
| **GoDaddy SSL** (paid) | GoDaddy API key (also fetches ACME/EAB) | Cloudflare token + optional GoDaddy key to fetch ACME/EAB (or type them in) |
| **Cloudflare / other ACME CA** | GoDaddy API key | Cloudflare token |

**About "certificate from Cloudflare":** Cloudflare's Universal/Advanced certs live only on Cloudflare's proxy, and its
Origin CA certs are trusted only by that proxy, so neither can be used on the Palo for GP clients. GP can't sit behind
the Cloudflare proxy anyway. Cloudflare announced a public ACME CA on 2026-09-29 but isn't issuing yet. When it is,
pick "Cloudflare or another ACME CA" and enter its directory URL. No code change is needed.

## Prerequisites

**Windows box (on site)**
- Windows 10 1803+ / Server 2019+ (needs built-in `curl.exe`). Windows PowerShell 5.1 works; pwsh 7 is used if you run setup from it.
- Outbound 443 to the firewall mgmt IP, the CA (`acme-v02.api.letsencrypt.org`, `acme-staging-v02.api.letsencrypt.org`, or GoDaddy's ACME URL),
  and the DNS API (`api.godaddy.com` or `api.cloudflare.com`). Outbound DNS to `1.1.1.1` helps setup detect the DNS host.
- Can reach the GP portal FQDN on 443 (for the post-deploy check), or give setup the portal's IP for the check, or `none` to skip.

**DNS at GoDaddy**
- **Production** API key + secret (developer.godaddy.com → API Keys). Not OTE. **Write access is required**, because it creates/deletes `_acme-challenge` TXT records.
- Since April 2026 the DNS API works for accounts with 1+ domain (was 10+). Setup tests the key first; 403 = account not entitled.

**DNS at Cloudflare**: create an API token:
1. Cloudflare dashboard → profile icon → **My Profile → API Tokens → Create Token**.
2. Use the template **Edit zone DNS** (permission *Zone → DNS → Edit*).
3. **Zone Resources:** *Include → Specific zone →* your domain (e.g. `contoso.com`).
4. Optional: **Client IP Address Filtering** = the site's public IP. Leave **TTL** empty (a token that expires stops renewals).
5. **Continue to summary → Create Token** and copy it (shown once). Setup asks for it and checks it can see the zone.
- The GP portal's DNS record (`vpn.contoso.com`) must be **DNS only (grey cloud)**, not *Proxied*. GP and the served-cert check need to reach the Palo directly.
- If the zone has **CAA** records (DNS → Records, type CAA), they must allow your CA: `letsencrypt.org` for Let's Encrypt, `godaddy.com` / `starfieldtech.com` for GoDaddy.
  No CAA records = any CA allowed.

**Cert from GoDaddy (paid SSL)**
- An active GoDaddy SSL certificate with ACME available: GoDaddy → SSL → *Manage All → ACME Automation → ACME Setup*.
  Which plan: GoDaddy installs nothing on a Palo (its "AI-assisted" and "fully managed" installs target websites), so you only need ACME access. The **Automated DV SSL** plan ("unlimited SSLs per domain") looks like the ACME one. The basic **DV SSL** plan allows 1 credit and 2 refreshes a year, which won't cover 45-day renewals. Before buying, ask GoDaddy: "does this plan include ACME / EAB credentials?". If ACME issuance fails with "no available product", your plan doesn't include it.
- Your GoDaddy customer number (account menu) plus a GoDaddy API key, so setup can fetch the ACME details automatically.
  Without them, copy the directory URL / EAB Key ID / Key Data from the ACME Setup page when asked.
- Not available to API reseller accounts. GoDaddy ACME issues **DV** certs (same level as Let's Encrypt).

**DNS somewhere else:** move the zone to GoDaddy/Cloudflare, or add a permanent CNAME `_acme-challenge.vpn.contoso.com → _acme-challenge.<a zone you host at Cloudflare/GoDaddy>`
and use Posh-ACME's `-DnsAlias` (not wired into setup).

**Firewall (PAN-OS 11.2)**
1. **Admin role: Superuser required (open issue).** On PAN-OS 11.2.15 and 11.2.16 only the built-in **Dynamic → Superuser** role works.
   Every failing test below used a fresh key (role change committed, then `-NewApiKey`, then `-Force`). What failed:
   - A custom role (*Device → Admin Roles*, Role = Device) with XML API `Import`, `Commit` and `Operational Requests`.
     It still failed with **every** Web UI, XML API and REST API permission enabled and Command Line = superuser.
     `type=keygen` works, but `type=import&category=certificate` returns
     `403 User not authorized to perform this operation.`
   - The built-in role-based profile `cryptoadmin`: `403 API Error: Type [import] not authorized for user role.`
   - The built-in **Dynamic → Device administrator**: same `403 User not authorized to perform this operation.`
   - Also ruled out: the API key format (fails with a key made under an API Key Certificate too), and overwriting an in-use cert (fails importing to a new name too).

   - `category=keypair` (cert + key in one PKCS#12 upload, see `Test-PanImportRole.ps1 -Category keypair`): same 403.

   This contradicts the acme.sh `panos.sh` docs (XML API Import + Commit on PAN-OS 9.1+), whose import calls are the same as ours.
   It looks like a regression of earlier fixes for the same symptom: PAN-126205 (8.1.14), PAN-152762 (9.1.7), PAN-199570 (10.1.8 / 10.2.4).
   `Test-PanImportRole.ps1` reproduces it with a throwaway cert and no commit.

   Until this is resolved, use Superuser and rely on the mitigations under *Security notes* (Permitted IP, a locked-down server).
   If you find a narrower role that passes `Update-PaloCert.ps1 -Force`, please contribute it.
2. *Device → Administrators → Add* `acme-api`: Administrator Type **Dynamic → Superuser** for now (see 1), long random password, password profile that **never expires**.
   The API key is derived from the password, so a password change/expiry breaks it. Also check *Device → Setup → Management → Authentication Settings → API Key Lifetime* (0 = never).
3. **API Key Certificate** (removes the commit warning about the deprecated keygen algorithm): *Device → Certificate Management → Certificates → Generate* `api-key-cert`: self-signed, **Certificate Authority checked**, RSA **3072 or larger**, shared (not in a vsys), long expiry (~10 years: keys also die when it expires). Then set *Device → Setup → Management → Authentication Settings → API Key Certificate* = `api-key-cert`, and commit. **Never use the ACME cert here**: it changes on every renewal. Changing this cert invalidates all existing API keys, so do it **before** setup, or afterwards run `pwsh -ExecutionPolicy Bypass -File C:\ProgramData\PaloAcme\Update-PaloCert.ps1 -NewApiKey`.
4. *Device → Setup → Interfaces → Management → Permitted IP*: include the Windows box.
5. Mgmt cert: either have the Windows box trust it (import the firewall's mgmt cert/CA into *Local Computer → Trusted Root*; its SAN must match the firewall address you give setup, and the factory cert won't), or answer yes when setup offers to connect without verifying (encrypted but not authenticated). Most sites end up there; pair it with the Permitted IP restriction.

## Install

Copy this folder to the Windows box. In an **elevated** PowerShell (pwsh 7 preferred, 5.1 OK):

```powershell
pwsh -ExecutionPolicy Bypass -File .\Install-PaloAcme.ps1
# no PowerShell 7? use powershell instead of pwsh (the daily task uses whichever runs setup)
```

> **You never create the Let's Encrypt certificate (or an account) by hand.** This setup script creates both. It registers a Let's Encrypt account using your email, proves you own the name with a temporary TXT record, receives the cert, and pushes it to the firewall. After that, the daily task renews it the same way.

No switches to remember. Setup asks, validates, and shows a summary to confirm before changing anything:

1. **Where the certificate comes from.** "Get the certificate from Let's Encrypt (recommended)?" If you answer no:
   1) GoDaddy paid SSL · 2) Cloudflare or another ACME CA (asks for the directory URL) · 3) Let's Encrypt STAGING (test; defaults the object name to `acme-test` and turns off the served-cert check) · 4) Back.
2. **Names** on the cert (GP portal FQDN first, extra SANs comma-separated).
3. **DNS host.** Setup looks up the zone's public nameservers: "DNS for contoso.com is hosted at Cloudflare. Use the Cloudflare API?"
   No, or not detected → choose Cloudflare / GoDaddy / Cancel. Picking a provider the nameservers don't point to is refused (the CA wouldn't see the record).
4. Contact email, firewall mgmt address (setup connects right away; untrusted mgmt cert → asks, default no), **cert object name** on the firewall.
5. **Served-cert check address** (portal FQDN by default, an IP if the name doesn't resolve from inside, or `none`).
6. **Summary → Proceed?** Nothing is installed before this.
7. Then: creates `C:\ProgramData\PaloAcme` (SYSTEM + Administrators only), installs Posh-ACME, asks for the
   **GoDaddy key or Cloudflare token and tests it** (retry, or stop), gets the GoDaddy ACME/EAB details if that CA was chosen
   (EAB prompt for other CAs if they need it), issues the cert (Let's Encrypt: `classic` profile; key reused on renewal, see Key rotation),
   asks for the `acme-api` firewall login to create the API key, registers task **PaloAcme Renew** (daily 03:17, SYSTEM),
   and offers to run the first deploy.

Re-running setup offers the previous answers as defaults: staging → production, switching CA or DNS provider, or a new key/token.
A new cert has a new thumbprint, so the next task run pushes it into the same object.
(`-At HH:mm` changes the task time.)

## Test plan (do in order)

| # | Step | Proves |
|---|---|---|
| T0 | Setup's DNS API check passes (GoDaddy key or Cloudflare token) | Credential works and can reach the zone |
| T1 | Setup, answer **no** → **Let's Encrypt STAGING**, accept defaults (`acme-test`, check `none`), your real DNS provider. A cert is issued. **Do this even if you'll use a GoDaddy cert**, since GoDaddy has no staging | DNS credentials + DNS-01 work end to end, no prod rate limits burned |
| T2a | `Start-ScheduledTask 'PaloAcme Renew'` → event 1000. On firewall *Device → Certificates*: `acme-test` exists, has key, chain includes the intermediate. Note the serial | First import of fullchain + key works on 11.2. Nothing production references `acme-test` |
| T2b | **Real renewal path:** elevated: `$env:POSHACME_HOME='C:\ProgramData\PaloAcme\posh-acme'; Import-Module Posh-ACME; Submit-Renewal -Force`, then run the task again. Firewall shows a **new serial**, still with key, commit `OK` | In-place overwrite of an existing cert object. (`Update-PaloCert.ps1 -Force` re-pushes the *same* cert and proves nothing here) |
| T2c | Prove the failure-revert call is valid for this role: `curl.exe -k -d "type=op" -d "key=<apikey.txt>" --data-urlencode "cmd=<revert><config><partial><admin><member>acme-api</member></admin></partial></config></revert>" https://10.0.0.1/api/` → `status="success"` | The safety net is the one call not borrowed from acme.sh |
| T3 | Log in `C:\ProgramData\PaloAcme\logs` shows commit job `OK`; *Monitor → Logs → Configuration* shows the commit by `acme-api` | Partial commit + polling with the restricted role |
| T3g | **GoDaddy cert only:** re-run setup, choose **GoDaddy SSL**, keep `acme-test` and check `none`. Cert issued, task → 1000, firewall shows a GoDaddy-issued `acme-test`. If account creation fails with an EAB/key error, re-run and type the Key Data from the ACME Setup page (manual path) | Only the GoDaddy ACME/EAB step is new here; everything else was proven with staging |
| T4 | Re-run setup, choose the production CA, object name `gp-acme`, served-cert check = portal FQDN/IP. Run the task → **expect 1001 "serves X, expected Y"**, because the portal still uses the old cert. Now **once, by hand**: SSL/TLS Service Profile used by the GP portal/gateway → certificate `gp-acme` → commit. Run task again → **1000**. Check the served chain (below) has ≥ 2 certs | Production cert. The retry works because the thumbprint is only saved after verification. From now on renewals overwrite `gp-acme` in place |
| T5 | Break it (e.g. wrong IP in `config.json` `Firewall`), run task → event **1001**, confirm your RMM alerts. Restore | Unattended run as SYSTEM + alerting |

External checks (Git Bash / Linux). The script only compares the leaf thumbprint, so check the chain by hand:
```
openssl s_client -connect vpn.contoso.com:443 -servername vpn.contoso.com -showcerts </dev/null 2>/dev/null | grep -c 'BEGIN CERTIFICATE'   # must be >= 2
openssl s_client -connect vpn.contoso.com:443 -servername vpn.contoso.com </dev/null 2>/dev/null | openssl x509 -noout -dates -serial
```

**If T2b fails** (PAN-OS rejects the new cert against the stored key), re-import with the key first: swap the two
`Pan ... '?type=import'` lines in `Update-PaloCert.ps1`. If T2a shows no intermediate, import the CA's intermediate
once as a CA cert (*Device → Certificates → Import*, no key).

Delete the `acme-test` cert from the firewall after T4.

## Optional: same cert for the admin web UI

Same mechanism, no second install. Add the firewall's management name to the cert and point the management SSL/TLS
profile at the same object. Every renewal then updates GP and the admin UI together. Do this **after GP go-live works**.

1. **Pick a name** in the same public zone, e.g. `fw.contoso.com`. It does **not** need a public A record (validation only
   writes a TXT record). Add an internal DNS A record → mgmt IP.
   Cert names are published in public Certificate Transparency logs, so anyone can see the name exists. Use a non-obvious name, or skip this if that's a concern.
2. **Re-run setup**, keep everything, names = `vpn.contoso.com, fw.contoso.com` (GP name first). A new cert is issued and pushed into `gp-acme`.
3. **Firewall, once:** *Device → Certificate Management → SSL/TLS Service Profile → Add* `mgmt-acme`, certificate `gp-acme`, min TLSv1.2.
   Then *Device → Setup → Management → General Settings (gear) → SSL/TLS Service Profile* = `mgmt-acme` → **Commit**.
   The web UI restarts (you'll be logged out). Browse to `https://fw.contoso.com`: no warning.
4. **Optional bonus:** re-run setup with firewall address `fw.contoso.com`. The mgmt cert is now trusted, so setup verifies it (no "connect without verifying").

**Locked out of the GUI?** SSH or console to the CLI: `configure` → `delete deviceconfig system ssl-tls-service-profile` → `commit`.
The admin UI goes back to the default self-signed cert.

The daily script rides out the web-server restart during commit (job polling retries). A *separate* cert for the admin UI
(different name/CA) would need a second install and isn't supported by setup.

## Operations

**Monitoring:** source `PaloAcme` in the Application log. Alert your RMM on:

| ID | Level | Meaning |
|---|---|---|
| 1000 | Info | New cert deployed and verified |
| 1002 | Info | Daily check, up to date. **Alert if absent for 2+ days** (task not running) |
| 1001 | Error | Renewal/deploy/verify failed. Details in event + `logs\` |
| 1003 | Error | Cert expires in < 10 days and hasn't renewed |

Renewal starts when a third of the lifetime is left (30 days on a 90-day cert, about 15 on a 45-day one), so you have at least two weeks to act on a 1001.

**Files:** `C:\ProgramData\PaloAcme\` contains `config.json` (settings), `apikey.txt` (PAN API key), `deployed-thumbprint.txt`, `posh-acme\` (ACME account/keys/certs, DNS API credentials), `logs\` (90-day retention).

**Common tasks**
- API key broke (password changed / 403 / "Invalid credential"): `pwsh -ExecutionPolicy Bypass -File C:\ProgramData\PaloAcme\Update-PaloCert.ps1 -NewApiKey`
- Force a re-push: `pwsh -ExecutionPolicy Bypass -File C:\ProgramData\PaloAcme\Update-PaloCert.ps1 -Force`
- New GoDaddy key / Cloudflare token, or switch CA or DNS provider: re-run `Install-PaloAcme.ps1` (previous answers are defaults), which re-issues and redeploys.
- Rollback: firewall config audit/rollback (*Device → Setup → Operations → Load config version*) or point the SSL/TLS service profile back at the previous cert.

**If a deploy fails mid-way**, the script reverts `acme-api`'s candidate changes so no half-imported cert/key is
picked up by the next human commit. If the revert also fails, the 1001 event says so. Check *Commit → Preview Changes* before committing.

## Troubleshooting

| Symptom | Cause → fix |
|---|---|
| GoDaddy check 401 / 403 | Wrong or OTE key / account not entitled to the API |
| Cloudflare check 401 / 403 | Wrong, revoked or expired token |
| Cloudflare "can't see zone" | Token's Zone Resources doesn't include this zone |
| "not GoDaddy or Cloudflare" at setup | Zone is hosted elsewhere: move it or CNAME-delegate `_acme-challenge` |
| Issuance fails with CAA error | Add a CAA record allowing your CA, or remove restrictive CAA records |
| Served-cert check fails, cert looks right in GUI | Portal record proxied (orange cloud) in Cloudflare: set DNS only |
| "Couldn't get ACME details from the GoDaddy API" | Wrong customer number / reseller account: type the values from the ACME Setup page |
| GoDaddy order fails with "no available product" | Your GoDaddy SSL plan has no ACME issuance left (basic DV: 1 credit, 2 refreshes a year). Use the Automated DV SSL plan, or Let's Encrypt |
| 1001 "Import of … failed. missing subject field" | The cert has no subject (Let's Encrypt `tlsserver` profile). Setup now always asks for `classic`: re-run setup |
| "You do not have an available product" (GoDaddy) | No active SSL purchase/credit linked to those ACME credentials |
| 1001 `(import certificate)` 403 "User not authorized to perform this operation" | Role-based admin, even with everything enabled. Use Dynamic → Superuser (see *Prerequisites → Firewall*) |
| 1001 403 "Type [import] not authorized for user role" | The role's XML API tab doesn't allow Import |
| 1001 "Invalid credential" / 403 from firewall | `acme-api` password or role changed, or the API Key Certificate changed (each invalidates the key): `Update-PaloCert.ps1 -NewApiKey` |
| 1001 "serves X, expected Y" | Expected once at go-live; otherwise GP profile uses another cert, or check address is wrong |
| 1001 "REVERT ALSO FAILED" | Before anyone commits: *Commit → Preview Changes*, revert `acme-api`'s changes |

## Key rotation
Default reuses the private key across renewals: the cert still rotates every ~30 days. This is the acme.sh
default and the field-proven PAN-OS path. To get a fresh key every renewal, after T2b passes:
`$env:POSHACME_HOME='C:\ProgramData\PaloAcme\posh-acme'; Import-Module Posh-ACME; Set-PAOrder -AlwaysNewKey`,
then repeat T2b (`Submit-Renewal -Force` + task) on the staging/test object to prove PAN-OS accepts a cert+key swap.

## Security notes
- Secrets live under an ACL'd folder readable only by SYSTEM/Administrators. Posh-ACME "alt plugin encryption" is used so the SYSTEM task can read the DNS API secret. Anyone who is local admin on this box can read the secrets, so treat the box as tier-0 for the firewall cert.
- The API key is passed to curl on stdin, never the command line, so process-creation auditing doesn't log it.
- A GoDaddy key can edit all DNS in that account. A Cloudflare token can be limited to one zone and DNS only, which is preferred.
- `acme-api` currently needs **Superuser** (see *Prerequisites → Firewall*), so a stolen API key means full control of the firewall from any address allowed to reach the mgmt interface. Restrict *Permitted IP* to this server.

**Where secrets are stored** (all under `C:\ProgramData\PaloAcme`, folder ACL = SYSTEM + Administrators, inheritance removed):

| Secret | File | Protection |
|---|---|---|
| Firewall API key | `apikey.txt` | Plain text, folder ACL only |
| Cloudflare token / GoDaddy key | `posh-acme\...\pluginargs.json` | Posh-ACME alt plugin encryption; its AES key sits in the same folder, so in practice the folder ACL |
| ACME account key, cert private key | `posh-acme\...` | Folder ACL |

The `acme-api` password is never stored; it is only used once to generate the API key. Any unattended renewal job has to
be able to read its own credentials, so the real controls are a narrow firewall role, Permitted IP, and limiting who is
admin on this box.

## Known limits
- Standalone firewall only. HA pair: run against the active unit (config sync carries it). Panorama: cert must go into the template and be pushed (acme.sh's `panos.sh` shows the template params). Not implemented here.
- PAN-OS import format (PEM fullchain + unencrypted key with dummy passphrase) is the field-proven acme.sh method. T2 validates it on your firewall.
- DNS providers other than GoDaddy/Cloudflare need CNAME delegation. Posh-ACME supports ~60 providers if you want to add one to setup.
- Server 2016 lacks `curl.exe`. Install curl and adjust the path, or use 2019+.

## License

MIT, see [LICENSE](LICENSE). Posh-ACME (MIT) is installed from the PowerShell Gallery at setup, not bundled.
