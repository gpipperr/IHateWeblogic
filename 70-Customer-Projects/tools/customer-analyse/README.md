# customer-analyse – analysis reports of customer configuration exports

**Customer data. Nothing below this directory is committed** except this
README, the generic report template `import_analyse_template.md` and the
generic rule lists in `rules/` (`.gitignore`:
`70-Customer-Projects/tools/customer-analyse/*` with exceptions).

```
customer-analyse/
  README.md                         committed
  import_analyse_template.md        committed – report template (English)
  <YYYY-MM-DD>_<customer>/          one run – git-ignored
    export/                         the unpacked export (may hold clear-text passwords!)
    csv/                            the tables of the report as ';'-CSV
    import_analyse_<customer>_<date>.md   the report for the customer
```

Flow:

1. At the customer: `tools/bash/export_forms_reports_conf.sh` (encrypted
   archive, or `--masked`).
2. Here: `tools/bash/analyse_forms_reports_export.sh -i <export.zip|.zip.enc|dir> -k <customer>`
   – refuses to run if the output directory is not git-ignored.
3. Hand the Markdown report to the customer ("this is how we build it in 14c").
4. Delete the run directory when the import is finished.

Details: [../README.md](../README.md#analyse_forms_reports_exportsh).
