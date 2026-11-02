#!/bin/bash
# =============================================================================
# Script   : 02-db_patch_db_software.sh
# Status   : DEPRECATED – functionality merged into 01-db_install_software.sh
#
# 01- installs Oracle 19c directly into the patched ORACLE_HOME (gold image,
# or 19.3 base + RU with opatch) in a single run. A separate patch step for a
# fresh home is no longer needed.
#
# See: 60-RCU-DB-19c/01-db_install_software.sh
#      60-RCU-DB-19c/docs/01-db_install_software.md
# Patching a RUNNING database (next RU): out-of-place with
#      01-db_install_software.sh --target-home <new home> --fresh-patches --apply
#      09-db_patch_rcu.sh --new-home <new home> --apply   (docs/09-db_patch_rcu.md)
# =============================================================================

printf "\033[33mWARN\033[0m  02-db_patch_db_software.sh is DEPRECATED.\n"
printf "       Patching is now integrated into 01-db_install_software.sh.\n"
printf "\n"
printf "       Run instead:\n"
printf "         New install (patched in one run):\n"
printf "           ./60-RCU-DB-19c/01-db_install_software.sh --apply\n"
printf "         Next RU for a running database (out-of-place):\n"
printf "           ./60-RCU-DB-19c/01-db_install_software.sh --target-home <new home> --fresh-patches --apply\n"
printf "           ./60-RCU-DB-19c/09-db_patch_rcu.sh --new-home <new home> --apply\n"
printf "\n"
exit 0
