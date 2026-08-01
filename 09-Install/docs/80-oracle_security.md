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

---

## References

| Topic | Source |
|---|---|
| sudo configuration | `09-Install/docs/00-root_set_os_parameter.md` – Prerequisites section |
| Firewall ports | `09-Install/docs/00-root_set_os_parameter.md` – Verification section |
| SELinux requirement (must stay disabled) | `09-Install/01-root_os_baseline.sh` – Section 1 |
| WebLogic password concept | `00-Setup/weblogic_sec.sh` |
