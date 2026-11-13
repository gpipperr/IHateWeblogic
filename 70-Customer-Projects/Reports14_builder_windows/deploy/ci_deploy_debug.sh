#!/bin/bash
# =============================================================================
# ci_deploy_debug.sh - show what a GitLab job hands to ci_deploy.sh (no logic)
# =============================================================================
# Writes the call arguments and the variables the job sees as plain
# NAME = value pairs to /tmp/report_pip.txt and prints the same into the
# job log. Changes nothing, connects nowhere.
#
# Use: in .gitlab-ci.yml put it in front of the real call (or replace it
# for one test run):
#
#   script:
#     - bash deploy/ci_deploy_debug.sh dev
#     - bash deploy/ci_deploy.sh dev
#
# /tmp is the /tmp of the runner (shell executor: the runner host; Docker
# executor: gone after the job - then read the job log).
# Secrets: DEPLOY_SSH_KEY is a file variable - only its path is shown,
# never the key. No other secret is listed.
#
# Doc: Git_deploy.md (IHateWeblogic, 70-Customer-Projects/Reports14_builder_windows)
# =============================================================================

OUT=/tmp/report_pip.txt

# one line "NAME = value"; empty or unset -> <empty>
show() {
    printf '  %-24s = %s\n' "$1" "${2:-<empty>}"
}

{
    printf '== ci_deploy_debug.sh  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"

    printf '\n-- 1. Call (from .gitlab-ci.yml, line script:)\n'
    show 'script ($0)'          "$0"
    show 'argument 1 ($1)'      "${1:-}"
    show 'number of arguments'  "$#"
    show 'working directory'    "$(pwd)"
    show 'user'                 "$(id -un)"
    show 'host'                 "$(hostname)"

    printf '\n-- 2. Set by GitLab automatically (predefined variables)\n'
    show CI_PIPELINE_SOURCE     "${CI_PIPELINE_SOURCE:-}"
    show CI_COMMIT_BRANCH       "${CI_COMMIT_BRANCH:-}"
    show CI_COMMIT_TAG          "${CI_COMMIT_TAG:-}"
    show CI_COMMIT_REF_NAME     "${CI_COMMIT_REF_NAME:-}"
    show CI_COMMIT_SHA          "${CI_COMMIT_SHA:-}"
    show CI_COMMIT_SHORT_SHA    "${CI_COMMIT_SHORT_SHA:-}"
    show CI_COMMIT_BEFORE_SHA   "${CI_COMMIT_BEFORE_SHA:-}"
    show CI_COMMIT_TITLE        "${CI_COMMIT_TITLE:-}"
    show CI_COMMIT_AUTHOR       "${CI_COMMIT_AUTHOR:-}"
    show CI_ENVIRONMENT_NAME    "${CI_ENVIRONMENT_NAME:-}"
    show CI_JOB_NAME            "${CI_JOB_NAME:-}"
    show CI_JOB_ID              "${CI_JOB_ID:-}"
    show CI_PIPELINE_ID         "${CI_PIPELINE_ID:-}"
    show CI_PROJECT_PATH        "${CI_PROJECT_PATH:-}"
    show CI_PROJECT_DIR         "${CI_PROJECT_DIR:-}"
    show CI_RUNNER_DESCRIPTION  "${CI_RUNNER_DESCRIPTION:-}"
    show CI_RUNNER_TAGS         "${CI_RUNNER_TAGS:-}"
    show GIT_DEPTH              "${GIT_DEPTH:-}"

    printf '\n-- 3. From Settings > CI/CD > Variables (scope = environment of the job)\n'
    show DEPLOY_HOST            "${DEPLOY_HOST:-}"
    show DEPLOY_USER            "${DEPLOY_USER:-}"
    show 'DEPLOY_SSH_KEY (path)' "${DEPLOY_SSH_KEY:-}"
    if [ -n "${DEPLOY_SSH_KEY:-}" ] && [ -f "$DEPLOY_SSH_KEY" ]; then
        show '  key file present'   'yes (content not shown)'
    else
        show '  key file present'   'no'
    fi
    show DEPLOY_KNOWN_HOSTS     "${DEPLOY_KNOWN_HOSTS:-}"
    show DEPLOY_WAIT            "${DEPLOY_WAIT:-}"
    show RWDEPLOY_LOCAL         "${RWDEPLOY_LOCAL:-}"

    printf '\n-- 4. Tools on the runner\n'
    show bash                   "$(bash --version | head -1)"
    show git                    "$(git --version 2>/dev/null)"
    show ssh                    "$(ssh -V 2>&1)"
} > "$OUT"

cat "$OUT"
printf '\nwritten: %s\n' "$OUT"
exit 0
