---
title: "Forms & Reports 14c Licensing – What the Licence Covers"
description: "How Oracle Forms & Reports 14.1.2 is licensed: runtime vs. Builder, NUP vs. processor, RCU database, WebLogic Basic, Reports deprecation, MOS note 885587.1."
---

# Forms & Reports licensing – a technical classification

> **Disclaimer (EN).** This page is a technical classification from the
> practice of installing and operating Forms & Reports. It is **no legal
> advice and no licence statement**. We take **no responsibility** for the
> correctness, completeness or currency of this page. Binding are only the
> customer's **ordering document** (contract) and the version of the *Oracle
> Fusion Middleware Licensing Information User Manual* that was valid when the
> licence was bought. Oracle changes rules, product names and prices; this
> page reflects the research of **2026-11-16**. Ask
> [Oracle License Management Services](https://www.oracle.com/corporate/license-management-services/),
> your Oracle account manager or a licence partner before you decide.
>
> **Haftungsausschluss (DE).** Diese Seite ist eine technische Einordnung aus
> der Praxis von Installation und Betrieb. Sie ist **keine Rechtsberatung und
> keine Lizenzaussage**. Wir übernehmen **keine Verantwortung** für Richtigkeit,
> Vollständigkeit oder Aktualität. Verbindlich sind allein das **Ordering
> Document** (Vertrag) des Kunden und die zum Kaufzeitpunkt gültige Fassung des
> *Oracle Fusion Middleware Licensing Information User Manual*. Oracle ändert
> Regeln, Produktnamen und Preise; Stand der Recherche ist der **16.11.2026**.
> Vor einer Entscheidung Oracle License Management Services, den Oracle Account
> Manager oder einen Lizenzpartner fragen.

Every statement is marked by how it is backed:

| Marker | Meaning |
|---|---|
| **documented** | Oracle document (licensing manual, price list, policy, release notes) – linked in the sentence |
| **secondary** | licence consultant, Oracle forum or community – not confirmed by an Oracle document |
| **derivation** | our conclusion from documented rules, no explicit Oracle sentence found |
| **confirmed (live)** | seen on the test host, with date |

## Glossary

| Abbreviation | Full name | What it is | Meaning for the licence |
|---|---|---|---|
| FMW | Oracle Fusion Middleware | Oracle's middleware product family (WebLogic, Forms, Reports, SOA …) | the FMWLC and the Lifetime Support Policy are organised by FMW release |
| BI EE | Oracle Business Intelligence Enterprise Edition | Oracle's analytics suite | one of the licences that allow Analytics Publisher in development / test |
| MOSC | My Oracle Support Community | Oracle's support forum | a secondary source |
| UPU | Universal Power Unit | an old processor-based metric of former contracts | only in old ordering documents (section 8) |
| OFR | Oracle Forms and Reports | the product on the price list that contains Forms Services and Reports Services | the licence this page is about |
| FMWLC | Oracle Fusion Middleware Licensing Information User Manual | Oracle's licensing manual for all middleware products | describes what a licence contains and how it is restricted |
| NUP | Named User Plus | user-based licence metric | every person **and** every non-human device that can use the programs |
| CSI | Customer Support Identifier | support contract number in My Oracle Support | shows the licences under support (and their current product names) |
| LMS | Oracle License Management Services | Oracle's licence audit / advisory unit | the binding contact for licence questions |
| OCI | Oracle Cloud Infrastructure | Oracle's public cloud | own counting rule: OCPUs instead of cores × core factor (section 4) |
| OCPU | Oracle CPU | the compute unit of OCI: one physical core (x86: 2 vCPUs, Ampere: 1) | x86: 2 OCPUs, Ampere: 4 OCPUs per processor licence |
| vCPU | virtual CPU | one hardware thread as the guest sees it | AWS / Azure / Google Cloud: 2 vCPUs (multi-threading on) per processor licence |
| BYOL | Bring Your Own Licence | own perpetual licences used in a cloud | counted by the cloud rules of section 4 |
| MOS | My Oracle Support | Oracle's support portal | notes like 885587.1, patches |
| OTN | Oracle Technology Network | Oracle's developer download site | own licence texts (developer / trial) |
| eDelivery | Oracle Software Delivery Cloud | download site for licensed software | Forms 14.1.2 comes from here; with a licence the own contract applies, without one a 30-day trial licence (evaluation, no production) |
| SSO | Oracle Single Sign-On | central login server of the old Application Server | included in OFR **only** to log in to OFR |
| OAM Basic | Oracle Access Manager Basic | reduced edition of Oracle's access / login server | included in OFR **only** to log in to OFR |
| OID | Oracle Internet Directory | Oracle's LDAP directory | included in OFR **only** for OFR users / groups / metadata |
| OHS | Oracle HTTP Server | Oracle's web server, based on Apache httpd ("Oracle Web Tier") | included in OFR **only** for OFR applications |
| WLS Basic | WebLogic Server Basic | licence-reduced edition of WebLogic Server (FMWLC appendix A) | included in OFR **only** to run OFR applications; many WebLogic features are not allowed |
| Analytics Publisher | Oracle Analytics Publisher (formerly BI Publisher) | Oracle's report server for pixel-perfect documents | included in OFR **only for production**; development / test need another licence |
| OWSM | Oracle Web Services Manager | policy / security layer for web services | included in OFR **only together with FADS** |
| FADS | Forms Application Deployment Services | deployment service for Forms applications ([forms_fads_app_dep_service.md](forms_fads_app_dep_service.md)) | the only allowed use of OWSM under OFR |
| iDS | Oracle Internet Developer Suite | developer licence (Form Builder, Reports Builder …) | needed by developers – OFR does not cover the Builder |
| iAS SE / EE | Oracle Internet Application Server Standard / Enterprise Edition | the old application server product family | has a restricted-use database for RCU – OFR has not |
| RCU | Repository Creation Utility | creates the metadata schemas of FMW in a database | needs a licensed database ([rcu_middleware_architecture.md §9.4](rcu_middleware_architecture.md)) |
| EE / SE2 | Oracle Database Enterprise Edition / Standard Edition 2 | database editions | SE2 needs a patch for RCU (ORA-00439, VPD) |
| VPD | Virtual Private Database | fine-grained access control of the database | used by RCU; not part of SE2 |
| OC4J | Oracle Containers for J2EE (Java 2 Enterprise Edition) | the Java application server of the old Oracle Application Server | named next to WLS Basic in the FMWLC (historical) |
| JDBC | Java Database Connectivity | database connections of WebLogic (data sources) | standalone JDBC module deployments are not allowed in WLS Basic |
| JRF | Java Required Files | the Oracle infrastructure libraries of an FMW domain | brings Oracle deployments / libraries into every Forms & Reports domain |
| WAR / EAR | Web Application Archive / Enterprise Application Archive | the deployment files of Java applications | an own WAR / EAR on the Forms domain is not an OFR application |
| RAC / FAN / ONS | Real Application Clusters / Fast Application Notification / Oracle Notification Service | clustered database and its event notification | WebLogic data sources with FAN / ONS = Active GridLink, not allowed in WLS Basic |
| MAN / WAN | Metropolitan / Wide Area Network | session replication between data centres | not allowed in WLS Basic |
| CCD / tile / die / chiplet | Core Complex Die (AMD) / tile (Intel) – one silicon chip of a multi-chip CPU | modern server CPUs consist of several dies in one package | no effect on OFR (core metric); for "Standard Edition" products every die counts as a socket |
| SMT | Simultaneous Multithreading (Intel: Hyper-Threading) | two threads per core | threads do not count, only cores |
| KVM / vCPU | Kernel-based Virtual Machine / virtual CPU | Linux virtualization / the CPUs a VM sees | Oracle Linux KVM with pinned cores = hard partitioning; vCPUs on VMware do not limit the count |
| WLST | WebLogic Scripting Tool | Jython scripting for WebLogic | runs the MOS measurement script |
| ORDS | Oracle REST Data Services | REST / web listener for the database (and APEX) | licensed with the database, not with OFR |
| APEX | Oracle Application Express | low-code web framework in the database | licensed with the database, not with OFR |
| DR | Disaster Recovery | standby / failover environment | counts as an environment that needs licences |
| JMS / SAF | Java Message Service / Store-and-Forward | WebLogic messaging; SAF forwards messages between servers | Unit-of-Order, Unit-of-Work and SAF agents are not allowed in WLS Basic |
| WLDF | WebLogic Diagnostics Framework | WebLogic's diagnostic / monitoring framework | not allowed in WLS Basic (except Oracle's own FMW module) |
| SNMP | Simple Network Management Protocol | monitoring protocol, WebLogic SNMP agent | not allowed in WLS Basic |
| WTC | WebLogic Tuxedo Connector | connection to Oracle Tuxedo | not allowed in WLS Basic |
| ActiveGridLink | Active GridLink for RAC | WebLogic data sources with RAC events (FAN / ONS) | not allowed in WLS Basic |

## 1. Typical customer questions

| Question | Short answer | Section |
|---|---|---|
| What does the Forms & Reports licence contain? | the runtime (Forms / Reports Services, compilers, WebUtil, Fusion Middleware Control) plus restricted-use products | [2](#2-what-the-ofr-licence-covers) |
| May our developers use Form Builder / Reports Builder with it? | no – the Builder is not covered | [3](#3-developers-and-the-builder) |
| Processor or Named User Plus? What does it cost? | both metrics exist; minimums and core factor apply | [4](#4-metric-and-prices) |
| We run on OCI / AWS / Azure / Google Cloud – how do we count? | OCI per OCPU (x86: 2 per processor licence), the others per vCPU – no core factor | [4](#4-metric-and-prices) |
| Is the database for the RCU schemas included? | no – a separately licensed database is needed | [5](#5-rcu-database-and-the-same-machine) |
| May ORDS, APEX or our own WAR run on the Forms WebLogic? | not under the OFR licence | [6](#6-weblogic-server-basic) |
| How do we check the WebLogic configuration? | MOS note 885587.1 (old script) + the licence indicators of our collector | [7](#7-mos-note-8855871-wls-basic-measurement-script) |
| Reports is deprecated – what now, especially Reports-only? | Reports 14.1.2 is supported (Premier until Dec 2030), plan the successor | [7b](#7b-oracle-reports-deprecated-and-reports-only-environments) |
| Do our Forms 4.5 / 6i licences still count? | depends on the contract and continuous support | [8](#8-old-contracts-forms-45--6i-and-older) |

## 2. What the OFR licence covers

The [FMWLC, section Oracle Forms and Reports](https://docs.oracle.com/en/middleware/fusion-middleware/fmwlc/application-server-products-new-structure.html)
lists the **integrated runtime components** of OFR (documented): Oracle Forms
Services, Oracle Reports Services, Oracle Enterprise Manager Fusion
Middleware Control, the Forms and Reports compilers and converters, and the
Forms WebUtil add-on. The same table lists OFR **14.1.2.0.0** among the
releases of the Application Server Products (together with 12.2.1.0 to
12.2.1.4).

The manual names the product itself "Oracle Forms and Reports (Oracle Reports
deprecated in 12.2.1.3.0)" – see section 7b.

**Restricted-use licences** – OFR contains these products, but only for the
named purpose ([FMWLC, Restricted-Use Licenses of OFR](https://docs.oracle.com/en/middleware/fusion-middleware/fmwlc/application-server-products-new-structure.html),
documented, quoted in short):

| Included product | Allowed use |
|---|---|
| Oracle Single Sign-On (SSO) | "restricted to providing authentication services to users accessing OFR" |
| Oracle Access Manager Basic (OAM Basic) | "restricted to providing authentication services to users accessing OFR" |
| Oracle Internet Directory (OID) | OFR users and groups with their credentials, synchronisation with third-party directories, "other metadata specific to OFR" |
| Oracle Web Tier / Oracle HTTP Server (OHS) | "for running OFR applications only" |
| WebLogic Server Basic or OC4J | "restricted to running OFR applications only" (section 6) |
| Oracle Analytics Publisher | "production deployment purposes only"; for development and testing "a full use Oracle Analytics Publisher, Oracle Business Intelligence EE, or Internet Developer Suite license is required" |
| Oracle Web Services Manager (OWSM) | "with the Forms Application Deployment Services (FADS) only" ([forms_fads_app_dep_service.md](forms_fads_app_dep_service.md)) |

Not in this list: a **database**. OFR contains no database licence of any
kind – see section 5.

## 3. Developers and the Builder

The FMWLC is explicit ([FMWLC, Oracle Forms and Reports](https://docs.oracle.com/en/middleware/fusion-middleware/fmwlc/application-server-products-new-structure.html),
documented): "Designtime components are included in the OFR installer.
However, a license to OFR does not include a license to the Designtime
components." Form Builder and Reports Builder are therefore **not** covered
by the OFR licence of the servers – even though the installer contains them.

- **Developer licence:** the current
  [Oracle Technology Global Price List](https://www.oracle.com/assets/technology-price-list-070617.pdf)
  (September 15, 2026) still lists **Internet Developer Suite** (iDS) with
  USD 5,800 per Named User Plus, support USD 1,276 (documented). That iDS
  covers Form Builder / Reports Builder 14.1.2 is the usual reading
  (secondary, e.g.
  [Redress Compliance, iDS](https://redresscompliance.com/oracle-ids-licensing-and-costs-breakdown));
  confirm it for your contract.
- **OTN licences** – three different texts, often mixed up:
  - [OTN Developer License Terms](https://www.oracle.com/downloads/licenses/standard-license.html)
    (documented): use "only for the purpose of developing, testing,
    prototyping, and demonstrating Your application and only as long as Your
    application has not been used for any data processing, business,
    commercial, or production purposes". After the application went live,
    further development under this text ends.
  - [OTN License Agreement](https://www.oracle.com/downloads/licenses/production-modify-license.html)
    ("production-modify", documented): additionally "running the Programs for
    your own internal business operations" – but only for programs shipped
    under exactly this text. In the Oracle forum it was quoted as proof for
    "OTN never in production"
    ([Oracle Forums, OTN License for development](https://forums.oracle.com/ords/apexds/post/otn-license-for-development-7753),
    secondary) – the text does not say that.
  - [OTN Free Developer License Terms](https://www.oracle.com/downloads/licenses/wls-dev-license.html)
    (WebLogic, documented): one Developer Desktop Computer per developer,
    used by one person, "You may not use the Programs in a Shared Development
    Environment". It is a WebLogic licence, not automatically one for the
    Builder.
- **eDelivery:** Forms 14.1.2 is downloaded from the Oracle Software Delivery
  Cloud (confirmed (live) 2026-11-16, download queue): one release "Oracle
  Forms and Reports 14.1.2.0.0" (published Dec 19, 2024, last updated Oct 16,
  2026) with the parts "Oracle Forms 14.1.2.0.0" and "Oracle Reports
  14.1.2.0.0" (2.6 GB each). **There is no separate Builder download** – Form
  Builder / Reports Builder come with the same software as the runtime; which
  part may be used is decided by the licence, not by the download.
  The terms are the **Oracle Standard Terms and Restrictions** of the portal
  (text "Last updated 21 November 2014", read 2026-11-16, documented):
  - access only if "(1) you have already obtained a license from Oracle, or
    an Oracle partner" – then the own contract ("Commercial License") governs
    the use – or "(2) … you accept that the Oracle Trial License Agreement …
    governs your use of the programs";
  - **Oracle Trial License Agreement:** "Trial Term" = "30 Days from the date
    of your acceptance"; "the temporary right to use the Programs for
    evaluation purposes on your single computer"; "only for evaluation and
    testing and not for production use"; after the trial term "you must
    acquire a license for each Program from Oracle";
  - "Programs downloaded for trial use or downloaded as replacement media may
    not be used to update any unsupported programs" – a customer without
    current support may **not** update an old installation with the 14.1.2
    download (section 8).
  For developers that means: the eDelivery download gives no lasting
  developer right for Form Builder / Reports Builder – after 30 days only
  with an own licence (iDS or equivalent).
- **Contractor scenario** (secondary, Oracle forum): a one-person software
  house developing for a customer – before go-live possibly OTN, afterwards
  an own developer licence or development on licences provided by the
  customer. Oracle licences are not transferable: check the customer's
  contract.

## 4. Metric and prices

**Two metrics** ([Technology Global Price List, definitions](https://www.oracle.com/assets/technology-price-list-070617.pdf),
documented):
- **Processor:** all processors where the programs are installed and/or
  running; cores × core factor of the
  [Oracle Processor Core Factor Table](https://www.oracle.com/us/corporate/contracts/processor-core-factor-table-070634.pdf),
  rounded up. Intel Xeon / AMD EPYC: **0.5** (table updated Jan 28, 2026).
  Example: 8 cores × 0.5 = 4 processor licences.
- **Named User Plus (NUP):** every individual authorised to use the programs,
  "regardless of whether the individual is actively using the programs".
  "A non human operated device will be counted as a named user plus" – batch
  jobs, service accounts and interfaces count too. With a multiplexing front
  end (web server, transaction monitor) users are counted at the front end.
- **Minimum 10 NUP per processor** for Forms and Reports (secondary – stated
  by licence consultants, e.g.
  [Redress Compliance](https://www.redresscompliance.com/oracle-forms-reports-licensing.html)
  and a [MOSC discussion](https://community.oracle.com/mosc/discussion/4517782/oracle-forms-and-reports-nup-license);
  the price list refers to a "user minimum table in the licensing rules",
  which we did not find in a public Oracle document). Example: 4 processors →
  at least 40 NUP, even with 12 real users.
- **Every environment counts:** the
  [Oracle Software Licensing Basics](https://www.oracle.com/a/ocom/docs/corporate/oracle-software-licensing-basics.pdf)
  (documented): "Use of Oracle Software requires Customers to license the
  respective Oracle programs in" production **and** non-production
  environments – "Development", "Quality Assurance/Testing & Staging",
  "Disaster Recovery". Development licences limited to development
  activities exist under the OTN terms (section 3).

**Prices** – list prices, without discount; binding is the offer / ordering
document:

| Source | Metric | Licence | Support 1st year |
|---|---|---|---|
| [Oracle Store](https://shop.oracle.com/apex/f?p=DSTORE:6:::::), "Oracle Forms and Reports (On-Premises)", EUR, read 2026-11-16 (VAT included or not: check) | Processor, perpetual | EUR 21,390.00 | EUR 4,705.80 (22 %) |
| same | Named User Plus, perpetual | EUR 427.80 | EUR 94.12 (22 %) |
| [Technology Global Price List](https://www.oracle.com/assets/technology-price-list-070617.pdf), USD, September 15, 2026 | Processor | USD 23,000.00 | USD 5,060.00 |
| same | Named User Plus | USD 460.00 | USD 101.20 |

Two different minimums – do not mix them up:
- the **Oracle Store** sells NUP with a **minimum order quantity of 10** –
  a minimum per order;
- the **licence rule** "10 NUP per processor" (secondary, above) can be much
  higher: 4 processors → 40 NUP.

Example calculation with the store prices (Intel x86, 8 cores = 4 processor
licences; example, list price, without discount):

| Variant | Licences | Licence price | Support / year |
|---|---|---|---|
| Processor | 4 × EUR 21,390.00 | EUR 85,560.00 | EUR 18,823.20 |
| NUP at the minimum | 40 × EUR 427.80 | EUR 17,112.00 | EUR 3,764.80 |
| NUP, 100 users | 100 × EUR 427.80 | EUR 42,780.00 | EUR 9,412.00 |

Break-even: EUR 21,390.00 / EUR 427.80 = **50 NUP per processor** – below
that NUP is cheaper, above it the processor metric (derivation). Internet
applications with unknown users can only be licensed per processor
(secondary).

**Virtualization:** the
[Oracle Partitioning Policy](https://www.oracle.com/assets/partitioning-070609.pdf)
(documented, "educational purposes only", as of February 14, 2022) calls
VMware and Oracle VM (without core pinning) **soft partitioning**, which "is
not permitted as a means to determine or limit the number of software
licenses required for any given server or cluster of servers". On VMware the
count can therefore extend to all physical cores of the host / cluster –
clarify with LMS before you license per processor on a hypervisor. Hard
partitioning is accepted for Oracle Linux KVM "only if specific cores are
allocated" as described in
[Oracle Linux KVM hard partitioning](https://www.oracle.com/a/ocom/docs/linux/ol-kvm-hard-partitioning.pdf)
(documented, same policy).

**Public cloud – own rules instead of core factor and Partitioning Policy.**
Licences you bring yourself (bring your own licence, BYOL) are counted by
the size of the cloud instance, not by the physical host:
- **Oracle Cloud Infrastructure (OCI)**: the section "Running Oracle Licenses
  in the Oracle Cloud and Oracle Compute Cloud@Customer" of the
  [Oracle Processor Core Factor Table](https://www.oracle.com/us/corporate/contracts/processor-core-factor-table-070634.pdf)
  (documented, updated January 28, 2026) says: "For running on the x86
  platform, every one (1) Processor license covers use of the program on two
  (2) OCPUs. For running on the Ampere (Altra/AltraMax and AmpereOne)
  platform, every one (1) Processor license covers use of the program on
  four (4) OCPUs." For NUP "you must have the greater of: a) the actual
  number of users, or b) the minimum number of NUP licenses per Processor",
  e.g. "a minimum of 10 NUP licenses for every two (2) OCPUs of x86" for
  programs with a minimum of 10 NUP per processor. An OCPU (Oracle CPU) is
  one physical core – on x86 with two hardware threads (2 vCPUs), on Ampere
  one thread. Example: a Forms VM with 2 OCPUs x86 (4 vCPUs) needs 1
  processor licence, or at least 10 NUP if the 10-NUP minimum applies to OFR
  (secondary, see above); with 4 OCPUs it is 2 processor licences / 20 NUP.
  Programs with "Standard Edition" in the name count "every one (1) Processor
  license … on four (4) OCPUs" (same source).
- **AWS, Microsoft Azure and Google Cloud** ("Authorized Cloud Environments"):
  [Licensing Oracle Software in the Cloud Computing Environment](https://www.oracle.com/a/ocom/docs/cloud-licensing-070579.pdf)
  (documented, "educational purposes only", in effect as of September 4,
  2026): "count two vCPUs as equivalent to one Oracle Processor license if
  multi-threading of processor cores is enabled, and one vCPU as equivalent
  to one Oracle Processor license if multi-threading of processor cores is
  not enabled", counted on "the maximum vCPUs of an instance type"; "the
  Oracle Processor Core Factor Table is not applicable". The policy names
  only these three vendors; OCI is covered by the Core Factor Table above.
- Other clouds and hosters (not named in either document): treat them like
  on-premises virtualization (Partitioning Policy) and clarify with LMS.

The collector writes the cloud as `host;cloud` (`oci`, `aws`, `azure`, `gcp`
or `none`, read from the DMI data of the guest as cloud-init does: chassis
asset tag `OracleCloud.com` = OCI) and `host;cpu_arch` into
`45_licence.txt`; the environment analysis turns it into a "Licence" finding
with the count of this instance.

**Socket metric and chiplets – not an OFR topic, but one for the database
next to it.** The price list counts a processor as an occupied socket only
"When licensing Oracle programs with Standard Edition One, Standard Edition 2
or Standard Edition in the product name … however, in the case of
multi-chip modules, each chip in the multi-chip module is counted as one
occupied socket"
([Technology Global Price List, definition Processor](https://www.oracle.com/assets/technology-price-list-070617.pdf),
documented). "Forms and Reports" has no "Standard Edition" in its name: it
is counted **per core × core factor**; how many dies (chiplets: AMD CCDs,
Intel tiles) a CPU has does not matter for OFR. It matters for
- a **Database Standard Edition 2** (SE2) for the RCU schemas or on the same
  host: at most 2 sockets, every die counts as a socket – a modern multi-die
  CPU makes SE2 impossible on that server (details and a CPU list:
  [Oracle SE2 with Oracle 26ai – chiplets](https://www.pipperr.de/dokuwiki/doku.php?id=dba:oracle_se2_with_oracle26ai),
  the author's own article, secondary);
- **WebLogic Server Standard Edition**, if a customer licenses it instead of
  the WLS Basic included in OFR: "Standard Edition" is in the product name,
  so the socket / chip counting applies (derivation from the wording; the
  price list excepts only WebCenter Enterprise Capture SE and the Java SE
  products).

**Example – a typical 2-socket AMD EPYC 9654 server** (96 cores and 12
compute dies (CCDs) per CPU; list prices of the Oracle Store, 2026-11-16,
without discount; example, not an offer):

| Step | Forms & Reports per processor | Forms & Reports per NUP (minimum) |
|---|---|---|
| Cores | 2 sockets × 96 cores = 192 cores (threads / SMT do not count) | same |
| Core factor AMD EPYC | 192 × 0.5 = **96 processor licences** | – |
| Licences needed | 96 processor licences | at least 10 NUP × 96 processors = **960 NUP** (secondary rule, section 4), or more if more users / devices |
| Licence price (store, EUR) | 96 × 21,390.00 = **EUR 2,053,440.00** | 960 × 427.80 = **EUR 410,688.00** |
| Support per year (22 %) | 96 × 4,705.80 = EUR 451,756.80 | 960 × 94.12 = EUR 90,355.20 |
| Same in USD (price list, Sept 2026) | 96 × 23,000 = USD 2,208,000 (support USD 485,760) | 960 × 460 = USD 441,600 (support USD 97,152) |
| Break-even | – | NUP is cheaper up to 50 NUP per processor = **4,800 named users / devices** |
| The 12 CCDs per CPU | no effect (core metric) | no effect |
| Database SE2 on this server | not allowed: 2 × 12 CCDs = 24 "sockets" > 2 | – |

What the example shows:
- Per processor the big box is expensive, because every core counts, also
  the cores the Forms environment never uses. With fewer than 4,800 named
  users the NUP metric is cheaper – but its minimum still follows the 96
  processors (960 NUP, not 10).
- A Forms VM with 8 vCPUs on this host under **VMware** does not reduce the
  count: soft partitioning – all 192 cores of the host (or of every host of
  the cluster the VM may run on) count. With **Oracle Linux KVM hard
  partitioning** (8 pinned cores) it is 8 × 0.5 = 4 processor licences, or at
  least 40 NUP.
- For Forms & Reports a smaller dedicated server (or hard partitioning) is
  usually the cheaper licence decision than a share of a large virtualization
  host – to be clarified with LMS before the hardware is bought.

## 5. RCU database and the same machine

- **No database in OFR:** the restricted-use list of OFR contains no Oracle
  Database ([FMWLC, OFR](https://docs.oracle.com/en/middleware/fusion-middleware/fmwlc/application-server-products-new-structure.html),
  documented). The RCU schemas of a Forms & Reports domain need a
  **separately licensed database** – this repository's decision and audit
  wording: [rcu_middleware_architecture.md §9.4](rcu_middleware_architecture.md#94-licence--separately-licensed-database-decision-2026-10-27).
- **The RCU database of iAS:** only Oracle Internet Application Server
  Standard / Enterprise Edition contains "The Oracle Database (Enterprise
  Edition) … only for use with the Oracle Repository Creation Utility database
  schema for storing product metadata" (documented, same page, section
  Oracle Internet Application Server). With the notes: the restricted use
  does not apply when the schemas go into an existing licensed database; a
  database machine that runs no other FMW installation needs no iAS licence;
  the RCU schemas may raise the number of database users. This applies to
  iAS customers, **not** to OFR-only customers.
- **Forms and database on the same machine:** each product is licensed for
  the processors where it is installed / running, so the machine needs
  licences for **both** (derivation from the processor definition – no
  explicit Oracle sentence found).
- **Technical facts** ([Forms 14.1.2, Using RCU](https://docs.oracle.com/en/middleware/developer-tools/forms/14.1.2/install-fnr/using-repository-creation-utility.html),
  [Preparing to Install](https://docs.oracle.com/en/middleware/developer-tools/forms/14.1.2/install-fnr/preparing-install.html),
  documented): "Running RCU is not required for domains that will be based
  on the Oracle Forms Development template"; the Form Builder Standalone
  option "cannot coexist with Fusion Middleware Infrastructure in the same
  Home"; only the WebLogic of FMW Infrastructure is supported ("Do not
  attempt to install and use any of the standalone WebLogic Server
  installations with Oracle Forms or Reports").
- **SE2:** RCU uses fine-grained access control (VPD), SE2 answers with
  ORA-00439; a patch is the workaround
  ([dbi services](https://www.dbi-services.com/blog/oracle-fmw-14-installation-ora-00439-feature-not-enabled-fine-grained-access-control/),
  secondary; details in [rcu_middleware_architecture.md §9.3](rcu_middleware_architecture.md)).
  Besides the technique, SE2 has the **socket limit**: at most 2 sockets per
  server, and with multi-chip CPUs every die counts as a socket (section 4,
  "Socket metric and chiplets"). An RCU database on SE2 on the same host as
  Forms is impossible on a multi-die server (e.g. AMD EPYC 9004 / 9005,
  Intel Xeon 6 / Sapphire Rapids XCC) – check the CPU model and the die count
  per CPU (in writing from the hardware vendor) before SE2 is planned.
- **Which edition is installed?** Without a database login: the edition
  chosen at the installation of a database home is in
  `$ORACLE_HOME/inventory/globalvariables/oracle.server/globalvariables.xml`,
  variable `oracle_install_db_InstallEdition` (`EE`, `SE2`, …; confirmed
  (live) 2026-11-16 on a 19.33 home, also known from 11g; 23ai / 26ai still
  to check). The collector maps every running instance to its home (Linux
  `/proc/<pmon pid>/exe`, Windows the image path of the `OracleService<SID>`
  service) and reads that variable. It is the choice at installation time –
  the options really used (e.g. Partitioning) are only visible inside the
  database (`DBA_FEATURE_USAGE_STATISTICS`).

## 6. WebLogic Server Basic

**The OFR rule** ([FMWLC, OFR](https://docs.oracle.com/en/middleware/fusion-middleware/fmwlc/application-server-products-new-structure.html),
documented): "Use of Oracle WebLogic Server Basic or Oracle Containers for
J2EE (OC4J) is restricted to running OFR applications only." The same
applies to Oracle HTTP Server.

**The contradiction:** the appendix
[WebLogic Server Basic](https://docs.oracle.com/en/middleware/fusion-middleware/fmwlc/weblogic-server-basic.html)
(documented) says WLS Basic "is only for running components provided within
these products such as Forms, Reports, Discoverer and Portal", and in the
same note "It can also be used for custom Java applications such as those
developed for Oracle Containers for J2EE". That second sentence is a leftover
from the iAS times. For an OFR licence the stricter OFR sentence applies
(derivation).

**In practice:** no ORDS, no APEX and no own WAR / EAR on the Forms &
Reports domain. This library runs ORDS **standalone** with its own Jetty,
outside WebLogic ([ords_architecture.md](ords_architecture.md)); ORDS and
APEX are features of the licensed database, not of OFR.

**Restricted features** of WLS Basic
([FMWLC appendix A, Table A-1](https://docs.oracle.com/en/middleware/fusion-middleware/fmwlc/weblogic-server-basic.html),
documented, grouped):

| Area | Not allowed in WLS Basic |
|---|---|
| High availability | whole server migration, service migration, Managed Server cloning, MAN / WAN state replication, singleton services, cluster constraints deployment, overload management, server ADMIN and STANDBY mode, GridLink data sources (Active GridLink for RAC) |
| Deployment | production redeployment (versioned redeploy), application administration mode, changing the deployment order, FastSwap, standalone deployment of WebLogic JMS and JDBC modules |
| JMS | Message Unit-of-Order, Unit-of-Work message groups, JMS Store-and-Forward (SAF) agents |
| Further services | WebLogic Diagnostics Framework (WLDF), WebLogic SNMP agents, WebLogic Tuxedo Connector (WTC), HTTP Publish-Subscribe Server, Work Managers to prioritize work |
| Web services | buffered, asynchronous and conversational web services, JMS transport |
| Tooling | Configuration Wizard / Domain Template Builder / pack-unpack for custom domains and templates, recording console operations as WLST scripts |
| APIs | CommonJ Work Manager for application-initiated work, WebLogic JMS clients for .NET and C |

The Oracle domain templates of Forms & Reports bring their own Oracle
deployments, libraries, data sources and the Oracle WLDF module
(`Module-FMWDFW`) – these are part of the product, not a customer use of a
restricted feature (derivation from the purpose of the restriction).

## 7. MOS note 885587.1 (WLS Basic measurement script)

[My Oracle Support Doc ID 885587.1](https://support.oracle.com/rs?type=doc&id=885587.1)
(KB158056, "WebLogic Server Basic License Feature Usage Measurement Script",
MOS login needed; documented):
- a WLST script that connects to the Administration Server and lists the
  usage / configuration of restricted WLS Basic features;
- written for WLS 11gR1, valid for **WebLogic 10.3.1 to 12.2.1.4.0**;
  version 20 of 2015-05-13 (ActiveGridLink); the note was last reviewed in
  2019 and updated in 2026;
- "will no longer [be] maintained … Provided as-is for historical purposes
  only"; not every restriction is checked; no data is transmitted; its use
  is voluntary;
- the note says it is referenced from the Licensing Information User Manual.
  The current WLS Basic appendix of the 14.1.2 manual (read 2026-11-16) no
  longer names it.

The script itself is downloaded from MOS (Oracle copyright) – it is **not**
part of this repository. Run under 14.1.2 (untested):
`$ORACLE_HOME/oracle_common/common/bin/wlst.sh wls-basic-measurement.py username <user> password <pwd> url t3://<host>:<port> output report.txt`
(the password on the command line ends up in the process list – rather let
the script prompt for it).

**Our assessment for 14.1.2** (read 2026-11-16, no code reproduced here):
- the list of Oracle applications inside the script is from 11g – newer
  Oracle deployments of a 14.1.2 domain (e.g. `opss-rest`, FADS, OWSM / JRF
  applications) are treated as customer applications and can show up as
  false findings (work managers, deployment order);
- the domain-wide **administration port** is counted as an error. In WLS
  14.1.x **secured production mode** switches the administration port on
  (to be verified per domain). The licence restricts the start in ADMIN /
  STANDBY, not the port – treat it as a warning. Domains built with this
  library run production mode without secured mode (confirmed (live)
  2026-11-16: no domain-wide administration port);
- the global work manager check uses a name filter that can hit work
  managers of FMW templates;
- the most important restriction of OFR – **only OFR applications on the
  domain** – is not checked at all: an ORDS or an own WAR stays unseen;
- some outputs of the script are wrong in verbose mode and an error path is
  broken (no impact on the result).

**Our alternative:** the collector `collect_fmw_env.sh` / `.ps1`
(`70-Customer-Projects/tools`) writes **licence indicators**
(`45_licence.txt`): the restricted features that are visible in the domain
configuration, every application / library of the domain, CPU and
virtualization, a database (with the edition chosen at its installation) or
ORDS on the same host – offline, without an admin login. The environment analysis compares the deployments with a list
of the Oracle / OFR deployments and shows the findings as hints, never as a
"violation". What only the running server knows (server state ADMIN /
STANDBY, application work managers, FastSwap, application admin mode) still
needs the MOS script.

## 7b. Oracle Reports: deprecated, and Reports-only environments

**Status** (documented):
- [Release Notes Forms 14.1.2](https://docs.oracle.com/en/middleware/developer-tools/forms/14.1.2/releasenotes-fnr/release-notes-oracle-forms.pdf):
  "Although included in this release, Oracle Reports has been deprecated.
  Oracle is not planning any functional enhancements other than critical bug
  fixes and changes necessary to make it compatible with a new supporting
  technology stack." Oracle recommends Oracle Analytics Publisher, "Oracle's
  strategic product for enterprise reporting". The Reports Naming Service is
  desupported.
- The FMWLC names the product "Oracle Forms and Reports (Oracle Reports
  deprecated in 12.2.1.3.0)".
- [Statement of Direction Oracle Reports](https://www.oracle.com/a/otn/docs/oracle-reports-sod.pdf)
  (September 2021, version 1.1): "Oracle Reports is no longer under active
  development"; Reports 10g (2005) was the last release with new features;
  "there is no upgrade or migration assistance offered for moving from Oracle
  Reports to Oracle BI Publisher"; availability beyond 12.2.1.4 was "subject
  to continued availability of the technologies that Oracle Reports depends
  on". It then shipped with 14.1.2 – statements about "the last release" are
  only valid with their date.

**Deprecated vs. desupported:** deprecated = still included and supported,
but no further development; desupported = no longer included / supported
(as used in the release notes: Reports deprecated, Reports Naming Service
desupported).

**Support dates** ([Oracle Lifetime Support Policy: Fusion Middleware](https://www.oracle.com/us/assets/lifetime-support-middleware-069163.pdf),
effective date April 13, 2026, documented; Forms and Reports are part of the
FMW release lines):

| Release | Premier Support ends | Extended Support ends | Sustaining |
|---|---|---|---|
| Fusion Middleware 14.1.x (incl. Forms and Reports 14.1.2) | Dec 2030 | Dec 2033 | indefinite |
| Fusion Middleware 12c 12.2.x (incl. Forms and Reports 12.2.1.x) | **Dec 2026** | Dec 2027 | indefinite |

For 12.2.1.4 customers the move to 14.1.2 is therefore due now, Reports
included.

**Licence for a Reports-only customer:**
- There is no separate Reports product on the price list – the price list
  knows "Forms and Reports" only
  ([Technology Global Price List](https://www.oracle.com/assets/technology-price-list-070617.pdf),
  documented). Reports-only also needs the OFR licence; the unused Forms part
  makes it neither cheaper nor different (derivation).
- Moving to **Analytics Publisher:** OFR contains Analytics Publisher only
  for production; development and testing of the new reports need a full
  Analytics Publisher, BI EE or iDS licence (documented, section 2). A full
  move usually changes the licence – clarify with LMS.
- **APEX** as an alternative is licensed with the database, not with OFR
  (Oracle's view as marketing:
  [Oracle Reports is Deprecated. How can Oracle APEX help you?](https://blogs.oracle.com/apex/oracle-reports-is-deprecated)).
- **Practice for the 14c move:** Reports 14.1.2 is the safe next step (this
  library builds Reports-only environments with
  `INSTALL_COMPONENTS=REPORTS_ONLY`); start the replacement in parallel and
  plan the operating time along the Lifetime Support dates. The environment
  analysis notes this as a "Lifecycle" finding whenever Reports is used.

## 8. Old contracts (Forms 4.5 / 6i and older)

- Binding is the **ordering document** with the licence definitions of the
  purchase date (Concurrent Device, UPU, Named User …). Today's FMWLC
  describes "Oracle Forms and Reports", not "Developer/2000 Runtime".
- The [Oracle Forms 6i and Reports 6i Licensing FAQ](https://oracle.com/a/ocom/docs/forms-reports-070602.pdf)
  (policies as of June 1, 2003, documented):
  - "Customers current on their software update may upgrade to the latest
    version at no additional charge";
  - Forms and Reports were "no longer sold as stand alone products (since
    July 2000)";
  - "Customers using the free client/server deployment licensing from
    previous releases of Forms and Reports … would need to upgrade their
    licenses to full use iAS EE licenses for web deployment."
- A gap in Software Update License & Support means no automatic upgrade right
  – possibly reinstatement fees (secondary).
  The eDelivery terms say the same for the download itself: "Programs
  downloaded for trial use or downloaded as replacement media may not be used
  to update any unsupported programs" (section 3, documented).
- Tip: the current support renewal or the CSI overview in MOS often shows the
  internally converted product names of today (e.g. "Forms and Reports –
  Named User Plus Perpetual").
- Whether an old client/server runtime licence covers web deployment with
  WebLogic and OHS depends on that conversion – do not assume it without a
  written statement of Oracle LMS.

## 9. Checklist – licence check of a Forms 14 environment

- [ ] Ordering documents, CSI numbers and the last support invoice of the customer collected
- [ ] Metric clear (processor or NUP); cores and core factor of every Forms / Reports server noted
- [ ] Virtualization noted (VMware / KVM / Oracle VM, cluster size) and clarified against the Partitioning Policy
- [ ] Public cloud noted: OCI counted per OCPU (x86 2, Ampere 4 OCPUs per processor licence), AWS / Azure / Google Cloud per vCPU (cloud licensing policy)
- [ ] With NUP: people plus batch jobs / service accounts / interfaces counted, minimum per processor checked
- [ ] Every environment listed and licensed (production, development, QA / test / staging, DR – Oracle Software Licensing Basics)
- [ ] Developers with Form Builder / Reports Builder have an own developer licence (iDS or equivalent)
- [ ] RCU schemas in a fully licensed database (or the iAS restricted use documented)
- [ ] RCU database on SE2: at most 2 sockets, CPU model and dies per CPU checked (chiplets count as sockets)
- [ ] Additional database users of the RCU schemas covered by the database licence
- [ ] Forms and database on the same machine: both products licensed for that machine
- [ ] Only OFR applications on the Forms domain (no ORDS, no APEX, no own WAR)
- [ ] OHS only for OFR applications
- [ ] Licence indicators of the collector (`45_licence.txt`) evaluated; MOS script 885587.1 run where runtime checks are needed
- [ ] Analytics Publisher of OFR only in production
- [ ] OWSM only for FADS
- [ ] Reports in use: successor planned along the Lifetime Support dates
- [ ] Open questions asked in writing to Oracle LMS / the account manager

## 10. Open points

1. ~~Licence text of the eDelivery download~~ – answered 2026-11-16: Oracle
   Standard Terms and Restrictions with the 30-day Oracle Trial License for
   users without a licence (section 3).
2. Does iDS cover Form Builder / Reports Builder 14.1.2, or is there a
   successor? The price list of September 2026 still lists iDS.
3. Secured production mode / administration port: our library domains run
   without secured mode (confirmed (live)); a domain created with the Oracle
   defaults still has to be checked.
4. Allowlist of the OFR deployments: started from the 14.1.2 test domain
   (7 applications, about 90 Oracle libraries); 12.2.1.x domains to add with
   the first customer collections.
5. Minimum 10 NUP per processor: no public Oracle primary source found that
   names OFR. The Core Factor Table (OCI section) confirms the concept –
   "programs with a license minimum of 10 NUP per Processor" and of 25 NUP –
   but not which programs have which minimum.
6. Conversion of old Forms licences: case by case, in writing from Oracle
   LMS.

## 11. Sources

Oracle (primary):
- Oracle Fusion Middleware Licensing Information User Manual, Application
  Server Products (OFR, iAS restricted use):
  <https://docs.oracle.com/en/middleware/fusion-middleware/fmwlc/application-server-products-new-structure.html>
- FMWLC, appendix WebLogic Server Basic:
  <https://docs.oracle.com/en/middleware/fusion-middleware/fmwlc/weblogic-server-basic.html>
- Oracle Technology Global Price List (September 15, 2026):
  <https://www.oracle.com/assets/technology-price-list-070617.pdf> – overview:
  <https://www.oracle.com/corporate/pricing/>
- Oracle Store, Oracle Forms and Reports (On-Premises):
  <https://shop.oracle.com/apex/f?p=DSTORE:6:::::>
- Oracle Processor Core Factor Table:
  <https://www.oracle.com/us/corporate/contracts/processor-core-factor-table-070634.pdf>
- Licensing Oracle Software in the Cloud Computing Environment (AWS, Azure,
  Google Cloud; in effect as of September 4, 2026):
  <https://www.oracle.com/a/ocom/docs/cloud-licensing-070579.pdf>
- Oracle Partitioning Policy:
  <https://www.oracle.com/assets/partitioning-070609.pdf>
- Oracle Linux KVM hard partitioning:
  <https://www.oracle.com/a/ocom/docs/linux/ol-kvm-hard-partitioning.pdf>
- Oracle Software Licensing Basics:
  <https://www.oracle.com/a/ocom/docs/corporate/oracle-software-licensing-basics.pdf>
- Oracle Lifetime Support Policy, Fusion Middleware:
  <https://www.oracle.com/us/assets/lifetime-support-middleware-069163.pdf>
- Release Notes for Oracle Forms 14.1.2.0.0:
  <https://docs.oracle.com/en/middleware/developer-tools/forms/14.1.2/releasenotes-fnr/release-notes-oracle-forms.pdf>
- Statement of Direction Oracle Reports (2021):
  <https://www.oracle.com/a/otn/docs/oracle-reports-sod.pdf>
- Forms 14.1.2, Using the Repository Creation Utility:
  <https://docs.oracle.com/en/middleware/developer-tools/forms/14.1.2/install-fnr/using-repository-creation-utility.html>
- Forms 14.1.2, Preparing to Install:
  <https://docs.oracle.com/en/middleware/developer-tools/forms/14.1.2/install-fnr/preparing-install.html>
- OTN Developer License Terms:
  <https://www.oracle.com/downloads/licenses/standard-license.html>
- OTN License Agreement (production-modify):
  <https://www.oracle.com/downloads/licenses/production-modify-license.html>
- OTN Free Developer License Terms (WebLogic):
  <https://www.oracle.com/downloads/licenses/wls-dev-license.html>
- Oracle Forms 6i and Reports 6i Licensing (FAQ, 2003):
  <https://oracle.com/a/ocom/docs/forms-reports-070602.pdf>
- Oracle APEX blog, Oracle Reports is Deprecated:
  <https://blogs.oracle.com/apex/oracle-reports-is-deprecated>
- Oracle Software Delivery Cloud (eDelivery), Oracle Standard Terms and
  Restrictions with the Oracle Trial License Agreement (shown at the download,
  Oracle account needed): <https://edelivery.oracle.com/>
- Oracle License Management Services:
  <https://www.oracle.com/corporate/license-management-services/>
- My Oracle Support, Doc ID 885587.1 / KB158056 (MOS login):
  <https://support.oracle.com/rs?type=doc&id=885587.1>

Community / consultants (secondary):
- Gunther Pipperr, Oracle SE2 with Oracle 26ai (chiplets / multi-chip modules):
  <https://www.pipperr.de/dokuwiki/doku.php?id=dba:oracle_se2_with_oracle26ai>
- Oracle Forums, OTN License for development:
  <https://forums.oracle.com/ords/apexds/post/otn-license-for-development-7753>
- MOSC, Oracle Forms and Reports NUP license:
  <https://community.oracle.com/mosc/discussion/4517782/oracle-forms-and-reports-nup-license>
- dbi services, FMW 14 installation ORA-00439:
  <https://www.dbi-services.com/blog/oracle-fmw-14-installation-ora-00439-feature-not-enabled-fine-grained-access-control/>
- Redress Compliance, Oracle Forms and Reports licensing:
  <https://www.redresscompliance.com/oracle-forms-reports-licensing.html>
- Redress Compliance, iDS licensing:
  <https://redresscompliance.com/oracle-ids-licensing-and-costs-breakdown>
- Oracle Licensing Experts, Forms & Reports licensing:
  <https://oraclelicensingexperts.com/blog/oracle-forms-reports-licensing/>

Some Oracle pages (forums, blogs, OTN licences) refuse automated requests;
they open in a browser.
