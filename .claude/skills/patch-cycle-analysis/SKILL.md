---
name: patch-cycle-analysis
description: Run the IHateWeblogic Oracle patch-cycle analysis (CPU / CSPU / Security Alert) for Forms & Reports 14.1.2 or a customer home – phase "prepare" reads the public Oracle advisories and writes the list of patch READMEs to download, phase "analyse" reads the collected READMEs and the environment and writes the analysis README, the manual guide and (maintainer mode) update_plan.md. Use when the user starts 10-Monitoring/patch_cycle_analysis.sh or asks for a patch-cycle analysis.
---

# Patch-cycle analysis

The full procedure is in `10-Monitoring/patch_cycle_analysis_skill.md` – read
it completely first and follow it exactly.

Arguments (from `10-Monitoring/patch_cycle_analysis.sh` or typed by the user):

- `prepare <Patch-Doku dir>` – phase 1 (section 2 of the skill document)
- `analyse <Patch-Doku dir> mode=customer|maintainer` – phase 2 (section 3);
  maintainer mode also writes `update_plan.md` (section 5)

The Patch-Doku directory contains `cycle.info` (cycle id, advisory URL,
release date, configured cycle, mode). If no directory is given, ask for it or
point to `10-Monitoring/patch_cycle_analysis.sh` (status shows the cycles).

Answer the user in German (project rule), write repo documents in English,
customer cookbooks in German ASCII. Never commit without asking.
