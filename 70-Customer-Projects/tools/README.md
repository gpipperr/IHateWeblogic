# tools – metadata collection on a Forms & Reports host

Shared, standalone helpers for the patch analyses in `70-Customer-Projects/`
– **no** IHateWeblogic library, plain bash + coreutils, copy them to the host
and run them there. One script for all releases: it works for FMW / Forms &
Reports **12.2.1.x** (12.2.1.19 on WLS 12.2.1.4, JDK 8) and **14.1.2** (JDK
17 / 21) – tested on both (2026-10-23). Release differences are detected at
runtime, never by a second copy of the script.

Used by:
- [Forms12_reports12_patch_analyse_10_2026](../Forms12_reports12_patch_analyse_10_2026/README.md)
- [Forms14_reports14_patch_analyse_10_2026](../Forms14_reports14_patch_analyse_10_2026/README.md)

## collect_fmw_env.sh

Collects the metadata of an Oracle Forms & Reports / FMW host – OS, Java,
Oracle Home / inventory / patches, domain configuration, processes, Oracle
Net, logs – into one directory plus a `.tar.gz` for the analysis.

```bash
# as the software owner of the Oracle Home (oracle), not root
cp collect_fmw_env.sh /tmp/ && cd /tmp && chmod +x collect_fmw_env.sh
./collect_fmw_env.sh                    # auto-detect ORACLE_HOME / DOMAIN_HOME
./collect_fmw_env.sh -o /oracle/product/mw -d /oracle/user_projects/domains/fr_domain
./collect_fmw_env.sh --full             # + opatch lsinventory -details / -bugs_fixed
./collect_fmw_env.sh --logs             # + error lines of the server logs (last 200)
```

| Option | Meaning |
|---|---|
| `-o DIR` | Oracle Home (default: `$ORACLE_HOME`, then `/oracle/product/mw`, `/u01/app/oracle/fmw`, …) |
| `-d DIR` | domain home (default: `$DOMAIN_HOME`, `$ORACLE_HOME/domain-registry.xml`, the running AdminServer) |
| `-t DIR` | base directory of the output (default `/tmp`) |
| `--full` | large inventory output – for bug / CVE questions (`-bugs_fixed`) |
| `--logs` | error / FRM- / REP- / ORA- lines of the server logs |

Check the version first: `./collect_fmw_env.sh -V` (also the first line of
`00_summary.txt`) – it must match the version in the repository.

Result: `/tmp/fmw_collect_<host>_<timestamp>/` and `….tar.gz` (about 100 KB
without `--full`); `00_summary.txt` holds the key facts, every other file one
area (`10_os`, `20_java`, `30_inventory`, `31_opatch`, `40_config.xml`,
`41_domain_scripts`, `42_forms_reports_config`, `43_ohs_config`, `50_processes`, `60_net`, `61_webserver`,
`70_logs`). Runtime on the test host: about 30 s.

**Read-only:** writes only into the output directory (OPatch writes its usual
logs to `$ORACLE_HOME/cfgtoollogs` while it reads the inventory). Every
command runs under `timeout 600`.

**Secrets:** password elements, `{AES}` values, `userid=` / `authid=` /
`password=` values, `user/password@` connect strings and `-D…password=`
arguments are replaced by `***MASKED***` before anything is written.
Host names, IP addresses and paths stay in the output – they are needed for
the analysis. Check the files before sending; never commit the output to a
repository.
