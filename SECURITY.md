# Security Policy

## Reporting a vulnerability

Please report security problems **privately** – not as a public issue:

1. **GitHub private vulnerability reporting** (preferred): tab *Security* →
   *Report a vulnerability* in this repository.
2. **E-mail:** info@pipperr.de

Contact: Gunther Pipperr – https://pipperr.de

Please include the script / file, the commit or date of your checkout, what
an attacker can do and how to reproduce it. Do **not** attach `*.des3`
files, `environment.conf`, logs or collector archives – they contain host
names, IP addresses and encrypted credentials of a real system.

This is a private project maintained alongside customer work: reports are
handled on a best-effort basis, without guaranteed response times. Fixes go
into `main`; there are no releases and no backports.

## Supported versions

Only the current state of the `main` branch is supported.

## Scope

In scope: the scripts, templates and documentation of this repository.

Not in scope – please report these elsewhere:

- Vulnerabilities in Oracle products (WebLogic Server, Forms, Reports, Oracle
  JDK, Oracle Database, ORDS, APEX, OPatch) – report them to Oracle
  (https://www.oracle.com/corporate/security-practices/assurance/vulnerability/reporting.html).
  Their patch status is tracked in
  [09-Install/docs/00-patch-references.md](09-Install/docs/00-patch-references.md).
- Third-party tools used by the scripts (getMOSPatch, JACOB, Nginx, OS
  packages) – report them to their maintainers.
- Anything that requires being the OS user `oracle` or `root` on the host
  already – see the next section.

## Password encryption is obfuscation, not protection

The `*.des3` files (`weblogic_sec.conf.des3`, `db_sys_sec.conf.des3`,
`mos_sec.conf.des3`, … – list in
[00-Setup/README.md](00-Setup/README.md#credential-scripts-weblogic_secsh--database_rcu_secsh--mos_secsh))
are encrypted with `openssl des3 -pbkdf2` using a key **derived from the
machine itself** (disk UUID, fallback `/etc/machine-id`).

That is the key under the doormat:

- **What it does:** no password lies around in plain text – not in Git, not
  in a diff, a pull request, a backup or a copied file. A `*.des3` file
  copied to another host cannot be decrypted there.
- **What it does not do:** protect against anyone who can read files on the
  host as `oracle` or `root`. They can run the same scripts and decrypt every
  password. At the end of the day the passwords are readable on the machine.

The real security boundary is the host: who may log in (SSH), who may become
`oracle` or `root` (sudo policy), file permissions (`*.des3` are written
mode 600), and keeping the repository and its backups on trusted systems.
WebLogic itself stores its credentials the same way (`boot.properties`
encrypted with the domain's `SerializedSystemIni.dat`).

## Using the scripts safely

- Every script is **read-only by default**; changes need `--apply`. Read
  what a script does before you run it with `--apply`, especially the
  `*root*` scripts.
- Run the library as the software owner `oracle`, root only where a script
  says so.
- Never commit `environment.conf`, `*.des3`, `log/` or
  `07-Maintenance/ConfigBackup/` – they are listed in `.gitignore` for that
  reason.
- Hardening applied by the installation (loopback-only WebLogic, Nginx as the
  only entry, header stripping, firewall, sshd) and what to do after the
  installation: [09-Install/docs/80-oracle_security.md](09-Install/docs/80-oracle_security.md).
