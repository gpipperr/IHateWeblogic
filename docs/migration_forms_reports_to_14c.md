---
title: "Migrate Oracle Forms & Reports 12c to 14c – Process in Three Steps"
description: "Moving Oracle Forms & Reports from 12c to 14c: export and analyse the old environment, rebuild 14c with the customer's configuration, re-analyse and harden security."
---

# Moving from 12c to Forms & Reports 14c

← Back to the [root README](../README.md)

## Moving from 12c to Forms & Reports 14c – the process in three steps

```
 1. extract + analyse          2. build 14c with the customer's     3. analyse again +
    the old environment    ──▶    master data                   ──▶    harden security
```

| # | Step | What happens | Details |
|---|---|---|---|
| 1 | **Extract and analyse the data** | At the customer, from the tools ZIP: `collect_fmw_env.sh` (patch level) and `export_forms_reports_conf.sh` (configuration). On our host: a patch report and a Forms & Reports status report with traffic lights, as PDF for the customer. | [70-Customer-Projects/tools](../70-Customer-Projects/tools/README.md), road map in [70-Customer-Projects](../70-Customer-Projects/README.md#first-steps-at-a-customer--the-road-map) |
| 2 | **Build the new environment with the customer's master data** | `customer_conf_import.sh` turns the export into the conf and an overlay. **Preferred:** import first, then interview and install chain (Way 1). For an environment already built with the library: `apply_customer_conf.sh` (Way 2). | [00-transfer_customer_settings.md](../09-Install/docs/00-transfer_customer_settings.md) |
| 3 | **Analyse again and harden security** | The same tools against the new 14c environment – the same reports, now as before / after for the customer. Then hardening along the findings, and `90-oracle_validate.sh`. | [phase D](../09-Install/docs/00-transfer_customer_settings.md#6-phase-d--analyse-again-and-harden-security-step-3), [80-oracle_security.md](../09-Install/docs/80-oracle_security.md), [81-reports_rwservlet_security.md](../09-Install/docs/81-reports_rwservlet_security.md), [Security & Patch Status](forms_reports_security.md#security--patch-status) |

Collect at the **start** of a project, not when the new host is ready: the
export of the old environment is the master data of the new build.

**Step 2 in order on the new host (Way 1).** The import comes **before** the
interview:

```
 [oracle] git clone <repo> && cd IHateWeblogic
 [oracle] ./00-Setup/customer_conf_import.sh -i <export>.zip.enc --env <env>           # dry run
 [oracle] ./00-Setup/customer_conf_import.sh -i <export>.zip.enc --env <env> --apply   # conf + overlay, links environment.conf
 [oracle] ./09-Install/01-setup-interview.sh --apply      # continues the imported conf: customer values [kept],
                                                          # asks only host values, decisions, passwords
 [root]   phase 0 (00-root_* … 05-root_nginx_ssl.sh), then the install chain 04- … 15-, 30-, 90-
          → 09-Install/README.md "Installation Flow"
```

The overlay holds placeholders, not paths of the new host – `14-` fills them
in later from the complete conf. So the importer needs nothing from the
interview. Details and Way 2:
[00-transfer_customer_settings.md](../09-Install/docs/00-transfer_customer_settings.md#when-does-the-interview-run-no-chicken-and-egg-problem).
