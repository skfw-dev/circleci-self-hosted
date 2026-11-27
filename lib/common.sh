#!/usr/bin/env bash
# Shared helpers for setup.sh and runner.sh. Sourced, not executed.
# shellcheck shell=bash
# shellcheck disable=SC2034  # variables here are used by the sourcing scripts

# ROOT_DIR must be set by the sourcing script.
ENV_FILE="${ROOT_DIR}/.env"
RUNNER_ENV_FILE="${ROOT_DIR}/runner.env"
SERVICE="runner"
DEFAULT_API_URL="https://runner.circleci.com"
BINARY_HOST_URL="https://circleci-binary-releases.s3.amazonaws.com"
STORAGE_HOST_URL="https://circleci-tasks-prod.s3.us-east-1.amazonaws.com"

if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
  C_RED=$'\033[31m' C_GREEN=$'\033[32m' C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m' C_BOLD=$'\033[1m' C_RESET=$'\033[0m'
else
  C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_BOLD='' C_RESET=''
fi

info() { printf '%s==>%s %s\n' "${C_BLUE}" "${C_RESET}" "$*" >&2; }
ok()   { printf '%s ok %s %s\n' "${C_GREEN}" "${C_RESET}" "$*" >&2; }
warn() { printf '%swarn%s %s\n' "${C_YELLOW}" "${C_RESET}" "$*" >&2; }
err()  { printf '%sfail%s %s\n' "${C_RED}" "${C_RESET}" "$*" >&2; }
die()  { err "$*"; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

# docker compose, always against this project directory.
compose() {
  docker compose --project-directory "${ROOT_DIR}" "$@"
}

# Read KEY from a KEY=value file; strips one pair of surrounding quotes.
get_kv() {
  local file="$1" key="$2" line val
  [[ -f "${file}" ]] || return 0
  line="$(grep -E "^${key}=" "${file}" | tail -n 1 || true)"
  [[ -n "${line}" ]] || return 0
  val="${line#*=}"
  if (( ${#val} >= 2 )); then
    if [[ "${val}" == \'*\' || "${val}" == \"*\" ]]; then
      val="${val:1:${#val}-2}"
    fi
  fi
  printf '%s' "${val}"
}

# Octal permission bits of a file (GNU/BusyBox stat, then BSD stat).
file_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null || echo '?'
}

# Docker Engine, Compose v2 and a reachable daemon. Dies with a hint otherwise.
require_docker() {
  have docker ||
    die "Docker is not installed. See https://docs.docker.com/engine/install/"
  docker compose version >/dev/null 2>&1 ||
    die "Docker Compose v2 is missing ('docker compose'). Install the docker-compose-plugin package."
  docker info >/dev/null 2>&1 ||
    die "Cannot reach the Docker daemon. Start Docker, or run as a user in the 'docker' group (or with sudo)."
}

# Any HTTP response counts as reachable; only connection failures fail.
# Returns 0 reachable, 1 unreachable, 2 curl missing.
endpoint_reachable() {
  have curl || return 2
  curl --silent --show-error --output /dev/null \
    --connect-timeout 5 --max-time 15 "$1" 2>/dev/null
}

# IDs of this project's runner containers (running or not).
runner_container_ids() {
  compose ps --all --quiet "${SERVICE}" 2>/dev/null
}

# Watch the logs until the runner has asked CircleCI for work.
# Returns 0 claim accepted, 1 token rejected (401), 2 container not running,
# 3 no claim seen before the timeout.
wait_for_first_claim() {
  local timeout="${1:-150}" waited=0 logs ids id state
  while (( waited < timeout )); do
    ids="$(runner_container_ids)"
    if [[ -z "${ids}" ]]; then
      return 2
    fi
    for id in ${ids}; do
      state="$(docker inspect --format '{{.State.Status}}' "${id}" 2>/dev/null || echo unknown)"
      if [[ "${state}" != "running" ]]; then
        return 2
      fi
    done
    logs="$(compose logs --no-color --no-log-prefix "${SERVICE}" 2>&1 || true)"
    if grep -q '401 (Unauthorized)' <<<"${logs}"; then
      return 1
    fi
    if grep -q '/runner/claim' <<<"${logs}"; then
      return 0
    fi
    sleep 5
    waited=$(( waited + 5 ))
  done
  return 3
}
