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
- `fmw_prod.conf.template` → copy, rename, adapt for your FMW domain
- `db_prod.conf.template`  → copy, rename, adapt for your DB home

---

## Usage

```bash
# Interactive menu – source to set variables in the current shell:
. ./00-Setup/set_env.sh

# Direct select without menu (e.g. in .bash_profile):
. ./00-Setup/set_env.sh 1

# List only (no env change):
./00-Setup/set_env.sh --list
```

---

## How it works

`set_env.sh` updates the symlink in the project root and, when sourced,
exports the appropriate variables + adjusts `PATH`:

**FMW:** `ORACLE_HOME`, `DOMAIN_HOME`, `JDK_HOME`
→ PATH gets `$ORACLE_HOME/bin`, `$ORACLE_HOME/oracle_common/common/bin`, `$JDK_HOME/bin`

**DB:**  `ORACLE_HOME`, `ORACLE_SID`, `ORACLE_BASE`, `NLS_LANG`
→ PATH gets `$ORACLE_HOME/bin`

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

## .bash_profile integration

Add to `~/.bash_profile` of the `oracle` user:

```bash
IHW_ROOT="/path/to/IHateWeblogic"

if [ -d "$IHW_ROOT/00-Setup/environments" ]; then
    _conf_count=$(find "$IHW_ROOT/00-Setup/environments" -maxdepth 1 \
        -name "*.conf" ! -name "*.template" 2>/dev/null | wc -l)
    if [ "$_conf_count" -gt 1 ]; then
        # Multiple environments → show selection menu
        . "$IHW_ROOT/00-Setup/set_env.sh"
    elif [ -f "$IHW_ROOT/environment.conf" ]; then
        # Single environment → load directly
        source "$IHW_ROOT/environment.conf"
        export ORACLE_HOME DOMAIN_HOME JDK_HOME ORACLE_SID
        [ -n "${ORACLE_HOME:-}" ] && export PATH="$ORACLE_HOME/bin:$PATH"
        [ -n "${JDK_HOME:-}"    ] && export PATH="$JDK_HOME/bin:$PATH"
    fi
    unset _conf_count
fi
unset IHW_ROOT
```

---

## .gitignore

The actual `*.conf` files contain server-specific paths and are excluded
from Git. Only `*.template` files and this `README.md` are committed.
