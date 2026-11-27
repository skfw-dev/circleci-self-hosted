#!/usr/bin/env bash
# Day-to-day operations for the CircleCI runner started by setup.sh.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${ROOT_DIR}/lib/common.sh"

usage() {
  cat <<'EOF'
Usage: ./runner.sh <command>

  up         Build if needed and start the runner container(s)
  down       Drain and remove the container(s). An active job gets
             RUNNER_STOP_GRACE_PERIOD (default 10m) to finish.
  restart    Drain, then start again
  status     Container state plus a CPU / memory snapshot
  logs       Follow the runner logs (extra arguments go to `docker compose logs`)
  update     Pull the newest base image, rebuild and recreate the container(s)
  scale N    Run N runner containers
  shell      Open a shell inside a running runner container
  doctor     Check Docker, configuration, permissions, network and token
  help       Show this help
EOF
}

require_config() {
  [[ -f "${ENV_FILE}" && -f "${RUNNER_ENV_FILE}" ]] ||
    die "Not configured yet. Run ./setup.sh first."
}

cmd_up() {
  require_docker
  require_config
  compose up --detach --build --remove-orphans
}

cmd_down() {
  require_docker
  require_config
  info "Stopping; an active job may take up to the stop grace period to finish"
  compose down --remove-orphans
}

cmd_restart() {
  cmd_down
  cmd_up
}

cmd_status() {
  require_docker
  require_config
  compose ps --all
  local ids
  ids="$(compose ps --quiet "${SERVICE}" 2>/dev/null || true)"
  if [[ -n "${ids}" ]]; then
    printf '\n'
    # shellcheck disable=SC2086  # one argument per container id
    docker stats --no-stream \
      --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.PIDs}}' ${ids}
  fi
}

cmd_logs() {
  require_docker
  require_config
  if [[ $# -eq 0 ]]; then
    set -- --follow --tail 100
  fi
  compose logs "$@" "${SERVICE}"
}

cmd_update() {
  require_docker
  require_config
  info "Pulling the base image and rebuilding"
  compose build --pull
  info "Recreating the container(s); an active job is allowed to finish first"
  compose up --detach --remove-orphans
  ok "Updated. Old image layers can be removed with: docker image prune"
}

cmd_scale() {
  [[ "${1:-}" =~ ^[1-9][0-9]*$ ]] || die "Usage: ./runner.sh scale N   (N = 1 or more)"
  require_docker
  require_config
  local n="$1" tmp
  # Persist the value so the next `up` keeps it, and make names unique.
  tmp="$(mktemp "${ROOT_DIR}/.env.XXXXXX")"
  grep -v '^RUNNER_REPLICAS=' "${ENV_FILE}" >"${tmp}" || true
  echo "RUNNER_REPLICAS=${n}" >>"${tmp}"
  chmod 600 "${tmp}"
  mv -f "${tmp}" "${ENV_FILE}"

  local append="false"
  (( n > 1 )) && append="true"
  tmp="$(mktemp "${ROOT_DIR}/runner.env.XXXXXX")"
  chmod 600 "${tmp}"
  grep -v '^RUNNER_NAME_APPEND_HOSTNAME=' "${RUNNER_ENV_FILE}" >"${tmp}" || true
  echo "RUNNER_NAME_APPEND_HOSTNAME=${append}" >>"${tmp}"
  mv -f "${tmp}" "${RUNNER_ENV_FILE}"

  compose up --detach --remove-orphans
  ok "Running ${n} runner container(s)."
}

cmd_shell() {
  require_docker
  require_config
  compose exec "${SERVICE}" bash
}

cmd_doctor() {
  local failures=0 warnings=0 mode name token api_url rc url logs
  pass()    { ok "$*"; }
  problem() { err "$*"; failures=$(( failures + 1 )); }
  caution() { warn "$*"; warnings=$(( warnings + 1 )); }

  info "Docker"
  if ! have docker; then
    problem "docker is not installed"
  elif ! docker compose version >/dev/null 2>&1; then
    problem "Docker Compose v2 ('docker compose') is missing"
  elif ! docker info >/dev/null 2>&1; then
    problem "cannot reach the Docker daemon (is it running? is this user in the docker group?)"
  else
    pass "Docker $(docker version --format '{{.Server.Version}}'), Compose $(docker compose version --short)"
  fi

  info "Configuration"
  if [[ ! -f "${ENV_FILE}" || ! -f "${RUNNER_ENV_FILE}" ]]; then
    problem ".env or runner.env is missing - run ./setup.sh"
  else
    mode="$(file_mode "${RUNNER_ENV_FILE}")"
    if [[ "${mode}" == "600" || "${mode}" == "400" ]]; then
      pass "runner.env permissions are ${mode}"
    else
      problem "runner.env permissions are ${mode}; it holds the token - run: chmod 600 runner.env"
    fi
    name="$(get_kv "${RUNNER_ENV_FILE}" CIRCLECI_RUNNER_NAME)"
    token="$(get_kv "${RUNNER_ENV_FILE}" CIRCLECI_RUNNER_API_AUTH_TOKEN)"
    if [[ -n "${name}" ]]; then pass "runner name: ${name}"; else problem "CIRCLECI_RUNNER_NAME is empty"; fi
    if [[ -z "${token}" || "${token}" == "paste-your-resource-class-token-here" ]]; then
      problem "CIRCLECI_RUNNER_API_AUTH_TOKEN is not set"
    else
      pass "token is set (${#token} characters)"
    fi
    if have docker && compose config --quiet 2>/dev/null; then
      pass "compose configuration is valid"
    else
      problem "compose configuration is invalid - run: docker compose config"
    fi
    if [[ "$(get_kv "${ENV_FILE}" RUNNER_BUILD_TARGET)" == "runner-dood" ]]; then
      caution "host Docker socket is mounted: jobs have root-equivalent access to this host"
    fi
  fi

  info "Network (outbound HTTPS)"
  api_url="$(get_kv "${RUNNER_ENV_FILE}" CIRCLECI_RUNNER_API_URL)"
  for url in "${api_url:-${DEFAULT_API_URL}}" "${BINARY_HOST_URL}" "${STORAGE_HOST_URL}"; do
    rc=0
    endpoint_reachable "${url}" || rc=$?
    case "${rc}" in
      0) pass "reachable: ${url}" ;;
      2) caution "curl is not installed; cannot test ${url}" ;;
      *)
        if [[ "${url}" == "${STORAGE_HOST_URL}" ]]; then
          caution "unreachable: ${url} (needed for caches, workspaces and artifacts)"
        else
          problem "unreachable: ${url}"
        fi
        ;;
    esac
  done

  info "Runner"
  if have docker && docker info >/dev/null 2>&1 && [[ -f "${RUNNER_ENV_FILE}" ]]; then
    if [[ -z "$(compose ps --quiet --status running "${SERVICE}" 2>/dev/null || true)" ]]; then
      problem "no runner container is running - start it with ./runner.sh up"
    else
      pass "runner container(s) running: $(compose ps --quiet --status running "${SERVICE}" | wc -l | tr -d ' ')"
      logs="$(compose logs --no-color --no-log-prefix --tail 200 "${SERVICE}" 2>&1 || true)"
      if grep -q '401 (Unauthorized)' <<<"${logs}"; then
        problem "CircleCI is rejecting the token (401 Unauthorized) - create a new token and run ./setup.sh"
      elif grep -q '/runner/claim' <<<"${logs}"; then
        pass "runner is polling CircleCI for jobs"
      else
        caution "no poll seen in the last 200 log lines - check ./runner.sh logs"
      fi
    fi
  else
    caution "skipped (Docker or configuration unavailable)"
  fi

  printf '\n' >&2
  if (( failures > 0 )); then
    err "${failures} problem(s), ${warnings} warning(s)"
    return 1
  fi
  ok "no problems found, ${warnings} warning(s)"
}

main() {
  local command="${1:-help}"
  [[ $# -gt 0 ]] && shift
  case "${command}" in
    up | start)   cmd_up ;;
    down | stop)  cmd_down ;;
    restart)      cmd_restart ;;
    status | ps)  cmd_status ;;
    logs)         cmd_logs "$@" ;;
    update)       cmd_update ;;
    scale)        cmd_scale "$@" ;;
    shell)        cmd_shell ;;
    doctor)       cmd_doctor ;;
    help | -h | --help) usage ;;
    *)            usage >&2; die "Unknown command: ${command}" ;;
  esac
}

main "$@"
