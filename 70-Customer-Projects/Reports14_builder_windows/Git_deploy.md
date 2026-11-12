# Git deployment – `development` → DEV server, one released report → `main` → production

Follow-up of [Git_checkin.md](Git_checkin.md): the developers check reports
in to the branch **`development`** with `checkin.ps1`. This document
describes how they reach the Linux Reports servers. The Git server is a
self-hosted **GitLab**.

- **DEV:** Every push to `development` deploys **all** reports to the DEV
  Reports server automatically.
- **Production:** Only **one released report** goes to `main`, through a
  merge request with approval. A **manual** pipeline job then deploys only
  the reports released since the last production deploy.

Status 2026-11-12: built and tested on the Linux test host (sandbox:
PowerShell 7.4, local bare repositories, `ssh` simulated). At the customer,
the GitLab runner, the SSH keys and the rules are still **to confirm**
(section 6).

Folder [deploy/](https://github.com/gpipperr/IHateWeblogic/tree/main/70-Customer-Projects/Reports14_builder_windows/deploy)
holds the server and pipeline side. [scripts/promote.ps1](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/promote.ps1)
is the release script for the developers.

---

## 1. The idea

```
 developer: checkin.ps1 --push--> development --pipeline (automatic)--> DEV server
                                                                         (all reports, snapshot)
 release:   promote.ps1 umsatz
              | temporary worktree on origin/main (working copy untouched)
              | git checkout origin/development -- umsatz.rdf umsatz.xml [+ images]
              | push release/umsatz-<date>  -o merge_request.create -o merge_request.target=main
              v
 GitLab:    merge request "Release umsatz: <reason>" --maintainer approves + merges--> main
              v
            pipeline on main: job deploy_prod (manual, environment production)
              | "Play" --> only the files changed since the last PROD deploy
              v
            PROD server: rwdeploy.sh --> backup, copy, log, status
```

**Rule: `development` is never merged into `main`.** `main` receives reports
only one by one, via `promote.ps1` and a merge request. `main` therefore
holds exactly what is released, and the production server gets only what
`main` holds.

Network: only **GitLab → server** (SSH). The servers never reach GitLab, so
there is no `git fetch` on the servers and no inbound HTTP service such as
a webhook receiver.

## 2. Files

| File | Where it goes | Purpose |
|---|---|---|
| [template.gitlab-ci.yml](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/deploy/template.gitlab-ci.yml) | `.gitlab-ci.yml` in the top folder of the repository, on **both** branches | job `deploy_dev` (development, automatic) and `deploy_prod` (main, manual), `GIT_DEPTH: 0`, `resource_group` per environment |
| [ci_deploy.sh](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/deploy/ci_deploy.sh) | `Reports/deploy/ci_deploy.sh` in the repository, on both branches | the job (section 4) |
| [rwdeploy.sh](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/deploy/rwdeploy.sh) | Reports server, e.g. `/u01/app/oracle/rwdeploy/bin/` | queue + worker, SSH forced command (section 5) |
| [rwdeploy.conf.template](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/deploy/rwdeploy.conf.template) | `rwdeploy.conf` next to `rwdeploy.sh` | spool folder, target folders, size limit |
| [authorized_keys.example](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/deploy/authorized_keys.example) | `~oracle/.ssh/authorized_keys` on the server | the deploy key may only start `rwdeploy.sh`, only from the runner |
| [promote.ps1](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/promote.ps1) | `Reports\promote.ps1` next to `checkin.ps1` | release of one report (section 3) |

## 3. Release of one report – `promote.ps1`

```powershell
cd E:\git\<login>
.\Reports\promote.ps1 umsatz
```

The script runs these steps:

1. `git fetch` – the developer's files stay unchanged.
2. Checks. On any of them the script stops with a German message and
   releases nothing.
   - `origin/development:Reports/source/<name>.rdf` and the `.xml` exist
     (`git cat-file -e`).
   - The report differs from `origin/main`. Otherwise: "ist in main schon
     genau so" (exit 0).
   - The report is not changed locally and not checked in without being
     sent. The release takes the **server state** of `development`, so a
     local edit would silently be missing from it.
3. Images that are new or changed in `development` compared with `main` are
   listed. The developer picks numbers separated by commas, `a` for all, or
   Enter for none.
4. The script shows the files and the report's check-ins since `main`
   (`git log origin/main..origin/development -- <rdf>`) and asks for the
   **reason**. An empty reason cancels.
5. `git worktree add --detach <temp> origin/main`: a second working folder
   on the state of `main`. The developer's working copy and branch are
   **not** touched, so open Builder work stays where it is. Inside it:
   - `git checkout origin/development -- <rdf> <xml> <images>`
   - `git commit -m "Release <name>: <reason>"`
   - `git push -o merge_request.create -o merge_request.target=main`, plus
     `-o merge_request.title=…` and `-o merge_request.remove_source_branch`,
     to `release/<name>-<yyyyMMdd-HHmm>`. Umlauts in the branch name are
     written as `ue`, `oe`, …
6. `git worktree remove --force` and `git worktree prune` always run, also
   after an error. GitLab's `remote:` lines carry the link to the merge
   request, and the script shows them.

Push options are standard GitLab behaviour: no API token is needed. The
login is the same as for `checkin.ps1` (Git Credential Manager).

## 4. The pipeline – `ci_deploy.sh`

| | `deploy_dev` | `deploy_prod` |
|---|---|---|
| rule | `$CI_COMMIT_BRANCH == "development" && $CI_PIPELINE_SOURCE == "push"` | `$CI_COMMIT_BRANCH == "main" && $CI_PIPELINE_SOURCE == "push"`, `when: manual` |
| start | automatically on every push | button **"Play"** in GitLab (Pipelines / Environments → production) |
| content | **snapshot**: every `Reports/source/*.rdf` and `Reports/images/*` of the commit | **delta**: the files changed between the last successful PROD deploy and this commit (`git diff --diff-filter=AMR`) |
| older pipeline after a newer deploy | "already part of the last deploy – nothing to do" | same |
| serialised by | `resource_group: deploy-dev` | `resource_group: deploy-prod` |

The last deployed commit comes from the server itself (`rwdeploy.sh last`).

- If a "Play" is skipped, nothing is lost: the next PROD job brings every
  release since the last deploy.
- An older pipeline that is played after a newer one is recognised with
  `git merge-base --is-ancestor` and does nothing.
- If the last deployed commit is **not** an ancestor (because `main` was
  rewritten), the job stops.

`.xml` files are not deployed. They exist for the review in Git; the server
needs only the `.rdf` files and the images. Deleted files are never removed
from a server.

The job sends `git archive <sha> -- <files>` as a tar over SSH
(`enqueue <sha> snapshot|delta`). It then waits with `status <sha> --wait
300`, so **the pipeline shows green or red for the deploy itself**, with the
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
| `enqueue <sha> snapshot\|delta` | tar from stdin, at most `MAX_TAR_MB`, written to `spool/incoming/<timestamp>-<sha>.tar` + `.meta` (renamed atomically), then starts the worker in the background |
| `status <sha> [--wait N]` | log of the newest job for the commit; exit 0 = done, 1 = failed, 2 = still pending |
| `last` | commit of the last successful job (`state/last_sha`) or `none` |
| `list` | the last 15 jobs with their state |
| `work` | the worker – also from cron as a safety net |

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
- **never deletes**. A snapshot job warns about `.rdf` files on the server
  that are no longer in Git.

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

# deploy key: one key pair per server, the private key goes to GitLab (DEV_ / PROD_)
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

**First set-up PROD:**
- `main` holds today's production reports (one import), together with
  `.gitlab-ci.yml` and `Reports/deploy/ci_deploy.sh`.
- The commit of that state is written **once by hand** as the last deploy:

```bash
git rev-parse origin/main                # on a clone: the commit of the imported state
mkdir -p /u01/app/oracle/rwdeploy/state                            # on the PROD server
printf '%s\n' '<commit>' > /u01/app/oracle/rwdeploy/state/last_sha
```

Without it the PROD job stops with "the server has no last deploy".

## 6. GitLab settings (customer – to confirm)

- **`main` protected:** allowed to push = No one, allowed to merge =
  Maintainers. Nobody pushes directly; `main` changes only through a merge
  request.
- **Approvals:** In editions with merge request approval rules, require at
  least one approval and prevent approval by the author. In the Free
  edition, "only maintainers may merge" is the approval.
- **`development` protected:** push and merge for Developers. Protected CI
  variables are only visible on protected branches.
- Settings → CI/CD → General pipelines: **"Prevent outdated deployment
  jobs"** as a second line next to the ancestor check in `ci_deploy.sh`.
- `release/*` branches start no pipeline: no rule matches.

## 7. When something goes wrong

| Message | Meaning | What to do |
|---|---|---|
| `promote.ps1`: "ist bei Ihnen geaendert und noch nicht eingecheckt" | the release takes the server state | `checkin.ps1` first, then `promote.ps1` again |
| `promote.ps1`: "ein anderer Stand als auf dem Git-Server" | local check-in not sent, or a colleague's check-in not fetched | `status.ps1` shows which one; `checkin.ps1` (`n` = only send) or `pull.ps1` |
| job: `ERROR: the server has no last deploy` | PROD first set-up missing | section 5, first set-up PROD |
| job: `not an ancestor ... main rewritten?` | `main` history was changed (force push) | set `last_sha` on the server to the commit really deployed – check with the logs in `spool/log/` |
| job red, `ERROR: path not allowed` | a file outside `Reports/source/*.rdf` / `Reports/images/` was sent | nothing was copied; check the repository content |
| job: `PENDING` after the wait | worker busy or not running | `ssh … list` on the runner host; cron safety net present? |
| wrong report in production | – | the replaced file is in `spool/backup/<job>/` on the server; a correct release through `promote.ps1` is the clean way |

## 8. Tests (Linux test host, 2026-11-12)

| Test | Result |
|---|---|
| DEV snapshot, first run | 2 reports + 1 image copied, job DONE, pipeline exit 0 |
| same commit again | "unchanged 3", exit 0 – idempotent |
| report changed + a report only on the server | 1 copied, backup of the old file, "WARNING not in git (kept)" |
| DEV: newest deploy first, then an older pipeline | "already part of the last deploy", file stays at the newest state |
| 5 jobs queued at the same moment | worked off one after the other (`flock`), nothing left in `incoming/` / `work/` |
| PROD without `last_sha` | stops with the first-set-up message |
| PROD: two releases merged, only the newest pipeline played | both released files deployed, the **not released** report never reaches PROD |
| PROD: older pipeline played afterwards / newest again | "already part of the last deploy" / "already deployed", exit 0 |
| tar with `../`, absolute path, symlink, other folder, `.sh` in `source`, garbage, > `MAX_TAR_MB` | job FAILED or rejected, nothing copied |
| commands `rm -rf /`, `last; id`, `list $(id)`, invalid sha / kind / wait | rejected (no shell, words not expanded) |
| `promote.ps1` umsatz + 1 of 3 images | release branch holds exactly `umsatz.rdf`, `umsatz.xml`, `logo.png`; push options arrived (pre-receive hook); working copy stays on `development` with an open change to another report; worktree removed |
| `promote.ps1`: missing report, local change, unsent check-in, empty reason, invalid image number, already same in main | clear message, nothing released |
| `promote.ps1`: push rejected | message, worktree removed, nothing released |
| report `Übersicht` | branch `release/Uebersicht-<date>`, title with the umlaut |

Open at the customer: real GitLab (push options create the MR, rules, the
manual job, protected variables), SSH from the runner, `promote.ps1` on
Windows PowerShell 5.1 (`git worktree` in `%TEMP%`).
