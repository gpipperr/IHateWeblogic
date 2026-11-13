#!/bin/bash
# =============================================================================
# ci_notify_mail.sh - GitLab CI job: mail after a PROD deploy (prod-* tag)
# =============================================================================
# Called by .gitlab-ci.yml (template.gitlab-ci.yml) after deploy_prod:
#
#   ci_notify_mail.sh ok       deploy_prod was green
#   ci_notify_mail.sh failed   deploy_prod was red
#
# The mail says which tag, which reports (files of the tagged commit), who
# released it, the tag message and the links to pipeline and job. It is
# handed to the local sendmail of the runner host (Postfix with a relayhost
# to the company mail server) - the runner host needs that, see the cookbook.
#
# CI variables (Settings > CI/CD > Variables, scope production):
#   MAIL_TO      recipients, comma separated (required)
#   MAIL_FROM    sender (default: gitlab-runner@<runner host>)
# From GitLab: CI_COMMIT_TAG, CI_COMMIT_TAG_MESSAGE, CI_COMMIT_SHA,
#   GITLAB_USER_NAME, GITLAB_USER_EMAIL, CI_PIPELINE_URL, CI_JOB_URL,
#   CI_PROJECT_PATH
# Only for tests: MAIL_DRYRUN=1 prints the mail instead of sending it.
#
# Doc: Git_deploy.md (IHateWeblogic, 14-ReportsBuilder)
# =============================================================================

set -u

RESULT="${1:-}"
say() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$1" >&2; exit 1; }

[[ "$RESULT" == "ok" || "$RESULT" == "failed" ]] || die "usage: ci_notify_mail.sh ok|failed"
[ -n "${MAIL_TO:-}" ] || die "MAIL_TO not set (CI variable, scope production)"

TAG="${CI_COMMIT_TAG:-<no tag>}"
SHA="${CI_COMMIT_SHA:-}"
FROM="${MAIL_FROM:-gitlab-runner@$(hostname -f)}"

# reports / images of the tagged commit - the same list as deploy_prod
FILES=""
if [ -n "$SHA" ]; then
    FILES="$(git diff-tree -r --root --no-commit-id --name-only --diff-filter=AMR "$SHA" -- source images 2>/dev/null)"
fi
# first report name for the subject (or the tag)
FIRST="$(printf '%s\n' "$FILES" | grep -m1 '\.rdf$')"
FIRST="${FIRST##*/}"
[ -n "$FIRST" ] || FIRST="$TAG"

if [ "$RESULT" = "ok" ]; then
    SUBJECT="[PROD] $FIRST deployed - $TAG"
    STATE="DEPLOYED to production"
else
    SUBJECT="[PROD] FAILED: $FIRST - $TAG"
    STATE="FAILED - the files were NOT (completely) deployed, see the job log"
fi

# subject as RFC 2047 (UTF-8, base64) - report names may hold umlauts
SUBJECT_ENC="=?UTF-8?B?$(printf '%s' "$SUBJECT" | base64 -w0)?="

BODY="$(
    printf 'Production deploy of the Oracle Reports repository %s\n\n' "${CI_PROJECT_PATH:-}"
    printf '  Result      : %s\n' "$STATE"
    printf '  Tag         : %s\n' "$TAG"
    printf '  Commit      : %s\n' "$SHA"
    printf '  Released by : %s <%s>\n' "${GITLAB_USER_NAME:-?}" "${GITLAB_USER_EMAIL:-?}"
    printf '  Pipeline    : %s\n' "${CI_PIPELINE_URL:-}"
    printf '  Job         : %s\n' "${CI_JOB_URL:-}"
    printf '\nTag message:\n%s\n' "${CI_COMMIT_TAG_MESSAGE:-<none>}"
    printf '\nFiles of this check-in (source/*.rdf, images/*):\n'
    if [ -n "$FILES" ]; then
        printf '%s\n' "$FILES" | sed 's/^/  /'
    else
        printf '  <none found>\n'
    fi
    printf '\n-- \nsent by ci_notify_mail.sh on %s\n' "$(hostname -f)"
)"

MAIL="$(
    printf 'From: %s\n' "$FROM"
    printf 'To: %s\n' "$MAIL_TO"
    printf 'Subject: %s\n' "$SUBJECT_ENC"
    printf 'MIME-Version: 1.0\n'
    printf 'Content-Type: text/plain; charset=UTF-8\n'
    printf 'Content-Transfer-Encoding: 8bit\n'
    printf '\n%s\n' "$BODY"
)"

if [ "${MAIL_DRYRUN:-}" = "1" ]; then
    say "--- MAIL_DRYRUN=1 - mail not sent:"
    say "$MAIL"
    exit 0
fi

SENDMAIL=/usr/sbin/sendmail
[ -x "$SENDMAIL" ] || die "$SENDMAIL not found - install Postfix on the runner host (cookbook step 9)"

# -t : recipients from the To: header, -oi : a line with a single dot does not end the mail
printf '%s\n' "$MAIL" | "$SENDMAIL" -t -oi || die "sendmail failed (rc $?) - check: journalctl -u postfix, postconf relayhost"
say "mail sent to: $MAIL_TO  ($SUBJECT)"
exit 0
