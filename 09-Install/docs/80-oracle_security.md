# Step 20 – Post-Installation Security Hardening

**Runs as:** `root`
**When:** After Phase 7 (Validation) — once WebLogic / Forms / Reports have been
verified to run correctly. Not tied to a specific numbered install phase; this
is a manual checklist with no corresponding automation script.

---

## Overview

This checklist is carried out **after** installation and verification are complete.
During installation, temporary privileges were granted (e.g. NOPASSWD sudo) that
must now be revoked.

---

## 1 – Revert sudo Configuration

### Why

During the installation phase (scripts `01` through `05`), `oracle` was granted
NOPASSWD sudo so the scripts could run non-interactively via `sudo -n`. This is
an unnecessary security risk once installation is complete.

### Option A – Restore password requirement on the wheel group

If the relaxation was granted via the `wheel` group:

```bash
# Check current state
grep wheel /etc/sudoers
# %wheel  ALL=(ALL)  NOPASSWD: ALL   ← temporary install-time setting

# Edit safely
visudo

# Change the line from:
%wheel  ALL=(ALL)  NOPASSWD: ALL
# To:
%wheel  ALL=(ALL)  ALL
```

Verification:

```bash
# As oracle – must now prompt for a password (exit code != 0 without one)
sudo -n true 2>&1
# Expected output: sudo: a password is required
```

### Option B – Remove the sudoers drop-in

If the `/etc/sudoers.d/oracle-fmw` drop-in was created:

```bash
# Check its contents
cat /etc/sudoers.d/oracle-fmw

# Remove it
rm /etc/sudoers.d/oracle-fmw

# Safety check – no syntax errors in the remaining files
visudo -c
# Expected output: /etc/sudoers: parsed OK
```

---

## 2 – Remove sudo from the oracle User Entirely (optional, recommended)

If the `oracle` user needs no sudo access at all after installation:

```bash
# Remove from the wheel group
gpasswd -d oracle wheel

# Verify
id oracle
# groups= must no longer contain wheel

# Test
su - oracle -c "sudo -l"
# Expected output: User oracle is not allowed to run sudo on ...
```

> **Note:** Day-to-day WebLogic operation (NodeManager, AdminServer, Managed
> Servers) requires no sudo at all. The JVMs run as the `oracle` user without
> elevated privileges.
>
> Without sudo, the library scripts that need a root step later (`fc-cache` in
> the font scripts, `firewall-cmd` checks, systemd units of `30-` / ORDS,
> `13-root_reports_fix.sh`) do not fail – they **print the root command**
> (`ihw_run_root`) for an administrator to run.

---

## 3 – Post-Hardening Checklist

```bash
# sudo configuration – oracle must have no NOPASSWD entries left
sudo -l -U oracle | grep NOPASSWD
# Expected output: (empty)

# wheel group
grep wheel /etc/sudoers /etc/sudoers.d/* 2>/dev/null
# Must no longer contain NOPASSWD: ALL

# Drop-in file gone
ls -la /etc/sudoers.d/
# oracle-fmw must no longer appear

# oracle group membership
id oracle
# no wheel, no sudo
```

---

## 4 – Further Hardening Measures (Operations)

| Measure | Description | When |
|---|---|---|
| Remove sudo NOPASSWD | See sections 1 + 2 | After installation |
| SELinux | **Do NOT simply set `SELINUX=enforcing`** — Forms/Reports native libraries require SELinux disabled (see `01-root_os_baseline.sh` / `docs/00-root_set_os_parameter.md`). A proper, WLS-specific SELinux policy is a planned future improvement, not yet available | Not currently actionable |
| Review firewall rules | Only ports 80/443 open externally; 7001/9001/9002/5556 internal only | After installation |
| WebLogic Console: enforce HTTPS | Admin Console reachable only via SSL | After certificate setup |
| Rotate WebLogic passwords | Re-encrypt `boot.properties` | After initial installation |
| Clean up oracle `.bash_history` | Remove passwords from shell history | After initial installation |

Already applied by the library (check, do not redo):

| Measure | Where | Background |
|---|---|---|
| Every internal socket on `127.0.0.1` (WebLogic, Node Manager, Reports ORB, Coherence), Nginx the only entry | `08-`, `13-`, `02-Checks/clone_check.sh` | [clone_golden_image.md](../../80-FMW-Architecture/clone_golden_image.md) |
| WebLogic SSL demo listen ports (demo certificate) off | `08-`, `clone_check.sh --apply` | [doc 08](08-oracle_setup_domain.md#loopback-only-ssl-listen-ports-off-coherence-on-the-listen-address) |
| Client-supplied WebLogic proxy headers stripped, `X-Forwarded-For` overwritten | `09-Install/nginx-wls.conf.template` | [doc 05-root_nginx_ssl](05-root_nginx_ssl.md) |
| `/console`, `/em`, Reports admin web commands only from `ADMIN_IP_RANGE` | Nginx template (default `10.0.0.0/8` – narrow it, open item) | [doc 81](81-reports_rwservlet_security.md) |
| Secured Reports server (`REPORTS_SECURITY=ldap`), web-command rights | `12-`, `13-` | [reports_user_local_ldap.md](../../80-FMW-Architecture/reports_user_local_ldap.md) |
| Firewall + sshd hardening | `01-root_os_baseline.sh` | [doc 00-root_set_os_parameter](00-root_set_os_parameter.md#firewall-and-ssh-hardening-01-root_os_baselinesh-sections-8--9) |
| No outbound calls of the domain, external-DTD trap | `04-oracle_pre_checks.sh` (check 10), `02-Checks/egress_check.sh` | [weblogic_outbound_connections.md](../../80-FMW-Architecture/weblogic_outbound_connections.md) |
| Certificate expiry, CA quality | `10-Monitoring/cert_expiry_check.sh --cron --apply`, `02-Checks/ssl_check.sh` | [certificates_trust_stores.md](../../80-FMW-Architecture/certificates_trust_stores.md) |

---

## 5 – Password Recovery

Passwords cannot be "looked up" in a WebLogic domain – they are stored either
encrypted with the domain key (`security/SerializedSystemIni.dat`) or only as a
one-way hash. Recovery always means **setting a new value** at the right place.
Background – the key model, every store, the Node Manager cache and what to
observe for security: [fmw_pwd_handling.md](../../80-FMW-Architecture/fmw_pwd_handling.md).

### 5.1 Where the credentials live

| Credential | Location | Form | Read by |
|---|---|---|---|
| WebLogic admin user | embedded LDAP of the AdminServer (`servers/AdminServer/data/ldap/`) | hash | AdminServer (login, `connect()`) |
| Server boot identity – Node Manager cache | `servers/<ms>/data/nodemanager/boot.properties` (+ `startup.properties`), written by the NM when the AdminServer starts the server | `{AES256}…` (mode 640) | NM restarts / `nmStart` – **old identity after a password change**: delete it (server stopped) and start once via the AdminServer – [fmw_pwd_handling.md §3](../../80-FMW-Architecture/fmw_pwd_handling.md#3-the-node-managers-own-copy--datanodemanagerbootproperties) |
| Server boot identity | `servers/<server>/security/boot.properties` | cleartext until the first start, then `{AES256}…` (14.1.2; older releases `{AES}`) | server start via `startWebLogic.sh`/`startManagedWebLogic.sh`; `stopWebLogic.sh`/`stopManagedWebLogic.sh` without user/password |
| Node Manager user/password (domain side) | `config/config.xml` → `<security-configuration>`: `<node-manager-username>` (cleartext), `<node-manager-password-encrypted>{AES256}…` | encrypted | AdminServer, WLST; `startComponent.sh` takes the **user name** from here |
| Node Manager user/password (NM side) | `config/nodemanager/nm_password.properties` | `hashed=…` (one-way) | **the Node Manager itself** at every `nmConnect` |
| WLST stored credentials (`storeUserConfig()`, `startComponent.sh … storeUserConfig`) | `~/<os-user>-WebLogicConfig.properties` + `~/<os-user>-WebLogicKey.properties` (default), or the files given to `storeUserConfig` | encrypted + key | WLST `connect()`/`nmConnect()` **without** credentials, `startComponent.sh`/`stopComponent.sh` |
| Autostart key files (`30-configure_autostart.sh`) | `$ORACLE_BASE/admin/<domain>/ctrl/keyfile/` | encrypted + key | `fmw_ctl.sh` / systemd unit |
| IHateWeblogic passwords | `*.des3` in the repository root (`weblogic_sec.conf.des3`, `db_sys_sec.conf.des3`, `reports_users.conf.des3`, …) | `openssl des3`, key = system identifier | IHateWeblogic scripts (local helper `00-Setup/getPWDs.sh` displays them – gitignored) |
| Local CA root key (`08-SSL/ssl_local_ca.sh`) | `$SSL_CA_DIR/ca/ca.key` (default `$ORACLE_BASE/admin/pki`, dir 700, file 600); passphrase `SSL_CA_PASS` in `ssl_ca_sec.conf.des3` | AES-256 encrypted key | `ssl_local_ca.sh` when issuing server / code-signing certificates. Back up `SSL_CA_DIR` **and** the passphrase offline – the des3 file only works on this machine |
| Code-signing keystore (Forms/WebUtil `jacob.jar`) | `FORMS_SIGN_KEYSTORE` (PKCS12, 600); password `FORMS_SIGN_STOREPASS` in `forms_sign_sec.conf.des3` | PKCS12 | `ssl_local_ca.sh codesign`, `14-oracle_setup_forms.sh` (`jarsigner -storepass:file`, temp file 600, never on the command line) |

> Admin password and Node Manager password are **independent**.
> `<node-manager-username>weblogic` does not mean the NM password equals the
> admin password, and changing the admin password later does not change the
> NM password. A domain written by WLST offline in production mode without
> explicit NM credentials even gets a **random** NM user/password (confirmed
> 2026-10-15, e.g. user `o2HTp584LE`).

### 5.2 Node Manager password: `connect()` works, `nmConnect()` fails

Typical picture: `connect('weblogic', '<pw>', 't3://localhost:7001')` succeeds,
`nmConnect(...)` with the same password fails, or `startComponent.sh` keeps
asking "Please enter Node Manager password". The NM checks the hash in
`nm_password.properties`, which no longer matches. First rule out the other
causes: Node Manager running (`ss -ltn | grep ':5556'` – "Connection refused"
is not a password problem) and the right `nmType` (`plain` only with
`SecureListener=false` in `nodemanager.properties`, otherwise `ssl`).

**Check the Node Manager port and type first** (verified on the test host
2026-10-15):

```bash
# 1. Where the NM listens (its own configuration)
grep -E "^(ListenPort|ListenAddress|SecureListener)=" $DOMAIN_HOME/nodemanager/nodemanager.properties
#    SecureListener=false -> nmType 'plain', otherwise 'ssl'

# 2. Where the AdminServer connects to (Machine in the domain) - no
#    <listen-address>/<listen-port> means the defaults localhost/5556;
#    must match 1., otherwise the AdminServer cannot reach the NM
awk '/<node-manager>/,/<\/node-manager>/' $DOMAIN_HOME/config/config.xml

# 3. What really listens - expected: a LISTEN line owned by "java"
ss -ltnp | grep ':5556'

# 4. What the NM reported at its start ("Plain" or "SSL" socket listener)
grep -i "socket listener started" $DOMAIN_HOME/nodemanager/nodemanager.log | tail -1

# Reachability without a password
timeout 3 bash -c "echo > /dev/tcp/localhost/5556" && echo "port 5556 reachable"
```

**A – via WLST online (preferred, keeps both places consistent)** – the
AdminServer must run:

```python
connect('weblogic', '<WLS_ADMIN_PASSWORD>', 't3://localhost:7001')
edit(); startEdit()
cd('/SecurityConfiguration/<DOMAIN_NAME>')
cmo.setNodeManagerUsername('weblogic')
cmo.setNodeManagerPassword('<WLS_ADMIN_PASSWORD>')   # not set('NodeManagerPasswordEncrypted', ...):
save(); activate(block='true')                       # clear text is refused in production mode
disconnect(); exit()
```

On activation the AdminServer also rewrites `nm_password.properties`
(observed 2026-10-15: the file's timestamp equals the activation time). Then
restart the Node Manager – it reads the file only at startup:

```bash
$DOMAIN_HOME/bin/stopNodeManager.sh
nohup $DOMAIN_HOME/bin/startNodeManager.sh > $DOMAIN_HOME/nodemanager/nm_start.log 2>&1 &
```

Automated by `09-Install/11-oracle_nodemanager.sh --apply`.

**B – clear text in `nm_password.properties` (AdminServer not available)** –
the Node Manager accepts clear text there and replaces it by a hash at its
next start (Oracle-documented procedure; **live-tested on the test host
2026-10-15**: clear text written, NM restarted via `stopNodeManager.sh` /
`startNodeManager.sh`, listening again after ~4 s, file contained only
`hashed=…` afterwards, `nmConnect` OK – checked with
`11-oracle_nodemanager.sh` – and all servers kept running):

```bash
F=$DOMAIN_HOME/config/nodemanager/nm_password.properties
cp -p $F $F.bak_$(date +%Y%m%d_%H%M%S)
cat > $F << 'EOF'
username=weblogic
password=<WLS_ADMIN_PASSWORD>
EOF
chmod 640 $F
$DOMAIN_HOME/bin/stopNodeManager.sh
nohup $DOMAIN_HOME/bin/startNodeManager.sh > $DOMAIN_HOME/nodemanager/nm_start.log 2>&1 &
sleep 10
sed 's/=.*/=<...>/' $F        # must show "hashed=..." again
```

- Write the file only right before the restart – until then the password is
  in clear text on disk.
- Still `username=`/`password=` after the start → the NM did not read it
  (wrong `DOMAIN_HOME`, NM not really restarted).
- Afterwards run **A** as soon as the AdminServer is up – otherwise
  `config.xml` keeps the old NM password and the AdminServer fails when it
  starts servers via the Node Manager.

**Verify** (WLST):

```python
nmConnect('weblogic', '<WLS_ADMIN_PASSWORD>', 'localhost', '5556', '<DOMAIN_NAME>', '<DOMAIN_HOME>', 'plain')
nmDisconnect()
```

Then renew stored credentials that still contain the old password: section 5.4.

### 5.3 boot.properties (server dies at start / stop script cannot log in)

`boot.properties` is regenerated, never decrypted:

```bash
cat > $DOMAIN_HOME/servers/<server>/security/boot.properties << 'EOF'
username=weblogic
password=<WLS_ADMIN_PASSWORD>
EOF
chmod 600 $DOMAIN_HOME/servers/<server>/security/boot.properties
```

The server encrypts it on its next start (`{AES256}`). Automated by
`09-Install/10-oracle_boot_properties.sh --apply` (all servers from
`config.xml`, skips files that are already encrypted). Symptoms of a missing
file: `BEA-090782 … System Console … not found`, `shutDownStatus=255` at a
background start; `No valid username/password or userConfigFile/userKeyFile
provided` from `stopManagedWebLogic.sh` without user/password.

### 5.4 Stored WLST credentials after a password change

Files created with `storeUserConfig()` keep the password of the time they were
written. After an admin or NM password change, recreate them:

- `startComponent.sh <component> storeUserConfig` (writes
  `~/<os-user>-WebLogicConfig.properties` + `…Key.properties` if they do not
  exist – delete the old pair first), then `chmod 600` both files.
- Autostart key files: `09-Install/30-configure_autostart.sh --apply`.
- IHateWeblogic `*.des3`: `00-Setup/weblogic_sec.sh` (WebLogic),
  `00-Setup/database_rcu_sec.sh` (DB), `12-oracle_reports_users.sh` (Reports
  users).

> **Caution when testing:** the default pair in the oracle home is used
> silently by every WLST `connect()`/`nmConnect()` **without** credentials. It
> can hide a missing `boot.properties` or a wrong NM password in tests – move
> it aside temporarily when testing those cases (seen 2026-10-15).

### 5.5 WebLogic admin password lost

Not covered here in detail – it requires resetting the embedded LDAP of the
AdminServer (Oracle procedure: create a new admin with
`weblogic.security.utils.AdminAccount` in `$DOMAIN_HOME/security/`, move the
AdminServer's `data/ldap` aside, start the AdminServer, then reset the
original user's password). Follow the current MOS note for the exact steps
and take a full domain backup (`07-Maintenance/backup_config.sh --apply`)
before. Afterwards renew everything in 5.3 and 5.4.

---

## References

| Topic | Source |
|---|---|
| sudo configuration | `09-Install/docs/00-root_set_os_parameter.md` – Prerequisites section |
| Firewall ports | `09-Install/docs/00-root_set_os_parameter.md` – Verification section |
| SELinux requirement (must stay disabled) | `09-Install/01-root_os_baseline.sh` – Section 1 |
| WebLogic password concept | `00-Setup/weblogic_sec.sh` |
| Node Manager credentials (WLST) | `09-Install/11-oracle_nodemanager.sh`, `docs/11-oracle_nodemanager.md` |
| boot.properties | `09-Install/10-oracle_boot_properties.sh`, `docs/10-oracle_boot_properties.md` |
| Reports servlet / `<identifier>` | `docs/81-reports_rwservlet_security.md` |
