#!/usr/bin/env bash
# Thin wrapper around the upstream start script.
#
# It validates the two required variables so a misconfigured container fails
# with a readable message, and it can make the runner name unique per replica.
set -euo pipefail

fail() {
  printf 'runner-entrypoint: %s\n' "$*" >&2
  exit 64
}

[[ -n "${CIRCLECI_RUNNER_API_AUTH_TOKEN:-}" ]] ||
  fail "CIRCLECI_RUNNER_API_AUTH_TOKEN is empty. Run ./setup.sh or edit runner.env."
[[ -n "${CIRCLECI_RUNNER_NAME:-}" ]] ||
  fail "CIRCLECI_RUNNER_NAME is empty. Run ./setup.sh or edit runner.env."

# CircleCI expects each runner instance to have a unique name. Replicas share
# one runner.env, so append the container hostname (unique per container).
if [[ "${RUNNER_NAME_APPEND_HOSTNAME:-false}" == "true" ]]; then
  CIRCLECI_RUNNER_NAME="${CIRCLECI_RUNNER_NAME}-$(hostname)"
  export CIRCLECI_RUNNER_NAME
fi

# exec keeps the signal chain intact: `docker stop` sends TERM, the runner
# drains (finishes the active job, claims no new one) and then exits.
exec /opt/circleci/scripts/run.sh "$@"
