---
title: "Patch Once, Transfer the FMW Home – Forms & Reports Patch Concept"
description: "Concept for Oracle Forms & Reports 12c / 14c: patch the Oracle Home once on a patch master that is also the application test, then transfer the patched home as a tar to QA and production – clone family, what travels, the two inventories, Java through the link, procedure with a short downtime and rollback."
---

# Patch once, transfer the FMW home

**State 2026-11-23: concept.**
- **12c:** a customer is testing the procedure, so far with success.
- **14c:** not yet tested live on the test host.

Every claim below is marked:
- **confirmed (live)**: seen on the test host or at the customer;
- **documented**: Oracle documentation or a patch README;
- **assumption**: not yet proven.

---

## 1. Idea and roles

The Oracle Home is patched **once**, on the **patch master**:
- the patch master runs the IHateWeblogic library;
- it is at the same time the **test environment of the application**.

After the test and the acceptance there, the patched home goes as an archive
to the next environments (QA, then production). On a target host nobody runs
OPatch.

```ascii?name=fmw-home-transfer
  patch master (= application test)              target (QA, then PROD)
  +-------------------------------------+        +-------------------------------------+
  | dnf: OS + nginx                     |        | dnf: OS + nginx                     |
  | JDK: new version, link switched     |        | JDK: new version, link switched     |
  | OPatch: SPB, bundles, QPRs (80-82)  |        |   (no OPatch on the target)         |
  | test + acceptance of the app        |        |                                     |
  |              |                      |        |                                     |
  |   tar of the Oracle Home            |  scp   |  unpack to fmw.new (no downtime)    |
  |   (without user_projects,           | -----> |  --- downtime -------------------   |
  |    domain-registry.xml, caches)     | sha256 |  mv fmw fmw.prev_<cycle>            |
  |   + manifest (lspatches, GUID)      |        |  mv fmw.new fmw, copy back the      |
  |   + central inventory (reference)   |        |  domain's files, clean tmp, start   |
  +-------------------------------------+        +-------------------------------------+
```

| What | Patch master | Target |
|---|---|---|
| OS packages, nginx | `dnf` | `dnf` |
| JDK (`JDK_HOME`, Oracle JDK 21) | new directory, link switched | the same JDK version, link switched |
| Oracle Home (WebLogic, Forms, Reports, OPatch, bundled JDK) | OPatch | **replaced by the patched copy** |
| Domain (`DOMAIN_HOME`) | unchanged | unchanged |
| RCU schemas | per environment, only if a README asks for it | the same |

What this gives:
- Every environment gets exactly the home that was tested and accepted on the
  master. There is no second OPatch run that can end differently, and no
  OPatch conflict analysis on production.
- The downtime on the target is a stop, two `mv` and a start, instead of one
  hour of OPatch.
- The way back is a `mv` back.

---

## 2. Precondition: the clone family

The transfer works only between hosts that came from the same installation (a
clone, or the same install with the same parameters). The paths are written
into thousands of files of the home and of the domain.

| Must be equal | Check on master and target |
|---|---|
| `ORACLE_BASE`, `ORACLE_HOME`, `DOMAIN_HOME` layout | `grep -E '^(ORACLE_BASE\|ORACLE_HOME\|DOMAIN_HOME)=' environment.conf` |
| `JDK_HOME` link path (not its target) | `ls -l /u01/app/oracle/java/jdk-21` |
| central inventory path | `cat /etc/oraInst.loc` |
| FMW owner and group, **with the same uid / gid** | `id oracle` |
| product set and version (WebLogic, Forms, Reports 14.1.2.0.0 / 12.2.1.4) | `$ORACLE_HOME/OPatch/opatch lsinventory \| grep -i 'Oracle .* 1[24]\.'` |
| starting patch level of the cycle before | `$ORACLE_HOME/OPatch/opatch lspatches` |
| home name and GUID | section 4 |
| OS release and glibc | `cat /etc/oracle-release; rpm -q glibc` |
| domain internally on localhost | [`02-Checks/clone_check.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/02-Checks/clone_check.sh) – [clone_golden_image.md](../80-FMW-Architecture/clone_golden_image.md) |

**Why the OS level matters:** the Forms and Reports QPRs relink native
binaries on the master. Examples are `frmweb` and the Reports engine. These
binaries are linked against the libraries of the master's OS. A target on a
different OS release (for example OL8 vs. OL9) can fail at runtime
(**assumption**, from the relink behaviour in
[06-oracle_patch_forms_reports.md](../09-Install/docs/06-oracle_patch_forms_reports.md)).
Rule: patch the OS of master and targets to the same level first, then
transfer the home.

---

## 3. What travels, what stays

| Part | In the archive? | Why |
|---|---|---|
| Oracle Home: WebLogic, Forms, Reports, `oracle_common`, OPatch | **yes** | the patched code |
| bundled JDK `$ORACLE_HOME/oracle_common/jdk` | **yes** | part of the home, patched with OPatch |
| home inventory `$ORACLE_HOME/inventory/` | **yes** | the patch state – section 4 |
| `$ORACLE_HOME/.patch_storage` (1.5 GB on the test host) | **yes** | `opatch rollback` and the conflict check of the next cycle need it |
| applications directory (`em.ear`, `forms/`, `.fads.domain`): `APPLICATIONS_HOME` of new installs, `$ORACLE_HOME/user_projects/applications/<domain>/` in the old layout | **no** – stays per host | written at domain creation, belongs to the domain ([§1a](../80-FMW-Architecture/weblogic_middleware_architecture.md#1a-oracle-home-domain-home-applications-home--who-holds-what)) |
| `$ORACLE_HOME/domain-registry.xml` | **no** – stays per host | list of the domains of this home |
| JACOB / signed jars of [`14-oracle_setup_forms.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/09-Install/14-oracle_setup_forms.sh) (`forms/java/jacob.jar`, `extensions.jnlp`, `forms/webutil/win*/jacob-*.dll`) | from the master, then copy back or rerun `14-` | signed per environment if the certificates differ |
| `$ORACLE_HOME/envPropertiesCache/` | **no** | runtime cache, rebuilt |
| domain `servers/*/tmp`, `servers/*/cache` | – | deleted on the target before the start (section 6 E) |
| external JDK `JDK_HOME` incl. `java.security`, `cacerts` | **no** – per host | section 5 |
| central inventory | **no** – reference copy only | section 4 |
| nginx, certificates, `environment.conf`, `*.des3` | **no** | per host, bound to the host |

**Target layout: the applications directory outside the home.** Without
`AppDir` WLST puts `user_projects/applications/<domain>` into the Oracle Home
(**confirmed (live)**: `config.xml` of the test host points to
`/u01/app/oracle/fmw/user_projects/applications/fr_domain/em.ear`).

Since 2026-11-24 new installations of this library put it next to the
domains: `APPLICATIONS_HOME`, default `/u01/app/oracle/applications/fr_domain`
(interview + [`08-oracle_setup_domain.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/09-Install/08-oracle_setup_domain.sh),
`setOption('AppDir')`). This is the layout of Oracle's Enterprise Deployment
Guide (`…/applications/<domain>` next to `…/domains/<domain>`). The home then
holds no domain file except `domain-registry.xml`, and the transfer gets
simpler. Roles of the homes and what a patch does in which one:
[architecture §1a](../80-FMW-Architecture/weblogic_middleware_architecture.md#1a-oracle-home-domain-home-applications-home--who-holds-what). Existing domains keep the old layout until they are
migrated (TODO) – **for them the `user_projects/` directory is copied back
from the old home** (section 6 E).

---

## 4. The two inventories

This is the point that looks dangerous. In practice it is simple, because an
FMW home since 12c keeps its patch state **inside the home**.

| Inventory | Where | Content | On a transfer |
|---|---|---|---|
| **home inventory** | `$ORACLE_HOME/inventory/` | installed components, `patches/*.xml`, `ContentsXML/oraclehomeproperties.xml` (home GUID) | **travels inside the tar** – `opatch lspatches` / `lsinventory` read it |
| **central inventory** | `/etc/oraInst.loc` → `inventory_loc` (default `/u01/app/oraInventory`) | `ContentsXML/inventory.xml`: the **list of all Oracle homes** of the host (name, path), plus logs, locks, backups | **stays on the target**, is only checked |

Facts on the test host (**confirmed (live)**):
- **Central inventory:** 57 MB. It lists the FMW home and also the DB homes,
  including removed ones:
  ```
  <HOME NAME="OracleHome1" LOC="/u01/app/oracle/fmw" TYPE="O" IDX="1"/>
  <HOME NAME="OraDB19Home_19_33_0" LOC="/u01/app/oracle/product/19.33.0/db_home1" TYPE="O" IDX="4"/>
  ```
  Overwriting it with the master's copy would make the target forget its own
  other homes: a DB client or a second FMW home.
- **Home inventory:** it holds the patch XMLs (`inventory/patches/36964826.xml`
  …) and the GUID of the home in `ContentsXML/oraclehomeproperties.xml`.

**Rule: do not overwrite the central inventory.** With the same
`ORACLE_HOME` path and the same home name, the target's entry is already the
right one – the home behind it is simply newer. The step "overwrite the
inventory" of the first draft is not needed. It would only do no harm on a
target whose central inventory knows nothing but this one home (**assumption**,
consistent with the 12c customer test so far).

**On the master** the central inventory goes into a separate archive, as a
**reference and backup** – not to be restored on a target.

**Check on the target** (before and after the switch):

```bash
# 1. the home is registered under the same name and path, not removed
grep '<HOME ' "$(sed -n 's/^inventory_loc=//p' /etc/oraInst.loc)/ContentsXML/inventory.xml"

# 2. same home GUID as on the master (same clone origin)
grep -o '<GUID>[^<]*' $ORACLE_HOME/inventory/ContentsXML/oraclehomeproperties.xml

# 3. the proof: patch list equal to the manifest of the master
$ORACLE_HOME/OPatch/opatch lspatches > /tmp/lspatches_target.txt
diff <(sort manifest/lspatches.txt) <(sort /tmp/lspatches_target.txt) && echo "patch level equal"
```

**Only when the entry is missing or points to another path:** register the
home with Oracle's tool (**documented**, present in the home of the test host):

```bash
$ORACLE_HOME/oui/bin/attachHome.sh -silent -invPtrLoc /etc/oraInst.loc
```

**When path or home name must differ** (not a clone family): use Oracle's
supported binary clone instead of a tar. `copyBinary.sh` on the master packs
the home. `pasteBinary.sh` on the target unpacks it to a new path and
registers it in the central inventory (**documented**; both are in
`$ORACLE_HOME/oracle_common/bin` on the test host). The domain then has to be
moved to the new path as well – a different project, not this concept.

---

## 5. Java: always through the link

Two JDKs are involved:

| JDK | Used by | Updated how |
|---|---|---|
| external Oracle JDK 21, `JDK_HOME=/u01/app/oracle/java/jdk-21` → `jdk-21.0.x` | WebLogic servers, Node Manager, WLST, OPatch | new directory + link switch, [`02b-root_os_java.sh --upgrade-jdk`](../09-Install/docs/01-root_setup_java.md), per host |
| bundled JDK `$ORACLE_HOME/oracle_common/jdk` | Reports engines (via `reports.sh`) and other tools of the home | OPatch on the master – **travels with the home** |

The domain and the home must reach the external JDK **only through the
link**. WLST and the installer write the resolved, versioned directory into
several files, for example `setDomainEnv.sh`, `nodemanager.properties` and
`oui/.globalEnv.properties`. After a JDK update the old directory is then
still used, or is missing. [`07-Maintenance/domain_jdk_path.sh`](../07-Maintenance/docs/02-patching.md#domain_jdk_pathsh)
finds these places and replaces them with the link:

```bash
./07-Maintenance/domain_jdk_path.sh            # dry run: lists versioned JDK paths in domain + home
./07-Maintenance/domain_jdk_path.sh --apply    # replaces them with JDK_HOME (backup first)
```

- **On the master:** run it before packing, so that the home carries no
  versioned path (`oui/.globalEnv.properties` travels).
- **On the target:** run the dry run before the downtime. It must find
  nothing, otherwise run `--apply` first.
- `JAVA_HOME` in `.bash_profile` of the FMW owner points to `JDK_HOME`.
  `alternatives` decides only the system `java` and plays no role for
  WebLogic.

**Lost on every JDK update** – the new JDK directory comes from the Oracle
download, without our changes:
- `conf/security/java.security`: `securerandom.source=file:/dev/./urandom`;
- `lib/security/cacerts`: the certificates of an internal CA.

Apply both again to the new directory on **every** host, before the link is
switched. `02b-root_os_java.sh` and `02-Checks/weblogic_performance.sh` show the
securerandom setting of the JDK.

---

## 6. Procedure

### A. Patch master – patch and accept

1. `dnf` update of OS and nginx (reboot if the kernel changed).
2. New JDK: `02b-root_os_java.sh --upgrade-jdk`, then `java.security` /
   `cacerts` (section 5), then `domain_jdk_path.sh`.
3. OPatch with the library – [02-patching.md](../07-Maintenance/docs/02-patching.md):
   `80-patch_java_os.sh`, `81-patch_weblogic.sh`, `82-patch_forms_reports.sh`.
4. Post-install steps of the READMEs (section 7).
5. Test and acceptance of the application on the master. **Only an accepted
   home is packed.**

### B. Pack (home quiet: no OPatch running; domain stopped for a clean copy)

```bash
CYCLE=2026-11                         # patch cycle, name of the archives
OUT=$PATCH_STORAGE/fmw_transfer/$CYCLE
mkdir -p $OUT/manifest
cd "$(dirname $ORACLE_HOME)"          # /u01/app/oracle

# the home, without what belongs to the domain or is a cache
tar -cpzf $OUT/fmw_home_$CYCLE.tgz \
    --exclude="$(basename $ORACLE_HOME)/user_projects" \
    --exclude="$(basename $ORACLE_HOME)/domain-registry.xml" \
    --exclude="$(basename $ORACLE_HOME)/envPropertiesCache" \
    "$(basename $ORACLE_HOME)"

# central inventory - reference only, never restored on a target
INV=$(sed -n 's/^inventory_loc=//p' /etc/oraInst.loc)
tar -cpzf $OUT/oraInventory_master_$CYCLE.tgz -C "$(dirname $INV)" "$(basename $INV)"

# manifest: what the target must show afterwards
$ORACLE_HOME/OPatch/opatch lspatches                  > $OUT/manifest/lspatches.txt
grep -o '<GUID>[^<]*' $ORACLE_HOME/inventory/ContentsXML/oraclehomeproperties.xml > $OUT/manifest/home_guid.txt
readlink -f $JDK_HOME                                 > $OUT/manifest/jdk.txt
$ORACLE_HOME/oracle_common/jdk/bin/java -version 2>> $OUT/manifest/jdk.txt
cat /etc/oracle-release; rpm -q glibc                 > $OUT/manifest/os.txt
cd $OUT && sha256sum *.tgz > SHA256SUMS
```

Before packing, check that the home holds only files of the FMW owner. A file
of root would get a wrong owner on the target:
```bash
find $ORACLE_HOME ! -user oracle -ls | head
```

### C. Copy

Copy the directory `$OUT` to the target (`scp`, or through `PATCH_ARCHIVE` –
[`patch_storage.sh`](../07-Maintenance/docs/02-patching.md#patch_storagesh)).
Then check on the target:
```bash
cd $PATCH_STORAGE/fmw_transfer/$CYCLE && sha256sum -c SHA256SUMS
```

### D. Target – prepare, without downtime

1. `dnf` update of OS and nginx – to the same level as the master (section 2).
2. Unpack the new JDK directory, apply `java.security` / `cacerts`. **Do not
   switch the link yet** – running processes keep their JDK anyway, but a
   restart in between would pick up the new one.
3. `domain_jdk_path.sh` dry run: the domain reaches Java only through the link.
4. Check the clone family (section 2) against the manifest.
5. Disk space: the home exists twice for some days (7.1 GB on the test host).
6. Unpack next to the running home, on the **same file system** (then the
   switch is a rename, not a copy):
   ```bash
   cd /u01/app/oracle
   mkdir fmw.new && tar -xpzf $PATCH_STORAGE/fmw_transfer/$CYCLE/fmw_home_$CYCLE.tgz -C fmw.new --strip-components=1
   ```

### E. Target – downtime

```bash
# 1. stop everything, including the Node Manager
./01-Run/startStop.sh stop-all --apply    # library; or the domain's stop scripts

# 2. switch the JDK link
ln -sfn /u01/app/oracle/java/jdk-21.0.x /u01/app/oracle/java/jdk-21

# 3. keep the old home - this IS the backup, the way back takes seconds
mv /u01/app/oracle/fmw /u01/app/oracle/fmw.prev_$CYCLE
mv /u01/app/oracle/fmw.new /u01/app/oracle/fmw

# 4. bring back what belongs to this host's domain
#    user_projects only in the old layout (APPLICATIONS_HOME inside the home)
cp -a /u01/app/oracle/fmw.prev_$CYCLE/user_projects      /u01/app/oracle/fmw/
cp -a /u01/app/oracle/fmw.prev_$CYCLE/domain-registry.xml /u01/app/oracle/fmw/
#    JACOB / signed jars: rerun 09-Install/14-oracle_setup_forms.sh, or copy the files of section 3

# 5. delete the rebuildable files of the domain
clean_domain_tmp.sh --apply

# 6. inventory check (section 4) - lspatches must equal the manifest
# 7. start
./01-Run/startStop.sh start-all --apply
```

**Check after the start:**
- `opatch lspatches` equals `manifest/lspatches.txt`;
- the processes run from the new home and the new JDK:
  `ls -l /proc/$(pgrep -f 'weblogic.Name=AdminServer')/exe`;
- `status.sh` of the [customer tools](../70-Customer-Projects/tools/README.md) and the runtime monitor [11-wlsmon](../11-wlsmon/README.md)
  (tab Patch level: the expected cycle);
- the application test of the environment;
- EM: a missing `em.ear` shows only there, not in Forms or Reports.

### F. Way back

```bash
./01-Run/startStop.sh stop-all --apply
mv /u01/app/oracle/fmw /u01/app/oracle/fmw.failed_$CYCLE
mv /u01/app/oracle/fmw.prev_$CYCLE /u01/app/oracle/fmw
ln -sfn /u01/app/oracle/java/<old jdk-21.0.x> /u01/app/oracle/java/jdk-21
clean_domain_tmp.sh --apply
./01-Run/startStop.sh start-all --apply
```

### G. Clean up

After some days of stable operation – like the out-of-place DB patch
([09-db_patch_rcu.md](../60-RCU-DB-19c/docs/09-db_patch_rcu.md)) – delete
`fmw.prev_<cycle>` and the old JDK directory. Keep the archive of the cycle
on the master until the next cycle is through.

---

## 7. What the archive does not carry

The tar transfers the **binaries**. Everything a patch asks for outside the
Oracle Home has to be done on every environment:

- **Post-install steps of a README.** Read them on the master. On the test
  host the bundle READMEs of 14c asked for "verify, start" only (**confirmed
  (live)**, [§7a](../80-FMW-Architecture/weblogic_middleware_architecture.md#7a-what-a-patch-changes--oracle-home-domain-home-swapped-home)).
  KB694158, the post-install note of the WLS PSU, is still unread.
- **RCU / database changes:** every environment has its own RCU schemas. A
  patch with a schema step (rare) needs that step per environment.
- **Files copied into the domain at its creation:** 304 domain files on the
  test host are identical to a file of the home. A patch of such a file
  reaches neither an OPatch-patched nor a transferred domain. Check this per
  cycle (§7a).
- **`em.ear` in the applications directory:** a copy of
  `em/archives/applications/em_fmwconsole.ear` made at domain creation. A patch
  of that EAR (CPU Oct 2026: the `/em` cookie fix of 39995927) reaches neither
  way – the domain keeps the old copy ([§1a](../80-FMW-Architecture/weblogic_middleware_architecture.md#1a-oracle-home-domain-home-applications-home--who-holds-what)). Refresh procedure open (TODO).
- **OS and nginx:** with `dnf`, on every host.

---

## 8. Risks and open points

| Point | State |
|---|---|
| relinked binaries vs. OS level of the target | rule: same OS level first (section 2) – **assumption**, to be proven on 14c |
| central inventory not overwritten, entry only checked | **assumption** for 14c; 12c customer: running |
| files of root in the home | check before packing (section 6 B) |
| SELinux contexts (if enforcing) | `tar` does not keep them by default – `restorecon -R` on the new home, or `tar --selinux` |
| disk space | home twice for some days |
| applications directory inside the home | new installs: `APPLICATIONS_HOME` outside the home (2026-11-24); migration of existing domains – TODO |
| `em.ear` copy never patched | finding 2026-11-24 – check + refresh procedure + MOS research – TODO |
| live test 14c on the test host | open – TODO |
| script `07-Maintenance/fmw_home_transfer.sh` (`pack`, `check`, `stage`, `switch`, `rollback`) | idea – after the live test |

---

## 9. Related

- [weblogic_middleware_architecture.md §7a](../80-FMW-Architecture/weblogic_middleware_architecture.md#swapping-a-patched-home) – what a patch changes, what the domain leaves in the home, swap checklist
- [clone_golden_image.md](../80-FMW-Architecture/clone_golden_image.md) – clone-capable domain, localhost rule
- [oracle_patch_basics.md](../80-FMW-Architecture/oracle_patch_basics.md) – in-place vs. out-of-place, patch numbers
- [02-patching.md](../07-Maintenance/docs/02-patching.md) – patch workflow of the library (80-82, JDK, `patch_storage.sh`)
- [09-db_patch_rcu.md](../60-RCU-DB-19c/docs/09-db_patch_rcu.md) – out-of-place pattern of the DB home
- [update_lib_to_act_cpu.md](update_lib_to_act_cpu.md) – the library switch per patch cycle
