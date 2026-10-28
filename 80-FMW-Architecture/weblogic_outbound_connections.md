# Outbound connections of an FMW domain – what leaves the host, and the external-DTD trap

> Certificates, keys and trust stores of the whole stack (terms, where what lives, who needs what, customer PKI / TLS interception): [certificates_trust_stores.md](certificates_trust_stores.md)

Which connections a Forms & Reports 14.1.2 domain opens to other hosts, how
to measure that, and why an XML parser that downloads a DTD can block a
server start forever behind a firewall. Background for
`02-Checks/egress_check.sh` and the customer pre-check in
`09-Install/04-oracle_pre_checks.sh`.

Markers: **confirmed (live)** = measured on the test host (FMW 14.1.2,
Oracle JDK 21.0.12.1, OL 9, 2026-10-20), **documented** = Oracle
documentation (section 7), **assumption** = plausible, not verified.

---

## 1. What a Forms/Reports domain talks to

| Target | Who | Protocol | Needed |
|---|---|---|---|
| Repository DB (`DB_HOST:1521`) | AdminServer, WLS_FORMS, WLS_REPORTS (JDBC), Reports engines | TCP | yes |
| Application databases | `frmweb` (per session), Reports engines | SQL*Net | yes |
| LDAP / OID / AD (if configured) | WebLogic security providers, OPSS | LDAP(S) | if used |
| Reports discovery `228.5.6.7:<port>` | `rwserver` at start | UDP multicast, LAN only | yes ([discovery](reports_server_discovery_multicast.md)) |
| DNS, NTP | OS (resolver, chrony) | UDP | yes |
| Node Manager, AdminServer ↔ managed servers | WebLogic | T3, loopback / own host | yes |
| **Internet** | – | – | **no** – nothing in the product needs it at run time |
| MOS, yum, GitHub, Oracle advisories | **our scripts** (`04-oracle_pre_download.sh`, `dnf`, `cve_inventory.sh --online`), never the domain | HTTPS | only for downloads / the CVE watch |

**Confirmed (live) 2026-10-20:** full restart of the domain under
`tcpdump` – AdminServer incl. Enterprise Manager, WLS_FORMS incl. the
prestarted `frmweb`, WLS_REPORTS, `repserver01`, then the smoke test
(Forms JNLP + report → PDF). Not one connection and not one DNS lookup to
the outside. The only traffic beyond the LAN in the capture came from the
OS timer `dnf-makecache` (yum.oracle.com) – the systemd journal shows it,
not WebLogic.

## 2. The external-DTD trap

An XML file can name its DTD with a URL:

```xml
<!DOCTYPE web-app PUBLIC "-//Sun Microsystems, Inc.//DTD Web Application 2.3//EN"
          "http://java.sun.com/dtd/web-app_2_3.dtd">
```

The standard JAXP parser of the JDK (`com.sun.org.apache.xerces.internal`)
**downloads that DTD over the network – also in non-validating mode** –
unless the application resolves it locally (an `EntityResolver`, an XML
catalog) or switches the download off. Oracle: "External connections are
allowed even when FSP is on by default" (**documented**, JAXP Security
Guide); the default of `javax.xml.accessExternalDTD` is `all`.

How a missing local DTD turns into a start problem depends only on how the
network blocks the request (**confirmed (live)**, reproducer in
`SR/oam_external_dtd/`, JDK 21.0.12.1):

| Network behaviour | Parser result | Effect on a server start |
|---|---|---|
| internet reachable | DTD loaded, ~170 ms | works – the dependency stays hidden |
| connection refused (RST, e.g. `/etc/hosts` → an address that rejects) | `ConnectException` after ~55 ms | fast failure, the component decides |
| packets dropped (classic firewall DROP) | `ConnectException: Connection timed out` after **~130 s – per DTD** | start delayed by minutes |
| TCP accepted, no answer (application firewall / proxy keeping the port open) | **blocks forever** – no read timeout by default; thread `RUNNABLE` in `XMLEntityManager.setupCurrentEntity` → `HttpURLConnection.getInputStream` → `SocketDispatcher.read0` | server start hangs |

Customer case (OAM, not our stack – **confirmed** by Gunther at the
customer, without names): an OAM component parsed an XML with a
`java.sun.com` DTD that is not in its jar; an application firewall kept the
connection open → the start blocked. Workaround: an `/etc/hosts` entry for
`java.sun.com` to an address that refuses the connection – the request
fails fast instead of hanging. SR draft: `SR/oam_external_dtd/`
(gitignored).

**Not affected:** `java.util.Properties.loadFromXML` – Oracle: "the system
URI (http://java.sun.com/dtd/properties.dtd) is not accessed when
exporting or importing properties" (**documented**, `Properties` Javadoc;
**confirmed (live)**: 6 ms, no packet). Our Forms configuration
(`formsapp_*/config/timer.xml`, `IdentityStoreConfig.xml`) uses exactly
this DTD.

## 3. Mitigations

| Where | Setting | Effect (confirmed live, silent firewall in the path) |
|---|---|---|
| code (the fix) | resolve the DTD from the jar (`EntityResolver` / `javax.xml.catalog`) – like `Properties` does | no network at all |
| code | `http://apache.org/xml/features/nonvalidating/load-external-dtd = false` (only if the DTD defines nothing the application needs: entities, default attributes) | parse OK in 30 ms |
| JVM option | `-Djavax.xml.accessExternalDTD=` (empty = deny) | immediate `SAXParseException … 'http' access is not allowed` – **the component gets an error instead of the DTD** |
| JVM option | `-Dsun.net.client.defaultConnectTimeout=5000 -Dsun.net.client.defaultReadTimeout=5000` (default `-1` = infinite, **documented**) | `SocketTimeoutException` after 5 s instead of a hang – affects every `URLConnection` of that JVM |
| OS | `/etc/hosts`: the DTD host → an address that refuses | fast failure (customer workaround) |
| network | firewall REJECT instead of DROP / no silent proxy for servers | fast failure |

The JVM options and the hosts entry change *how* the parse fails, not
*that* it fails – whether the product tolerates the exception has to be
confirmed by Oracle for the affected component.

## 4. How to measure what a JVM sends

1. **Static:** external URLs in `DOCTYPE` / `schemaLocation` of the
   configuration – `02-Checks/egress_check.sh` lists them per host and file.
2. **Live snapshot:** `ss -tnp` – established connections that leave the
   host, per process (`egress_check.sh` without options).
3. **Capture during a start:** `tcpdump` of DNS and of outgoing TCP SYN /
   UDP to non-local networks, while the server is restarted
   (`egress_check.sh --capture <seconds>`), correlated with an `ss` poll
   for the process. A pcap has no process – the poll and the time stamps
   give it.
   Pitfall: the host itself is in the local network, so a filter
   `not src net <lan>` drops every outgoing packet – filter on the
   **destination** only.
4. **Which code:** a thread dump of the hanging JVM (`jstack <pid>` /
   `kill -3`); the blocked thread shows the XML entity manager and above it
   the calling class.
5. **Reproduce without the product and without root:** route the DTD
   request with `-Dhttp.proxyHost=127.0.0.1 -Dhttp.proxyPort=<port>` to a
   closed port (refused) or to `ncat -lk <port> --recv-only` (silent
   firewall) – `SR/oam_external_dtd/run_repro.sh`.

## 5. Where the library handles this

| Script | What |
|---|---|
| `02-Checks/egress_check.sh` | static DTD/schema URLs, `/etc/hosts` entries for them, XML/network JVM options of the running servers, live outbound connections, `--capture` |
| `09-Install/04-oracle_pre_checks.sh` | customer pre-check: proxy settings, does `http://java.sun.com/dtd/…` answer, fail fast or hang? |
| `09-Install/docs/00-root_set_os_parameter.md` | firewall: outgoing traffic is not filtered by firewalld |

## 6. Open points

- Which components of a Forms/Reports or an OAM domain parse XML with
  external DTDs at start – a capture per product at the next customer
  installation (`egress_check.sh --capture`).
- Whether WebLogic's XML Registry (domain-wide entity resolution) can map
  the `java.sun.com` DTDs to local copies as a supported workaround
  (**assumption**, to be clarified in the SR).

## 7. Sources

All checked 2026-10-20 (HTTP 200, title matches):

- Java API for XML Processing (JAXP) Security Guide (JDK 21) –
  `accessExternalDTD`, default `all`, "External connections are allowed
  even when FSP is on by default":
  https://docs.oracle.com/en/java/javase/21/security/java-api-xml-processing-jaxp-security-guide.html
- `java.util.Properties` (Java SE 21) – properties.dtd "is not accessed":
  https://docs.oracle.com/en/java/javase/21/docs/api/java.base/java/util/Properties.html
- Networking Properties (Java SE 8 guide) – `sun.net.client.defaultConnectTimeout` /
  `defaultReadTimeout`, default `-1`:
  https://docs.oracle.com/javase/8/docs/technotes/guides/net/properties.html
- `javax.xml.XMLConstants` (Java SE 21) – `ACCESS_EXTERNAL_DTD`:
  https://docs.oracle.com/en/java/javase/21/docs/api/java.xml/javax/xml/XMLConstants.html
