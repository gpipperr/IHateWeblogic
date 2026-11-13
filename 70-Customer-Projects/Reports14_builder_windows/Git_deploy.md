# Git deployment – push to `main` → DEV server, `prod-*` tag → production

Follow-up of [Git_checkin.md](Git_checkin.md): the developers check reports
in with [`checkin.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/checkin.ps1). This document describes how they reach the Linux
Reports servers. The Git server is a self-hosted **GitLab**.

- **One branch:** there is only **`main`**. No `development` branch, no
  merge requests, no merge logic.
- **One report per check-in:** `checkin.ps1` commits every selected file
  on its own (a report together with its `.xml`).
- **DEV:** every push to `main` deploys the changed reports to the DEV
  Reports server automatically – normally exactly the checked-in report.
- **Production:** a **`prod-*` tag** on a check-in (set with
  [`release_tag.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/release_tag.ps1)) starts the pipeline that deploys **exactly the files of
  that check-in** to production. Nothing else goes along.

Decided by the customer on 2026-11-12; it replaces the first design of the
same day (`development` → DEV, single reports via `promote.ps1` and a merge
request to `main`). Built and tested on the Linux test host (sandbox:
PowerShell 7.4, local bare repositories, `ssh` simulated).

Status at the customer: **live since 2026-11-13.** Own project runner
`report-deploy` (after a runner update, see section 4 "Runner version");
push → `deploy_dev` → report on the DEV server, `prod-*` tag →
`deploy_prod` → report on the PROD server, the mail after the PROD deploy,
protected `prod-*` tags and the variables per environment – all confirmed,
the files arrive correctly.

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
- Check in one report per check-in ([`checkin.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/checkin.ps1) does that on its own,
  also with selection `a`).
- Production only through a `prod-*` tag – never copy by hand.
- Creating a `prod-*` tag is the release: protect the tags in GitLab
  (section 6).

Network: the **project runner** (own Linux VM, section 4) fetches its jobs
from GitLab (outbound HTTPS) and connects to the Reports servers (outbound
SSH, port 22). The servers never reach GitLab, so there is no `git fetch` on
the servers and no inbound HTTP service such as a webhook receiver.

Step-by-step set-up of both pipelines for the administrators (German,
cookbook style): [git_pipeline_kochbuch_de.txt](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/git_pipeline_kochbuch_de.txt).

## 2. Files

Repository layout (the customer's, adopted 2026-11-12): top folder with
[`menu.cmd`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/menu.cmd) / [`menu.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/menu.ps1) / [`menu.ini`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/menu.ini), `.gitlab-ci.yml`, `README.md`; folders
`deploy/` (all scripts incl. [`ci_deploy.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/deploy/ci_deploy.sh)), `source/` (`.rdf`), `xml/`
(`.xml`, only for review), `images/`. Deployed are only `source/*.rdf` and
`images/*` – the tar keeps these repository paths, [`rwdeploy.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/deploy/rwdeploy.sh) accepts
nothing else.

| File | Where it goes | Purpose |
|---|---|---|
| [template.gitlab-ci.yml](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/deploy/template.gitlab-ci.yml) | `.gitlab-ci.yml` in the top folder of the repository | job `deploy_dev` (push to `main`) and `deploy_prod` (tag `prod-*`), `GIT_DEPTH: 0`, `resource_group` per environment |
| [template_mail_in_pipe.gitlab-ci.yml](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/deploy/template_mail_in_pipe.gitlab-ci.yml) | instead of `template.gitlab-ci.yml` as `.gitlab-ci.yml` (alternative) | the same two jobs, plus a result mail after **every** deploy (DEV and PROD) to the user who started the pipeline, sent with `curl` from the `after_script` – the customer's solution (section 4, "Mail – two ways") |
| [ci_deploy.sh](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/deploy/ci_deploy.sh) | [`deploy/ci_deploy.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/deploy/ci_deploy.sh) in the repository | the job (section 4) |
| [ci_notify_mail.sh](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/deploy/ci_notify_mail.sh) | `deploy/ci_notify_mail.sh` in the repository | mail after the PROD deploy (jobs `notify_prod_ok` / `notify_prod_failed`, section 4) |
| [ci_deploy_debug.sh](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/deploy/ci_deploy_debug.sh) | `deploy/ci_deploy_debug.sh` in the repository (only for tests) | no logic: writes the call (`$0`, `$1`), the GitLab predefined variables and the `DEPLOY_*` variables as `NAME = value` to `/tmp/report_pip.txt` and into the job log – `DEPLOY_SSH_KEY` only as path. In `.gitlab-ci.yml` before the real call: `- bash deploy/ci_deploy_debug.sh dev` |
| [rwdeploy.sh](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/deploy/rwdeploy.sh) | Reports server, e.g. `/u01/app/oracle/rwdeploy/bin/` | queue + worker, SSH forced command (section 5) |
| [rwdeploy.conf.template](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/deploy/rwdeploy.conf.template) | `rwdeploy.conf` next to [`rwdeploy.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/deploy/rwdeploy.sh) | spool folder, target folders, size limit |
| [authorized_keys.example](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/deploy/authorized_keys.example) | `~oracle/.ssh/authorized_keys` on the server | the deploy key may only start [`rwdeploy.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/deploy/rwdeploy.sh), only from the runner |
| [release_tag.ps1](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/release_tag.ps1) | `deploy\release_tag.ps1` next to [`checkin.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/checkin.ps1) | release of one check-in (section 3); the customer uses an own variant of it – the pipeline only needs the `prod-*` tag |

## 3. Release of one report – `release_tag.ps1`

```powershell
cd E:\git\<login>\oracle-report
.\deploy\release_tag.ps1                  # show, then choose a number (Enter = nothing)
.\deploy\release_tag.ps1 -List            # only show (parts 1 and 2) - no question, no tag
.\deploy\release_tag.ps1 -File umsatz     # only files with 'umsatz' in the name
```

1. `git fetch origin --tags` – the developer's files stay unchanged.
2. **Not yet in production:** what is in production for a file is the
   check-in of the **most recently created** `prod-*` tag of that file (a
   later tag on an older version = rollback). Listed are the check-ins on
   `origin/main` that are newer than that – numbered, with their files and a
   summary per file.
3. **Last check-ins:** the last 20 check-ins sorted by date (`git log
   --date-order`, newest first), one row per file with the tag of **its own**
   check-in, or `NO_TAG`. Then the **last 20 releases** sorted by the tag
   date (newest first): tag, check-in, tagger and **only the files of the
   tagged check-in** – not the files between two tags.
4. **Release:** the developer enters a number from part 2 – or a **commit
   id** (e.g. from part 3, also an older check-in; `-Commit <id>`). The tag
   points at exactly this one check-in; newer check-ins are **not** pulled
   in. The script
   - checks a commit id: exists, on `origin/main`, not a merge commit;
   - warns with the list of **newer** check-ins of the same file (they do not
     go along – production gets the older state, i.e. a rollback) and if the
     check-in holds several files;
   - asks for the file for the tag name (only if there are several) and the
     tag message;
   - sets an annotated tag `prod-<yyyy-MM-dd_HHmm>_<file>` (umlauts written
     as `ue`, `oe`, …; `-2`, `-3` if the name exists) and pushes it with
     `git push origin <tag>` – this starts `deploy_prod`.

   Git reference: [`git tag -a`](https://git-scm.com/docs/git-tag) (annotated
   tag on a given commit), [`git for-each-ref --sort=creatordate`](https://git-scm.com/docs/git-for-each-ref)
   (which tag was created last), [`git push origin <tag>`](https://git-scm.com/docs/git-push).

Default filter `-Filter '*.rdf'` (`-like` on the whole path); `-Filter ''`
shows all files, `-Filter '*.png'` only images. `-File <text>` = part of the
file name, case-insensitive. Further: `-Nummer`, `-Ja` (no questions),
`-TagDatei`, `-Nachricht`, `-NoPush`, `-NoFetch`, `-Branch`, `-TagPrefix`,
`-Anzahl`.

**Rollback:** set a new tag on the older check-in ([`release_tag.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/release_tag.ps1), enter
its commit id from the list of the last check-ins, or `-Commit <id>`). The
newer check-ins of the report then count as open again. The replaced file is also in `spool/backup/<job>/` on the server.

## 4. The pipeline – `ci_deploy.sh`

| | `deploy_dev` | `deploy_prod` |
|---|---|---|
| rule | `$CI_COMMIT_BRANCH == "main" && $CI_PIPELINE_SOURCE == "push"` | `$CI_COMMIT_TAG =~ /^prod-/` |
| start | automatically on every push | automatically when a `prod-*` tag is pushed |
| content | the files changed between the last successful DEV deploy and this commit (`git diff --diff-filter=AMR <last> <sha>`) – normally the checked-in report; one push with several check-ins brings all of them | exactly the files of the tagged commit (`git diff-tree -r --root --diff-filter=AMR <sha>`) |
| older pipeline after a newer deploy | "already part of the last deploy – nothing to do" | deploys its own check-in again (= rollback when started on purpose) |
| stops | – | tag on a merge commit; tagged commit without `.rdf` / image |
| serialised by | `resource_group: deploy-dev` | `resource_group: deploy-prod` |
| mail | – | stage `notify` after `deploy_prod`: `notify_prod_ok` (`when: on_success`) or `notify_prod_failed` (`when: on_failure`) – exactly one mail per release |

GitLab reference: job rules [`rules:if`](https://docs.gitlab.com/ci/yaml/#rules) with the
[predefined variables](https://docs.gitlab.com/ci/variables/predefined_variables/)
`CI_COMMIT_BRANCH`, `CI_PIPELINE_SOURCE`, `CI_COMMIT_TAG`, `CI_COMMIT_SHA`,
`CI_COMMIT_BEFORE_SHA`; [`environment`](https://docs.gitlab.com/ci/yaml/#environment)
([environments](https://docs.gitlab.com/ci/environments/)); one deployment at a time with
[`resource_group`](https://docs.gitlab.com/ci/yaml/#resource_group)
([resource groups](https://docs.gitlab.com/ci/resource_groups/)); [`interruptible`](https://docs.gitlab.com/ci/yaml/#interruptible);
full history for the delta with `GIT_DEPTH: "0"`
([shallow cloning](https://docs.gitlab.com/ci/runners/configure_runners/#shallow-cloning)).

**Test the mechanism first** ([`ci_deploy_debug.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/deploy/ci_deploy_debug.sh),
cookbook step 4b). Before the servers, the keys and the variables are set
up, the pipeline runs once with only the debug script in both jobs
(`- bash deploy/ci_deploy_debug.sh dev` / `prod`): it has no logic, opens no
connection and writes what the job receives – the argument, the GitLab
variables, the `DEPLOY_*` values – into the job log and
`/tmp/report_pip.txt` on the runner host. A push must show `dev`,
`CI_COMMIT_BRANCH=main`, `CI_ENVIRONMENT_NAME=development`; a test tag
`prod-test-debug` must show `prod`, `CI_COMMIT_TAG`, `production`. Only
when that works is the rest configured; after the variables are set
(cookbook 5.3) a retry of the debug job shows that each scope delivers the
right server. Requirement: `main` and `prod-*` are protected – the project
runner is protected and does not take jobs of unprotected refs.

**Where each value is set – and where it is used:**

| Value | Set in | Used by |
|---|---|---|
| `dev` / `prod` (`$1`) | `.gitlab-ci.yml`, line `script:` of the job | `ci_deploy.sh` (which path: delta or tag) |
| `CI_COMMIT_SHA`, `CI_COMMIT_TAG`, `CI_COMMIT_BEFORE_SHA`, `CI_PIPELINE_SOURCE`, `CI_COMMIT_BRANCH` | GitLab, automatically per pipeline | the job rules in `.gitlab-ci.yml`, `ci_deploy.sh` |
| `CI_COMMIT_TAG_MESSAGE`, `GITLAB_USER_NAME` / `_EMAIL`, `CI_PIPELINE_URL`, `CI_JOB_URL` | GitLab, automatically | `ci_notify_mail.sh` |
| `CI_ENVIRONMENT_NAME` (`development` / `production`) | `.gitlab-ci.yml`, `environment:` of the job | GitLab: chooses which scoped variables the job gets |
| `DEPLOY_HOST`, `DEPLOY_USER`, `DEPLOY_SSH_KEY`, `DEPLOY_KNOWN_HOSTS`, `DEPLOY_WAIT` | GitLab Settings → CI/CD → Variables, scope `development` / `production`, protected | `ci_deploy.sh` (ssh target, key, host key, wait) |
| `MAIL_TO`, `MAIL_FROM` | the same, scope `production` | `ci_notify_mail.sh` |
| runner tag `reports-deploy` | `.gitlab-ci.yml` `tags:` + the project runner (cookbook 4.4) | GitLab: which runner takes the job |
| `rwdeploy.sh` as the program behind the key | `authorized_keys` on the server, `command="…"` | `sshd` – starts it for every login with the key, the request in `SSH_ORIGINAL_COMMAND` |
| target folders, spool | `rwdeploy.conf` next to `rwdeploy.sh` (or `RWDEPLOY_CONF`) | `rwdeploy.sh` |
| last DEV deploy | `state/last_sha` on the DEV server (written by `rwdeploy.sh`) | `ci_deploy.sh dev` via `rwdeploy.sh last` |

**Mail after the PROD deploy** ([`ci_notify_mail.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/deploy/ci_notify_mail.sh)):
only tag pipelines `prod-*`, no mail for DEV. Subject `[PROD] <report>.rdf
deployed - <tag>` (or `FAILED`), body with released by (`GITLAB_USER_NAME` /
`GITLAB_USER_EMAIL`), tag message (`CI_COMMIT_TAG_MESSAGE`), files of the
check-in and links (`CI_PIPELINE_URL`, `CI_JOB_URL`). Recipients in the CI
variable `MAIL_TO` (scope `production`), sender `MAIL_FROM` (optional). The
script hands the mail to the local `sendmail` of the runner host – Postfix
with a `relayhost` to the company mail server over TLS (demo: `[mxmail01.pipperr.local]:587`,
STARTTLS, `smtp_tls_security_level = encrypt`; cookbook step 9). The jobs
have `allow_failure: true` – a mail problem shows orange, the release stays
green; `MAIL_DRYRUN=1` prints the mail instead of sending it
([`when`](https://docs.gitlab.com/ci/yaml/#when), [`needs`](https://docs.gitlab.com/ci/yaml/#needs),
[`allow_failure`](https://docs.gitlab.com/ci/yaml/#allow_failure),
[`environment:action`](https://docs.gitlab.com/ci/yaml/#environmentaction)). Alternative without
code: GitLab [pipeline status emails](https://docs.gitlab.com/user/project/integrations/pipeline_status_emails/) –
but for every pipeline (also DEV) and with a generic text.

**Mail – two ways.** The customer uses a second solution:
[`template_mail_in_pipe.gitlab-ci.yml`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/deploy/template_mail_in_pipe.gitlab-ci.yml) – the mail is written in the
`after_script` of every deploy job and sent with `curl` straight to the SMTP
server; the job output is captured with
`set -o pipefail; bash deploy/ci_deploy.sh … 2>&1 | tee deploy.log` and goes
into the mail.

| | `ci_notify_mail.sh` (stage `notify`) | `template_mail_in_pipe.gitlab-ci.yml` (`after_script`) |
|---|---|---|
| when | only PROD (`prod-*` tag) | every deploy, DEV and PROD |
| to | `MAIL_TO` (fixed list, scope `production`) | `GITLAB_USER_EMAIL` – the user who pushed / tagged |
| content | tag, report files, released by, tag message, links | BESTANDEN / NICHT BESTANDEN, environment, commit, the **full output** of `ci_deploy.sh` |
| sent via | local `sendmail` (Postfix relay on the runner host, cookbook step 9) | `curl` to `SMTP_HOST:SMTP_PORT` (465 = implicit TLS, else STARTTLS; TLS required) – no MTA on the runner host |
| variables | `MAIL_TO`, `MAIL_FROM` | `SMTP_HOST`, `SMTP_PORT`, `SMTP_USER` / `SMTP_PASS` (optional, masked), `SMTP_MAIL_FROM`, `SMTP_MAIL_FROM_NAME`, `SMTP_TLS_INSECURE` (optional) – values e.g. from the SMTP settings in `/etc/gitlab/gitlab.rb` |

Both keep the release result: a mail problem never turns the deploy red
(`allow_failure` / `after_script`). In the template, compared with the
customer's first version: the SMTP password reaches `curl` as a config on
stdin (`-K -`), never on the command line; the server certificate is
verified unless `SMTP_TLS_INSECURE=1` is set on purpose (better: the CA of
the mail server on the runner host). Tested with a fake `curl` (mail text,
colour codes removed, password not in the arguments, `"` / `\` in the
password escaped); the customer runs it live
([`after_script`](https://docs.gitlab.com/ci/yaml/#after_script),
[`CI_JOB_STATUS`](https://docs.gitlab.com/ci/variables/predefined_variables/),
[curl SMTP](https://everything.curl.dev/usingcurl/smtp.html)).

DEV takes the last deployed commit from the server itself (`rwdeploy.sh
last`):
- A failed or skipped DEV pipeline loses nothing: the next one brings every
  change since the last successful deploy.
- An older pipeline after a newer deploy is recognised with [`git merge-base
  --is-ancestor`](https://git-scm.com/docs/git-merge-base) and does nothing.
- First deploy (server answers `none`): the files of this push
  (`CI_COMMIT_BEFORE_SHA..CI_COMMIT_SHA`), or only the files of the commit.
- If the last deployed commit is not an ancestor (`main` rewritten), the job
  warns and deploys only the files of this commit.

`.xml` files are not deployed. They exist for the review in Git; the server
needs only the `.rdf` files and the images. Deleted files are never removed
from a server.

The job sends [`git archive <sha> -- <files>`](https://git-scm.com/docs/git-archive) as a tar over SSH
(`enqueue <sha> delta|tag`; file list from [`git diff`](https://git-scm.com/docs/git-diff) /
[`git diff-tree`](https://git-scm.com/docs/git-diff-tree) with `--diff-filter=AMR`). It then waits with `status <sha> --wait 300`,
so **the pipeline shows green or red for the deploy itself**, with the
server's log in the job output.

CI variables (Settings → CI/CD → Variables). Set them **protected**, and
**per environment** (scope `development` / `production`) – GitLab:
[protect a variable](https://docs.gitlab.com/ci/variables/#protect-a-cicd-variable),
[environment scope](https://docs.gitlab.com/ci/variables/#environment-scope),
[file type variable](https://docs.gitlab.com/ci/variables/#use-file-type-cicd-variables),
[SSH keys in CI/CD jobs](https://docs.gitlab.com/ci/jobs/ssh_keys/):

| Variable | Content |
|---|---|
| `DEPLOY_HOST` | server name |
| `DEPLOY_USER` | SSH user (default `oracle`) |
| `DEPLOY_SSH_KEY` | private key, variable type **File** – one key per environment |
| `DEPLOY_KNOWN_HOSTS` | output of [`ssh-keyscan <server>`](https://man.openbsd.org/ssh-keyscan); the job uses [`StrictHostKeyChecking=yes`](https://man.openbsd.org/ssh_config#StrictHostKeyChecking) with only this host key ([`UserKnownHostsFile`](https://man.openbsd.org/ssh_config#UserKnownHostsFile), [`BatchMode`](https://man.openbsd.org/ssh_config#BatchMode); GitLab: [verifying the SSH host keys](https://docs.gitlab.com/ci/jobs/ssh_keys/#verifying-the-ssh-host-keys)) |
| `DEPLOY_WAIT` | optional, seconds to wait for the result (default 300) |

**Runner – an own project runner** (cookbook step 4). The jobs need a
runner with the tag `reports-deploy` ([`tags`](https://docs.gitlab.com/ci/yaml/#tags)); the
customer's GitLab had none for this project, so we created one (live
2026-11-13, name `report-deploy`):

| Step | Where | What |
|---|---|---|
| runner host | own Linux VM (not a Reports server) | outbound HTTPS to GitLab (the runner polls for jobs – nothing inbound), outbound port 22 to DEV and PROD; its IP goes into `from=` of `authorized_keys` |
| install | runner host, root | package `gitlab-runner` from packages.gitlab.com ([install](https://docs.gitlab.com/runner/install/linux-repository/)); creates the user `gitlab-runner` and the service |
| create | GitLab: project → Settings → CI/CD → Runners → **New project runner** | tag `reports-deploy`, "Run untagged jobs" off, **Protected** on (only jobs of protected branches / tags = `main`, `prod-*` – matches the protected variables); GitLab shows a token `glrt-…` ([project runners](https://docs.gitlab.com/ci/runners/runners_scope/#create-a-project-runner-with-a-runner-authentication-token)) |
| register | runner host, root | `gitlab-runner register --non-interactive --url <gitlab> --token <glrt-…> --executor shell` – token read with `read -s`, kept in `/etc/gitlab-runner/config.toml` (600) ([registering runners](https://docs.gitlab.com/runner/register/), [shell executor](https://docs.gitlab.com/runner/executors/shell/)) |
| restrict | GitLab | not enabled for other projects ([prevent enabling for other projects](https://docs.gitlab.com/ci/runners/runners_scope/#prevent-a-project-runner-from-being-enabled-for-other-projects)) |
| check | runner host + GitLab | `gitlab-runner list`, `gitlab-runner verify` (`is alive` for every runner); runner green in the project; bash, git, ssh and port 22 checked **as user `gitlab-runner`** (the shell executor runs the jobs as this user) |

There is no runner on the Reports servers. The token is a secret like a
password. Menu names and the output of `register` follow the GitLab
documentation; the steps were run at the customer on 2026-11-13.

**Runner version (customer, 2026-11-13).** The runner's `major.minor`
must match the GitLab version ("the GitLab Runner major.minor version
should stay in sync with the GitLab major and minor version", GitLab Runner
docs). At the customer an outdated runner took no jobs. Solved in this
order: check `gitlab-runner --version` → add the GitLab Runner repository →
`dnf upgrade gitlab-runner` → reboot → **delete the old runner in GitLab**
(it was still shown with the old version after the reboot – that is the old
registration, not the service) → create the runner again and register it
with a **new name** (the interactive `register` proposes the name of the
existing runner – do not take it; the customer used `report-deploy`) →
test commit → the job ran. Cookbook step 4.3 "Runner zu alt".

**A runner already exists?**
- `gitlab-runner register` does **not** overwrite anything: it appends one
  more `[[runners]]` block to `config.toml`; one `gitlab-runner` service
  serves any number of runners and re-reads `config.toml` every 3 seconds
  ([advanced configuration](https://docs.gitlab.com/runner/configuration/advanced-configuration/)) –
  **no restart** after `register`; a `systemctl restart gitlab-runner` would
  abort the running jobs of all runners of the host. The cookbook backs up `config.toml` and
  compares `gitlab-runner list` before / after (exactly one new line).
- **Stale entries first:** before registering, `gitlab-runner verify` must
  show `is alive` for every runner. An entry whose runner was already
  deleted in GitLab (`is removed`, 403) keeps polling and fills the log with
  errors that would hide the messages of the new runner – back up
  `config.toml`, then [`gitlab-runner verify --delete`](https://docs.gitlab.com/runner/commands/#gitlab-runner-verify)
  (removes only such entries; cannot be undone; count the `[[runners]]`
  blocks before / after; restore from the backup if a wrong one went;
  cookbook step 4.3 "Altlasten bereinigen"). A clean `journalctl -u gitlab-runner` is the
  baseline.
- A runner with the tag `reports-deploy` that is online for the project is
  enough – a second one with the same tag would take jobs as well. Only the
  deploy runner carries this tag.
- On a host that already runs runners of other projects: `concurrent` in
  `config.toml` (default 1) counts for **all** runners of the host – the
  deploy job waits behind their jobs.
- **Security:** with the shell executor all jobs of all runners of a host
  run as the same user `gitlab-runner`. During our job the private deploy
  key (`DEPLOY_SSH_KEY`, file variable) lies in the build folder, readable
  for a parallel job of another project. For the PROD key: an **own host**
  for the deploy runner; at least no project there whose pipeline any
  developer can change.


## 5. The server side – `rwdeploy.sh`

`rwdeploy.sh` is the **forced command** of the deploy key: OpenSSH runs it
for every login with this key and passes the requested command in
`SSH_ORIGINAL_COMMAND` – [`sshd(8)` AUTHORIZED_KEYS FILE FORMAT](https://man.openbsd.org/sshd#AUTHORIZED_KEYS_FILE_FORMAT):
[`command=`](https://man.openbsd.org/sshd#command=_command_),
[`restrict`](https://man.openbsd.org/sshd#restrict),
[`from=`](https://man.openbsd.org/sshd#from=_pattern-list_).

| Command (from `SSH_ORIGINAL_COMMAND`) | Effect |
|---|---|
| `enqueue <sha> delta\|tag\|snapshot` | tar from stdin, at most `MAX_TAR_MB`, written to `spool/incoming/<timestamp>-<sha>.tar` + `.meta` (renamed atomically), then starts the worker in the background |
| `status <sha> [--wait N]` | log of the newest job for the commit; exit 0 = done, 1 = failed, 2 = still pending |
| `last` | commit of the last successful job (`state/last_sha`) or `none` |
| `list` | the last 15 jobs with their state |
| `work` | the worker – also from cron as a safety net |

`delta` = DEV, `tag` = PROD. `snapshot` (the whole `source` +
`images`, with a warning for `.rdf` files that are no longer in Git)
is still accepted but no longer sent by [`ci_deploy.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/deploy/ci_deploy.sh).

The worker:
- runs once at a time ([`flock`](https://man7.org/linux/man-pages/man1/flock.1.html)) and takes the jobs oldest first;
- checks **every tar member before extracting**:
  - only plain files and folders are allowed, no links;
  - only the names `source/<name>.rdf` and `images/<name>`;
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
#   the targets must be in REPORTS_PATH and in <folderAccess><read> (Oracle: links below)

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

Oracle Reports: the target folders must be in
[`REPORTS_PATH`](https://docs.oracle.com/middleware/12213/formsandreports/use-reports/pbr_rfap001.htm#i648209) (Publishing Reports 12.2.1.3,
B.1.61 – where the Reports server looks for reports and images) and in
[`<folderAccess>`](https://docs.oracle.com/middleware/12213/formsandreports/use-reports/pbr_conf002.htm#CHDJEGID) of `rwserver.conf` (7.2.1.21 –
the folders the server may read; one `<read>` element, folders separated
by `;`). Reports 14.1.2 refers to the 12.2.1.3 documentation for Reports.
SSH key: [`ssh-keygen`](https://man.openbsd.org/ssh-keygen).

**First set-up:**
- `main` holds today's reports (one import), together with `.gitlab-ci.yml`,
  `deploy/ci_deploy.sh` and `deploy/ci_notify_mail.sh`.
- PROD needs no starting point: each tag brings its own files.
- DEV: optional, write the commit of the imported state once as the last
  deploy, so the first DEV pipeline sends only what changed after the
  import:

```bash
git rev-parse origin/main                # on a clone: the commit of the imported state
mkdir -p /u01/app/oracle/rwdeploy/state                            # on the DEV server
printf '%s\n' '<commit>' > /u01/app/oracle/rwdeploy/state/last_sha
```

## 6. GitLab settings (live at the customer since 2026-11-13)

- **`main` protected** ([protected branches](https://docs.gitlab.com/user/project/repository/branches/protected/)):
  push for Developers (they check in directly), no force push.
- **Tags `prod-*` protected** ([protected tags](https://docs.gitlab.com/user/project/protected_tags/); Settings → Repository → Protected tags):
  allowed to create = Maintainers, or the persons who may release. Creating
  the tag is the release; protected CI variables are also available to
  protected tags.
- CI variables per [environment scope](https://docs.gitlab.com/ci/variables/#environment-scope) (`development` / `production`), so the
  DEV job never sees the PROD key.
- Settings → CI/CD → General pipelines: **["Prevent outdated deployment
  jobs"](https://docs.gitlab.com/ci/environments/deployment_safety/#prevent-outdated-deployment-jobs)** for DEV, as a second line next to the ancestor check in
  [`ci_deploy.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/deploy/ci_deploy.sh). It also blocks retrying an older PROD pipeline – for a
  rollback set a new tag on the older check-in instead.
- The old branch `development` is already deleted at the customer.

## 7. When something goes wrong

| Message | Meaning | What to do |
|---|---|---|
| [`release_tag.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/release_tag.ps1): "ACHTUNG: Es gibt N neuere(n) Check-in(s) dieser Datei(en)" | the chosen check-in is not the newest version of the report; the newer ones do not go along | answer `n` and choose the newer one – unless the older version is wanted on purpose (rollback) |
| [`release_tag.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/release_tag.ps1): "Der Check-in hat N Dateien" | an old check-in with several reports | all of them go to production – fine if wanted, otherwise do not tag it |
| job: `the tag is on a merge commit` | the tag points at a merge of [`checkin.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/checkin.ps1) (colleague checked in at the same moment) | delete the tag (`git push origin :refs/tags/<tag>`, `git tag -d <tag>`) and tag the check-in of the report with [`release_tag.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/release_tag.ps1) |
| job: `the tagged commit holds no report (.rdf) or image` | the tag is on a check-in without report or image | delete the tag, tag the right check-in |
| job: `last deploy … is not an ancestor` (warning, DEV) | `main` history was changed (force push) | only the files of this commit were deployed; check DEV, set `last_sha` |
| job red, `ERROR: path not allowed` | a file outside `source/*.rdf` / `images/` was sent | nothing was copied; check the repository content |
| job: `PENDING` after the wait | worker busy or not running | `ssh … list` on the runner host; cron safety net present? |
| wrong report in production | – | rollback (section 3); the replaced file is in `spool/backup/<job>/` on the server |

## 8. Tests (Linux test host 2026-11-12/13, customer 2026-11-13)

| Test | Result |
|---|---|
| [`checkin.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/checkin.ps1) selection `a` with 2 reports | 2 check-ins `Erste Version (lager.rdf)` / `(umsatz.rdf)`, each with its `.xml` |
| [`checkin_only.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/checkin_only.ps1) selection `a` | one check-in per file, file name in the comment |
| DEV, first push with 2 check-ins, server `none` | both reports deployed (`CI_COMMIT_BEFORE_SHA..sha`) |
| DEV, next push with `umsatz` v2 | only `umsatz.rdf` copied |
| DEV, older pipeline afterwards | "already part of the last deploy", file stays at v2 |
| [`release_tag.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/release_tag.ps1) before any tag | 4 open check-ins incl. both versions of `umsatz`; tag on `lager` pushed |
| PROD tag `lager` | only `lager.rdf` deployed – the newer `umsatz` stays out |
| [`release_tag.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/release_tag.ps1) on the older `umsatz` check-in | "ACHTUNG … neuere(n) Check-in(s)" with the list, `n` = nothing tagged |
| rollback: commit id of `umsatz` v1 entered (`-Commit 52819c1`) | tag on exactly that check-in; PROD job copies only `umsatz.rdf` v1, v2 does not go along; afterwards v2 open again; invalid id / merge commit / not on main: message, exit 1 |
| PROD tag on `umsatz` v2 (`-Nummer 1 -Ja`) | `umsatz.rdf` v2 deployed; afterwards both `umsatz` check-ins no longer open, both tags listed with their files |
| PROD tag on a doc-only check-in / on a merge commit | job stops with the message, nothing copied |
| **customer, 2026-11-13** | project runner created and registered (after `gitlab-runner` update, old runner deleted, new name `report-deploy`), test commit → pipeline ran |
| **customer, 2026-11-13 – live** | DEV: push → `deploy_dev` → report on the DEV server; PROD: `prod-*` tag → `deploy_prod` → report on the PROD server; mail after the PROD deploy arrived; protected `prod-*` tags and scoped variables in place – files transferred correctly |
| [`ci_notify_mail.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/deploy/ci_notify_mail.sh) (2026-11-13, `MAIL_DRYRUN=1`) | `ok`: subject `[PROD] umsatz.rdf deployed - prod-…`, body with tag, commit, released by, tag message, files; `failed`: `[PROD] FAILED: …`; no `MAIL_TO` / wrong argument: message, exit 1; real sending via Postfix not tested (no relay on the test host) |
| [`rwdeploy.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/deploy/rwdeploy.sh) from the first design: tar with `../`, absolute path, symlink, other folder, `.sh` in `source`, garbage, > `MAX_TAR_MB`; 5 concurrent jobs; commands `rm -rf /`, `last; id`, `list $(id)` | rejected / worked off one after the other – unchanged code paths |

Open at the customer: nothing for the pipeline – in operation since
2026-11-13. Still open on Windows: the points of
[Git_checkin.md 2.3](Git_checkin.md#23-open-on-windows).

## 9. References

Checked 2026-11-13 (all addresses HTTP 200, anchors present).

| Topic | Original documentation |
|---|---|
| job rules, variables | GitLab [CI/CD YAML syntax – `rules`](https://docs.gitlab.com/ci/yaml/#rules), [predefined CI/CD variables](https://docs.gitlab.com/ci/variables/predefined_variables/) |
| one deploy at a time | GitLab [`resource_group`](https://docs.gitlab.com/ci/yaml/#resource_group), [resource groups](https://docs.gitlab.com/ci/resource_groups/) |
| environments, outdated jobs | GitLab [environments](https://docs.gitlab.com/ci/environments/), [deployment safety – prevent outdated deployment jobs](https://docs.gitlab.com/ci/environments/deployment_safety/#prevent-outdated-deployment-jobs) |
| full clone | GitLab [shallow cloning / `GIT_DEPTH`](https://docs.gitlab.com/ci/runners/configure_runners/#shallow-cloning) |
| runner selection | GitLab [`tags`](https://docs.gitlab.com/ci/yaml/#tags) |
| mail (alternative) | GitLab [`after_script`](https://docs.gitlab.com/ci/yaml/#after_script); [curl – SMTP](https://everything.curl.dev/usingcurl/smtp.html), [curl `-K` config file](https://curl.se/docs/manpage.html#-K) |
| mail | GitLab [`when`](https://docs.gitlab.com/ci/yaml/#when), [`needs`](https://docs.gitlab.com/ci/yaml/#needs), [`allow_failure`](https://docs.gitlab.com/ci/yaml/#allow_failure), [pipeline status emails](https://docs.gitlab.com/user/project/integrations/pipeline_status_emails/) (alternative) |
| project runner | GitLab [project runners](https://docs.gitlab.com/ci/runners/runners_scope/#project-runners), [install GitLab Runner (Linux repository)](https://docs.gitlab.com/runner/install/linux-repository/), [registering runners](https://docs.gitlab.com/runner/register/), [shell executor](https://docs.gitlab.com/runner/executors/shell/) |
| secrets | GitLab [CI/CD variables – protect](https://docs.gitlab.com/ci/variables/#protect-a-cicd-variable), [environment scope](https://docs.gitlab.com/ci/variables/#environment-scope), [file type](https://docs.gitlab.com/ci/variables/#use-file-type-cicd-variables); [SSH keys in CI/CD jobs](https://docs.gitlab.com/ci/jobs/ssh_keys/) |
| who may push / release | GitLab [protected branches](https://docs.gitlab.com/user/project/repository/branches/protected/), [protected tags](https://docs.gitlab.com/user/project/protected_tags/) |
| forced command | OpenSSH [`sshd(8)` – AUTHORIZED_KEYS FILE FORMAT](https://man.openbsd.org/sshd#AUTHORIZED_KEYS_FILE_FORMAT) (`command=`, `restrict`, `from=`) |
| SSH client options | OpenSSH [`ssh_config(5)`](https://man.openbsd.org/ssh_config) (`StrictHostKeyChecking`, `UserKnownHostsFile`, `BatchMode`, `IdentitiesOnly`), [`ssh-keyscan(1)`](https://man.openbsd.org/ssh-keyscan), [`ssh-keygen(1)`](https://man.openbsd.org/ssh-keygen) |
| file lists, tar | Git [`git diff`](https://git-scm.com/docs/git-diff), [`git diff-tree`](https://git-scm.com/docs/git-diff-tree), [`git archive`](https://git-scm.com/docs/git-archive), [`git merge-base --is-ancestor`](https://git-scm.com/docs/git-merge-base) |
| release tags | Git [`git tag`](https://git-scm.com/docs/git-tag), [`git for-each-ref`](https://git-scm.com/docs/git-for-each-ref), [`git push`](https://git-scm.com/docs/git-push) |
| one worker at a time | [`flock(1)`](https://man7.org/linux/man-pages/man1/flock.1.html) |
| target folders on the Reports server | Oracle Publishing Reports 12.2.1.3: [`REPORTS_PATH` (B.1.61)](https://docs.oracle.com/middleware/12213/formsandreports/use-reports/pbr_rfap001.htm#i648209), [`folderAccess` in `rwserver.conf` (7.2.1.21)](https://docs.oracle.com/middleware/12213/formsandreports/use-reports/pbr_conf002.htm#CHDJEGID) |
