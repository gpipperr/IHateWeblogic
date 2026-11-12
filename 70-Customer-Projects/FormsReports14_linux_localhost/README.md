# Forms & Reports 14.1.2 – Domain on localhost only (Linux)

Knowledge base for the **loopback hardening of an existing Forms / Reports
14.1.2 domain**: every internal socket on `127.0.0.1` / `localhost`, only
Nginx (and its certificate) carries the host name. The result is safer
(7001 / 9001 / 9002 are no longer reachable from the network) and the
installation becomes **clone-capable** – the precondition for a golden image
or a move to another machine.

Built from a customer run (Reports-only domain, 2026-11-09 / 2026-11-10,
anonymised) and read-only checks on our test host (Forms + Reports domain,
created hardened by `09-Install/08-`).

| File | Content |
|---|---|
| [Localhost_cookbook_en.txt](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/FormsReports14_linux_localhost/Localhost_cookbook_en.txt) | Step-by-step cookbook (bash, English, plain text): starting point, backup, WLST, `reports.sh`, `setUserOverrides.sh`, engine `jvmOptions`, `startup.properties`, `bin/*.sh`, EM `emoms.properties`, restart, checks, firewall, rollback, known problems. One run ends with `clone_check_fmw.sh` **"Clone-capable: yes"**. Forms parts marked "skip if Reports only". |

Theory (not repeated here):
[../../80-FMW-Architecture/clone_golden_image.md](../../80-FMW-Architecture/clone_golden_image.md)
– section 1 (target picture), section 2 (sockets and bind addresses),
section 2.1 (hardening checklist), section 3 (where host name / IP live).

---

## 1. Target picture

![localhost-target](diagrams/localhost-target.svg?v=4ae0820e)
<sub>Source: [diagrams/localhost-target.prompt](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/FormsReports14_linux_localhost/diagrams/localhost-target.prompt) · [D2](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/FormsReports14_linux_localhost/diagrams/localhost-target.d2)</sub>

<details><summary>ASCII version</summary>

```ascii name=localhost-target
  client (browser / Forms client)
        |  HTTPS, host name + certificate   <-- the ONLY host-specific edge
        v
  Nginx 0.0.0.0:443  -- upstream / proxy_pass http://127.0.0.1:<port>
        |
        +--> AdminServer 127.0.0.1:7001      Node Manager 127.0.0.1:5556
        +--> WLS_FORMS   127.0.0.1:9001 --> frmweb (0.0.0.0, no option)
        +--> WLS_REPORTS 127.0.0.1:9002 --> rwserver + rwEng-* 127.0.0.1
```

</details>

Details: [clone_golden_image.md §1–§3](../../80-FMW-Architecture/clone_golden_image.md).

---

## 2. Every place touched

Markers: **live** = confirmed on the test host (2026-10-23 / 2026-11-10),
**customer** = confirmed at the customer 2026-11-10 (Reports-only domain).
Cookbook step in brackets.

| # | File / place | Setting / value | How to check | Marker |
|---|---|---|---|---|
| 1 | `config/config.xml` AdminServer, WLS_FORMS, WLS_REPORTS (WLST `/Servers/<srv>`) | `ListenAddress=localhost` (3.1) | `grep -n listen-address config.xml`; `ss -Hltn` – 7001 / 9001 / 9002 on 127.0.0.1 | live, customer |
| 2 | `nodemanager/nodemanager.properties` | `ListenAddress=localhost` (or `127.0.0.1`), `SecureListener=false` (3.3) | `grep ^ListenAddress`; `ss` – 5556 on 127.0.0.1 | live, customer (was already 127.0.0.1) |
| 3 | WLST `/Servers/<ms>/SSL/<ms>` | `Enabled=false` – SSL listen ports 9501 / 9512 (demo certificate) off (3.1) | `grep -A2 '<ssl>' config.xml`; clone_check section 2 | live |
| 4 | WLST `/Servers/<ms>/CoherenceMemberConfig/<ms>` | `UnicastListenAddress=127.0.0.1` (3.1) | `<unicast-listen-address>` in `config.xml`; clone_check section 2 | live, customer |
| 5 | `$DOMAIN_HOME/reports/bin/reports.sh` | `REPORTS_JVM_OPTIONS="-Xmx256M -DORBWaitForResponseTimeout=999999999 -Dcom.sun.corba.ee.ORBServerHost=127.0.0.1"` + `export` (4.1). **Without** the timeout: `REP-50125` NullPointerException in `Utility.getOrbProperties`, Reports server does not start | `grep REPORTS_JVM_OPTIONS reports.sh`; `ss -ltnp` – `rwserver` on 127.0.0.1 | live, customer |
| 6 | `$DOMAIN_HOME/bin/setUserOverrides.sh`, block `SERVER_NAME = WLS_REPORTS` | `EXTRA_JAVA_PROPERTIES += -Dcom.sun.corba.ee.ORBServerHost=127.0.0.1` – rwservlet ORB (4.2) | `grep ORBServerHost setUserOverrides.sh`; clone_check section 3 | live, customer |
| 7 | `rwserver.conf` `<engine id="rwEng" ... jvmOptions="...">` | append `-DORBWaitForResponseTimeout=999999999 -Dcom.sun.corba.ee.ORBServerHost=127.0.0.1` – `jvmOptions` **replace** the inherited `REPORTS_JVM_OPTIONS` (4.3). No `jvmOptions` = nothing to do | `/proc/<pid>/cmdline` of the `rwEng-*` processes; clone_check section 1 (no `rwEng-*` on 0.0.0.0) | customer |
| 8 | `servers/<ms>/data/nodemanager/startup.properties` | `AdminURL=http\://localhost\:7001` (5.1) – the hardening does not rewrite it | AdminServer log `BEA-149506` per managed server; `ps … management.server=` | customer (live: already localhost) |
| 9 | `$DOMAIN_HOME/bin/*.sh` (`stopWebLogic.sh`, `stopManagedWebLogic.sh`), `ADMIN_URL` in the oracle profile | `ADMIN_URL="t3://localhost:7001"` (5.2) | `grep -n 'ADMIN_URL="t3' bin/*.sh`; clone_check section 4 | customer (clone), live |
| 10 | EM: `config/fmwconfig/servers/AdminServer/applications/em/META-INF/emoms.properties` **and** `.jmxori` **and** the template `servers/AdminServer/tmp/_WL_user/em/<id>/META-INF/emoms.properties` | `ConsoleServerHost=localhost`, `ConsoleServerName=localhost:7001_Management_Service` in **all three** (5.3) | `grep ConsoleServerHost` after an AdminServer restart; clone_check section 4 | customer (live: localhost from the domain creation) |
| 11 | Nginx `/etc/nginx/conf.d/*.conf` | `upstream` / `proxy_pass` to `127.0.0.1:<port>` (1.5) – before the change | `grep -rn ':7001\|:9001\|:9002' /etc/nginx/conf.d/` | live, customer |
| 12 | Direct client access | nobody calls `http://<host>:7001` / `:9001` / `:9002` past Nginx (1.4) – before the change | `ss -Htn state established '( sport = :7001 or … )'` – peer only 127.0.0.1; repeat during the day | customer |
| 13 | firewalld | only ssh, http, https and the Reports discovery `<port>/udp` open; 7001 / 9001 / 9002 / 5556 / 7574 closed (STEP 8) | `firewall-cmd --list-all` (root) | customer (not checked on the test host as oracle) |

Not changed on purpose: the mail sender in `rwserver.conf`
(`<property name="sender" value="reports@<host>"/>`) is host-specific by
design – `clone_check` reports it as STEP (adjust per clone), not as FIX.

---

## 3. What stays on the host IP by design

| Socket | Why | Treatment |
|---|---|---|
| Coherence cluster port 7574 (tcp + udp) and one more ephemeral tcp port (WLS_FORMS / WLS_REPORTS) | not removable with `UnicastListenAddress` or `-Dcoherence.localhost` – member traffic itself runs over loopback | firewall; clone_check: "Coherence remainder … firewall" |
| Reports multicast discovery UDP `228.5.6.7:<port>` (e.g. 14022 / 14027, `rwnetwork.conf`) | multicast needs an interface; the Reports server needs it for its start | stays open in the firewall; a clone in the same subnet needs its own port |
| `frmweb` (Forms only, one per session) | no Oracle option for a bind address, no host name inside | firewall; clone-neutral |

---

## 4. Checks

| Check | Expected |
|---|---|
| `70-Customer-Projects/tools/bash/clone_check_fmw.sh --config -t <dir>` (customer hosts, read-only, version **2026-11-10.8** or newer; in `tools/ihw_customer_tools_linux.zip`) | last line `OK  Clone-capable: yes – <n> step(s) after cloning` (test host: 11 STEP) |
| `02-Checks/clone_check.sh` (hosts with the IHateWeblogic library) | `OK  Clone-capable: yes – <n> step(s) after cloning (INFO above)` (test host: 14). `--apply` switches SSL off and Coherence to 127.0.0.1 (WLST online) and sets the file places `AdminURL`, `ADMIN_URL`, emoms (3 files), engine `jvmOptions` (backup of each) – the automated version of the cookbook steps for these places |
| `tools/bash/status.sh` | `Ergebnis: alles in Ordnung` (German output) – note: says RUNNING even when EM is red (symptom 1 below) |
| `ss -Hltn '( sport = :7001 or sport = :9001 or sport = :9002 or sport = :5556 )'` | only `127.0.0.1:<port>` |
| `ss -Hltnp 'not src 127.0.0.1' \| grep -e rwserver -e java` | only the Coherence remainder (7574 + one port) |
| `grep -E 'BEA-14950[56]' AdminServer.log \| tail -2` | `BEA-149506 Established JMX Connectivity with WLS_REPORTS … t3://localhost:9002` |

---

## 5. Symptom → cause → fix

| Symptom | Cause | Fix (cookbook) |
|---|---|---|
| EM shows WLS_REPORTS, `cluster_reports` and the `reports` deployment red / shut down, `status.sh` says RUNNING; AdminServer.log only `BEA-149505 … JMX Service URL of <none>`; WLS_REPORTS.log "Managed Server independence mode" | Node Manager started the managed server directly (autostart) with the old `AdminURL` (host IP) from `startup.properties`; the AdminServer listens only on localhost | `startup.properties` → `http\://localhost\:7001`, restart via Node Manager → `BEA-149506` (5.1) |
| clone_check: `tcp 0.0.0.0:<port> rwEng-0 … all interfaces`, the Reports server itself on loopback | `<engine jvmOptions="…">` replaces `REPORTS_JVM_OPTIONS` – no `ORBServerHost` for the engines | append both options to `jvmOptions`, restart the Reports server (4.3) |
| `emoms.properties` back to the FQDN after an AdminServer restart | EM copies `servers/AdminServer/tmp/_WL_user/em/<id>/META-INF/emoms.properties` over the `config/` files at every start | change all three files (5.3); check again after an EM patch / redeploy |
| Reports server does not start: `REP-50125 : java.lang.NullPointerException … Utility.getOrbProperties` | `REPORTS_JVM_OPTIONS` set without `-DORBWaitForResponseTimeout=…` (Oracle reads it as empty) – or broken quotes in `jvmOptions` | add `-DORBWaitForResponseTimeout=999999999` (4.1 / 4.3) (background: [reports_engine_architecture.md §6](../../80-FMW-Architecture/reports_engine_architecture.md), MOS KB924687) |
| Report hangs, `REP-51002`, "Bind to server failed" | only `reports.sh` **or** only `setUserOverrides.sh` changed – rwservlet and Reports server do not find each other | both (4.1 + 4.2), complete restart |
| `stopWebLogic.sh` / a script: "Connection refused" on `t3://<host>:7001` | `ADMIN_URL` with the host name | `t3://localhost:7001` (5.2) |
| An application no longer reaches `http://<host>:9002/reports/…` | it went past Nginx | `https://<host>/reports/…` (check 1.4 beforehand) |
| `BEA-2194505` / "Local address 127.0.0.1 is a loopback address" in the managed-server logs | intended – Coherence over loopback | harmless |

---

## 6. New installations – the repository scripts do it

| Script | What |
|---|---|
| `09-Install/08-oracle_setup_domain.sh` + `09-Install/response_files/domain_config.py.template` | domain with `ListenAddress=${WLS_LISTEN_ADDRESS}` (default 127.0.0.1 / localhost) for AdminServer and managed servers, SSL listen ports of the managed servers off, Coherence `UnicastListenAddress`; `nodemanager.properties` `ListenAddress=127.0.0.1`; checks Coherence unicast on loopback |
| `09-Install/11-oracle_nodemanager.sh` | Node Manager settings, admin URL `t3://localhost:<port>` |
| `09-Install/13-oracle_setup_reports.sh` | `reports.sh` `REPORTS_JVM_OPTIONS` (with timeout + `ORBServerHost`), `setUserOverrides.sh` rwservlet ORB for WLS_REPORTS, engine `jvmOptions` always with both options (since 2026-11-10) |
| `05-ReportsPerformance/engine_perf_settings.sh` | keeps both ORB options when it changes engine `jvmOptions` |
| `02-Checks/clone_check.sh [--apply]` | check; `--apply` = SSL off + Coherence 127.0.0.1 and the four file places on an existing domain |

Domains created with `localhost` have `startup.properties`, `bin/*.sh`
and `emoms.properties` on localhost from the start (test host) – the gaps
of rows 8–10 appear only on domains created with a host name and hardened
later.

---

## 7. Next step

Clone the hardened installation (new host, RCU prefix, certificate, …):
[../FormsReports14_linux_clone/README.md](../FormsReports14_linux_clone/README.md).
Recipe and background: [clone_golden_image.md §5–§6](../../80-FMW-Architecture/clone_golden_image.md).
