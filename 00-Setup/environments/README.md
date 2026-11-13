---
title: "environments/ – One Configuration per Oracle Home"
description: "The environments directory of IHateWeblogic: one conf file per FMW domain or Oracle Database home, the active one linked as environment.conf, with templates."
permalink: /00-Setup/environments/
---

# environments/

One `*.conf` file per Oracle environment on this server.
Supports two types — both can coexist in this directory:

| ENV_TYPE | Use case | Key variables |
|---|---|---|
| `FMW` | WebLogic / Forms & Reports domain | `ORACLE_HOME`, `DOMAIN_HOME`, `JDK_HOME` |
| `DB`  | Oracle Database home | `ORACLE_HOME`, `ORACLE_SID`, `ORACLE_BASE` |

---

## File format

Same as the standard `environment.conf`, plus two optional header comments:

```bash
# ENV_TYPE=FMW          # or DB (auto-detected if omitted)
# ENV_LABEL=Production  # human-readable name for the menu
```

Templates:
- [`fmw_prod.conf.template`](https://github.com/gpipperr/IHateWeblogic/blob/main/00-Setup/environments/fmw_prod.conf.template) → copy, rename, adapt for your FMW domain
- [`db_prod.conf.template`](https://github.com/gpipperr/IHateWeblogic/blob/main/00-Setup/environments/db_prod.conf.template)  → copy, rename, adapt for your DB home

---

## Usage

```bash
# List the registered environments (active one = symlink target, marked *):
./00-Setup/detect_env_conf.sh --list

# Point environment.conf to another conf (menu without the number;
# without --apply only a dry-run):
./00-Setup/detect_env_conf.sh --select 2 --apply
```

`--select` changes **only** the symlink `environment.conf` in the project
root – the conf the library scripts read. After selecting a DB conf the FMW
scripts miss `DOMAIN_HOME`; select the FMW conf again.

The **current shell** (`ORACLE_HOME`, `ORACLE_SID`, `DOMAIN_HOME`, `PATH`,
`wlst`) is switched with `setdb` / `setfmw`
([ihw_shell_env.sh](../../70-Customer-Projects/tools/README.md#ihw_shell_envsh),
installed by [`09-Install/03-root_user_oracle.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/09-Install/03-root_user_oracle.sh) as `~/.bashrc.d/ihw_env.sh`).
It detects the homes itself and does not read these conf files. The former
`00-Setup/set_env.sh` (symlink + shell export) was removed on 2026-11-04.

```
IHateWeblogic/
├── environment.conf          → symlink to active conf
└── 00-Setup/
    └── environments/
        ├── fmw_prod.conf     # Forms & Reports production domain
        ├── fmw_test.conf     # Forms & Reports test domain
        └── db_prod.conf      # Oracle DB 19c production
```

---

## .gitignore

The actual `*.conf` files contain server-specific paths and are excluded
from Git, together with their backups (`*.conf.bak*` of [`detect_env_conf.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/00-Setup/detect_env_conf.sh),
`*.conf.pre_deinstall_*` of [`09-Install/99-oracle_deinstall_fmw.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/09-Install/99-oracle_deinstall_fmw.sh)). Only
`*.template` files and this `README.md` are committed.

Typical content on a host (`detect_env_conf.sh --apply` names the file after the
domain, e.g. `fr_domain.conf`): the active conf and dated backups.
`07-Maintenance/bak_cleanup.sh --apply` keeps the newest `BAK_FILES_KEEP` (3)
`*.conf.bak_<ts>` copies per file here as well; `environment.conf.bak_*`
and `*.pre_deinstall_*` (other name patterns) are removed by hand.

Full concept: [../set_environment.md](../set_environment.md); every
parameter: [09-Install/docs/00-environment-setup.md](../../09-Install/docs/00-environment-setup.md).
