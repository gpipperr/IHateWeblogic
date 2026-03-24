#!/bin/bash
# =============================================================================
# Script   : 02-db_patch_db_software.sh
# Status   : DEPRECATED – functionality merged into 01-db_install_software.sh
#
# As of the -applyRU approach, Oracle 19c is installed directly to the patched
# ORACLE_HOME (19.30.0) in a single step.  A separate patch step is no longer
# needed.
#
# See: 60-RCU-DB-19c/01-db_install_software.sh
#      60-RCU-DB-19c/docs/01-db_install_software.md
# =============================================================================

printf "\033[33mWARN\033[0m  02-db_patch_db_software.sh is DEPRECATED.\n"
printf "       Patching is now integrated into 01-db_install_software.sh.\n"
printf "\n"
printf "       Run instead:\n"
printf "         ./60-RCU-DB-19c/01-db_install_software.sh --apply\n"
printf "\n"
exit 0
