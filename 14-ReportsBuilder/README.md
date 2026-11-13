---
nav_title: "Reports Builder"
title: "Oracle Reports Builder 14.1.2 – Builder Server and Deployment with GitLab"
description: "Oracle Reports Builder 14.1.2 on a central Windows Server and the report deployment with GitLab: rdf to xml, one report per check-in, push to DEV, tag to PROD."
permalink: /14-ReportsBuilder/
redirect_from:
  - /70-Customer-Projects/Reports14_builder_windows/
---

# 14-ReportsBuilder – Reports Builder and report deployment with GitLab

Two questions every Oracle Reports 14c migration runs into, answered with
a setup that is in production use:

1. **Where do the developers work?** The Reports Builder 14.1.2 needs a
   Fusion Middleware installation – which parts of it, and on which machine?
2. **How do the reports get to the servers?** An `.rdf` is a binary file.
   Who changed what, which version runs on DEV and which in production, and
   how do you go back?

## 1. The idea – one builder-only Windows server

- **One central Windows Server** for the Reports Builder; the developers
  work on it via **RDP**. No Builder on the developer PCs.
- **As little FMW as possible:** Oracle Home plus a builder domain whose
  AdminServer stays stopped – no Reports server, no Windows services, no
  SSL on this machine. Day to day only `rwbuilder.bat` runs.
- **The reports run on Linux:** designed on Windows, executed and tested on
  the existing Linux Reports server (`rwservlet`).

Why exactly this cut (there is no "standalone Reports Builder" as for
Forms – the Reports Tools template needs JRF, EM and RCU), the domain and
the multi-user operation:
[80-FMW-Architecture/reports_rwbuilder.md](../80-FMW-Architecture/reports_rwbuilder.md)
(architecture) and
[ReportsBuilder_install_windows.md](ReportsBuilder_install_windows.md)
(installation, patches, open points).

## 2. The core question – distribute and manage reports with GitLab

| Problem | Answer |
|---|---|
| `.rdf` is binary – a diff shows nothing | on every check-in the report is converted to `.xml` (`rwconverter`) and checked in next to it – GitLab shows *what* changed |
| developers without Git experience | PowerShell scripts and a menu: `pull.ps1` at the start, `checkin.ps1` at the end – no Git commands |
| which version is where? | **one report per check-in**: a check-in *is* a report version |
| DEV | every push to `main` deploys the changed reports to the DEV server automatically |
| production | a **`prod-*` tag** on a check-in deploys **exactly the files of that check-in** – nothing else goes along; `release_tag.ps1` lists what is not released yet |
| going back | a new `prod-*` tag on an older check-in |
| merge conflicts, branches | none: only the branch `main`, no merge requests – a tag selects the version |
| who may release? | creating a `prod-*` tag is the release – the tags are protected in GitLab |
| the servers | an SSH forced command: the runner may only call `rwdeploy.sh` – a queue that checks the delivery, makes a backup, copies and never deletes |
| feedback | pipeline green / red in GitLab, a mail after the production deploy |

![builder-gitlab-flow](diagrams/builder-gitlab-flow.svg?v=0e258161)
<sub>Source: [diagrams/builder-gitlab-flow.prompt](https://github.com/gpipperr/IHateWeblogic/blob/main/14-ReportsBuilder/diagrams/builder-gitlab-flow.prompt) · [D2](https://github.com/gpipperr/IHateWeblogic/blob/main/14-ReportsBuilder/diagrams/builder-gitlab-flow.d2)</sub>

<details markdown="block"><summary>ASCII version</summary>

```ascii?name=builder-gitlab-flow
 Developer (RDP)
       |
       v
 Windows Builder server
   Reports Builder, Git clone per developer
   checkin.ps1:  .rdf -> .xml, one report per check-in
   release_tag.ps1:  tag prod-<date>_<report>
       |  git push (HTTPS)
       v
 GitLab project
   branch main  ---- push ----> job deploy_dev
   tags prod-*  ---- tag  ----> job deploy_prod
       |
       v
 Project runner (Linux VM, shell executor)
   |  ssh, forced command
   +-------------------------> DEV Reports server:  rwdeploy.sh
   |                             backup, copy, log
   +-------------------------> PROD Reports server: rwdeploy.sh
   |                             backup, copy, log
   +--> mail after the PROD deploy
```

</details>

The servers never reach GitLab: the runner fetches its jobs (outbound
HTTPS) and connects to the Reports servers (outbound SSH). No `git fetch`
on a Reports server, no webhook receiver.

## 3. The documents

| Document | Content | For |
|---|---|---|
| [ReportsBuilder_install_windows.md](ReportsBuilder_install_windows.md) | builder-only domain, decisions, multi-user operation (RDP), patch level, open points | administrators |
| [ReportBuilder_Windows_Kochbuch_en.txt](https://github.com/gpipperr/IHateWeblogic/blob/main/14-ReportsBuilder/ReportBuilder_Windows_Kochbuch_en.txt) / [`_de.txt`](https://github.com/gpipperr/IHateWeblogic/blob/main/14-ReportsBuilder/ReportBuilder_Windows_Kochbuch_de.txt) | installation step by step (English / German) | administrators |
| [Git_checkin.md](Git_checkin.md) | design of the check-in: repository layout, rdf → xml, the scripts, tests | Git contact person |
| [Git_deploy.md](Git_deploy.md) | the pipeline (`ci_deploy.sh`), the server queue (`rwdeploy.sh`), GitLab settings, mail, tests | Git contact person, administrators |
| [git_pipeline_kochbuch_de.txt](https://github.com/gpipperr/IHateWeblogic/blob/main/14-ReportsBuilder/git_pipeline_kochbuch_de.txt) | set-up of runner, servers, keys, variables and both pipelines step by step (German) – mechanism first with `ci_deploy_debug.sh` | administrators |
| [scripts/README.md](scripts/README.md) / [scripts/README_DE.md](scripts/README_DE.md) | the daily workflow: menu, pull, check-in, status, release (English / German) | report developers |
| [scripts/](https://github.com/gpipperr/IHateWeblogic/tree/main/14-ReportsBuilder/scripts) | PowerShell scripts (`menu.*`, `pull.ps1`, `checkin.ps1`, `status*.ps1`, `release_tag.ps1`, …) | – |
| [deploy/](https://github.com/gpipperr/IHateWeblogic/tree/main/14-ReportsBuilder/deploy) | `ci_deploy.sh`, `rwdeploy.sh`, GitLab CI templates (also with the mail in the pipeline), `authorized_keys.example` | – |

## 4. Origin and state

Started as a customer project in `70-Customer-Projects/` (builder server
live 2026-10-27, Git check-in 2026-11-12) and moved here on 2026-11-13,
when the GitLab deployment went **live**: own project runner, DEV and PROD
deploys, mail after the PROD deploy, protected tags and variables per
environment. Still open: the Windows test points of the scripts under
Windows PowerShell 5.1 ([Git_checkin.md](Git_checkin.md), section 2.3).
