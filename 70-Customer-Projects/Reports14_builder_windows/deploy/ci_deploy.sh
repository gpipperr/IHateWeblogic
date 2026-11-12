#!/bin/bash
# =============================================================================
# ci_deploy.sh - GitLab CI job: send Reports sources to a Reports server queue
# =============================================================================
# Called by .gitlab-ci.yml (template.gitlab-ci.yml):
#
#   ci_deploy.sh dev    push to main: the files changed since the last DEV
#                       deploy (normally the one checked-in report)
#   ci_deploy.sh prod   tag prod-*: exactly the files of the tagged commit
#                       (every report is checked in on its own)
#
# The files go as a tar over SSH to rwdeploy.sh on the server (forced
# command, see authorized_keys.example); then the job waits for the result,
# so the pipeline shows green / red for the deploy itself.
#
# CI variables (Settings > CI/CD > Variables, protected, per environment):
#   DEPLOY_HOST          server name
#   DEPLOY_USER          SSH user (default oracle)
#   DEPLOY_SSH_KEY       private key - variable type "File"
#   DEPLOY_KNOWN_HOSTS   line(s) of ssh-keyscan of the server - fixed host key
#   DEPLOY_WAIT          seconds to wait for the result (default 300)
# From GitLab: CI_COMMIT_SHA, CI_COMMIT_TAG (prod), CI_COMMIT_BEFORE_SHA (dev,
# only used when the server has no last deploy yet)
# Only for tests: RWDEPLOY_LOCAL=<path to rwdeploy.sh> runs it locally
# instead of ssh.
#
# Doc: Git_deploy.md (IHateWeblogic, 70-Customer-Projects/Reports14_builder_windows)
# =============================================================================

set -u
set -o pipefail

MODE="${1:-}"
SHA="${CI_COMMIT_SHA:-}"
WAIT="${DEPLOY_WAIT:-300}"

say() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ "$MODE" == "dev" || "$MODE" == "prod" ]] || die "usage: ci_deploy.sh dev|prod"
[[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || die "CI_COMMIT_SHA missing or invalid"

# --- remote call: ssh with fixed host key, or local for tests
KNOWN_HOSTS_FILE=""
if [ -z "${RWDEPLOY_LOCAL:-}" ]; then
    : "${DEPLOY_HOST:?DEPLOY_HOST not set}"
    : "${DEPLOY_SSH_KEY:?DEPLOY_SSH_KEY not set (CI variable of type File)}"
    : "${DEPLOY_KNOWN_HOSTS:?DEPLOY_KNOWN_HOSTS not set (ssh-keyscan of the server)}"
    KNOWN_HOSTS_FILE="$(mktemp)"
    printf '%s\n' "$DEPLOY_KNOWN_HOSTS" > "$KNOWN_HOSTS_FILE"
    chmod 600 "$DEPLOY_SSH_KEY"
    trap 'rm -f "$KNOWN_HOSTS_FILE"' EXIT
fi

remote() {
    if [ -n "${RWDEPLOY_LOCAL:-}" ]; then
        SSH_ORIGINAL_COMMAND="$1" "$RWDEPLOY_LOCAL"
    else
        # BatchMode: never ask for a password; StrictHostKeyChecking=yes +
        # own known_hosts: only the server with the stored host key
        ssh -i "$DEPLOY_SSH_KEY" -o BatchMode=yes -o IdentitiesOnly=yes \
            -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN_HOSTS_FILE" \
            "${DEPLOY_USER:-oracle}@$DEPLOY_HOST" "$1"
    fi
}

# --- file list -------------------------------------------------------------
# files changed by one commit (a merge commit has none of its own)
commit_files() {
    # diff-tree: --root also for the very first commit, -r into folders,
    # --no-commit-id only the paths; deletions (D) are not deployed
    git diff-tree -z -r --root --no-commit-id --name-only --diff-filter=AMR "$1" -- Reports/source Reports/images
}

FILES=()
if [ "$MODE" = "dev" ]; then
    KIND="delta"
    # push to main: the files changed since the last DEV deploy - normally
    # exactly the checked-in report. One push can carry several check-ins,
    # and a failed pipeline is made up for by the next one.
    LAST="$(remote last)" || die "cannot read the last deploy from $MODE server"
    LAST="${LAST//[[:space:]]/}"
    if [[ "$LAST" =~ ^[0-9a-f]{7,40}$ ]] && git cat-file -e "$LAST^{commit}" 2>/dev/null; then
        if [ "$(git rev-parse "$LAST")" = "$SHA" ]; then
            say "already deployed: $SHA - nothing to do"
            exit 0
        fi
        # GitLab runs one deploy at a time (resource_group), but not always in
        # push order: an older pipeline must not bring back an older state
        if git merge-base --is-ancestor "$SHA" "$LAST"; then
            say "$SHA is already part of the last deploy $LAST - nothing to do"
            exit 0
        fi
        if git merge-base --is-ancestor "$LAST" "$SHA"; then
            say "changes since the last deploy $LAST:"
            # --diff-filter=AMR: added, modified, renamed - deletions are not deployed
            mapfile -d '' FILES < <(git diff -z --name-only --diff-filter=AMR "$LAST" "$SHA" -- Reports/source Reports/images)
        else
            say "WARNING: last deploy $LAST is not an ancestor of $SHA (main rewritten?) - only the files of this commit"
            mapfile -d '' FILES < <(commit_files "$SHA")
        fi
    else
        # first deploy (server answers "none") or unknown commit: the files of
        # this push (GitLab: CI_COMMIT_BEFORE_SHA = main before the push),
        # otherwise only the files of this commit
        BEFORE="${CI_COMMIT_BEFORE_SHA:-}"
        if [[ "$BEFORE" =~ ^[0-9a-f]{40}$ ]] && [[ ! "$BEFORE" =~ ^0+$ ]] \
            && git cat-file -e "$BEFORE^{commit}" 2>/dev/null && git merge-base --is-ancestor "$BEFORE" "$SHA"; then
            say "no usable last deploy ('$LAST') - the files of this push since $BEFORE"
            mapfile -d '' FILES < <(git diff -z --name-only --diff-filter=AMR "$BEFORE" "$SHA" -- Reports/source Reports/images)
        else
            say "no usable last deploy ('$LAST') - only the files of this commit"
            mapfile -d '' FILES < <(commit_files "$SHA")
        fi
    fi
else
    KIND="tag"
    # tag prod-...: exactly the files of the tagged commit - every report is
    # checked in on its own, so this is the released report. Older or newer
    # check-ins of other reports stay where they are.
    say "tag ${CI_COMMIT_TAG:-?} on $SHA"
    parents="$(git rev-list --parents -n 1 "$SHA" | wc -w)"
    if [ "$parents" -gt 2 ]; then
        die "the tag is on a merge commit - put it on the check-in of the report (release_tag.ps1)"
    fi
    say "files of this commit:"
    mapfile -d '' FILES < <(commit_files "$SHA")
fi

# only .rdf from source (xml is for review in git, not for the server)
SEND=()
for f in "${FILES[@]}"; do
    case "$f" in
        Reports/source/*.rdf|Reports/images/*) SEND+=("$f"); say "  $f" ;;
    esac
done
say "files to deploy: ${#SEND[@]} ($KIND)"
if [ "$MODE" = "prod" ] && [ "${#SEND[@]}" -eq 0 ]; then
    die "the tagged commit holds no report (.rdf) or image - nothing to deploy, check the tag"
fi

# --- send + wait -------------------------------------------------------------
if [ "${#SEND[@]}" -gt 0 ]; then
    git archive --format=tar "$SHA" -- "${SEND[@]}" | remote "enqueue $SHA $KIND" || die "enqueue failed"
else
    # empty tar - the server still records this commit as deployed
    tar -cf - --files-from /dev/null | remote "enqueue $SHA $KIND" || die "enqueue failed"
fi

remote "status $SHA --wait $WAIT"
rc=$?
case "$rc" in
    0) say "deploy OK" ;;
    2) say "deploy still pending after ${WAIT}s - check later: rwdeploy.sh list" ;;
    *) say "deploy FAILED - see the log above" ;;
esac
exit "$rc"
