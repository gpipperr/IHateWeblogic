# 80-FMW-Architecture – how Forms/Reports/WebLogic work internally

Background knowledge gained while installing, operating and debugging
FMW 14.1.2 environments. These documents are neither installation steps
(`09-Install/`) nor operating procedures (`01-Run/`, `07-Maintenance/`,
`70-Customer-Projects/`) – they explain **why** something behaves the way it
does, so that the scripts, docs and cookbooks can refer to one place.

Every statement is marked by how it is backed:

| Marker | Meaning |
|---|---|
| **confirmed (code)** | read from the bytecode of the shipped JARs (`javap -c`) |
| **confirmed (live)** | reproduced on the test host or seen at a customer, with date |
| **documented** | Oracle documentation / MOS note, not reproduced |
| **assumption** | plausible, not verified – to be checked |

## Documents

| Document | Topic |
|---|---|
| [reports_server_discovery_multicast.md](reports_server_discovery_multicast.md) | How Reports servers, the rwservlet and the Reports tools find each other (UDP multicast, `rwnetwork.conf`), why a server stops with `REP-50600`/`REP-56040`, active search of the network with `rwdiag`/`DiagServerLocator`, hardening ideas, prerequisites and diagnosis |
| [report_server_image_handling.md](report_server_image_handling.md) | Images in migrated reports: embedded vs. Link File vs. *Read from File*, `REPORTS_PATH` search, no fallback for Windows paths (`REP-108`), `<folderAccess>` – one `<read>`, `;`-separated, last element wins, no subdirectories (`REP-56132`, test series), migration with `rwconverter` |
| [em_principal_search_libovd.md](em_principal_search_libovd.md) | EM "Add Principal" finds no users: the EM search goes through libOVD; the Reports server rewrites the shared libOVD config and leaves `ovd.lok`, an AdminServer started with it has no LDAP adapter – trace, test series, fix in the start scripts |
| [forms_jakob_webutil.md](forms_jakob_webutil.md) | WebUtil and JACOB (Java–COM bridge for OLE/Office automation): architecture, download source and checksums of JACOB 1.21, files and locations, `webutil.cfg` syslib list, signing, state of the test host |

## Candidates for further documents

Findings already collected elsewhere that belong here as a whole:

- Node Manager credentials – two stores (`config.xml` encrypted vs.
  `nm_password.properties` hash), random credentials of WLST-offline domains
  (today in `09-Install/docs/80-oracle_security.md` §5)
- rwservlet web commands – `webcommandaccess`, `<identifier>`,
  `checkDiagnostic` (today in `09-Install/docs/81-reports_rwservlet_security.md`)
- Which configuration file is effective (domain `config/fmwconfig/…` vs. the
  staged `servers/<ms>/tmp/_WL_user/…` copy vs. `$ORACLE_HOME/…/conf` templates)
- WLST credential resolution (`connect()` without arguments → default
  `~/<user>-WebLogicConfig.properties`, `boot.properties` of the target server)
