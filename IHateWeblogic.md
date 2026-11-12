

# IHateWeblogic – Oracle Forms & Reports Diagnostic Script Library

<p align="center">Made by <a href="https://www.pipperr.info/" target="_blank" rel="noopener"><img src="assets/IHateWeblogic_logo.png" alt="IHateWeblogic logo" width="160"></a> Gunther & Claude</p>

Author: Gunther Pipperr | <https://pipperr.de>
License: Apache 2.0

## Meaning of the Project Name


- **I** – Innovation
- **H** – Helps
- **A** – Admins
- **T** – To
- **E** – Enhance
- **W** – Weblogic
- **B** – Based
- **L** – Lifecycle
- **O** – Operations
- **G** – Governance
- **I** – Integration
- **C** – Control


Innovation Helps Admins To Enhance Weblogic-Based Lifecycle Operations, Governance, Integration & Control.



## Intention

Oracle Forms and Reports on WebLogic is powerful but notoriously difficult to diagnose.
This script library exists because the author has spent too many hours debugging obscure
configuration issues, font problems, segfaults, and SSL mismatches on Oracle Middleware
installations. It brings together knowledge from the author's blog (www.pipperr.de) and
years of documentation from real customer projects, built with the help of Claude to
turn personal experience into reusable automation and tooling.

This library focuses on:

- **Installation and configuration** of an Oracle WebLogic Forms/Reports and APEX
  setup behind Nginx – scripted, repeatable, loopback-only and clone-capable
- **Patching** – the monthly Oracle cycle (CPU / CSPU / Security Alerts) for
  WebLogic, Forms/Reports, OPatch and the JDK, with backup and rollback
- **Security** – hardening of WebLogic, Reports and Nginx, encrypted credentials,
  certificate management, CVE inventory against the Oracle advisories
- **Diagnosis** after installation and in running environments
- **Configuration validation** against the Oracle documentation
- **Bug hunting and root cause analysis**
- **Documentation** for support cases and customer cookbooks

### Why Forms & Reports still matter – an appeal

Oracle Forms and Oracle Reports have been tied to the success of the
Oracle database from the very beginning. The database came first, in 1979,
and its forms tools (IAF, later SQL\*Forms) followed in the early 1980s.
Without the success of Forms, Oracle the company – and its database –
would not be what they are today. Generations of business applications
were built with it, and they made the database indispensable in countless
companies.

For more than twenty years Oracle has not really kept this stack in focus.
Even so, thousands of companies still run Forms and Reports productively
in their core processes – against every prediction of their end, and in
spite of all the resistance. B2B technology databases alone list between
roughly 3,100 and 12,400 companies using Oracle Forms (Landbase: 3,142;
6sense: about 12,200; iDataLabs: 12,367 – state 2026)¹. Counting the
in-house systems that never show up in such databases, a realistic
estimate is several tens of thousands of active Forms applications
worldwide. The software keeps delivering real value to
its customers. There are no fancy bells and whistles; it often looks
old-fashioned and can be uncomfortable to run (hence this library). But
it works, it is paid for, and the business depends on it.

So my appeal to Oracle: **keep taking these customers seriously.** The
high license fees for the database are paid because there is a good
application running on it. Once Forms leaves a company, the next
competitor – SAP HANA or any other platform – is already waiting around
the corner to replace one more Oracle database. Old soldiers never die:
Forms will retire together with us, whether Oracle likes it or not.

And my appeal to the DOAG, all Oracle user groups and every customer:
whenever you meet an Oracle sales representative, make it clear that the
end of Forms in a company can also mean the end of the Oracle story there –
and that there are many alternatives. All the more so as many of Oracle's
own business applications still rely on Forms and Reports today – the
E-Business Suite first among them, also when run in Oracle's cloud, and the
OPERA 5 property management system of Oracle Hospitality (formerly MICROS
Fidelio), whose application server is a WebLogic / Forms / Reports stack.

### And Oracle Reports – deprecated for years, still doing its job

Oracle Reports has been deprecated for many years, yet it cannot be taken
out of an Oracle Forms solution – and it still does its business job with
flying colours. Like Forms it is a little old-fashioned. But the reports are
built with embedded PL/SQL – data model queries, formula columns, triggers,
the same packages as the Forms application – so a classic PDF generator
cannot simply take over: every report would have to be rebuilt, with its
logic. Let us hope Oracle is wise enough to keep maintaining it.

How long "deprecated" has lasted so far – in Oracle's own words²:

| Year | Release | What Oracle says |
|---|---|---|
| 2005 | Reports 10g | "Oracle Reports 10g, shipped in 2005 was its last feature bearing release." (looking back, release notes 12.2.1.2) |
| 2015 | FMW 12.2.1 | "Oracle Reports is deprecated. It is included in this 12.2.1 release, but will not be updated in future releases." |
| 2016 | FMW 12.2.1.2 | "Oracle Fusion Middleware's 12c R2 release (12.2.1.3.0) will be Oracle Reports terminal release." |
| 2017 | FMW 12.2.1.3 | the announced terminal release ships |
| 2019 | FMW 12.2.1.4 | ships with Reports again – still deprecated |
| 2023 | Forms & Reports 12.2.1.19 | "Oracle Reports has been deprecated as of Fusion Middleware 12c Release 2 (12.2.1.3.0). No further development of Oracle Reports is planned for the future. If future releases are made available, …" |
| 2024 | Forms & Reports 14.1.2 | "Although included in this release, Oracle Reports has been deprecated. Oracle is not planning any functional enhancements other than critical bug fixes and changes necessary to make it compatible with a new supporting technology stack." |

So the last release with new features is more than twenty years old, the
product has been deprecated since 2015, and after the announced terminal
release 12.2.1.3 three more releases have shipped with it – 12.2.1.4,
12.2.1.19 and 14.1.2. A bit like the Rolling Stones: every tour is
announced as the last one, and the band keeps playing. The customers keep
listening, too.

¹ Detected by web crawling, each vendor with its own method – the counts
differ accordingly and show only what is publicly visible (checked
2026-10-23):
[Landbase](https://data.landbase.com/technology/oracle-forms/),
[6sense](https://6sense.com/tech/database/oracle-forms-market-share),
[iDataLabs](https://www.idatalabs.com/tech/products/oracle-forms).

² Oracle documentation, quotes checked 2026-11-12:
[release notes 12.2.1 – Oracle Reports](https://docs.oracle.com/middleware/1221/formsandreports/releasenotes-fnr/reports.htm),
[release notes 12.2.1.2 – Deprecation Notice for Oracle Reports](https://docs.oracle.com/middleware/12212/formsandreports/releasenotes-fnr/GUID-344F190C-4F51-428E-850E-B3BE8E0706A5.htm),
[release notes 12.2.1.19 – Deprecated and Desupported Features](https://docs.oracle.com/en/middleware/developer-tools/forms/12.2.1.19/releasenotes-fnr/deprecated-and-desupported-features.html),
[release notes 14.1.2 – Deprecated and Desupported Features](https://docs.oracle.com/en/middleware/developer-tools/forms/14.1.2/releasenotes-fnr/deprecated-and-desupported-features.html).
Release years: 12.2.1 October 2015
([oracle-base](https://oracle-base.com/blog/2015/10/24/fusion-middleware-12-2-1-0-released/)),
12.2.1.3 August 2017, 12.2.1.19 February 2023
([Oracle blog, Japanese](https://blogs.oracle.com/oracle4engineer/oracle-forms-and-reports-122119)),
14.1.2 December 2024
([Oracle announcement](https://blogs.oracle.com/fusionmiddlewaresupport/post/announcement-oracle-fmw-forms-and-reports-1412-has-been-released)).

## Target Environment

- Oracle Forms 14c / Reports 12c (technically 14c naming but Reports is still 12c codebase)
- Oracle WebLogic 14c (FMW 14.1.2), Oracle JDK 21
- Oracle Linux 8 / 9, Nginx as the only entry
- Repository database Oracle 19c (local, `60-RCU-DB-19c/`) or 26ai
- Oracle APEX + ORDS beside Forms (`12-APEX-Ords/`)
- Existing 12.2.1.x installations: analysis and manual patch cookbooks with
  standalone tools (`70-Customer-Projects/`)

## Philosophy

- **Read-only by default.** Every script only reads and reports unless `--apply` is passed.
- **No surprises.** Every change is backed up before it is applied.
- **Source is king.** Where possible, behavior is validated against the official Oracle docs.
- **One library, many scripts.** All shared logic lives in [`00-Setup/IHateWeblogic_lib.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/00-Setup/IHateWeblogic_lib.sh).

## License

Copyright 2024 Gunther Pipperr – <https://pipperr.de>

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at:

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
