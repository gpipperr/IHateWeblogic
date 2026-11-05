# customer-analyse – analysis reports of customer configuration exports

**Customer data. Nothing below this directory is committed** except this
README, the generic report templates `fmw_forms_reports_status_template.md` /
`patch_analyse_template.md` and the
generic rule lists in `rules/` (`.gitignore`:
`70-Customer-Projects/tools/customer-analyse/*` with exceptions).

```
customer-analyse/
  README.md                         committed
  fmw_forms_reports_status_template.md        committed – report template (English)
  patch_analyse_template.md         committed – patch analysis template (English)
  rules/security_weights.txt        committed – weight of every security finding (traffic light)
  <YYYY-MM-DD>_<customer>/          one run – git-ignored
    export/                         the unpacked export (may hold clear-text passwords!)
    collect/                        the unpacked collection (collect_fmw_env.sh, masked)
    csv/                            the tables of the reports as ';'-CSV (csv/patch/ = patch analysis)
    fmw_forms_reports_status_<customer>_<date>.md   the configuration report for the customer
    patch_analyse_<customer>_<date>.md    the patch analysis for the customer
```

Flow:

1. At the customer: `tools/bash/export_forms_reports_conf.sh` (encrypted
   archive, or `--masked`).
2. Here: `tools/bash/analyse_forms_reports_export.sh -i <export.zip|.zip.enc|dir> -k <customer>`
   – refuses to run if the output directory is not git-ignored.
3. Hand the Markdown report to the customer ("this is how we build it in 14c").
4. Delete the run directory when the import is finished.

Details: [../README.md](../README.md#analyse_forms_reports_exportsh).

Patch analysis (same run directory):

1. At the customer: `tools/bash/collect_fmw_env.sh` (encrypted `.zip.enc`).
2. Here: `tools/bash/analyse_patch_collect.sh -i <fmw_collect_*.zip.enc|.zip|dir> -k <customer>`
   – compares the patch level with our patch list of the cycle.
3. Hand the report to the customer; patching later with the cookbook of the
   customer folder or – environments built with the library – with
   `07-Maintenance/80-/81-/82-` (section 8 of the report).

Details: [../README.md](../README.md#analyse_patch_collectsh).
