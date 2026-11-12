# Git deployment – push to `main` → DEV server, `prod-*` tag → production

Follow-up of [Git_checkin.md](Git_checkin.md): the developers check reports
in with `checkin.ps1`. This document describes how they reach the Linux
Reports servers. The Git server is a self-hosted **GitLab**.

- **One branch:** there is only **`main`**. No `development` branch, no
  merge requests, no merge logic.
- **One report per check-in:** `checkin.ps1` commits every selected file
  on its own (a report together with its `.xml`).
- **DEV:** every push to `main` deploys the changed reports to the DEV
  Reports server automatically – normally exactly the checked-in report.
- **Production:** a **`prod-*` tag** on a check-in (set with
  `release_tag.ps1`) starts the pipeline that deploys **exactly the files of
  that check-in** to production. Nothing else goes along.

Decided by the customer on 2026-11-12; it replaces the first design of the
same day (`development` → DEV, single reports via `promote.ps1` and a merge
request to `main`). Built and tested on the Linux test host (sandbox:
PowerShell 7.4, local bare repositories, `ssh` simulated). At the customer,
the GitLab runner, the SSH keys and the protected tags are still **to
confirm** (section 6).

Folder [deploy/](https://github.com/gpipperr/IHateWeblogic/tree/main/70-Customer-Projects/Reports14_builder_windows/deploy)
holds the server and pipeline side. [scripts/release_tag.ps1](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/release_tag.ps1)
is the release script for the developers.

---

## 1. The idea

```
 developer: checkin.ps1 (one check-in per report) --push--> main
                                                              |
                         pipeline deploy_dev (automatic) <----+
                           | files changed since the last DEV deploy
                           v
                         DEV server: rwdeploy.sh --> backup, copy, log, status

 release:   release_tag.ps1
              | shows the check-ins not yet in production (numbered)
              | number --> annotated tag prod-<date>_<report> on that check-in
              | git push origin <tag>
              v
            pipeline deploy_prod (automatic on tag prod-*)
              | exactly the files of the tagged check-in
              v
            PROD server: rwdeploy.sh --> backup, copy, log, status
```

**Why it works without merges:** every report is its own check-in, so a
check-in *is* a report version. A tag points at one check-in, and the
production job takes only the files that this check-in changed, in the state
of this check-in. Other reports on `main` – newer or older, released or not
– are not touched.

**Rules:**
- Check in one report per check-in (`checkin.ps1` does that on its own,
  also with selection `a`).
- Production only through a `prod-*` tag – never copy by hand.
- Creating a `prod-*` tag is the release: protect the tags in GitLab
  (section 6).

Network: only **GitLab → server** (SSH). The servers never reach GitLab, so
there is no `git fetch` on the servers and no inbound HTTP service such as
a webhook receiver.

## 2. Files

| File | Where it goes | Purpose |
|---|---|---|
| [template.gitlab-ci.yml](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/deploy/template.gitlab-ci.yml) | `.gitlab-ci.yml` in the top folder of the repository | job `deploy_dev` (push to `main`) and `deploy_prod` (tag `prod-*`), `GIT_DEPTH: 0`, `resource_group` per environment |
| [ci_deploy.sh](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/deploy/ci_deploy.sh) | `Reports/deploy/ci_deploy.sh` in the repository | the job (section 4) |
| [rwdeploy.sh](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/deploy/rwdeploy.sh) | Reports server, e.g. `/u01/app/oracle/rwdeploy/bin/` | queue + worker, SSH forced command (section 5) |
| [rwdeploy.conf.template](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/deploy/rwdeploy.conf.template) | `rwdeploy.conf` next to `rwdeploy.sh` | spool folder, target folders, size limit |
| [authorized_keys.example](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/deploy/authorized_keys.example) | `~oracle/.ssh/authorized_keys` on the server | the deploy key may only start `rwdeploy.sh`, only from the runner |
| [release_tag.ps1](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/release_tag.ps1) | `Reports\release_tag.ps1` next to `checkin.ps1` | release of one check-in (section 3) |

## 3. Release of one report – `release_tag.ps1`

```powershell
cd E:\git\<login>
.\Reports\release_tag.ps1                  # show, then choose a number (Enter = nothing)
.\Reports\release_tag.ps1 -File umsatz     # only files with 'umsatz' in the name
```

1. `git fetch origin --tags` – the developer's files stay unchanged.
2. **Not yet in production:** the check-ins on `origin/main` without an own
   `prod-*` tag whose files have no **newer** tagged check-in – numbered,
   with their files and a summary per file. A tag on a newer version of a
   report makes the older check-ins of that report obsolete.
3. **Last releases:** the last 20 `prod-*` tags with date, tagger, check-in
   and the files of that check-in (= what went to production).
4. **Release:** the developer enters a number. The script
   - warns if there is a **newer** check-in of the same file (production
     would get the older state) and if the check-in holds several files;
   - asks for the file for the tag name (only if there are several) and the
     tag message;
   - sets an annotated tag `prod-<yyyy-MM-dd_HHmm>_<file>` (umlauts written
     as `ue`, `oe`, …; `-2`, `-3` if the name exists) and pushes it with
     `git push origin <tag>` – this starts `deploy_prod`.

Default filter `-Filter '*.rdf'` (`-like` on the whole path); `-Filter ''`
shows all files, `-Filter '*.png'` only images. `-File <text>` = part of the
file name, case-insensitive. Further: `-Nummer`, `-Ja` (no questions),
`-TagDatei`, `-Nachricht`, `-NoPush`, `-NoFetch`, `-Branch`, `-TagPrefix`,
`-Anzahl`.

**Rollback:** run the pipeline of an older `prod-*` tag of the report again
(GitLab → Build → Pipelines → retry), or set a new tag on the older
check-in. The replaced file is also in `spool/backup/<job>/` on the server.

## 4. The pipeline – `ci_deploy.sh`

| | `deploy_dev` | `deploy_prod` |
|---|---|---|
| rule | `$CI_COMMIT_BRANCH == "main" && $CI_PIPELINE_SOURCE == "push"` | `$CI_COMMIT_TAG =~ /^prod-/` |
| start | automatically on every push | automatically when a `prod-*` tag is pushed |
| content | the files changed between the last successful DEV deploy and this commit (`git diff --diff-filter=AMR <last> <sha>`) – normally the checked-in report; one push with several check-ins brings all of them | exactly the files of the tagged commit (`git diff-tree -r --root --diff-filter=AMR <sha>`) |
| older pipeline after a newer deploy | "already part of the last deploy – nothing to do" | deploys its own check-in again (= rollback when started on purpose) |
| stops | – | tag on a merge commit; tagged commit without `.rdf` / image |
| serialised by | `resource_group: deploy-dev` | `resource_group: deploy-prod` |

DEV takes the last deployed commit from the server itself (`rwdeploy.sh
last`):
- A failed or skipped DEV pipeline loses nothing: the next one brings every
  change since the last successful deploy.
- An older pipeline after a newer deploy is recognised with `git merge-base
  --is-ancestor` and does nothing.
- First deploy (server answers `none`): the files of this push
  (`CI_COMMIT_BEFORE_SHA..CI_COMMIT_SHA`), or only the files of the commit.
- If the last deployed commit is not an ancestor (`main` rewritten), the job
  warns and deploys only the files of this commit.

`.xml` files are not deployed. They exist for the review in Git; the server
needs only the `.rdf` files and the images. Deleted files are never removed
from a server.

The job sends `git archive <sha> -- <files>` as a tar over SSH
(`enqueue <sha> delta|tag`). It then waits with `status <sha> --wait 300`,
so **the pipeline shows green or red for the deploy itself**, with the
server's log in the job output.

CI variables (Settings → CI/CD → Variables). Set them **protected**, and
**per environment** (scope `development` / `production`):

| Variable | Content |
|---|---|
| `DEPLOY_HOST` | server name |
| `DEPLOY_USER` | SSH user (default `oracle`) |
| `DEPLOY_SSH_KEY` | private key, variable type **File** – one key per environment |
| `DEPLOY_KNOWN_HOSTS` | output of `ssh-keyscan <server>`; the job uses `StrictHostKeyChecking=yes` with only this host key |
| `DEPLOY_WAIT` | optional, seconds to wait for the result (default 300) |

Runner: a runner with the tag `reports-deploy` that has bash, git and ssh,
and may reach the servers on port 22. A shell runner on the GitLab side is
enough; there is no runner on the Reports servers.

## 5. The server side – `rwdeploy.sh`

| Command (from `SSH_ORIGINAL_COMMAND`) | Effect |
|---|---|
| `enqueue <sha> delta\|tag\|snapshot` | tar from stdin, at most `MAX_TAR_MB`, written to `spool/incoming/<timestamp>-<sha>.tar` + `.meta` (renamed atomically), then starts the worker in the background |
| `status <sha> [--wait N]` | log of the newest job for the commit; exit 0 = done, 1 = failed, 2 = still pending |
| `last` | commit of the last successful job (`state/last_sha`) or `none` |
| `list` | the last 15 jobs with their state |
| `work` | the worker – also from cron as a safety net |

`delta` = DEV, `tag` = PROD. `snapshot` (the whole `Reports/source` +
`Reports/images`, with a warning for `.rdf` files that are no longer in Git)
is still accepted but no longer sent by `ci_deploy.sh`.

The worker:
- runs once at a time (`flock`) and takes the jobs oldest first;
- checks **every tar member before extracting**:
  - only plain files and folders are allowed, no links;
  - only the names `Reports/source/<name>.rdf` and `Reports/images/<name>`;
  - no `..`, no absolute paths;
- extracts into `staging/`;
- copies only changed files (`cmp`), each first to a temporary name and then
  renamed, so the Reports server never reads half a file;
- saves every replaced file under `backup/<job>/`;
- **never deletes**.

Each job leaves a log in `log/<job>.log` and a result in `done/` or
`failed/`. On a failure nothing more is copied.

Set-up on each server (DEV and PROD), as `oracle`:

```bash
mkdir -p /u01/app/oracle/rwdeploy/bin
cp rwdeploy.sh /u01/app/oracle/rwdeploy/bin/
chmod 750 /u01/app/oracle/rwdeploy/bin/rwdeploy.sh

cp rwdeploy.conf.template /u01/app/oracle/rwdeploy/bin/rwdeploy.conf
vi /u01/app/oracle/rwdeploy/bin/rwdeploy.conf
#   SPOOL_DIR, TARGET_SOURCE_DIR, TARGET_IMAGE_DIR
#   the targets must be in REPORTS_PATH and in <folderAccess><read>

# deploy key: one key pair per server, the private key goes to GitLab (scope development / production)
ssh-keygen -t ed25519 -N '' -C gitlab-deploy-dev -f ./gitlab-deploy-dev

# one line in ~/.ssh/authorized_keys (authorized_keys.example):
#   command="/u01/app/oracle/rwdeploy/bin/rwdeploy.sh",restrict,from="<runner-ip>" ssh-ed25519 AAAA... gitlab-deploy-dev

# safety net: worker every 5 minutes (normally enqueue starts it at once)
crontab -e
#   */5 * * * * /u01/app/oracle/rwdeploy/bin/rwdeploy.sh work

# test from the runner host:
ssh -i gitlab-deploy-dev oracle@<server> list
ssh -i gitlab-deploy-dev oracle@<server> 'id'    # -> ERROR: unknown command 'id'
```

**First set-up:**
- `main` holds today's reports (one import), together with `.gitlab-ci.yml`
  and `Reports/deploy/ci_deploy.sh`.
- PROD needs no starting point: each tag brings its own files.
- DEV: optional, write the commit of the imported state once as the last
  deploy, so the first DEV pipeline sends only what changed after the
  import:

```bash
git rev-parse origin/main                # on a clone: the commit of the imported state
mkdir -p /u01/app/oracle/rwdeploy/state                            # on the DEV server
printf '%s\n' '<commit>' > /u01/app/oracle/rwdeploy/state/last_sha
```

## 6. GitLab settings (customer – to confirm)

- **`main` protected:** push for Developers (they check in directly), no
  force push.
- **Tags `prod-*` protected** (Settings → Repository → Protected tags):
  allowed to create = Maintainers, or the persons who may release. Creating
  the tag is the release; protected CI variables are also available to
  protected tags.
- CI variables per environment scope (`development` / `production`), so the
  DEV job never sees the PROD key.
- Settings → CI/CD → General pipelines: **"Prevent outdated deployment
  jobs"** for DEV, as a second line next to the ancestor check in
  `ci_deploy.sh`. It also blocks retrying an older PROD pipeline – for a
  rollback set a new tag on the older check-in instead.
- The old branch `development` is already deleted at the customer.

## 7. When something goes wrong

| Message | Meaning | What to do |
|---|---|---|
| `release_tag.ps1`: "ACHTUNG: Von … gibt es einen neueren Check-in" | the chosen check-in is not the newest version of the report | answer `n` and choose the newer number – unless the older version is wanted on purpose (rollback) |
| `release_tag.ps1`: "Der Check-in hat N Dateien" | an old check-in with several reports | all of them go to production – fine if wanted, otherwise do not tag it |
| job: `the tag is on a merge commit` | the tag points at a merge of `checkin.ps1` (colleague checked in at the same moment) | delete the tag (`git push origin :refs/tags/<tag>`, `git tag -d <tag>`) and tag the check-in of the report with `release_tag.ps1` |
| job: `the tagged commit holds no report (.rdf) or image` | the tag is on a check-in without report or image | delete the tag, tag the right check-in |
| job: `last deploy … is not an ancestor` (warning, DEV) | `main` history was changed (force push) | only the files of this commit were deployed; check DEV, set `last_sha` |
| job red, `ERROR: path not allowed` | a file outside `Reports/source/*.rdf` / `Reports/images/` was sent | nothing was copied; check the repository content |
| job: `PENDING` after the wait | worker busy or not running | `ssh … list` on the runner host; cron safety net present? |
| wrong report in production | – | rollback (section 3); the replaced file is in `spool/backup/<job>/` on the server |

## 8. Tests (Linux test host, 2026-11-12)

| Test | Result |
|---|---|
| `checkin.ps1` selection `a` with 2 reports | 2 check-ins `Erste Version (lager.rdf)` / `(umsatz.rdf)`, each with its `.xml` |
| `checkin_only.ps1` selection `a` | one check-in per file, file name in the comment |
| DEV, first push with 2 check-ins, server `none` | both reports deployed (`CI_COMMIT_BEFORE_SHA..sha`) |
| DEV, next push with `umsatz` v2 | only `umsatz.rdf` copied |
| DEV, older pipeline afterwards | "already part of the last deploy", file stays at v2 |
| `release_tag.ps1` before any tag | 4 open check-ins incl. both versions of `umsatz`; tag on `lager` pushed |
| PROD tag `lager` | only `lager.rdf` deployed – the newer `umsatz` stays out |
| `release_tag.ps1` on the older `umsatz` check-in | "ACHTUNG … neuerer Check-in [1]", `n` = nothing tagged |
| PROD tag on `umsatz` v2 (`-Nummer 1 -Ja`) | `umsatz.rdf` v2 deployed; afterwards both `umsatz` check-ins no longer open, both tags listed with their files |
| PROD tag on a doc-only check-in / on a merge commit | job stops with the message, nothing copied |
| `rwdeploy.sh` from the first design: tar with `../`, absolute path, symlink, other folder, `.sh` in `source`, garbage, > `MAX_TAR_MB`; 5 concurrent jobs; commands `rm -rf /`, `last; id`, `list $(id)` | rejected / worked off one after the other – unchanged code paths |

Open at the customer: real GitLab (tag rule, protected tags, protected and
scoped variables), SSH from the runner, the scripts on Windows PowerShell
5.1.
