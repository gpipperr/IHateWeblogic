# Reports server discovery – UDP multicast, `rwnetwork.conf`, REP-50600 / REP-56040

**Scope:** Oracle Reports 14.1.2 (FMW 14.1.2.0.0, Reports QPR 39600348),
standalone Reports server (`ReportsServerComponent`, `rwserver`) with the
rwservlet on the managed server `WLS_REPORTS`. Sources: bytecode of
`$ORACLE_HOME/reports/jlib/rwrun.jar`, live tests on the test host
(2026-10-15), one customer case (2026-10-15).

---

## 1. Who needs to find whom

| Participant | Process | Configuration |
|---|---|---|
| Reports server (`repserver01`) | native `rwserver server=repserver01 …`, started/stopped by the Node Manager (`startComponent.sh`) | `$DOMAIN_HOME/config/fmwconfig/components/ReportsServerComponent/<name>/rwserver.conf` + `rwnetwork.conf` |
| rwservlet (web front end, `getserverinfo`, report requests) | Java, inside `WLS_REPORTS` | `$DOMAIN_HOME/config/fmwconfig/servers/WLS_REPORTS/applications/reports_14.1.2/configuration/rwservlet.properties` + `rwnetwork.conf` |
| Reports tools (`rwrun`, `rwclient`, `rwconverter`) | command line | `$DOMAIN_HOME/config/fmwconfig/components/ReportsToolsComponent/<instance>/rwnetwork.conf` |

The rwservlet does not know where the Reports server runs – with
`<inprocess>no</inprocess>` and `<server>repserver01</server>` it looks the server
up **by name** over the network. All participants must therefore use the
same discovery settings: **the three `rwnetwork.conf` files must contain the
same channel and port.**

## 2. Discovery modes

`rwnetwork.conf` (14.1.2 default as shipped in `$ORACLE_HOME/reports/conf/`):

```xml
<discoveryService xmlns="http://xmlns.oracle.com/reports/network" …>
  <multicast channel="228.5.6.7" port="14021" timeout="1000"/>
  <!--namingService name="Cos" host="%NAMING_HOST%" port="%NAMING_PORT%"/-->
</discoveryService>
```

- **Multicast (default):** UDP multicast to the group `channel` (`228.5.6.7`)
  on `port` (`14021`). **confirmed (live)**
- **Naming service (COS naming):** a central CORBA naming service instead of
  multicast – the commented-out `<namingService>` element; the REP-50600
  message itself recommends it ("Please enable cosnaming"). Which exact
  condition switches the mode is decided by
  `oracle.reports.utility.Utility.useNamingService()` – **not traced further,
  not tested**.
- In older releases the element was `<cluster … port=…>`; 14.1.2 uses
  `<multicast …>`. A `sed` on `<cluster` changes nothing in 14.1.2.
  **confirmed (live)** (`13-oracle_setup_reports.sh` handles both since 2026-10-15)

## 3. What the Reports server does at start (multicast mode)

From `oracle.reports.server.RWServer.startServer` – **confirmed (code)**:

1. `Utility.useNamingService()` → false → log "Using multicast mechanism".
2. `ServerPacketHandler.enableCallback()` – start listening on the group.
3. `NetworkUtility.getIOR("server", <name>)` – multicast query: *is there
   already a server with my name?* The answer sets a flag "server exists".
4. `ServerPacketHandler.packetsReceived()` – **did this process receive any
   multicast packet at all** (at least its own query looped back)? Sets a flag
   "broadcast works".
5. `disableCallback()`.
6. Decision:
   - a server with the same name answered → **`REP-56040`** (name already in
     use), start aborted;
   - no packet received → **`REP-50600 Broadcasting is disabled. Please enable
     cosnaming for Reports discovery.`**, start aborted (not for an in-process
     server);
   - otherwise the server starts; with a cluster configuration it later calls
     `ClusterManager.joinMulticastCluster()`.

Consequences:

- REP-50600 means **this host did not receive multicast packets** – not "another
  server is in the way". Other Reports servers on the same channel/port would
  *send* packets and make step 4 succeed.
- A **same-name** server on the same channel/port anywhere in the multicast
  domain → REP-56040.
- Under the Node Manager an aborted start shows up as a restart loop in
  `nodemanager.log`: `… is no longer alive` / `Server failed so attempting to
  restart` every few seconds. **confirmed (live, customer 2026-10-15)**

## 4. Traffic observed – confirmed (live, test host 2026-10-15)

Passive listener on `228.5.6.7:14027` (Python, `IP_ADD_MEMBERSHIP`, no root):

| Situation | Packets |
|---|---|
| Reports server running, idle, 30 s | **0** |
| `stopComponent.sh` + `startComponent.sh repserver01` (+ first status query) | **7**, all from the host's own IP |

→ A Reports server announces itself **only while starting / searching**, it
does not send a periodic heartbeat. A passive check can therefore **not**
prove that a port is unused in the subnet; it only catches servers that start
during the listen window.

A foreign datagram sent to the port of a **running** server is read by it and
logged as `REP-50125 … java.io.StreamCorruptedException: invalid stream header`
in `rwserver_diagnostic.log` (harmless, but an incident entry).
**confirmed (live)**

## 4b. Active search – `rwdiag` / `DiagServerLocator` – confirmed (live, test host 2026-10-15)

Because servers are silent while idle (§4), finding the Reports servers in a
network needs an **active query** – the same "who is server X?" request a
starting server sends (§3 step 3); running servers answer it. Oracle ships a
tool for exactly that:

```bash
$DOMAIN_HOME/reports/bin/rwdiag.sh -find <server-name>
$DOMAIN_HOME/reports/bin/rwdiag.sh -findAll [-timeout <sec>]
$DOMAIN_HOME/reports/bin/rwdiag.sh -monitor [-log <file>]      # not tested yet
```

`rwdiag.sh` runs `oracle.reports.utility.DiagServerLocator` (FMW-bundled JDK,
`REPORTS_CLASSPATH` from `reports.sh`). Result on the test host:

```
Reading the rwnetwork.conf from :…/ReportsToolsComponent/reptools1/rwnetwork.conf
Broadcast mechanism used to locate servers
Channel address = 228.5.6.7
Channel port  = 14027
(1) Name = repserver01 : Type = server : Host = <test-host>
```

- `rwdiag.sh` hard-codes `COMPONENT_CONFIG_PATH` to the ReportsTools instance,
  i.e. it only searches **the own channel/port**. `-conf <file>` is resolved
  relative to that directory (an absolute path is simply appended).
- Any other port can be searched without touching the domain: call the class
  directly with `COMPONENT_CONFIG_PATH` pointing to a temporary directory that
  contains a copy of `rwnetwork.conf` with the port to test:

  ```bash
  . $DOMAIN_HOME/reports/bin/reports.sh            # sets REPORTS_CLASSPATH
  d=$(mktemp -d)
  sed 's/\(<multicast[^>]*port="\)[0-9]*/\114021/' \
      $DOMAIN_HOME/config/fmwconfig/components/ReportsToolsComponent/<tools>/rwnetwork.conf > $d/rwnetwork.conf
  COMPONENT_CONFIG_PATH=$d $ORACLE_HOME/oracle_common/jdk/bin/java \
      -DORACLE_HOME=$ORACLE_HOME -classpath $REPORTS_CLASSPATH \
      oracle.reports.utility.DiagServerLocator -findAll -timeout 3
  rm -rf $d
  ```

  | Port | Result on the test host |
  |---|---|
  | 14021 (Oracle default, unused here) | `REP-50503 No server found in the network` |
  | 14027 (own port) | `(1) Name = repserver01 : Type = server : Host = <test-host>` |

- Looping over 14021–14030 therefore shows **which environment uses which
  port** in the multicast domain – the check the passive listener (§4) cannot
  provide. Not yet tried against a network with several environments.

## 4c. Hardening ideas (draft)

| Measure | Effect | Status |
|---|---|---|
| unique broadcast port per environment, chosen after a scan of 14021–14030 (§4b) | environments do not see each other; no REP-56040 on equal server names | `02-Checks/reports_network_scan.sh` |
| unique server names per environment (e.g. with environment suffix) | a port clash cannot turn into REP-56040 | convention only |
| own multicast **channel** per environment (`channel=` instead of `228.5.6.7`, all three `rwnetwork.conf`) | separates environments even on the same port | **assumption – not tested** |
| UDP broadcast port only reachable from the own segment / host (firewall source restriction instead of an open port) | foreign hosts can neither see nor disturb the discovery | **assumption – not tested** (rich rule with source address) |
| COS naming service instead of multicast (`<namingService>`) | no multicast at all; explicit registry | not tested (§2) |
| keep the IPv6/NIC + firewall baseline (§5) | discovery works at all | implemented in `00-`/`01-`/`13-` |

Tool: `02-Checks/reports_network_scan.sh` (implemented 2026-10-15) – checks of
§5, multicast self-test (moved out of `13-`), active `DiagServerLocator` scan
over a port range (default 14021–14030), WARN for foreign hosts on the own
port, FAIL for own server names on other hosts (REP-56040), list of ports
without answer; read-only. Note: `DiagServerLocator` needs the full
`reports.sh` environment (class path alone → `InvocationTargetException`).

## 5. Prerequisites on the host

| Prerequisite | Why | Check |
|---|---|---|
| UDP `<port>` open in the firewall | the looped-back packet passes the input filter; blocked → step 4 fails → REP-50600 | `firewall-cmd --query-port=<port>/udp` |
| route for the group via the LAN interface | multicast needs an outgoing interface | `ip route get 228.5.6.7` – must name the LAN interface, not `lo`/unreachable |
| `MULTICAST` flag on that interface | interface must accept multicast | `ip -br link show dev <if>` |
| IPv6 off on **every** interface (project baseline) | the JVMs otherwise bind via the IPv6 stack (`[::ffff:127.0.0.1]`); at the customer REP-50600 occurred together with `ens33` still having IPv6 | `sysctl -a \| grep disable_ipv6` – all `= 1` |
| port unique per environment in the multicast domain | otherwise environments see each other; same server name → REP-56040 | range 14021–14030 (Doc ID 437228.1); see §4 for the limits of checking |

Customer case 2026-10-15: REP-50600 restart loop; IPv6 was still active on
`ens33` (`all`/`default` were 1) and firewalld was suspected; after changes on
the customer side the environment runs – **which change fixed it is not
confirmed**.

## 6. Diagnosis

```bash
# Reports server log (name = instance name, case-sensitive)
grep -hE "REP-[0-9]+" $DOMAIN_HOME/servers/<name>/logs/rwserver_diagnostic.log | tail
# "Using multicast mechanism" without REP-50600 = discovery works

# Same channel/port in all three rwnetwork.conf?
grep -H multicast \
  $DOMAIN_HOME/config/fmwconfig/components/ReportsServerComponent/<name>/rwnetwork.conf \
  $DOMAIN_HOME/config/fmwconfig/components/ReportsToolsComponent/<tools>/rwnetwork.conf \
  $DOMAIN_HOME/config/fmwconfig/servers/WLS_REPORTS/applications/reports_14.1.2/configuration/rwnetwork.conf

# Who sends on the port? (root) – run while stopping/starting the server
tcpdump -ni <if> udp port <port>
#   foreign IPs  -> another environment uses the same port
#   own IP only  -> packets dropped locally (firewall)
#   nothing      -> route / interface
```

Restart the Reports server with `stopComponent.sh` + `startComponent.sh` –
`restartComponent.sh` is refused by the Node Manager for Reports servers
("Server softRestart command is not supported on ReportsServerComponent
server"). **confirmed (live)**

## 7. Where the library handles this

| Script | What it does |
|---|---|
| `09-Install/00-root_os_network.sh` | reports IPv6 per interface + NetworkManager `ipv6.method` |
| `09-Install/01-root_os_baseline.sh` | opens `REPORTS_BROADCAST_PORT`/udp; disables IPv6 per interface (runtime + `nmcli`) |
| `09-Install/13-oracle_setup_reports.sh` | sets the port in all three `rwnetwork.conf` (`<multicast>` or `<cluster>`); calls `reports_network_scan.sh --no-scan` for the prerequisites and the self-test |
| `02-Checks/reports_network_scan.sh` | rwnetwork.conf consistency, route/`MULTICAST`/IPv6/firewall, send+receive self-test (skipped while a server runs), active scan for Reports servers per port (`DiagServerLocator`) |

Docs: `09-Install/docs/13-reports-detail-settings.md` (REP-50600 section),
`09-Install/docs/00-root_set_os_parameter.md` (firewall, IPv6 per interface).
Cookbooks: `70-Customer-Projects/Reports14_Only_manuall_install/` (OS steps 1+2,
Reports 9.5 + known problems).

## 8. Open points

- Try `02-Checks/reports_network_scan.sh` in a network with several
  environments; test `rwdiag.sh -monitor`.
- Test an own multicast channel per environment and a source-restricted
  firewall rule (§4c).

- `Utility.useNamingService()`: exact switch to COS naming; set up and test a
  naming service as alternative where multicast is not possible.
- Multicast TTL used by the Reports server (multi-subnet setups).
- Confirm which change fixed the customer case (firewall vs. IPv6 per interface).
