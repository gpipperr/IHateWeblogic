# EM "Add Principal" finds no users – libOVD and the lock of the Reports server

**Scope:** FMW 14.1.2.0.0 (CSPU Sep 2026, Reports QPR 39600348), Forms/Reports
domain with JRF, Enterprise Manager Fusion Middleware Control on the
AdminServer, standalone Reports server (`ReportsServerComponent`). Found at a
customer and on the test host on 2026-10-16. Sources: ODL trace of the
AdminServer, the libOVD configuration files, `repserver01.out`, two controlled
restarts on the test host.

Markers as in [README.md](README.md): **confirmed (code)**, **confirmed
(live)**, **documented**, **assumption**.

---

## 1. Symptom

EM → WebLogic Domain → Security → Application Roles → role (e.g.
`RW_MONITOR`, stripe `reports`) → Edit → Members → Add → dialog *Add
Principal*, Type = User, search `>`: **no result** – no user, not even the
administrator. No error in the AdminServer log, the diagnostic log or
`sysman/log/emoms.log`.

At the same time:

- the users exist (WLST `cmo.listUsers('*', 0)` on the `DefaultAuthenticator`),
- `grantAppRole` via WLST works (writes the principal into the policy store
  without any search),
- the dialog option *Advanced Option* (enter the principal name manually)
  works.

## 2. How the EM searches users (confirmed (live), trace)

The EM search does **not** ask the WebLogic security realm directly. Stack of
the search (ODL trace, loggers `oracle.igf*`, `oracle.ods.virtualization`):

```
EditAppRolePageModel.searchPrincipal
 -> UserRoleUtil.fetchUserListIGF
 -> oracle.igf.ids.UserManager.searchUsers
 -> ArisIdServiceManager.searchEntities
 -> com.oracle.ovd.arisid.OvdIdsStackProvider.doSearch     (libOVD)
```

OPSS identity store of the domain (`config/fmwconfig/jps-config.xml`, context
`default`): `idstore.ldap` with `WlsLdapIdStoreConfigProvider` – it hands the
LDAP authenticators of the domain to libOVD (`AdminServer.out`: *Pushed ldap
name and types info to libOvd. Ldaps : DefaultAuthenticator:…*). libOVD keeps
its adapters in `config/fmwconfig/ovd/default/adapters.os_xml`.

In the failing case the trace shows the search with an **empty base**:

```
IGF Search interaction:
 Base:
 Filter: (&(objectclass=person)(uid=mon*))
```

and `adapters.os_xml` contains only the XML adapter
`<ghost id="idstore.xml">` (`dc=jazn.com`, `system-jazn-data.xml`) – **no**
`<ldap id="DefaultAuthenticator">` adapter. In the working case the file has
the LDAP adapter (`root ou=myrealm,dc=<domain>`, `serverType WLS_OVD`, host
`%HOST%`, port `-1` – filled in at runtime).

## 3. Who breaks it: the Reports server (confirmed (live))

The standalone Reports server (`rwserver`, Java SE – *Current Platform is not
weblogic*) initialises OPSS with `config/fmwconfig/jps-config-jse.xml`
(identity store `idstore.xml`) and libOVD in the **same** directory
`config/fmwconfig/ovd/default`:

```
repserver01.out:
  LibOvdUtil pushLdapDataToLibOvd  WARNING: Current Platform is not weblogic
  ... DO_NOT_PUSH_DATA_LIBOVD value : null
  LibOvdUtil pushLdapNamesToLibOvd INFO: Pushed ldap name and types info to libOvd.
        Ldaps : …system-jazn-data.xml idstore.xml…
```

At every start of the Reports server, in the same second:

- `adapters.os_xml` is rewritten with only the XML adapter,
- `ovd.lok` is created and **left behind** (not held open by any process –
  checked in `/proc/<pid>/fd` of `rwserver` and the engines).

An AdminServer that starts while `ovd.lok` exists builds no LDAP adapter for
the `DefaultAuthenticator` → empty EM search. Why the lock blocks it exactly
is not read from the code (**assumption**: libOVD does not store/initialise its
config while the lock file exists); the effect is reproducible.

This is **not** the WebLogic edit lock (*Lock & Edit*):
`getConfigManager().getCurrentEditor()` = `None`, `$DOMAIN_HOME/pending/`
empty.

## 4. Test series (test host, 2026-10-16)

| Step | `adapters.os_xml` / `ovd.lok` | EM search |
|---|---|---|
| Domain started normally (lock from the last Reports server run present) | XML adapter only, `ovd.lok` present | empty |
| AdminServer stopped, `ovd.lok` moved away, AdminServer started (managed servers + Reports server keep running) | rewritten at AdminServer start **with** `DefaultAuthenticator` LDAP adapter, no lock | **users found** |
| Then only the Reports server restarted | rewritten again with XML adapter only, new `ovd.lok` | **users still found** (adapter in AdminServer memory) |
| Full restart (`systemctl restart`) with the fix in `fmw_ctl.sh` | lock removed before AdminServer start → LDAP adapter; Reports server start afterwards rewrites file + lock | users found (to be confirmed in EM after each change) |

Consequences:

- It breaks at the **next AdminServer start**, not at runtime.
- Every normal `start-all` hits it, because the lock of the previous Reports
  server run is always there.
- Removing the lock is safe also while the Reports server runs (step 2).

The customer's fix (move `ovd.lok`, `stopWebLogic.sh`, `startWebLogic.sh`)
is exactly step 2.

## 5. Fix

Before **every** AdminServer start, if the AdminServer is not running:

```bash
mv -f $DOMAIN_HOME/config/fmwconfig/ovd/default/ovd.lok \
      $DOMAIN_HOME/config/fmwconfig/ovd/default/ovd.lok.stale
```

Implemented in:

| Where | |
|---|---|
| `09-Install/autostart_templates/fmw_ctl.sh.template` (`_clear_ovd_lock`) | before `start all` / `start AdminServer`, logged in `ctrl/log/fmw_ctl_<date>.log` |
| `01-Run/startStop.sh` (ADMIN start) | before `startWebLogic.sh` |
| `70-Customer-Projects/…/WLS_Report_start_stop_kochbuch.txt` | step 0.1 and `start_wls_all.sh` |
| `70-Customer-Projects/…/Autostart_linux_middleware.txt` | `start_all.sh` |
| `70-Customer-Projects/…/Reports_security.txt` | known problem, check, manual fix, workaround |

Open (**assumption**, untested): keep the Reports server away from the shared
libOVD config – candidate is `DO_NOT_PUSH_DATA_LIBOVD` (logged by `LibOvdUtil`
in `repserver01.out`; whether it is a JVM property for the Reports server and
whether it prevents the rewrite is not verified).

## 6. Diagnosis

```bash
OVD=$DOMAIN_HOME/config/fmwconfig/ovd/default
ls -la --time-style=+%F_%T $OVD                       # ovd.lok? times of adapters.os_xml
grep -E '<(ldap|ghost) id' $OVD/adapters.os_xml        # LDAP adapter present?
ps -o lstart= -p $(pgrep -f "weblogic.Name=AdminServer" | head -1)   # AdminServer start
grep -h "Pushed ldap name" $DOMAIN_HOME/servers/AdminServer/logs/AdminServer.out | tail -1
```

`ovd.lok` older than the AdminServer start and no `<ldap id=…>` right after the
AdminServer start → this problem.

## 7. Side notes from the analysis

- Temporary trace: `setLogLevel(target='AdminServer', logger=…, level='TRACE:32',
  persist='0', addLogger='1')` **did persist** the new loggers into
  `config/fmwconfig/servers/AdminServer/logging.xml` (confirmed (live)) – remove
  them afterwards. With the trace active, EM logins were very slow and failed
  with `User <anonymous> does not have permission on weblogic.management.mbeanservers`
  in `sysman/log/emoms.log`; after a full restart without trace the login
  worked again.
- The EM log for login problems is `$DOMAIN_HOME/sysman/log/emoms.log` /
  `emoms.trc`, not the AdminServer log.
