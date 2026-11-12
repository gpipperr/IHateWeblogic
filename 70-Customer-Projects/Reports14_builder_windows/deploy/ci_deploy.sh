#!/bin/bash
# =============================================================================
# ci_deploy.sh - GitLab CI job: send Reports sources to a Reports server queue
# =============================================================================
# Called by .gitlab-ci.yml (template.gitlab-ci.yml):
#
#   ci_deploy.sh dev    branch development: whole Reports/source (*.rdf) +
#                       Reports/images as a snapshot
#   ci_deploy.sh prod   branch main: only the files changed since the last
#                       successful PROD deploy (released reports)
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
FILES=()
if [ "$MODE" = "dev" ]; then
    KIND="snapshot"
    # GitLab runs one deploy at a time (resource_group), but not always in push
    # order: a pipeline whose commit is already part of the last deploy must
    # not bring back the older state
    LAST="$(remote last)" || die "cannot read the last deploy from $MODE server"
    LAST="${LAST//[[:space:]]/}"
    if [[ "$LAST" =~ ^[0-9a-f]{7,40}$ ]] && git cat-file -e "$LAST^{commit}" 2>/dev/null \
        && [ "$(git rev-parse "$LAST")" != "$SHA" ] && git merge-base --is-ancestor "$SHA" "$LAST"; then
        say "$SHA is already part of the last deploy $LAST - nothing to do"
        exit 0
    fi
    # all reports and images of this commit
    mapfile -d '' FILES < <(git ls-tree -r -z --name-only "$SHA" -- Reports/source Reports/images)
else
    KIND="delta"
    LAST="$(remote last)" || die "cannot read the last deploy from $MODE server"
    LAST="${LAST//[[:space:]]/}"
    if [ "$LAST" = "none" ]; then
        die "the server has no last deploy - set it once (Git_deploy.md, first set-up PROD)"
    fi
    [[ "$LAST" =~ ^[0-9a-f]{7,40}$ ]] || die "invalid answer for last deploy: '$LAST'"
    git cat-file -e "$LAST^{commit}" 2>/dev/null || \
        die "last deploy $LAST not in this repository (GIT_DEPTH: 0 set?)"
    if [ "$(git rev-parse "$LAST")" = "$SHA" ]; then
        say "already deployed: $SHA - nothing to do"
        exit 0
    fi
    # an older pipeline must never overwrite a newer deploy
    if git merge-base --is-ancestor "$SHA" "$LAST"; then
        say "$SHA is already part of the last deploy $LAST - nothing to do"
        exit 0
    fi
    git merge-base --is-ancestor "$LAST" "$SHA" || \
        die "last deploy $LAST is not an ancestor of $SHA - main rewritten? Check Git_deploy.md"
    say "changes since the last deploy $LAST:"
    # --diff-filter=AMR: added, modified, renamed - deletions are not deployed
    mapfile -d '' FILES < <(git diff -z --name-only --diff-filter=AMR "$LAST" "$SHA" -- Reports/source Reports/images)
fi

# only .rdf from source (xml is for review in git, not for the server)
SEND=()
for f in "${FILES[@]}"; do
    case "$f" in
        Reports/source/*.rdf|Reports/images/*) SEND+=("$f"); say "  $f" ;;
    esac
done
say "files to deploy: ${#SEND[@]} ($KIND)"

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
